import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'effects.dart' show FxClock;
import 'palette.dart';

double _c01(double v) => v.clamp(0.0, 1.0).toDouble();

/// Wide, soft wedges of light that fan out from the cover and turn very
/// slowly. They brighten a little on bass. One path, one shader, one draw.
class OrbitRaysPainter extends CustomPainter {
  final FxClock clock;
  final ArtPalette palette;
  final Offset center;

  OrbitRaysPainter({
    required this.clock,
    required this.palette,
    required this.center,
    required Listenable repaint,
  }) : super(repaint: repaint);

  static const int _n = 9;

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock.t;
    final reach = size.longestSide * 1.2;
    final path = Path();
    for (int i = 0; i < _n; i++) {
      final base = i * 2 * math.pi / _n + t * 0.012;
      final half =
          (i.isEven ? 0.13 : 0.075) + 0.02 * math.sin(t * 0.2 + i.toDouble());
      path.moveTo(center.dx, center.dy);
      path.lineTo(center.dx + math.cos(base - half) * reach,
          center.dy + math.sin(base - half) * reach);
      path.lineTo(center.dx + math.cos(base + half) * reach,
          center.dy + math.sin(base + half) * reach);
      path.close();
    }
    final a = _c01(0.20 + 0.14 * clock.bass);
    canvas.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.radial(
          center,
          reach * 0.6,
          [palette.a.withOpacity(a), palette.a.withOpacity(0)],
        ),
    );
  }

  @override
  bool shouldRepaint(OrbitRaysPainter old) =>
      old.palette != palette || old.center != center;
}

/// The thin orbit rings around the cover, the glowing orbs that circle on
/// them, a dotted ring, and a few drifting bokeh lights.
class OrbitRingsPainter extends CustomPainter {
  final FxClock clock;
  final ArtPalette palette;
  final Offset center;
  final double artR;

  /// Skips the bokeh and the streaks (performance mode).
  final bool lite;

  /// Faint horizontal streaks near the bottom (landscape only).
  final bool streaks;

  OrbitRingsPainter({
    required this.clock,
    required this.palette,
    required this.center,
    required this.artR,
    required this.lite,
    required this.streaks,
    required Listenable repaint,
  }) : super(repaint: repaint);

  static const List<double> _orbAng = [0.35, 1.2, 2.2, 3.1, 4.0, 4.9, 5.6];
  static const List<double> _orbSpeed = [0.05, -0.04, 0.035, 0.06, -0.05, 0.04, -0.03];
  static const List<double> _orbRing = [1.46, 1.46, 1.62, 1.46, 1.62, 1.46, 1.62];
  static const List<double> _orbSize = [0.05, 0.035, 0.04, 0.03, 0.06, 0.04, 0.03];

  static const List<double> _bkAng = [0.6, 1.7, 2.6, 3.7, 4.4, 5.3, 5.9, 0.1];
  static const List<double> _bkRad = [1.9, 2.3, 1.8, 2.5, 2.1, 2.6, 1.95, 2.4];
  static const List<double> _bkSize = [0.03, 0.02, 0.025, 0.035, 0.018, 0.028, 0.022, 0.016];

  List<Offset>? _dots;

  void _prepareDots() {
    if (_dots != null) return;
    const n = 120;
    final r = artR * 1.54;
    _dots = List<Offset>.generate(n, (i) {
      final a = 2 * math.pi * i / n;
      return Offset(center.dx + math.cos(a) * r, center.dy + math.sin(a) * r);
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock.t;
    final bass = clock.bass;
    final main = palette.a;
    final light = Color.lerp(main, Colors.white, 0.55)!;

    // Rings: the one around the cover edge, the orbit ring, a faint outer one.
    final ring = Paint()..style = PaintingStyle.stroke;
    ring
      ..strokeWidth = 1.2
      ..color = light.withOpacity(0.55);
    canvas.drawCircle(center, artR * 1.46, ring);
    ring
      ..strokeWidth = 1.0
      ..color = light.withOpacity(0.25);
    canvas.drawCircle(center, artR * 1.62, ring);

    _prepareDots();
    canvas.drawPoints(
      ui.PointMode.points,
      _dots!,
      Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 2.0
        ..color = Colors.white.withOpacity(0.35),
    );

    // Orbs circling on the two rings.
    final p = Paint();
    for (int i = 0; i < _orbAng.length; i++) {
      final ang = _orbAng[i] + t * _orbSpeed[i];
      final rad = artR * _orbRing[i];
      final pos = Offset(center.dx + math.cos(ang) * rad,
          center.dy + math.sin(ang) * rad);
      final r = artR * _orbSize[i] * (1 + 0.25 * bass);
      p.style = PaintingStyle.fill;
      p.color = main.withOpacity(0.10);
      canvas.drawCircle(pos, r * 3.2, p);
      p.color = main.withOpacity(0.22);
      canvas.drawCircle(pos, r * 1.9, p);
      p.color = light.withOpacity(0.95);
      canvas.drawCircle(pos, r, p);
      p
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = light.withOpacity(0.5);
      canvas.drawCircle(pos, r * 2.2, p);
    }

    if (lite) return;

    // Bokeh: soft lights drifting slowly around the whole group.
    p.style = PaintingStyle.fill;
    for (int i = 0; i < _bkAng.length; i++) {
      final ang = _bkAng[i] + t * 0.01 * (1 + i % 3);
      final rad = artR * (_bkRad[i] + 0.08 * math.sin(t * 0.3 + i.toDouble()));
      final pos = Offset(center.dx + math.cos(ang) * rad,
          center.dy + math.sin(ang) * rad);
      final r = artR * _bkSize[i];
      final tw = 0.5 + 0.5 * math.sin(t * 0.9 + i * 1.7);
      p.color = main.withOpacity(_c01(0.10 + 0.08 * tw));
      canvas.drawCircle(pos, r * 2.6, p);
      p.color = light.withOpacity(_c01(0.40 + 0.30 * tw));
      canvas.drawCircle(pos, r, p);
    }

    if (streaks) {
      final w = size.width;
      final h = size.height;
      const ys = [0.88, 0.91, 0.94, 0.965];
      const lens = [0.40, 0.30, 0.22, 0.34];
      for (int i = 0; i < ys.length; i++) {
        final x1 = w * lens[i];
        final y = h * ys[i];
        canvas.drawLine(
          Offset(0, y),
          Offset(x1, y),
          Paint()
            ..strokeWidth = 2
            ..shader = ui.Gradient.linear(
              Offset(0, y),
              Offset(x1, y),
              [
                Colors.white.withOpacity(0.0),
                Colors.white.withOpacity(0.12),
                Colors.white.withOpacity(0.0),
              ],
              const [0.0, 0.5, 1.0],
            ),
        );
      }
    }
  }

  @override
  bool shouldRepaint(OrbitRingsPainter old) =>
      old.palette != palette ||
      old.center != center ||
      old.artR != artR ||
      old.lite != lite ||
      old.streaks != streaks;
}
