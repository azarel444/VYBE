import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Keeps song titles at their requested font size in every theme. When a
/// title is too wide for its slot it pans horizontally with feathered edges,
/// rather than shrinking the typography or forcing an ellipsis.
class SongTitleMarquee extends StatefulWidget {
  final String title;
  final TextStyle style;
  final Alignment alignment;
  // Reuse VYBE's existing 30-fps clock; no separate marquee ticker
  // consuming frames on underpowered Android head units.
  final Listenable animation;
  final double Function() elapsedSeconds;

  const SongTitleMarquee({
    super.key,
    required this.title,
    required this.style,
    required this.animation,
    required this.elapsedSeconds,
    this.alignment = Alignment.center,
  });

  @override
  State<SongTitleMarquee> createState() => _SongTitleMarqueeState();
}

class _SongTitleMarqueeState extends State<SongTitleMarquee> {
  late double _startTime;

  @override
  void initState() {
    super.initState();
    _startTime = widget.elapsedSeconds();
  }

  @override
  void didUpdateWidget(covariant SongTitleMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title) {
      // New tracks always start with their opening words fully visible.
      _startTime = widget.elapsedSeconds();
    }
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
            width: textWidth,
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
          animation: widget.animation,
          builder: (context, _) {
            // Longer titles pan at a readable pace instead of flying by.
            final seconds = (travel / 46.0 * 1.6 + 3.5)
                .clamp(9.0, 32.0).toDouble();
            final elapsed = math.max(0.0,
                widget.elapsedSeconds() - _startTime);
            final progress = (elapsed % seconds) / seconds;
            return textAt(-travel * _scrollFraction(progress));
          },
        ),
      );
    });
  }
}
