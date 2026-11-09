import 'dart:async';
import 'dart:convert';
import 'portable_media_cache.dart';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// User-approved Android document tree. The index stores URIs, never image bytes.
class LocalArtwork {
  LocalArtwork._();
  static final instance = LocalArtwork._();
  static const _channel = MethodChannel('vybe/local_art');
  final List<Map<String, String>> _files = [];
  bool _loaded = false;
  Future<int>? _scanInFlight;
  // Increments after an explicit user scan so the active artist can refresh.
  int manualScanGeneration = 0;
  final Set<String> _rescanAttemptedFor = <String>{};
  String status = 'No local artwork scan yet';
  int get count => _files.length;

  static String normalize(String value) {
    var text = value.toLowerCase().trim();
    const aliases = <String, String>{
      'p!nk': 'pink', 'ac/dc': 'acdc', 'guns n roses': 'guns n roses',
    };
    // Match artist aliases before stripping punctuation: otherwise P!nk
    // becomes "p nk" and can never match a pinkfanart.jpg filename.
    if (aliases.containsKey(text)) return aliases[text]!;
    // Fold common Latin accents before ASCII-only filename matching.
    // Dart strings are not automatically Unicode-decomposed: stripping
    // combining marks alone would discard a precomposed 'é' entirely.
    const latinFolds = <String, String>{
      'à':'a','á':'a','â':'a','ã':'a','ä':'a','å':'a','æ':'ae',
      'ç':'c','è':'e','é':'e','ê':'e','ë':'e',
      'ì':'i','í':'i','î':'i','ï':'i','ð':'d',
      'ñ':'n','ò':'o','ó':'o','ô':'o','õ':'o','ö':'o','ø':'o',
      'ù':'u','ú':'u','û':'u','ü':'u',
      'ý':'y','ÿ':'y','þ':'th','ß':'ss','œ':'oe','ł':'l',
    };
    text = text.split('').map((c) => latinFolds[c] ?? c).join();
    text = text.replaceAll(RegExp(r'[\u0300-\u036f]'), '');
    text = text.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    return aliases[text] ?? text;
  }

