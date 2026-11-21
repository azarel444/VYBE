import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'stream_track_metadata.dart';

/// Music Video: user-initiated official YouTube embed with the source player's
/// audio paused during video playback. When no verified video is available,
/// the normal source audio and VYBE fanart/album art remain the fallback.
/// Only YouTube IDs and overlay preferences are cached, never video streams.
class MusicVideoTheme extends StatefulWidget {
  final String title;
  final String artist;
  final String album;
  final String sourcePackage;
  /// Catalog/release art, used only while an embedded music video is active.
  final Uint8List? artwork;
  /// Original art from the music player for fallback/album-only playback.
  final Uint8List? fallbackArtwork;
  final Uint8List? fanart;
  final Uint8List? clearLogo;
  final Color accent;
  /// Reuse the real, spinning Record Cut renderer. Never draw a fake vinyl.
  final Widget Function(double diameter) buildVinyl;
  /// Reuse the shared VYBE appearance and typography renderers.
  final Widget Function() buildFallbackBackground;
  final Widget Function(Alignment alignment) buildArtist;
  final Widget Function(Alignment alignment) buildTitle;
  final Widget Function(Alignment alignment) buildAlbum;
  final double backgroundDarkness;
  final double artistLogoScale;
  final ValueChanged<bool> onVideoPlaybackChanged;
  final int sourcePositionMs;
  final int sourceDurationMs;
  final bool sourcePlaying;
  final Future<void> Function(int) onSeekSource;
  final Future<void> Function() onSourcePlayPause;
  final VoidCallback onOpenThemes;
  final VoidCallback onToggleUtilityMenu;
  final VoidCallback onOpenCustomize;
  final VoidCallback onOpenSettings;

  const MusicVideoTheme({
    super.key,
    required this.title,
    required this.artist,
    required this.album,
    required this.sourcePackage,
    required this.accent,
    required this.buildVinyl,
    required this.buildFallbackBackground,
    required this.buildArtist,
    required this.buildTitle,
    required this.buildAlbum,
    required this.backgroundDarkness,
    required this.artistLogoScale,
    required this.onVideoPlaybackChanged,
    required this.sourcePositionMs,
    required this.sourceDurationMs,
    required this.sourcePlaying,
    required this.onSeekSource,
    required this.onSourcePlayPause,
    required this.onOpenThemes,
    required this.onToggleUtilityMenu,
    required this.onOpenCustomize,
    required this.onOpenSettings,
    this.artwork,
    this.fallbackArtwork,
    this.fanart,
    this.clearLogo,
  });

  @override
  State<MusicVideoTheme> createState() => _MusicVideoThemeState();
}

