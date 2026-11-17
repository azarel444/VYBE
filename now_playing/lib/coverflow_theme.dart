import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'coverflow_queue.dart';
import 'palette.dart';

/// Landscape-first VYBE Coverflow. Geometry, layered occlusion, ambient light,
/// floor-grain texture, full mirrored side-cover reflections and the selected
/// album/brand palette are rendered live. The mockup itself is NEVER painted
/// as a static background.
class CoverflowScene extends StatelessWidget {
  final String trackKey;
  final Uint8List? activeCover;
  final List<CoverflowCover> queue;
  final ArtPalette palette;
  final Widget artistHeader;
  final Widget trackTitle;
  final Widget albumPlaque;
  final Widget progress;
  final Widget? leftVisualizer;
  final Widget? rightVisualizer;
  final bool performanceMode;

  const CoverflowScene({
    super.key,
    required this.trackKey,
    required this.activeCover,
    required this.queue,
    required this.palette,
    required this.artistHeader,
    required this.trackTitle,
    required this.albumPlaque,
    required this.progress,
    this.leftVisualizer,
    this.rightVisualizer,
    this.performanceMode = false,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      final h = box.maxHeight;
      if (w <= 0 || h <= 0) return const SizedBox.shrink();
      final portrait = h > w * 1.08;
      final centerSize = portrait
          ? math.min(w * .57, h * .36)
          : math.min(h * .44, w * .31);
      final coverTop = portrait ? h * .295 : h * .238;
      final floorY = coverTop + centerSize * .97;
      final side = queue.where((e) =>
          e.slot != 0 && e.slot.abs() <= (portrait ? 2 : 3) &&
          e.thumb != null && e.thumb!.isNotEmpty).toList();
      // Reverse distance order. Nearest covers cast a dark silhouette across
      // the far covers behind them; the center artwork is always topmost.
      side.sort((a, b) => b.slot.abs().compareTo(a.slot.abs()));
      final all = <Widget>[
        Positioned.fill(child: IgnorePointer(
          child: CustomPaint(
            painter: _CoverflowAtmosphere(palette, floorY / h),
          ),
        )),
        if (leftVisualizer != null)
          Positioned(left: 0, top: 0, bottom: 0, width: w * .08,
              child: IgnorePointer(child: leftVisualizer!)),
        if (rightVisualizer != null)
          Positioned(right: 0, top: 0, bottom: 0, width: w * .08,
              child: IgnorePointer(child: rightVisualizer!)),
        for (final entry in side)
          _positionedCover(entry, w, h, centerSize, coverTop,
              portrait: portrait),
        _centerCover(w, h, centerSize, coverTop),
        Positioned(
          top: portrait ? h * .045 : h * .002,
          left: w * .095,
          width: w * .81,
          height: portrait ? h * .18 : h * .22,
          child: Center(child: artistHeader),
        ),
        Positioned(
          left: w * .12, right: w * .12,
          top: portrait ? h * .763 : h * .721,
          height: portrait ? h * .092 : h * .098,
          child: Center(child: trackTitle),
        ),
        Positioned(
          left: w * .15, right: w * .15,
          top: portrait ? h * .86 : h * .842,
          height: portrait ? h * .07 : h * .07,
          child: Center(child: albumPlaque),
        ),
        Positioned(left: w * .26, right: w * .26,
          bottom: h * .06, height: 3.5,
          child: progress),
      ];
      return ClipRect(child: TweenAnimationBuilder<double>(
        // Transition occurs only on track change. No continuously animated
        // 3D transforms, glowing blurs or floor effects on the 2GB ATOTO.
        key: ValueKey<String>('coverflow-transition-$trackKey'),
        tween: Tween<double>(begin: 0, end: 1),
        duration: const Duration(milliseconds: 430),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => Transform.translate(
          offset: Offset((1 - t) * w * .037, 0),
          child: Opacity(opacity: (.55 + .45 * t).clamp(0.0, 1.0),
            child: child)),
        child: Stack(fit: StackFit.expand,
          clipBehavior: Clip.hardEdge, children: all),
      ));
    });
  }

  Widget _positionedCover(CoverflowCover entry, double w, double h,
      double centerSize, double coverTop, {required bool portrait}) {
    final distance = entry.slot.abs();
    final near = distance == 1;
    final shrink = portrait
        ? (near ? .77 : .56)
        : (distance == 1 ? .84 : distance == 2 ? .65 : .48);
    final size = centerSize * shrink;
    final xFraction = portrait
        ? (near ? .21 : .095)
        : distance == 1 ? .292 : distance == 2 ? .195 : .124;
    final centerX = entry.slot < 0 ? w * xFraction : w * (1 - xFraction);
    // The near cards touch the center's rim but do not obliterate it.
    final top = coverTop + centerSize - size +
        (distance > 1 ? centerSize * .019 * (distance - 1) : 0);
    final intensity = near ? .91 : distance == 2 ? .68 : .46;
    final turn = (entry.slot < 0 ? 1 : -1) * (.34 + .07 * distance);
    return Positioned(
      left: centerX - size / 2,
      top: top,
      width: size,
      height: size * 1.38,
      child: RepaintBoundary(
        child: Opacity(opacity: intensity,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, .0017)
              ..rotateY(turn),
            child: _coverAndReflection(
              entry.thumb, size, distance: distance,
              left: entry.slot < 0),
          ),
        ),
      ),
    );
  }

  Widget _centerCover(double w, double h, double size, double y) {
    return Positioned(
      left: (w - size) * .5, top: y,
      width: size, height: size * 1.45,
      child: RepaintBoundary(child: _coverAndReflection(
        activeCover, size, distance: 0, left: false)),
    );
  }

  Widget _coverAndReflection(Uint8List? bytes, double size,
      {required int distance, required bool left}) {
    final active = distance == 0;
    final accent = active ? palette.a
        : distance == 1 ? palette.b : palette.c;
    final borderRadius = BorderRadius.circular(active ? 9 : 5);
    final reflectionHeight = size * (active ? .24 : .26);
    Widget coverFace() => ClipRRect(
      borderRadius: borderRadius,
      child: bytes != null
          ? Image.memory(bytes, width: size, height: size,
              fit: BoxFit.cover,
              cacheWidth: active ? 1024 : 288,
              filterQuality: active
                  ? FilterQuality.medium : FilterQuality.low,
              gaplessPlayback: true)
          : Image.asset('assets/vybe_album_placeholder.png',
              width: size, height: size, fit: BoxFit.cover),
    );

    return Stack(clipBehavior: Clip.hardEdge, children: [
      Positioned(left: 1, top: size + 3,
        width: size - 2, height: reflectionHeight,
        child: Opacity(
          opacity: active ? .7 : distance == 1 ? .42 : .23,
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xD9FFFFFF), Color(0x90FFFFFF),
                Color(0x00FFFFFF),
              ],
              stops: [0, .20, 1],
            ).createShader(rect),
            child: ClipRect(child: OverflowBox(
              alignment: Alignment.topCenter,
              minWidth: size, maxWidth: size,
              minHeight: size, maxHeight: size,
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.diagonal3Values(1, -1, 1),
                child: coverFace(),
              ),
            )),
          ),
        ),
      ),
      Positioned(left: 0, top: 0, width: size, height: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF080809),
            borderRadius: borderRadius,
            border: Border.all(
              color: accent.withOpacity(active ? .93 : .67),
              width: active ? 2.1 : 1.35),
            boxShadow: [
              const BoxShadow(color: Color(0xD9000000),
                offset: Offset(8, 11), blurRadius: 14),
              BoxShadow(
                color: accent.withOpacity(active ? .56 : distance == 1 ? .33 : .11),
                blurRadius: active ? 21 : distance == 1 ? 11 : 3,
                spreadRadius: active ? .9 : 0),
              if (active && !performanceMode)
                BoxShadow(color: palette.b.withOpacity(.23),
                  blurRadius: 29, spreadRadius: 1),
            ],
          ),
          child: Stack(fit: StackFit.expand, children: [
            Padding(padding: EdgeInsets.all(active ? 2 : 1),
              child: coverFace()),
            // Closest cover occludes the next one and casts a dark falloff on
            // the visible rear face; no hard black bar or duplicate album.
            if (!active)
              IgnorePointer(child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: left ? Alignment.centerRight : Alignment.centerLeft,
                    end: left ? Alignment.centerLeft : Alignment.centerRight,
                    colors: [
                      Colors.black.withOpacity(distance == 1 ? .36 : .55),
                      Colors.black.withOpacity(.07),
                    ],
                  ),
                ),
              )),
            // Luminous top-edge specular reflection follows palette, not
            // the fixed amber coloring of the reference mockup.
            Positioned(left: size * .06, right: size * .06, top: 0,
              height: active ? 3 : 1.5,
              child: DecoratedBox(decoration: BoxDecoration(
                gradient: LinearGradient(colors: [
                  Colors.transparent, accent.withOpacity(active ? 1 : .65),
                  Colors.transparent],
                ),
              ))),
          ]),
        ),
      ),
      // Dark contact shadow at the artwork-to-floor junction. This is
      // distinct from the reflection fade and preserved under every card.
      Positioned(left: size * .035, right: size * .035,
        top: size, height: math.max(2, size * .035),
        child: IgnorePointer(child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [const Color(0xAA000000),
                const Color(0x00000000)],
            ),
          ),
        )),
      ),
    ]);
  }
}