  /// The large artwork index is kept in an atomic native file, not the
  /// Flutter preferences map. The native reader migrates existing installs
  /// without deleting the selected SAF folder or any theme settings.
  Future<void> load() async {
    if (_loaded) return;
    try {
      final raw = await _channel.invokeMethod<String>('readIndex');
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is! List) throw const FormatException('Invalid artwork index');
        final entries = _validatedEntries(decoded);
        _files..clear()..addAll(entries);
      }
      status = '${_files.length} indexed local images';
    } catch (error) {
      _files.clear();
      status = 'Local index needs rebuilding: $error';
    } finally {
      _loaded = true;
    }
  }

  static List<Map<String, String>> _validatedEntries(List<dynamic> raw) {
    final entries = <Map<String, String>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final uri = item['uri'];
      if (uri is! String || !uri.startsWith('content://')) continue;
      entries.add(<String, String>{
        'uri': uri,
        'name': item['name'] is String ? item['name'] as String : '',
        'folder': item['folder'] is String ? item['folder'] as String : '',
      });
    }
    return entries;
  }

  Future<bool> chooseFolder() async {
    final selected =
        await _channel.invokeMethod<bool>('chooseFolder') ?? false;
    if (selected) {
      // The original app-private caches may already hold hundreds of images.
      // Back them up to the selected music folder as well, without blocking
      // onboarding or the artwork index scan.
      unawaited(PortableMediaCache.backupExisting());
    }
    return selected;
  }

  Future<bool> chooseFolderAndScan() async {
    final selected = await chooseFolder();
    if (selected) await scan();
    return selected;
  }

  /// Automatic lookup rescans share an in-flight scan. A user-requested
  /// rescan waits for it and then runs again, so newly added files are not
  /// skipped. Never replace a working index until the new one is persisted.
  Future<int> scan({bool manual = true}) {
    final pending = _scanInFlight;
    if (pending != null) {
      if (!manual) return pending;
      return pending.catchError((Object _) => count)
          .then((_) => scan(manual: true));
    }
    final work = _scanOnce();
    _scanInFlight = work;
    return work.whenComplete(() {
      if (identical(_scanInFlight, work)) _scanInFlight = null;
    }).then((indexed) {
      if (manual) {
        _rescanAttemptedFor.clear();
        manualScanGeneration++;
      }
      return indexed;
    });
  }

  Future<int> _scanOnce() async {
    final result = await _channel.invokeMethod<List<dynamic>>('scan') ?? [];
    final next = _validatedEntries(result);
    final saved = await _channel.invokeMethod<bool>('writeIndex',
        <String, Object>{'json': jsonEncode(next)});
    if (saved != true) {
      throw StateError('Could not save local artwork index');
    }
    _files..clear()..addAll(next);
    _loaded = true;
    status = '${_files.length} indexed local images';
    return _files.length;
  }

  /// Exact artist match with optional numeric suffixes, never a loose prefix.
  /// Examples: Prince.jpg, Prince2.jpg, Prince fanart 3.jpg, or
  /// Music/Prince/fanart2.jpg. Avoid treating album covers as fanart.
  bool _matchesFanart(Map<String, String> entry, String artistKey) {
    final name = (entry['name'] ?? '').replaceFirst(
        RegExp(r'\.(jpg|jpeg|png|webp)$', caseSensitive: false), '');
    final compactName = normalize(name).replaceAll(' ', '');
    final compactArtist = artistKey.replaceAll(' ', '');
    final folder = normalize((entry['folder'] ?? '').split('/').last);
    // Music/fanart/artistnamefanart.jpg and numbered variants.
    final exact = RegExp('^' + RegExp.escape(compactArtist) +
        r'(?:fanart|background)?[0-9]*$').hasMatch(compactName);
    final inArtistFolder = folder == artistKey &&
        RegExp(r'^(?:fanart|background|artist)[0-9]*$')
            .hasMatch(compactName);
    return exact || inArtistFolder;
  }

  Future<List<Uint8List>> fanartGallery(String artist) async {
    await load();
    final key = normalize(artist);
    if (key.isEmpty) return [];
    var matches = _files.where((entry) => _matchesFanart(entry, key)).toList();
    if (matches.isEmpty && _rescanAttemptedFor.add('fanart:$key')) {
      try {
        await scan(manual: false);
        matches = _files.where((entry) => _matchesFanart(entry, key)).toList();
      } catch (e) {
        status = 'Local artwork rescan failed: $e';
      }
    }
    final images = <Uint8List>[];
    for (final entry in matches) {
      final bytes = await _read(entry);
      if (bytes != null && bytes.isNotEmpty) images.add(bytes);
    }
    if (matches.isEmpty) {
      status = 'No local fanart matches for $artist in ${_files.length} indexed images';
    } else if (images.isNotEmpty) {
      status = 'Loaded ${images.length} local fanart images for $artist';
    } else if (matches.isNotEmpty && images.isEmpty) {
      status = 'Found ${matches.length} fanart files for $artist but could not read them';
    }
    return images;
  }

  Future<Uint8List?> fanart(String artist) async {
    final gallery = await fanartGallery(artist);
    return gallery.isEmpty ? null : gallery.first;
  }

  /// Local logos use the same compact artist naming as fanart:
  /// Music/fanart/breakingbenjaminclearlogo.png.
  /// PNG preserves transparency; legacy logo names remain supported.
  Future<Uint8List?> clearLogo(String artist) async {
    await load();
    final key = normalize(artist);
    if (key.isEmpty) return null;
    final compactArtist = key.replaceAll(' ', '');
    var matches = _files.where((entry) {
      final filename = entry['name'] ?? '';
      if (!filename.toLowerCase().endsWith('.png')) return false;
      final basename = filename.substring(0, filename.length - 4);
      final compactName = normalize(basename).replaceAll(' ', '');
      final folder = normalize((entry['folder'] ?? '').split('/').last);
      return compactName == '${compactArtist}clearlogo' ||
          compactName == '${compactArtist}logo' ||
          (folder == key && (compactName == 'clearlogo' || compactName == 'logo'));
    }).toList();
    if (matches.isEmpty && _rescanAttemptedFor.add('logo:$key')) {
      try {
        await scan(manual: false);
        matches = _files.where((entry) {
          final filename = entry['name'] ?? '';
          if (!filename.toLowerCase().endsWith('.png')) return false;
          final basename = filename.substring(0, filename.length - 4);
          final compactName = normalize(basename).replaceAll(' ', '');
          final folder = normalize((entry['folder'] ?? '').split('/').last);
          return compactName == '${compactArtist}clearlogo' ||
              compactName == '${compactArtist}logo' ||
              (folder == key && (compactName == 'clearlogo' || compactName == 'logo'));
        }).toList();
      } catch (e) {
        status = 'Local clearlogo rescan failed: $e';
      }
    }
    for (final entry in matches) {
      final bytes = await _read(entry);
      if (bytes != null && bytes.isNotEmpty) return bytes;
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
        RegExp(r'\.(jpg|jpeg|png|webp)$', caseSensitive: false), ''));
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
