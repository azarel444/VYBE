import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'riot_approved_spacing.dart';

/// Riot-only, editable optical corrections. NEVER modifies the bundled
/// TTF, artwork cache, or general VYBE settings. All values are em units.
/// The v1/v2 pair settings are migrated to deltas from the baked baseline,
/// so older saved corrections are NEVER applied twice after an update.
class RiotSpacingStore extends ChangeNotifier {
  RiotSpacingStore._();
  static final RiotSpacingStore instance = RiotSpacingStore._();
  static const String _key = 'vybe_riot_spacing_overrides_v3';
  static const String _priorKey = 'vybe_riot_spacing_overrides_v2';
  static const String _oldKey = 'vybe_riot_spacing_overrides_v1';

  final Map<String, double> _pairs = <String, double>{};
  final Map<String, double> _x = <String, double>{};
  final Map<String, double> _y = <String, double>{};
  final Map<String, double> _advance = <String, double>{};

  Timer? _saveDebounce;
  Future<void>? _loading;
  bool _edited = false;

  Map<String, double> get pairs => Map.unmodifiable(_pairs);
  Map<String, double> get horizontal => Map.unmodifiable(_x);
  Map<String, double> get vertical => Map.unmodifiable(_y);
  Map<String, double> get after => Map.unmodifiable(_advance);

  static bool isGlyph(String text) {
    if (text.runes.length != 1) return false;
    final rune = text.runes.first;
    return rune > 32 && rune != 127 &&
        !(rune >= 0x80 && rune <= 0x9F);
  }
  static bool isPair(String text) {
    final glyphs = text.runes.map(String.fromCharCode).toList();
    return glyphs.length == 2 && glyphs.every(isGlyph);
  }

  double deltaFor(String pair) => _pairs[pair.toUpperCase()] ?? 0;
  double xFor(String glyph) => _x[glyph.toUpperCase()] ?? 0;
  double yFor(String glyph) => _y[glyph.toUpperCase()] ?? 0;
  double afterFor(String glyph) => _advance[glyph.toUpperCase()] ?? 0;

  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = prefs.getString(_key);
      final previous = prefs.getString(_priorKey);
      final legacy = prefs.getString(_oldKey);
      // The editor may be opened before storage finishes loading: never
      // clobber a newly edited pair with a delayed read.
      if (!_edited) {
        if (current != null && current.isNotEmpty) {
          importJson(current, persist: false);
        } else {
          final old = previous != null && previous.isNotEmpty ? previous : legacy;
          if (old != null && old.isNotEmpty) {
            // v1/v2 values were applied on top of the old factory kerning;
            // importing them as residuals neutralizes the newly baked
            // approved defaults for exactly those pairs the user changed.
            importJson(old, persist: false);
            _scheduleSave();
          }
        }
      }
    } catch (error) {
      debugPrint('Riot spacing: load failed: $error');
    }
  }

  double _clamp(double value) =>
      ((value.isFinite ? value : 0) * 100).roundToDouble()
          .clamp(-60.0, 60.0) / 100.0;

  void _set(Map<String, double> destination, String glyph,
      double value, bool pair) {
    final key = glyph.toUpperCase();
    if (!(pair ? isPair(key) : isGlyph(key))) return;
    final v = _clamp(value);
    if (v.abs() < .005) {
      if (destination.remove(key) == null) return;
    } else {
      if (destination[key] == v) return;
      destination[key] = v;
    }
    _edited = true;
    notifyListeners();
    _scheduleSave();
  }

  void setPair(String pair, double value) => _set(_pairs, pair, value, true);
  void setHorizontal(String glyph, double value) =>
      _set(_x, glyph, value, false);
  void setVertical(String glyph, double value) =>
      _set(_y, glyph, value, false);
  void setAfter(String glyph, double value) =>
      _set(_advance, glyph, value, false);

  void resetPair(String pair) => setPair(pair, 0);
  void resetGlyph(String glyph) {
    setHorizontal(glyph, 0);
    setVertical(glyph, 0);
    setAfter(glyph, 0);
  }
  void resetAll() {
    if (_pairs.isEmpty && _x.isEmpty && _y.isEmpty && _advance.isEmpty) return;
    _pairs.clear();
    _x.clear();
    _y.clear();
    _advance.clear();
    _edited = true;
    notifyListeners();
    _scheduleSave();
  }

  String exportJson() {
    Map<String, double> sorted(Map<String, double> input) =>
        Map.fromEntries(input.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)));
    return const JsonEncoder.withIndent('  ').convert({
      'version': 3,
      'description': 'VYBE Riot corrections (em); negative = closer/left/up',
      'pairs': sorted(_pairs),
      'horizontal': sorted(_x),
      'vertical': sorted(_y),
      'after': sorted(_advance),
    });
  }

  void importJson(String json, {bool persist = true}) {
    final decoded = jsonDecode(json);
    if (decoded is! Map || decoded['pairs'] is! Map) {
      throw const FormatException('Expected Riot spacing JSON with pairs.');
    }

    Map<String, double> decode(dynamic raw, bool isPairValue) {
      final result = <String, double>{};
      if (raw == null) return result;
      if (raw is! Map) throw const FormatException('Invalid spacing section.');
      if (raw.length > 8192) throw const FormatException('Too many overrides.');
      for (final entry in raw.entries) {
        final glyph = entry.key.toString().toUpperCase();
        final value = entry.value;
        if (!(isPairValue ? isPair(glyph) : isGlyph(glyph)) ||
            value is! num || !value.isFinite) {
          throw FormatException('Invalid Riot character or spacing.');
        }
        final adjusted = _clamp(value.toDouble());
        if (adjusted.abs() >= .005) result[glyph] = adjusted;
      }
      return result;
    }

    final nextPairs = decode(decoded['pairs'], true);
    // Old exports contain total edits from the pre-bake renderer. Current
    // exports store residual adjustments from the approved defaults. This
    // also safely handles pasting a user's v2 JSON after upgrading.
    final version = decoded['version'];
    if (version is num && version.toInt() < 3) {
      for (final key in nextPairs.keys.toList()) {
        final baked = riotApprovedPairOffsets[key] ?? 0;
        final difference = _clamp(nextPairs[key]! - baked);
        if (difference.abs() < .005) {
          nextPairs.remove(key);
        } else {
          nextPairs[key] = difference;
        }
      }
    }
    final nextX = decode(decoded['horizontal'], false);
    final nextY = decode(decoded['vertical'], false);
    final nextAfter = decode(decoded['after'], false);
    _pairs..clear()..addAll(nextPairs);
    _x..clear()..addAll(nextX);
    _y..clear()..addAll(nextY);
    _advance..clear()..addAll(nextAfter);
    _edited = persist;
    notifyListeners();
    if (persist) _scheduleSave();
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(saveNow());
    });
  }

  Future<void> saveNow() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, exportJson());
    } catch (error) {
      debugPrint('Riot spacing: save failed: $error');
    }
  }
}
