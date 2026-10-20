import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

/// Fanart.tv client. Receives the development credential from app settings.
/// Production builds must use a server-side proxy instead.
class ArtistFanartCache {
  final Map<String, Uint8List?> _memory = {};
  String lastStatus = 'Not checked';

  Future<Uint8List?> get(String artist, String projectKey, {String personalKey = ''}) async {
    final cacheKey = artist.toLowerCase().trim();
    if (projectKey.trim().isEmpty) { lastStatus = 'Missing project API key'; return null; }
    if (_memory[cacheKey] != null) { lastStatus = 'Cached artwork'; return _memory[cacheKey]; }
    try {
      final folder = Directory('${(await getApplicationSupportDirectory()).path}/artist_fanart');
      await folder.create(recursive: true);
      final name = base64Url.encode(utf8.encode(cacheKey)).replaceAll('=', '');
      final file = File('${folder.path}/$name.jpg');
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        _memory[cacheKey] = bytes;
        lastStatus = 'Loaded cached image';
        return bytes;
      }
      // Search more than one candidate: MusicBrainz may return duplicate names,
      // legacy entries, or artist records without Fanart.tv coverage.
      final search = Uri.https('musicbrainz.org', '/ws/2/artist/', {
        'query': 'artist:"${artist.replaceAll('"', '')}"', 'fmt': 'json', 'limit': '15',
      });
      final result = await _json(search);
      final candidates = result['artists'];
      if (candidates is! List) { lastStatus = 'MusicBrainz lookup unavailable'; return null; }
      final ids = <String>[];
      for (final entry in candidates) {
        if (entry is! Map) continue;
        final candidateName = entry['name']?.toString().toLowerCase().trim();
        final candidateId = entry['id']?.toString();
        if (candidateName == cacheKey && candidateId != null && candidateId.isNotEmpty && !ids.contains(candidateId)) {
          ids.add(candidateId);
        }
      }
      if (ids.isEmpty) { lastStatus = 'Artist not matched in MusicBrainz'; return null; }
      Uint8List? bytes;
      var noBackground = 0;
      var lookupFailures = 0;
      for (final mbid in ids.take(2)) {
        final response = await _json(Uri.https('webservice.fanart.tv', '/v3/music/$mbid', {
          'api_key': projectKey,
          if (personalKey.isNotEmpty) 'client_key': personalKey,
        }));
        if (response.isEmpty) { lookupFailures++; continue; }
        final images = response['artistbackground'];
        if (images is! List || images.isEmpty) { noBackground++; continue; }
        for (final entry in images.take(3)) {
          if (entry is! Map || entry['url'] is! String) continue;
          final uri = Uri.tryParse(entry['url'] as String);
          if (uri == null || uri.scheme != 'https') continue;
          bytes = await _bytes(uri);
          if (bytes != null && bytes.isNotEmpty) break;
        }
        if (bytes != null && bytes.isNotEmpty) break;
      }
      if (bytes == null || bytes.isEmpty) {
        lastStatus = 'No usable background across ${ids.take(2).length} artist IDs '
            '($noBackground without images, $lookupFailures request failures)';
        return null;
      }
      await file.writeAsBytes(bytes, flush: false);
      _memory[cacheKey] = bytes;
      lastStatus = 'Downloaded artist background';
      return bytes;
    } catch (e) { lastStatus = 'Artwork request failed: $e'; return null; }
  }

  Future<Map<String, dynamic>> _json(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, 'VYBE/1.9 (music artwork; contact via app publisher)');
      final res = await req.close().timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return {};
      final body = await res.transform(utf8.decoder).join();
      if (body.length > 500000) return {};
      final json = jsonDecode(body);
      return json is Map<String, dynamic> ? json : {};
    } finally { client.close(force: true); }
  }

  Future<Uint8List?> _bytes(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.getUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 7));
      if (res.statusCode != 200) return null;
      final out = BytesBuilder(copy: false);
      await for (final chunk in res) {
        out.add(chunk);
        if (out.length > 6 * 1024 * 1024) return null;
      }
      return out.takeBytes();
    } finally { client.close(force: true); }
  }
}
