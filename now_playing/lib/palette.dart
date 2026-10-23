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
  /// Legacy compatibility flag. Decodable images are not rejected based on
  /// their color distribution or layout; minimalist album covers are valid.
  final bool flat;
  /// Fraction of the blurred artwork in the left/center text area that is near-white.
  final double nearWhiteTextCoverage;
  ArtAssets(this.bytes, this.tiny, this.palette,
      {this.flat = false, this.nearWhiteTextCoverage = 0});

  static Future<ArtAssets?> load(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 96);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final palette = data == null
          ? ArtPalette.fallback
          : _extract(data, img.width, img.height);
      // A valid decoded image is artwork. Do not guess whether it is a
      // placeholder from pixel colors: that rejects real minimalist covers.
      const flat = false;
      return ArtAssets(bytes, img, palette, flat: flat,
          nearWhiteTextCoverage: data == null ? 0 : _nearWhiteCoverage(data, img.width, img.height));
    } catch (_) {
      return null;
    }
  }

  static double _nearWhiteCoverage(ByteData data, int w, int h) {
    var white = 0, total = 0;
    // Left and central region where most themes display song information.
    for (var y = h ~/ 4; y < h * 3 ~/ 4; y += 2) {
      for (var x = 0; x < w * 3 ~/ 5; x += 2) {
        final idx = (y * w + x) * 4;
        final r = data.getUint8(idx), g = data.getUint8(idx + 1), b = data.getUint8(idx + 2);
        final maxC = math.max(r, math.max(g, b));
        final minC = math.min(r, math.min(g, b));
        if (minC >= 214 && maxC - minC <= 38) white++;
        total++;
      }
    }
    return total == 0 ? 0 : white / total;
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
