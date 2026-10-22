import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'palette.dart';

/// Premium shader scene. Compilation happens once per widget lifecycle.
/// Unsupported shader devices display a neutral stage instead of a cheap
/// imitation of the effect.
class GoldenHourBackground extends StatefulWidget {
  final double time;
  final double motion;
  final ArtPalette palette;
  const GoldenHourBackground({
    super.key, required this.time, required this.motion,
    required this.palette,
  });

  @override
  State<GoldenHourBackground> createState() => _GoldenHourBackgroundState();
}

class _GoldenHourBackgroundState extends State<GoldenHourBackground> {
  ui.FragmentProgram? _program;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final program = await ui.FragmentProgram.fromAsset(
          'shaders/golden_hour.frag');
      if (mounted) setState(() => _program = program);
    } catch (error) {
      debugPrint('Golden Hour shader unavailable: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final program = _program;
    if (program == null) {
      return const ColoredBox(color: Color(0xFF06070D));
    }
    return CustomPaint(
      painter: _GoldenHourPainter(
        program: program, time: widget.time * widget.motion,
        palette: widget.palette),
      child: const SizedBox.expand(),
    );
  }
}

class _GoldenHourPainter extends CustomPainter {
  final ui.FragmentProgram program;
  final double time;
  final ArtPalette palette;
  _GoldenHourPainter({
    required this.program, required this.time, required this.palette,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final shader = program.fragmentShader();
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, time);
    final colors = [palette.a, palette.b, palette.c];
    var index = 3;
    for (final color in colors) {
      shader.setFloat(index++, color.red / 255.0);
      shader.setFloat(index++, color.green / 255.0);
      shader.setFloat(index++, color.blue / 255.0);
    }
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _GoldenHourPainter old) =>
      old.time != time || old.palette != palette ||
      old.program != program;
}
