import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Stackable Impeller scene-processing pass: each instance reads the GPU
/// backdrop and transforms its actual pixels, leaving foreground UI sharp.
/// Unsupported devices keep the legacy canvas FX. WebView video is excluded.
class RefractionShaderLayer extends StatefulWidget {
  final double time;
  final double bass;
  final double strength;
  final int mode;
  final int blendMode;
  final double blendOpacity;
  final double effectSize;
  final double pulseAge;
  final Offset origin; // Projected album-art center on the FX viewport.
  final Color colorA;
  final Color colorB;
  final Color colorC;
  final Widget child;
  const RefractionShaderLayer({super.key, required this.time, required this.bass,
    required this.strength, required this.mode,
    required this.blendMode, required this.blendOpacity, required this.effectSize,
    this.pulseAge = 99.0,
    this.origin = const Offset(0.5, 0.5),
    this.colorA = const Color(0xFF00E5FF),
    this.colorB = const Color(0xFFFF36A8),
    this.colorC = const Color(0xFF665CFF),
    required this.child});

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
    shader.setFloat(6, widget.blendMode.toDouble());
    shader.setFloat(7, widget.blendOpacity);
    shader.setFloat(8, widget.effectSize);
    shader.setFloat(9, widget.pulseAge);
    shader.setFloat(10, widget.colorA.red / 255.0);
    shader.setFloat(11, widget.colorA.green / 255.0);
    shader.setFloat(12, widget.colorA.blue / 255.0);
    shader.setFloat(13, widget.colorB.red / 255.0);
    shader.setFloat(14, widget.colorB.green / 255.0);
    shader.setFloat(15, widget.colorB.blue / 255.0);
    shader.setFloat(16, widget.colorC.red / 255.0);
    shader.setFloat(17, widget.colorC.green / 255.0);
    shader.setFloat(18, widget.colorC.blue / 255.0);
    shader.setFloat(19, widget.origin.dx);
    shader.setFloat(20, widget.origin.dy);
    return ClipRect(child: BackdropFilter(
      filter: ui.ImageFilter.shader(shader),
      child: widget.child,
    ));
  }
}
