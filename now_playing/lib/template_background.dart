import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'palette.dart';

/// Lightweight, procedural backgrounds: one visual language per accent preset.
/// Drawn behind layouts and FX; no video, images, blur layers or extra ticker.
class TemplateBackgroundPainter extends CustomPainter {
  final ArtPalette palette;
  final int preset;
  final double time;
  final double motion;
  final double darkness;
  TemplateBackgroundPainter({required this.palette, required this.preset,
    required this.time, required this.motion, required this.darkness});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final rect = Offset.zero & size;
    final colors = [palette.a, palette.b, palette.c];
    final t = time * motion;
    canvas.drawRect(rect, Paint()..color = const Color(0xFF050811));
    final base = Paint()..shader = RadialGradient(
      center: Alignment(math.sin(t * .09) * .35, math.cos(t * .07) * .3),
      radius: 1.25,
      colors: [colors[preset % 3].withOpacity(.24), const Color(0xFF050811)],
    ).createShader(rect);
    canvas.drawRect(rect, base);
    final mode = preset % 8;
    if (mode == 0 || mode == 4) {
      // Aurora / silk: broad translucent ribbons that drift independently.
      for (var i = 0; i < 6; i++) {
        final path = Path();
        for (var x = -20.0; x <= w + 30; x += 12) {
          final y = h * (.18 + i * .13) + math.sin(x / (w + 1) * 6 + t * (.16 + i * .017) + i) * h * .12;
          if (x == -20) { path.moveTo(x, y); } else { path.lineTo(x, y); }
        }
        canvas.drawPath(path, Paint()..color = colors[i % 3].withOpacity(.10 + (i % 2) * .05)
          ..style = PaintingStyle.stroke..strokeWidth = h * .075..strokeCap = StrokeCap.round);
      }
    } else if (mode == 1 || mode == 5) {
      // Solar currents / ember: sweeping concentric arcs.
      for (var i = 0; i < 12; i++) {
        final r = math.min(w, h) * (.17 + i * .085);
        canvas.drawArc(Rect.fromCircle(center: Offset(w * .55, h * .58), radius: r),
          t * (.025 + i * .003) + i * .4, math.pi * (.5 + i % 3 * .2), false,
          Paint()..color = colors[i % 3].withOpacity(.10)..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 + (i % 3).toDouble());
      }
    } else if (mode == 2 || mode == 6) {
      // Water / ice: refracted diagonal waves.
      for (var i = 0; i < 18; i++) {
        final path = Path();
        for (var y = -20.0; y <= h + 20; y += 14) {
          final x = w * i / 17 + math.sin(y / (h + 1) * 8 + t * .14 + i * .4) * w * .065;
          if (y == -20) { path.moveTo(x, y); } else { path.lineTo(x, y); }
        }
        canvas.drawPath(path, Paint()..color = colors[i % 3].withOpacity(.12)
          ..style = PaintingStyle.stroke..strokeWidth = 1.2);
      }
    } else if (mode == 3) {
      // Botanical / geometric: slow orbital petals.
      for (var i = 0; i < 20; i++) {
        final a = i * math.pi * 2 / 20 + t * .025;
        final radius = math.min(w, h) * (.23 + .12 * math.sin(i * 1.7 + t * .06));
        final p = Offset(w * .5 + math.cos(a) * radius, h * .5 + math.sin(a) * radius);
        canvas.drawOval(Rect.fromCenter(center: p, width: w * .18, height: h * .09),
          Paint()..color = colors[i % 3].withOpacity(.09));
      }
    } else {
      // Prism / minimal: floating light planes and fine lines.
      for (var i = 0; i < 13; i++) {
        final x = w * ((i * .183 + .08 + math.sin(t * .045 + i) * .025) % 1);
        final y = h * ((i * .137 + .07 + math.cos(t * .052 + i) * .025) % 1);
        final path = Path()..moveTo(x, y)..lineTo(x + w * .16, y - h * .12)
          ..lineTo(x + w * .24, y + h * .08)..close();
        canvas.drawPath(path, Paint()..color = colors[i % 3].withOpacity(.06 + (i % 3) * .02));
        canvas.drawPath(path, Paint()..color = colors[i % 3].withOpacity(.14)
          ..style = PaintingStyle.stroke..strokeWidth = .7);
      }
    }
    // Match the existing background darkness control.
    canvas.drawRect(rect, Paint()..color = Colors.black.withOpacity((darkness * .27).clamp(0.0, .75)));
  }

  @override
  bool shouldRepaint(covariant TemplateBackgroundPainter old) =>
    old.time != time || old.motion != motion || old.preset != preset ||
    old.palette != palette || old.darkness != darkness;
}
