import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'palette.dart';

/// A second club environment: an immersive, accelerating geometric laser
/// corridor. Unlike the stage show, this has no fixtures or mirrorball.
class LaserTunnelBackgroundPainter extends CustomPainter {
  final ArtPalette palette;
  final double time, motion, darkness;
  final bool transparentStage;
  final BlendMode lightingBlend;
  const LaserTunnelBackgroundPainter({required this.palette, required this.time,
    required this.motion, required this.darkness, this.transparentStage = false,
    this.lightingBlend = BlendMode.srcOver});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0) return;
    final rect = Offset.zero & size;
    final t = time * motion;
    final colors = [palette.a, palette.b, palette.c];
    final vanishing = Offset(w * (.5 + .11 * math.sin(t * .13)), h * (.49 + .07 * math.cos(t * .17)));
    if (!transparentStage) {
      canvas.drawRect(rect, Paint()..shader = RadialGradient(center: Alignment(
        vanishing.dx / w * 2 - 1, vanishing.dy / h * 2 - 1), radius: 1.25,
        colors: const [Color(0xFF17102D), Color(0xFF060717), Color(0xFF02030A)],
      ).createShader(rect));
    }
    canvas.saveLayer(rect, Paint()..blendMode = lightingBlend);
    Color alpha(Color c, double a) => c.withOpacity(a.clamp(0, 1));
    double rand(int seed) { final n = math.sin(seed * 78.233) * 43758.5453; return n - n.floorToDouble(); }
    void glowLine(Offset a, Offset b, Color color, double strength, double width) {
      for (final factor in [7.0, 3.5, 1.0]) {
        canvas.drawLine(a, b, Paint()..color = alpha(color, strength / (factor == 1 ? 1 : factor * 2.1))
          ..strokeWidth = width * factor..strokeCap = StrokeCap.round);
      }
    }
    void aura(Offset point, double radius, Color color, double strength) {
      final r = Rect.fromCircle(center: point, radius: radius);
      canvas.drawCircle(point, radius, Paint()..shader = RadialGradient(colors: [
        alpha(color, strength), alpha(color, strength * .25), alpha(color, 0),
      ], stops: const [0, .38, 1]).createShader(r));
    }
    // Atmospheric volume, deliberately sparse enough for text readability.
    for (var i = 0; i < 8; i++) {
      final x = w * rand(i + 22) + math.sin(t * .12 + i) * w * .08;
      final y = h * rand(i + 87) + math.cos(t * .1 + i) * h * .08;
      aura(Offset(x, y), math.max(w, h) * (.16 + rand(i + 5) * .15), colors[i % 3], .075);
    }
    // Moving octagonal gates approach the viewer in perspective, with
    // individual rotation and breathing brightness rather than static rings.
    final extent = math.sqrt(w * w + h * h) * .68;
    for (var i = 0; i < 12; i++) {
      final depth = ((i / 12 + t * .035) % 1.0);
      final eased = depth * depth;
      final radius = 15 + extent * eased;
      final sides = i.isEven ? 6 : 8;
      final rotation = t * (i.isEven ? .045 : -.035) + i * .18;
      final points = <Offset>[];
      for (var j = 0; j < sides; j++) {
        final a = rotation + j * math.pi * 2 / sides;
        points.add(vanishing + Offset(math.cos(a) * radius, math.sin(a) * radius * .78));
      }
      final fade = (1 - (depth - .82).clamp(0, .18) / .18) * (depth * 1.5).clamp(.12, 1.0);
      for (var j = 0; j < sides; j++) {
        glowLine(points[j], points[(j + 1) % sides], colors[(i + j ~/ 3) % 3], fade * .85,
          1.1 + eased * 2.5);
      }
    }
    // Perspective rails shoot from the horizon toward the frame edges.
    for (var i = 0; i < 16; i++) {
      final angle = i * math.pi / 8 + .08 * math.sin(t * .21);
      final outer = vanishing + Offset(math.cos(angle) * extent * 1.3,
          math.sin(angle) * extent * .95);
      final inner = vanishing + Offset(math.cos(angle) * 18, math.sin(angle) * 14);
      glowLine(inner, outer, colors[i % 3], .11 + .09 * math.sin(t * .4 + i).abs(), 1.0);
    }
    // Scanning laser sheets: narrow, sharp cores in a broader soft fan.
    for (var bank = 0; bank < 2; bank++) {
      final origin = Offset(bank == 0 ? w * -.06 : w * 1.06, h * (.18 + bank * .64));
      final swing = math.sin(t * (.32 + bank * .09) + bank * 2.4);
      for (var ray = 0; ray < 7; ray++) {
        final angle = (bank == 0 ? -.15 : math.pi + .15) + swing * .36 + (ray - 3) * .075;
        final target = origin + Offset(math.cos(angle) * w * 1.65, math.sin(angle) * h * 1.8);
        glowLine(origin, target, colors[(ray + bank) % 3], .34, 1.15);
      }
      aura(origin, w * .13, colors[bank], .18);
    }
    // Star-like dust streaming out of the tunnel with depth-dependent size.
    for (var i = 0; i < 85; i++) {
      final phase = (rand(i + 33) + t * (.055 + rand(i + 99) * .04)) % 1;
      final a = rand(i + 199) * math.pi * 2;
      final radius = extent * phase * phase;
      final point = vanishing + Offset(math.cos(a) * radius, math.sin(a) * radius * .78);
      final r = .35 + phase * 2.0;
      canvas.drawCircle(point, r, Paint()..color = alpha(colors[i % 3], .17 + phase * .65));
      if (i % 11 == 0) aura(point, 8 + phase * 13, colors[i % 3], .15);
    }
    canvas.restore();
    if (!transparentStage) canvas.drawRect(rect, Paint()..color = Colors.black.withOpacity(
      (darkness * .24).clamp(0, .7)));
  }

  @override
  bool shouldRepaint(covariant LaserTunnelBackgroundPainter old) =>
    old.time != time || old.motion != motion || old.darkness != darkness ||
    old.palette != palette || old.transparentStage != transparentStage ||
    old.lightingBlend != lightingBlend;
}
