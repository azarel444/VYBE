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
    req.headers.set('User-Agent', 'VYBE/1.9.9 (Android music visualizer; artwork metadata lookup)');
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

// Album artwork URLs returned by iTunes are often 100x100bb.jpg. Try a
// higher-resolution variant, then the original URL if the CDN rejects it.
Future<Uint8List?> _appleArtwork(String rawUrl) async {
  final original = Uri.tryParse(rawUrl);
  if (original == null || original.scheme != 'https') return null;
  final larger = Uri.tryParse(rawUrl.replaceFirst(RegExp(r'100x100'), '600x600'));
  for (final uri in <Uri>{if (larger != null) larger, original}) {
    final bytes = await httpGetBytes(uri);
    if (bytes != null && bytes.length > 1024 && _looksLikeImage(bytes)) return bytes;
  }
  return null;
}

bool _looksLikeImage(Uint8List b) => b.length > 12 && (
  (b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) ||
  (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47) ||
  (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
   b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50)
);


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
    '$artist ${clean(title).replaceAll(RegExp(r'\s+'), ' ')}'.trim(),
    if (album.isNotEmpty) '$artist $album'.trim(),
  ].where((q) => q.isNotEmpty).toSet();
  // Album-only fallback: a valid album match must not be rejected just
  // because the song search result is for a different track on that album.
  // Apple's album entity returns the cover directly.
  if (_norm(album).isNotEmpty && _norm(artist).isNotEmpty) {
    final body = await httpGetString(Uri.https('itunes.apple.com', '/search', {
      'term': '$artist $album', 'entity': 'album', 'limit': '30',
    }));
    if (body != null) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map && decoded['results'] is List) {
          for (final entry in decoded['results'] as List) {
            if (entry is! Map) continue;
            final foundArtist = entry['artistName']?.toString() ?? '';
            final foundAlbum = entry['collectionName']?.toString() ?? '';
            final artUrl = entry['artworkUrl100']?.toString() ?? '';
            if (!_looseMatch(foundArtist, artist) ||
                _norm(foundAlbum) != _norm(album) || artUrl.isEmpty) continue;
            final bytes = await _appleArtwork(artUrl);
            if (bytes != null) return bytes;
          }
        }
      } catch (_) { /* Try the independent album catalog. */ }
    }
  }

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
        final bytes = await _appleArtwork(url);
        if (bytes != null) return bytes;
      }
    } catch (_) { /* Try another search term. */ }
  }
  // A second, independent catalog for albums missing from Apple's search.
  // Only query when both artist and album are present; title-only searches
  // frequently return the wrong release and therefore the wrong cover.
  return fetchCoverArtArchive(artist, album); 
}

/// MusicBrainz release-group search -> Cover Art Archive front image.
/// Uses no API key. Deliberately conservative: an exact artist + album match
/// is required, and unavailable images simply return null.
Future<Uint8List?> fetchCoverArtArchive(String artist, String album) async {
  if (_norm(artist).isEmpty || _norm(album).isEmpty) return null;
  try {
    String quoted(String s) => '"${s.replaceAll('"', '').trim()}"';
    final albumVariants = <String>{
      album.trim(),
      album.replaceAll(RegExp(r'\s*[\(\[][\s\S]*?(?:remaster|deluxe|anniversary|edition)[\s\S]*?[\)\]]', caseSensitive: false), '').trim(),
    }..removeWhere((s) => s.isEmpty);
    for (final albumVariant in albumVariants) {
    final query = 'releasegroup:${quoted(albumVariant)} AND artist:${quoted(artist)}';
    final body = await httpGetString(Uri.https('musicbrainz.org', '/ws/2/release-group/', {
      'query': query, 'fmt': 'json', 'limit': '12',
    }));
    if (body == null) continue;
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['release-groups'] is! List) continue;
    for (final item in decoded['release-groups'] as List) {
      if (item is! Map) continue;
      final id = item['id'];
      final name = item['title'];
      if (id is! String || name is! String || _norm(name) != _norm(albumVariant)) continue;
      final credit = item['artist-credit'];
      if (credit is! List) continue;
      final artistMatch = credit.any((part) {
        if (part is! Map) return false;
        final a = part['artist'];
        return a is Map &&
            (_norm(a['name']?.toString() ?? '') == _norm(artist) ||
             _norm(a['sort-name']?.toString() ?? '') == _norm(artist));
      });
      if (!artistMatch) continue;
      // Cover Art Archive can respond with a redirect to the hosted image.
      // httpGetBytes follows standard HttpClient redirects.
      final image = await httpGetBytes(Uri.https('coverartarchive.org',
          '/release-group/$id/front-500'));
      if (image != null && _looksLikeImage(image)) return image;
      // Some release groups have only the original front available.
      final original = await httpGetBytes(Uri.https('coverartarchive.org',
          '/release-group/$id/front'));
      if (original != null && _looksLikeImage(original)) return original;
    }
    }
  } catch (_) {
    // Absence or network failure should never break playback.
  }
  return null;
}

/// Strict song-specific cover lookup. Never fall back to an album-only search.
/// Returns null when the artist and track cannot both be matched.
Future<Uint8List?> fetchSongSpecificArtwork(String title, String artist) async {
  if (_norm(title).isEmpty || _norm(artist).isEmpty) return null;
  final term = '$artist $title';
  final body = await httpGetString(Uri.https('itunes.apple.com', '/search', {
    'term': term, 'entity': 'song', 'limit': '50',
  }));
  if (body == null) return null;
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['results'] is! List) return null;
    for (final item in decoded['results'] as List) {
      if (item is! Map) continue;
      final foundArtist = item['artistName']?.toString() ?? '';
      final foundTrack = item['trackName']?.toString() ?? '';
      final url = item['artworkUrl100']?.toString() ?? '';
      if (_norm(foundArtist) != _norm(artist) ||
          _norm(foundTrack) != _norm(title) || url.isEmpty) continue;
      return await _appleArtwork(url);
    }
  } catch (_) {}
  return null;
}
