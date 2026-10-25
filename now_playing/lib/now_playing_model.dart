import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lyrics.dart';
import 'net.dart';
import 'media_cache.dart';
import 'local_artwork.dart';
import 'palette.dart';

/// Talks to the Kotlin side (MainActivity) which listens to the active
/// Android media session, whichever player app owns it.
class NowPlayingModel extends ChangeNotifier {
  static const _events = EventChannel('nowplaying/stream');
  static const _control = MethodChannel('nowplaying/control');
  static const _fftEvents = EventChannel('nowplaying/fft');

  bool accessGranted = true; // assume yes until Android says otherwise
  bool visualizerEnabled = true;
  bool artLookupEnabled = true;
  bool lyricsEnabled = false;
  List<LyricLine>? lyrics;
  bool active = false;
  bool playing = false;
  String title = '';
  String artist = '';
  String album = '';
  int durationMs = 0;
  ArtAssets? art;

  int _posMs = 0;
  double _speed = 1.0;
  DateTime _stamp = DateTime.now();
  String _trackKey = '';
  int _artToken = 0;
  int _lyricsToken = 0;
  Timer? _netTimer;
  Timer? _artClearTimer;
  Timer? _sessionVerificationTimer;
  Timer? _artRetryTimer;
  Timer? _sessionArtRetryTimer;
  int _sessionArtRetries = 0;
  String _lookupInFlight = '';
  int _artAttempts = 0;
  String artworkStatus = 'Waiting for playback';
  String sessionArtworkStatus = 'No media-session event yet';
  String artworkSource = 'None';
  String artworkFailure = 'None';
  String artworkLookupState = 'Idle';

  String get artworkDiagnostics => 'Track: $title\nArtist: $artist\nAlbum: $album\n'
      'Session artwork: $sessionArtworkStatus\n'
      'Source: $artworkSource\nLookup: $artworkLookupState\n'
      'Status: $artworkStatus\nFailure: $artworkFailure\n'
      'Cover displayed: ${art != null && !art!.flat}';
  Timer? _idleTimer;
  String _albumKey = '';
  bool _needsArt = false; // album changed and the player sent no new cover yet
  String _sentLaunch = '';
  final Map<String, Uint8List> _artCache = {};
  // Reuse covers across songs on the same positively identified album.
  final Map<String, Uint8List> _albumArtCache = {};
  // Detect a player-supplied placeholder or shared playlist cover when the
  // identical image appears under unrelated artist/album identities.
  final Map<int, Set<String>> _sessionArtOwners = {};
  final Set<int> _sharedSessionImages = {};
  final Set<int> _markedPlaceholders = {};
  Uint8List? _latestSessionArtwork;
  bool _placeholderHashesLoaded = false;

