import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// GPU artist-name material. The child is the ALREADY-kerned Riot wordmark,
/// rendered once as a single composited alpha source. ImageFiltered samples
/// that alpha texture so highlights follow individual contours, not a box.
/// This intentionally never mutates the font, glyph editor, or artwork cache.
class ArtistLogoShaderLayer extends StatefulWidget {
  final Widget child;
  final Listenable repaint;
  final double Function() clock;
  final double Function() bass;
  final int treatment;
  final double depth;
  final double edge;
  final Color accent;
  final Color secondary;
  final Color tertiary;
  final double colorStrength;

  const ArtistLogoShaderLayer({
    super.key,
    required this.child,
    required this.repaint,
    required this.clock,
    required this.bass,
    required this.treatment,
    required this.depth,
    required this.edge,
    required this.accent,
    required this.secondary,
    required this.tertiary,
    required this.colorStrength,
  });

  @override
  State<ArtistLogoShaderLayer> createState() => _ArtistLogoShaderLayerState();
}

class _ArtistLogoShaderLayerState extends State<ArtistLogoShaderLayer> {
  static Future<ui.FragmentProgram>? _program;
  ui.FragmentShader? _front;
  ui.FragmentShader? _back;
  bool _toggle = false;

  @override
  void initState() {
    super.initState();
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    (_program ??= ui.FragmentProgram.fromAsset('shaders/artist_logo.frag'))
        .then((p) {
      if (!mounted) return;
      setState(() {
        _front = p.fragmentShader();
        _back = p.fragmentShader();
      });
    }).catchError((Object error) {
      debugPrint('VYBE Artist Logo shader unavailable: $error');
      // On unsupported GPUs VYBE retains its original legible Riot font.
    });
  }

  @override
  void dispose() {
    _front?.dispose();
    _back?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.treatment <= 0 ||
        _front == null || _back == null) return widget.child;

    // Paint text only once. Flutter's ImageFilter.shader has a filter-cache
    // issue with in-place shader uniform updates on some engine versions.
    // Swap between two reusable FragmentShaders on each tick so each frame
    // correctly invalidates its image filter without allocating GPU objects.
    return AnimatedBuilder(
      animation: widget.repaint,
      child: RepaintBoundary(child: widget.child),
      builder: (context, child) {
        _toggle = !_toggle;
        final shader = _toggle ? _front! : _back!;
        shader.setFloat(2, widget.clock());
        shader.setFloat(3, widget.treatment.toDouble());
        shader.setFloat(4, widget.depth.clamp(0.0, 1.0).toDouble());
        shader.setFloat(5, widget.edge.clamp(0.0, 1.0).toDouble());
        shader.setFloat(6, widget.bass().clamp(0.0, 1.0).toDouble());
        shader.setFloat(7, widget.accent.red / 255.0);
        shader.setFloat(8, widget.accent.green / 255.0);
        shader.setFloat(9, widget.accent.blue / 255.0);
        shader.setFloat(10, widget.secondary.red / 255.0);
        shader.setFloat(11, widget.secondary.green / 255.0);
        shader.setFloat(12, widget.secondary.blue / 255.0);
        shader.setFloat(13, widget.tertiary.red / 255.0);
        shader.setFloat(14, widget.tertiary.green / 255.0);
        shader.setFloat(15, widget.tertiary.blue / 255.0);
        shader.setFloat(16, widget.colorStrength.clamp(0.0, 1.0).toDouble());
        return ImageFiltered(
          imageFilter: ui.ImageFilter.shader(shader),
          child: child!,
        );
      },
    );
  }
}
