import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'palette.dart';

double _a(double v) => v.clamp(0.0, 1.0).toDouble();

// ------------------------------------------------------------- particles

/// Slowly rising embers. Position is a pure function of [t], so nothing is
/// allocated per frame.
class ParticleField {
  static const int n = 36;
  final List<double> x = [];
  final List<double> y = [];
  final List<double> r = [];
  final List<double> s = [];
  final List<double> ph = [];
  double t = 0;

  ParticleField() {
    final rnd = math.Random(5);
    for (int i = 0; i < n; i++) {
      x.add(rnd.nextDouble());
      y.add(rnd.nextDouble());
      r.add(1.5 + rnd.nextDouble() * 3.0);
      s.add(0.05 + rnd.nextDouble() * 0.10);
      ph.add(rnd.nextDouble() * 6.283);
    }
  }
}

class ParticlesPainter extends CustomPainter {
  final ParticleField field;
  final ArtPalette palette;
  final double k;

  ParticlesPainter({
    required this.field,
    required this.palette,
    this.k = 1.0,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint();
    final t = field.t;
    for (int i = 0; i < ParticleField.n; i++) {
      final yy = (field.y[i] - t * field.s[i]) % 1.0;
      final xx =
          (field.x[i] + 0.015 * math.sin(t * 1.3 + field.ph[i])) * size.width;
      final py = yy * size.height;
      final edge = math.sin(yy * math.pi);
      final tw = 0.5 + 0.5 * math.sin(t * 2.0 + field.ph[i] * 3.0);
      final alpha = _a((0.25 + 0.30 * tw) * edge * k);
      final c = palette.at(field.x[i]);
      p.color = c.withOpacity(alpha * 0.25);
      canvas.drawCircle(Offset(xx, py), field.r[i] * 3.2, p);
      p.color = c.withOpacity(alpha);
      canvas.drawCircle(Offset(xx, py), field.r[i], p);
    }
  }

  @override
  bool shouldRepaint(ParticlesPainter old) =>
      old.palette != palette || old.k != k;
}

// ------------------------------------------------------------------- VHS

/// Faint horizontal lines. Drawn once and cached (no repaint listener).
class ScanlinePainter extends CustomPainter {
  final double alpha;
  ScanlinePainter({required this.alpha});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Color.fromRGBO(0, 0, 0, _a(alpha))
      ..strokeWidth = 1.2;
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(ScanlinePainter old) => old.alpha != alpha;
}

/// A small tile of random noise, made once and then just moved around.
Future<ui.Image> makeNoiseImage() {
  const size = 128;
  final r = math.Random(7);
  final px = Uint8List(size * size * 4);
  for (int i = 0; i < size * size; i++) {
    final a = 40 + r.nextInt(70);
    final v = (r.nextInt(256) * a) ~/ 255; // premultiplied gray
    px[i * 4] = v;
    px[i * 4 + 1] = v;
    px[i * 4 + 2] = v;
    px[i * 4 + 3] = a;
  }
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(px, size, size, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

/// Film grain: the noise tile jumps to a new offset about 10 times a second.
class GrainPainter extends CustomPainter {
  final ui.Image? noise;
  final double k;
  final ValueListenable<int> tick;

  GrainPainter({required this.noise, required this.k, required this.tick})
      : super(repaint: tick);

  @override
  void paint(Canvas canvas, Size size) {
    final img = noise;
    if (img == null) return;
    final n = tick.value;
    final dx = ((n * 53) % 128).toDouble();
    final dy = ((n * 97) % 128).toDouble();
    final p = Paint()
      ..shader = ui.ImageShader(img, TileMode.repeated, TileMode.repeated,
          Matrix4.translationValues(dx, dy, 0).storage)
      ..color = Color.fromRGBO(255, 255, 255, _a(k));
    canvas.drawRect(Offset.zero & size, p);
  }

  @override
  bool shouldRepaint(GrainPainter old) => old.noise != noise || old.k != k;
}

/// Shared state for the tracking-glitch bands. The screen updates it;
/// the painter only reads it.
class GlitchState {
  double active = 0; // 0..1, fades in and out
  double y = 0.5; // 0..1 vertical position of the first band
  int bands = 1;
  int seed = 1;
}

class GlitchPainter extends CustomPainter {
  final GlitchState g;
  final double k;

  GlitchPainter({required this.g, required this.k, required Listenable repaint})
      : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final a = g.active * k;
    if (a <= 0.01) return;
    final r = math.Random(g.seed);
    final p = Paint();
    for (int b = 0; b < g.bands; b++) {
      final y = ((g.y + b * 0.23 + r.nextDouble() * 0.05) % 1.0) * size.height;
      final bh = size.height * (0.012 + r.nextDouble() * 0.03);
      final shift = (r.nextDouble() - 0.5) * size.width * 0.05;

      p.color = Color.fromRGBO(255, 255, 255, _a(0.10 * a));
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, bh), p);
      p.color = Color.fromRGBO(255, 46, 147, _a(0.22 * a));
      canvas.drawRect(Rect.fromLTWH(shift, y, size.width, bh * 0.35), p);
      p.color = Color.fromRGBO(5, 217, 255, _a(0.22 * a));
      canvas.drawRect(
          Rect.fromLTWH(-shift, y + bh * 0.65, size.width, bh * 0.35), p);

      p.color = Color.fromRGBO(255, 255, 255, _a(0.35 * a));
      for (int i = 0; i < 14; i++) {
        final x = r.nextDouble() * size.width;
        final w = size.width * (0.02 + r.nextDouble() * 0.08);
        canvas.drawRect(
            Rect.fromLTWH(x, y + r.nextDouble() * bh, w, 1.5), p);
      }
    }
  }