  Future<void> _loadPlaceholderHashes() async {
    if (_placeholderHashesLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    _markedPlaceholders.addAll((prefs.getStringList('vybe_marked_placeholder_hashes') ?? <String>[])
        .map(int.tryParse).whereType<int>());
    _placeholderHashesLoaded = true;
  }

  bool get canMarkSessionPlaceholder => _latestSessionArtwork != null;

  Future<bool> markCurrentSessionArtAsPlaceholder() async {
    final bytes = _latestSessionArtwork;
    if (bytes == null || bytes.isEmpty) return false;
    await _loadPlaceholderHashes();
    final hash = _imageFingerprint(bytes);
    _markedPlaceholders.add(hash);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('vybe_marked_placeholder_hashes',
        _markedPlaceholders.map((x) => x.toString()).toList());
    _sharedSessionImages.add(hash);
    _albumArtCache.remove(_albumArtKey(artist, album));
    _artCache.remove('${artist.toLowerCase()}|${title.toLowerCase()}');
    _sessionVerificationTimer?.cancel();
    _artToken++;
    art = null;
    artworkSource = 'None';
    sessionArtworkStatus = 'Rejected manually marked placeholder';
    artworkStatus = 'Known player placeholder rejected';
    artworkLookupState = 'Looking up real album artwork';
    notifyListeners();
    if (artLookupEnabled && title.isNotEmpty) _lookupArt(force: true);
    return true;
  }

  int _imageFingerprint(Uint8List bytes) {
    // FNV-1a over all bytes; no image decoding required.
    var hash = 2166136261;
    for (final value in bytes) {
      hash = ((hash ^ value) * 16777619) & 0xffffffff;
    }
    return hash;
  }

  bool _isSharedSessionArtwork(Uint8List bytes) {
    final hash = _imageFingerprint(bytes);
    final owner = '${artist.trim().toLowerCase()}|${album.trim().toLowerCase()}';
    final owners = _sessionArtOwners.putIfAbsent(hash, () => <String>{});
    owners.add(owner);
    if (owners.length >= 2 &&
        owners.map((x) => x.split('|').first).toSet().length >= 2) {
      _sharedSessionImages.add(hash);
    }
    if (_sessionArtOwners.length > 150) _sessionArtOwners.remove(_sessionArtOwners.keys.first);
    return _markedPlaceholders.contains(hash) || _sharedSessionImages.contains(hash);
  }


  String _albumArtKey(String artistName, String albumName) {
    final a = artistName.trim().toLowerCase();
    final b = albumName.trim().toLowerCase();
    return a.isNotEmpty && b.isNotEmpty ? 'album|$a|$b' : '';
  }

  void _rememberAlbumArt(Uint8List bytes, String albumKey) {
    if (albumKey.isEmpty || bytes.isEmpty) return;
    _albumArtCache[albumKey] = bytes;
    if (_albumArtCache.length > 24) {
      _albumArtCache.remove(_albumArtCache.keys.first);
    }
    MediaCache.putArt(albumKey, bytes);
  }
  final Map<String, List<LyricLine>?> _lyricsCache = {};
  StreamSubscription? _sub;
  StreamSubscription? _fftSub;

  /// Latest frequency bands from the audio output (96 values, 0..255).
  Uint8List? fft;
  DateTime _realAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// True while the device is giving us real audio data. When it stops
  /// (older/newer Android blocking it, or silence) the screen falls back to
  /// the simulated visualizer.
  bool get realActive =>
      fft != null && DateTime.now().difference(_realAt).inMilliseconds < 1500;

  void start() {
    _sub = _events.receiveBroadcastStream().listen(_onEvent, onError: (_) {});
    _fftSub =
        _fftEvents.receiveBroadcastStream().listen(_onFft, onError: (_) {});
    if (visualizerEnabled) startVisualizer();
  }

  void _onFft(dynamic e) {
    if (e is! Uint8List) return;
    fft = e;
    var sum = 0;
    for (final b in e) {
      sum += b;
    }
    if (sum > 30) _realAt = DateTime.now();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _fftSub?.cancel();
    _netTimer?.cancel();
    _artClearTimer?.cancel();
    _sessionVerificationTimer?.cancel();
    _artRetryTimer?.cancel();
    _sessionArtRetryTimer?.cancel();
    _idleTimer?.cancel();
    super.dispose();
  }

  /// Current position, interpolated between updates from the player.
  int get positionMs {
    var p = _posMs;
    if (playing) {
      p += (DateTime.now().difference(_stamp).inMilliseconds * _speed).round();
    }
    if (durationMs > 0 && p > durationMs) p = durationMs;
    return p < 0 ? 0 : p;
  }

  bool _linkReceiverActive = false;
  void setLinkReceiverActive(bool on) {
    _linkReceiverActive = on;
    if (on) { _netTimer?.cancel(); _artRetryTimer?.cancel(); _artClearTimer?.cancel(); }
    if (!on) { _clearAll(); active = false; notifyListeners(); }
  }

  void applyLinkMetadata({required String titleValue, required String artistValue,
      required String albumValue, required bool isPlaying, required bool isActive,
      required int duration, required int position, Uint8List? artwork}) {
    if (!_linkReceiverActive) return;
    final key = '$titleValue|$artistValue|$albumValue';
    final changed = key != _trackKey;
    if (changed) {
      _artToken++; _artRetryTimer?.cancel(); _artClearTimer?.cancel();
      _artAttempts = 0; _lookupInFlight = ''; art = null;
      lyrics = null; _lyricsToken++;
    }
    title = titleValue; artist = artistValue; album = albumValue;
    active = isActive; playing = isPlaying;
    durationMs = duration; _posMs = position; _stamp = DateTime.now();
    _trackKey = key; _albumKey = '${artist.toLowerCase()}|${album.toLowerCase()}';
    if (artwork != null && (changed || art == null || !listEquals(art!.bytes, artwork))) {
      _setArt(artwork);
    }
    if (changed && lyricsEnabled) _fetchLyrics();
    notifyListeners();
  }

  void applyLinkArtwork(Uint8List bytes) {
    if (!_linkReceiverActive || bytes.isEmpty) return;
    _setArt(bytes);
    notifyListeners();
  }

  void _onEvent(dynamic e) {
    if (_linkReceiverActive) return;
    final m = Map<String, dynamic>.from(e as Map);
    accessGranted = m['access'] == true;
    final nowActive = m['active'] == true;

    if (!accessGranted) {
      _idleTimer?.cancel();
      active = false;
      _clearAll();
      notifyListeners();
      return;
    }

    if (!nowActive) {
      // Players sometimes drop their session for a moment between songs or
      // albums. Wait before treating it as "nothing playing", so the screen
      // does not flash the empty state.
      playing = false;
      _idleTimer ??= Timer(const Duration(milliseconds: 2500), () {
        _idleTimer = null;
        active = false;
        _clearAll();
        notifyListeners();
      });
      notifyListeners();
      return;
    }
    _idleTimer?.cancel();
    _idleTimer = null;
    active = true;

    playing = m['playing'] == true;
    title = (m['title'] as String?) ?? '';
    artist = (m['artist'] as String?) ?? '';
    album = (m['album'] as String?) ?? '';
    durationMs = (m['duration'] as num?)?.toInt() ?? 0;
    _posMs = (m['position'] as num?)?.toInt() ?? 0;
    _speed = (m['speed'] as num?)?.toDouble() ?? 1.0;
    _stamp = DateTime.now();

    // The song's length often arrives a moment after its title, so it is
    // left out of the key: it must not count as a track change.
    final key = '$title|$artist|$album';
    final changed = key != _trackKey;
    final albumKey = '${artist.toLowerCase()}|${album.toLowerCase()}';
    final cacheAlbumKey = _albumArtKey(artist, album);
    final albumChanged = albumKey != _albumKey;

    if (changed) {
      _artToken++; // Invalidate lookups and decoding from the previous song.
      _artRetryTimer?.cancel();
      _sessionVerificationTimer?.cancel();
      _sessionArtRetryTimer?.cancel();
      _sessionArtRetries = 0;
      _artAttempts = 0;
      _lookupInFlight = '';
      _needsArt = false;
      sessionArtworkStatus = 'Awaiting artwork for new track';
      artworkSource = 'None';
      artworkFailure = 'None';
      artworkLookupState = 'Idle';
      _artClearTimer?.cancel();
      // Only reuse a cover when the album is positively identified as the same.
      if (albumChanged || album.isEmpty) art = null;
      // Restore an already decoded cover from another track on this album.
      if (art == null && cacheAlbumKey.isNotEmpty) {
        final cached = _albumArtCache[cacheAlbumKey];
        if (cached != null) {
          artworkSource = 'Album memory cache';
          _setArt(cached);
        }
      }
    }

    final artBytes = m['art'];
    if (artBytes is Uint8List && artBytes.isNotEmpty) {
      _latestSessionArtwork = artBytes;
      if (!_placeholderHashesLoaded) {
        _loadPlaceholderHashes().then((_) {
          if (_markedPlaceholders.contains(_imageFingerprint(artBytes)) &&
              _trackKey == key) {
            _albumArtCache.remove(cacheAlbumKey);
            _artToken++;
            art = null;
            artworkSource = 'None';
            sessionArtworkStatus = 'Rejected saved placeholder';
            notifyListeners();
            if (artLookupEnabled) _lookupArt(force: true);
          }
        });
      }
    } else if (changed) {
      _latestSessionArtwork = null;
    }
    if (artBytes is Uint8List && artBytes.isNotEmpty &&
        _isSharedSessionArtwork(artBytes)) {
      sessionArtworkStatus = 'Rejected repeated image across unrelated artists';
      artworkSource = 'None';
      artworkStatus = 'Shared player placeholder or playlist cover rejected';
      artworkLookupState = 'Looking up original track artwork';
      artworkFailure = 'Identical player artwork seen for multiple artists';
      _albumArtCache.remove(cacheAlbumKey);
      art = null;
      _artToken++;
      _netTimer?.cancel();
      _netTimer = Timer(const Duration(milliseconds: 200), _runNetwork);
    } else if (artBytes is Uint8List && artBytes.isNotEmpty) {
      sessionArtworkStatus = 'Received ${artBytes.length} bytes';
      artworkSource = 'Android media session';
      artworkStatus = 'Android media session artwork';
      _artClearTimer?.cancel();
      _sessionArtRetryTimer?.cancel();
      _needsArt = false;
      if (art == null || !listEquals(art!.bytes, artBytes)) {
        _setArt(artBytes);
      }
      // Media-session images are unverified: player apps may send their
      // branded placeholder even for well-known albums. Verify independently
      // rather than treating successful decoding as proof of album art.
      if (changed && artLookupEnabled) {
        final expectedTrack = key;
        _sessionVerificationTimer?.cancel();
        _sessionVerificationTimer = Timer(const Duration(milliseconds: 900), () {
          if (_trackKey == expectedTrack) _verifySessionArtwork();
        });
      }
    } else if (changed && art != null) {
      sessionArtworkStatus = 'Missing (no bytes in media session)';
      // Keep showing the current cover. Within the same album it stays for
      // good. If the album changed and no new cover shows up in a few
      // seconds, drop it so the placeholder (or an online lookup) takes over.
      if (albumChanged || album.isEmpty) {
        _needsArt = true;
        _artClearTimer?.cancel();
        _artClearTimer = Timer(const Duration(seconds: 3), () {
          if (!_needsArt) return;
          _artToken++;
          art = null;
          notifyListeners();
          if (artLookupEnabled && title.isNotEmpty) _lookupArt();
        });
      }
    }
    if ((artBytes is! Uint8List || artBytes.isEmpty) && changed) {
      sessionArtworkStatus = 'Missing (no bytes in media session)';
    }
    _trackKey = key;
    _albumKey = albumKey;
    if (art == null && title.isNotEmpty) _scheduleSessionArtRetry();

    if (changed) {
      lyrics = null;
      _lyricsToken++;
      // Wait a moment: players often update the metadata twice in a row.
      _netTimer?.cancel();
      _netTimer = Timer(const Duration(milliseconds: 700), _runNetwork);
    }
    notifyListeners();
  }

  // Re-query the Android media session when the player publishes metadata
  // before its artwork. A refresh re-reads the existing session without
  // restarting the music player or changing the track.
  void _scheduleSessionArtRetry() {
    if (_sessionArtRetryTimer != null || _sessionArtRetries >= 6 ||
        _linkReceiverActive) return;
    final track = _trackKey;
    final delays = <int>[1, 2, 3, 5, 8, 12];
    final delay = delays[_sessionArtRetries++];
    _sessionArtRetryTimer = Timer(Duration(seconds: delay), () {
      _sessionArtRetryTimer = null;
      if (_trackKey != track || art != null || !active) return;
      _control.invokeMethod<void>('recheckArtwork').catchError((_) {});
      _scheduleSessionArtRetry();
    });
  }

  void _clearAll() {
    title = '';
    artist = '';
    album = '';
    durationMs = 0;
    _trackKey = '';
    _albumKey = '';
    _needsArt = false;
    _latestSessionArtwork = null;
    _artClearTimer?.cancel();
    _sessionVerificationTimer?.cancel();
    _artRetryTimer?.cancel();
    _sessionArtRetryTimer?.cancel();
    _sessionArtRetries = 0;
    _artAttempts = 0;
    _lookupInFlight = '';
    _artToken++;
    art = null;
    lyrics = null;
    _lyricsToken++;
  }

  void _runNetwork() {
    if (title.isEmpty || _linkReceiverActive) return;
    if (artLookupEnabled && art == null) _lookupLocalFirst();
    if (lyricsEnabled) _fetchLyrics();
  }

  Future<void> _verifySessionArtwork() async {
    final token = _artToken;
    final track = _trackKey;
    final local = await LocalArtwork.instance.albumArt(artist, album);
    if (token != _artToken || track != _trackKey) return;
    if (local != null && local.isNotEmpty) {
      artworkSource = 'Verified local album artwork';
      _setArt(local);
      return;
    }
    // Force a catalog query, bypassing potentially contaminated old caches.
    // Retain the session image if no verified replacement is found.
    _lookupArt(force: true, verifySession: true);
  }

  Future<void> _lookupLocalFirst() async {
    final token = _artToken;
    final track = _trackKey;
    final bytes = await LocalArtwork.instance.albumArt(artist, album);
    if (token != _artToken || track != _trackKey || art != null) return;
    if (bytes != null && bytes.isNotEmpty) {
      artworkSource = 'Local artwork index';
      artworkStatus = 'Matched local album artwork';
      _setArt(bytes);
      notifyListeners();
    } else {
      _lookupArt();
    }
  }

  Future<void> _lookupArt({bool force = false, bool verifySession = false}) async {
    if (_linkReceiverActive || !artLookupEnabled || title.trim().isEmpty) return;
    final token = _artToken;
    final track = _trackKey;
    final k = '${artist.trim().toLowerCase()}|${title.trim().toLowerCase()}';
    if (_lookupInFlight == k && !force) return;
    if (force) {
      _artRetryTimer?.cancel();
      _artAttempts = 0;
    }
    // _runNetwork can be called repeatedly for one track; do not let it
    // bypass the retry budget after the scheduled attempts are exhausted.
    if (_artAttempts >= 4) return;
    _lookupInFlight = k;
    _artAttempts++;
    try {
      final albumCacheKey = _albumArtKey(artist, album);
      Uint8List? bytes = force ? null : _artCache[k];
      bytes ??= force || albumCacheKey.isEmpty ? null : _albumArtCache[albumCacheKey];
      bytes ??= force ? null : await MediaCache.getArt(k);
      bytes ??= force || albumCacheKey.isEmpty ? null : await MediaCache.getArt(albumCacheKey);
      if (bytes != null) artworkSource = 'Memory or disk cache';
      if (bytes == null) {
        artworkStatus = 'Searching online catalogs';
        artworkLookupState = 'Searching iTunes / Cover Art Archive';
        notifyListeners();
      }
      bytes ??= await fetchArtwork(title, artist, album: album);
      if (bytes != null && artworkSource != 'Memory or disk cache') artworkSource = 'Online catalog (iTunes or Cover Art Archive)';
      if (token != _artToken || track != _trackKey) return;
      if (bytes != null) {
        final decoded = await ArtAssets.load(bytes);
        if (token != _artToken || track != _trackKey) return;
        if (decoded != null && !decoded.flat) {
          _artCache[k] = bytes;
          _rememberAlbumArt(bytes, albumCacheKey);
          MediaCache.putArt(k, bytes);
          if (_artCache.length > 12) _artCache.remove(_artCache.keys.first);
          // Use decoded artwork directly: _setArt would invalidate this lookup's token.
          art = decoded;
          artworkStatus = verifySession ? 'Media-session cover verified/replaced by online catalog' : 'Artwork restored from cache or online catalog';
          artworkLookupState = 'Found and decoded';
          artworkFailure = 'None';
          _needsArt = false;
          _artClearTimer?.cancel();
          _artRetryTimer?.cancel();
          notifyListeners();
          return;
        }
      }
    } catch (error) {
      artworkFailure = 'Lookup exception: $error';
      artworkLookupState = 'Failed';
      // A temporary network/decoder failure must not permanently suppress retries.
      debugPrint('VYBE artwork lookup failed for $k: $error');
    } finally {
      if (_lookupInFlight == k) _lookupInFlight = '';
    }
    if (token == _artToken && track == _trackKey && art == null) {
      artworkStatus = _artAttempts < 4
          ? 'Artwork not found; retry ${_artAttempts}/4'
          : 'Artwork not found; automatic retries exhausted (4/4)';
      artworkLookupState = 'No usable match (attempt $_artAttempts/4)';
      if (artworkFailure == 'None') artworkFailure = 'No usable artwork returned by catalogs';
      notifyListeners();
    }
    if (token == _artToken && track == _trackKey && art == null && _artAttempts < 4) {
      // Never cache a failed lookup. Retry while the same track remains active.
        _artRetryTimer?.cancel();
        _artRetryTimer = Timer(Duration(seconds: 12 * _artAttempts), () {
          if (_trackKey == track && art == null) _lookupArt();
        });
    }
  }

  /// User-requested artwork refresh; bypasses cached artwork and retries online.
  void refreshArtwork() {
    if (title.isEmpty || !artLookupEnabled) return;
    _artToken++;
    _lookupInFlight = '';
    _lookupArt(force: true);
  }

  Future<void> _fetchLyrics() async {
    final token = ++_lyricsToken;
    final k = '${artist.toLowerCase()}|${title.toLowerCase()}';
    List<LyricLine>? found;
    if (_lyricsCache.containsKey(k)) {
      found = _lyricsCache[k];
    } else {
      found = await MediaCache.getLyrics(k);
      found ??= await fetchSyncedLyrics(title, artist, durationMs);
      if (found != null) {
        _lyricsCache[k] = found;
        MediaCache.putLyrics(k, found);
      }
      if (_lyricsCache.length > 12) _lyricsCache.remove(_lyricsCache.keys.first);
    }
    if (token != _lyricsToken) return;
    lyrics = found;
    notifyListeners();
  }

  /// Index of the lyric line being sung at [ms], or -1 before the first.
  int lyricIndexAt(int ms) {
    final l = lyrics;
    if (l == null || l.isEmpty) return -1;
    var lo = 0, hi = l.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (l[mid].ms <= ms) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  void setLyricsEnabled(bool on) {
    lyricsEnabled = on;
    if (on) {
      if (title.isNotEmpty) _fetchLyrics();
    } else {
      lyrics = null;
      _lyricsToken++;
      notifyListeners();
    }
  }

  void setArtLookup(bool on) {
    artLookupEnabled = on;
    if (on && title.isNotEmpty && art == null) _lookupArt();
  }

  Future<void> _setArt(Uint8List bytes) async {
    final token = ++_artToken;
    final albumCacheKey = _albumArtKey(artist, album);
    final loaded = await ArtAssets.load(bytes);
    if (token != _artToken) return;
    // Generic music-player placeholders are not usable album artwork.
    art = (loaded != null && !loaded.flat) ? loaded : null;
    if (art == null) {
      // Keep a previously verified cover only when new media-session bytes
      // cannot be decoded at all.
      final previousAlbumCover = _albumArtCache[albumCacheKey];
      if (previousAlbumCover != null && !listEquals(previousAlbumCover, bytes)) {
        final restored = await ArtAssets.load(previousAlbumCover);
        if (token != _artToken) return;
        if (restored != null && !restored.flat) {
          art = restored;
          artworkSource = 'Album memory cache';
          artworkLookupState = 'Restored valid album cover';
        }
      }
      if (art == null) {
        artworkFailure = loaded == null
            ? 'Media-session image could not be decoded'
            : 'Media-session image unavailable';
        if (artworkSource == 'Android media session') {
          sessionArtworkStatus = 'Received but unusable';
        }
      }
    } else {
      artworkFailure = 'None';
      artworkLookupState = 'Artwork displayed';
    }
    // Never persist an unverified media-session image as a known album cover.
    if (art != null && artworkSource != 'Android media session') {
      _rememberAlbumArt(bytes, albumCacheKey);
    }
    if (art == null && artLookupEnabled && title.isNotEmpty) {
      // Avoid blocking the media-session event while lookup runs.
      _netTimer?.cancel();
      _netTimer = Timer(const Duration(milliseconds: 700), _runNetwork);
    }
    _needsArt = false;
    _artClearTimer?.cancel();
    notifyListeners();
  }

  Future<void> playPause() => _call('playPause');
  Future<void> next() => _call('next');
  Future<void> previous() => _call('previous');
  Future<void> refresh() async {
    await _call('refresh');
    if (visualizerEnabled) await _call('startVisualizer');
  }

  void setVisualizer(bool on) {
    visualizerEnabled = on;
    _call(on ? 'startVisualizer' : 'stopVisualizer');
  }

  Future<void> seekTo(int ms) => _call('seekTo', ms);
  /// Returns 'ok', or a short message explaining why it could not open.
  Future<String?> openPlayer() async {
    try {
      return await _control.invokeMethod<String>('openPlayer');
    } catch (_) {
      return 'Could not open the player';
    }
  }
  Future<void> openOverlaySettings() => _call('openOverlaySettings');

  /// Tells the Kotlin side when it may open VYBE by itself.
  void setLaunchSettings({
    required bool boot,
    required bool music,
    required int graceSec,
    required bool allowVideo,
    required bool allowNav,
    required bool avoidNav,
    required String navPkg,
  }) {
    final key =
        '$boot|$music|$graceSec|$allowVideo|$allowNav|$avoidNav|$navPkg';
    if (key == _sentLaunch) return;
    _control.invokeMethod('setLaunchSettings', {
      'boot': boot,
      'music': music,
      'graceSec': graceSec,
      'allowVideo': allowVideo,
      'allowNav': allowNav,
      'avoidNav': avoidNav,
      'navPkg': navPkg,
    }).then((_) {
      _sentLaunch = key; // Only suppress repeats after native acknowledgement.
    }).catchError((Object e) {
      _sentLaunch = ''; // Permit retry on the next settings notification.
      debugPrint('VYBE native launch settings failed: $e');
    });
  }

  Future<void> startVisualizer() => _call('startVisualizer');
  Future<void> openAccessSettings() => _call('openAccessSettings');

  Future<void> _call(String method, [dynamic args]) async {
    try {
      await _control.invokeMethod(method, args);
    } catch (_) {}
  }
}