/// Textured reflective stage, colorized entirely from the active VYBE palette.
/// Painted once per palette/size change; no animation or texture downloads.
class _CoverflowAtmosphere extends CustomPainter {
  final ArtPalette p;
  final double horizon;
  const _CoverflowAtmosphere(this.p, this.horizon);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final y = h * horizon;
    final stage = Rect.fromLTWH(0, y, w, h - y);
    canvas.drawRect(stage, Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        stops: const [0, .14, .46, 1],
        colors: [
          const Color(0xA0000000),
          Color.lerp(const Color(0xF0000000), p.a, .075)!,
          const Color(0xEE08070A), const Color(0xED020204),
        ],
      ).createShader(stage));
    // The floor glows at the foot of the front artwork and spreads
    // horizontally into the side-cover reflection positions.
    final pool = Rect.fromCenter(
        center: Offset(w * .5, y + h * .075),
        width: w * .74, height: h * .27);
    canvas.drawOval(pool, Paint()
      ..shader = RadialGradient(colors: [
        p.a.withOpacity(.23), p.b.withOpacity(.09),
        Colors.transparent],
      ).createShader(pool));
    // Very fine film-grain streaks and tiny reflected highlights. Because
    // the mirrored covers are translucent, this remains visible through them.
    final grain = Paint()..strokeWidth = .60;
    for (var i = 0; i < 150; i++) {
      final seed = (i * 1664525 + 1013904223) & 0x7fffffff;
      final u = (seed % 10003) / 10003.0;
      final v = ((seed ~/ 59) % 10007) / 10007.0;
      final yy = y + (h - y) * v;
      final xx = w * u;
      final length = (4 + (1 - v) * 26) * (i % 5 == 0 ? 2.7 : 1);
      final tint = i % 4 == 0 ? p.a : (i % 4 == 1 ? p.b : Colors.white);
      grain.color = tint.withOpacity((.018 + (1 - v) * .038)
          .clamp(0.0, .07));
      canvas.drawLine(Offset(xx, yy), Offset(xx + length, yy), grain);
    }
    final rim = Paint()
      ..strokeWidth = 1.2
      ..shader = LinearGradient(colors: [
          Colors.transparent, p.b.withOpacity(.45),
          p.a.withOpacity(.65), p.b.withOpacity(.40),
          Colors.transparent])
          .createShader(Rect.fromLTWH(w * .10, y, w * .80, 2));
    canvas.drawLine(Offset(w * .10, y), Offset(w * .90, y), rim);
    final specular = Paint()..strokeWidth = 2.2
      ..shader = LinearGradient(colors: [
          Colors.transparent, p.b.withOpacity(.42),
          p.a.withOpacity(.83), p.c.withOpacity(.34),
          Colors.transparent])
        .createShader(Rect.fromLTWH(w * .32, y, w * .36, 2));
    canvas.drawLine(Offset(w * .32, y + 1), Offset(w * .68, y + 1),
        specular);
  }

  @override
  bool shouldRepaint(covariant _CoverflowAtmosphere old) =>
      old.horizon != horizon || old.p.a != p.a ||
      old.p.b != p.b || old.p.c != p.c;
}