  @override
  bool shouldRepaint(GlitchPainter old) => old.k != k;
}

// ------------------------------------------------------------ vaporwave

const double _horizon = 0.66;

/// A soft glow resting on the horizon in the album's main color. It swells
/// a little on bass.
class HorizonGlowPainter extends CustomPainter {
  final FxClock clock;
  final ArtPalette palette;
  final double k;

  HorizonGlowPainter({
    required this.clock,
    required this.palette,
    required this.k,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final hy = size.height * _horizon;
    final r = math.min(size.width, size.height) * 0.55 * (1 + 0.08 * clock.bass);
    final main = palette.a;
    final core = Color.lerp(main, Colors.white, 0.35)!;

    canvas.save();
    canvas.translate(size.width * 0.5, hy);
    canvas.scale(1.0, 0.5); // a wide, low glow that sits on the horizon
    canvas.drawCircle(
      Offset.zero,
      r,
      Paint()
        ..shader = ui.Gradient.radial(Offset.zero, r, [
          main.withOpacity(_a((0.55 + 0.25 * clock.bass) * k)),
          main.withOpacity(0),
        ]),
    );
    final r2 = r * 0.4;
    canvas.drawCircle(
      Offset.zero,
      r2,
      Paint()
        ..shader = ui.Gradient.radial(Offset.zero, r2, [
          core.withOpacity(_a((0.5 + 0.3 * clock.bass) * k)),
          core.withOpacity(0),
        ]),
    );
    canvas.restore();

    final x0 = size.width * 0.15;
    final x1 = size.width * 0.85;
    canvas.drawRect(
      Rect.fromLTWH(x0, hy - 1, x1 - x0, 2),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(x0, hy),
          Offset(x1, hy),
          [
            main.withOpacity(0),
            main.withOpacity(_a(0.8 * k)),
            main.withOpacity(0),
          ],
          const [0.0, 0.5, 1.0],
        ),
    );
  }

  @override
  bool shouldRepaint(HorizonGlowPainter old) =>
      old.palette != palette || old.k != k;
}

class GridState {
  double scroll = 0;
}

/// Perspective grid floor that scrolls toward the viewer.
class GridPainter extends CustomPainter {
  final GridState state;
  final double k;

  GridPainter({required this.state, required this.k, required Listenable repaint})
      : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final hy = size.height * _horizon;
    final cx = size.width / 2;

    canvas.drawRect(
      Rect.fromLTWH(0, hy, size.width, size.height - hy),
      Paint()..color = Color.fromRGBO(20, 0, 40, _a(0.35 * k)),
    );

    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    p.color = Color.fromRGBO(255, 46, 147, _a(0.5 * k));
    canvas.drawLine(Offset(0, hy), Offset(size.width, hy), p);

