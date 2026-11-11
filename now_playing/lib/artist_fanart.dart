import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'portable_media_cache.dart';

/// Fanart.tv client. Receives the development credential from app settings.
/// Production builds must use a server-side proxy instead.
class ArtistFanartCache {
  final Map<String, Uint8List?> _memory = {};
  final Map<String, Future<Uint8List?>> _inFlight = {};
  final Map<String, List<String>> _artistIds = {};
  final Set<String> _confirmedNameMisses = {};

  /// True only when a completed MusicBrainz search could not verify an
  /// exact artist with this whole name. Do not split a recognized duo.
  bool confirmedArtistNameMiss(String artist) =>
      _confirmedNameMisses.contains(artist.toLowerCase().trim());
  String lastStatus = 'Not checked';
  static String diagnostics = 'No fanart lookup recorded yet';
  final Map<String, String> _requestDetails = {};

  final Map<String, Uint8List> _logoMemory = {};
  final Map<String, Future<List<String>>> _artistIdInFlight = {};
  final Map<String, Future<List<Map<String, dynamic>>>> _metadataInFlight = {};

  static String _normalizeArtist(String name) => name.toLowerCase().trim()
      .replaceAll(RegExp(r'[-‐‑‒–—_]'), ' ')
      .replaceAll(RegExp(r'\s*&\s*'), ' and ')
      .replaceAll(RegExp(r'[.\u2018\u2019]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceFirst(RegExp(r'^the '), '')
      .trim();

  /// Resolve the artist ID independently of image downloads. Both artwork
  /// paths share this Future instead of making the clearlogo wait for fanart
  /// bytes (which can take tens of seconds on a slow CDN).
  Future<List<String>> _artistIdsFor(
      String artist, Directory folder, String encodedName) {
    final key = artist.toLowerCase().trim();
    final cached = _artistIds[key];
    if (cached != null && cached.isNotEmpty) {
      return Future<List<String>>.value(cached);
    }
    final pending = _artistIdInFlight[key];
    if (pending != null) return pending;
    final lookup = _resolveArtistIds(artist, folder, encodedName);
    _artistIdInFlight[key] = lookup;
    lookup.then((_) {
      if (identical(_artistIdInFlight[key], lookup)) {
        _artistIdInFlight.remove(key);
      }
    }, onError: (Object _) {
      if (identical(_artistIdInFlight[key], lookup)) {
        _artistIdInFlight.remove(key);
      }
    });
    return lookup;
  }

  Future<List<String>> _resolveArtistIds(
      String artist, Directory folder, String encodedName) async {
    final key = artist.toLowerCase().trim();
    final file = File('${folder.path}/$encodedName.ids.json');
    final ids = <String>[];
    try {
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List) {
          ids.addAll(decoded.whereType<String>().where((id) =>
              RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id)).take(2));
        }
      }
    } catch (_) {}
    if (ids.isNotEmpty) {
      _artistIds[key] = List.of(ids);
      return ids;
    }

    var completedSearch = false;
    final wanted = _normalizeArtist(artist);
    Future<void> search(String term) async {
      final data = await _json(Uri.https('musicbrainz.org', '/ws/2/artist/', {
        'query': 'artist:"${term.replaceAll('"', '')}"',
        'fmt': 'json', 'limit': '15',
      }));
      completedSearch = true;
      final artists = data['artists'];
      if (artists is! List) return;
      for (final candidate in artists) {
        if (candidate is! Map) continue;
        final candidateId = candidate['id']?.toString() ?? '';
        final candidateName = candidate['name']?.toString() ?? '';
        if (_normalizeArtist(candidateName) == wanted &&
            RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(candidateId) &&
            !ids.contains(candidateId)) {
          ids.add(candidateId);
        }
      }
    }

