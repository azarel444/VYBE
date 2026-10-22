import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'palette.dart';

/// Seventeen palette-specific procedural scenes. No image assets, blur filters,
/// timers or extra animation controllers: the existing slow ticker drives all.
class TemplateBackgroundPainter extends CustomPainter {
  final ArtPalette palette;
  final int preset;
  final double time, motion, darkness;
  TemplateBackgroundPainter({required this.palette, required this.preset,
    required this.time, required this.motion, required this.darkness});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0) return;
    final r = Offset.zero & size;
    final c = [palette.a, palette.b, palette.c];
    final t = time * motion;
    canvas.drawRect(r, Paint()..color = const Color(0xFF050811));
    void glow(Offset p, double radius, Color color, double alpha) {
      final bounds = Rect.fromCircle(center: p, radius: radius);
      canvas.drawCircle(p, radius, Paint()..shader = RadialGradient(colors: [
        color.withOpacity(alpha.clamp(0.0, 1.0)), color.withOpacity(0)
      ]).createShader(bounds));
    }
    // Soft animated light volumes extend outside the viewport.
    for (var layer = 0; layer < 3; layer++) {
      final x = w * (.12 + layer * .38 + math.sin(t * (.045 + layer * .012) + layer) * .12);
      final y = h * (.25 + layer * .22 + math.cos(t * .04 + layer * 2) * .15);
      glow(Offset(x, y), math.max(w, h) * (.45 + layer * .08),
        c[layer], .095);
    }
    void line(Offset a, Offset b, Color color, double opacity, double stroke) {
      canvas.drawLine(a, b, Paint()..color = color.withOpacity(opacity)
        ..strokeWidth = stroke..strokeCap = StrokeCap.round);
    }
    double fract(double x) => x - x.floorToDouble();
    double noise(int i, int salt) => fract(math.sin(i * 127.1 + salt * 311.7) * 43758.5453);
    void stars(int count, {bool streak = false}) {
      for (var i = 0; i < count; i++) {
        final x = noise(i, 1) * w, y = noise(i, 2) * h;
        final twinkle = .4 + .6 * (.5 + .5 * math.sin(t * .5 + i * 1.8));
        final p = Offset(x, y);
        if (streak) {
          line(p, p + Offset(-w * (.01 + noise(i, 3) * .035), h * .02), c[i % 3], .13 * twinkle, 1);
        } else {
          canvas.drawCircle(p, .45 + noise(i, 4) * 1.15,
            Paint()..color = c[i % 3].withOpacity(.12 + .35 * twinkle));
        }
      }
    }
    void wave({required bool vertical, required int count, required double amp,
        required double speed, double opacity = .13, double thickness = 1.5}) {
      for (var i = 0; i < count; i++) {
        final path = Path();
        for (var k = 0; k <= 64; k++) {
          final u = k / 64;
          final v = (i + 1) / (count + 1) + math.sin(u * math.pi * (2.3 + i % 3) + t * speed + i * .8) * amp;
          final p = vertical ? Offset(v * w, u * h) : Offset(u * w, v * h);
          if (k == 0) { path.moveTo(p.dx, p.dy); } else { path.lineTo(p.dx, p.dy); }
        }
        canvas.drawPath(path, Paint()..color = c[i % 3].withOpacity(opacity)
          ..style = PaintingStyle.stroke..strokeWidth = thickness + (i % 3) * .4);
      }
    }
    // Each palette has its own composition and motion language. Index 0 is
    // artwork-derived, so it uses a restrained spectral scene.
    switch (preset) {
      case 0: // Auto: drifting spectral pools
        for (var i = 0; i < 5; i++) {
          glow(Offset(w * (.18 + .16 * i + math.sin(t * .07 + i) * .09),
            h * (.18 + (i % 3) * .3 + math.cos(t * .08 + i) * .1)),
            math.max(w, h) * .37, c[i % 3], .13);
        }
        break;
      case 1: // Vaporwave: retro neon sun, scan horizon, perspective grid
        glow(Offset(w * .5, h * .36), w * .48, c[1], .19);
        canvas.drawCircle(Offset(w * .5, h * .36), w * .18,
          Paint()..color = c[1].withOpacity(.16));
        for (var i = 0; i < 9; i++) {
          final y = h * (.37 + i * .025);
          line(Offset(w * .32, y), Offset(w * .68, y), const Color(0xFF050811), .85, 1 + i * .65);
        }
        for (var i = -8; i <= 8; i++) {
          line(Offset(w * .5, h * .62), Offset(w * (.5 + i * .19), h), c[0], .17, 1);
        }
        for (var i = 0; i < 12; i++) {
          final q = fract(i / 12 + t * .025);
          final y = h * (.62 + q * q * .38);
          line(Offset(0, y), Offset(w, y), c[1], .09 + q * .14, 1);
        }
        break;
      case 2: // Sunset: layered glowing cloud banks
        glow(Offset(w * .72, h * .42), w * .65, c[0], .42);
        for (var i = 0; i < 8; i++) {
          final y = h * (.35 + i * .085);
          final path = Path()..moveTo(0, y);
          for (var k = 0; k <= 40; k++) {
            final x = w * k / 40;
            path.lineTo(x, y + math.sin(k * .25 + i + t * .065) * h * .025);
          }
          path.lineTo(w, h);
          path.lineTo(0, h);
          path.close();
          canvas.drawPath(path, Paint()..color = c[i % 3].withOpacity(.055 + i * .013));
        }
        break;
      case 3: // Ocean: refracted water and light caustics
        glow(Offset(w * .35, h * .25), w * .55, c[0], .18);
        wave(vertical: false, count: 23, amp: .055, speed: .34, opacity: .20);
        for (var i = 0; i < 15; i++) {
          final x = noise(i, 5) * w;
          final y = noise(i, 6) * h;
          final p = Offset(x + math.sin(t * .12 + i) * 12, y);
          canvas.drawOval(Rect.fromCenter(center: p, width: 24 + noise(i, 7) * 48, height: 4),
            Paint()..color = c[i % 3].withOpacity(.075));
        }
        break;
      case 4: // Forest: rising fireflies and branching silhouettes
        for (var i = 0; i < 16; i++) {
          final x = w * noise(i, 8), y = h * noise(i, 9);
          final top = Offset(x, y - h * .12);
          line(Offset(x, h), top, c[1], .07, 1 + noise(i, 10) * 2);
          line(Offset(x, y), Offset(x + (noise(i, 11) - .5) * w * .15, y - h * .12), c[0], .09, 1);
        }
        for (var i = 0; i < 42; i++) {
          final x = w * noise(i, 12) + math.sin(t * .11 + i) * 10;
          final y = h * fract(noise(i, 13) - t * (.009 + noise(i, 14) * .012));
          glow(Offset(x, y), 8 + noise(i, 15) * 12, c[i % 3], .13);
          canvas.drawCircle(Offset(x, y), 1.1, Paint()..color = c[i % 3].withOpacity(.5));
        }
        break;
      case 5: // White: clean pearl light folds
        for (var i = 0; i < 8; i++) {
          final path = Path();
          for (var k = 0; k <= 50; k++) {
            final x = w * k / 50;
            final y = h * (i / 9 + math.sin(x / w * 3.7 + t * .065 + i * .7) * .13);
            if (k == 0) { path.moveTo(x, y); } else { path.lineTo(x, y); }
          }
          canvas.drawPath(path, Paint()..color = c[i % 3].withOpacity(.10)
            ..style = PaintingStyle.stroke..strokeWidth = 8 + i * 2);
        }
        break;
      case 6: // Cosmic: nebula clusters and stellar dust
        for (var i = 0; i < 7; i++) {
          glow(Offset(w * (.15 + noise(i, 16) * .7 + math.sin(t * .035 + i) * .04),
            h * (.12 + noise(i, 17) * .75)), math.max(w, h) * (.22 + noise(i, 18) * .24), c[i % 3], .24);
        }
        stars(180);
        break;
      case 7: // Ember: layered fire tongues, floating glowing cinders
        glow(Offset(w * .5, h * 1.08), math.max(w, h) * .85, c[0], .33);
        for (var i = 0; i < 15; i++) {
          final x = w * (i + .5) / 15;
          final sway = math.sin(t * .27 + i * 2.1) * w * .045;
          final height = h * (.15 + noise(i, 19) * .24);
          final path = Path()..moveTo(x - w * .07, h)
            ..quadraticBezierTo(x - w * .06 + sway, h - height * .55,
              x + sway, h - height * (1 + .12 * math.sin(t * .38 + i)))
            ..quadraticBezierTo(x + w * .07 + sway, h - height * .35, x + w * .09, h)
            ..close();
          canvas.drawPath(path, Paint()..color = c[i % 3].withOpacity(.15 + .045 * (i % 3)));
        }
        for (var i = 0; i < 85; i++) {
          final rise = fract(noise(i, 20) + t * (.016 + noise(i, 21) * .032));
          final x = w * noise(i, 22) + math.sin(t * .18 + i * 1.3) * w * .045;
          final y = h * (1.04 - rise * 1.18);
          final p = Offset(x, y);
          final alpha = (math.sin(rise * math.pi) * .65).clamp(0.0, 1.0);
          glow(p, 5 + noise(i, 23) * 10, c[i % 3], alpha * .18);
          canvas.drawCircle(p, .6 + noise(i, 24) * 1.5,
            Paint()..color = c[i % 3].withOpacity(alpha * .8));
        }
        break;
      case 8: // Aurora: full-bleed luminous curtains
        for (var i = 0; i < 10; i++) {
          final path = Path();
          for (var k = -10; k <= 70; k++) {
            final y = h * k / 50;
            final x = w * (.06 + i * .1 + math.sin(y / h * 5 + t * .095 + i * .6) * .09);
            if (k == -10) { path.moveTo(x, y); } else { path.lineTo(x, y); }
          }
          canvas.drawPath(path, Paint()..color = c[i % 3].withOpacity(.16)
            ..style = PaintingStyle.stroke..strokeWidth = w * .11);
        }
        break;
      case 9: // Rose Gold: orbiting metallic arcs and glints
        for (var i = 0; i < 15; i++) {
          final rad = math.min(w, h) * (.13 + i * .055);
          canvas.drawArc(Rect.fromCircle(center: Offset(w * .55, h * .5), radius: rad),
            i * .55 + t * .028 * (i.isEven ? 1 : -1), .45 + (i % 4) * .22, false,
            Paint()..color = c[i % 3].withOpacity(.1 + (i % 4) * .018)
              ..style = PaintingStyle.stroke..strokeWidth = 1.2 + i % 3);
        }
        for (var i = 0; i < 18; i++) {
          final p = Offset(w * noise(i, 25), h * noise(i, 26));
          final a = .12 + .2 * (.5 + .5 * math.sin(t * .3 + i));
          line(p + const Offset(-5, 0), p + const Offset(5, 0), c[i % 3], a, .8);
          line(p + const Offset(0, -5), p + const Offset(0, 5), c[i % 3], a, .8);
        }
        break;
      case 10: // Electric Lime: electric branching circuit discharges
        for (var i = 0; i < 24; i++) {
          var p = Offset(w * noise(i, 27), h * noise(i, 28));
          for (var j = 0; j < 5; j++) {
            final q = p + Offset(w * (.03 + noise(i * 7 + j, 29) * .055),
              h * (noise(i * 7 + j, 30) - .5) * .09);
            line(p, q, c[i % 3], .08 + .12 * (.5 + .5 * math.sin(t * .28 + i)), 1.1);
            p = q;
          }
        }
        break;
      case 11: // Midnight: slow deep-blue rain with distant bokeh
        for (var i = 0; i < 48; i++) {
          final x = w * noise(i, 31);
          final y = h * fract(noise(i, 32) + t * (.015 + noise(i, 33) * .025));
          line(Offset(x, y), Offset(x - w * .008, y + h * (.025 + noise(i, 34) * .06)),
            c[i % 3], .06 + noise(i, 35) * .12, .7);
        }
        for (var i = 0; i < 9; i++) {
          glow(Offset(w * noise(i, 36), h * noise(i, 37)), w * .15, c[i % 3], .09);
        }
        break;
      case 12: // Ice: drifting crystalline facets
        for (var i = 0; i < 24; i++) {
          final x = w * noise(i, 38) + math.sin(t * .045 + i) * 10;
          final y = h * noise(i, 39) + math.cos(t * .04 + i) * 8;
          final s = math.min(w, h) * (.045 + noise(i, 40) * .16);
          final path = Path()..moveTo(x, y - s)..lineTo(x + s * .65, y)
            ..lineTo(x, y + s)..lineTo(x - s * .65, y)..close();
          canvas.drawPath(path, Paint()..color = c[i % 3].withOpacity(.09));
          canvas.drawPath(path, Paint()..color = c[i % 3].withOpacity(.27)
            ..style = PaintingStyle.stroke..strokeWidth = .8);
        }
        break;
      case 13: // Ruby: full-bleed liquid ribbons
        for (var i = 0; i < 9; i++) {
          final path = Path();
          for (var k = -10; k <= 70; k++) {
            final y = h * k / 50;
            final x = w * (.02 + i * .125 +
              math.sin(y / h * 4.6 + t * .20 + i * .65) * .15);
            if (k == -10) { path.moveTo(x, y); } else { path.lineTo(x, y); }
          }
          canvas.drawPath(path, Paint()
            ..color = c[i % 3].withOpacity(.16)
            ..style = PaintingStyle.stroke
            ..strokeWidth = w * (.09 + (i % 2) * .03));
          canvas.drawPath(path, Paint()
            ..color = c[(i + 1) % 3].withOpacity(.21)
            ..style = PaintingStyle.stroke..strokeWidth = w * .007);
        }
        break;
      case 14: // Golden Hour: sunbeams and airborne golden dust
        glow(Offset(w * .8, h * .16), math.max(w, h) * .7, c[0], .26);
        for (var i = 0; i < 21; i++) {
          final angle = math.pi * (.3 + i * .085) + math.sin(t * .025) * .07;
          final start = Offset(w * .8, h * .16);
          line(start, start + Offset(math.cos(angle) * w * 1.6, math.sin(angle) * h * 1.6),
            c[i % 3], .045 + .025 * (i % 3), 2.0 + (i % 4).toDouble());
        }
        for (var i = 0; i < 70; i++) {
          final x = w * noise(i, 41), y = h * fract(noise(i, 42) - t * .007);
          canvas.drawCircle(Offset(x, y), .5 + noise(i, 43) * 1.2,
            Paint()..color = c[i % 3].withOpacity(.18));
        }
        break;
      case 15: // Ultraviolet: rotating concentric interference rings
        for (var i = 0; i < 28; i++) {
          final radius = math.min(w, h) * (.07 + i * .038);
          final center = Offset(w * (.5 + math.sin(t * .05) * .045), h * .5);
          canvas.drawArc(Rect.fromCircle(center: center, radius: radius),
            t * (i.isEven ? .038 : -.028) + i * .36, math.pi * (.3 + i % 4 * .14), false,
            Paint()..color = c[i % 3].withOpacity(.07 + (i % 4) * .014)
              ..style = PaintingStyle.stroke..strokeWidth = 1.4);
        }
        break;
      case 16: // Monochrome: architectural shifting bars and fine grain
        for (var i = 0; i < 19; i++) {
          final x = w * i / 19;
          final offset = math.sin(t * .055 + i * .7) * h * .05;
          canvas.drawRect(Rect.fromLTWH(x, offset, w / 40, h),
            Paint()..color = c[i % 3].withOpacity(.025 + (i % 4) * .015));
        }
        for (var i = 0; i < 30; i++) {
          final y = h * i / 30;
          line(Offset(0, y), Offset(w, y), c[i % 3], .025, .5);
        }
        break;
      default:
        glow(Offset(w * .5, h * .5), w * .5, c[0], .17);
    }
    canvas.drawRect(r, Paint()..color = Colors.black.withOpacity((darkness * .27).clamp(0.0, .75)));
  }

  @override
  bool shouldRepaint(covariant TemplateBackgroundPainter old) =>
    old.time != time || old.motion != motion || old.preset != preset ||
    old.palette != palette || old.darkness != darkness;
}