    const n = 9;
    for (int i = 0; i < n; i++) {
      final z = ((i + state.scroll) % n) / n;
      final y = hy + (size.height - hy) * z * z;
      p.color = Color.fromRGBO(185, 103, 255, _a((0.15 + 0.55 * z) * k));
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }

    p.color = Color.fromRGBO(5, 217, 255, _a(0.30 * k));
    for (int j = -8; j <= 8; j++) {
      canvas.drawLine(
        Offset(cx + j * size.width * 0.012, hy),
        Offset(cx + j * size.width * 0.11, size.height),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(GridPainter old) => old.k != k;
}

// ------------------------------------------------------- extra effects

/// Shared clock for the extra effects. The screen updates it every frame.
class FxClock {
  double t = 0; // seconds
  double bass = 0; // 0..1
}

/// Finds the album art on screen so rings and rays can start from it.
RenderBox? _artBox(GlobalKey key) {
  final ro = key.currentContext?.findRenderObject();
  if (ro is RenderBox && ro.attached && ro.hasSize) return ro;
  return null;
}

Offset _artCenter(GlobalKey key, Size size) {
  final box = _artBox(key);
  if (box == null) return Offset(size.width * 0.25, size.height / 2);
  return box.localToGlobal(box.size.center(Offset.zero));
}

/// Breathing glow: three soft blobs in the art colors drift around and
/// swell slowly, a little brighter on bass.
class GlowPainter extends CustomPainter {
  final FxClock clock;
  final ArtPalette palette;
  final double k;

  GlowPainter({
    required this.clock,
    required this.palette,
    required this.k,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock.t;
    final cols = palette.colors;
    final big = math.max(size.width, size.height);
    for (int i = 0; i < 3; i++) {
      final c = Offset(
        size.width * (0.5 + 0.38 * math.sin(t * 0.11 + i * 2.1)),
        size.height * (0.5 + 0.34 * math.cos(t * 0.09 + i * 1.7)),
      );
      final r = big * (0.38 + 0.08 * math.sin(t * 0.35 + i));
      final a = _a((0.16 + 0.10 * math.sin(t * 0.5 + i * 1.3) + 0.12 * clock.bass) * k);
      final p = Paint()
        ..shader = ui.Gradient.radial(
          c,
          r,
          [cols[i].withOpacity(a), cols[i].withOpacity(0)],
        );
      canvas.drawCircle(c, r, p);
    }
  }

  @override
  bool shouldRepaint(GlowPainter old) => old.palette != palette || old.k != k;
}

/// Aurora sweep: slow soft bands of the art colors roll across the screen.
class SweepPainter extends CustomPainter {
  final FxClock clock;
  final ArtPalette palette;
  final double k;

  SweepPainter({
    required this.clock,
    required this.palette,
    required this.k,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final v = Offset(size.width * 0.9, size.height * 0.6);
    final p = (clock.t * 0.03) % 1.0;
    // Moving the start by exactly one period along v loops without a jump.
    final begin = Offset(v.dx * p, v.dy * p);
    final end = begin + v;
    final a = _a((0.20 + 0.15 * clock.bass) * k);
    final c = palette.colors;
    final shader = ui.Gradient.linear(
      begin,
      end,
      [
        c[0].withOpacity(0),
        c[0].withOpacity(a),
        c[1].withOpacity(a),
        c[2].withOpacity(a),
        c[2].withOpacity(0),
      ],
      const [0.0, 0.25, 0.5, 0.75, 1.0],
      TileMode.repeated,
    );
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(SweepPainter old) => old.palette != palette || old.k != k;
}

/// Light rays fanning out from behind the art, brighter on bass.
class RaysPainter extends CustomPainter {
  final FxClock clock;
  final GlobalKey artKey;
  final ArtPalette palette;
  final double k;

  /// Fans the beams down from the top center of the screen instead of from
  /// behind the cover (used by the Typo theme).
  final bool topOrigin;

  RaysPainter({
    required this.clock,
    required this.artKey,
    required this.palette,
    required this.k,
    this.topOrigin = false,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final c = topOrigin ? Offset(size.width / 2, 0) : _artCenter(artKey, size);
    final reach = math.sqrt(size.width * size.width + size.height * size.height);
    final intensity = _a((0.12 + 0.35 * clock.bass) * k);
    final cols = palette.colors;
    final paints = List<Paint>.generate(
      3,
      (i) => Paint()
        ..shader = ui.Gradient.radial(
          c,
          reach * 0.7,
          [cols[i].withOpacity(intensity), cols[i].withOpacity(0)],
        ),
    );
    final rot = clock.t * 0.05;
    const n = 9;
    for (int i = 0; i < n; i++) {
      // From the top center the beams only fan downward, and sway gently.
      final ang = topOrigin
          ? math.pi / 2 +
              (i - (n - 1) / 2) * (math.pi * 0.86 / (n - 1)) +
              0.12 * math.sin(clock.t * 0.15 + i * 0.7)
          : rot + i * 2 * math.pi / n;
      final half = 0.075 + 0.03 * math.sin(clock.t * 0.4 + i);
      final path = Path()
        ..moveTo(c.dx, c.dy)
        ..lineTo(c.dx + reach * math.cos(ang - half),
            c.dy + reach * math.sin(ang - half))
        ..lineTo(c.dx + reach * math.cos(ang + half),
            c.dy + reach * math.sin(ang + half))
        ..close();
      canvas.drawPath(path, paints[i % 3]);
    }
  }

  @override
  bool shouldRepaint(RaysPainter old) =>
      old.palette != palette || old.k != k || old.topOrigin != topOrigin;
}

/// Starts of the ripple rings. A ring is born on each detected beat.
class RippleState {
  final List<double> starts = [];
  double _lastBeat = -10;
  double _avg = 0.2;

  void update(double now, double bass, bool enabled) {
    starts.removeWhere((s) => now - s > 2.8);
    final previous = _avg;
    _avg = _avg * 0.93 + bass * 0.07;
    if (!enabled) return;
    // Adaptive transient gate: reacts to bass peaks across quiet and loud
    // sources without a fixed 0.25 floor that misses most head-unit audio.
    if (bass > 0.09 && bass > previous * 1.17 + 0.025 && now - _lastBeat > 0.27) {
      _lastBeat = now;
      starts.add(now);
      if (starts.length > 5) starts.removeAt(0);
    }
  }
}

/// Rings that expand outward from the art on each beat, like water.
class RipplesPainter extends CustomPainter {
  final RippleState state;
  final FxClock clock;
  final GlobalKey artKey;
  final ArtPalette palette;
  final double k;

  RipplesPainter({
    required this.state,
    required this.clock,
    required this.artKey,
    required this.palette,
    required this.k,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (state.starts.isEmpty) return;
    final c = _artCenter(artKey, size);
    final box = _artBox(artKey);
    final baseR = box != null ? box.size.shortestSide / 2 : size.shortestSide * 0.2;
    final maxR = math.sqrt(size.width * size.width + size.height * size.height) * 0.55;
    final p = Paint()..style = PaintingStyle.stroke;
    for (final s in state.starts) {
      final f = (clock.t - s) / 2.6;
      if (f < 0 || f > 1) continue;
      p.strokeWidth = 1.0 + 3.0 * (1 - f);
      p.color = palette.at(f).withOpacity(_a((1 - f) * 0.70 * k));
      canvas.drawCircle(c, baseR + f * maxR, p);
    }
  }

  @override
  bool shouldRepaint(RipplesPainter old) => old.palette != palette || old.k != k;
}

/// Water shimmer: faint broken lines that drift and twinkle in the lower
/// part of the screen, like light on a lake.
class WaterPainter extends CustomPainter {
  final FxClock clock;
  final ArtPalette palette;
  final double k;

  WaterPainter({
    required this.clock,
    required this.palette,
    required this.k,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    const lines = 26;
    final top = size.height * 0.72;
    final tint = Color.lerp(Colors.white, palette.b, 0.4)!;
    final p = Paint();
    for (int i = 0; i < lines; i++) {
      final f = i / (lines - 1);
      final y = top + (size.height - top) * math.pow(f, 1.5).toDouble();
      final ph = i * 1.7;
      final len = size.width * (0.12 + 0.28 * (((i * 37) % 10) / 10));
      final x = ((((i * 53) % 100) / 100) + 0.05 * math.sin(clock.t * 0.6 + ph)) *
          size.width;
      final tw = 0.5 + 0.5 * math.sin(clock.t * 1.1 + ph * 2);
      p.color = tint.withOpacity(_a((0.04 + 0.07 * tw) * (0.4 + f) * k));
      canvas.drawRect(Rect.fromLTWH(x - len / 2, y, len, 1.5 + 2 * f), p);
    }
  }

  @override
  bool shouldRepaint(WaterPainter old) => old.palette != palette || old.k != k;
}


// ------------------------------------------------------------- idle backdrop

/// Shown when there is no album art: a deep night sky with slow aurora
/// ribbons, soft drifting colour and a few twinkling stars.
class IdleBackdropPainter extends CustomPainter {
  final FxClock clock;
  final ArtPalette palette;
  final bool animate;

  IdleBackdropPainter({
    required this.clock,
    required this.palette,
    required this.animate,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final t = animate ? clock.t : 0.0;
    final rect = Offset.zero & size;

    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF05060F), Color(0xFF0B0A22), Color(0xFF150E2E)],
        ).createShader(rect),
    );

    // Soft colour clouds that wander slowly.
    final cols = [palette.a, palette.b, palette.c];
    for (int i = 0; i < 3; i++) {
      final ph = i * 2.1;
      final cx = w * (0.5 + 0.38 * math.sin(t * 0.07 + ph));
      final cy = h * (0.45 + 0.28 * math.cos(t * 0.05 + ph * 1.3));
      final r = math.max(w, h) * (0.45 + 0.05 * math.sin(t * 0.11 + ph));
      canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..shader = RadialGradient(colors: [
            cols[i].withOpacity(0.30),
            cols[i].withOpacity(0.0),
          ]).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r)),
      );
    }

    // Aurora ribbons.
    for (int i = 0; i < 3; i++) {
      final path = Path();
      final base = h * (0.28 + 0.16 * i);
      path.moveTo(0, h);
      for (double x = 0; x <= w + 12; x += 12) {
        final u = x / w;
        final y = base +
            h * 0.07 * math.sin(u * 5.0 + t * 0.25 + i * 1.7) +
            h * 0.04 * math.sin(u * 11.0 - t * 0.17 + i);
        path.lineTo(x, y);
      }
      path.lineTo(w, h);
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              cols[i].withOpacity(0.20),
              cols[i].withOpacity(0.0),
            ],
          ).createShader(Rect.fromLTWH(0, base - h * 0.12, w, h * 0.6)),
      );
    }

