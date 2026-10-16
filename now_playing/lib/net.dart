import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Tiny HTTPS helpers built on dart:io, so no extra packages are needed.
/// Every failure just returns null; the app works fine without a network.

Future<Uint8List?> httpGetBytes(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final req = await client.getUrl(uri);
    req.headers.set('User-Agent', 'NowPlaying/1.2');
    final res = await req.close().timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      await res.drain<void>();
      return null;
    }
    final builder = BytesBuilder();
    await for (final chunk in res.timeout(const Duration(seconds: 15))) {
      builder.add(chunk);
      if (builder.length > 6 * 1024 * 1024) return null; // sanity limit
    }
    return builder.takeBytes();
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<String?> httpGetString(Uri uri) async {
  final bytes = await httpGetBytes(uri);
  if (bytes == null) return null;
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return null;
  }
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

bool _looseMatch(String a, String b) {
  final x = _norm(a), y = _norm(b);
  if (x.isEmpty || y.isEmpty) return false;
  return x.contains(y) || y.contains(x);
}

/// Looks the track up on the iTunes Search API (free, no key) and returns
/// the album cover as image bytes, or null.
Future<Uint8List?> fetchArtwork(String title, String artist, {String album = ''}) async {
  String clean(String s) => s.replaceAll(
      RegExp(r'\s*[\(\[][^\)\]]*(?:remaster|extended|radio edit|version|mix)[^\)\]]*[\)\]]', caseSensitive: false), '').trim();
  final queries = <String>[
    '$artist $title'.trim(),
    '$artist ${clean(title)}'.trim(),
    if (album.isNotEmpty) '$artist $album'.trim(),
  ].where((q) => q.isNotEmpty).toSet();
  for (final term in queries) {
    final body = await httpGetString(Uri.https('itunes.apple.com', '/search', {
      'term': term, 'entity': 'song', 'limit': '25',
    }));
    if (body == null) continue;
    try {
      final data = jsonDecode(body);
      if (data is! Map || data['results'] is! List) continue;
      final matches = <Map>[];
      for (final item in data['results'] as List) {
        if (item is! Map || item['artworkUrl100'] is! String) continue;
        final a = item['artistName'];
        final t = item['trackName'];
        if (artist.isNotEmpty && (a is! String || !_looseMatch(a, artist))) continue;
        // Never substitute unrelated songs just because their artist matches.
        if (t is! String || !_looseMatch(clean(t), clean(title))) continue;
        matches.add(item);
      }
      matches.sort((a, b) {
        int score(Map r) =>
          (_norm(r['trackName']?.toString() ?? '') == _norm(title) ? 4 : 0) +
          (album.isNotEmpty && _looseMatch(r['collectionName']?.toString() ?? '', album) ? 2 : 0);
        return score(b).compareTo(score(a));
      });
      for (final r in matches.take(3)) {
        final url = r['artworkUrl100'] as String;
        final bytes = await httpGetBytes(Uri.parse(url.replaceFirst('100x100', '600x600')));
        if (bytes != null && bytes.isNotEmpty) return bytes;
      }
    } catch (_) { /* Try another search term. */ }
  }
  return null;
}
