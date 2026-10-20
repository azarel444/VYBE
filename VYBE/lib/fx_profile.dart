import 'dart:convert';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'settings.dart';

/// Device-local observations of REAL Now Playing frames. A profile is tied to
/// theme, orientation, resolution, and the exact selected FX combination.
/// No CPU model blacklist, no synthetic preview benchmark.
class FxProfileStore {
  static const key = 'vybeFxObservedProfilesV1';
  static Map<String, dynamic> data = {};
  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    try { data = Map<String,dynamic>.from(jsonDecode(p.getString(key) ?? '{}') as Map); }
    catch (_) { data = {}; }
  }
  static String signature(AppSettings s, double width, double height) {
    final selected = <String>[];
    if (s.bgEffects) selected.add('Background Motion');
    if (s.particles) selected.add('Floating Particles');
    if (s.fxNebula) selected.add('Nebula Haze');
    if (s.fxGrid) selected.add('Perspective Grid');
    if (s.fxStars) selected.add('Twinkling Stars');
    if (s.fxGlow) selected.add('Moving Bokeh');
    if (s.fxSweep) selected.add('Aurora Sweep');
    if (s.fxRays) selected.add('Light Rays');
    if (s.fxRipples) selected.add('Beat Ripples');
    if (s.fxWater) selected.add('Water Shimmer');
    if (s.fxBloom) selected.add('Cover Bloom');
    if (s.fxVhs) selected.add('VHS');
    for (final n in AppSettings.extraFxNames) { if (s.extraFx[n] ?? false) selected.add(n); }
    selected.sort();
    return '${s.theme}:${width.round()}x${height.round()}:${selected.join('|')}';
  }
  static Future<void> record(String signature, double slowRatio, double averageMs) async {
    final old = data[signature];
    final count = old is Map ? ((old['windows'] as num?)?.toInt() ?? 0) : 0;
    final prev = old is Map ? ((old['slowRatio'] as num?)?.toDouble() ?? slowRatio) : slowRatio;
    final prevMs = old is Map ? ((old['averageMs'] as num?)?.toDouble() ?? averageMs) : averageMs;
    data[signature] = {'windows':count+1,'slowRatio':count==0?slowRatio:prev*.65+slowRatio*.35,
      'averageMs':count==0?averageMs:prevMs*.65+averageMs*.35};
    // Bound storage even for users who explore hundreds of combinations.
    while (data.length > 180) { data.remove(data.keys.first); }
    final p = await SharedPreferences.getInstance();
    await p.setString(key, jsonEncode(data));
  }
  static Map<String,dynamic>? result(String signature) {
    final v = data[signature];
    return v is Map ? Map<String,dynamic>.from(v) : null;
  }
  static Future<void> clear() async {
    data.clear();
    final p = await SharedPreferences.getInstance();
    await p.remove(key);
  }
}

class FxFrameProfiler {
  String? Function()? signature;
  String? _active;
  int _frames=0, _slow=0;
  double _totalMs=0;
  late final TimingsCallback _listener = (frames) {
    final next = signature?.call();
    if (next == null) return;
    if (_active != next) { _active=next; _frames=0; _slow=0; _totalMs=0; return; }
    for (final f in frames) {
      final ms = (f.buildDuration.inMicroseconds + f.rasterDuration.inMicroseconds)/1000.0;
      _frames++; _totalMs += ms;
      if (ms > 28) _slow++;
    }
    if (_frames >= 180) {
      final id = _active!;
      final ratio = _slow/_frames, avg = _totalMs/_frames;
      _frames=0; _slow=0; _totalMs=0;
      FxProfileStore.record(id, ratio, avg);
    }
  };
  void start() => SchedulerBinding.instance.addTimingsCallback(_listener);
  void stop() => SchedulerBinding.instance.removeTimingsCallback(_listener);
}
