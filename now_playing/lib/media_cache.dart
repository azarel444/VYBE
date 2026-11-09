import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'lyrics.dart';
import 'portable_media_cache.dart';

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

  // Keep app-private art/lyrics filenames compatible with the unsigned
  // portable cache. The same signed formatting bug affected both caches.
  static String _hash(String key) => PortableMediaCache.hashKey(key);

  // Migrate app-private files written by old builds with signed hashes so
  // installing over VYBE doesn't invalidate old album covers and lyrics.
  static String _legacyHash(String key) {
    var h = 0xcbf29ce484222325;
    for (final byte in utf8.encode(key.toLowerCase().trim())) {
      h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }

  static Future<File> _file(String kind, String key) async {
    final dir = await _directory();
    final canonical = File('${dir.path}/$kind-${_hash(key)}.dat');
    if (await canonical.exists()) return canonical;
    final legacyHash = _legacyHash(key);
    if (legacyHash != _hash(key)) {
      final legacy = File('${dir.path}/$kind-$legacyHash.dat');
      if (await legacy.exists()) {
        try {
          await legacy.rename(canonical.path);
        } catch (_) {
          try {
            await canonical.writeAsBytes(
                await legacy.readAsBytes(), flush: false);
          } catch (_) {
            return legacy;
          }
        }
      }
    }
    return canonical;
  }

  static Future<Uint8List?> getArt(String key) async {
    try {
      final file = await _file('art', key);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty && bytes.length <= 6 * 1024 * 1024) return bytes;
      }
      final restored = await PortableMediaCache.get('art', key);
      if (restored == null || restored.length > 6 * 1024 * 1024) return null;
      await file.writeAsBytes(restored, flush: false);
      return restored;
    } catch (_) { return null; }
  }

  static Future<void> putArt(String key, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 6 * 1024 * 1024) return;
    try {
      await (await _file('art', key)).writeAsBytes(bytes, flush: false);
      await _trim();
    } catch (_) {}
    // User-folder copy survives uninstall; failures leave the regular cache.
    await PortableMediaCache.put('art', key, bytes);
  }

  static Future<List<LyricLine>?> getLyrics(String key) async {
    try {
      final file = await _file('lyrics', key);
      String? contents;
      if (await file.exists()) {
        contents = await file.readAsString();
      } else {
        final restored = await PortableMediaCache.get('lyrics', key);
        if (restored == null) return null;
        contents = utf8.decode(restored);
        await file.writeAsString(contents, flush: false);
      }
      final data = jsonDecode(contents);
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
    final data = jsonEncode([for (final l in lines) [l.ms, l.text]]);
    try {
      await (await _file('lyrics', key)).writeAsString(data);
      await _trim();
    } catch (_) {}
    await PortableMediaCache.put(
        'lyrics', key, Uint8List.fromList(utf8.encode(data)));
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
