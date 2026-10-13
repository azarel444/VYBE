import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Impeller-only true backdrop refraction. Falls back to existing canvas FX on
/// Skia / older head units. Never captures the UI or changes the source art.
class RefractionShaderLayer extends StatefulWidget {
  final double time;
  final double bass;
  final double strength;
  final int mode;
  final Widget child;
  const RefractionShaderLayer({super.key, required this.time, required this.bass,
    required this.strength, required this.mode, required this.child});

  @override
  State<RefractionShaderLayer> createState() => _RefractionShaderLayerState();
}

class _RefractionShaderLayerState extends State<RefractionShaderLayer> {
  static Future<ui.FragmentProgram>? _program;
  ui.FragmentShader? _shader;
  @override
  void initState() {
    super.initState();
    if (ui.ImageFilter.isShaderFilterSupported) {
      (_program ??= ui.FragmentProgram.fromAsset('shaders/vybe_refraction.frag'))
          .then((p) {
        if (mounted) setState(() => _shader = p.fragmentShader());
      }).catchError((Object _) { /* unsupported driver: canvas FX remain */ });
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    if (shader == null || widget.strength <= 0) return widget.child;
    // The engine supplies u_size at float slots 0-1 and u_texture at sampler 0.
    shader.setFloat(2, widget.time);
    shader.setFloat(3, widget.bass);
    shader.setFloat(4, widget.strength);
    shader.setFloat(5, widget.mode.toDouble());
    return ClipRect(child: BackdropFilter(
      filter: ui.ImageFilter.shader(shader),
      child: widget.child,
    ));
  }
}
