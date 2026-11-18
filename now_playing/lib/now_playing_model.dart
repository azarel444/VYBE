import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lyrics.dart';
import 'net.dart';
import 'media_cache.dart';
import 'local_artwork.dart';
import 'palette.dart';
import 'stream_track_metadata.dart';
import 'musicolet_placeholder.dart';
import 'coverflow_queue.dart';

/// Talks to the Kotlin side (MainActivity) which listens to the active
/// Android media session, whichever player app owns it.
class NowPlayingModel extends ChangeNotifier {
  static const _events = EventChannel('nowplaying/stream');
  static const _control = MethodChannel('nowplaying/control');
  static const _fftEvents = EventChannel('nowplaying/fft');
  static const _queueArt = MethodChannel('nowplaying/queue_art');

  bool accessGranted = true; // assume yes until Android says otherwise
  bool visualizerEnabled = true;
  bool artLookupEnabled = true;
  bool lyricsEnabled = false;
  // The phone must resolve lyrics for its paired head unit even when its own
  // current theme does not display them. This flag never forces the phone UI
  // to show lyrics, and doesn't depend on a second network connection.
  bool _sendLyricsOverLink = false;
  bool get _needsLyrics => lyricsEnabled || _sendLyricsOverLink;
  List<LyricLine>? lyrics;
  bool active = false;
  bool playing = false;
  String title = '';
  String artist = '';
  String album = '';

  /// Real MediaSession queue entries. Side covers are requested as small
  /// thumbnails; the main cover stays in [art] at original quality.
  List<CoverflowCover> coverflowCovers = <CoverflowCover>[];
  int coverflowRevision = 0;
  final Map<String, Uint8List> _coverflowThumbCache = {};
  final Set<String> _coverflowSharpLookupAttempts = <String>{};
  final List<CoverflowCover> _coverflowHistory = <CoverflowCover>[];
  String _coverflowQueueSignature = '';
  int _coverflowToken = 0;
  int _coverflowRepeatCheckSerial = 0;
  // Preserve ALL real queue/history candidates when identical artwork is
  // skipped. Otherwise the removed first previous sleeve can never be
  // replaced by an older, different album cover.
  List<CoverflowCover> _coverflowCandidates = <CoverflowCover>[];
  final Map<Uint8List, Uint8List> _coverflowSamples = {};

  /// Up to two REAL upcoming queue entries, independent of the selected
  /// visual theme. No inferred or historical tracks can enter prefetch.
  List<CoverflowCover> get smartPrefetchQueue {
    if (_linkReceiverActive || !active) return const <CoverflowCover>[];
    final next = _coverflowCandidates.where((item) =>
        item.slot > 0 && item.slot <= 2 &&
        item.title.trim().isNotEmpty && item.artist.trim().isNotEmpty).toList()
      ..sort((a, b) => a.slot.compareTo(b.slot));
    return next.take(2).toList(growable: false);
  }

  // Hold a maximum of three already-decoded catalog covers. They can be
  // displayed in the very first frame of a song transition if the source
  // doesn't supply its own artwork. Normal media-session covers still win.
  final Map<String, ArtAssets> _smartPrefetchedAlbums = {};
  final Set<String> _smartPrefetchInFlight = {};
  static String _smartPrefetchKey(String artistName, String titleName) =>
      '${artistName.trim().toLowerCase()}|${titleName.trim().toLowerCase()}';

  /// Low-priority album lookup for a *published* upcoming queue entry.
  /// Does not mutate current-track fields or replace supplied player art.
  Future<void> prefetchQueueAlbum(CoverflowCover entry) async {
    if (_disposed || _linkReceiverActive || !active || !playing ||
        !artLookupEnabled || albumArtPriorityPending || art == null) return;
    final key = _smartPrefetchKey(entry.artist, entry.title);
    if (entry.artist.trim().isEmpty || entry.title.trim().isEmpty ||
        key == _smartPrefetchKey(artist, title) ||
        _smartPrefetchedAlbums.containsKey(key) ||
        !_smartPrefetchInFlight.add(key)) return;
    try {
      Uint8List? bytes = _artCache[key] ?? await MediaCache.getArt(key);
      if (bytes == null) {
        // Queue entries have no trustworthy album tag. Never use a guessed
        // album or an original-remix fallback as an exact track cover.
        final result = await fetchArtworkWithMatch(
          entry.title, entry.artist, allowOriginalFallback: false,
        );
        bytes = result?.bytes;
      }
      if (_disposed || bytes == null || bytes.isEmpty ||
          bytes.length > 6 * 1024 * 1024) return;
      final asset = await ArtAssets.load(bytes);
      if (_disposed || asset == null || asset.flat) return;
      _artCache[key] = bytes;
      if (_artCache.length > 12) _artCache.remove(_artCache.keys.first);
      _smartPrefetchedAlbums.remove(key);
      _smartPrefetchedAlbums[key] = asset;
      while (_smartPrefetchedAlbums.length > 3) {
        _smartPrefetchedAlbums.remove(_smartPrefetchedAlbums.keys.first);
      }
      // Persist in the SAME exact artist+song cache read by _lookupArt.
      unawaited(MediaCache.putArt(key, bytes));
      // Coverflow previously kept displaying the low-resolution queue
      // icon even AFTER Smart Prefetch prepared an exact recording match.
      // Feed that high-quality image straight into any visible future sleeve.
      // Do not substitute a cover when artist or song/version differs.
      await _publishPrefetchedCoverflowArt(key, bytes);
      debugPrint('VYBE Smart Prefetch: ready album for ${entry.artist} — ${entry.title}');
    } catch (error) {
      debugPrint('VYBE Smart Prefetch album unavailable: $error');
    } finally {
      _smartPrefetchInFlight.remove(key);
    }
  }

  /// Reuse the verified, full-resolution cover prepared by Smart Prefetch
  /// for the same song in Coverflow, including when viewing via VYBE Link.
  /// This also prevents repeated online queries for a cover already cached.
  Future<void> _publishPrefetchedCoverflowArt(String trackKey, Uint8List bytes) async {
    if (_disposed || _linkReceiverActive) return;
    final matches = _coverflowCandidates.where((entry) =>
        entry.slot > 0 &&
        _smartPrefetchKey(entry.artist, entry.title) == trackKey).toList();
    if (matches.isEmpty) return;
    try {
      final encoded = await _queueArt.invokeMethod<Uint8List>('encode', {
        'bytes': bytes, 'targetSide': 768,
      });
      if (_disposed || encoded == null || encoded.isEmpty ||
          encoded.length > 280 * 1024) return;
      var changed = false;
      final upgraded = <CoverflowCover>[];
      for (final entry in _coverflowCandidates) {
        if (entry.slot > 0 &&
            _smartPrefetchKey(entry.artist, entry.title) == trackKey) {
          final key = '${entry.id}|${entry.artUri}';
          _coverflowThumbCache[key] = encoded;
          upgraded.add(entry.withThumbnail(encoded));
          changed = true;
        } else {
          upgraded.add(entry);
        }
      }
      if (changed) {
        _coverflowCandidates = upgraded;
        _checkCoverflowRepeatedArtwork();
      }
    } catch (error) {
      debugPrint('VYBE cached Coverflow cover upgrade unavailable: $error');
    }
  }

