import 'package:flutter/services.dart';

/// Android-backed settings using synchronous native commits.
class SharedPreferences {
  SharedPreferences._();
  static const MethodChannel _channel = MethodChannel('vybe/preferences');
  final Map<String, dynamic> _values = {};
  static Future<SharedPreferences> getInstance() async {
    final p = SharedPreferences._();
    await p.reload();
    return p;
  }
  Future<void> reload() async {
    final m = await _channel.invokeMapMethod<String, dynamic>('getAll');
    _values.clear();
    if (m != null) _values.addAll(m);
  }
  bool? getBool(String key) => _values[key] is bool ? _values[key] as bool : null;
  int? getInt(String key) => _values[key] is int ? _values[key] as int : null;
  double? getDouble(String key) => _values[key] is num ? (_values[key] as num).toDouble() : null;
  String? getString(String key) => _values[key] is String ? _values[key] as String : null;
  Future<bool> _put(String key, Object value) async {
    final ok = await _channel.invokeMethod<bool>('set', {'key': key, 'value': value}) ?? false;
    if (ok) _values[key] = value;
    return ok;
  }
  Future<bool> setBool(String key, bool value) => _put(key, value);
  Future<bool> setInt(String key, int value) => _put(key, value);
  Future<bool> setDouble(String key, double value) => _put(key, value);
  Future<bool> setString(String key, String value) => _put(key, value);
}
