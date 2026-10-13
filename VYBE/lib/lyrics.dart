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
  final body = await httpGetString(Uri.https('lrclib.net', '/api/search', {
    'track_name': title,
    if (artist.isNotEmpty) 'artist_name': artist,
  }));
  if (body == null) return null;
  try {
    final data = jsonDecode(body);
    if (data is! List) return null;
    Map? best;
    var bestDiff = 1e12;
    for (final item in data) {
      if (item is! Map) continue;
      final synced = item['syncedLyrics'];
      if (synced is! String || synced.isEmpty) continue;
      final dur = item['duration'];
      final diff = (durationMs > 0 && dur is num)
          ? (dur * 1000 - durationMs).abs().toDouble()
          : 0.0;
      if (diff < bestDiff) {
        bestDiff = diff;
        best = item;
      }
    }
    if (best == null) return null;
    if (durationMs > 0 && bestDiff > 5000) return null; // probably a different cut
    final lines = parseLrc(best['syncedLyrics'] as String);
    return lines.length >= 2 ? lines : null;
  } catch (_) {
    return null;
  }
}
