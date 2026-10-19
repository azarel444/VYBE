import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

/// Fanart.tv client. A user-supplied API key is required.
/// No public/test key is embedded in the shipped application.
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
      final search = Uri.https('musicbrainz.org', '/ws/2/artist/', {
        'query': 'artist:"${artist.replaceAll('"', '')}"', 'fmt': 'json', 'limit': '5',
      });
      final result = await _json(search);
      final candidates = result['artists'];
      if (candidates is! List) { lastStatus = 'MusicBrainz lookup failed'; return null; }
      String? mbid;
      for (final entry in candidates) {
        if (entry is Map && (entry['name']?.toString().toLowerCase() == cacheKey)) {
          mbid = entry['id']?.toString(); break;
        }
      }
      if (mbid == null) { lastStatus = 'Artist not matched in MusicBrainz'; return null; }
      final fanart = await _json(Uri.https('webservice.fanart.tv', '/v3/music/$mbid', {'api_key': projectKey, if (personalKey.isNotEmpty) 'client_key': personalKey}));
      final images = fanart['artistbackground'];
      if (images is! List || images.isEmpty) { lastStatus = 'Fanart.tv returned no artist background (or API request failed)'; return null; }
      final entry = images.first;
      if (entry is! Map || entry['url'] is! String) return null;
      final uri = Uri.tryParse(entry['url'] as String);
      if (uri == null || uri.scheme != 'https') return null;
      final bytes = await _bytes(uri);
      if (bytes == null) return null;
      await file.writeAsBytes(bytes, flush: false);
      _memory[cacheKey] = bytes;
      lastStatus = 'Downloaded artist background';
      return bytes;
    } catch (e) { lastStatus = 'Artwork request failed: $e'; return null; }
  }

  Future<Map<String, dynamic>> _json(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 7);
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, 'VYBE/1.9 (music artwork; contact via app publisher)');
      final res = await req.close().timeout(const Duration(seconds: 9));
      if (res.statusCode != 200) return {};
      final body = await res.transform(utf8.decoder).join();
      if (body.length > 500000) return {};
      final json = jsonDecode(body);
      return json is Map<String, dynamic> ? json : {};
    } finally { client.close(force: true); }
  }

  Future<Uint8List?> _bytes(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 7);
    try {
      final req = await client.getUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 10));
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
