import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Isolates a widget FX as one compositing layer, rather than applying its
/// transfer mode to the entire Now Playing UI. Normal/opaque skips saveLayer.
class FxComposite extends SingleChildRenderObjectWidget {
  final int mode;
  final double opacity;
  const FxComposite({super.key, required this.mode, required this.opacity, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _FxCompositeRender(mode, opacity);

  @override
  void updateRenderObject(BuildContext context, covariant _FxCompositeRender renderObject) {
    renderObject.configure(mode, opacity);
  }
}

class _FxCompositeRender extends RenderProxyBox {
  _FxCompositeRender(this._mode, this._opacity);
  int _mode;
  double _opacity;
  void configure(int mode, double opacity) {
    if (_mode == mode && _opacity == opacity) return;
    _mode = mode;
    _opacity = opacity;
    markNeedsPaint();
  }

  static const modes = <BlendMode>[
    BlendMode.srcOver, BlendMode.plus, BlendMode.screen, BlendMode.multiply,
    BlendMode.overlay, BlendMode.softLight, BlendMode.hardLight,
    BlendMode.lighten, BlendMode.darken, BlendMode.colorDodge,
    BlendMode.colorBurn, BlendMode.difference, BlendMode.exclusion,
    BlendMode.hue, BlendMode.saturation, BlendMode.color,
    BlendMode.luminosity, BlendMode.srcIn, BlendMode.dstIn,
    BlendMode.srcOut, BlendMode.dstOut, BlendMode.xor,
    BlendMode.modulate, BlendMode.clear,
  ];

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || _opacity <= 0) return;
    if (_mode == 0 && _opacity >= 0.999) {
      super.paint(context, offset);
      return;
    }
    final bounds = offset & size;
    context.canvas.saveLayer(bounds, Paint()
      ..blendMode = modes[_mode.clamp(0, modes.length - 1)]
      ..color = Color.fromRGBO(255, 255, 255, _opacity.clamp(0.0, 1.0)));
    super.paint(context, offset);
    context.canvas.restore();
  }
}
