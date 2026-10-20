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
  final BlendMode lightingBlend;
  final bool transparentStage;
  const ClubBackgroundPainter({required this.palette, required this.time,
    required this.motion, required this.darkness,
    this.lightingBlend = BlendMode.srcOver, this.transparentStage = false});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0) return;
    final t = time * motion;
    final colors = [palette.a, palette.b, palette.c];
    final rect = Offset.zero & size;
    final center = Offset(w * .5, h * .48);
    if (!transparentStage) canvas.drawRect(rect, Paint()..shader = const LinearGradient(
      begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [Color(0xFF04030C), Color(0xFF100B24), Color(0xFF030510)],
    ).createShader(rect));

    // Composite the lighting independently from the dark stage backdrop.
    canvas.saveLayer(rect, Paint()..blendMode = lightingBlend);

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

    // Subtle drifting stage smoke replaces the rigid LED/grid wall.
    // Long translucent wisps overlap without image filters or texture assets.
    for (var i = 0; i < 13; i++) {
      final phase = t * (.045 + (i % 3) * .012) + i * 2.13;
      final x = w * (.10 + .8 * hash(i, 21)) + math.sin(phase) * w * .13;
      final y = h * (.24 + .57 * hash(i, 22)) -
          (t * (2.0 + hash(i, 23) * 2.0) + i * 13) % (h * .22);
      final smokeColor = Color.lerp(colors[i % 3], Colors.white, .45)!;
      final centerSmoke = Offset(x, y);
      final rx = w * (.17 + hash(i, 24) * .18);
      final ry = h * (.055 + hash(i, 25) * .08);
      canvas.save();
      canvas.translate(centerSmoke.dx, centerSmoke.dy);
      canvas.rotate(math.sin(phase * .65) * .28);
      final smokeRect = Rect.fromCenter(center: Offset.zero,
          width: rx * 2, height: ry * 2);
      canvas.drawOval(smokeRect, Paint()..shader = RadialGradient(
        colors: [tint(smokeColor, .037), tint(smokeColor, .014),
          tint(smokeColor, 0)],
        stops: const [0, .5, 1],
      ).createShader(smokeRect));
      canvas.restore();
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
      // Alternate fixtures simulate near-field defocused stage lights.
      // Larger, softer washes cross behind crisp distant beams.
      final foreground = i.isOdd;
      if (foreground) {
        final nearSpread = spread * 3.0;
        final farA = origin + Offset(
          math.cos(angle - nearSpread), math.sin(angle - nearSpread)) * length;
        final farB = origin + Offset(
          math.cos(angle + nearSpread), math.sin(angle + nearSpread)) * length;
        final beamPath = Path()..moveTo(origin.dx, origin.dy)
          ..lineTo(farA.dx, farA.dy)..lineTo(farB.dx, farB.dy)..close();
        // Multiple translucent overlapping cones soften the edges.
        for (var layer = 5; layer >= 0; layer--) {
          final feather = 1.0 + layer * .21;
          final a = origin + Offset(
            math.cos(angle - nearSpread * feather),
            math.sin(angle - nearSpread * feather)) * length;
          final b = origin + Offset(
            math.cos(angle + nearSpread * feather),
            math.sin(angle + nearSpread * feather)) * length;
          final cone = Path()..moveTo(origin.dx, origin.dy)
            ..lineTo(a.dx, a.dy)..lineTo(b.dx, b.dy)..close();
          canvas.drawPath(cone, Paint()..shader = LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [tint(color, .023), tint(color, .012), tint(color, 0)],
            stops: const [0, .45, 1],
          ).createShader(rect));
        }
        canvas.drawPath(beamPath, Paint()..shader = LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [tint(color, .085), tint(color, .018), tint(color, 0)],
          stops: const [0, .5, 1],
        ).createShader(rect));
        halo(origin + (aim - origin) * .38, w * .24, color, .035);
      } else {
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
        stroke(origin, aim, color, .055, 11);
        stroke(origin, aim, color, .085, 5);
        stroke(origin, aim, color, .21, 1.25);
      }
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
        final power = .5 + .5 * math.sin(t * .6 + beam);
        stroke(source, endpoint, c, .027 + .02 * power, 7);
        stroke(source, endpoint, c, .07 + .04 * power, 3);
        stroke(source, endpoint, c, .19 + .1 * power, .85);
      }
      halo(source, w * .07, colors[side], .14);
    }

    // Mirrorball: rotating tiled sphere with a moving specular highlight.
    // The curved facets change apparent size at the silhouette; reflected
    // light spots sweep across the stage in synchrony with its rotation.
    final ball = Offset(w * .5, h * .115);
    final radius = math.min(w, h) * .053;
    final spin = t * .52;
    halo(ball, radius * 3.5, colors[1], .18);
    canvas.drawCircle(ball, radius, Paint()..shader = RadialGradient(
      center: const Alignment(-.45, -.5), radius: 1.1,
      colors: [const Color(0xFFADB9CD), const Color(0xFF353B54), const Color(0xFF090C19)],
    ).createShader(Rect.fromCircle(center: ball, radius: radius)));
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: ball, radius: radius)));
    const tileRows = 12;
    for (var row = 0; row < tileRows; row++) {
      final ny = (row + .5) / tileRows * 2 - 1;
      final half = math.sqrt(math.max(0.0, 1 - ny * ny));
      final latitude = math.asin(ny);
      final bands = math.max(8, (26 * math.cos(latitude)).round());
      for (var col = 0; col < bands; col++) {
        final longitude = (col / bands * math.pi * 2 + spin + row * .13) % (math.pi * 2);
        final depth = math.cos(longitude);
        if (depth < -.12) continue;
        final nx = math.sin(longitude) * half;
        final px = ball.dx + nx * radius;
        final py = ball.dy + ny * radius;
        final facetW = math.max(1.0, radius * .21 * math.max(.22, depth));
        final facetH = radius * .145;
        final glint = math.pow(math.max(0.0,
          1 - (nx + .38).abs() * 1.65 - (ny + .38).abs() * 1.3), 4).toDouble();
        final shimmer = math.pow(math.max(0.0,
          math.sin(longitude * 7 + row * 1.9 + t * 1.7)), 12).toDouble();
        final brightness = (.12 + .36 * math.max(0.0, depth) +
          .45 * glint + .36 * shimmer).clamp(0.0, 1.0);
        final facet = Rect.fromCenter(center: Offset(px, py),
          width: facetW, height: facetH);
        canvas.drawRRect(RRect.fromRectAndRadius(facet, const Radius.circular(.7)),
          Paint()..color = Color.lerp(const Color(0xFF182032),
            Colors.white, brightness)!);
        if (glint > .27 && shimmer > .45) halo(Offset(px, py), radius * .24,
          Colors.white, glint * shimmer * .55);
      }
    }
    canvas.restore();
    halo(ball + Offset(-radius * .32, -radius * .36), radius * .55,
      Colors.white, .22 + .1 * math.sin(t * 1.1));
    // Rotating scatter: reflected spots, each with a soft halo and bright core.
    // Deterministic distribution avoids frame-to-frame flicker.
    for (var i = 0; i < 110; i++) {
      final phase = hash(i, 11) * math.pi * 2 + spin * (i.isEven ? 1 : -1);
      final orbit = .12 + hash(i, 12) * .69;
      final x = center.dx + math.sin(phase) * w * orbit;
      final y = center.dy + math.cos(phase * .77 + i * .35) * h * (.13 + orbit * .7);
      final visible = .24 + .76 * math.pow(math.max(0.0,
        math.cos(phase * 1.7 + i)), 2).toDouble();
      final p = Offset(x, y);
      final r = 1.2 + hash(i, 13) * 3.2;
      final color = i % 5 == 0 ? Colors.white : colors[i % 3];
      halo(p, r * 5.2, color, .045 * visible);
      canvas.drawCircle(p, r, Paint()..color = tint(color, .08 * visible));
      canvas.drawCircle(p, r * .42,
        Paint()..color = tint(color, .42 * visible));
      if (visible > .73 && i % 4 == 0) {
        stroke(p + Offset(-r * 2.1, 0), p + Offset(r * 2.1, 0),
          color, .27 * visible, .65);
        stroke(p + Offset(0, -r * 2.1), p + Offset(0, r * 2.1),
          color, .27 * visible, .65);
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
    canvas.restore(); // Complete the isolated lighting blend.
    if (!transparentStage) canvas.drawRect(rect, Paint()..color = Colors.black.withOpacity(
      (darkness * .24).clamp(0.0, .7)));
  }

  @override
  bool shouldRepaint(covariant ClubBackgroundPainter old) =>
    old.time != time || old.motion != motion || old.darkness != darkness ||
    old.palette != palette || old.lightingBlend != lightingBlend || old.transparentStage != transparentStage;
}
