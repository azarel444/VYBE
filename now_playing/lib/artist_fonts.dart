import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// User-owned fonts stay on the user's Android device, not in the public
/// VYBE GitHub repository or distributed APK. Riot remains the default.
class ArtistFontOption {
  final String key;
  final String label;
  final String fileName;
  final String family;
  const ArtistFontOption(this.key, this.label, this.fileName, this.family);
}

class ArtistFonts extends ChangeNotifier {
  ArtistFonts._();
  static final ArtistFonts instance = ArtistFonts._();
  static const _channel = MethodChannel('vybe/artist_fonts');
  static const options = <ArtistFontOption>[
    ArtistFontOption('riot', 'VYBE Riot (original)', '', 'VYBERiot'),
    ArtistFontOption('beachScript', 'Beach Club Script', 'Beach Club Script.ttf', 'VYBEArtistBeachScript'),
    ArtistFontOption('beachSwash', 'Beach Club Swash', 'Beach Club Swash.ttf', 'VYBEArtistBeachSwash'),
    ArtistFontOption('gojira', 'Gojira Black', 'Gojira Black.ttf', 'VYBEArtistGojira'),
    ArtistFontOption('gojiraSlant', 'Gojira Black Slant', 'Gojira Black Slant.ttf', 'VYBEArtistGojiraSlant'),
    ArtistFontOption('smasher', 'Smasher', 'Smasher.ttf', 'VYBEArtistSmasher'),
    ArtistFontOption('smasherSwash', 'Smasher Swash', 'Smasher-Swash.ttf', 'VYBEArtistSmasherSwash'),
  ];

  final Set<String> _loaded = <String>{};
  Directory? _directory;

  static bool isKnown(String key) => options.any((o) => o.key == key);
  bool available(String key) => key == 'riot' || _loaded.contains(key);
  String? familyFor(String key) {
    if (key == 'riot' || !available(key)) return null;
    for (final option in options) {
      if (option.key == key) return option.family;
    }
    return null;
  }

  Future<Directory> _folder() async {
    final existing = _directory;
    if (existing != null) return existing;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/user_artist_fonts');
    await dir.create(recursive: true);
    _directory = dir;
    return dir;
  }

  Future<void> initialize() async {
    final dir = await _folder();
    for (final option in options.skip(1)) {
      final file = File('${dir.path}/${option.fileName}');
      if (!await file.exists()) continue;
      try {
        await _load(option, await file.readAsBytes());
      } catch (e) {
        debugPrint('VYBE: could not load local font ${option.label}: $e');
      }
    }
  }

  Future<void> _load(ArtistFontOption option, Uint8List bytes) async {
    if (_loaded.contains(option.key)) return;
    if (bytes.length < 100 || bytes.length > 6 * 1024 * 1024) {
      throw const FormatException('Invalid or oversized font');
    }
    final header = bytes.buffer.asByteData(bytes.offsetInBytes, bytes.lengthInBytes)
        .getUint32(0);
    if (header != 0x00010000 && header != 0x4F54544F &&
        header != 0x74727565) {
      throw const FormatException('Please choose a TTF/OTF font file');
    }
    final loader = FontLoader(option.family);
    loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
    _loaded.add(option.key);
    notifyListeners();
  }

  /// Android's file picker accepts multiple fonts in one selection. Imported
  /// files are kept in the app-private data directory and never uploaded.
  Future<List<String>> importFromDevice() async {
    final picked = await _channel.invokeMethod<List<dynamic>>('pickFonts');
    if (picked == null || picked.isEmpty) return const <String>[];
    final dir = await _folder();
    final added = <String>[];
    for (final raw in picked) {
      if (raw is! Map) continue;
      final name = raw['name'];
      final bytes = raw['bytes'];
      if (name is! String || bytes is! Uint8List) continue;
      ArtistFontOption? found;
      for (final option in options.skip(1)) {
        if (option.fileName.toLowerCase() == name.toLowerCase()) {
          found = option;
          break;
        }
      }
      if (found == null) continue;
      final option = found;
      try {
        await _load(option, bytes);
        await File('${dir.path}/${option.fileName}').writeAsBytes(bytes, flush: true);
        added.add(option.label);
      } catch (e) {
        debugPrint('VYBE: rejected ${option.label}: $e');
      }
    }
    return added;
  }
}
