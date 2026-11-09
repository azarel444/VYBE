import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

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
}
