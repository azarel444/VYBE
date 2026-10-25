import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-approved Android document tree. The index stores URIs, never image bytes.
class LocalArtwork {
  LocalArtwork._();
  static final instance = LocalArtwork._();
  static const _channel = MethodChannel('vybe/local_art');
  final List<Map<String, String>> _files = [];
  bool _loaded = false;
  String status = 'No local artwork scan yet';
  int get count => _files.length;

  static String normalize(String value) {
    var text = value.toLowerCase().trim();
    const aliases = <String, String>{
      'p!nk': 'pink', 'ac/dc': 'acdc', 'guns n roses': 'guns n roses',
    };
    text = text.replaceAll(RegExp(r'[\\u0300-\\u036f]'), '');
    text = text.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    text = text.replaceAll(RegExp(r'\\s+'), ' ');
    return aliases[text] ?? text;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = prefs.getString('localArtworkIndex');
      if (raw != null) {
        for (final entry in jsonDecode(raw) as List) {
          _files.add(Map<String, String>.from(entry as Map));
        }
      }
      status = '${_files.length} indexed local images';
    } catch (_) { status = 'Local index needs rebuilding'; }
  }

  Future<bool> chooseFolderAndScan() async {
    final selected = await _channel.invokeMethod<bool>('chooseFolder') ?? false;
    if (selected) await scan();
    return selected;
  }

  Future<int> scan() async {
    final result = await _channel.invokeMethod<List<dynamic>>('scan') ?? [];
    final next = <Map<String, String>>[];
    for (final item in result) {
      if (item is Map) next.add(Map<String, String>.from(item));
    }
    _files..clear()..addAll(next);
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('localArtworkIndex', jsonEncode(_files));
    status = '${_files.length} indexed local images';
    return _files.length;
  }

  Future<Uint8List?> fanart(String artist) async {
    await load();
    final key = normalize(artist);
    if (key.isEmpty) return null;
    // Only accept a specifically named artist background, not a random
    // cover from an artist's album folder.
    for (final entry in _files) {
      final file = normalize((entry['name'] ?? '').replaceFirst(
        RegExp(r'\\.(jpg|jpeg|png|webp)$', caseSensitive: false), ''));
      final folder = normalize((entry['folder'] ?? '').split('/').last);
      final named = file == key || file == '${key} fanart' ||
          file == '${key} background' || file == '${key} artist';
      final dedicatedFolder = folder == key &&
          (file == 'fanart' || file == 'artist' || file == 'background');
      if (named || dedicatedFolder) return _read(entry);
    }
    return null;
  }

  Future<Uint8List?> albumArt(String artist, String album) async {
    await load();
    final a = normalize(artist), b = normalize(album);
    if (a.isEmpty || b.isEmpty) return null;
    for (final entry in _files) {
      final path = normalize(entry['folder'] ?? '');
      final file = normalize((entry['name'] ?? '').replaceFirst(
        RegExp(r'\\.(jpg|jpeg|png|webp)$', caseSensitive: false), ''));
      // Require both artist and album to prevent generic compilation
      // and playlist covers from being applied to unrelated tracks.
      if (path.contains(a) && path.contains(b) &&
          (file == 'cover' || file == 'folder' || file == 'front' ||
              file == b || file == '${a} ${b}')) {
        return _read(entry);
      }
    }
    return null;
  }

  Future<Uint8List?> _read(Map<String, String> entry) async {
    try {
      return await _channel.invokeMethod<Uint8List>('read', {'uri': entry['uri']});
    } catch (_) { return null; }
  }
}
