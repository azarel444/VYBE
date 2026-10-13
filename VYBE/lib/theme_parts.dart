import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Fine concentric grooves over the record surface. Drawn once: it sits
/// inside the rotating, cached part of the record, so it costs nothing per
/// frame.
class VinylGroovesPainter extends CustomPainter {
  /// Label diameter as a fraction of the record diameter.
  final double labelFrac;

  const VinylGroovesPainter({required this.labelFrac});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final inner = r * labelFrac * 1.1;
    final outer = r * 0.975;

    // A little darkening so the cover reads as vinyl, not as a photo.
    canvas.drawCircle(c, r, Paint()..color = const Color(0x59000000));

    // Smooth band between the label and the first groove.
    canvas.drawCircle(
      c,
      inner,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.03
        ..color = const Color(0x66000000),
    );

    final step = math.max(2.2, r * 0.011);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    var i = 0;
    for (var rad = inner + r * 0.03; rad < outer; rad += step) {
      p.color = (i % 2 == 0) ? const Color(0x0DFFFFFF) : const Color(0x1F000000);
      canvas.drawCircle(c, rad, p);
      i++;
    }

    // A few wider gaps between "tracks".
    final gap = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2.5, r * 0.012)
      ..color = const Color(0x40000000);
    for (final f in const [0.62, 0.74, 0.86]) {
      canvas.drawCircle(c, r * f, gap);
    }

    // Bright rim and a dark ring just inside it.
    canvas.drawCircle(
      c,
      r - 0.8,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = const Color(0x59FFFFFF),
    );
    canvas.drawCircle(
      c,
      r * 0.985,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.02
        ..color = const Color(0x4D000000),
    );
  }

  @override
  bool shouldRepaint(VinylGroovesPainter old) => old.labelFrac != labelFrac;
}

/// A lamp shining on the record. It stays still while the record spins
/// beneath it, which is what makes the record look like a real object:
/// two opposite wedges of light plus a soft highlight.
class VinylLightPainter extends CustomPainter {
  const VinylLightPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final circle = Rect.fromCircle(center: c, radius: r);

    canvas.save();
    canvas.clipPath(Path()..addOval(circle));

    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const SweepGradient(
          center: Alignment.center,
          startAngle: 0,
          endAngle: 2 * math.pi,
          colors: [
            Color(0x00FFFFFF),
            Color(0x00FFFFFF),
            Color(0x3DFFFFFF),
            Color(0x00FFFFFF),
            Color(0x00FFFFFF),
            Color(0x29FFFFFF),
            Color(0x00FFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: [0.0, 0.06, 0.11, 0.17, 0.56, 0.61, 0.66, 1.0],
          transform: GradientRotation(-1.476),
        ).createShader(circle),
    );

    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(0.45, -0.5),
          radius: 0.9,
          colors: [Color(0x26FFFFFF), Color(0x00FFFFFF)],
        ).createShader(circle),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(VinylLightPainter old) => false;
}

/// Clips a child to a polygon (used for the diagonal cut).
class PolyClipper extends CustomClipper<Path> {
  final List<Offset> points;
  const PolyClipper(this.points);

  @override
  Path getClip(Size size) => Path()..addPolygon(points, true);

  @override
  bool shouldReclip(PolyClipper old) => true;
}

/// A glowing white line from [a] to [b].
class CutLinePainter extends CustomPainter {
  final Offset a;
  final Offset b;
  const CutLinePainter({required this.a, required this.b});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      a,
      b,
      Paint()
        ..color = const Color(0x66FFFFFF)
        ..strokeWidth = 7
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawLine(
      a,
      b,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(CutLinePainter old) => old.a != a || old.b != b;
}

/// A soft black shadow along the cut line, on the side the bars grow toward.
/// It is darkest at the line and fades out. Drawn once and cached.
class CutShadePainter extends CustomPainter {
  final Offset a;
  final Offset b;
  final Offset normal;
  final double reach;
  const CutShadePainter({
    required this.a,
    required this.b,
    required this.normal,
    required this.reach,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final dir = (b - a) / (b - a).distance;
    // Run a little past both ends so the shadow does not fade at the edges.
    final start = a - dir * reach + normal * (reach * 0.45);
    final end = b + dir * reach + normal * (reach * 0.45);
    canvas.drawLine(
      start,
      end,
      Paint()
        ..color = const Color(0xB3000000)
        ..strokeWidth = reach * 0.9
        ..strokeCap = StrokeCap.butt
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, reach * 0.35),
    );
  }

  @override
  bool shouldRepaint(CutShadePainter old) =>
      old.a != a || old.b != b || old.normal != normal || old.reach != reach;
}
