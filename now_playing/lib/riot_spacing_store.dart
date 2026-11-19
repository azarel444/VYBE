import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Adjustable optical spacing added to the existing Riot renderer.
/// Values are in font-size em units: negative brings pairs together,
/// positive moves them apart. The original pair-specific corrections stay
/// untouched so resetting a pair restores precisely the previous rendering.
class RiotSpacingStore extends ChangeNotifier {
  RiotSpacingStore._();

  static final RiotSpacingStore instance = RiotSpacingStore._();
  static const String _key = 'vybe_riot_spacing_overrides_v1';
  final Map<String, double> _pairs = <String, double>{};
  Timer? _saveDebounce;
  bool _loaded = false;

  Map<String, double> get pairs => Map<String, double>.unmodifiable(_pairs);

  double deltaFor(String pair) => _pairs[pair.toUpperCase()] ?? 0.0;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null && raw.trim().isNotEmpty) {
        importJson(raw, persist: false);
      }
    } catch (error) {
      debugPrint('Riot spacing: could not restore saved pairs: ' + error.toString());
    }
  }

  void setPair(String pair, double emDelta) {
    final normalized = pair.toUpperCase();
    if (normalized.runes.length != 2 ||
        normalized.contains(RegExp(r'\s'))) return;
    final value = (emDelta * 100).roundToDouble() / 100;
    if (value.abs() < .005) {
      if (_pairs.remove(normalized) == null) return;
    } else {
      if (_pairs[normalized] == value) return;
      _pairs[normalized] = value.clamp(-.40, .40).toDouble();
    }
    notifyListeners();
    _scheduleSave();
  }

  void resetAll() {
    if (_pairs.isEmpty) return;
    _pairs.clear();
    notifyListeners();
    _scheduleSave();
  }

  String exportJson() {
    final sorted = Map<String, double>.fromEntries(
        _pairs.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    return const JsonEncoder.withIndent('  ').convert(<String, Object>{
      'version': 1,
      'description': 'VYBE Riot optical pair spacing; negative closer, positive farther',
      'pairs': sorted,
    });
  }

  void importJson(String value, {bool persist = true}) {
    final decoded = jsonDecode(value);
    if (decoded is! Map || decoded['pairs'] is! Map) {
      throw const FormatException('Expected JSON with a pairs object.');
    }
    final next = <String, double>{};
    for (final entry in (decoded['pairs'] as Map).entries) {
      final pair = entry.key.toString().toUpperCase();
      final number = entry.value;
      if (pair.runes.length != 2 || number is! num ||
          !number.isFinite || pair.contains(RegExp(r'\s'))) {
        throw FormatException('Invalid Riot pair or spacing: ' + pair);
      }
      final delta = number.toDouble().clamp(-.40, .40).toDouble();
      if (delta.abs() >= .005) next[pair] = delta;
    }
    _pairs
      ..clear()
      ..addAll(next);
    notifyListeners();
    if (persist) _scheduleSave();
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 280), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_key, exportJson());
      } catch (error) {
        debugPrint('Riot spacing: could not save pairs: ' + error.toString());
      }
    });
  }
}
