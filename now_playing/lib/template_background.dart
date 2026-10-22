import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'palette.dart';

/// New background collection. Only Golden Hour (preset 14) is implemented.
/// Other presets deliberately use a neutral stage until redesigned.
class TemplateBackgroundPainter extends CustomPainter {
  final ArtPalette palette;
  final int preset;
  final double time, motion, darkness;
  TemplateBackgroundPainter({
    required this.palette, required this.preset,
    required this.time, required this.motion, required this.darkness,
  });

  static double _fract(double v) => v - v.floorToDouble();
  static double _rand(int n, int salt) =>
      _fract(math.sin(n * 127.1 + salt * 311.7) * 43758.5453);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0) return;
    final full = Offset.zero & size;
    canvas.drawRect(full, Paint()..color = const Color(0xFF06070D));
    if (preset != 14) {
      canvas.drawRect(full, Paint()..color = Colors.black.withOpacity(
          darkness.clamp(0.0, 1.0)));
      return;
    }
    final t = time * motion;
    final horizon = h * .73;
    final source = Offset(w * .52 + math.sin(t * .10) * w * .025,
        horizon - h * .055);
    final gold = palette.a;
    final amber = palette.b;
    final pale = const Color(0xFFFFF2C6);

    void halo(Offset center, double radius, Color color, double alpha) {
      canvas.drawCircle(center, radius, Paint()
        ..shader = RadialGradient(
          colors: [
            color.withOpacity(alpha.clamp(0.0, 1.0)),
            color.withOpacity((alpha * .30).clamp(0.0, 1.0)),
            color.withOpacity(0),
          ],
          stops: const [0, .27, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius)));
    }

    // The scene is a dark atmospheric stage, not a flat black field.
    canvas.drawRect(full, Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [
          const Color(0xFF05060D),
          Color.lerp(const Color(0xFF080810), amber, .09)!,
          Color.lerp(const Color(0xFF09080C), gold, .17)!,
          const Color(0xFF09070A),
        ],
        stops: const [0, .46, .76, 1],
      ).createShader(full));

    // Wide atmospheric bloom around the distant light source.
    halo(source, w * .55, amber, .20);
    halo(source, w * .27, gold, .29);
    halo(source, w * .115, pale, .65);

    // Tapered volumetric-looking rays, animated with independent phase.
    for (var i = 0; i < 66; i++) {
      final a = -math.pi + i * (2 * math.pi / 66);
      final drift = math.sin(t * .11 + i * 1.71) * .035;
      final angle = a + drift;
      final length = math.max(w, h) * (1.0 + _rand(i, 4) * .75);
      final spread = .006 + _rand(i, 7) * .023;
      final near = 5.0 + _rand(i, 8) * 15;
      final p1 = source + Offset(math.cos(angle - spread) * near,
          math.sin(angle - spread) * near);
      final p2 = source + Offset(math.cos(angle + spread) * near,
          math.sin(angle + spread) * near);
      final p3 = source + Offset(math.cos(angle + spread) * length,
          math.sin(angle + spread) * length);
      final p4 = source + Offset(math.cos(angle - spread) * length,
          math.sin(angle - spread) * length);
      final opacity = (.017 + _rand(i, 9) * .075) *
          (.8 + .2 * math.sin(t * .35 + i));
      final ray = Path()..moveTo(p1.dx, p1.dy)
        ..lineTo(p2.dx, p2.dy)..lineTo(p3.dx, p3.dy)
        ..lineTo(p4.dx, p4.dy)..close();
      canvas.drawPath(ray, Paint()
        ..shader = RadialGradient(
          center: Alignment(
            (source.dx / w - .5) * 2,
            (source.dy / h - .5) * 2),
          radius: 1.3,
          colors: [pale.withOpacity(opacity), amber.withOpacity(0)],
        ).createShader(full));
    }

    // Horizon glow, with the strongest luminosity at the vanishing point.
    final horizonRect = Rect.fromLTWH(0, horizon - h * .035, w, h * .10);
    canvas.drawRect(horizonRect, Paint()
      ..shader = LinearGradient(colors: [
        amber.withOpacity(0), amber.withOpacity(.16),
        pale.withOpacity(.72), amber.withOpacity(.16),
        amber.withOpacity(0),
      ], stops: const [0, .25, .5, .75, 1]).createShader(horizonRect));
    halo(source, w * .07, pale, .92);
    halo(source, w * .022, Colors.white, .94);

    // Reflective lower stage: many fading horizontal streaks rather than
    // a hard-edged geometric floor.
    for (var i = 0; i < 44; i++) {
      final q = (i + 1) / 45;
      final y = horizon + q * q * (h - horizon);
      final shimmer = math.sin(t * .55 + i * 2.9);
      final width = w * (.012 + q * .42) * (.8 + .2 * shimmer);
      final x = source.dx + math.sin(t * .24 + i * 1.8) * w * q * .025;
      final alpha = (.23 * (1 - q) + .025) * (.75 + .25 * shimmer);
      canvas.drawLine(Offset(x - width, y), Offset(x + width, y),
        Paint()..color = amber.withOpacity(alpha.clamp(0.0, 1.0))
          ..strokeWidth = .6 + q * 2.5
          ..strokeCap = StrokeCap.round);
    }

    // Foreground dust in several depth layers, moving across the screen.
    for (var i = 0; i < 115; i++) {
      final depth = .25 + _rand(i, 15) * .75;
      final x = w * _fract(_rand(i, 16) + t * (.001 + depth * .002));
      final y = h * _fract(_rand(i, 17) - t * (.0015 + depth * .003));
      final twinkle = .55 + .45 * math.sin(t * (.6 + depth) + i * 2.1);
      final radius = .4 + depth * 1.35;
      canvas.drawCircle(Offset(x, y), radius,
        Paint()..color = pale.withOpacity(
          (.09 + .35 * depth * twinkle).clamp(0.0, 1.0)));
    }

    canvas.drawRect(full, Paint()..color = Colors.black.withOpacity(
        darkness.clamp(0.0, 1.0)));
  }

  @override
  bool shouldRepaint(covariant TemplateBackgroundPainter old) =>
      old.time != time || old.motion != motion || old.preset != preset ||
      old.palette != palette || old.darkness != darkness;
}