  /// Remote media queues (notably YouTube Music) frequently publish a
  /// 60-pixel URL even while the underlying cover is available at 768px.
  /// Request the larger provider-owned thumbnail instead of stretching
  /// the 60px icon. The original URI remains the last-resort fallback.
  List<Uri> _coverflowSourceUris(String raw) {
    final original = Uri.tryParse(raw);
    if (original == null || original.scheme != 'https') return <Uri>[];
    final host = original.host.toLowerCase();
    final candidates = <Uri>[];
    void add(String url) {
      final uri = Uri.tryParse(url);
      if (uri != null && uri.scheme == 'https' &&
          uri.host.toLowerCase() == host && !candidates.contains(uri)) {
        candidates.add(uri);
      }
    }
    if (host == 'yt3.googleusercontent.com' ||
        host == 'lh3.googleusercontent.com' || host == 'yt3.ggpht.com') {
      // Only rewrite documented thumbnail size suffixes for known hosts.
      final larger = raw.replaceFirst(
          RegExp(r'=w[0-9]+-h[0-9]+'), '=w768-h768');
      if (larger != raw) add(larger);
      final largerSquare = raw.replaceFirst(
          RegExp(r'=s[0-9]+'), '=s768');
      if (largerSquare != raw) add(largerSquare);
    } else if (host == 'i.ytimg.com' || host == 'img.youtube.com') {
      // For video entries, a larger thumbnail for the SAME video ID
      // is preferable when provided by YouTube; no unrelated search.
      final segments = original.pathSegments;
      if (segments.length >= 3 &&
          (segments[0] == 'vi' || segments[0] == 'vi_webp') &&
          RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(segments[1])) {
        add(original.replace(
          pathSegments: [...segments.take(2), 'maxresdefault.jpg'],
          query: '',
        ).toString());
        add(original.replace(
          pathSegments: [...segments.take(2), 'sddefault.jpg'],
          query: '',
        ).toString());
      }
    }
    add(raw);
    return candidates;
  }