class _MusicVideoThemeState extends State<MusicVideoTheme>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('nowplaying/control');
  static const _origin = 'https://com.conjure.now_playing';
  static const _ytMusic = 'com.google.android.apps.youtube.music';

  late final WebViewController _web;
  Timer? _callTimer;
  bool _busy = false;
  bool _embedded = false;
  bool _ready = false;
  bool _playWhenReady = false;
  bool _videoPlaying = false;
  bool _advancing = false;
  bool _pausedSource = false;
  bool _inCall = false;
  bool _resumeAfterCall = false;
  bool _disposed = false;
  bool _showLogo = true;
  bool _showInfo = true;
  bool _showVinyl = true;
  int _generation = 0;
  String _sourcePackage = '';
  String _title = '';
  String _artist = '';
  String _album = '';
  String _videoId = '';
  String _status = 'Press Play to find a matching music video';
  double _position = 0;
  double _duration = 0;
  bool _scrubbing = false;
  double _seekPreview = 0;
  DateTime _ignoreOldProgressUntil = DateTime.fromMillisecondsSinceEpoch(0);
  double? _fallbackSeekPosition;
  DateTime _fallbackSeekUntil = DateTime.fromMillisecondsSinceEpoch(0);
  String _autoAttemptedTrack = '';
  String _autoScheduledTrack = '';
  // The new YT Music MediaSession can publish its title BEFORE the queue's
  // video thumbnail/media ID becomes available. Keep verified queue IDs
  // from the same active playlist and make bounded delayed rechecks.
  final Map<String, String> _publishedQueueVideoIds = {};
  final Set<String> _ambiguousQueueTitles = {};
  Timer? _videoRetryTimer;
  String _videoRetryTrack = '';
  int _videoMisses = 0;
  // Ignore late events from a previous YouTube iframe after a track switch.
  int _embedSession = 0;
  // Retry recovery for mode switches that do not alter artist/title metadata.
  bool _recoveryProbeRunning = false;
  String _recoveryTrack = '';
  String _recoveryIdentity = '';
  DateTime _lastRecoveryProbeAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRecoveryAttemptAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sourcePackage = widget.sourcePackage;
    _title = widget.title;
    _artist = widget.artist;
    _album = widget.album;
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel('VybeVideo',
          onMessageReceived: (message) => _handleVideoEvent(message.message))
      ..setNavigationDelegate(NavigationDelegate(
        onWebResourceError: (error) {
          if (error.isForMainFrame == true && mounted && _embedded) {
            unawaited(_fallback('Video player unavailable: ' + error.description));
          }
        },
      ));
    if (_web.platform is AndroidWebViewController) {
      unawaited((_web.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false));
    }
    unawaited(_loadOverlayChoices());
    _callTimer = Timer.periodic(const Duration(milliseconds: 1100), (_) {
      unawaited(_checkCall());
      unawaited(_checkVideoRecovery());
    });
    // Entering from an already playing YouTube Music video should not
    // require a second manual tap on VYBE's Play Music Video button.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoStart());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted || _disposed ||
        _embedded || _busy || _advancing || _inCall ||
        _sourcePackage != _ytMusic) return;
    // Returning after toggling Video in YouTube Music doesn't necessarily
    // alter MediaSession title or playing state. Give the same song another
    // chance without requiring the user to skip away and back.
    _autoAttemptedTrack = '';
    _videoRetryTimer?.cancel();
    _videoMisses = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeAutoStart();
    });
  }

  @override
  void didUpdateWidget(covariant MusicVideoTheme oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Embedded WebView playback can advertise VYBE's own MediaSession.
    // Never replace the remembered original music app with that session;
    // otherwise Next accidentally stops addressing YouTube Music.
    final incomingPackage = widget.sourcePackage;
    if (incomingPackage.isNotEmpty &&
        incomingPackage != 'com.conjure.now_playing' &&
        (_sourcePackage.isEmpty || !_embedded)) {
      _sourcePackage = incomingPackage;
    }
    final sourceResumed = !oldWidget.sourcePlaying && widget.sourcePlaying;
    if (oldWidget.title != widget.title || oldWidget.artist != widget.artist) {
      // Treat a changed MediaSession track as authoritative, even when the
      // change arrived during a Next request. The old implementation ignored
      // these events while _advancing and could remain on the old player.
      final changed = _title != widget.title || _artist != widget.artist;
      if (changed) {
        ++_generation; // Cancel all in-flight lookups for the old track.
        ++_embedSession;
        _recoveryTrack = '';
        _recoveryIdentity = '';
        _autoAttemptedTrack = '';
        _autoScheduledTrack = '';
        final hadVideo = _embedded;
        _videoRetryTimer?.cancel();
        _videoRetryTrack = '';
        _videoMisses = 0;
        _busy = false;
        _advancing = false;
        _embedded = false;
        _ready = false;
        _playWhenReady = false;
        _videoPlaying = false;
        widget.onVideoPlaybackChanged(false);
        _videoId = '';
        _position = 0;
        _duration = 0;
        _scrubbing = false;
        _fallbackSeekPosition = null;
        // The next MediaSession track may already be playing externally.
        // Never force-resume the newly selected song based on stale state.
        _pausedSource = false;
        _status = '';
        if (hadVideo) {
          unawaited(_send('window.vybeStop && window.vybeStop();'));
        }
      }
      _title = widget.title;
      _artist = widget.artist;
      _album = widget.album;
    }
    // A source pause/resume may reflect a same-song switch from audio to
    // video. Re-arm the song rather than preserving its exhausted attempt.
    if (sourceResumed && !_embedded && _sourcePackage == _ytMusic) {
      _autoAttemptedTrack = '';
      _videoRetryTimer?.cancel();
      _videoMisses = 0;
      debugPrint('Music Video: source resumed; refreshing same song');
    }
    _maybeAutoStart();
  }

  // A new song receives its own attempt; status and backdrop remain clean
  // while the identity lookup runs. A missing verified video leaves the
  // existing full-screen VYBE artwork/vinyl composition in place.
  void _maybeAutoStart({bool sourceConfirmedPlaying = false}) {
    if (!mounted || _disposed || _sourcePackage != _ytMusic ||
        (!widget.sourcePlaying && !sourceConfirmedPlaying) ||
        _title.isEmpty || _artist.isEmpty ||
        _busy || _embedded || _advancing || _inCall) return;
    final key = _sourcePackage + '|' + _songKey;
    if (_autoAttemptedTrack == key || _autoScheduledTrack == key) return;
    // Scheduling is not the same as beginning the lookup: the callback
    // can be invalidated by a track change or a currently busy source.
    _autoScheduledTrack = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_autoScheduledTrack == key) _autoScheduledTrack = '';
      if (!mounted || _disposed || _embedded || _busy || _advancing ||
          _inCall || _sourcePackage != _ytMusic ||
          (!widget.sourcePlaying && !sourceConfirmedPlaying) ||
          _artist.isEmpty || _title.isEmpty ||
          key != _sourcePackage + '|' + _songKey ||
          _autoAttemptedTrack == key) return;
      _autoAttemptedTrack = key;
      _lastRecoveryAttemptAt = DateTime.now();
      unawaited(_beginVideo());
    });
  }

  /// MediaSession recheck, not an internet lookup: YouTube Music can publish
  /// a different video/queue ID without changing its displayed song title.
  /// Don't leave that track locked out after four delayed retries.
  Future<void> _checkVideoRecovery() async {
    if (!mounted || _disposed || _recoveryProbeRunning || _inCall ||
        _busy || _advancing || _embedded || _sourcePackage != _ytMusic ||
        _title.isEmpty || _artist.isEmpty) return;
    final key = _sourcePackage + '|' + _songKey;
    if (_autoAttemptedTrack != key ||
        (_videoRetryTimer?.isActive ?? false)) return;
    final now = DateTime.now();
    if (now.difference(_lastRecoveryProbeAt).inMilliseconds < 6500) return;
    _lastRecoveryProbeAt = now;
    _recoveryProbeRunning = true;
    try {
      final snapshot = await _channel.invokeMapMethod<String, dynamic>(
          'integrationDiagnostics', {'service': 'youtube_music'});
      if (!mounted || _disposed || _sourcePackage != _ytMusic ||
          _embedded || _busy || _advancing || _inCall ||
          key != _sourcePackage + '|' + _songKey ||
          snapshot == null || snapshot['sessionFound'] != true) return;
      final metadata = snapshot['metadata'];
      if (metadata is! Map || !_matchesNativeTrack(metadata)) return;
      final sourcePlaying = snapshot['playbackState'] == 3 ||
          widget.sourcePlaying;
      if (!sourcePlaying) return;
      final probe = snapshot['videoProbe'];
      final hints = probe is Map ? probe : const <String, dynamic>{};
      // Never use position/time in this identity: those change each tick.
      final identity = [
        snapshot['activeQueueItemId'], metadata['mediaId'],
        metadata['artUri'], metadata['displayIconUri'],
        hints['activeQueueVideoId'], hints['activeMediaId'],
        hints['activeMediaUri'],
      ].map((value) => value?.toString() ?? '').join('|');
      if (_recoveryTrack != key) {
        _recoveryTrack = key;
        _recoveryIdentity = identity;
      }
      final changed = identity != _recoveryIdentity;
      final cooledDown = now.difference(_lastRecoveryAttemptAt).inSeconds >= 30;
      if (!changed && !cooledDown) return;
      _recoveryIdentity = identity;
      _videoRetryTimer?.cancel();
      _videoMisses = 0;
      _autoAttemptedTrack = '';
      debugPrint('Music Video: retry same song because ' +
          (changed ? 'MediaSession identity changed' : 'recovery cooldown elapsed'));
      _maybeAutoStart(sourceConfirmedPlaying: true);
    } catch (error) {
      debugPrint('Music Video: background recovery probe failed: $error');
    } finally {
      _recoveryProbeRunning = false;
    }
  }

  String get _songKey =>
      'vybe_music_video_id|' + _artist.trim().toLowerCase() + '|' +
      _title.trim().toLowerCase();

  Future<void> _loadOverlayChoices() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _showLogo = prefs.getBool('musicVideoShowLogo') ?? true;
      _showInfo = prefs.getBool('musicVideoShowInfo') ?? true;
      _showVinyl = prefs.getBool('musicVideoShowVinyl') ?? true;
    });
  }

  Future<void> _toggleOverlay(String name) async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      if (name == 'logo') _showLogo = !_showLogo;
      if (name == 'info') _showInfo = !_showInfo;
      if (name == 'vinyl') _showVinyl = !_showVinyl;
    });
    await prefs.setBool('musicVideoShowLogo', _showLogo);
    await prefs.setBool('musicVideoShowInfo', _showInfo);
    await prefs.setBool('musicVideoShowVinyl', _showVinyl);
  }

  static String _normalize(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// The shared VYBE model repairs upload-style YT Music metadata such as
  /// "Fat Joe - Watch The Sound" to artist="Fat Joe", title="Watch The
  /// Sound". The native MediaSession still publishes the ORIGINAL title.
  /// Both must resolve to the same song before we take over its audio/video.
  bool _matchesNativeTrack(Map raw) {
    final rawTitle = raw['title']?.toString().trim() ?? '';
    final rawArtist = raw['artist']?.toString().trim() ?? '';
    final rawAlbum = raw['album']?.toString().trim() ?? '';
    if (rawTitle.isEmpty || _title.isEmpty) return false;
    final parsed = StreamTrackMetadata.resolve(
      title: rawTitle,
      artist: rawArtist,
      album: rawAlbum,
      sourcePackage: _ytMusic,
    );
    final displayedTitle = _normalize(_title);
    final displayedArtist = _normalize(_artist);
    if (_normalize(parsed.title) == displayedTitle &&
        (displayedArtist.isEmpty || _normalize(parsed.artist) == displayedArtist ||
         rawArtist.isEmpty)) return true;
    // A real catalog track can have upload-specific artist metadata while
    // preserving the same exact track title in both Android and VYBE.
    return _normalize(rawTitle) == displayedTitle;
  }

  String _queueSongKey(String title, String artist) {
    final parsed = StreamTrackMetadata.resolve(
      title: title,
      artist: artist,
      album: '',
      sourcePackage: _ytMusic,
    );
    return _normalize(parsed.title);
  }

  static String _validId(Object? candidate) {
    final value = candidate?.toString().trim() ?? '';
    return RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(value) ? value : '';
  }

  static String _idFromUri(Object? raw) {
    final uri = Uri.tryParse(raw?.toString() ?? '');
    if (uri == null) return '';
    final host = uri.host.toLowerCase();
    final path = uri.pathSegments;
    if ((host == 'i.ytimg.com' || host == 'img.youtube.com') &&
        path.length >= 2 && (path[0] == 'vi' || path[0] == 'vi_webp')) {
      return _validId(path[1]);
    }
    if (host == 'youtu.be' && path.isNotEmpty) {
      return _validId(path.first);
    }
    if (host == 'youtube.com' || host == 'www.youtube.com' ||
        host == 'music.youtube.com' || host == 'm.youtube.com') {
      if (path.length >= 2 && path.first == 'embed') {
        return _validId(path[1]);
      }
      if (path.length >= 2 && path.first == 'shorts') {
        return _validId(path[1]);
      }
      return _validId(uri.queryParameters['v']);
    }
    return '';
  }

  void _rememberPublishedYoutubeQueue(Map<dynamic, dynamic> snapshot) {
    if (snapshot['package'] != _ytMusic || snapshot['sessionFound'] != true) {
      return;
    }
    final queue = snapshot['queue'];
    if (queue is! List) return;
    for (final item in queue) {
      if (item is! Map) continue;
      final rawName = _normalize(item['title']?.toString() ?? '');
      final correctedName = _queueSongKey(
        item['title']?.toString() ?? '',
        item['subtitle']?.toString() ?? '',
      );
      // Thumbnail is stronger evidence for a VIDEO than MediaSession mediaId,
      // which can identify a separate audio-only recording. Do NOT mark a
      // track ambiguous just because those two identifiers differ.
      final thumb = _validId(item['youtubeThumbnailVideoId']).isNotEmpty
          ? _validId(item['youtubeThumbnailVideoId'])
          : _idFromUri(item['artworkUri']);
      final id = thumb.isNotEmpty ? thumb :
          (_validId(item['mediaId']).isNotEmpty
              ? _validId(item['mediaId'])
              : _idFromUri(item['mediaUri']));
      if (id.isEmpty) continue;
      for (final name in {rawName, correctedName}) {
        if (name.isEmpty || _ambiguousQueueTitles.contains(name)) continue;
        final previous = _publishedQueueVideoIds[name];
        if (previous != null && previous != id) {
          // Different QUEUE ENTRIES with the same displayed title are not
          // interchangeable. Do not guess one video over another.
          _publishedQueueVideoIds.remove(name);
          _ambiguousQueueTitles.add(name);
        } else {
          _publishedQueueVideoIds[name] = id;
        }
      }
    }
  }

  String _verifiedYoutubeMusicId(Map<dynamic, dynamic> snapshot) {
    final meta = snapshot['metadata'];
    if (meta is! Map || !_matchesNativeTrack(meta)) {
      if (meta is Map) {
        debugPrint('Music Video: YTM raw title does not match displayed '
            'track: "${meta['title']}" vs "$_title"');
      }
      return '';
    }
    _rememberPublishedYoutubeQueue(snapshot);
    final currentTitle = _normalize(_title);
    // The active queue ID is tied to PlaybackState.activeQueueItemId:
    // it belongs to the currently playing track, even if descriptionTitle
    // is empty or differs from MediaMetadata's display title.
    final probe = snapshot['videoProbe'];
    if (probe is Map) {
      final activeId = _validId(probe['activeQueueVideoId']);
      if (activeId.isNotEmpty) return activeId;
    }
    final fromQueue = _ambiguousQueueTitles.contains(currentTitle)
        ? null : _publishedQueueVideoIds[currentTitle];
    if (fromQueue != null && fromQueue.isNotEmpty) return fromQueue;
    for (final candidate in [
      meta['mediaId'],
      _idFromUri(meta['artUri']),
      _idFromUri(meta['albumArtUri']),
      _idFromUri(meta['displayIconUri']),
    ]) {
      final id = _validId(candidate);
      if (id.isNotEmpty) return id;
    }
    if (probe is Map &&
        (_normalize(probe['descriptionTitle']?.toString() ?? '') ==
            currentTitle ||
         _queueSongKey(probe['descriptionTitle']?.toString() ?? '',
              probe['descriptionSubtitle']?.toString() ?? '') ==
            currentTitle)) {
      for (final candidate in [
        probe['activeMediaId'],
        _idFromUri(probe['activeMediaUri']),
      ]) {
        final id = _validId(candidate);
        if (id.isNotEmpty) return id;
      }
    }
    return '';
  }

  Future<String> _findVideo() async {
    if (_title.isEmpty || _artist.isEmpty) return '';
    final song = _songKey;
    final prefs = await SharedPreferences.getInstance();
    // Start with known, previous-queue IDs when the source just skipped.
    // The next song's notification metadata is sometimes published ahead
    // of its queue artwork, leading to a false permanent "no video" result.
    if (_sourcePackage == _ytMusic) {
      final queueTitle = _normalize(_title);
      for (var scan = 0; scan < 4; scan++) {
        if (!mounted || _disposed || _songKey != song ||
            _sourcePackage != _ytMusic) return '';
        try {
          final snapshot = await _channel.invokeMapMethod<String, dynamic>(
              'integrationDiagnostics', {'service': 'youtube_music'});
          if (snapshot != null && snapshot['sessionFound'] == true) {
            // This collects the active playlist's exact published IDs even
            // if the new MediaMetadata title has not caught up yet.
            _rememberPublishedYoutubeQueue(snapshot);
            final id = _verifiedYoutubeMusicId(snapshot);
            if (id.isNotEmpty) {
              await prefs.setString(song, id);
              return id;
            }
            final fromQueue = _ambiguousQueueTitles.contains(queueTitle)
                ? null : _publishedQueueVideoIds[queueTitle];
            if (fromQueue != null && fromQueue.isNotEmpty) return fromQueue;
          }
        } catch (error) {
          debugPrint('Music Video: YTM session probe failed: $error');
        }
        if (scan < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 525));
        }
      }
      final saved = _validId(prefs.getString(song));
      if (saved.isNotEmpty) return saved;
      debugPrint('Music Video: YTM published no usable video ID for $_artist — $_title');
      return '';
    }

    final saved = _validId(prefs.getString(song));
    if (saved.isNotEmpty) return saved;
    final related = await _musicBrainzVideoId();
    if (related.isNotEmpty) await prefs.setString(song, related);
    return related;
  }

  /// Optional exact recording-to-video relationship fallback for Spotify
  /// and local players; no automated YouTube search-result guessing.
  Future<String> _musicBrainzVideoId() async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      Future<Map<String, dynamic>?> fetch(Uri uri) async {
        final req = await client!.getUrl(uri).timeout(const Duration(seconds: 7));
        req.headers.set(HttpHeaders.userAgentHeader, 'VYBE/1.9 (Music Video metadata)');
        final response = await req.close().timeout(const Duration(seconds: 7));
        if (response.statusCode != 200) return null;
        final decoded = jsonDecode(await utf8.decoder.bind(response)
            .join().timeout(const Duration(seconds: 7)));
        return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
      }
      final title = _title.replaceAll('"', '').trim();
      final artist = _artist.replaceAll('"', '').trim();
      if (title.isEmpty || artist.isEmpty) return '';
      final search = await fetch(Uri.https('musicbrainz.org',
          '/ws/2/recording/', {'query': 'recording:"' + title +
          '" AND artist:"' + artist + '"', 'fmt': 'json', 'limit': '5'}));
      final recs = search?['recordings'];
      if (recs is! List) return '';
      final ids = <String>[];
      for (final entry in recs) {
        if (entry is! Map ||
            _normalize(entry['title']?.toString() ?? '') != _normalize(title)) continue;
        final credits = entry['artist-credit'];
        if (credits is! List || !credits.whereType<Map>().any((credit) =>
            credit['artist'] is Map &&
            _normalize(credit['artist']['name']?.toString() ?? '') ==
                _normalize(artist))) continue;
        final id = entry['id']?.toString() ?? '';
        if (RegExp(r'^[0-9a-f-]{36}$').hasMatch(id)) ids.add(id);
        if (ids.length >= 2) break;
      }
      final results = <String>{};
      for (final id in ids) {
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        final recording = await fetch(Uri.https('musicbrainz.org',
            '/ws/2/recording/' + id, {'inc': 'url-rels', 'fmt': 'json'}));
        final links = recording?['relations'];
        if (links is! List) continue;
        for (final relation in links) {
          if (relation is! Map ||
              (relation['type'] != 'free streaming' &&
               relation['type'] != 'streaming')) continue;
          final attributes = relation['attributes'], url = relation['url'];
          if (attributes is! List || !attributes.contains('video') || url is! Map) continue;
          final id = _idFromUri(url['resource']);
          if (id.isNotEmpty) results.add(id);
        }
      }
      return results.length == 1 ? results.single : '';
    } catch (_) { return ''; }
    finally { client?.close(force: true); }
  }

  Future<void> _openSourcePlayer() async {
    if (_sourcePackage.isEmpty) {
      // The model has no identified original music app. Never launch an
      // unrelated global MediaSession (which may belong to the WebView).
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('The source music app is not available'),
      ));
      return;
    }
    String response;
    try {
      response = await _channel.invokeMethod<String>(
        'musicVideoOpenSource', {'package': _sourcePackage}) ??
          'Could not open the music app';
    } catch (_) {
      response = 'Could not open the music app';
    }
    if (!mounted || response == 'ok') return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(response),
        duration: const Duration(seconds: 3)),
    );
  }

  Future<Map<dynamic, dynamic>?> _sourceSnapshot() async {
    if (_sourcePackage.isEmpty) return null;
    try {
      return await _channel.invokeMapMethod<dynamic, dynamic>(
          'musicVideoSourceSnapshot', {'package': _sourcePackage});
    } catch (_) {
      return null;
    }
  }

  Future<Map<dynamic, dynamic>?> _sourceCommand(
      String action, String expectedTitle) async {
    if (_sourcePackage.isEmpty) return null;
    var nativeTitle = expectedTitle;
    if (action == 'pause' || action == 'resume') {
      // Flutter displays repaired upload titles but Android requires the
      // exact original MediaSession title. Resolve and verify it FIRST,
      // then send that raw title to the native stale-song safety check.
      final snapshot = await _sourceSnapshot();
      if (snapshot == null || snapshot['found'] != true ||
          !_matchesNativeTrack(snapshot)) {
        return {'sent': false, 'reason':
            'YouTube Music source track is still updating'};
      }
      nativeTitle = snapshot['title']?.toString() ?? expectedTitle;
    }
    try {
      return await _channel.invokeMapMethod<dynamic, dynamic>(
          'musicVideoSourceControl', {
        'package': _sourcePackage,
        'action': action,
        'expectedTitle': nativeTitle,
      });
    } catch (_) {
      return null;
    }
  }

  Future<bool> _pauseSource() async {
    final result = await _sourceCommand('pause', _title);
    final confirmed = result?['paused'] == true || result?['alreadyPaused'] == true;
    if (result?['paused'] == true) _pausedSource = true;
    if (!confirmed && mounted) {
      setState(() => _status = result?['reason']?.toString() ??
          'Could not pause the source player safely');
    }
    return confirmed;
  }

  Future<void> _resumeSource() async {
    if (!_pausedSource) return;
    _pausedSource = false;
    await _sourceCommand('resume', _title);
  }

  Future<void> _send(String script) async {
    try {
      await _web.runJavaScript(script);
    } catch (_) {}
  }

  String _iframe(String id, int embedSession) => '''
<!doctype html><html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<meta name="referrer" content="strict-origin-when-cross-origin">
<style>
html,body{padding:0;margin:0;position:fixed;inset:0;width:100%;height:100%;
overflow:hidden;overscroll-behavior:none;background:#000}
#player{position:absolute;inset:0;width:100%;height:100%;overflow:hidden}
</style>
</head><body><div id="player"></div><script>
var vybePlayer=null;
var vybeStopping=false;
function vybeEvent(event,detail) {
 try { window.VybeVideo.postMessage(JSON.stringify({event:event,detail:String(detail),embedSession:$embedSession})); } catch(e){}
}
window.vybePlay=function(){if(vybePlayer)vybePlayer.playVideo();};
window.vybePause=function(){if(vybePlayer)vybePlayer.pauseVideo();};
window.vybeStop=function(){vybeStopping=true;if(vybePlayer)vybePlayer.stopVideo();};
window.vybeSeek=function(seconds){
 if(vybePlayer && typeof vybePlayer.seekTo==='function'){
   vybePlayer.seekTo(Math.max(0,seconds),true);
 }
};
function onYouTubeIframeAPIReady() {
 try {
  vybePlayer=new YT.Player('player',{
   width:'100%',height:'100%',videoId:'$id',
   playerVars:{autoplay:0,controls:0,playsinline:1,rel:0,
    cc_load_policy:0,iv_load_policy:3,disablekb:1,
    enablejsapi:1,origin:'$_origin'},
   events:{
    onReady:function(){vybeEvent('ready','ok');},
    onStateChange:function(e){
     // Explicitly stopping a prior video must not advance the playlist.
     if(vybeStopping)return;
     var s={'-1':'Unstarted','0':'Ended','1':'Playing','2':'Paused','3':'Buffering','5':'Cued'};
     vybeEvent('state',s[e.data]||'Unknown');
    },
    onError:function(e){vybeEvent('error',e.data);},
    onAutoplayBlocked:function(){vybeEvent('error','Autoplay blocked');}
   }
  });
 }catch(e){vybeEvent('error',e.message);}
}
setInterval(function(){
 if(!vybePlayer||!vybePlayer.getCurrentTime)return;
 try {vybeEvent('progress',vybePlayer.getCurrentTime()+','+vybePlayer.getDuration());}catch(e){}
},850);
var tag=document.createElement('script');tag.src='https://www.youtube.com/iframe_api';
tag.onerror=function(){vybeEvent('error','Player API unavailable');};
document.head.appendChild(tag);
</script></body></html>
''';

  Future<void> _loadVideo(String id) async {
    if (!mounted) return;
    final session = ++_embedSession;
    widget.onVideoPlaybackChanged(false);
    setState(() {
      _videoId = id;
      _embedded = true;
      _ready = false;
      _playWhenReady = true;
      _videoPlaying = false;
      _position = 0;
      _duration = 0;
      _scrubbing = false;
      _seekPreview = 0;
      _status = 'Loading verified music video…';
    });
    try {
      await _web.loadHtmlString(_iframe(id, session), baseUrl: '$_origin/');
    } catch (error) {
      if (mounted && session == _embedSession) {
        await _fallback('Could not open embedded video: ' + error.toString());
      }
    }
  }

  // Missing IDs and late permission to pause the original music player
  // both require bounded retries after playlist transitions.
  void _retryUnmatchedYoutubeMusicVideo(String reason) {
    if (_sourcePackage != _ytMusic || !mounted || _disposed || _inCall) return;
    final key = _songKey;
    if (_videoRetryTrack != key) {
      _videoRetryTrack = key;
      _videoMisses = 0;
    }
    const delays = [1500, 2700, 4500, 6500];
    if (_videoMisses >= delays.length) {
      debugPrint('Music Video: retry limit reached for $reason');
      return;
    }
    final attempt = ++_videoMisses;
    _videoRetryTimer?.cancel();
    debugPrint('Music Video: retry $attempt after $reason');
    _videoRetryTimer = Timer(
      Duration(milliseconds: delays[attempt - 1]), () {
      if (!mounted || _disposed || _songKey != key || _embedded ||
          _busy || _advancing || _inCall || _sourcePackage != _ytMusic) return;
      unawaited(_retryCurrentVideoWhenPlaying(key));
    });
  }

  Future<void> _retryCurrentVideoWhenPlaying(String key) async {
    if (widget.sourcePlaying) {
      await _beginVideo();
      return;
    }
    // Aggregated media playback can momentarily be stale. Inspect the
    // original source session rather than permanently aborting the retry.
    final source = await _sourceSnapshot();
    if (!mounted || _disposed || _songKey != key || _busy ||
        _embedded || _advancing || _inCall) return;
    if (source != null && source['found'] == true &&
        source['playing'] == true && _matchesNativeTrack(source)) {
      await _beginVideo();
    }
  }

  Future<void> _beginVideo() async {
    if (_busy || _advancing || _inCall || _title.isEmpty || _artist.isEmpty) return;
    if (_embedded && _ready) {
      if (await _pauseSource()) {
        await _send('window.vybePlay && window.vybePlay();');
      }
      return;
    }
    final token = ++_generation;
    setState(() {
      _busy = true;
      _status = 'Finding a verified music video for this song…';
    });
    final id = await _findVideo();
    if (!mounted || token != _generation) return;
    if (id.isEmpty) {
      setState(() {
        _busy = false;
        _status = '';
      });
      // After video-driven Skip Next, the source may still be muted.
      // Fallback must always restore the original music app's audio.
      await _resumeSource();
      _retryUnmatchedYoutubeMusicVideo('video ID pending');
      return;
    }
    // A valid video ID is not a completed handoff. The source pause
    // can reject temporarily while its media session is changing tracks.
    if (!await _pauseSource()) {
      if (mounted && token == _generation) {
        setState(() {
          _busy = false;
          _status = '';
        });
        _retryUnmatchedYoutubeMusicVideo('source pause pending');
      }
      return;
    }
    if (!mounted || token != _generation) return;
    _videoRetryTimer?.cancel();
    setState(() => _busy = false);
    await _loadVideo(id);
  }

  Future<void> _fallback(String reason) async {
    if (!mounted) return;
    final token = ++_generation;
    ++_embedSession;
    _playWhenReady = false;
    _videoPlaying = false;
    widget.onVideoPlaybackChanged(false);
    await _send('window.vybeStop && window.vybeStop();');
    if (!mounted || token != _generation) return;
    setState(() {
      _embedded = false;
      _ready = false;
      _status = reason;
    });
    await _resumeSource();
  }

  void _handleVideoEvent(String raw) {
    if (!mounted || !_embedded) return;
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['embedSession'] != _embedSession) return;
      final type = value['event']?.toString() ?? '';
      final detail = value['detail']?.toString() ?? '';
      if (type == 'ready') {
        _ready = true;
        if (_playWhenReady && !_inCall) {
          _playWhenReady = false;
          unawaited(_send('window.vybePlay && window.vybePlay();'));
        }
      } else if (type == 'state') {
        if (detail == 'Playing') {
          if (_inCall) {
            unawaited(_send('window.vybePause && window.vybePause();'));
          } else {
            _videoPlaying = true;
            widget.onVideoPlaybackChanged(true);
            unawaited(_pauseSource());
          }
        } else {
          _videoPlaying = false;
          widget.onVideoPlaybackChanged(false);
          if (detail == 'Ended' && !_advancing) unawaited(_advance());
        }
        setState(() => _status = detail == 'Playing'
            ? 'Music video playing' : 'Video: ' + detail);
      } else if (type == 'progress') {
        final parts = detail.split(',');
        if (parts.length == 2) {
          final current = double.tryParse(parts[0]);
          final total = double.tryParse(parts[1]);
          setState(() {
            if (total != null && total.isFinite && total > 0) _duration = total;
            // Do not let late WebView progress overwrite the user's drag.
            if (!_scrubbing &&
                DateTime.now().isAfter(_ignoreOldProgressUntil) &&
                current != null && current.isFinite) {
              _position = current;
            }
          });
        }
      } else if (type == 'error') {
        final message = detail == '101' || detail == '150'
            ? 'This video does not allow embedding — using VYBE artwork'
            : 'YouTube video unavailable (' + detail + ')';
        unawaited(_fallback(message));
      }
    } catch (_) {}
  }

  /// Send a skip only to the ORIGINAL music app. Show the artwork fallback
  /// immediately and observe the next MediaSession song in parallel instead
  /// of holding the previous WebView and a "looking up" screen for seconds.
  Future<void> _advance({bool previous = false}) async {
    // User-initiated skip takes priority even while an async video lookup
    // is in progress. Bump _generation to invalidate that stale lookup.
    if (_advancing || _inCall || _sourcePackage.isEmpty) return;
    final previousTitle = _title;
    final token = ++_generation;
    setState(() {
      _advancing = true;
      _status = '';
    });
    // Restore the handoff order used before #847: relinquish embedded
    // video/audio playback BEFORE starting the next source-app track.
    // Previously dispatching Skip while the iframe still played could
    // race YouTube Music's audio focus and next-song metadata.
    final oldVideoId = _videoId;
    final oldVideoPlaying = _embedded && _videoPlaying;
    ++_embedSession; // Suppress old iframe callbacks during skip.
    await _send('window.vybeStop && window.vybeStop();');
    widget.onVideoPlaybackChanged(false);
    if (!mounted || token != _generation) return;
    final response = await _sourceCommand(
        previous ? 'previous' : 'next', previousTitle);
    if (!mounted || token != _generation) return;
    if (response?['sent'] != true) {
      setState(() {
        _advancing = false;
        _status = '';
      });
      // A rejected skip should not permanently stop the existing video.
      if (oldVideoPlaying && oldVideoId.isNotEmpty && _embedded) {
        await _loadVideo(oldVideoId);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(response?['reason']?.toString() ??
              'The music player did not accept the track change'),
          duration: const Duration(seconds: 3),
        ));
      }
      return;
    }
    if (!mounted || token != _generation) return;
    setState(() {
      _advancing = false;
      _busy = false;
      _embedded = false;
      _ready = false;
      _playWhenReady = false;
      _videoPlaying = false;
      _videoId = '';
      _position = 0;
      _duration = 0;
      _status = '';
    });
    // Source Skip Next commonly starts YouTube Music video playback
    // externally. That new playing song becomes our source to match/pause.
    _pausedSource = false;
    unawaited(_observeSkippedSong(previousTitle, token));
  }

  Future<void> _observeSkippedSong(String previousTitle, int token) async {
    for (var attempt = 0; attempt < 13; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted || _disposed || token != _generation || _inCall) return;
      final snapshot = await _sourceSnapshot();
      final title = snapshot?['title']?.toString().trim() ?? '';
      if (title.isEmpty || _normalize(title) == _normalize(previousTitle)) {
        continue;
      }
      final nextArtist = snapshot?['artist']?.toString() ?? '';
      final nextAlbum = snapshot?['album']?.toString() ?? '';
      if (nextArtist.trim().isEmpty) return;
      // The native player may still report the RAW upload title, while
      // the Flutter UI already has corrected artist/song metadata.
      final parsed = StreamTrackMetadata.resolve(
        title: title, artist: nextArtist, album: nextAlbum,
        sourcePackage: _sourcePackage,
      );
      if (_normalize(parsed.title) == _normalize(previousTitle) ||
          _normalize(title) == _normalize(previousTitle)) continue;
      if (_title != parsed.title || _artist != parsed.artist) {
        _autoAttemptedTrack = '';
        _autoScheduledTrack = '';
        setState(() {
          _title = parsed.title;
          _artist = parsed.artist;
          _album = parsed.album;
          _status = '';
        });
      }
      if (snapshot?['playing'] == true) {
        _maybeAutoStart(sourceConfirmedPlaying: true);
      }
      return;
    }
    // No confirmed next track: artwork still remains visible and controls
    // still address the source app. Never leave an indefinite waiting label.
  }

  Future<void> _checkCall() async {
    try {
      final state = await _channel.invokeMapMethod<String, dynamic>(
          'musicVideoCallState');
      if (!mounted || state == null) return;
      final active = state['inCall'] == true;
      if (active == _inCall) return;
      _inCall = active;
      if (active) {
        _resumeAfterCall = _videoPlaying || _playWhenReady;
        _playWhenReady = false;
        await _send('window.vybePause && window.vybePause();');
      } else if (_resumeAfterCall && _embedded) {
        _resumeAfterCall = false;
        if (await _pauseSource()) {
          await _send('window.vybePlay && window.vybePlay();');
        }
      }
    } catch (_) {}
  }

  /// Seek the video that is actually playing in VYBE's YouTube iframe.
  /// The original YouTube Music MediaSession remains paused while embedded
  /// playback owns the audio; seeking it would affect the wrong player.
  Future<void> _seekVideo(double seconds) async {
    if (!_embedded || !_ready || _duration <= 0 || _inCall) return;
    final target = seconds.clamp(0.0, _duration).toDouble();
    setState(() {
      _scrubbing = false;
      _position = target;
      _seekPreview = target;
      _ignoreOldProgressUntil =
          DateTime.now().add(const Duration(milliseconds: 1100));
    });
    await _send('window.vybeSeek && window.vybeSeek(' +
        target.toStringAsFixed(3) + ');');
  }

  /// The same mockup slider also seeks source audio when no verified video
  /// exists, instead of becoming a decorative, dead control.
  Future<void> _seekPlayback(double seconds) async {
    if (_embedded) {
      await _seekVideo(seconds);
      return;
    }
    if (widget.sourceDurationMs <= 0 || _inCall) return;
    final target = seconds.clamp(
        0.0, widget.sourceDurationMs / 1000.0).toDouble();
    setState(() {
      _scrubbing = false;
      _seekPreview = target;
      _fallbackSeekPosition = target;
      _fallbackSeekUntil = DateTime.now().add(
          const Duration(milliseconds: 1500));
    });
    await widget.onSeekSource((target * 1000).round());
  }

  Future<void> _togglePlay() async {
    if (!_embedded) {
      await widget.onSourcePlayPause();
      return;
    }
    if (_embedded && _videoPlaying) {
      await _send('window.vybePause && window.vybePause();');
      widget.onVideoPlaybackChanged(false);
      if (mounted) setState(() => _videoPlaying = false);
    } else {
      await _beginVideo();
    }
  }

  Future<void> _linkVideo() async {
    final input = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1822),
        title: const Text('Link a music video'),
        content: TextField(
          controller: input, autofocus: true, autocorrect: false,
          decoration: const InputDecoration(
            hintText: 'YouTube link or 11-character video ID',
            helperText: 'Saves the link for this artist and song',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, input.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    input.dispose();
    if (!mounted || raw == null) return;
    final id = _validId(raw).isNotEmpty ? _validId(raw) : _idFromUri(raw);
    if (id.isEmpty) {
      setState(() => _status = 'Invalid YouTube video link');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_songKey, id);
    if (mounted) {
      // A replacement link must replace the current iframe, not resume it.
      if (_embedded) {
        ++_embedSession;
        await _send('window.vybeStop && window.vybeStop();');
        if (mounted) setState(() {
          _embedded = false;
          _ready = false;
          _videoPlaying = false;
        });
      }
      if (!mounted) return;
      setState(() => _status = 'Video link saved for this song');
      await _beginVideo();
    }
  }

  static String _clock(double seconds) {
    final time = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
    return (time ~/ 60).toString() + ':' + (time % 60).toString().padLeft(2, '0');
  }

  /// Only construct the backdrop when the embedded video is not present.
  /// Its filters, motion, and source selection remain live in Customize.
  Widget _videoBackdrop() => widget.buildFallbackBackground();

  Widget _ringTransport(IconData icon, VoidCallback? onTap,
      double diameter, String tooltip) {
    return Tooltip(message: tooltip, child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(width: diameter, height: diameter,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0x30050D10),
            border: Border.all(color: widget.accent.withOpacity(.92),
                width: 1.2),
          ),
          child: Center(child: Icon(icon, color: Colors.white,
              size: diameter * .58)),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, bounds) {
      final w = bounds.maxWidth, h = bounds.maxHeight;
      final portrait = h > w * 1.1;
      // Fade to truly opaque black at both edges, but ease the alpha
      // gradually to zero so neither transition leaves a horizontal seam.
      final topFadeHeight = h * (portrait ? .265 : .205);
      // Only portrait changes the placement; landscape sleeve stays anchored.
      final discRatio = .72;
      // Portrait album cover now acts as a full-width lower image backplate.
      // Keep the OLD compact cover measurement solely to preserve the
      // existing song/album metadata vertical position.
      final compactPortraitArtSide = math.min(w * .38, h * .24);
      final artSide = portrait ? w * .94 : w * .285;
      final discSide = artSide * discRatio;
      final transportWidth = portrait ? math.min(w * .86, 560.0) : w * .52;
      final transportRight = portrait ? (w - transportWidth) * .5 : w * .032;
      final transportBottom = portrait ? h * .035 : h * .038;
      final transportHeight = portrait ? 68.0 :
          (h * .084).clamp(62.0, 76.0).toDouble();
      final transportTop = h - transportBottom - transportHeight;
      final iconSize = portrait ? 44.0 :
          (h * .061).clamp(40.0, 55.0).toDouble();
      final iconGap = portrait ? 9.0 : w * .015;
      // Song/album stay TOP RIGHT in landscape. Only the available text
      // width increases leftwards so long names may occupy half the screen.
      final infoWidth = portrait ? w * .90 : w * .54;
      final infoLeft = portrait ? (w - infoWidth) * .5
          : w - w * .031 - infoWidth;
      // Short landscape titles should sit directly over the center of the
      // right-anchored album plaque, whose minimum width is 78% of the panel.
      // Long titles keep the entire 54%-screen marquee width unchanged.
      bool shortLandscapeTitle = false;
      if (!portrait) {
        final titleMeasure = TextPainter(
          text: TextSpan(text: widget.title,
            style: TextStyle(fontSize: h * .050)),
          textDirection: Directionality.of(context),
          maxLines: 1,
        )..layout();
        shortLandscapeTitle = titleMeasure.width < infoWidth * .76;
        titleMeasure.dispose();
      }
      final songHeight = portrait
          ? (h * .058).clamp(54.0, 94.0).toDouble()
          : (h * .070).clamp(27.0, 56.0).toDouble();
      final albumHeight = portrait
          ? (h * .049).clamp(46.0, 78.0).toDouble()
          : (h * .055).clamp(24.0, 44.0).toDouble();
      final infoGap = portrait ? 7.0 : 3.0;
      final infoHeight = songHeight + infoGap + albumHeight;
      final artGap = portrait ? 18.0 : 6.0;
      final footerGap = portrait ? 18.0 : 7.0;
      final artLeft = portrait ? (w - artSide) * .5 : w * .013;
      // Preserve the existing portrait song title and album-label layout.
      // Only the cover moves DOWN behind them, its top stroke just above
      // the first metadata line; the cover's bottom extends off-screen.
      final songTop = portrait
          ? math.max(h * .48,
              transportTop - infoHeight - footerGap - artGap -
                  compactPortraitArtSide) + compactPortraitArtSide + artGap
          : h * .747 + artSide + artGap;
      final artTop = portrait ? songTop - h * .021 : h * .747;
      // Center of the real spinning record is at the sleeve's right edge.
      final discLeft = artLeft + artSide - discSide * .5;
      final discTop = artTop + artSide * .075;
      // At 200%, artist logos can use the whole generously sized header.
      // The shared renderer still applies its existing 50–200% scale.
      // Source-matched cover during audio-only fallback, catalog cover
      // only while an actual music video is displayed.
      final sleeveArtwork = _embedded
          ? (widget.artwork ?? widget.fallbackArtwork)
          : (widget.fallbackArtwork ?? widget.artwork);
      final logoScale = widget.artistLogoScale.clamp(.5, 2.0).toDouble();
      final logoWidth = portrait
          ? w * (.70 + .10 * logoScale)
          // LANDSCAPE ANCHOR UNCHANGED: expands rightward to reach the
          // sleeve/half exposed record at a 200% size selection.
          : w * (.185 + (.205 / 1.5) * (logoScale - .5));
      final logoHeight = portrait
          ? h * (.145 + .018 * logoScale) : h * .29;
      final logoLeft = portrait ? (w - logoWidth) * .5 : w * .024;
      final logoTop = portrait ? h * .026 : h * .045;
      // Only the region BELOW the bottom edge of the progress bar is
      // solid black. Above it the shadow slowly dissolves into the video
      // by the top of the record (landscape) / album (portrait).
      // This changes the fade, NOT the position of any landscape control.
      final progressTrackThickness = portrait ? 5.0 : 8.0;
      final progressBottomY = h - transportBottom - transportHeight * .5 +
          progressTrackThickness * .5;
      final bottomFadeStart = portrait ? artTop : discTop;
      final bottomFadeEnd = math.max(
          bottomFadeStart + 1.0, progressBottomY).clamp(0.0, h).toDouble();
      final bottomFadeHeight = bottomFadeEnd - bottomFadeStart;
      // The existing bottom gradient is painted UNDER the album sleeve.
      // Portrait's enlarged sleeve covers it. Add a separate inexpensive
      // alpha gradient ON the image so the track and buttons remain readable
      // without moving them or altering landscape.
      final portraitCoverFadeHeight = portrait
          ? math.max(1.0, math.min(artSide, progressBottomY - artTop))
          : 0.0;
      final duration = _embedded ? _duration
          : widget.sourceDurationMs / 1000.0;
      final position = _embedded ? _position
          : (_fallbackSeekPosition != null &&
             DateTime.now().isBefore(_fallbackSeekUntil)
              ? _fallbackSeekPosition!
              : widget.sourcePositionMs / 1000.0);
      final canSeek = !_inCall && (_embedded
          ? _ready && _duration > 0 : widget.sourceDurationMs > 0);
      final isPlaying = _embedded ? _videoPlaying : widget.sourcePlaying;

      return ClipRect(child: Stack(fit: StackFit.expand, children: [
        // Keep existing artist imagery as a safe fallback while a verified
        // video is not available. Never display an empty, black-only theme.
        if (!_embedded) _videoBackdrop()
        else const ColoredBox(color: Colors.black),
        if (_embedded)
          Positioned.fill(child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.center,
              minWidth: 0, minHeight: 0,
              maxWidth: double.infinity, maxHeight: double.infinity,
              child: SizedBox(
                // Enlarge to 16:9 and crop overflow; never letterbox the
                // full-screen reference inside a centered small rectangle.
                width: math.max(w, h * (16 / 9)),
                height: math.max(h, w * (9 / 16)),
                // A raw pointer listener observes touches without winning
                // the WebView's gesture arena. The previous full-screen
                // opaque GestureDetector swallowed taps needed by YouTube.
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (_) => widget.onToggleUtilityMenu(),
                  child: WebViewWidget(controller: _web),
                ),
              ),
            ),
          )),
        // Customize Darkness affects artwork/fanart/animated fallback only;
        // video itself stays full brightness by default.
        if (!_embedded && widget.backgroundDarkness > .001)
          Positioned.fill(child: IgnorePointer(child: ColoredBox(
            color: Colors.black.withOpacity(
              widget.backgroundDarkness.clamp(0.0, 1.0))))),
        // The top begins SOLID BLACK and feathers through a long low-alpha
        // tail; the previous 17% fade showed a clear horizontal stop line.
        Positioned(left: 0, right: 0, top: 0,
          height: topFadeHeight,
          child: const IgnorePointer(child: DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0, .10, .27, .43, .63, .80, .93, 1],
              colors: [
                Color(0xFF000000), Color(0xFF000000),
                Color(0xF6000000), Color(0xDC000000),
                Color(0x90000000), Color(0x38000000),
                Color(0x08000000), Color(0x00000000),
              ],
            )),
          )),
        ),
        // Transparent at record/album top, smoothly transitions through
        // black levels, and reaches full black at the progress track bottom.
        Positioned(left: 0, right: 0, top: bottomFadeStart,
          height: bottomFadeHeight,
          child: const IgnorePointer(child: DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              stops: [0, .08, .20, .36, .53, .68, .81, .91, 1],
              colors: [
                Color(0x00000000), Color(0x00000000),
                Color(0x0D000000), Color(0x35000000),
                Color(0x78000000), Color(0xB8000000),
                Color(0xE8000000), Color(0xFA000000),
                Color(0xFF000000),
              ],
            )),
          )),
        ),
        // Start the solid region at the BOTTOM of the progress line,
        // never at the top of the album art or record.
        Positioned(left: 0, right: 0, top: bottomFadeEnd, bottom: 0,
          child: const IgnorePointer(child: ColoredBox(color: Colors.black))),
        // One consistent gesture surface across the ENTIRE video/fanart
        // area, not an impossible-to-discover invisible hotspot at the top.
        // The sleeve and transport controls are painted AFTER this surface,
        // so their own taps and drags take precedence.
        if (!_embedded)
          Positioned.fill(child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onToggleUtilityMenu,
            onDoubleTap: () => unawaited(_beginVideo()),
            onLongPress: () => unawaited(_linkVideo()),
            child: const SizedBox.expand(),
          )),
        if (_showVinyl) ...[
          // True feathered halo with ZERO alpha at every drawing edge.
          // The previous rectangle began abruptly ~20% above the sleeve,
          // creating the clearly visible horizontal band in the screenshots.
          Positioned(
            left: artLeft - artSide * .20,
            top: artTop - artSide * .34,
            width: artSide * 1.80,
            height: artSide * 1.76,
            child: IgnorePointer(child: CustomPaint(
              painter: _MusicVideoFeatheredHalo(widget.accent),
            )),
          ),
          // The record remains untouched in landscape and is simply not
          // rendered in portrait, where the enlarged cover is the backplate.
          if (!portrait)
            Positioned(left: discLeft, top: discTop,
              width: discSide, height: discSide,
              child: IgnorePointer(child: widget.buildVinyl(discSide))),
          Positioned(
            left: artLeft, top: artTop,
            width: artSide, height: artSide,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => unawaited(_openSourcePlayer()),
              child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(color: widget.accent.withOpacity(.67),
                    blurRadius: 48, spreadRadius: 4),
                  const BoxShadow(color: Color(0xB0000000),
                    blurRadius: 24, offset: Offset(6, 14)),
                ],
                border: Border.all(color: widget.accent.withOpacity(.91),
                  width: 1.8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(fit: StackFit.expand, children: [
                  sleeveArtwork == null
                      // Same VYBE branded cover as other themes when idle.
                      ? Image.asset('assets/vybe_album_placeholder.png',
                          fit: BoxFit.cover, filterQuality: FilterQuality.high)
                      : Image.memory(sleeveArtwork, fit: BoxFit.cover,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.high),
                  if (portrait) ...[
                    // Black through a smooth alpha ramp: it has the same
                    // darkening behavior as multiplying by black, without a
                    // costly framebuffer blend pass on low-end head units.
                    // Start just below the artwork's top border; fade to
                    // near-black beneath the existing progress track.
                    Positioned(left: 0, right: 0, top: 0,
                      height: portraitCoverFadeHeight,
                      child: const IgnorePointer(child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: [0, .10, .23, .40, .58, .74, .89, 1],
                            colors: [
                              Color(0x00000000),
                              Color(0x00000000),
                              Color(0x10000000),
                              Color(0x38000000),
                              Color(0x78000000),
                              Color(0xB9000000),
                              Color(0xE9000000),
                              Color(0xFF000000),
                            ],
                          ),
                        ),
                      )),
                    ),
                    // Only BELOW the progress track is solid black.
                    if (portraitCoverFadeHeight < artSide)
                      Positioned(left: 0, right: 0,
                        top: portraitCoverFadeHeight, bottom: 0,
                        child: const IgnorePointer(
                          child: ColoredBox(color: Colors.black))),
                  ],
                ]),
              ),
            )),
          ),
        ],
        if (_showLogo)
          Positioned(
            left: logoLeft, top: logoTop,
            width: logoWidth, height: logoHeight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onToggleUtilityMenu,
              onLongPress: widget.onOpenCustomize,
              onDoubleTap: widget.onOpenSettings,
              // Logo size is controlled by the same saved artistLogoScale
              // as every VYBE theme; a wide centered slot prevents its
              // 200% setting from being capped at a tiny 18%-width box.
              child: SizedBox.expand(
                child: widget.buildArtist(
                    portrait ? Alignment.topCenter : Alignment.topLeft)),
            ),
          ),
        if (_showInfo)
          Positioned(
            left: infoLeft,
            top: portrait ? songTop : h * .049,
            width: infoWidth,
            height: portrait ? infoHeight : h * .17,
            child: IgnorePointer(child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: portrait
                  ? CrossAxisAlignment.center : CrossAxisAlignment.end,
              children: [
                SizedBox(width: infoWidth,
                  height: portrait ? songHeight : h * .065,
                  child: shortLandscapeTitle
                    ? Align(alignment: Alignment.centerRight,
                        child: SizedBox(width: infoWidth * .78,
                          child: widget.buildTitle(Alignment.center)))
                    : widget.buildTitle(Alignment.center)),
                SizedBox(height: portrait ? infoGap : 4.0),
                SizedBox(width: infoWidth,
                  height: portrait ? albumHeight : h * .060,
                  child: widget.buildAlbum(portrait
                      ? Alignment.center : Alignment.centerRight)),
              ],
            )),
          ),
        // EXACTLY ONE interaction row, aligned at lower right of the mockup.
        // In contrast to the previous noninteractive progress indicator,
        // this slider seeks the actual embedded YouTube video.
        Positioned(
          right: transportRight, bottom: transportBottom,
          width: transportWidth, height: transportHeight,
          child: Row(crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _ringTransport(Icons.arrow_left_rounded,
                  _advancing ? null
                      : () => unawaited(_advance(previous: true)),
                  iconSize, 'Previous song'),
              SizedBox(width: iconGap),
              _ringTransport(isPlaying ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
                  _advancing ? null
                      : () => unawaited(_togglePlay()),
                  iconSize, isPlaying ? 'Pause' : 'Play'),
              SizedBox(width: iconGap),
              Expanded(child: Stack(fit: StackFit.expand, children: [
                // The thumb/track share the SAME vertical center as buttons.
                Positioned.fill(child: Align(
                  alignment: Alignment.center,
                  child: SizedBox(height: iconSize,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: portrait ? 5.0 : 8.0,
                        activeTrackColor: widget.accent,
                        inactiveTrackColor: widget.accent.withOpacity(.73),
                        thumbColor: const Color(0xFF050C10),
                        disabledThumbColor: const Color(0xFF050C10),
                        overlayColor: widget.accent.withOpacity(.25),
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius: portrait ? 9 : 14,
                          disabledThumbRadius: portrait ? 8 : 13,
                          elevation: 0, pressedElevation: 0),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 17),
                      ),
                      child: Slider(
                        value: (_scrubbing ? _seekPreview : position)
                          .clamp(0.0, duration > 0 ? duration : 1.0)
                          .toDouble(),
                        min: 0.0,
                        max: duration > 0 ? duration : 1.0,
                        onChangeStart: canSeek
                          ? (value) => setState(() {
                              _scrubbing = true; _seekPreview = value;
                            }) : null,
                        onChanged: canSeek
                          ? (value) => setState(() => _seekPreview = value)
                          : null,
                        onChangeEnd: canSeek
                          ? (value) => unawaited(_seekPlayback(value))
                          : null,
                      ),
                    ),
                  ),
                )),
                Positioned(left: 0, right: 0, bottom: 0,
                  child: IgnorePointer(child: Text(
                    _clock(_scrubbing ? _seekPreview : position) +
                    ' - ' + (duration > 0 ? _clock(duration) : '0:00'),
                    maxLines: 1, textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white,
                      fontSize: portrait ? 11.0 :
                          (h * .020).clamp(12.0, 18.0).toDouble()),
                  )),
                ),
              ])),
              SizedBox(width: iconGap),
              _ringTransport(Icons.arrow_right_rounded,
                  _advancing ? null : () => unawaited(_advance()),
                  iconSize, 'Next song'),
            ],
          ),
        ),
      ]));
    });
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    ++_embedSession;
    _callTimer?.cancel();
    _videoRetryTimer?.cancel();
    unawaited(_send('window.vybeStop && window.vybeStop();'));
    widget.onVideoPlaybackChanged(false);
    if (!_inCall) unawaited(_resumeSource());
    super.dispose();
  }
}

