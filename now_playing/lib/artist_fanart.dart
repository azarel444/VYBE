import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

/// Fanart.tv client. Receives the development credential from app settings.
/// Production builds must use a server-side proxy instead.
class ArtistFanartCache {
  final Map<String, Uint8List?> _memory = {};
  final Map<String, Future<Uint8List?>> _inFlight = {};
  final Map<String, List<String>> _artistIds = {};
  String lastStatus = 'Not checked';
  static String diagnostics = 'No fanart lookup recorded yet';
  final Map<String, String> _requestDetails = {};

  Future<Uint8List?> get(String artist, String projectKey, {String personalKey = ''}) {
    final key = artist.toLowerCase().trim();
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final future = _getUnshared(artist, projectKey, personalKey: personalKey);
    _inFlight[key] = future;
    future.whenComplete(() { _inFlight.remove(key); });
    return future;
  }

  Future<Uint8List?> _getUnshared(String artist, String projectKey, {String personalKey = ''}) async {
    final watch = Stopwatch()..start();
    final stages = <String>[];
    void record(String stage) => stages.add('$stage: ${watch.elapsedMilliseconds} ms elapsed');
    void report(String status) {
      lastStatus = status;
      diagnostics = 'Artist: $artist\\nStatus: $status\\n${stages.join('\\n')}\\nTotal: ${watch.elapsedMilliseconds} ms';
    }
    final cacheKey = artist.toLowerCase().trim();
    if (projectKey.trim().isEmpty) { report('Missing project API key'); return null; }
    if (_memory[cacheKey] != null) { record('Memory cache hit'); report('Cached artwork'); return _memory[cacheKey]; }
    try {
      record('Memory cache miss');
      final folder = Directory('${(await getApplicationSupportDirectory()).path}/artist_fanart');
      await folder.create(recursive: true);
      final name = base64Url.encode(utf8.encode(cacheKey)).replaceAll('=', '');
      final file = File('${folder.path}/$name.jpg');
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        _memory[cacheKey] = bytes;
        record('Disk cache hit');
        report('Loaded cached image');
        return bytes;
      }
      record('Disk cache miss');
      // Cache resolved MusicBrainz IDs on disk independently of the image.
      // This also helps when a previous image download failed.
      final idFile = File('${folder.path}/$name.ids.json');
      final ids = <String>[];
      final remembered = _artistIds[cacheKey];
      if (remembered != null) {
        ids.addAll(remembered);
        record('Artist IDs memory cache hit');
      } else if (await idFile.exists()) {
        try {
          final decoded = jsonDecode(await idFile.readAsString());
          if (decoded is List) {
            ids.addAll(decoded.whereType<String>().where((id) =>
                RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id)).take(2));
          }
        } catch (_) {}
        if (ids.isNotEmpty) {
          _artistIds[cacheKey] = List.of(ids);
          record('Artist IDs disk cache hit');
        }
      }
      if (ids.isEmpty) {
        record('Artist IDs cache miss');
        final search = Uri.https('musicbrainz.org', '/ws/2/artist/', {
          'query': 'artist:"${artist.replaceAll('"', '')}"',
          'fmt': 'json', 'limit': '15',
        });
        final result = await _json(search);
        record('MusicBrainz lookup completed: ${_requestDetails['musicbrainz.org'] ?? 'unknown'}');
        final candidates = result['artists'];
        if (candidates is! List) {
          report('MusicBrainz lookup unavailable');
          return null;
        }
        // Match harmless typography variations such as Rendez Vous versus
        // Rendez-Vous, while still requiring the full artist name.
        String normalize(String name) => name.toLowerCase().trim()
            .replaceAll(RegExp(r'[-‐‑‒–—_]'), ' ')
            .replaceAll(RegExp(r'[.\u2018\u2019]'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .replaceFirst(RegExp(r'^the '), '')
            .trim();
        for (final entry in candidates) {
          if (entry is! Map) continue;
          final candidateName = entry['name']?.toString();
          final candidateId = entry['id']?.toString();
          if (candidateName != null && candidateId != null &&
              normalize(candidateName) == normalize(cacheKey) &&
              !ids.contains(candidateId)) {
            ids.add(candidateId);
          }
        }
        if (ids.isEmpty) {
          // A quoted search for "Sheila E." may not return "Sheila E".
          // Retry the punctuation-normalized spelling, but still require a
          // complete normalized artist-name match before accepting an ID.
          final alternative = normalize(artist);
          if (alternative.isNotEmpty && alternative != artist.toLowerCase().trim()) {
            try {
              final retry = await _json(Uri.https('musicbrainz.org', '/ws/2/artist/', {
                'query': 'artist:"${alternative.replaceAll('"', '')}"',
                'fmt': 'json', 'limit': '15',
              }));
              final candidates = retry['artists'];
              if (candidates is List) {
                for (final entry in candidates) {
                  if (entry is! Map) continue;
                  final candidateName = entry['name']?.toString();
                  final candidateId = entry['id']?.toString();
                  if (candidateName != null && candidateId != null &&
                      normalize(candidateName) == normalize(cacheKey) &&
                      !ids.contains(candidateId)) {
                    ids.add(candidateId);
                  }
                }
              }
              record('Normalized artist lookup completed');
            } catch (e) {
              record('Normalized artist lookup failed: $e');
            }
          }
        }
        if (ids.isEmpty) {
          report('Artist not matched in MusicBrainz');
          return null;
        }
        _artistIds[cacheKey] = ids.take(2).toList();
        try {
          await idFile.writeAsString(jsonEncode(_artistIds[cacheKey]));
          record('Artist IDs cached to disk');
        } catch (_) {
          record('Artist IDs kept in memory only');
        }
      }
      record('Matched ${ids.length} MusicBrainz artist IDs');
      // Fanart.tv artist records are independent: query both candidates in
      // parallel instead of waiting for a timeout before trying the second.
      final responses = await Future.wait(ids.take(2).map((mbid) =>
          _json(Uri.https('webservice.fanart.tv', '/v3/music/$mbid', {
            'api_key': projectKey,
            if (personalKey.isNotEmpty) 'client_key': personalKey,
          }))));
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
        final first = await Future.wait(urls.take(2).map((uri) async {
          try { return await _bytes(uri); } catch (_) { return null; }
        }));
        for (final result in first) {
          if (result != null && result.isNotEmpty) { bytes = result; break; }
        }
        record('First image downloads completed');
        if (bytes == null) {
          for (final uri in urls.skip(2)) {
            try { bytes = await _bytes(uri); } catch (_) { bytes = null; }
            if (bytes != null && bytes.isNotEmpty) break;
          }
        }
      }
      record('Image download attempts completed');
      if (bytes == null || bytes.isEmpty) {
        report('No usable background across ${ids.take(2).length} artist IDs '
            '($noBackground without images, $lookupFailures request failures)');
        return null;
      }
      await file.writeAsBytes(bytes, flush: false);
      _memory[cacheKey] = bytes;
      record('Disk cache write completed (${bytes.length} bytes)');
      report('Downloaded artist background');
      return bytes;
    } catch (e) { report('Artwork request failed: $e'); return null; }
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