  /// Resolution is checked on SOURCE bytes before native compression.
  /// Changing targetSide alone cannot restore detail to a 60px image.
  Future<int> _coverflowSourceDetail(Uint8List bytes) async {
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      try {
        return math.min(frame.image.width, frame.image.height);
      } finally {
        frame.image.dispose();
      }
    } catch (_) {
      return 0;
    } finally {
      codec?.dispose();
    }
  }

  Future<Uint8List?> _coverflowImageSample(Uint8List bytes) async {
    final hit = _coverflowSamples[bytes];
    if (hit != null) return hit;
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes,
          targetWidth: 24, targetHeight: 24);
      final frame = await codec.getNextFrame();
      try {
        final pixels = await frame.image.toByteData(
            format: ui.ImageByteFormat.rawRgba);
        if (pixels == null) return null;
        final data = Uint8List.fromList(pixels.buffer.asUint8List(
            pixels.offsetInBytes, pixels.lengthInBytes));
        if (_coverflowSamples.length >= 48) {
          _coverflowSamples.remove(_coverflowSamples.keys.first);
        }
        _coverflowSamples[bytes] = data;
        return data;
      } finally {
        frame.image.dispose();
      }
    } catch (error) {
      debugPrint('VYBE Coverflow image comparison unavailable: $error');
      return null;
    } finally {
      codec?.dispose();
    }
  }

  bool _coverflowSameArtwork(Uint8List a, Uint8List b) {
    if (a.length != b.length || a.length < 64 || a.length % 4 != 0) {
      return false;
    }
    var difference = 0;
    for (var i = 0; i < a.length; i += 4) {
      difference += (a[i] - b[i]).abs();
      difference += (a[i + 1] - b[i + 1]).abs();
      difference += (a[i + 2] - b[i + 2]).abs();
    }
    // Allow JPEG thumbnail recompression, not visually different covers.
    return difference / (a.length / 4 * 3) < 12.0;
  }

  void _publishCoverflowSelection(List<CoverflowCover> selected) {
    if (_disposed) return;
    final unchanged = coverflowCovers.length == selected.length &&
        List.generate(selected.length, (i) =>
            coverflowCovers[i].id == selected[i].id &&
            coverflowCovers[i].slot == selected[i].slot &&
            identical(coverflowCovers[i].thumb, selected[i].thumb))
            .every((same) => same);
    if (unchanged) return;
    coverflowCovers = selected;
    coverflowRevision++;
    notifyListeners();
  }

  // Never collapse or delete the source queue. Compact actual distinct
  // artwork into the three visible slots, searching deeper in real played
  // history when several consecutive tracks share the same album sleeve.
  void _checkCoverflowRepeatedArtwork() {
    final serial = ++_coverflowRepeatCheckSerial;
    final candidates = List<CoverflowCover>.of(_coverflowCandidates);
    final token = _coverflowToken;
    final expectedTrack = _trackKey;
    final activeBytes = art?.bytes;
    if (candidates.isEmpty) {
      _publishCoverflowSelection(const <CoverflowCover>[]);
      return;
    }

    // An outgoing album is deliberately kept during a track transition.
    // Until new art is confirmed, avoid comparing older history against
    // that provisional center image. Once confirmed, run the full test.
    if (activeBytes == null || _albumArtPriorityPending) {
      final picks = <CoverflowCover>[];
      for (final side in const [-1, 1]) {
        final ordered = candidates.where((c) =>
            c.slot * side > 0 && c.thumb != null && c.thumb!.isNotEmpty).toList()
          ..sort((a, b) => a.slot.abs().compareTo(b.slot.abs()));
        var count = 0;
        final seen = <Uint8List>[];
        for (final entry in ordered) {
          if (count == 3) break;
          final bytes = entry.thumb!;
          if (seen.any((previous) =>
              identical(previous, bytes) || listEquals(previous, bytes))) {
            continue;
          }
          seen.add(bytes);
          picks.add(entry.atSlot(side * ++count));
        }
      }
      _publishCoverflowSelection(picks);
      return;
    }
    unawaited(_pruneCoverflowRepeatedArtwork(
        activeBytes, candidates, serial, expectedTrack, token));
  }

  Future<void> _pruneCoverflowRepeatedArtwork(
      Uint8List activeArt, List<CoverflowCover> candidates,
      int serial, String track, int token) async {
    bool stale() => _disposed || serial != _coverflowRepeatCheckSerial ||
        token != _coverflowToken || track != _trackKey;
    final centerSample = await _coverflowImageSample(activeArt);
    if (stale()) return;

    final usedBytes = <Uint8List>[activeArt];
    final usedSamples = <Uint8List>[
      if (centerSample != null) centerSample,
    ];
    final selected = <CoverflowCover>[];
    for (final side in const [-1, 1]) {
      final ordered = candidates.where((c) =>
          c.slot * side > 0 && c.thumb != null && c.thumb!.isNotEmpty).toList()
        ..sort((a, b) => a.slot.abs().compareTo(b.slot.abs()));
      var count = 0;
      for (final entry in ordered) {
        if (count == 3) break;
        final bytes = entry.thumb!;
        if (usedBytes.any((old) =>
            identical(old, bytes) || listEquals(old, bytes))) continue;
        final sample = await _coverflowImageSample(bytes);
        if (stale()) return;
        if (sample != null &&
            usedSamples.any((old) => _coverflowSameArtwork(old, sample))) {
          continue;
        }
        selected.add(entry.atSlot(side * ++count));
        usedBytes.add(bytes);
        if (sample != null) usedSamples.add(sample);
      }
    }
    if (!stale()) _publishCoverflowSelection(selected);
  }

  void _rememberCoverflowPrevious(String oldTitle, String oldArtist,
      Uint8List? oldArt) {
    if (oldTitle.trim().isEmpty || oldArt == null || oldArt.isEmpty) return;
    // History is actual played artwork only; never guess the future.
    _coverflowHistory.removeWhere((e) =>
        e.title == oldTitle && e.artist == oldArtist);
    _coverflowHistory.insert(0, CoverflowCover(
        id: 'played:${DateTime.now().microsecondsSinceEpoch}',
        slot: -1, title: oldTitle, artist: oldArtist, thumb: oldArt));
    if (_coverflowHistory.length > 24) _coverflowHistory.removeRange(24, _coverflowHistory.length);
  }

  void _showCoverflowHistory() {
    _coverflowCandidates = [
      for (var i = 0; i < _coverflowHistory.length; i++)
        _coverflowHistory[i].atSlot(-(i + 1)),
    ];
    _checkCoverflowRepeatedArtwork();
  }

  /// Called only for actual published queue entries. Never fabricate a next
  /// cover for players that expose no queue. Image loading is asynchronous,
  /// cached, and guarded against track changes.
  void _applyNativeCoverflowQueue(dynamic raw) {
    if (_linkReceiverActive || raw is! List) return;
    final entries = <CoverflowCover>[];
    for (final value in raw.take(7)) {
      if (value is! Map) continue;
      final id = value['id']?.toString() ?? '';
      final slot = (value['slot'] as num?)?.toInt();
      final name = value['title']?.toString().trim() ?? '';
      if (id.isEmpty || slot == null || slot.abs() > 3 ||
          name.isEmpty || slot == 0) continue;
      final uri = value['artUri']?.toString() ?? '';
      final cacheKey = '$id|$uri';
      entries.add(CoverflowCover(
          id: id, slot: slot, title: name,
          artist: value['artist']?.toString() ?? '',
          artUri: uri, thumb: _coverflowThumbCache[cacheKey]));
    }
    final signature = entries.map((x) => '${x.id}:${x.slot}:${x.artUri}').join('|');
    if (signature == _coverflowQueueSignature) return;
    _coverflowQueueSignature = signature;
    final token = ++_coverflowToken;
    // Queue positions remain authoritative. Backfill from actual playback
    // history (not fabricated upcoming tracks), including older albums past
    // the first three songs sharing an identical cover.
    var nextPrevious = 0;
    for (final e in entries) {
      if (e.slot < 0 && e.slot.abs() > nextPrevious) {
        nextPrevious = e.slot.abs();
      }
    }
    for (final played in _coverflowHistory) {
      if (entries.any((e) => e.slot < 0 &&
          e.title == played.title && e.artist == played.artist)) continue;
      entries.add(played.atSlot(-(++nextPrevious)));
    }
    _coverflowCandidates = entries;
    _checkCoverflowRepeatedArtwork();
    // Prioritize the active cover and clearlogo before fetching *side*
    // thumbnails. Run the network/decode work one at a time so six artwork
    // downloads do not spike Wi-Fi Direct/Bluetooth coexistence on the A5L.
    final pending = entries.where((e) =>
        e.thumb == null && !e.id.startsWith('played:')).toList()
      ..sort((a, b) => a.slot.abs().compareTo(b.slot.abs()));
    unawaited(() async {
      for (final entry in pending) {
        if (token != _coverflowToken || _disposed) return;
        // The main cover always wins the song-change load race.
        if (albumArtPriorityPending || art == null) {
          await Future<void>.delayed(const Duration(milliseconds: 450));
        }
        if (token != _coverflowToken || _disposed) return;
        await _fetchCoverflowThumbnail(entry, token);
        await Future<void>.delayed(const Duration(milliseconds: 95));
      }
    }());
  }

  Future<void> _fetchCoverflowThumbnail(CoverflowCover entry, int token) async {
    Uint8List? bytes;
    final cacheKey = '${entry.id}|${entry.artUri}';
    if (_coverflowThumbCache[cacheKey]?.isNotEmpty == true) return;
    // The nearest sleeves are almost as large as the selected cover.
    final targetSide = entry.slot.abs() == 1 ? 768
        : entry.slot.abs() == 2 ? 640 : 512;
    try {
      final trackKey = _smartPrefetchKey(entry.artist, entry.title);
      // First check the EXACT recording cache prepared in normal playback.
      // It is already persisted and often sharper than a player's queue icon.
      Uint8List? cachedCover = _artCache[trackKey];
      cachedCover ??= await MediaCache.getArt(trackKey);
      if (cachedCover != null && cachedCover.isNotEmpty &&
          cachedCover.length <= 8 * 1024 * 1024 &&
          await _coverflowSourceDetail(cachedCover) >= 420) {
        bytes = await _queueArt.invokeMethod<Uint8List>('encode', {
          'bytes': cachedCover, 'targetSide': targetSide,
        });
      }

      if (bytes == null || bytes.isEmpty) {
        Uint8List? bestSource;
        var detail = 0;
        // Prefer the genuine larger artwork URL, not an enlarged icon.
        for (final uri in _coverflowSourceUris(entry.artUri)) {
          if (token != _coverflowToken || _disposed) return;
          try {
            final downloaded = await httpGetBytes(uri);
            if (downloaded == null || downloaded.isEmpty ||
                downloaded.length > 8 * 1024 * 1024) continue;
            final measured = await _coverflowSourceDetail(downloaded);
            if (measured > detail) {
              bestSource = downloaded;
              detail = measured;
            }
            if (detail >= math.min(targetSide, 600)) break;
          } catch (error) {
            debugPrint('VYBE Coverflow larger queue image unavailable: $error');
          }
        }
        if (bestSource != null) {
          bytes = await _queueArt.invokeMethod<Uint8List>('encode', {
            'bytes': bestSource, 'targetSide': targetSide,
          });
        }
      }
      if (bytes == null || bytes.isEmpty) {
        final numericId = int.tryParse(entry.id);
        if (numericId != null) {
          bytes = await _queueArt.invokeMethod<Uint8List>('thumbnail', {
            'queueId': numericId, 'targetSide': targetSide,
          });
        }
      }
    } catch (error) {
      debugPrint('VYBE Coverflow queue thumbnail unavailable: $error');
    }
    if (bytes == null || bytes.isEmpty || bytes.length > 280 * 1024 ||
        token != _coverflowToken || _disposed) return;
    // Smart Prefetch might have supplied a sharper matching cover during
    // the network request; never overwrite it with a delayed small bitmap.
    if (_coverflowThumbCache[cacheKey]?.isNotEmpty == true) return;
    _coverflowThumbCache[cacheKey] = bytes;
    if (_coverflowThumbCache.length > 30) {
      _coverflowThumbCache.remove(_coverflowThumbCache.keys.first);
    }
    final index = _coverflowCandidates.indexWhere((e) =>
        e.id == entry.id && e.slot == entry.slot);
    if (index == -1) return;
    _coverflowCandidates = List<CoverflowCover>.of(_coverflowCandidates)
      ..[index] = entry.withThumbnail(bytes);
    _checkCoverflowRepeatedArtwork();

    // Upgrade every visible *future* sleeve, not just the closest one.
    // A source image with genuinely sufficient dimensions exits fast.
    // When a provider only publishes low-resolution artwork, attempt an
    // exact artist+recording catalog match. Never invent an unrelated art.
    if (entry.slot > 0 && entry.slot <= 3 && artLookupEnabled &&
        entry.title.trim().isNotEmpty && entry.artist.trim().isNotEmpty &&
        _coverflowSharpLookupAttempts.add(cacheKey)) {
      if (_coverflowSharpLookupAttempts.length > 80) {
        _coverflowSharpLookupAttempts.clear();
        _coverflowSharpLookupAttempts.add(cacheKey);
      }
      unawaited(_upgradeCoverflowSideArt(entry, cacheKey, bytes, token));
    }
  }

  Future<void> _upgradeCoverflowSideArt(
      CoverflowCover entry, String cacheKey,
      Uint8List original, int token) async {
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(original);
      final frame = await codec.getNextFrame();
      final width = frame.image.width;
      final height = frame.image.height;
      frame.image.dispose();
      if (width >= 550 && height >= 550) return;
      if (_disposed || token != _coverflowToken) return;
      // Avoid competing with the current song's primary album-art request.
      if (albumArtPriorityPending) {
        await Future<void>.delayed(const Duration(milliseconds: 550));
      }
      if (_disposed || token != _coverflowToken) return;
      final result = await fetchArtworkWithMatch(
        entry.title, entry.artist, allowOriginalFallback: false,
      );
      if (result == null || token != _coverflowToken || _disposed) return;
      final candidate = await _queueArt.invokeMethod<Uint8List>('encode', {
        'bytes': result.bytes, 'targetSide': 768,
      });
      if (candidate == null || candidate.isEmpty ||
          candidate.length > 280 * 1024 ||
          token != _coverflowToken || _disposed) return;
      final newIndex = _coverflowCandidates.indexWhere((e) =>
          e.id == entry.id && e.slot == entry.slot);
      if (newIndex < 0) return;
      _coverflowThumbCache[cacheKey] = candidate;
      _coverflowCandidates = List<CoverflowCover>.of(_coverflowCandidates)
        ..[newIndex] =
            _coverflowCandidates[newIndex].withThumbnail(candidate);
      _checkCoverflowRepeatedArtwork();
    } catch (error) {
      debugPrint('VYBE high-resolution side cover unavailable: $error');
    } finally {
      codec?.dispose();
    }
  }

  void applyLinkCoverflow(String track, List<CoverflowCover> incoming) {
    if (!_linkReceiverActive || track != _trackKey) return;
    // The receiving head unit never fetches player queue art from the
    // internet. It displays only the exact thumbnails sent by the phone.
    _coverflowCandidates = incoming.where((e) =>
        e.slot != 0 && e.slot.abs() <= 3 &&
        e.thumb != null && e.thumb!.isNotEmpty).toList();
    _checkCoverflowRepeatedArtwork();
  }

  // Preserve the media session's raw album value for cover searches. An
  // independently verified catalog release may enrich the *label* only.
  String _catalogReleaseTitle = '';
  final Map<String, String> _catalogReleaseCache = {};
  String _releaseLookupTrack = '';
  bool _disposed = false;

  bool get _missingAlbumTag {
    final value = album.trim().toLowerCase();
    return value.isEmpty || const <String>{
      'unknown', 'unknown album', 'album unknown', '<unknown>',
      'not available', 'n/a',
    }.contains(value);
  }

  /// Never say ALBUM UNKNOWN for a playing song. Match a known real release
  /// when available; if tags/catalog data are absent, preserve the track
  /// title as a possible single instead of inventing release metadata.
  String get displayAlbumTitle {
    if (!_missingAlbumTag) return album.trim();
    if (_catalogReleaseTitle.isNotEmpty) return _catalogReleaseTitle;
    return active ? title.trim() : '';
  }

  void _resolveMissingAlbum(String expectedTrack) {
    if (_disposed || !artLookupEnabled || !_missingAlbumTag ||
        title.trim().isEmpty || artist.trim().isEmpty ||
        expectedTrack != _trackKey) return;
    final key = '${artist.trim().toLowerCase()}|${title.trim().toLowerCase()}';
    final cached = _catalogReleaseCache[key];
    if (cached != null) {
      if (_catalogReleaseTitle != cached) {
        _catalogReleaseTitle = cached;
        notifyListeners();
      }
      return;
    }
    if (_releaseLookupTrack == expectedTrack) return;
    _releaseLookupTrack = expectedTrack;
    final artistName = artist;
    final songName = title;
    unawaited(() async {
      final release = await fetchSongReleaseTitle(songName, artistName);
      if (_disposed || expectedTrack != _trackKey || !_missingAlbumTag ||
          release == null || release.trim().isEmpty) return;
      final verified = release.trim();
      _catalogReleaseTitle = verified;
      _catalogReleaseCache[key] = verified;
      if (_catalogReleaseCache.length > 60) {
        _catalogReleaseCache.remove(_catalogReleaseCache.keys.first);
      }
      notifyListeners();
    }());
  }

  int durationMs = 0;
  ArtAssets? art;

  int _posMs = 0;
  double _speed = 1.0;
  DateTime _stamp = DateTime.now();
  String _trackKey = '';
  int _artToken = 0;
  int _lyricsToken = 0;
  Timer? _lyricsRetryTimer;
  int _lyricsRetryAttempts = 0;
  Timer? _netTimer;
  Timer? _artClearTimer;
  Timer? _sessionVerificationTimer;
  Timer? _artRetryTimer;
  Timer? _sessionArtRetryTimer;
  int _sessionArtRetries = 0;
  String _lookupInFlight = '';
  String _localArtLookupTrack = '';
  // The current song's album cover gets the first opportunity to load;
  // backgrounds and logos can start after the first attempt or a short cap.
  bool _albumArtPriorityPending = false;
  bool get albumArtPriorityPending =>
      _albumArtPriorityPending && artLookupEnabled && active;
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
  Timer? _linkInactiveTimer;
  Timer? _linkDisconnectTimer;
  String _albumKey = '';
  bool _needsArt = false; // album changed and the player sent no new cover yet
  String _sentLaunch = '';
  final Map<String, Uint8List> _artCache = {};
  // Original song covers do not certify an exact remix release.
  final Map<String, Uint8List> _originalFallbackArtCache = {};
  // Reuse covers across songs on the same positively identified album.
  final Map<String, Uint8List> _albumArtCache = {};
  // Detect a player-supplied placeholder or shared playlist cover when the
  // identical image appears under unrelated artist/album identities.
  final Map<int, Set<String>> _sessionArtOwners = {};
  final Set<int> _sharedSessionImages = {};
  final Set<int> _markedPlaceholders = {};
  // Detected visual fingerprints of Musicolet's branded default cover.
  final Set<int> _automaticPlaceholderHashes = {};
  String _sessionPlayerPackage = '';
  /// Spotify represents an ad break as a track with an artist credit such
  /// as "Advertisement 2 of 3". This is not a real artist.
  bool get isSpotifyAdvertisement {
    if (_sessionPlayerPackage != 'com.spotify.music') return false;
    return RegExp(
      r'^advertisement(?:\s+\d+\s+of\s+\d+)?$',
      caseSensitive: false,
    ).hasMatch(artist.trim());
  }
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
    // Do not persist unverified media-session images under broad album
    // keys. Old caches could otherwise store a generic player's icon.
    // Strictly verified downloaded covers are cached by artist + song.
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
    _disposed = true;
    _sub?.cancel();
    _fftSub?.cancel();
    _netTimer?.cancel();
    _lyricsRetryTimer?.cancel();
    _artClearTimer?.cancel();
    _sessionVerificationTimer?.cancel();
    _artRetryTimer?.cancel();
    _sessionArtRetryTimer?.cancel();
    _idleTimer?.cancel();
    _linkInactiveTimer?.cancel();
    _linkDisconnectTimer?.cancel();
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

  /// A Link connection must never clear the native music state on a sender.
  /// On receivers, a brief Wi-Fi interruption should retain the last song
  /// instead of switching repeatedly to the empty-state screen.
  void setLinkReceiverActive(bool on, {bool immediate = false}) {
    _linkDisconnectTimer?.cancel();
    _linkDisconnectTimer = null;
    if (on) {
      _linkReceiverActive = true;
      _linkInactiveTimer?.cancel();
      _linkInactiveTimer = null;
      _idleTimer?.cancel();
      _netTimer?.cancel();
      _artRetryTimer?.cancel();
      _artClearTimer?.cancel();
      return;
    }
    if (!_linkReceiverActive) return; // Sender/disabled: no receiver state to reset.
    void releaseReceiver() {
      _linkDisconnectTimer = null;
      if (!_linkReceiverActive) return;
      _linkReceiverActive = false;
      _linkInactiveTimer?.cancel();
      _linkInactiveTimer = null;
      _clearAll();
      active = false;
      playing = false;
      notifyListeners();
      // Resume reading the device's own media sessions if one is available.
      _control.invokeMethod<void>('refresh').catchError((_) {});
    }
    if (immediate) {
      releaseReceiver();
    } else {
      _linkDisconnectTimer = Timer(const Duration(seconds: 10), releaseReceiver);
    }
  }

  void applyLinkMetadata({required String titleValue, required String artistValue,
      required String albumValue, required bool isPlaying, required bool isActive,
      required int duration, required int position, Uint8List? artwork}) {
    if (!_linkReceiverActive) return;

    // The sender may briefly report an empty session while Android switches
    // media controllers. Require a sustained inactive report before clearing.
    // Cancel immediately when valid song information resumes.
    if ((!isActive || titleValue.trim().isEmpty) && active && title.isNotEmpty) {
      _linkInactiveTimer ??= Timer(const Duration(seconds: 7), () {
        _linkInactiveTimer = null;
        if (!_linkReceiverActive) return;
        _clearAll();
        active = false;
        playing = false;
        notifyListeners();
      });
      return;
    }
    _linkInactiveTimer?.cancel();
    _linkInactiveTimer = null;
    final key = '$titleValue|$artistValue|$albumValue';
    final changed = key != _trackKey;
    if (changed) {
      _rememberCoverflowPrevious(title, artist, art?.bytes);
      _coverflowToken++;
      _coverflowQueueSignature = '';
      _showCoverflowHistory();
      _catalogReleaseTitle = '';
      _releaseLookupTrack = '';
      _artToken++; _artRetryTimer?.cancel(); _artClearTimer?.cancel();
      _artAttempts = 0; _lookupInFlight = ''; // Retain previous cover until new art arrives.
      _resetLyricsLookup();
      lyrics = null; _lyricsToken++;
    }
    title = titleValue; artist = artistValue; album = albumValue;
    active = isActive; playing = isPlaying;
    durationMs = duration; _posMs = position; _stamp = DateTime.now();
    _trackKey = key; _albumKey = '${artist.toLowerCase()}|${album.toLowerCase()}';
    if (artwork != null && (changed || art == null || !listEquals(art!.bytes, artwork))) {
      _setArt(artwork);
    }
    if (changed && _needsLyrics) _fetchLyrics();
    notifyListeners();
    if (changed && _missingAlbumTag) _resolveMissingAlbum(key);
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
    // Some players keep their session alive but publish an empty metadata
    // snapshot while switching tracks. Treat that as transient too.
    final missingMetadata = nowActive && active && title.isNotEmpty &&
        ((m['title'] as String?) ?? '').trim().isEmpty;

    if (!accessGranted) {
      _idleTimer?.cancel();
      active = false;
      _clearAll();
      notifyListeners();
      return;
    }

    if (!nowActive || missingMetadata) {
      // A temporary missing session OR an empty metadata callback must
      // not replace a real song with the placeholder.
      // An empty getActiveSessions result is not evidence that the user
      // stopped the music. Keep the last known track while the player
      // replaces its media session; only clear after a sustained absence.
      if (active && title.isNotEmpty) {
        _idleTimer ??= Timer(const Duration(seconds: 7), () {
          _idleTimer = null;
          active = false;
          playing = false;
          _clearAll();
          notifyListeners();
        });
      } else {
        playing = false;
      }
      return;
    }
    _idleTimer?.cancel();
    _idleTimer = null;
    active = true;

    playing = m['playing'] == true;
    _sessionPlayerPackage = (m['sourcePackage'] as String?) ?? '';
    final sessionMetadata = StreamTrackMetadata.resolve(
      title: (m['title'] as String?) ?? '',
      artist: (m['artist'] as String?) ?? '',
      album: (m['album'] as String?) ?? '',
      sourcePackage: (m['sourcePackage'] as String?) ?? '',
    );
    // Resolve before computing the track key and initiating artwork, lyric,
    // album and VYBE Connect updates so every subsystem shares the same
    // corrected artist/title when an upload-style session is detected.
    final oldTitleForCoverflow = title;
    final oldArtistForCoverflow = artist;
    final oldArtForCoverflow = art?.bytes;
    title = sessionMetadata.title;
    artist = sessionMetadata.artist;
    album = sessionMetadata.album;
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
      _rememberCoverflowPrevious(
          oldTitleForCoverflow, oldArtistForCoverflow, oldArtForCoverflow);
      _coverflowToken++;
      _coverflowQueueSignature = '';
      _showCoverflowHistory();
      _catalogReleaseTitle = '';
      _releaseLookupTrack = '';
      _artToken++; // Invalidate lookups and decoding from the previous song.
      _artRetryTimer?.cancel();
      _sessionVerificationTimer?.cancel();
      _sessionArtRetryTimer?.cancel();
      _sessionArtRetries = 0;
      _artAttempts = 0;
      _lookupInFlight = '';
      _localArtLookupTrack = '';
      _albumArtPriorityPending = artLookupEnabled && title.isNotEmpty;
      _needsArt = false;
      sessionArtworkStatus = 'Awaiting artwork for new track';
      artworkSource = 'None';
      artworkFailure = 'None';
      artworkLookupState = 'Idle';
      _artClearTimer?.cancel();
      // Keep outgoing cover until new artwork arrives, avoiding standby flashes.
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
        unawaited(_loadPlaceholderHashes().then((_) {
          if (_disposed || _trackKey != key ||
              !_markedPlaceholders.contains(_imageFingerprint(artBytes))) return;
          // Only remove this exact player image, never a verified catalog
          // cover which might have been loaded while preferences were read.
          if (art != null && listEquals(art!.bytes, artBytes)) {
            _artToken++;
            art = null;
            artworkSource = 'None';
            _albumArtCache.remove(cacheAlbumKey);
            sessionArtworkStatus = 'Rejected saved player placeholder';
            notifyListeners();
            if (artLookupEnabled) unawaited(_lookupLocalFirst());
          }
        }));
      }
    } else if (changed) {
      _latestSessionArtwork = null;
    }
    // Manual placeholder marks apply to every metadata event, not only the
    // first callback. Legitimate compilation/shared covers stay usable.
    final rejectedSessionImage = artBytes is Uint8List &&
        artBytes.isNotEmpty &&
        (_automaticPlaceholderHashes.contains(_imageFingerprint(artBytes)) ||
            (_placeholderHashesLoaded &&
                _markedPlaceholders.contains(_imageFingerprint(artBytes))));
    if (artBytes is Uint8List && artBytes.isNotEmpty &&
        !rejectedSessionImage) {
      // Capture the current source before updating diagnostics. Repeated
      // media-session callbacks must not undo a verified song-specific cover.
      final hasVerifiedSongCover = artworkSource == 'Exact song catalog match' &&
          !changed && art != null;
      sessionArtworkStatus = 'Received ${artBytes.length} bytes';
      if (!hasVerifiedSongCover) {
        artworkSource = 'Android media session';
        artworkStatus = 'Android media session artwork';
      }
      _artClearTimer?.cancel();
      _sessionArtRetryTimer?.cancel();
      _needsArt = false;
      // A repeated media-session callback must not overwrite a verified
      // song-specific upgrade for this same track. The original supplied
      // image remains available as fallback on the next track or failed lookup.
      if (!hasVerifiedSongCover &&
          (art == null || !listEquals(art!.bytes, artBytes))) {
        _setArt(artBytes);
      }
      // A valid media-session cover is authoritative, including YouTube Music.
      // Never replace it through an automatic catalog search. The explicit
      // placeholder rejection and missing-cover paths still search normally.
      _sessionVerificationTimer?.cancel();
    } else if (rejectedSessionImage) {
      sessionArtworkStatus = 'Known player placeholder rejected';
      final currentIsRejected = art != null &&
          artBytes is Uint8List && listEquals(art!.bytes, artBytes);
      if (changed || currentIsRejected) {
        _artToken++;
        art = null;
        artworkSource = 'None';
        _albumArtCache.remove(cacheAlbumKey);
        // Start local/catalog lookup after _trackKey has been updated.
        // Starting here captures the old track and discards the result.
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
          // Don't cancel a cover download that started for this new track
          // merely because the old cover's three-second grace period ended.
          final onlineLookupActive = _lookupInFlight.isNotEmpty;
          if (!onlineLookupActive) _artToken++;
          art = null;
          notifyListeners();
          if (!onlineLookupActive && artLookupEnabled && title.isNotEmpty) {
            unawaited(_lookupArt());
          }
        });
      }
    }
    if ((artBytes is! Uint8List || artBytes.isEmpty) && changed) {
      sessionArtworkStatus = 'Missing (no bytes in media session)';
    }
    _trackKey = key;
    // A prepared, already decoded cover is ready immediately when the
    // music app omits artwork. This never substitutes a catalog cover for
    // real media-session art supplied by Spotify/YouTube Music/etc.
    if (changed &&
        ((artBytes is! Uint8List || artBytes.isEmpty) ||
         rejectedSessionImage)) {
      final prepared = _smartPrefetchedAlbums[_smartPrefetchKey(artist, title)];
      if (prepared != null) {
        _artToken++;
        art = prepared;
        _albumArtPriorityPending = false;
        _needsArt = false;
        _artClearTimer?.cancel();
        _sessionArtRetryTimer?.cancel();
        artworkSource = 'Smart Prefetch (exact artist and song)';
        artworkStatus = 'Prepared album cover displayed immediately';
        artworkLookupState = 'Ready before track started';
        artworkFailure = 'None';
        _checkCoverflowRepeatedArtwork();
      }
    }
    // If the new track's verified session art is the SAME image, _setArt()
    // is correctly skipped. That must still release the "artwork pending"
    // gate and rerun deduplication. Same-album playback with no fresh
    // image also legitimately reuses the already displayed cover.
    if (changed && art != null &&
        ((artBytes is Uint8List && artBytes.isNotEmpty &&
            !rejectedSessionImage && listEquals(art!.bytes, artBytes)) ||
         (!albumChanged && oldArtistForCoverflow == artist &&
             (artBytes is! Uint8List || artBytes.isEmpty)))) {
      _albumArtPriorityPending = false;
    }
    if (m.containsKey('queueItems')) {
      _applyNativeCoverflowQueue(m['queueItems']);
    }
    if (changed && !_albumArtPriorityPending) {
      _checkCoverflowRepeatedArtwork();
    }
    _albumKey = albumKey;
    if (changed && artLookupEnabled && title.isNotEmpty &&
        (art == null || _needsArt) &&
        ((artBytes is! Uint8List || artBytes.isEmpty) ||
         rejectedSessionImage)) {
      // Do not wait for the old 700-ms network timer before even reading
      // the cover cache/local index. Artist assets are secondary.
      unawaited(_lookupLocalFirst());
    }
    if ((artBytes is! Uint8List || artBytes.isEmpty) && title.isNotEmpty)
      _scheduleSessionArtRetry();

    if (changed) {
      _resetLyricsLookup();
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
    _catalogReleaseTitle = '';
    _releaseLookupTrack = '';
    durationMs = 0;
    _trackKey = '';
    _albumKey = '';
    _needsArt = false;
    _albumArtPriorityPending = false;
    _localArtLookupTrack = '';
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
    _resetLyricsLookup();
    lyrics = null;
    _lyricsToken++;
    _coverflowToken++;
    _coverflowRepeatCheckSerial++;
    _coverflowQueueSignature = '';
    _coverflowCandidates = <CoverflowCover>[];
    coverflowCovers = <CoverflowCover>[];
    _coverflowSamples.clear();
    coverflowRevision++;
  }

  Future<void> _findSongCoverUpgrade(String expectedTrack) async {
    if (!artLookupEnabled || _linkReceiverActive || expectedTrack != _trackKey ||
        title.trim().isEmpty || artist.trim().isEmpty) return;
    final requestedTitle = title;
    final requestedArtist = artist;
    // Only invoked when a provisional original-song remix fallback is being
    // checked for newly available exact-remix art. Genuine player-provided
    // artwork must not enter this upgrade path automatically.
    final songKey = '${requestedArtist.trim().toLowerCase()}|${requestedTitle.trim().toLowerCase()}';
    Uint8List? bytes = _artCache[songKey];
    bytes ??= await MediaCache.getArt(songKey);
    bytes ??= await fetchSongSpecificArtwork(requestedTitle, requestedArtist);
    if (bytes == null || expectedTrack != _trackKey) return;
    final decoded = await ArtAssets.load(bytes);
    if (decoded == null || decoded.flat || expectedTrack != _trackKey) return;
    final current = art;
    if (current != null && listEquals(current.bytes, bytes)) return;
    ++_artToken;
    art = decoded;
    artworkSource = 'Exact song catalog match';
    artworkStatus = 'Song-specific cover found';
    artworkLookupState = 'Exact artist and song match';
    artworkFailure = 'None';
    // A compilation's album tag is shared by unrelated songs. Do not cache
    // this song-specific cover under that album name, or it can leak to
    // another track in the compilation.
    _artCache['${artist.trim().toLowerCase()}|${title.trim().toLowerCase()}'] = bytes;
    _originalFallbackArtCache.remove(songKey);
    MediaCache.putArt('${artist.trim().toLowerCase()}|${title.trim().toLowerCase()}', bytes);
    notifyListeners();
  }

  void _runNetwork() {
    if (title.isEmpty || _linkReceiverActive) return;
    if (artLookupEnabled && art == null) _lookupLocalFirst();
    if (artLookupEnabled && _missingAlbumTag) _resolveMissingAlbum(_trackKey);
    // The sender must resolve lyrics for the receiver even if this phone
    // uses a non-lyric theme or has its own lyric display turned off.
    if (_needsLyrics) _fetchLyrics();
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
    if (track.isEmpty || _localArtLookupTrack == track) return;
    _localArtLookupTrack = track;
    try {
      // Read the fast in-memory/disk cache and begin verified network lookup
      // concurrently with checking the local music index. Do not make a
      // potentially slow SAF read block all album-art requests.
      unawaited(_lookupArt());
      final bytes = await LocalArtwork.instance.albumArt(artist, album);
      if (token != _artToken || track != _trackKey ||
          (art != null && !_needsArt)) return;
      if (bytes != null && bytes.isNotEmpty) {
        artworkSource = 'Local artwork index';
        artworkStatus = 'Matched local album artwork';
        unawaited(_setArt(bytes));
        notifyListeners();
      }
      // No additional network request here: the concurrent one is already
      // in flight and guarded against duplicate requests.
    } finally {
      if (_localArtLookupTrack == track) _localArtLookupTrack = '';
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
      final fallbackCacheKey = 'original_fallback|$k';
      Uint8List? bytes = force ? null : _artCache[k];
      bytes ??= force || albumCacheKey.isEmpty ? null : _albumArtCache[albumCacheKey];
      bytes ??= force ? null : await MediaCache.getArt(k);
      bool originalFallback = false;
      String originalRelease = '';
      if (bytes == null && !force && hasRemixArtworkFallback(title)) {
        bytes = _originalFallbackArtCache[k] ??
            await MediaCache.getArt(fallbackCacheKey);
        originalFallback = bytes != null;
      }
      if (bytes != null) artworkSource = originalFallback
          ? 'Original song cover (remix fallback, cached)'
          : 'Memory or disk cache';
      if (bytes == null) {
        artworkStatus = 'Searching online catalogs';
        artworkLookupState = 'Searching MusicBrainz / Cover Art Archive / Fanart.tv';
        notifyListeners();
        final lookup = await fetchArtworkWithMatch(title, artist, album: album);
        bytes = lookup?.bytes;
        originalFallback = lookup?.originalSongFallback ?? false;
        originalRelease = lookup?.releaseTitle ?? '';
        if (bytes != null) {
          artworkSource = originalFallback
              ? 'Original song cover (remix fallback)'
              : 'Online catalog (Cover Art Archive or Fanart.tv)';
        }
      }
      if (token != _artToken || track != _trackKey) return;
      if (bytes != null) {
        final decoded = await ArtAssets.load(bytes);
        if (token != _artToken || track != _trackKey) return;
        if (decoded != null && !decoded.flat) {
          if (originalFallback) {
            _originalFallbackArtCache[k] = bytes;
            unawaited(MediaCache.putArt(fallbackCacheKey, bytes));
          } else {
            _artCache[k] = bytes;
            _originalFallbackArtCache.remove(k);
            _rememberAlbumArt(bytes, albumCacheKey);
            unawaited(MediaCache.putArt(k, bytes));
          }
          if (_artCache.length > 12) _artCache.remove(_artCache.keys.first);
          if (_originalFallbackArtCache.length > 12) {
            _originalFallbackArtCache.remove(_originalFallbackArtCache.keys.first);
          }
          art = decoded;
          _albumArtPriorityPending = false;
          artworkStatus = originalFallback
              ? 'Using original song cover until exact remix art is available'
              : (verifySession
                  ? 'Media-session cover verified/replaced by online catalog'
                  : 'Artwork restored from cache or online catalog');
          artworkLookupState = originalFallback
              ? 'Original song fallback (not an exact remix match)${originalRelease.isEmpty ? "" : ": $originalRelease"}'
              : 'Found and decoded';
          artworkFailure = 'None';
          _needsArt = false;
          _artClearTimer?.cancel();
          _artRetryTimer?.cancel();
          if (originalFallback) {
            _sessionVerificationTimer?.cancel();
            _sessionVerificationTimer = Timer(const Duration(seconds: 3), () {
              if (_trackKey == track) unawaited(_findSongCoverUpgrade(track));
            });
          }
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
    if (token == _artToken && track == _trackKey) {
      // A cover wasn't delivered on the first attempt. Release the
      // artist artwork queue while normal album-art retries continue.
      _albumArtPriorityPending = false;
      if (art != null) notifyListeners();
    }
    if (token == _artToken && track == _trackKey && art == null) {
      artworkStatus = _artAttempts < 4
          ? 'Artwork not found; retry ${_artAttempts}/4'
          : 'Artwork not found; automatic retries exhausted (4/4)';
      // Distinguish a missing artist/recording match from a linked release
      // with no downloadable cover, as well as transient catalog failures.
      artworkLookupState =
          '$latestArtworkCatalogDiagnostic (attempt $_artAttempts/4)';
      if (artworkFailure == 'None') {
        artworkFailure = latestArtworkCatalogDiagnostic;
      }
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

  void _resetLyricsLookup() {
    _lyricsRetryTimer?.cancel();
    _lyricsRetryTimer = null;
    _lyricsRetryAttempts = 0;
  }

  Future<void> _fetchLyrics() async {
    final token = ++_lyricsToken;
    final track = _trackKey;
    _lyricsRetryTimer?.cancel();
    _lyricsRetryTimer = null;
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
    if (token != _lyricsToken || track != _trackKey || !_needsLyrics) return;
    lyrics = found;
    notifyListeners();
    // A temporary network failure must not leave lyrics blank for the entire
    // song. Retry the same track twice, without retaining negative cache hits.
    if (found == null && active && _lyricsRetryAttempts < 2) {
      final seconds = _lyricsRetryAttempts++ == 0 ? 8 : 25;
      _lyricsRetryTimer = Timer(Duration(seconds: seconds), () {
        _lyricsRetryTimer = null;
        if (_needsLyrics && active && _trackKey == track && lyrics == null) {
          _fetchLyrics();
        }
      });
    }
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

  /// The paired sender needs timed lyrics regardless of its own displayed
  /// theme. On the head unit, received lines can still be displayed according
  /// to the user's lyrics preference.
  void setLinkLyricsSourceEnabled(bool on) {
    if (_sendLyricsOverLink == on) return;
    _sendLyricsOverLink = on;
    if (on && title.isNotEmpty && (lyrics == null || lyrics!.isEmpty)) {
      _resetLyricsLookup();
      _fetchLyrics();
    } else if (!on && !lyricsEnabled) {
      _resetLyricsLookup();
      _lyricsToken++;
      lyrics = null;
      notifyListeners();
    }
  }

  /// Apply a full ordered set of synchronized lyric lines from the verified
  /// phone. Ignore delayed packets from a prior song and prevent an in-flight
  /// local LRCLIB lookup from replacing the phone's version afterward.
  void applyLinkLyrics(String track, List<LyricLine> lines) {
    if (!_linkReceiverActive || track != _trackKey || lines.isEmpty) return;
    _resetLyricsLookup();
    _lyricsToken++;
    lyrics = List<LyricLine>.unmodifiable(lines);
    final cacheKey = '${artist.toLowerCase()}|${title.toLowerCase()}';
    _lyricsCache[cacheKey] = lyrics;
    if (_lyricsCache.length > 12) _lyricsCache.remove(_lyricsCache.keys.first);
    notifyListeners();
  }

  void setLyricsEnabled(bool on) {
    if (lyricsEnabled == on) return;
    lyricsEnabled = on;
    if (on) {
      _resetLyricsLookup();
      // A receiver may already have the synchronized lines from the phone.
      // Don't start a redundant lookup or replace those lines.
      if (title.isNotEmpty && (lyrics == null || lyrics!.isEmpty)) _fetchLyrics();
      notifyListeners();
    } else if (!_sendLyricsOverLink) {
      _resetLyricsLookup();
      lyrics = null;
      _lyricsToken++;
      notifyListeners();
    } else {
      // Keep fetching for the head unit but honor the phone's display toggle.
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
    final incomingFromMusicolet = artworkSource == 'Android media session' &&
        _sessionPlayerPackage == 'in.krosbits.musicolet';
    if (incomingFromMusicolet) {
      final hash = _imageFingerprint(bytes);
      final isPlaceholder = _automaticPlaceholderHashes.contains(hash) ||
          await MusicoletPlaceholder.matches(bytes);
      if (token != _artToken) return;
      if (isPlaceholder) {
        _automaticPlaceholderHashes.add(hash);
        // No generic player logo enters album memory or appears as artwork.
        _albumArtCache.remove(albumCacheKey);
        art = null;
        artworkSource = 'None';
        sessionArtworkStatus = 'Musicolet branded placeholder rejected';
        artworkStatus = 'Showing VYBE placeholder until a real cover is found';
        artworkLookupState = 'Looking up local and catalog artwork';
        artworkFailure = 'None';
        notifyListeners();
        if (artLookupEnabled && title.isNotEmpty) {
          unawaited(_lookupLocalFirst());
        }
        return;
      }
    }
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
    // Keep usable media-session covers available while offline.
    if (art != null) {
      _albumArtPriorityPending = false;
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
    _checkCoverflowRepeatedArtwork();
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
