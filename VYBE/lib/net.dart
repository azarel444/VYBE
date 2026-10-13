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
Future<Uint8List?> fetchArtwork(String title, String artist) async {
  final term = artist.isEmpty ? title : '$artist $title';
  final body = await httpGetString(Uri.https('itunes.apple.com', '/search', {
    'term': term,
    'entity': 'song',
    'limit': '5',
  }));
  if (body == null) return null;
  try {
    final data = jsonDecode(body);
    if (data is! Map) return null;
    final results = data['results'];
    if (results is! List) return null;
    for (final r in results) {
      if (r is! Map) continue;
      final url = r['artworkUrl100'];
      if (url is! String) continue;
      final a = r['artistName'];
      if (artist.isNotEmpty && !(a is String && _looseMatch(a, artist))) {
        continue; // avoid showing the cover of a different artist's song
      }
      return httpGetBytes(Uri.parse(url.replaceFirst('100x100', '600x600')));
    }
  } catch (_) {}
  return null;
}
