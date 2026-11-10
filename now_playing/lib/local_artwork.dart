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
  int savedArtworkCount = 0;
  static const _libraryKey = 'artwork_inventory_v1';

  static String _assetKey(Map<String, String> entry) =>
      '${entry['folder'] ?? ''}|${entry['name'] ?? ''}';

  static String _assetCacheName(Map<String, String> entry) =>
      PortableMediaCache.fileName('localimage', _assetKey(entry));

  Future<List<Map<String, String>>> _readBackedUpIndex() async {
    try {
      final bytes = await PortableMediaCache.get('localindex', _libraryKey);
      if (bytes == null) return [];
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! List) return [];
      return _validatedEntries(data);
    } catch (_) { return []; }
  }

  /// Reconnect the Saved Artwork Library immediately after selecting its
  /// folder, including a fresh installation with no attached music drive.
  Future<int> reconnectSavedArtwork() async {
    await load();
    final backedUp = await _readBackedUpIndex();
    final seen = _files.map(_assetKey).toSet();
    for (final entry in backedUp) {
      if (seen.add(_assetKey(entry))) {
        _files.add(entry);
      } else {
        final existing = _files.firstWhere(
            (value) => _assetKey(value) == _assetKey(entry));
        if (entry['cacheName'] == _assetCacheName(entry)) {
          existing['cacheName'] = entry['cacheName']!;
        }
      }
    }
    savedArtworkCount = backedUp.length;
    status = '${_files.length} local images; '
        '$savedArtworkCount recovered from Saved Artwork Library';
    return savedArtworkCount;
  }

  /// Copy image bytes and a manifest into the selected persistent folder.
  /// The manifest provides artist/album names even if the original music USB
  /// drive is gone. Backups are never deleted when a scan finds fewer files.
  Future<int> mirrorIndexedArtwork() async {
    await load();
    if (_files.isEmpty) return 0;
    final payload = <Map<String, String>>[];
    for (final entry in _files) {
      if ((entry['uri'] ?? '').isEmpty) continue;
      payload.add({
        'uri': entry['uri']!,
        'cacheName': _assetCacheName(entry),
      });
    }
    Set<String> saved = {};
    try {
      final names = await _channel.invokeMethod<List<dynamic>>(
          'mirrorLocalArtwork', {'entries': payload});
      saved = (names ?? []).whereType<String>().toSet();
    } catch (error) {
      status = 'Artwork backup interrupted: $error';
    }
    for (final entry in _files) {
      final name = _assetCacheName(entry);
      if (saved.contains(name)) entry['cacheName'] = name;
    }
    final backedUp = _files.where((entry) =>
        entry['cacheName'] == _assetCacheName(entry)).toList();
    savedArtworkCount = backedUp.length;
    if (backedUp.isNotEmpty) {
      await PortableMediaCache.put('localindex', _libraryKey,
          Uint8List.fromList(utf8.encode(jsonEncode(backedUp))));
    }
    status = '${_files.length} images indexed; '
        '$savedArtworkCount preserved in VYBE Cache';
    return savedArtworkCount;
  }

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
      final restored = await _readBackedUpIndex();
      final keys = _files.map(_assetKey).toSet();
      for (final entry in restored) {
        if (keys.add(_assetKey(entry))) {
          _files.add(entry);
        } else {
          final found = _files.firstWhere(
              (value) => _assetKey(value) == _assetKey(entry));
          found['cacheName'] = entry['cacheName'] ?? '';
        }
      }
      savedArtworkCount = restored.length;
      status = '${_files.length} indexed local images; '
          '$savedArtworkCount saved artwork backups';
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
      final name = item['name'];
      final folder = item['folder'];
      final storedName = item['cacheName'];
      if (name is! String || folder is! String) continue;
      final hasSource = uri is String && uri.startsWith('content://');
      final expectedName = PortableMediaCache.fileName(
          'localimage', '$folder|$name');
      final hasCopy = storedName is String && storedName == expectedName;
      if (!hasSource && !hasCopy) continue;
      entries.add(<String, String>{
        'uri': hasSource ? uri : '',
        'name': name,
        'folder': folder,
        if (hasCopy) 'cacheName': expectedName,
      });
    }
    return entries;
  }

  Future<bool> chooseFolder() async {
    final selected =
        await _channel.invokeMethod<bool>('chooseFolder') ?? false;
    if (selected) {
      // Keep the independent cache location unchanged. The selected music
      // folder may be on removable storage; its scan is mirrored separately.
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
    // A missing USB drive must never erase copies of previously indexed art.
    final previousBackups = await _readBackedUpIndex();
    final known = next.map(_assetKey).toSet();
    for (final backup in previousBackups) {
      if (known.add(_assetKey(backup))) {
        next.add(backup);
      } else {
        final source = next.firstWhere(
            (entry) => _assetKey(entry) == _assetKey(backup));
        source['cacheName'] = backup['cacheName'] ?? '';
      }
    }
    final saved = await _channel.invokeMethod<bool>('writeIndex',
        <String, Object>{'json': jsonEncode(next)});
    if (saved != true) {
      throw StateError('Could not save local artwork index');
    }
    _files..clear()..addAll(next);
    _loaded = true;
    // Indexing must finish independently of copying images to the saved
    // artwork folder. Mirroring many files over Android SAF can take minutes;
    // keep it in the background instead of holding onboarding hostage.
    unawaited(mirrorIndexedArtwork());
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

  Future<List<Uint8List>> fanartGallery(String artist,
      {bool rescanOnMiss = true}) async {
    await load();
    final key = normalize(artist);
    if (key.isEmpty) return [];
    var matches = _files.where((entry) => _matchesFanart(entry, key)).toList();
    if (matches.isEmpty && rescanOnMiss &&
        _rescanAttemptedFor.add('fanart:$key')) {
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
  Future<Uint8List?> clearLogo(String artist,
      {bool rescanOnMiss = true}) async {
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
    if (matches.isEmpty && rescanOnMiss &&
        _rescanAttemptedFor.add('logo:$key')) {
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
    final uri = entry['uri'] ?? '';
    if (uri.startsWith('content://')) {
      try {
        final bytes = await _channel.invokeMethod<Uint8List>(
            'read', {'uri': uri});
        if (bytes != null && bytes.isNotEmpty) return bytes;
      } catch (_) {}
    }
    if (entry['cacheName'] == _assetCacheName(entry)) {
      return PortableMediaCache.get('localimage', _assetKey(entry));
    }
    return null;
  }
}
