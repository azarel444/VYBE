import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Three accent colors pulled from the album art. Used for the glow,
/// the visualizer gradient and the progress line.
class ArtPalette {
  final Color a, b, c;
  const ArtPalette(this.a, this.b, this.c);

  static const fallback = ArtPalette(
    Color(0xFF3DE0D0), // teal
    Color(0xFF8B5CFF), // violet
    Color(0xFFFF6FA8), // rose
  );

  /// Soft white-blue tints, used when the art has no real color (black and
  /// white covers) so the visualizer still matches instead of inventing hues.
  static const neutral = ArtPalette(
    Color(0xFFEAF0FA),
    Color(0xFFB4BED2),
    Color(0xFF8590A8),
  );

  List<Color> get colors => [a, b, c];

  /// t: 0 (left) .. 1 (right)
  Color at(double t) {
    t = t.clamp(0.0, 1.0).toDouble();
    return t < 0.5
        ? Color.lerp(a, b, t * 2)!
        : Color.lerp(b, c, (t - 0.5) * 2)!;
  }
}

/// Decoded album art: the original bytes for the sharp card, plus a tiny
/// decoded copy that is scaled up for the soft background (cheap "blur"
/// that costs nothing per frame on slow head units).
class ArtAssets {
  final Uint8List bytes;
  final ui.Image tiny;
  final ArtPalette palette;
  /// True when the picture is almost one flat color, which is what players
  /// send when a song has no real cover (a logo on a plain background).
  final bool flat;
  ArtAssets(this.bytes, this.tiny, this.palette, {this.flat = false});

  static Future<ArtAssets?> load(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 96);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final palette = data == null
          ? ArtPalette.fallback
          : _extract(data, img.width, img.height);
      final flat = data != null && _isFlat(data, img.width * img.height);
      return ArtAssets(bytes, img, palette, flat: flat);
    } catch (_) {
      return null;
    }
  }

  /// Looks at the tiny copy: if one color (4 bits per channel) covers most
  /// of the picture, it is a placeholder rather than a real cover.
  static bool _isFlat(ByteData d, int n) {
    if (n <= 0) return false;
    final counts = <int, int>{};
    var best = 0;
    for (int i = 0; i < n; i++) {
      final key = ((d.getUint8(i * 4) >> 4) << 8) |
          ((d.getUint8(i * 4 + 1) >> 4) << 4) |
          (d.getUint8(i * 4 + 2) >> 4);
      final c = (counts[key] ?? 0) + 1;
      counts[key] = c;
      if (c > best) best = c;
    }
    return best > n * 0.85;
  }

  /// Colors come only from the art itself: pixels are grouped into 12 hue
  /// bins weighted by how vivid they are, and the biggest bins win. If the
  /// art only has one real hue, the other two are lighter and deeper shades
  /// of that same hue (never a made-up different hue).
  static ArtPalette _extract(ByteData d, int w, int h) {
    const bins = 12;
    final wt = List<double>.filled(bins, 0.0);
    final sSum = List<double>.filled(bins, 0.0);
    final vSum = List<double>.filled(bins, 0.0);
    final xSum = List<double>.filled(bins, 0.0);
    final ySum = List<double>.filled(bins, 0.0);
    var valueSum = 0.0;
    final n = w * h;

    for (int i = 0; i < n; i++) {
      final hsv = HSVColor.fromColor(Color.fromARGB(
          255, d.getUint8(i * 4), d.getUint8(i * 4 + 1), d.getUint8(i * 4 + 2)));
      valueSum += hsv.value;
      if (hsv.saturation < 0.18 || hsv.value < 0.18) continue;
      final score = hsv.saturation * hsv.value;
      final bi = (hsv.hue ~/ 30) % bins;
      wt[bi] += score;
      sSum[bi] += hsv.saturation * score;
      vSum[bi] += hsv.value * score;
      final rad = hsv.hue * math.pi / 180;
      xSum[bi] += math.cos(rad) * score;
      ySum[bi] += math.sin(rad) * score;
    }

    var total = 0.0;
    for (final x in wt) {
      total += x;
    }
    if (n == 0 || total < n * 0.02) {
      // Black and white or very dark art: stay neutral.
      final v = n == 0 ? 0.8 : valueSum / n;
      Color gray(double mul) => HSVColor.fromAHSV(
              1, 215, 0.08, (mul * (0.7 + 0.3 * v)).clamp(0.0, 1.0).toDouble())
          .toColor();
      return ArtPalette(gray(1.0), gray(0.8), gray(0.62));
    }

    HSVColor rep(int i) {
      var hue = math.atan2(ySum[i], xSum[i]) * 180 / math.pi;
      if (hue < 0) hue += 360;
      return HSVColor.fromAHSV(
        1,
        hue.clamp(0.0, 360.0).toDouble(),
        (sSum[i] / wt[i]).clamp(0.0, 1.0).toDouble(),
        (vSum[i] / wt[i]).clamp(0.0, 1.0).toDouble(),
      );
    }

    final order = List<int>.generate(bins, (i) => i)
      ..sort((x, y) => wt[y].compareTo(wt[x]));
    final first = rep(order[0]);
    HSVColor? second;
    HSVColor? third;
    for (final i in order.skip(1)) {
      if (wt[i] < wt[order[0]] * 0.12) break;
      final c = rep(i);
      if (second == null) {
        if (_hueDist(c.hue, first.hue) >= 35) second = c;
      } else if (_hueDist(c.hue, first.hue) >= 35 &&
          _hueDist(c.hue, second.hue) >= 35) {
        third = c;
        break;
      }
    }
    // Same hue, different shade: always related to the art.
    second ??= HSVColor.fromAHSV(1, first.hue, first.saturation * 0.65,
        math.min(1.0, first.value + 0.15));
    third ??= HSVColor.fromAHSV(1, second.hue,
        math.min(1.0, second.saturation * 1.1), second.value * 0.72);

    return ArtPalette(_vivid(first), _vivid(second), _vivid(third));
  }

  static double _hueDist(double a, double b) {
    final d = (a - b).abs() % 360;
    return d > 180 ? 360 - d : d;
  }

  /// A gentle lift so colors read well on a dark screen. The hue is kept.
  static Color _vivid(HSVColor c) => c
      .withSaturation(math.max(c.saturation, 0.45))
      .withValue(math.max(c.value, 0.8))
      .toColor();
}