    // Stars.
    final rnd = math.Random(11);
    final sp = Paint();
    for (int i = 0; i < 60; i++) {
      final x = rnd.nextDouble() * w;
      final y = rnd.nextDouble() * h * 0.7;
      final r = 0.6 + rnd.nextDouble() * 1.3;
      final tw = 0.5 + 0.5 * math.sin(t * (0.6 + rnd.nextDouble()) + i);
      sp.color = Colors.white.withOpacity(0.12 + 0.35 * tw);
      canvas.drawCircle(Offset(x, y), r, sp);
    }

    // Darken the edges a little so text always reads.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          radius: 1.0,
          colors: [Color(0x00000000), Color(0x99000000)],
          stops: [0.55, 1.0],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(IdleBackdropPainter old) =>
      old.palette != palette || old.animate != animate;
}


/// Three lightweight, album-palette-aware background layers. These draw on
/// transparent canvases ABOVE the blurred art, never replace it.
class AtmospherePainter extends CustomPainter {
  final int mode; // 0 clouds, 1 perspective grid, 2 star field
  final FxClock clock;
  final ArtPalette palette;
  final double k;
  AtmospherePainter({required this.mode, required this.clock,
      required this.palette, required this.k, required Listenable repaint})
      : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (k <= 0) return;
    final w = size.width, h = size.height, t = clock.t;
    final paint = Paint()..style = PaintingStyle.fill;
    if (mode == 0) {
      for (var i = 0; i < 4; i++) {
        final x = w * (0.12 + i * 0.26 + 0.045 * math.sin(t * 0.17 + i));
        final y = h * (0.22 + 0.17 * (i % 3) + 0.045 * math.cos(t * 0.13 + i));
        final radius = math.max(w, h) * (0.25 + 0.035 * math.sin(t * 0.3 + i));
        paint.shader = ui.Gradient.radial(Offset(x, y), radius,
          [palette.at(i / 4).withOpacity(0.44 * k), Colors.transparent]);
        canvas.drawCircle(Offset(x, y), radius, paint);
      }
      paint.shader = null;
    } else if (mode == 1) {
      final horizon = h * 0.68;
      paint..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = palette.a.withOpacity(0.18 * k);
      final center = Offset(w / 2, horizon);
      for (var i = -10; i <= 10; i++) {
        canvas.drawLine(center, Offset(w / 2 + i * w / 9, h), paint);
      }
      for (var i = 1; i <= 10; i++) {
        final frac = math.pow(i / 10, 1.7).toDouble();
        final yy = horizon + (h - horizon) * frac;
        canvas.drawLine(Offset(0, yy), Offset(w, yy), paint);
      }
    } else {
      for (var i = 0; i < 130; i++) {
        final x = ((i * 0.6180339887 + 0.13) % 1.0) * w;
        final y = ((i * 0.4142135623 + 0.37) % 1.0) * h;
        final twinkle = 0.5 + 0.5 * math.sin(t * (0.5 + i % 4 * 0.2) + i);
        paint.color = palette.at((i % 9) / 9).withOpacity((0.22 + 0.70 * twinkle) * k);
        canvas.drawCircle(Offset(x, y), 1.0 + (i % 4) * 0.75, paint);
      }
    }
  }
  @override
  bool shouldRepaint(AtmospherePainter old) =>
      old.mode != mode || old.palette != palette || old.k != k;
}


