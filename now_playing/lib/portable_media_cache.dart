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

  static String _hash(String key) {
    var h = 0xcbf29ce484222325;
    final bytes = utf8.encode(key.toLowerCase().trim());
    for (final b in bytes) {
      h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }

  static String _filename(String kind, String key) =>
      '${kind}_${_hash(key)}.bin';

  static Future<Uint8List?> get(String kind, String key) async {
    try {
      final value = await _channel.invokeMethod<Uint8List>('cacheRead',
          {'name': _filename(kind, key)});
      if (value == null || value.isEmpty || value.length > 12 * 1024 * 1024) {
        return null;
      }
      return value;
    } catch (_) {
      // Selecting a writable folder is optional. Read-only providers, absent
      // permissions and removed storage must not interrupt playback.
      return null;
    }
  }

  static Future<void> put(String kind, String key, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 12 * 1024 * 1024) return;
    try {
      await _channel.invokeMethod<bool>('cacheWrite', {
        'name': _filename(kind, key),
        'bytes': bytes,
      });
    } catch (_) {
      // Keep the normal app-private cache working even if the user-selected
      // document provider cannot accept writes.
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
        await _channel.invokeMethod<bool>('cacheWrite', {
          'name': filename,
          'bytes': bytes,
        });
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
          final found = RegExp(r'^(art|lyrics)-([a-f0-9]{16})\.dat$')
              .firstMatch(name);
          if (found == null) continue;
          await mirror(item, '${found[1]}_${found[2]}.bin');
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