/// Gaussian-like radial falloff reaching full transparency before its bounds.
/// No rectangular background means no hard band when album colors change.
class _MusicVideoFeatheredHalo extends CustomPainter {
  final Color accent;
  const _MusicVideoFeatheredHalo(this.accent);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-.12, .08),
        radius: .43,
        stops: const [0, .28, .55, .82, 1],
        colors: [
          accent.withOpacity(.45),
          accent.withOpacity(.34),
          accent.withOpacity(.14),
          accent.withOpacity(.025),
          accent.withOpacity(0),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }
  @override
  bool shouldRepaint(covariant _MusicVideoFeatheredHalo old) =>
      old.accent != accent;
}

/// Subtle grooves catch the light near the exposed right side of the record.
class _MusicVideoVinylGrooves extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide / 2;
    for (var i = 0; i < 28; i++) {
      final radius = r * (.35 + i * .021);
      canvas.drawCircle(c, radius, Paint()
        ..color = Colors.white.withOpacity(i.isEven ? .043 : .023)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .65);
    }
    canvas.drawCircle(c, r * .095, Paint()
      ..color = const Color(0xFF141418));
    canvas.drawCircle(c, r * .021, Paint()
      ..color = const Color(0xFF767B85));
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Offline, nonplaying theme-library preview. Never starts video or YouTube
/// network activity merely because the user browses available themes.
class MusicVideoThemePreview extends StatelessWidget {
  final Uint8List? artwork;
  final Uint8List? fanart;
  final Uint8List? clearLogo;
  final String title;
  final String album;
  final String artist;
  final Color accent;

