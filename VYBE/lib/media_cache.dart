import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'lyrics.dart';

/// Persistent bounded disk cache. Failed lookups are not cached, allowing
/// later network retries. Files are stored in the app-private cache directory.
class MediaCache {
  static Directory? _dir;
  static Future<Directory> _directory() async {
    if (_dir != null) return _dir!;
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/vybe_media_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  static String _hash(String key) {
    // Stable FNV-1a 64-bit; no dependency on process-specific hashCode.
    var h = 0xcbf29ce484222325;
    for (final byte in utf8.encode(key.toLowerCase().trim())) {
      h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }

  static Future<File> _file(String kind, String key) async =>
      File('${(await _directory()).path}/$kind-${_hash(key)}.dat');

  static Future<Uint8List?> getArt(String key) async {
    try {
      final file = await _file('art', key);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > 6 * 1024 * 1024) return null;
      return bytes;
    } catch (_) { return null; }
  }

  static Future<void> putArt(String key, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 6 * 1024 * 1024) return;
    try {
      await (await _file('art', key)).writeAsBytes(bytes, flush: false);
      await _trim();
    } catch (_) {}
  }

  static Future<List<LyricLine>?> getLyrics(String key) async {
    try {
      final file = await _file('lyrics', key);
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString());
      if (data is! List) return null;
      final lines = <LyricLine>[];
      for (final line in data) {
        if (line is List && line.length == 2 && line[0] is int && line[1] is String) {
          lines.add(LyricLine(line[0] as int, line[1] as String));
        }
      }
      return lines.length >= 2 ? lines : null;
    } catch (_) { return null; }
  }

  static Future<void> putLyrics(String key, List<LyricLine> lines) async {
    if (lines.isEmpty) return;
    try {
      final json = jsonEncode([for (final l in lines) [l.ms, l.text]]);
      await (await _file('lyrics', key)).writeAsString(json);
      await _trim();
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final dir = await _directory();
      await for (final entity in dir.list()) {
        if (entity is File) await entity.delete();
      }
    } catch (_) {}
  }

  static Future<void> _trim() async {
    try {
      final dir = await _directory();
      final files = await dir.list().where((e) => e is File).cast<File>().toList();
      final entries = <_CacheEntry>[];
      var total = 0;
      for (final file in files) {
        final stat = await file.stat();
        total += stat.size;
        entries.add(_CacheEntry(file, stat.modified, stat.size));
      }
      if (total <= 80 * 1024 * 1024 && entries.length <= 350) return;
      entries.sort((a,b) => a.modified.compareTo(b.modified));
      var remaining = entries.length;
      for (final entry in entries) {
        if (total <= 65 * 1024 * 1024 && remaining <= 300) break;
        await entry.file.delete();
        total -= entry.size;
        remaining--;
      }
    } catch (_) {}
  }
}

class _CacheEntry {
  final File file;
  final DateTime modified;
  final int size;

  const _CacheEntry(this.file, this.modified, this.size);
}
