import 'package:flutter/material.dart';
import 'palette.dart';

/// Neutral placeholder for presets awaiting their individual GPU redesign.
/// Golden Hour (14) is rendered by GoldenHourBackground instead.
class TemplateBackgroundPainter extends CustomPainter {
  final ArtPalette palette;
  final int preset;
  final double time, motion, darkness;
  TemplateBackgroundPainter({
    required this.palette, required this.preset,
    required this.time, required this.motion, required this.darkness,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size,
      Paint()..color = const Color(0xFF06070D));
    if (darkness > 0) {
      canvas.drawRect(Offset.zero & size,
        Paint()..color = Colors.black.withOpacity(darkness.clamp(0.0, 1.0)));
    }
  }

  @override
  bool shouldRepaint(covariant TemplateBackgroundPainter old) =>
      old.darkness != darkness || old.preset != preset;
}
