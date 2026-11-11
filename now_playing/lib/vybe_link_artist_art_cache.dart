import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'portable_media_cache.dart';

/// Android's main and transparent Drive windows run separate Flutter engines.
/// Each engine has its own VybeLink singleton, so incoming artist images must
/// be shared through app-private storage, not a second Connect socket.
class LinkArtistArtworkSnapshot {
  final Uint8List bytes;
  final String version;

  const LinkArtistArtworkSnapshot(this.bytes, this.version);
}

class LinkArtistArtworkCache {
  LinkArtistArtworkCache._();

  static Future<File?> _file(String artist, String kind) async {
    final key = artist.toLowerCase().trim();
    if (key.isEmpty) return null;
    final root = await getApplicationSupportDirectory();
    final directory = Directory('${root.path}/vybe_link_artist_art');
    final hash = PortableMediaCache.hashKey(key);
    return File('${directory.path}/$kind-$hash.png');
  }

  static Future<void> save(String artist, String kind, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 6 * 1024 * 1024) return;
    if (kind != 'fanart' && kind != 'clearlogo') return;
    final target = await _file(artist, kind);
    if (target == null) return;
    try {
      await target.parent.create(recursive: true);
      // Atomic replacement keeps Drive from decoding half-written PNGs.
      final pending = File('${target.path}.writing');
      await pending.writeAsBytes(bytes, flush: true);
      await pending.rename(target.path);
    } catch (_) {
      // Disconnecting a USB drive or storage failure must not affect music.
    }
  }

  /// Returns only an updated image. Checking the file's metadata first avoids
  /// decoding the same image every time Drive polls for a new Connect packet.
  static Future<LinkArtistArtworkSnapshot?> readChanged(
      String artist, String kind, String? previousVersion) async {
    if (kind != 'fanart' && kind != 'clearlogo') return null;
    final target = await _file(artist, kind);
    if (target == null) return null;
    try {
      if (!await target.exists()) return null;
      final stat = await target.stat();
      if (stat.size <= 0 || stat.size > 6 * 1024 * 1024) return null;
      final version = '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
      if (previousVersion == version) return null;
      final bytes = await target.readAsBytes();
      if (bytes.isEmpty || bytes.length > 6 * 1024 * 1024) return null;
      return LinkArtistArtworkSnapshot(bytes, version);
    } catch (_) {
      return null;
    }
  }
}
