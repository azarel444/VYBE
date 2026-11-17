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

      // Use the space reclaimed from the removed progress bar for the main
      // sleeve and move BOTH text sections down. Every sleeve is projected
      // onto the SAME stage, never staggered down as it recedes.
      final centerSize = portrait
          ? math.min(w * .72, h * .37)
          : math.min(h * .54, w * .345);
      final floorY = h * (portrait ? .695 : .766);
      final side = queue.where((e) =>
          e.slot != 0 && e.slot.abs() <= (portrait ? 2 : 3) &&
          e.thumb != null && e.thumb!.isNotEmpty).toList()
        ..sort((a, b) => b.slot.abs().compareTo(a.slot.abs()));

      return ClipRect(child: TweenAnimationBuilder<double>(
        key: ValueKey<String>('coverflow-transition-$trackKey'),
        tween: Tween<double>(begin: 0, end: 1),
        duration: const Duration(milliseconds: 430),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => Transform.translate(
          offset: Offset((1 - t) * w * .037, 0),
          child: Opacity(
            opacity: (.55 + .45 * t).clamp(0.0, 1.0).toDouble(),
            child: child,
          ),
        ),
        child: Stack(fit: StackFit.expand, clipBehavior: Clip.hardEdge,
          children: [
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

            // Back to front. Every near sleeve occludes its actual rear
            // neighbor; selected art is always the final and frontmost cover.
            for (final entry in side)
              _sceneCover(entry.thumb, centerSize,
                _coverQuad(w, floorY, centerSize,
                  slot: entry.slot, portrait: portrait),
                distance: entry.slot.abs(), left: entry.slot < 0),
            _sceneCover(activeCover, centerSize,
              _coverQuad(w, floorY, centerSize,
                slot: 0, portrait: portrait),
              distance: 0, left: false),

            Positioned(
              top: portrait ? h * .045 : h * .002,
              left: w * .095, width: w * .81,
              height: portrait ? h * .18 : h * .22,
              child: Center(child: artistHeader),
            ),
            Positioned(
              left: w * .12, right: w * .12,
              top: portrait ? h * .773 : h * .781,
              height: portrait ? h * .080 : h * .087,
              child: Center(child: trackTitle),
            ),
            Positioned(
              left: w * .15, right: w * .15,
              top: portrait ? h * .864 : h * .887,
              height: portrait ? h * .075 : h * .076,
              child: Center(child: albumPlaque),
            ),
          ],
        ),
      ));
    });
  }

  // Literal four-corner planes match the approved mockup. The previous
  // rotateY on rectangular boxes couldn't establish the mockup's compound
  // angles, shared contact baseline or correct overlap.
  List<Offset> _coverQuad(double width, double floor, double size,
      {required int slot, required bool portrait}) {
    final cx = width * .5;
    if (slot == 0) {
      // The active cover is ALSO angled: upper edge narrower than lower
      // edge, as in the render, but remains prominent and nearly frontal.
      return [
        Offset(cx - size * .47, floor - size * .96),
        Offset(cx + size * .47, floor - size * .96),
        Offset(cx + size * .525, floor),
        Offset(cx - size * .525, floor),
      ];
    }

    final d = slot.abs();
    // [outerTopX, innerTopX, outerBottomX, innerBottomX,
    //  outerTopY, innerTopY, outerBottomY, innerBottomY]
    // X coordinates describe offsets LEFT of center. The right side mirrors
    // these exact corners. Close cards tuck visibly UNDER the active art,
    // and each outward sleeve is largely hidden by the preceding sleeve.
    final v = d == 1
        ? [-1.04, -.41, -1.20, -.425, -.86, -.95, -.05, 0.0]
        : d == 2
            ? [-1.43, -.91, -1.57, -.92, -.66, -.79, -.08, -.025]
            : [-1.70, -1.34, -1.84, -1.36, -.51, -.65, -.10, -.05];
    final xScale = portrait ? .56 : 1.0;
    Offset p(double x, double y) =>
        Offset(cx + size * x * xScale, floor + size * y);
    final outerTop = p(v[0], v[4]);
    final innerTop = p(v[1], v[5]);
    final outerBottom = p(v[2], v[6]);
    final innerBottom = p(v[3], v[7]);
    if (slot < 0) {
      return [outerTop, innerTop, innerBottom, outerBottom];
    }
    Offset flip(Offset o) => Offset(width - o.dx, o.dy);
    return [
      flip(innerTop), flip(outerTop),
      flip(outerBottom), flip(innerBottom),
    ];
  }

  Widget _sceneCover(Uint8List? bytes, double size, List<Offset> corners,
      {required int distance, required bool left}) {
    // A true four-point projective homography maps a square face to its
    // explicit trapezoid, including the sideward top/bottom pitch. Unlike
    // a basic Y rotation this is deterministic on head units and DeX.
    final transform = _planeMatrix(corners, size);
    return Positioned(
      left: 0, top: 0, width: size, height: size * 1.44,
      // Keep the raster boundary INSIDE the transform. A boundary at
      // (0,0) around an off-center projected card can cull its pixels.
      child: Transform(
        alignment: Alignment.topLeft,
        transform: transform,
        transformHitTests: false,
        child: RepaintBoundary(
          child: Opacity(
            opacity: distance == 0 ? 1 : distance == 1 ? 1
                : distance == 2 ? .83 : .65,
            child: _coverAndReflection(bytes, size,
              distance: distance, left: left),
          ),
        ),
      ),
    );
  }

  Matrix4 _planeMatrix(List<Offset> q, double size) {
    // Destination points: top-left, top-right, bottom-right, bottom-left.
    final tl = q[0], tr = q[1], br = q[2], bl = q[3];
    final dx1 = tr.dx - br.dx;
    final dx2 = bl.dx - br.dx;
    final dx3 = tl.dx - tr.dx + br.dx - bl.dx;
    final dy1 = tr.dy - br.dy;
    final dy2 = bl.dy - br.dy;
    final dy3 = tl.dy - tr.dy + br.dy - bl.dy;
    final determinant = dx1 * dy2 - dx2 * dy1;
    final g = determinant.abs() < 0.000001 ? 0.0
        : (dx3 * dy2 - dx2 * dy3) / determinant;
    final h = determinant.abs() < 0.000001 ? 0.0
        : (dx1 * dy3 - dx3 * dy1) / determinant;
    final a = tr.dx - tl.dx + g * tr.dx;
    final b = bl.dx - tl.dx + h * bl.dx;
    final d = tr.dy - tl.dy + g * tr.dy;
    final e = bl.dy - tl.dy + h * bl.dy;
    return Matrix4.identity()
      ..setEntry(0, 0, a / size)
      ..setEntry(0, 1, b / size)
      ..setEntry(0, 3, tl.dx)
      ..setEntry(1, 0, d / size)
      ..setEntry(1, 1, e / size)
      ..setEntry(1, 3, tl.dy)
      ..setEntry(3, 0, g / size)
      ..setEntry(3, 1, h / size);
  }

  Widget _coverAndReflection(Uint8List? bytes, double size,
      {required int distance, required bool left}) {
    final active = distance == 0;
    final accent = active ? palette.a
        : distance == 1 ? palette.b : palette.c;
    final borderRadius = BorderRadius.circular(active ? 9 : 5);
    final reflectionHeight = size * (active ? .35 : .31);
    Widget coverFace() => ClipRRect(
      borderRadius: borderRadius,
      child: bytes != null
          ? Image.memory(bytes, width: size, height: size,
              fit: BoxFit.cover,
              cacheWidth: active ? 1024 : distance == 1 ? 320 : distance == 2 ? 224 : 144,
              filterQuality: active
                  ? FilterQuality.medium : FilterQuality.low,
              gaplessPlayback: true)
          : Image.asset('assets/vybe_album_placeholder.png',
              width: size, height: size, fit: BoxFit.cover),
    );

    return Stack(clipBehavior: Clip.none, children: [
      // Cast a distinct, soft shadow OUTWARD over the actual rear sleeve.
      // The near art is composited after that rear sleeve, so it visibly
      // occludes and shades it, instead of just dimming its own front face.
      if (!active)
        Positioned(
          left: left ? -size * .38 : size * .79,
          top: size * .11,
          width: size * .59,
          height: size * .80,
          child: IgnorePointer(child: DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(
              begin: left ? Alignment.centerLeft : Alignment.centerRight,
              end: left ? Alignment.centerRight : Alignment.centerLeft,
              colors: [Colors.transparent,
                Colors.black.withOpacity(distance == 1 ? .78 : .63)],
            )),
          )),
        ),
      Positioned(left: 1, top: size + 3,
        width: size - 2, height: reflectionHeight,
        child: Opacity(
          opacity: active ? .75 : distance == 1 ? .55 : .31,
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
              color: accent.withOpacity(active ? .96 : .87),
              width: active ? 2.1 : 1.35),
            boxShadow: [
              // Painted behind later/nearer covers; this shadow actually
              // reaches the artwork behind it instead of darkening itself.
              BoxShadow(
                color: Colors.black.withOpacity(active ? .84 : .94),
                offset: Offset(active ? 9 : (left ? -17 : 17),
                  active ? 13 : 8),
                blurRadius: active ? 23 : 20,
                spreadRadius: active ? 2 : 9),
              BoxShadow(
                color: accent.withOpacity(active
                    ? .82 : distance == 1 ? .54 : distance == 2 ? .31 : .16),
                blurRadius: performanceMode
                    ? (active ? 17 : 10)
                    : (active ? 42 : distance == 1 ? 35 : 21),
                spreadRadius: active ? (performanceMode ? 2 : 5) : 3),
              if (active && !performanceMode)
                BoxShadow(color: palette.b.withOpacity(.38),
                  blurRadius: 50, spreadRadius: 1),
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
        p.a.withOpacity(.37), p.b.withOpacity(.16),
        Colors.transparent],
      ).createShader(pool));
    // Separate reflected colored light around the left and right sleeves.
    for (final sideX in [.23, .77]) {
      final sidePool = Rect.fromCenter(
        center: Offset(w * sideX, y + h * .051),
        width: w * .32, height: h * .18);
      canvas.drawOval(sidePool, Paint()
        ..shader = RadialGradient(colors: [
          p.b.withOpacity(.20), p.c.withOpacity(.07),
          Colors.transparent,
        ]).createShader(sidePool));
    }
    // Very fine film-grain streaks and tiny reflected highlights. Because
    // the mirrored covers are translucent, this remains visible through them.
    final grain = Paint()..strokeWidth = .85;
    for (var i = 0; i < 440; i++) {
      final seed = (i * 1664525 + 1013904223) & 0x7fffffff;
      final u = (seed % 10003) / 10003.0;
      final v = ((seed ~/ 59) % 10007) / 10007.0;
      final yy = y + (h - y) * v;
      final xx = w * u;
      final length = (5 + v * 41) * (i % 7 == 0 ? 2.9 : 1);
      final tint = i % 4 == 0 ? p.a : (i % 4 == 1 ? p.b : Colors.white);
      grain.color = tint.withOpacity((.040 + v * .087)
          .clamp(0.0, .13));
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
