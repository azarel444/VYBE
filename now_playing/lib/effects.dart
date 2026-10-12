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
    _avg = _avg * 0.95 + bass * 0.05;
    if (!enabled) return;
    if (bass > 0.25 && bass > _avg * 1.35 + 0.08 && now - _lastBeat > 0.45) {
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
      p.color = palette.at(f).withOpacity(_a((1 - f) * 0.35 * k));
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