    try {
      await search(artist);
    } catch (_) {}
    if (ids.isEmpty && wanted != key) {
      try { await search(wanted); } catch (_) {}
    }
    if (ids.isEmpty) {
      if (completedSearch) _confirmedNameMisses.add(key);
      return const <String>[];
    }
    _confirmedNameMisses.remove(key);
    final verified = ids.take(2).toList();
    _artistIds[key] = verified;
    unawaited(file.writeAsString(jsonEncode(verified)).then((_) {},
        onError: (Object _) {}));
    return verified;
  }

  Future<List<Map<String, dynamic>>> _artistMetadata(
      String artist, String projectKey, String personalKey,
      List<String> ids) {
    final cacheKey = '${artist.toLowerCase().trim()}|$projectKey|$personalKey';
    final pending = _metadataInFlight[cacheKey];
    if (pending != null) return pending;
    final request = Future.wait(ids.take(2).map((id) async {
      try {
        return await _json(Uri.https('webservice.fanart.tv',
            '/v3/music/$id', {
          'api_key': projectKey,
          if (personalKey.isNotEmpty) 'client_key': personalKey,
        }));
      } catch (_) {
        return <String, dynamic>{};
      }
    }));
    _metadataInFlight[cacheKey] = request;
    request.then((data) {
      // Keep successful responses in memory for the other artwork type.
      // Failures must be retried rather than cached for the session.
      if (data.every((item) => item.isEmpty) &&
          identical(_metadataInFlight[cacheKey], request)) {
        _metadataInFlight.remove(cacheKey);
      }
      if (_metadataInFlight.length > 30) {
        _metadataInFlight.remove(_metadataInFlight.keys.first);
      }
    }, onError: (Object _) {
      if (identical(_metadataInFlight[cacheKey], request)) {
        _metadataInFlight.remove(cacheKey);
      }
    });
    return request;
  }

  /// A responsive CDN must not be held hostage by a slower candidate.
  Future<Uint8List?> _firstAvailableImage(List<Uri> urls) async {
    if (urls.isEmpty) return null;
    final result = Completer<Uint8List?>();
    var remaining = urls.length;
    for (final uri in urls) {
      _bytes(uri).then((image) {
        if (image != null && image.isNotEmpty && !result.isCompleted) {
          result.complete(image);
        }
      }, onError: (Object _) {}).whenComplete(() {
        remaining--;
        if (remaining == 0 && !result.isCompleted) result.complete(null);
      });
    }
    return result.future;
  }

  /// Return existing fanart immediately; never consult MusicBrainz or Fanart.tv.
  /// Called before the optional full local-artwork index scan after reinstall.
  Future<Uint8List?> getCachedFanart(String artist) async {
    final key = artist.toLowerCase().trim();
    if (key.isEmpty) return null;
    final memory = _memory[key];
    if (memory != null && memory.isNotEmpty) return memory;
    try {
      final folder = Directory('${(await getApplicationSupportDirectory()).path}/artist_fanart');
      final name = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
      final file = File('${folder.path}/$name.jpg');
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          _memory[key] = bytes;
          lastStatus = 'Internal fanart cache hit';
          return bytes;
        }
      }
      final restored = await PortableMediaCache.get('fanart', key);
      if (restored != null && restored.isNotEmpty) {
        // The external music-folder copy survives an app uninstall.
        await folder.create(recursive: true);
        try { await file.writeAsBytes(restored, flush: false); } catch (_) {}
        _memory[key] = restored;
        lastStatus = 'Persistent music-folder fanart cache hit';
        return restored;
      }
    } catch (e) {
      lastStatus = 'Cached fanart read failed: $e';
    }
    return null;
  }

  /// Same cache-only lookup for transparent clearlogos. Do not make network
  /// requests or rescan the user's music library before displaying a hit.
  Future<Uint8List?> getCachedClearLogo(String artist) async {
    final key = artist.toLowerCase().trim();
    if (key.isEmpty) return null;
    final memory = _logoMemory[key];
    if (memory != null && memory.isNotEmpty) return memory;
    try {
      final folder = Directory('${(await getApplicationSupportDirectory()).path}/artist_fanart');
      final name = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
      final file = File('${folder.path}/$name.clearlogo.png');
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          _logoMemory[key] = bytes;
          lastStatus = 'Internal clearlogo cache hit';
          return bytes;
        }
      }
      final restored = await PortableMediaCache.get('clearlogo', key);
      if (restored != null && restored.isNotEmpty) {
        await folder.create(recursive: true);
        try { await file.writeAsBytes(restored, flush: false); } catch (_) {}
        _logoMemory[key] = restored;
        lastStatus = 'Persistent artwork-folder clearlogo cache hit';
        return restored;
      }
    } catch (e) {
      lastStatus = 'Cached clearlogo read failed: $e';
    }
    return null;
  }

  Future<Uint8List?> get(String artist, String projectKey,
      {String personalKey = '', bool cacheChecked = false}) {
    final key = artist.toLowerCase().trim();
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final future = _getUnshared(artist, projectKey,
        personalKey: personalKey, cacheChecked: cacheChecked);
    _inFlight[key] = future;
    future.whenComplete(() { _inFlight.remove(key); });
    return future;
  }

  Future<Uint8List?> _getUnshared(String artist, String projectKey,
      {String personalKey = '', bool cacheChecked = false}) async {
    final watch = Stopwatch()..start();
    final stages = <String>[];
    void record(String stage) => stages.add('$stage: ${watch.elapsedMilliseconds} ms elapsed');
    void report(String status) {
      lastStatus = status;
      diagnostics = 'Artist: $artist\nStatus: $status\n${stages.join('\n')}\nTotal: ${watch.elapsedMilliseconds} ms';
    }
    final cacheKey = artist.toLowerCase().trim();
    if (_memory[cacheKey] != null) { record('Memory cache hit'); report('Cached artwork'); return _memory[cacheKey]; }
    try {
      record('Memory cache miss');
      final folder = Directory('${(await getApplicationSupportDirectory()).path}/artist_fanart');
      await folder.create(recursive: true);
      final name = base64Url.encode(utf8.encode(cacheKey)).replaceAll('=', '');
      final file = File('${folder.path}/$name.jpg');
      if (!cacheChecked) {
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) {
            _memory[cacheKey] = bytes;
            record('Disk cache hit');
            report('Loaded cached image');
            return bytes;
          }
        }
        final restored = await PortableMediaCache.get('fanart', cacheKey);
        if (restored != null && restored.isNotEmpty) {
          _memory[cacheKey] = restored;
          unawaited(file.writeAsBytes(restored, flush: false).then((_) {},
              onError: (Object _) {}));
          report('Restored artist fanart from saved artwork folder');
          return restored;
        }
      }
      if (projectKey.trim().isEmpty) {
        report('Missing project API key; no downloaded art found');
        return null;
      }
      record('Disk cache miss');
      // Shared ID resolution finishes independently from the fanart image
      // download so clearlogo retrieval can run simultaneously.
      final ids = await _artistIdsFor(artist, folder, name);
      if (ids.isEmpty) {
        report('No verified MusicBrainz artist ID available');
        return null;
      }
      record('Matched ${ids.length} MusicBrainz artist IDs');
      final responses = await _artistMetadata(
          artist, projectKey, personalKey, ids);
      record('Fanart.tv metadata completed (${responses.length} requests): ${_requestDetails['webservice.fanart.tv'] ?? 'unknown'}');
      Uint8List? bytes;
      var noBackground = 0;
      var lookupFailures = 0;
      final urls = <Uri>[];
      for (final response in responses) {
        if (response.isEmpty) { lookupFailures++; continue; }
        final images = response['artistbackground'];
        if (images is! List || images.isEmpty) { noBackground++; continue; }
        for (final entry in images.take(3)) {
          if (entry is! Map || entry['url'] is! String) continue;
          final uri = Uri.tryParse(entry['url'] as String);
          if (uri != null && uri.scheme == 'https' && !urls.contains(uri)) {
            urls.add(uri);
          }
        }
      }
      // Request the first two image candidates together, so a slow/broken
      // image CDN does not block the usable image behind it. Preserve the
      // existing sequential fallback for remaining candidates.
      record('Found ${urls.length} background URLs');
      if (urls.isNotEmpty) {
        // First valid image wins; do not wait for a slower CDN download when
        // another verified background is already available.
        bytes = await _firstAvailableImage(urls.take(3).toList());
        record('First available artist image downloaded');
        if (bytes == null && urls.length > 3) {
          bytes = await _firstAvailableImage(urls.skip(3).take(3).toList());
        }
      }
      record('Image download attempts completed');
      if (bytes == null || bytes.isEmpty) {
        report('No usable background across ${ids.take(2).length} artist IDs '
            '($noBackground without images, $lookupFailures request failures)');
        return null;
      }
      _memory[cacheKey] = bytes;
      // Show downloaded artwork before the potentially slow persistent SAF
      // backup finishes, preserving both app-private and selected-folder copies.
      unawaited(file.writeAsBytes(bytes, flush: false).then((_) {},
          onError: (Object _) {}));
      unawaited(PortableMediaCache.put('fanart', cacheKey, bytes));
      record('Background available (${bytes.length} bytes), cache saving separately');
      report('Downloaded artist background');
      return bytes;
    } catch (e) { report('Artwork request failed: $e'); return null; }
  }


  /// Load additional artist backgrounds for a randomized slideshow. The first
  /// image remains managed by get(), preserving existing fallback behavior.
  Future<List<Uint8List>> getGallery(String artist, String projectKey,
      {String personalKey = '', int maxImages = 10}) async {
    final key = artist.toLowerCase().trim();
    if (key.isEmpty) return [];
    final folder = Directory('${(await getApplicationSupportDirectory()).path}/artist_fanart');
    await folder.create(recursive: true);
    final name = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    final result = <Uint8List>[];
    final first = await get(artist, projectKey, personalKey: personalKey);
    if (first == null) return result;
    result.add(first);
    // Restore all previously downloaded gallery images from disk first.
    // This works without internet, and avoids requiring a Fanart.tv lookup
    // before an offline slideshow can start.
    for (var i = 1; i < maxImages; i++) {
      final cached = File('${folder.path}/$name.gallery.$i.jpg');
      try {
        final bytes = await cached.exists()
            ? await cached.readAsBytes()
            : await PortableMediaCache.get('fanart_gallery', '$key:$i');
        if (bytes != null && bytes.isNotEmpty) {
          if (!await cached.exists()) await cached.writeAsBytes(bytes);
          result.add(bytes);
        }
      } catch (_) {}
    }
    if (result.length >= maxImages) return result;
    final idsFile = File('${folder.path}/$name.ids.json');
    var ids = _artistIds[key] ?? <String>[];
    if (ids.isEmpty && await idsFile.exists()) {
      try {
        ids = (jsonDecode(await idsFile.readAsString()) as List).whereType<String>().take(2).toList();
      } catch (_) {}
    }
    if (ids.isEmpty) {
      try {
        final lookup = await _json(Uri.https('musicbrainz.org', '/ws/2/artist/', {
          'query': 'artist:"${artist.replaceAll('"', '')}"',
          'fmt': 'json',
          'limit': '15',
        }));
        String normalize(String value) => value.toLowerCase().trim()
            .replaceAll(RegExp(r'[-‐-‒–—_]'), ' ')
            .replaceAll(RegExp(r'[.\u2018\u2019]'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .replaceFirst(RegExp(r'^the '), '').trim();
        final candidates = lookup['artists'];
        if (candidates is List) {
          for (final entry in candidates) {
            if (entry is! Map) continue;
            final id = entry['id']?.toString();
            final artistName = entry['name']?.toString();
            if (id != null && artistName != null &&
                normalize(artistName) == normalize(artist) &&
                RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id) &&
                !ids.contains(id)) {
              ids.add(id);
              if (ids.length >= 2) break;
            }
          }
        }
        if (ids.isNotEmpty) {
          _artistIds[key] = List.of(ids);
          await idsFile.writeAsString(jsonEncode(ids));
        }
      } catch (error) {
        lastStatus = 'Gallery ID lookup failed: $error';
      }
    }
    if (ids.isEmpty) return result;
    final urls = <Uri>[];
    for (final id in ids.take(2)) {
      try {
        final data = await _json(Uri.https('webservice.fanart.tv', '/v3/music/$id', {
          'api_key': projectKey,
          if (personalKey.isNotEmpty) 'client_key': personalKey,
        }));
        final backgrounds = data['artistbackground'];
        if (backgrounds is List) {
          for (final entry in backgrounds) {
            if (entry is! Map || entry['url'] is! String) continue;
            final uri = Uri.tryParse(entry['url'] as String);
            if (uri != null && uri.scheme == 'https' && !urls.contains(uri)) urls.add(uri);
          }
        }
      } catch (_) {}
    }
    // Skip the first URL, which the existing get() method normally caches.
    // Cached gallery images are reusable without another download.
    for (var i = 1; i < urls.length && result.length < maxImages; i++) {
      final file = File('${folder.path}/$name.gallery.$i.jpg');
      Uint8List? bytes;
      try {
        bytes = await file.exists() ? await file.readAsBytes() : await _bytes(urls[i]);
        if (bytes != null && bytes.isNotEmpty) {
          if (!await file.exists()) await file.writeAsBytes(bytes);
          await PortableMediaCache.put('fanart_gallery', '$key:$i', bytes);
          result.add(bytes);
        }
      } catch (_) {}
    }
    return result;
  }

  /// Download Fanart.tv HD music clearlogo, with a persistent offline cache.
  Future<Uint8List?> getClearLogo(String artist, String projectKey,
      {String personalKey = '', bool cacheChecked = false}) async {
    if (artist.trim().isEmpty) return null;
    final key = artist.toLowerCase().trim();
    final folder = Directory('${(await getApplicationSupportDirectory()).path}/artist_fanart');
    await folder.create(recursive: true);
    final name = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    final file = File('${folder.path}/$name.clearlogo.png');
    if (!cacheChecked) {
      final memory = _logoMemory[key];
      if (memory != null && memory.isNotEmpty) return memory;
      if (await file.exists()) {
        try {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) {
            _logoMemory[key] = bytes;
            return bytes;
          }
        } catch (_) {}
      }
      final restored = await PortableMediaCache.get('clearlogo', key);
      if (restored != null && restored.isNotEmpty) {
        _logoMemory[key] = restored;
        unawaited(file.writeAsBytes(restored).then((_) {},
            onError: (Object _) {}));
        return restored;
      }
    }
    if (projectKey.isEmpty) return null;
    // Resolve the artist ID without waiting for artist fanart image bytes.
    final ids = await _artistIdsFor(artist, folder, name);
    if (ids.isEmpty) return null;
    final responses = await _artistMetadata(
        artist, projectKey, personalKey, ids);
    final urls = <Uri>[];
    for (final data in responses) {
      for (final category in <String>['hdmusiclogo', 'musiclogo']) {
        final entries = data[category];
        if (entries is! List) continue;
        for (final entry in entries) {
          if (entry is! Map || entry['url'] is! String) continue;
          final uri = Uri.tryParse(entry['url'] as String);
          if (uri != null && uri.scheme == 'https' && !urls.contains(uri)) {
            urls.add(uri);
          }
        }
      }
    }
    Uint8List? image = await _firstAvailableImage(urls.take(3).toList());
    if (image == null && urls.length > 3) {
      image = await _firstAvailableImage(urls.skip(3).toList());
    }
    if (image != null && image.isNotEmpty) {
      _logoMemory[key] = image;
      unawaited(file.writeAsBytes(image).then((_) {},
          onError: (Object _) {}));
      unawaited(PortableMediaCache.put('clearlogo', key, image));
      return image;
    }
    return null;
  }

  Future<Map<String, dynamic>> _json(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 6));
      req.headers.set(HttpHeaders.userAgentHeader, 'VYBE/1.9 (music artwork; contact via app publisher)');
      final res = await req.close().timeout(const Duration(seconds: 6));
      _requestDetails[uri.host] = 'HTTP ${res.statusCode}';
      if (res.statusCode != 200) return {};
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 8));
      if (body.length > 500000) { _requestDetails[uri.host] = 'Response too large'; return {}; }
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) { _requestDetails[uri.host] = 'Unexpected JSON structure'; return {}; }
      _requestDetails[uri.host] = 'HTTP 200, JSON parsed';
      return json;
    } catch (e) {
      _requestDetails[uri.host] = '${e.runtimeType}: $e';
      rethrow;
    } finally { client.close(force: true); }
  }

  Future<Uint8List?> _bytes(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.getUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 7));
      if (res.statusCode != 200) return null;
      final out = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(const Duration(seconds: 10))) {
        out.add(chunk);
        if (out.length > 6 * 1024 * 1024) return null;
      }
      return out.takeBytes();
    } finally { client.close(force: true); }
  }
}
