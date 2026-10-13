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
      final flat = data != null && (_isFlat(data, img.width * img.height) ||
          _isGenericPlaceholder(data, img.width, img.height));
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

  /// Detect generic player icons on an almost uniform dark-gray canvas.
  /// Unlike the single-color check above, this catches placeholders with a
  /// central logo and label (such as the Musicolett default cover). Require
  /// uniform neutral corners AND a dominant neutral background to avoid
  /// rejecting legitimate dark photographic album artwork.
  static bool _isGenericPlaceholder(ByteData data, int w, int h) {
    if (w < 24 || h < 24) return false;
    final cornerSize = math.max(2, math.min(w, h) ~/ 9);
    final samples = <List<int>>[];
    for (final y0 in [0, h - cornerSize]) {
      for (final x0 in [0, w - cornerSize]) {
        var r = 0, g = 0, b = 0, count = 0;
        for (var y = y0; y < y0 + cornerSize; y += 2) {
          for (var x = x0; x < x0 + cornerSize; x += 2) {
            final i = (y * w + x) * 4;
            r += data.getUint8(i);
            g += data.getUint8(i + 1);
            b += data.getUint8(i + 2);
            count++;
          }
        }
        samples.add([r ~/ count, g ~/ count, b ~/ count]);
      }
    }
    final base = samples.first;
    // Generic dark placeholders have the same neutral canvas in every corner.
    if (base.reduce(math.max) - base.reduce(math.min) > 18 ||
        base.reduce(math.max) > 95) return false;
    for (final c in samples.skip(1)) {
      for (var j = 0; j < 3; j++) {
        if ((c[j] - base[j]).abs() > 13) return false;
      }
    }
    var background = 0, total = 0, centerDetail = 0;
    for (var y = 0; y < h; y += 2) {
      for (var x = 0; x < w; x += 2) {
        final i = (y * w + x) * 4;
        final r = data.getUint8(i), g = data.getUint8(i + 1),
            b = data.getUint8(i + 2);
        if ((r - base[0]).abs() <= 19 &&
            (g - base[1]).abs() <= 19 &&
            (b - base[2]).abs() <= 19) background++;
        if (x > w * 0.25 && x < w * 0.75 &&
            y > h * 0.2 && y < h * 0.8 &&
            (r - base[0]).abs() + (g - base[1]).abs() +
                (b - base[2]).abs() > 80) centerDetail++;
        total++;
      }
    }
    return background > total * 0.58 && centerDetail > total * 0.012;
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
