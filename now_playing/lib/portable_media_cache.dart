import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Optional offline mirror in a user-selected music folder.
///
/// Android's Storage Access Framework owns this folder. Files stay there
/// after VYBE is uninstalled; selecting the same folder on a fresh install
/// reconnects the app to its saved album covers, fanart, clearlogos and
/// synced lyrics. The internal caches are still used first for speed.
///
/// The native bridge owns document-tree operations. Only hashed names enter
/// the VYBE Cache directory; artist and song names never become filenames.
class PortableMediaCache {
  PortableMediaCache._();
  static const MethodChannel _channel = MethodChannel('vybe/local_art');

  /// Last observed cache hit/miss or write result, for support diagnostics.
  static String lastReadStatus = 'No persistent cache read yet';
  static String lastWriteStatus = 'No persistent cache write yet';

  /// FNV-1a encoded as exactly SIXTEEN unsigned hexadecimal digits.
  /// Dart's signed 64-bit int.toRadixString(16) produced a minus sign for
  /// ~half the keys, including "disturbed". The Android cache validator
  /// rejected those names and earlier code silently discarded the failure.
  /// Two unsigned 32-bit pieces preserve old valid filenames.
  static String hashKey(String key) {
    var h = 0xcbf29ce484222325;
    for (final byte in utf8.encode(key.toLowerCase().trim())) {
      h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    final high = (h >>> 32).toRadixString(16).padLeft(8, '0');
    final low = (h & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    return '$high$low';
  }

  static String _filename(String kind, String key) =>
      '${kind}_${hashKey(key)}.bin';

  /// Map legacy signed app-private filename hashes to valid portable names.
  static String? _canonicalStoredHash(String old) {
    if (RegExp(r'^[0-9a-f]{16}$').hasMatch(old)) return old;
    if (!RegExp(r'^0*-[0-9a-f]{1,16}$').hasMatch(old)) return null;
    try {
      final signIndex = old.indexOf('-');
      final magnitude = BigInt.parse(old.substring(signIndex + 1), radix: 16);
      if (magnitude <= BigInt.zero || magnitude > (BigInt.one << 63)) {
        return null;
      }
      return ((BigInt.one << 64) - magnitude)
          .toRadixString(16).padLeft(16, '0');
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> get(String kind, String key) async {
    final name = _filename(kind, key);
    final clock = Stopwatch()..start();
    try {
      final value = await _channel.invokeMethod<Uint8List>('cacheRead',
          {'name': name});
      if (value == null || value.isEmpty || value.length > 12 * 1024 * 1024) {
        lastReadStatus = 'MISS $name in ${clock.elapsedMilliseconds}ms';
        return null;
      }
      lastReadStatus = 'HIT $name, ${value.length} bytes in ${clock.elapsedMilliseconds}ms';
      return value;
    } catch (error) {
      lastReadStatus = 'ERROR $name: $error';
      return null; // Artwork lookup can proceed without persistent storage.
    }
  }

  static Future<void> put(String kind, String key, Uint8List bytes) async {
    final name = _filename(kind, key);
    if (bytes.isEmpty || bytes.length > 12 * 1024 * 1024) {
      lastWriteStatus = 'SKIPPED $name: invalid size ${bytes.length}';
      return;
    }
    try {
      final saved = await _channel.invokeMethod<bool>('cacheWrite', {
        'name': name,
        'bytes': bytes,
      });
      lastWriteStatus = saved == true
          ? 'SAVED $name, ${bytes.length} bytes'
          : 'FAILED $name: Android rejected cacheWrite';
    } catch (error) {
      lastWriteStatus = 'FAILED $name: $error';
    }
  }

  /// When the user first grants a music folder, migrate already-downloaded
  /// app-private files into it as well. Without this, only future downloads
  /// would survive a later uninstall. Runs asynchronously from folder setup.
  static Future<void> backupExisting() async {
    Future<void> mirror(File file, String filename) async {
      try {
        if (await file.length() > 12 * 1024 * 1024) return;
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) return;
        final saved = await _channel.invokeMethod<bool>('cacheWrite', {
          'name': filename,
          'bytes': bytes,
        });
        if (saved != true) {
          lastWriteStatus = 'FAILED BACKUP $filename: Android rejected cacheWrite';
        }
      } catch (_) {
        // A read-only cloud provider or unplugged drive cannot break setup.
      }
    }

    try {
      final root = await getApplicationSupportDirectory();
      final basic = Directory('${root.path}/vybe_media_cache');
      if (await basic.exists()) {
        await for (final item in basic.list(followLinks: false)) {
          if (item is! File) continue;
          final name = item.uri.pathSegments.last;
          final found = RegExp(r'^(art|lyrics)-(.+)\.dat$')
              .firstMatch(name);
          if (found == null) continue;
          final canonical = _canonicalStoredHash(found[2]!);
          if (canonical == null) continue;
          await mirror(item, '${found[1]}_$canonical.bin');
        }
      }
      final fanart = Directory('${root.path}/artist_fanart');
      if (!await fanart.exists()) return;
      await for (final item in fanart.list(followLinks: false)) {
        if (item is! File) continue;
        final filename = item.uri.pathSegments.last;
        String encoded;
        String kind;
        int? imageNumber;
        if (filename.endsWith('.clearlogo.png')) {
          encoded = filename.substring(0,
              filename.length - '.clearlogo.png'.length);
          kind = 'clearlogo';
        } else if (filename.contains('.gallery.') &&
            filename.endsWith('.jpg')) {
          final match = RegExp(r'^(.*?)\.gallery\.([0-9]+)\.jpg$')
              .firstMatch(filename);
          if (match == null) continue;
          encoded = match[1]!;
          imageNumber = int.tryParse(match[2]!);
          if (imageNumber == null) continue;
          kind = 'fanart_gallery';
        } else if (filename.endsWith('.jpg')) {
          encoded = filename.substring(0, filename.length - 4);
          kind = 'fanart';
        } else {
          continue;
        }
        try {
          final padded = encoded.padRight(
              ((encoded.length + 3) ~/ 4) * 4, '=');
          final artist = utf8.decode(base64Url.decode(padded));
          if (artist.isEmpty) continue;
          final key = imageNumber == null ? artist : '$artist:$imageNumber';
          await mirror(item, _filename(kind, key));
        } catch (_) {
          // Ignore files not created by the VYBE fanart cache.
        }
      }
    } catch (_) {}
  }

}