  const MusicVideoThemePreview({
    super.key,
    this.artwork,
    this.fanart,
    this.clearLogo,
    required this.title,
    required this.album,
    required this.artist,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final portrait = h > w * 1.1;
      final originalSide = math.min(w * .38, h * .24);
      final side = portrait ? w * .94 : w * .285;
      final discSide = side * .72;
      final left = portrait ? (w - side) * .5 : w * .013;
      final controlsHeight = h * .084;
      final controlsTop = h - h * .035 - controlsHeight;
      final songHeight = portrait ? h * .058 : h * .070;
      final albumHeight = portrait ? h * .049 : h * .055;
      final infoGap = portrait ? h * .006 : h * .005;
      final infoWidth = portrait ? w * .90 : w * .54;
      final infoLeft = portrait
          ? (w - infoWidth) * .5 : w - w * .032 - infoWidth;
      final artGap = portrait ? h * .014 : h * .009;
      final songTop = portrait
          ? math.max(h * .48, controlsTop - songHeight - albumHeight -
              infoGap - artGap - h * .016 - originalSide) +
              originalSide + artGap
          : h * .049;
      final top = portrait ? songTop - h * .021 : h * .747;
      final fadeStart = portrait ? top : top + side * .075;
      final fadeEnd = math.max(fadeStart + 1, h - h * .035 -
          controlsHeight * .5 + h * .003).clamp(0.0, h).toDouble();
      final fadeHeight = fadeEnd - fadeStart;
      return ClipRect(child: Stack(fit: StackFit.expand, children: [
        // A static fanart approximation for the theme gallery. Never start
        // YouTube/WebView simply by browsing the theme preview.
        if (fanart != null || artwork != null)
          Image.memory(fanart ?? artwork!, fit: BoxFit.cover,
              gaplessPlayback: true)
        else
          const ColoredBox(color: Color(0xFF091319)),
        Positioned(top: 0, left: 0, right: 0,
          height: h * (portrait ? .265 : .205),
          child: const DecoratedBox(decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              stops: [0, .10, .27, .43, .63, .80, .93, 1],
              colors: [
                Color(0xFF000000), Color(0xFF000000),
                Color(0xF6000000), Color(0xDC000000),
                Color(0x90000000), Color(0x38000000),
                Color(0x08000000), Color(0x00000000),
              ]))),
        ),
        Positioned(top: fadeStart, left: 0, right: 0, height: fadeHeight,
          child: const DecoratedBox(decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              stops: [0, .08, .20, .36, .53, .68, .81, .91, 1],
              colors: [
                Color(0x00000000), Color(0x00000000),
                Color(0x0D000000), Color(0x35000000),
                Color(0x78000000), Color(0xB8000000),
                Color(0xE8000000), Color(0xFA000000),
                Color(0xFF000000),
              ]))),
        ),
        Positioned(top: fadeEnd, bottom: 0, left: 0, right: 0,
          child: const ColoredBox(color: Colors.black)),

        Positioned(
          left: left - side * .20, top: top - side * .21,
          width: side * 1.75, height: side * 1.30,
          child: DecoratedBox(decoration: BoxDecoration(
            gradient: RadialGradient(
              colors: [accent.withOpacity(.55),
                accent.withOpacity(.18), Colors.transparent],
            ),
          )),
        ),
        if (!portrait)
          Positioned(left: left + side - discSide * .5, top: top + side * .075,
          width: discSide, height: discSide,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                colors: [Color(0xFF2F3138), Color(0xFF0C0D12),
                  Color(0xFF34343C), Colors.black],
                stops: [0, .33, .67, 1],
              ),
            ),
            child: CustomPaint(painter: _MusicVideoVinylGrooves()),
          ),
        ),
        Positioned(left: left, top: top, width: side, height: side,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: accent, width: 1.1),
              boxShadow: [BoxShadow(color: accent.withOpacity(.55),
                blurRadius: 11, spreadRadius: 2)],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: artwork != null
                ? Image.memory(artwork!, fit: BoxFit.cover)
                : Image.asset('assets/vybe_album_placeholder.png',
                    fit: BoxFit.cover),
            ),
          ),
        ),
        Positioned(
          left: portrait ? w * .08 : w * .024,
          right: portrait ? w * .08 : null,
          width: portrait ? null : w * .253,
          top: portrait ? h * .026 : h * .045,
          height: portrait ? h * .18 : h * .29,
          child: Align(
            alignment: portrait ? Alignment.topCenter : Alignment.topLeft,
            child: clearLogo != null
              ? Image.memory(clearLogo!, fit: BoxFit.contain,
                  alignment: portrait ? Alignment.topCenter : Alignment.topLeft)
              : Text(artist.isEmpty ? 'VYBE' : artist.toUpperCase(),
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  textAlign: portrait ? TextAlign.center : TextAlign.left,
                  style: TextStyle(color: Colors.white,
                    fontFamily: 'VYBERiot',
                    fontWeight: FontWeight.w800,
                    fontStyle: FontStyle.italic,
                    fontSize: portrait ? w * .047 : w * .032)),
          ),
        ),
        Positioned(left: infoLeft, top: songTop,
          width: infoWidth,
          child: Column(
            crossAxisAlignment: portrait
                ? CrossAxisAlignment.center : CrossAxisAlignment.end,
            children: [
              SizedBox(height: songHeight, width: infoWidth,
                child: Align(
                  alignment: Alignment.center,
                  child: Text(
                    title.isEmpty ? 'MUSIC VIDEO' : title,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white,
                      fontSize: portrait ? h * .033 : h * .05)))),
              SizedBox(height: infoGap),
              SizedBox(height: albumHeight, width: infoWidth,
                child: Align(
                  alignment: portrait ? Alignment.center : Alignment.centerRight,
                  child: Text(
                    album.isEmpty ? 'ALBUM' : album.toUpperCase(),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    textAlign: portrait ? TextAlign.center : TextAlign.right,
                    style: TextStyle(color: Colors.white,
                      fontSize: portrait ? h * .021 : h * .025,
                      fontStyle: FontStyle.italic,
                      letterSpacing: 1.4)))),
            ],
          )),
        Positioned(right: portrait ? w * .07 : w * .032,
          bottom: portrait ? h * .035 : h * .038,
          width: portrait ? w * .86 : w * .52,
          height: h * .084,
          child: Row(children: [
            Icon(Icons.arrow_circle_left_outlined,
              color: accent, size: h * .054),
            SizedBox(width: w * .012),
            Icon(Icons.pause_circle_outline_rounded,
              color: accent, size: h * .054),
            SizedBox(width: w * .016),
            Expanded(child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(height: math.max(2.0, h * .009).toDouble(),
                  decoration: BoxDecoration(color: accent,
                    borderRadius: BorderRadius.circular(3))),
                SizedBox(height: h * .016),
                Text('1:22 - 4:45',
                  style: TextStyle(color: Colors.white,
                    fontSize: math.max(7.0, h * .017).toDouble())),
              ],
            )),
            SizedBox(width: w * .016),
            Icon(Icons.arrow_circle_right_outlined,
              color: accent, size: h * .054),
          ]),
        ),
      ]));
    },
  );
}
