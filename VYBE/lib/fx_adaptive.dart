import 'dart:ui' as ui;
import 'package:flutter/scheduler.dart';

/// Uses actual raster/build frame timings instead of guessing from CPU model.
/// This is a conservative live quality governor, not an individual FX benchmark.
class FxAdaptiveGovernor {
  int tier = 2; // 2 full shader, 1 reduced, 0 canvas-only
  int _samples = 0;
  int _slow = 0;
  int _fastWindows = 0;
  int _windows = 0;
  bool enabled = true;
  void Function(int)? onTierChanged;

  late final TimingsCallback _callback = _onTimings;
  void start() => SchedulerBinding.instance.addTimingsCallback(_callback);
  void stop() => SchedulerBinding.instance.removeTimingsCallback(_callback);

  void _onTimings(List<ui.FrameTiming> frames) {
    if (!enabled) return;
    // A 30 fps app has ~33ms per frame; raster times above 28ms risk jank.
    for (final f in frames) {
      _samples++;
      if (f.rasterDuration.inMicroseconds > 28000 ||
          f.buildDuration.inMicroseconds > 28000) _slow++;
    }
    if (_samples < 150) return;
    final ratio = _slow / _samples;
    _samples = 0;
    _slow = 0;
    _windows++;
    if (_windows <= 1) return; // shader and image warm-up
    if (ratio > 0.22 && tier > 0) {
      tier--;
      _fastWindows = 0;
      onTierChanged?.call(tier);
    } else if (ratio < 0.035 && tier < 2) {
      _fastWindows++;
      if (_fastWindows >= 4) {
        tier++;
        _fastWindows = 0;
        onTierChanged?.call(tier);
      }
    } else {
      _fastWindows = 0;
    }
  }
}
