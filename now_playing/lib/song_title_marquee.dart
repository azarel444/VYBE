import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Keeps song titles at their requested font size in every theme. When a
/// title is too wide for its slot it pans horizontally with feathered edges,
/// rather than shrinking the typography or forcing an ellipsis.
class SongTitleMarquee extends StatefulWidget {
  final String title;
  final TextStyle style;
  final Alignment alignment;

  const SongTitleMarquee({
    super.key,
    required this.title,
    required this.style,
    this.alignment = Alignment.center,
  });

  @override
  State<SongTitleMarquee> createState() => _SongTitleMarqueeState();
}

class _SongTitleMarqueeState extends State<SongTitleMarquee>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scroll = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 13),
  )..repeat();

  @override
  void didUpdateWidget(covariant SongTitleMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title) {
      // New tracks start with the first words fully visible.
      _scroll
        ..reset()
        ..repeat();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  double _scrollFraction(double p) {
    // Pause to read the beginning, pan to the end, pause again, then
    // ease back to the beginning. No clipping or scaled-down fonts.
    if (p < .15) return 0;
    if (p < .66) {
      return Curves.easeInOut.transform((p - .15) / .51);
    }
    if (p < .82) return 1;
    return 1 - Curves.easeInOut.transform((p - .82) / .18);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final screenWidth = MediaQuery.sizeOf(context).width;
      final available = box.maxWidth.isFinite
          ? math.max(1.0, box.maxWidth)
          : math.max(1.0, screenWidth * .86);
      final direction = Directionality.of(context);
      final painter = TextPainter(
        text: TextSpan(text: widget.title, style: widget.style),
        textDirection: direction,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final textWidth = painter.width + 2;
      final height = math.max(painter.height + 8, 24.0);
      painter.dispose();
      final travel = math.max(0.0, textWidth - available);
      final overflow = travel > 1;
      final xAtRest = widget.alignment.x < -.5
          ? 0.0 : widget.alignment.x > .5
              ? available - textWidth
              : (available - textWidth) / 2;

      Widget textAt(double x) => SizedBox(
        width: available,
        height: height,
        child: ClipRect(child: Stack(children: [
          Positioned(
            left: x,
            top: 3,
            child: Text(widget.title,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.visible,
              textScaler: MediaQuery.textScalerOf(context),
              style: widget.style),
          ),
        ])),
      );

      if (!overflow) return textAt(xAtRest);

      return ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => const LinearGradient(
          colors: [Colors.transparent, Colors.white,
            Colors.white, Colors.transparent],
          stops: [0.0, .042, .958, 1.0],
        ).createShader(bounds),
        child: AnimatedBuilder(
          animation: _scroll,
          builder: (context, _) =>
              textAt(-travel * _scrollFraction(_scroll.value)),
        ),
      );
    });
  }
}