/// Lightweight GPU-canvas effects. Every mode draws visible animation over
/// the blurred artwork; modes are deliberately distinct for solo testing.
class ExpandedFxPainter extends CustomPainter {
  final int mode;
  final FxClock clock;
  final ArtPalette palette;
  final double k;
  ExpandedFxPainter({required this.mode, required this.clock,
    required this.palette, required this.k, required Listenable repaint})
    : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (k <= 0) return;
    final w = size.width, h = size.height, t = clock.t;
    final center = Offset(w * .5, h * .5);
    final bright = palette.a.withOpacity((.72 * k).clamp(0.0, 1.0));
    final second = palette.b.withOpacity((.68 * k).clamp(0.0, 1.0));
    final stroke = Paint()..style = PaintingStyle.stroke..strokeWidth = 2.5..color = bright;
    switch (mode) {
      case 0: // Liquid refraction: translucent flowing contours
        for (var i = 0; i < 12; i++) {
          final path = Path();
          for (var j = 0; j <= 60; j++) {
            final x = w * j / 60;
            final y = h * (i + 1) / 13 + h * .055 *
              math.sin(x / w * 9 + t * .85 + i * .65);
            if (j == 0) { path.moveTo(x, y); } else { path.lineTo(x, y); }
          }
          canvas.drawPath(path, stroke..color = (i.isEven ? bright : second)..strokeWidth = 1.5 + 2 * k);
        }
        break;
      case 1: // Bass shockwave: energy-responsive expanding rings
        final phase = (t * (0.55 + clock.bass * 2)) % 1.0;
        for (var i = 0; i < 3; i++) {
          final f = (phase + i / 3) % 1.0;
          canvas.drawCircle(center, (0.08 + f * .7) * w,
            stroke..strokeWidth = 2 + 7 * clock.bass * k
              ..color = palette.at(i / 3).withOpacity((1 - f) * .7 * k));
        }
        break;
      case 2: // Aurora curtains: tall undulating ribbons
        for (var i = 0; i < 7; i++) {
          final path = Path();
          for (var j = 0; j <= 55; j++) {
            final y = h * j / 55;
            final x = w * (.12 + i * .13) + w * .11 *
              math.sin(y / h * 5 + t * .6 + i * .5);
            if (j == 0) {path.moveTo(x,y);} else {path.lineTo(x,y);}
          }
          canvas.drawPath(path, stroke..strokeWidth = 10 + i * 2.0
            ..color = palette.at(i / 7).withOpacity(.22 * k));
        }
        break;
      case 3: // Vortex tunnel
        for (var i = 0; i < 7; i++) {
          final path = Path();
          for (var j = 0; j < 150; j++) {
            final a = j / 150 * math.pi * 5 + t * .55 + i * math.pi / 3.5;
            final r = (j / 150) * w * .53;
            final pt = center + Offset(math.cos(a) * r, math.sin(a) * r * h / w);
            if (j == 0) {path.moveTo(pt.dx,pt.dy);} else {path.lineTo(pt.dx,pt.dy);}
          }
          canvas.drawPath(path, stroke..strokeWidth = 1.5 + k * 2
            ..color = palette.at(i / 7).withOpacity(.65 * k));
        }
        break;
      case 4: // Electric arcs: deterministic branching flicker
        for (var i = 0; i < 7; i++) {
          final path = Path();
          final seed = (t * 6).floor() + i * 19;
          for (var j = 0; j < 17; j++) {
            final x = w * j / 16;
            final y = h * (.13 + i * .12) + math.sin(j * 9.3 + seed * 3.7) * h * .045;
            if (j == 0) {path.moveTo(x,y);} else {path.lineTo(x,y);}
          }
          canvas.drawPath(path, stroke..strokeWidth = i.isEven ? 2.5 : 1.3
            ..color = palette.at(i / 7).withOpacity(.6 * k));
        }
        break;
      case 5: // Prism shards
        for (var i = 0; i < 13; i++) {
          final x = w * ((i * .618 + t * .015) % 1);
          final y = h * ((i * .37 + t * .009) % 1);
          final r = 20 + (i % 4) * 22.0;
          final a = t * .13 + i;
          final path = Path()..moveTo(x + math.cos(a)*r,y + math.sin(a)*r)
            ..lineTo(x + math.cos(a+2.1)*r,y + math.sin(a+2.1)*r)
            ..lineTo(x + math.cos(a+4.2)*r,y + math.sin(a+4.2)*r)..close();
          canvas.drawPath(path, Paint()..color=palette.at(i/13).withOpacity(.24*k));
          canvas.drawPath(path, stroke..strokeWidth=1.5..color=bright);
        }
        break;
      case 6: // Light trails
        for (var i = 0; i < 12; i++) {
          final path = Path();
          for (var j = 0; j < 32; j++) {
            final x = w * j / 31;
            final y = h * (.12 + i * .07) + h * .09 * math.sin(j * .13 + t * (1 + i*.04) + i);
            if (j == 0) {path.moveTo(x,y);} else {path.lineTo(x,y);}
          }
          canvas.drawPath(path, stroke..strokeWidth=1.8+i%3*1.0
            ..color=palette.at(i/12).withOpacity(.7*k));
        }
        break;
      case 7: // Morphing wireframe
        for (var i = 0; i <= 15; i++) {
          final path = Path();
          for (var j = 0; j <= 35; j++) {
            final x = w * j / 35;
            final y = h * (.15 + i * .05) + h * .055 * math.sin(j*.25 + t + i*.5);
            if (j == 0) {path.moveTo(x,y);} else {path.lineTo(x,y);}
          }
          canvas.drawPath(path, stroke..strokeWidth=1.2..color=bright);
        }
        for (var j=0;j<=25;j++) {
          final x=w*j/25;
          final path=Path();
          for(var i=0;i<=15;i++) {
            final y=h*(.15+i*.05)+h*.055*math.sin(j/25*35*.25+t+i*.5);
            if(i==0){path.moveTo(x,y);}else{path.lineTo(x,y);}
          }
          canvas.drawPath(path,stroke..strokeWidth=.9..color=second);
        }
        break;
      case 8: // Particle currents
        for (var i=0;i<220;i++) {
          final f=(i*.6180339+t*.04*(1+i%4))%1;
          final a=i*.47+t*.45;
          final r=(.08+f*.47)*w;
          final pt=center+Offset(math.cos(a+f*8)*r,math.sin(a+f*8)*r*h/w);
          canvas.drawCircle(pt,1.0+(i%4)*.65,Paint()..color=palette.at(i/220).withOpacity(.65*k));
        }
        break;
      case 9: // Holographic interference
        for (var i=0;i<45;i++) {
          final y=h*((i/45+t*.12)%1);
          final path=Path();
          for(var j=0;j<=35;j++) {
            final x=w*j/35;
            final yy=y+h*.025*math.sin(j*.35+t*1.3+i*.3);
            if(j==0){path.moveTo(x,yy);}else{path.lineTo(x,yy);}
          }
          canvas.drawPath(path,stroke..strokeWidth=1.0+i%5*.3
            ..color=palette.at(i/45).withOpacity(.36*k));
        }
        break;
    }
  }
  @override
  bool shouldRepaint(ExpandedFxPainter old) =>
    old.mode != mode || old.k != k || old.palette != palette;
}
