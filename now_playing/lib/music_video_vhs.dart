import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Low-cost animated analog tape tracking on top of Music Video's WebView.
/// Uses the shared 30fps VYBE ticker; does not screen-capture or re-render
/// YouTube's protected video surface. The 0% setting builds no overlay.
class MusicVideoTrackingPainter extends CustomPainter {
  final double intensity;
  final double Function() clock;

  MusicVideoTrackingPainter({
    required this.intensity,
    required this.clock,
    required Listenable repaint,
  }) : super(repaint: repaint);

  static double _noise(int seed) {
    final x = math.sin(seed * 12.9898 + 78.233) * 43758.5453;
    return x - x.floorToDouble();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final amount = intensity.clamp(0.0, 1.0).toDouble();
    if (amount <= 0 || size.isEmpty) return;
    final w = size.width, h = size.height;
    final t = clock();

    canvas.save();
    canvas.clipRect(Offset.zero & size);

    // Main rolling tracking band: softly edged luminance distortion travelling
    // downward over several seconds, rather than static grain alone.
    final roll = ((t * (.105 + amount * .085)) % 1.30) - .15;
    final y = roll * h;
    final bandH = h * (.065 + amount * .085);
    final band = Rect.fromLTWH(0, y - bandH * .55, w, bandH);
    canvas.drawRect(band, Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: const [0, .17, .39, .58, .79, 1],
        colors: [
          Colors.transparent,
          Colors.white.withOpacity(.07 * amount),
          Colors.white.withOpacity(.15 * amount),
          Colors.black.withOpacity(.21 * amount),
          const Color(0xFF7CA5C3).withOpacity(.09 * amount),
          Colors.transparent,
        ],
      ).createShader(band));

    // Several drifting sync lines keep the band visibly in motion.
    final lineCount = 2 + (amount * 6).round();
    for (var i = 0; i < lineCount; i++) {
      final spread = (i - lineCount / 2) * (1.7 + amount * 2.8);
      final ly = y + spread + math.sin(t * 6.4 + i * 1.9) * amount * 2.2;
      if (ly < 0 || ly > h) continue;
      final alpha = (.055 + .24 * amount) * (i.isEven ? 1 : .58);
      canvas.drawLine(Offset(0, ly), Offset(w, ly),
        Paint()
          ..color = (i % 3 == 0 ? const Color(0xFFB7EAF4) : Colors.white)
              .withOpacity(alpha)
          ..strokeWidth = .55 + amount * .9);
    }

    // A second, faster moving horizontal tear / short dropout cluster.
    // Colored parallel edges evoke unstable analog chroma tracking without
    // touching the WebView's decoded frames or interfering with controls.
    if (amount > .15) {
      final drift = (((t * .33 + .19) % 1.25) - .12) * h;
      final frame = (t * (6 + 4 * amount)).floor();
      final fragments = 3 + (amount * 12).round();
      for (var i = 0; i < fragments; i++) {
        final jitter = _noise(frame * 19 + i * 47);
        final yy = drift + (jitter - .5) * h * (.055 + .04 * amount);
        if (yy < 0 || yy > h) continue;
        final x = _noise(frame * 31 + i * 29) * w * .76;
        final length = w * (.055 + .25 * amount * _noise(frame + i * 101));
        final start = Offset(x, yy);
        final end = Offset(math.min(w, x + length), yy);
        canvas.drawLine(start, end, Paint()
          ..color = Colors.white.withOpacity(.055 * amount)
          ..strokeWidth = .7 + 1.8 * amount);
        canvas.drawLine(start.translate(-1.5 * amount, -1.25),
          end.translate(-1.5 * amount, -1.25), Paint()
          ..color = const Color(0xFFFF4D95).withOpacity(.13 * amount)
          ..strokeWidth = .65 + 1.25 * amount);
        canvas.drawLine(start.translate(1.6 * amount, 1.25),
          end.translate(1.6 * amount, 1.25), Paint()
          ..color = const Color(0xFF45DFFB).withOpacity(.13 * amount)
          ..strokeWidth = .65 + 1.25 * amount);
      }
    }

    // At the upper end a second narrow rolling dropout appears, but the
    // overlay never freezes, pauses, or replaces the underlying video.
    if (amount > .62) {
      final lineY = (((t * .27 + .42) % 1.25) - .12) * h;
      canvas.drawRect(Rect.fromLTWH(0, lineY, w, 1.4 + 4 * amount),
        Paint()..color = Colors.black.withOpacity((amount - .62) * .46));
      canvas.drawLine(Offset(0, lineY - 1), Offset(w, lineY - 1),
        Paint()..color = Colors.white.withOpacity((amount - .62) * .29));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MusicVideoTrackingPainter old) =>
      old.intensity != intensity;
}
