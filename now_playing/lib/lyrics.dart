import 'dart:convert';

import 'net.dart';

class LyricLine {
  final int ms;
  final String text;
  const LyricLine(this.ms, this.text);
}

/// Parses "[mm:ss.xx] words" lines. Lines can carry several timestamps.
List<LyricLine> parseLrc(String s) {
  final re = RegExp(r'\[(\d+):(\d+(?:\.\d+)?)\]');
  final out = <LyricLine>[];
  for (final raw in s.split('\n')) {
    final matches = re.allMatches(raw).toList();
    if (matches.isEmpty) continue;
    final text = raw.substring(matches.last.end).trim();
    for (final m in matches) {
      final min = int.parse(m.group(1)!);
      final sec = double.parse(m.group(2)!);
      out.add(LyricLine((min * 60000 + sec * 1000).round(), text));
    }
  }
  out.sort((a, b) => a.ms.compareTo(b.ms));
  return out;
}

/// Finds time-synced lyrics on LRCLIB (free, no key). Returns null when the
/// song has none or the network is unavailable.
Future<List<LyricLine>?> fetchSyncedLyrics(
    String title, String artist, int durationMs) async {
  // LRCLIB is queried independently of any music player's lyrics screen.
  // Prefer exact metadata, then retry with release/mix suffixes removed.
  String clean(String value) => value.replaceAll(
      RegExp(r'\s*\([^)]*(?:mix|version|remaster|edit|live|radio|extended)[^)]*\)',
          caseSensitive: false), '').trim();
  final titles = <String>{title.trim(), clean(title)}.where((t) => t.isNotEmpty);
  final normalizedArtist = artist.trim();
  final candidates = <Map>[];
  for (final track in titles) {
    final urls = [
      Uri.https('lrclib.net', '/api/search', {
        'track_name': track,
        if (normalizedArtist.isNotEmpty) 'artist_name': normalizedArtist,
      }),
      Uri.https('lrclib.net', '/api/search', {
        'q': '$normalizedArtist $track'.trim(),
      }),
    ];
    for (final url in urls) {
      final body = await httpGetString(url);
      if (body == null) continue;
      try {
        final data = jsonDecode(body);
        if (data is List) candidates.addAll(data.whereType<Map>());
      } catch (_) { /* Try the next lookup. */ }
      if (candidates.isNotEmpty) break;
    }
    if (candidates.isNotEmpty) break;
  }
  String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final requested = norm(clean(title));
  final requestedArtist = norm(normalizedArtist);
  Map? best;
  double bestScore = double.infinity;
  for (final item in candidates) {
    final synced = item['syncedLyrics'];
    if (synced is! String || synced.isEmpty) continue;
    final candidateTitle = norm(clean(item['trackName']?.toString() ?? ''));
    final candidateArtist = norm(item['artistName']?.toString() ?? '');
    if (requested.isEmpty || candidateTitle != requested) continue;
    if (requestedArtist.isNotEmpty &&
        candidateArtist != requestedArtist &&
        !candidateArtist.contains(requestedArtist) &&
        !requestedArtist.contains(candidateArtist)) continue;
    final dur = item['duration'];
    final diff = (durationMs > 0 && dur is num)
        ? (dur * 1000 - durationMs).abs().toDouble() : 0.0;
    if (durationMs > 0 && diff > 15000) continue;
    if (diff < bestScore) {
      bestScore = diff;
      best = item;
    }
  }
  if (best == null) return null;
  final lines = parseLrc(best['syncedLyrics'] as String);
  return lines.length >= 2 ? lines : null;
}
