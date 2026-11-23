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
  final GlobalKey? artKey;
  final GlobalKey? layerKey;

  ParticlesPainter({
    required this.field,
    required this.palette,
    this.k = 1.0,
    this.artKey,
    this.layerKey,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint();
    final t = field.t;
    // Real artwork origin is resolved during paint, *after* layout.
    final source = artKey == null ? null
        : _artCenter(artKey!, size, layerKey: layerKey);
    if (artKey != null && source == null) return;
    final reach = math.sqrt(
        size.width * size.width + size.height * size.height);
    for (int i = 0; i < ParticleField.n; i++) {
      final phase = (field.y[i] + t * field.s[i]) % 1.0;
      final angle = field.ph[i] +
          0.18 * math.sin(t * 0.3 + field.x[i] * 9.0);
      final pos = source == null
          ? Offset(
              (field.x[i] + .015 * math.sin(t * 1.3 + field.ph[i])) * size.width,
              ((field.y[i] - t * field.s[i]) % 1.0) * size.height)
          : source + Offset(math.cos(angle), math.sin(angle)) *
              (phase * reach * 0.9);
      final fade = math.sin(phase * math.pi).clamp(0.0, 1.0).toDouble();
      final tw = 0.5 + 0.5 * math.sin(t * 2.0 + field.ph[i] * 3.0);
      final alpha = _a((0.25 + 0.30 * tw) * fade * k);
      final c = palette.at(field.x[i]);
      p.color = c.withOpacity(alpha * 0.25);
      canvas.drawCircle(pos, field.r[i] * 3.2, p);
      p.color = c.withOpacity(alpha);
      canvas.drawCircle(pos, field.r[i], p);
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

Offset? _artCenter(GlobalKey key, Size size, {GlobalKey? layerKey}) {
  final box = _artBox(key);
  final layer = layerKey?.currentContext?.findRenderObject();
  // Never guess screen center or reuse global coordinates as layer-local
  // coordinates. If either render box is missing, wait for actual layout.
  if (box == null || layer is! RenderBox ||
      !layer.attached || !layer.hasSize) return null;
  final globalCenter = box.localToGlobal(box.size.center(Offset.zero));
  return layer.globalToLocal(globalCenter);
}

/// Soft photographic bokeh with genuine filled defocus and light bleed.
/// Each depth plane drifts away from the artwork without outlined rings.
class GlowPainter extends CustomPainter {
  final FxClock clock;
  final ArtPalette palette;
  final double k;
  final double effectSize;
  final Offset origin;
  final GlobalKey? artKey;
  final GlobalKey? layerKey;

  GlowPainter({
    required this.clock,
    required this.palette,
    required this.k,
    this.effectSize = 1.0,
    this.origin = const Offset(.5,.5),
    this.artKey,
    this.layerKey,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock.t;
    final scale = effectSize.clamp(.35, 2.5);
    final shortest = math.min(size.width, size.height);
    final source = artKey == null
        ? Offset(size.width*origin.dx,size.height*origin.dy)
        : _artCenter(artKey!, size, layerKey: layerKey);
    if (source == null) return; // An art-less frame must not emit from center.
    for (var i=0;i<25;i++) {
      final seed=i*2.399963;
      final phase=((t*(.009+(i%7)*.0015)+i*.277)%1.0);
      final angle=seed + .22*math.sin(t*.11+i*1.3);
      final distance=shortest*(.03+phase*1.32);
      final pos=source+Offset(math.cos(angle),math.sin(angle))*distance;
      final depth=i%3;
      final radius=shortest*(depth==0 ? .028 : depth==1 ? .075 : .14)*
          scale*(.75+(i%5)*.11);
      final life=(math.min(phase/.18,1.0)*
          math.min((1-phase)/.18,1.0)).clamp(0.0,1.0);
      if(life<=0)continue;
      final color=palette.colors[i%3];
      final opacity=(k*life*(depth == 0 ? 0.53 : depth == 1 ? 0.30 : 0.18)*
          (.86+.14*math.sin(t*.54+seed))).clamp(0.0,1.0).toDouble();
      // Filled center, feathered aperture and broad atmospheric spill.
      canvas.drawCircle(pos,radius*2.2,Paint()..shader=ui.Gradient.radial(
        pos,radius*2.2,[
          color.withOpacity(opacity*.5),
          color.withOpacity(opacity*.28),
          color.withOpacity(0),
        ],[0,.38,1]));
      canvas.drawCircle(pos,radius,Paint()..shader=ui.Gradient.radial(
        pos,radius,[
          Color.lerp(color,Colors.white,.28)!.withOpacity(opacity),
          color.withOpacity(opacity*.76),
          color.withOpacity(opacity*.30),
          color.withOpacity(0),
        ],[0,.33,.77,1]));
    }
  }

  @override
  bool shouldRepaint(GlowPainter old) =>
      old.palette != palette || old.k != k ||
      old.effectSize != effectSize || old.origin != origin;
}

/// Aurora sweep: slow soft bands of the art colors roll across the screen.
class SweepPainter extends CustomPainter {
  final FxClock clock;
  final ArtPalette palette;
  final double k;
  final double effectSize;

  SweepPainter({
    required this.clock,
    required this.palette,
    required this.k,
    this.effectSize = 1.0,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    // Scale the sweep's pattern, not its rectangular render surface.
    final scale = effectSize.clamp(0.15, 3.0);
    final v = Offset(size.width * 1.25 * scale, size.height * 0.85 * scale);
    final p = (clock.t * 0.13) % 1.0;
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
  bool shouldRepaint(SweepPainter old) =>
      old.palette != palette || old.k != k || old.effectSize != effectSize;
}

/// Album-emitted Light Rays: luminous beam cores plus wide feathered spill.
/// Size controls both beam length and spread, never scales a clipped widget.
class RaysPainter extends CustomPainter {
  final FxClock clock;
  final GlobalKey artKey;
  final GlobalKey? layerKey;
  final Offset? pinnedOrigin;
  final ArtPalette palette;
  final double k;
  final double effectSize;
  final bool topOrigin;

  RaysPainter({
    required this.clock,
    required this.artKey,
    this.layerKey,
    this.pinnedOrigin,
    required this.palette,
    required this.k,
    this.effectSize = 1.0,
    this.topOrigin = false,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (k <= 0 || size.isEmpty) return;
    final c = topOrigin ? Offset(size.width * .5, 0)
        : pinnedOrigin != null
            ? Offset(size.width * pinnedOrigin!.dx,
                size.height * pinnedOrigin!.dy)
            : _artCenter(artKey, size, layerKey: layerKey);
    if (c == null) return;
    final sizeControl = effectSize.clamp(0.5, 2.5).toDouble();
    final reach = math.sqrt(size.width * size.width + size.height * size.height)
        * (0.40 + 0.45 * sizeControl);
    final strength = _a(k * (0.86 + 0.14 * clock.bass));
    const count = 10;
    const bands = 6;
    for (var i = 0; i < count; i++) {
      final angle = clock.t * .065 + i * 2 * math.pi / count
          + .07 * math.sin(clock.t * .31 + i * 1.4);
      final halfWidth = (0.07 + .055 * sizeControl) *
          (0.9 + .12 * math.sin(clock.t * .24 + i * 2.0));
      final color = palette.colors[i % 3];
      // Multiple nested wedges are softer near the outside and create a
      // much brighter luminous beam close to the source.
      for (var band = bands - 1; band >= 0; band--) {
        final portion = (band + 1) / bands;
        final outerHalfWidth = halfWidth * portion;
        final intensity = math.pow(1.0 - band / (bands + 1), 1.1).toDouble();
        final alpha = _a(strength * intensity);
        final wedge = Path()
          ..moveTo(c.dx, c.dy)
          ..lineTo(c.dx + reach * math.cos(angle - outerHalfWidth),
              c.dy + reach * math.sin(angle - outerHalfWidth))
          ..lineTo(c.dx + reach * math.cos(angle + outerHalfWidth),
              c.dy + reach * math.sin(angle + outerHalfWidth))
          ..close();
        canvas.drawPath(wedge, Paint()..shader = ui.Gradient.radial(
          c, reach,
          [
            color.withOpacity(_a(alpha * .68)),
            color.withOpacity(_a(alpha * .36)),
            color.withOpacity(_a(alpha * .16)),
            color.withOpacity(0),
          ],
          const [0.0, 0.28, 0.69, 1.0],
        ));
      }
    }
  }

  @override
  bool shouldRepaint(RaysPainter old) =>
      old.palette != palette || old.k != k ||
      old.effectSize != effectSize || old.topOrigin != topOrigin;
}

/// Timestamped kick-like low-frequency onsets from ACTUAL Android FFT.
/// No simulated beat clock, repeated frame sampling, or free-running pulses.
class RippleState {
  // Shared event stream for Beat Pulse, Beat Ripples, and Bass Shockwave.
  // Only new Android FFT frames can add events; the synthetic visualizer
  // never generates a kick.
  final List<double> starts = [];
  int _lastFftFrame = -1;
  double _lowFloor = 0.0;
  double _lastLow = 0.0;
  double _lastMid = 0.0;
  double _riseFloor = 0.0;
  double _lastBeat = -10.0;
  bool _primed = false;

  void _reset() {
    _primed = false;
    _lastFftFrame = -1;
    _lowFloor = 0.0;
    _lastLow = 0.0;
    _lastMid = 0.0;
    _riseFloor = 0.0;
    _lastBeat = -10.0;
    starts.clear();
  }

  /// A short kick-only impulse: quick attack followed by natural decay.
  /// Zero between detected attacks; no free-running or simulated pulse.
  double pulseAt(double now) {
    if (starts.isEmpty) return 0.0;
    final age = now - starts.last;
    if (age < 0 || age >= 0.27) return 0.0;
    final attack = (age / .012).clamp(0.0, 1.0).toDouble();
    final decay = math.pow(1.0 - age / .27, 2.3).toDouble();
    return (attack * decay).clamp(0.0, 1.0).toDouble();
  }

  void update(double now, Uint8List? fft, int fftFrame, bool playing) {
    starts.removeWhere((start) => now - start > 1.45);
    if (!playing || fft == null || fft.length < 96) {
      _reset();
      return;
    }
    if (_lastFftFrame == fftFrame) return;
    _lastFftFrame = fftFrame;

    // Android sends 96 logarithmically spaced, un-smoothed bands.
    // Use the low-frequency punch, with an upper-bass shoulder. Compare
    // its rise to midrange attacks to reject snare/voice/mix transients.
    var lowSum = 0.0;
    var weightSum = 0.0;
    for (var i = 5; i < 30; i++) {
      final weight = i < 23 ? 1.0 : 0.45;
      lowSum += (fft[i] / 255.0) * weight;
      weightSum += weight;
    }
    final low = lowSum / weightSum;
    var midSum = 0.0;
    for (var i = 32; i < 60; i++) {
      midSum += fft[i] / 255.0;
    }
    final mid = midSum / 28.0;
    if (!_primed) {
      _primed = true;
      _lowFloor = low;
      _lastLow = low;
      _lastMid = mid;
      return;
    }

    final lowRise = math.max(0.0, low - _lastLow);
    final midRise = math.max(0.0, mid - _lastMid);
    final riseGate = math.max(0.029, _riseFloor * 2.25);
    final energyGate = math.max(0.028, _lowFloor * 0.11);
    final lowDominant = low >= mid * 0.79 &&
        lowRise >= midRise * 1.12 + 0.006;
    final hit = low >= 0.105 &&
        lowRise >= riseGate &&
        low >= _lowFloor + energyGate &&
        lowDominant &&
        now - _lastBeat >= 0.22;

    // Follow the musical bed slowly, without letting the candidate kick
    // shift its own detection threshold before testing it.
    _lowFloor += (low - _lowFloor) * 0.055;
    _riseFloor += (lowRise - _riseFloor) * 0.10;
    _lastLow = low;
    _lastMid = mid;
    if (hit) {
      _lastBeat = now;
      starts.add(now);
      if (starts.length > 8) starts.removeAt(0);
    }
  }
}

/// Rings that expand outward from the art on each beat, like water.
class RipplesPainter extends CustomPainter {
  final RippleState state;
  final FxClock clock;
  final GlobalKey artKey;
  final GlobalKey? layerKey;
  final Offset? pinnedOrigin;
  final ArtPalette palette;
  final double k;

  RipplesPainter({
    required this.state,
    required this.clock,
    required this.artKey,
    this.layerKey,
    this.pinnedOrigin,
    required this.palette,
    required this.k,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (state.starts.isEmpty) return;
    final c = pinnedOrigin != null
        ? Offset(size.width * pinnedOrigin!.dx,
            size.height * pinnedOrigin!.dy)
        : _artCenter(artKey, size, layerKey: layerKey);
    if (c == null) return;
    final box = _artBox(artKey);
    final baseR = box != null ? box.size.shortestSide / 2
        : size.shortestSide * .26;
    final maxR = math.sqrt(size.width * size.width + size.height * size.height) * 0.55;
    final p = Paint()..style = PaintingStyle.stroke;
    for (final s in state.starts) {
      // A shorter visible echo reads as one kick-synced ripple rather than
      // an unrelated ring still travelling several beats later.
      final f = (clock.t - s) / 1.3;
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
        final x = w * (0.12 + i * 0.26 + 0.115 * math.sin(t * 0.31 + i));
        final y = h * (0.22 + 0.17 * (i % 3) + 0.11 * math.cos(t * 0.27 + i));
        final radius = math.max(w, h) * (0.28 + 0.09 * math.sin(t * 0.47 + i));
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
  final GlobalKey? artKey;
  final GlobalKey? layerKey;
  final Offset? pinnedOrigin;
  final RippleState? bassOnsets;
  ExpandedFxPainter({required this.mode, required this.clock,
    required this.palette, required this.k, this.artKey, this.layerKey,
    this.pinnedOrigin, this.bassOnsets, required Listenable repaint})
    : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (k <= 0) return;
    final w = size.width, h = size.height, t = clock.t;
    final center = pinnedOrigin != null
        ? Offset(w * pinnedOrigin!.dx, h * pinnedOrigin!.dy)
        // FX gallery previews intentionally have no live album widget.
        : artKey == null ? Offset(w * .5, h * .5)
            : _artCenter(artKey!, size, layerKey: layerKey);
    // Live Now Playing always supplies artKey: never guess when absent.
    if (center == null) return;
    final bright = palette.a.withOpacity((.72 * k).clamp(0.0, 1.0));
    final second = palette.b.withOpacity((.68 * k).clamp(0.0, 1.0));
    final stroke = Paint()..style = PaintingStyle.stroke..strokeWidth = 2.5..color = bright;
    switch (mode) {
      case 0: // Liquid refraction: flowing caustic bands and specular highlights.
        // This is a canvas approximation; it does not displace source pixels.
        for (var i = 0; i < 14; i++) {
          final path = Path();
          for (var j = 0; j <= 80; j++) {
            final x = w * j / 80;
            final u = x / w;
            final y = h * (i + .6) / 14 + h * (.037 + .012 * clock.bass) *
                math.sin(u * 10.5 + t * .72 + i * .58) +
                h * .022 * math.sin(u * 18.0 - t * .48 + i * 1.7);
            if (j == 0) { path.moveTo(x, y); } else { path.lineTo(x, y); }
          }
          final color = palette.at(i / 14);
          canvas.drawPath(path, Paint()..style = PaintingStyle.stroke
            ..strokeWidth = 13 * k..color = color.withOpacity(.075 * k)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12));
          canvas.drawPath(path, Paint()..style = PaintingStyle.stroke
            ..strokeWidth = 1.2 + 1.8 * k
            ..color = Color.lerp(color, Colors.white, .52)!.withOpacity(.50 * k));
        }
        break;
      case 1: // Bass shockwave: energy-responsive expanding rings
        final shockCenter = center;
        for (final onset in (bassOnsets?.starts ?? const <double>[])) {
          final f = (t - onset) / 0.85;
          if (f < 0 || f > 1) continue;
          final radius = (0.08 + f * .7) * math.min(w, h);
          final color = palette.at(f);
          canvas.drawCircle(shockCenter, radius, Paint()..style = PaintingStyle.stroke
            ..strokeWidth = 15 + 18 * clock.bass
            ..color = color.withOpacity((1 - f) * .22 * k)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 13));
          canvas.drawCircle(shockCenter, radius, Paint()..style = PaintingStyle.stroke
            ..strokeWidth = 2 + 7 * clock.bass * k
            ..color = color.withOpacity((1 - f) * .82 * k));
        }
        break;
      case 2: // Aurora curtains: luminous, moving translucent ribbons.
        for (var i = 0; i < 7; i++) {
          final path = Path();
          for (var j = 0; j <= 64; j++) {
            final y = h * j / 64;
            final x = w * (.10 + i * .135) + w * .12 *
              math.sin(y / h * 4.4 + t * .40 + i * .6);
            if (j == 0) {path.moveTo(x,y);} else {path.lineTo(x,y);}
          }
          final color = palette.at(i / 7);
          canvas.drawPath(path, Paint()..style = PaintingStyle.stroke
            ..strokeWidth = w * (.11 + .025 * clock.bass)
            ..color = color.withOpacity(.13 * k)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22));
          canvas.drawPath(path, Paint()..style = PaintingStyle.stroke
            ..strokeWidth = w * .027
            ..color = color.withOpacity((.26 + .12 * clock.bass) * k)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
          canvas.drawPath(path, Paint()..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = Color.lerp(color, Colors.white, .55)!.withOpacity(.5 * k));
        }
        break;
      case 3: // Vortex: visible rotating spirals and receding tunnel rings.
        final reach = math.sqrt(w * w + h * h) * .95;
        for (var i = 0; i < 8; i++) {
          final path = Path();
          for (var j = 0; j <= 144; j++) {
            final f = j / 144.0;
            final radius = reach * f;
            final a = t * .82 + i * 2 * math.pi / 8 +
                f * math.pi * 5.5;
            final pt = center + Offset(math.cos(a), math.sin(a)) * radius;
            if (j == 0) { path.moveTo(pt.dx, pt.dy); }
            else { path.lineTo(pt.dx, pt.dy); }
          }
          final color = palette.at(i / 8);
          canvas.drawPath(path, Paint()..style = PaintingStyle.stroke
            ..strokeWidth = 23..color = color.withOpacity(.28 * k)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 21));
          canvas.drawPath(path, Paint()..style = PaintingStyle.stroke
            ..strokeWidth = 5..color = color.withOpacity(.47 * k)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
          canvas.drawPath(path, Paint()..style = PaintingStyle.stroke
            ..strokeWidth = 1.6..color =
                Color.lerp(color, Colors.white, .65)!.withOpacity(.82 * k));
        }
        for (var i = 0; i < 6; i++) {
          final radius = (i + .8) / 6 * math.min(w,h) *
              (.82 + .05 * math.sin(t * .9 + i));
          canvas.drawCircle(center, radius, Paint()
            ..style = PaintingStyle.stroke..strokeWidth = 1.3
            ..color = palette.at(i / 6).withOpacity(.24 * k));
        }
        break;
      case 4: // Jagged electrical branches emitting from the cover.
        final reach = math.sqrt(w*w + h*h) * .9;
        final flicker = (t * 13).floor();
        for (var i = 0; i < 9; i++) {
          final path = Path();
          final direction = i * 2.399963 + .13 * math.sin(t*.35+i);
          for (var j=0; j <= 54; j++) {
            final f=j/54.0;
            final radius=reach*(.04+f*.94);
            final a=direction + f*.12 +
                (.035+.045*f)*math.sin(j*5.71+flicker*.91+i*7.4) +
                .018*math.sin(j*13.13-flicker*1.17+i*2.3);
            final pt=center+Offset(math.cos(a),math.sin(a))*radius;
            if (j==0) {path.moveTo(pt.dx,pt.dy);}
            else {path.lineTo(pt.dx,pt.dy);}
          }
          final c=palette.at(i/9);
          canvas.drawPath(path, Paint()..style=PaintingStyle.stroke
            ..strokeWidth=22..color=c.withOpacity(.23*k)
            ..maskFilter=const MaskFilter.blur(BlurStyle.normal,17));
          canvas.drawPath(path, Paint()..style=PaintingStyle.stroke
            ..strokeWidth=4.0..color=c.withOpacity(.62*k)
            ..maskFilter=const MaskFilter.blur(BlurStyle.normal,4));
          canvas.drawPath(path, Paint()..style=PaintingStyle.stroke
            ..strokeWidth=1.15..color=Colors.white.withOpacity(.84*k));
        }
        break;
      case 5: // Prism shards: sparse glass facets, no full wireframe outlines.
        for (var i = 0; i < 12; i++) {
          final x = w * ((i * .61803398875 + .12 + t * (.055 + (i % 3) * .017)) % 1);
          final y = h * ((i * .41421356237 + .23 + t * (.034 + (i % 4) * .013)) % 1);
          final r = 23 + (i % 4) * 21.0;
          final a = t * (.34 + (i % 4) * .12) + i * 1.73;
          final p0 = Offset(x + math.cos(a)*r, y + math.sin(a)*r);
          final p1 = Offset(x + math.cos(a+2.1)*r, y + math.sin(a+2.1)*r);
          final p2 = Offset(x + math.cos(a+4.2)*r, y + math.sin(a+4.2)*r);
          final path = Path()..moveTo(p0.dx,p0.dy)..lineTo(p1.dx,p1.dy)
            ..lineTo(p2.dx,p2.dy)..close();
          final color = palette.at(i / 12);
          canvas.drawPath(path, Paint()..color = color.withOpacity(.12 * k));
          // Highlight only a single lit facet edge, never the entire perimeter.
          final edge = Path()..moveTo(p0.dx,p0.dy)..lineTo(p1.dx,p1.dy);
          canvas.drawPath(edge, Paint()..style = PaintingStyle.stroke
            ..strokeWidth = 6..color = Colors.white.withOpacity(.20 * k)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
          canvas.drawPath(edge, Paint()..style = PaintingStyle.stroke
            ..strokeWidth = 1.1..color = Colors.white.withOpacity(.68 * k));
          if (i % 3 == 0) {
            final glint = p0 + (p1-p0) * ((math.sin(t * .8 + i)+1)*.5);
            canvas.drawCircle(glint, 2.5, Paint()..color = Colors.white.withOpacity(.65*k)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
          }
        }
        break;
      case 6: // Persistent luminous trails with a fading afterglow.
        // The outgoing tail survives the next light's start: no disappearing
        // full-length path when a moving tip wraps its animation cycle.
        final reach = math.sqrt(w*w+h*h) * .82;
        double smooth(double a, double b, double v) {
          final x = ((v-a)/(b-a)).clamp(0.0,1.0).toDouble();
          return x*x*(3-2*x);
        }
        for (var i=0; i<11; i++) {
          final phase = (t*(.17+i*.008)+i*.19)%1.0;
          final c=palette.at(i/11);
          // Draw the prior generation first, then the current bright head.
          for (var gen=1;gen>=0;gen--) {
            final age=phase+gen;
            final fade=(smooth(0,.22,age) *
                (1-smooth(1.05,1.90,age))).clamp(0.0,1.0).toDouble();
            if(fade<.003) continue;
            final headRadius=reach*(.10+age*.94);
            final path=Path();
            Offset head=center;
            for (var j=0;j<=84;j++) {
              final fraction=j/84.0;
              final radius=headRadius*fraction;
              final angle=i*2.399963 + radius/reach*1.04 +
                  .22*math.sin(radius/reach*5.9-t*.62+i*.8);
              final point=center+
                  Offset(math.cos(angle),math.sin(angle))*radius;
              if(j==0){path.moveTo(point.dx,point.dy);}
              else {path.lineTo(point.dx,point.dy);}
              head=point;
            }
            // Bright at the tip, progressively transparent behind it.
            // The radial gradient also dims the old on-screen tail as its
            // invisible head continues outward beyond the viewport.
            ui.Shader tailShader(double alpha) => ui.Gradient.radial(
              center,headRadius,[
                c.withOpacity(0),
                c.withOpacity(alpha*.06),
                c.withOpacity(alpha*.25),
                c.withOpacity(alpha*.62),
                c.withOpacity(alpha),
              ],const [0,.16,.48,.79,1]);
            canvas.drawPath(path,Paint()
              ..style=PaintingStyle.stroke..strokeWidth=25
              ..shader=tailShader(.34*k*fade)
              ..maskFilter=const MaskFilter.blur(BlurStyle.normal,21));
            canvas.drawPath(path,Paint()
              ..style=PaintingStyle.stroke..strokeWidth=7
              ..shader=tailShader(.68*k*fade)
              ..maskFilter=const MaskFilter.blur(BlurStyle.normal,7));
            canvas.drawPath(path,Paint()
              ..style=PaintingStyle.stroke..strokeWidth=2
              ..shader=tailShader(.92*k*fade));
            canvas.drawCircle(head,26,Paint()..shader=ui.Gradient.radial(
              head,26,[
                c.withOpacity(.65*k*fade),
                c.withOpacity(.20*k*fade),
                c.withOpacity(0),
              ],const [0,.35,1]));
            canvas.drawCircle(head,2.8,Paint()
              ..color=Colors.white.withOpacity(.97*k*fade));
          }
        }
        break;
      case 7: // Polar morphing wireframe, projected from album center.
        final reach=math.sqrt(w*w+h*h)*.8;
        for (var ring=1;ring<=13;ring++) {
          final path=Path();
          for (var j=0;j<=120;j++) {
            final angle=j/120.0*2*math.pi;
            final radius=ring/13.0*reach*
                (1+.055*math.sin(angle*7+t*.58+ring*.4));
            final pt=center+Offset(math.cos(angle),math.sin(angle))*radius;
            if(j==0){path.moveTo(pt.dx,pt.dy);}
            else {path.lineTo(pt.dx,pt.dy);}
          }
          canvas.drawPath(path,Paint()..style=PaintingStyle.stroke
            ..strokeWidth=1.1..color=palette.at(ring/13).withOpacity(.48*k));
        }
        for (var spoke=0;spoke<24;spoke++) {
          final path=Path();
          for(var j=0;j<=36;j++) {
            final f=j/36.0;
            final angle=spoke*2*math.pi/24+.055*math.sin(f*9-t*.62);
            final radius=reach*f;
            final pt=center+Offset(math.cos(angle),math.sin(angle))*radius;
            if(j==0){path.moveTo(pt.dx,pt.dy);}
            else {path.lineTo(pt.dx,pt.dy);}
          }
          canvas.drawPath(path,Paint()..style=PaintingStyle.stroke
            ..strokeWidth=.95..color=second);
        }
        break;
      case 8: // Particle currents
        for (var i=0;i<220;i++) {
          final f=(i*.6180339+t*.04*(1+i%4))%1;
          final a=i*.47+t*.45;
          final r=(.08+f*.47)*w;
          final pt=center+Offset(math.cos(a+f*8)*r,math.sin(a+f*8)*r*h/w);
          final c = palette.at(i / 220);
          if (i % 6 == 0) {
            canvas.drawCircle(pt, 5.5, Paint()..color = c.withOpacity(.24 * k)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
          }
          canvas.drawCircle(pt, 1.0 + (i % 4) * .65,
            Paint()..color = c.withOpacity(.78 * k));
        }
        break;
      case 9: // Holographic interference: interference lines + RGB fringes.
        for (var i = 0; i < 55; i++) {
          final y = h * ((i / 55 + t * .075) % 1);
          final path = Path();
          for (var j = 0; j <= 45; j++) {
            final x = w * j / 45;
            final yy = y + h * .014 * math.sin(j * .3 + t * 1.2 + i * .33);
            if (j == 0) {path.moveTo(x,yy);} else {path.lineTo(x,yy);}
          }
          final c = palette.at(i / 55);
          canvas.drawPath(path, Paint()..style = PaintingStyle.stroke
            ..strokeWidth = 1.1..color = c.withOpacity(.45 * k));
          if (i % 5 == 0) {
            canvas.save();
            canvas.translate(0, 2.5);
            canvas.drawPath(path, Paint()..style = PaintingStyle.stroke
              ..strokeWidth = 1.5..color = const Color(0xFF00DBFF).withOpacity(.35 * k));
            canvas.translate(0, -5);
            canvas.drawPath(path, Paint()..style = PaintingStyle.stroke
              ..strokeWidth = 1.5..color = const Color(0xFFFF42B7).withOpacity(.35 * k));
            canvas.restore();
          }
        }
        break;
    }
  }
  @override
  bool shouldRepaint(ExpandedFxPainter old) =>
    old.mode != mode || old.k != k || old.palette != palette;
}
