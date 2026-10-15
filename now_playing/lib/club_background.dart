import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'palette.dart';

/// One fully choreographed club environment: atmospheric haze, automated
/// moving-head fixtures, crossing volumetric beams, laser fans, LED wall,
/// mirrorball scatter, and restrained rhythmic accents. No extra tickers,
/// image allocations, external assets, or audio permissions.
class ClubBackgroundPainter extends CustomPainter {
  final ArtPalette palette;
  final double time, motion, darkness;
  const ClubBackgroundPainter({required this.palette, required this.time,
    required this.motion, required this.darkness});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0) return;
    final t = time * motion;
    final colors = [palette.a, palette.b, palette.c];
    final rect = Offset.zero & size;
    final center = Offset(w * .5, h * .48);
    canvas.drawRect(rect, Paint()..shader = const LinearGradient(
      begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [Color(0xFF04030C), Color(0xFF100B24), Color(0xFF030510)],
    ).createShader(rect));

    double hash(int i, int salt) {
      final x = math.sin(i * 127.1 + salt * 311.7) * 43758.5453;
      return x - x.floorToDouble();
    }
    Color tint(Color c, double alpha) => c.withOpacity(alpha.clamp(0.0, 1.0));
    void halo(Offset p, double radius, Color color, double opacity) {
      final r = Rect.fromCircle(center: p, radius: radius);
      canvas.drawCircle(p, radius, Paint()..shader = RadialGradient(
        colors: [tint(color, opacity), tint(color, opacity * .2), tint(color, 0)],
        stops: const [0, .4, 1],
      ).createShader(r));
    }
    void stroke(Offset a, Offset b, Color color, double alpha, double width) {
      canvas.drawLine(a, b, Paint()..color = tint(color, alpha)
        ..strokeWidth = width..strokeCap = StrokeCap.round);
    }

    // Haze: slowly drifting pools of diffuse colored atmosphere.
    for (var i = 0; i < 9; i++) {
      final x = w * (.08 + .84 * hash(i, 1)) + math.sin(t * .13 + i * 1.8) * w * .09;
      final y = h * (.12 + .78 * hash(i, 2)) + math.cos(t * .09 + i) * h * .06;
      halo(Offset(x, y), math.max(w, h) * (.18 + hash(i, 3) * .18),
        colors[i % 3], .055);
    }

    // Stage LED wall: staggered cells with traveling diagonal sequences.
    final cols = w > h ? 24 : 14;
    const rows = 15;
    final left = w * .1, top = h * .17, wallW = w * .8, wallH = h * .58;
    final dx = wallW / cols, dy = wallH / rows;
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final phase = t * .82 - col * .35 - row * .24;
        final pulse = math.pow(math.max(0.0, math.sin(phase)), 5).toDouble();
        final sweep = math.pow(math.max(0.0, math.cos(t * .32 + row * .4 - col * .22)), 9).toDouble();
        final brightness = .013 + pulse * .085 + sweep * .07;
        final cell = Rect.fromLTWH(left + col * dx + dx * .12,
          top + row * dy + dy * .12, dx * .76, dy * .76);
        canvas.drawRRect(RRect.fromRectAndRadius(cell, const Radius.circular(1.5)),
          Paint()..color = tint(colors[(col ~/ 5 + row ~/ 5) % 3], brightness));
      }
    }

    // Motorized moving-head beams. Multiple wide translucent layers simulate
    // volumetric falloff without costly blur filters.
    final fixtures = w > h ? 7 : 5;
    for (var i = 0; i < fixtures; i++) {
      final origin = Offset(w * (i + .5) / fixtures, h * .065);
      final sweep = math.sin(t * (.28 + (i % 3) * .055) + i * 1.45);
      final aim = Offset(w * (.5 + sweep * .49), h * (.76 + .12 * math.cos(t * .17 + i)));
      final angle = math.atan2(aim.dy - origin.dy, aim.dx - origin.dx);
      final spread = .105 + .035 * (.5 + .5 * math.sin(t * .43 + i));
      final length = math.max(w, h) * 1.65;
      final color = colors[i % 3];
      for (var layer = 0; layer < 3; layer++) {
        final factor = 1.0 + layer * .65;
        final a = origin + Offset(math.cos(angle - spread * factor), math.sin(angle - spread * factor)) * length;
        final b = origin + Offset(math.cos(angle + spread * factor), math.sin(angle + spread * factor)) * length;
        final path = Path()..moveTo(origin.dx, origin.dy)..lineTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy)..close();
        canvas.drawPath(path, Paint()..shader = LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [tint(color, .14 / (layer + 1)), tint(color, .027 / (layer + 1)), tint(color, 0)],
          stops: const [0, .48, 1],
        ).createShader(rect));
      }
      stroke(origin, aim, color, .16, 1.1);
      halo(origin, w * .035, color, .23);
      canvas.drawCircle(origin, 2.5, Paint()..color = tint(Colors.white, .5));
    }

    // Laser fans: precise narrow rays pivoting from the side trusses.
    for (var side = 0; side < 2; side++) {
      final source = Offset(side == 0 ? w * .025 : w * .975, h * .39);
      final direction = side == 0 ? 1.0 : -1.0;
      final rotation = math.sin(t * .38 + side * 2.2) * .25;
      for (var beam = 0; beam < 11; beam++) {
        final a = (beam - 5) * .074 + rotation;
        final endpoint = source + Offset(direction * w * 1.1,
          math.tan(a) * h * 1.05);
        final c = colors[(beam ~/ 4 + side) % 3];
        stroke(source, endpoint, c, .12 + .08 * (.5 + .5 * math.sin(t * .6 + beam)), .8);
      }
      halo(source, w * .07, colors[side], .14);
    }

    // Rotating mirrorball: glints travel on ellipses rather than appearing as
    // a static particle field.
    final ball = Offset(w * .5, h * .115);
    final radius = math.min(w, h) * .043;
    halo(ball, radius * 3, colors[1], .12);
    canvas.drawCircle(ball, radius, Paint()..color = const Color(0xFF242638));
    for (var i = 0; i < 19; i++) {
      final yy = (i - 9) / 10;
      final half = math.sqrt(math.max(0.0, 1 - yy * yy));
      stroke(ball + Offset(-radius * half, yy * radius),
        ball + Offset(radius * half, yy * radius), Colors.white, .15, .6);
    }
    for (var i = 0; i < 68; i++) {
      final angle = hash(i, 11) * math.pi * 2 + t * .11;
      final orbit = .16 + hash(i, 12) * .53;
      final x = center.dx + math.cos(angle) * w * orbit;
      final y = center.dy + math.sin(angle * .83 + i * .2) * h * (.15 + orbit * .65);
      final twinkle = math.pow(math.max(0.0, math.sin(t * .7 + i * 2.7)), 4).toDouble();
      final p = Offset(x, y);
      final alpha = .04 + .22 * twinkle;
      canvas.drawCircle(p, .6 + hash(i, 13) * 1.5,
        Paint()..color = tint(colors[i % 3], alpha));
      if (twinkle > .72) {
        stroke(p + const Offset(-4, 0), p + const Offset(4, 0), colors[i % 3], alpha, .7);
        stroke(p + const Offset(0, -4), p + const Offset(0, 4), colors[i % 3], alpha, .7);
      }
    }

    // Floor wash and low-frequency lighting accents. No hard white strobes.
    final pulse = .5 + .5 * math.sin(t * 1.25);
    halo(Offset(w * .5, h * .98), w * .75, colors[0], .07 + pulse * .045);
    for (var i = 0; i < 5; i++) {
      final y = h * (.79 + i * .043);
      stroke(Offset(w * (.16 - i * .04), y),
        Offset(w * (.84 + i * .04), y), colors[(i + 1) % 3], .035 + pulse * .035, 1);
    }
    canvas.drawRect(rect, Paint()..color = Colors.black.withOpacity(
      (darkness * .24).clamp(0.0, .7)));
  }

  @override
  bool shouldRepaint(covariant ClubBackgroundPainter old) =>
    old.time != time || old.motion != motion || old.darkness != darkness ||
    old.palette != palette;
}
