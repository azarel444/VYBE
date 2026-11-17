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
            for (final entry in side) ...[
              if (entry.slot.abs() == 1)
                Positioned.fill(child: IgnorePointer(
                  child: CustomPaint(painter: _CoverflowCoverGlow(
                    quad: _coverQuad(w, floorY, centerSize,
                      slot: entry.slot, portrait: portrait),
                    accent: palette.a, performanceMode: performanceMode,
                    strength: .79)),
                )),
              _sceneCover(entry.thumb, centerSize,
                _coverQuad(w, floorY, centerSize,
                  slot: entry.slot, portrait: portrait),
                distance: entry.slot.abs(), left: entry.slot < 0),
            ],
            Positioned.fill(child: IgnorePointer(
              child: CustomPaint(painter: _CoverflowCoverGlow(
                quad: _coverQuad(w, floorY, centerSize,
                  slot: 0, portrait: portrait),
                accent: palette.a, performanceMode: performanceMode,
                strength: 1.0)),
            )),
            _sceneCover(activeCover, centerSize,
              _coverQuad(w, floorY, centerSize,
                slot: 0, portrait: portrait),
              distance: 0, left: false),

            Positioned(
              top: portrait ? h * .045 : h * .002,
              left: w * .095, width: w * .81,
              height: portrait ? h * .18 : h * .255,
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
      // Main sleeve is a deliberately PROJECTED square, not a rectangle:
      // its upper edge has receded in depth, with a slight diagonal pitch.
      // Its bottom edge is wider and closer to the camera, like the render.
      return [
        Offset(cx - size * .475, floor - size * .965),
        Offset(cx + size * .485, floor - size * .938),
        Offset(cx + size * .565, floor),
        Offset(cx - size * .565, floor),
      ];
    }

    final d = slot.abs();
    // [outerTopX, innerTopX, outerBottomX, innerBottomX,
    //  outerTopY, innerTopY, outerBottomY, innerBottomY]
    // X coordinates describe offsets LEFT of center. The right side mirrors
    // these exact corners. Close cards tuck visibly UNDER the active art,
    // and each outward sleeve is largely hidden by the preceding sleeve.
    // Exterior top corners move BACK and UP in depth. Bottom corners
    // remain on an almost level stage line. Do not turn the bottom edges
    // upward into the incorrect "wings" shown in previous APK screenshots.
    final v = d == 1
        ? [-1.09, -.46, -1.225, -.45, -.82, -.69, -.008, -.008]
        : d == 2
            ? [-1.45, -.90, -1.56, -.94, -.655, -.555, -.025, -.025]
            : [-1.69, -1.31, -1.78, -1.34, -.51, -.435, -.050, -.050];
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
            opacity: distance == 0 ? 1.0 : distance == 1 ? 1.0
                : distance == 2 ? .97 : .84,
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
    final accent = Color.lerp(palette.a, palette.b,
        active ? 0 : distance == 1 ? .13 : .23)!;
    final borderRadius = BorderRadius.circular(active ? 9 : 5);
    final reflectionHeight = size * (active ? .225 : .17);
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
      Positioned(left: 1, top: size + 3,
        width: size - 2, height: reflectionHeight,
        child: Opacity(
          opacity: active ? .47 : distance == 1 ? .30 : .12,
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xB6FFFFFF), Color(0x4AFFFFFF),
                Color(0x00FFFFFF),
              ],
              stops: [0, .24, 1],
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
              // Only a small neutral contact shadow below the sleeve.
              // Cast darkness is painted INSIDE the underlying rear face,
              // never as a floating black rectangle off the front rim.
              BoxShadow(
                color: Colors.black.withOpacity(.45),
                offset: const Offset(0, 3),
                blurRadius: 6,
                spreadRadius: 0),
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
            // True BLACK occlusion is limited to pixels of the REAR
            // album face. Each inner edge faces its nearer neighbor.
            // Clipping the shade here prevents cast shadows from hanging
            // outside the rear cover or across the fanart/background.
            if (!active)
              Positioned.fill(child: ClipRRect(
                borderRadius: borderRadius,
                child: IgnorePointer(child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: left ? Alignment.centerRight : Alignment.centerLeft,
                      end: left ? Alignment.centerLeft : Alignment.centerRight,
                      colors: [
                        Colors.black.withOpacity(.995),
                        Colors.black.withOpacity(distance == 1 ? .95 : .985),
                        Colors.black.withOpacity(distance == 1 ? .35 : .52),
                        Colors.transparent,
                      ],
                      stops: const [0, .11, .34, .61],
                    ),
                  ),
                )),
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

/// Stage-darkening is translucent at its strongest point and deliberately
/// FADES OUT downwards, revealing the artist fanart all the way to the bottom.
/// No random horizontal scratches and no flat opaque rectangle.
class _CoverflowAtmosphere extends CustomPainter {
  final ArtPalette p;
  final double horizon;
  const _CoverflowAtmosphere(this.p, this.horizon);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final y = h * horizon;
    final stage = Rect.fromLTWH(0, y, w, math.max(1, h - y));

    canvas.drawRect(stage, Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: [0, .13, .48, .78, 1],
        colors: [
          Color(0x95000000), // Dark contact zone but NOT opaque
          Color(0x79000000),
          Color(0x47000000),
          Color(0x1E000000),
          Color(0x00000000), // Fade the black to transparent at the bottom
        ],
      ).createShader(stage));

    // Narrow light spill hugs the foot of each sleeve. No large, blurry
    // colored cloud obscuring the floor or the artist background behind it.
    for (final spill in const <List<double>>[
      [0.50, 0.39, 0.38],
      [0.31, 0.21, 0.23],
      [0.69, 0.21, 0.23],
    ]) {
      final x = spill[0], width = spill[1], strength = spill[2];
      final light = Rect.fromCenter(
        center: Offset(w * x, y + h * .017),
        width: w * width, height: h * .092);
      canvas.drawOval(light, Paint()
        ..shader = RadialGradient(
          colors: [
            p.a.withOpacity(strength),
            p.b.withOpacity(strength * .16),
            Colors.transparent,
          ],
          stops: const [0, .25, 1],
        ).createShader(light));
    }

    // An almost imperceptible polished-stone micrograin; not horizontal
    // streaks. The subtle specks remain visible THROUGH translucent cover
    // reflections and appear across the WHOLE floor, not just bright pools.
    final grain = Paint();
    for (var i = 0; i < 1000; i++) {
      final seed = (i * 1664525 + 1013904223) & 0x7fffffff;
      final u = (seed % 10003) / 10003.0;
      final v = ((seed ~/ 67) % 10007) / 10007.0;
      final px = w * u, py = y + (h - y) * v;
      grain.color = (i % 3 == 0 ? Colors.white : Colors.black)
          .withOpacity(i % 3 == 0 ? .034 : .064);
      canvas.drawCircle(Offset(px, py), i % 5 == 0 ? .68 : .38, grain);
    }
  }

  @override
  bool shouldRepaint(covariant _CoverflowAtmosphere old) =>
      old.horizon != horizon || old.p.a != p.a ||
      old.p.b != p.b || old.p.c != p.c;
}

/// A bright tight rim plus soft colored bloom, drawn immediately BEHIND
/// each visible cover. Colors always follow the selected album/VYBE palette.
class _CoverflowCoverGlow extends CustomPainter {
  final List<Offset> quad;
  final Color accent;
  final double strength;
  final bool performanceMode;
  const _CoverflowCoverGlow({
    required this.quad, required this.accent, required this.strength,
    required this.performanceMode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(quad[0].dx, quad[0].dy)
      ..lineTo(quad[1].dx, quad[1].dy)
      ..lineTo(quad[2].dx, quad[2].dy)
      ..lineTo(quad[3].dx, quad[3].dy)
      ..close();
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = performanceMode ? 6 : 11
      ..maskFilter = MaskFilter.blur(BlurStyle.normal,
        performanceMode ? 6 : 14)
      ..color = accent.withOpacity(.88 * strength));
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = performanceMode ? 3.2 : 4.5
      ..maskFilter = MaskFilter.blur(BlurStyle.normal,
        performanceMode ? 1.5 : 3.0)
      ..color = accent.withOpacity(.88 * strength));
    // The tight warm/white specular pinline of the approved rendering.
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..color = Color.lerp(accent, Colors.white, .29)!
          .withOpacity(.90 * strength));
    // Small focused flares at the floor contact points, not a huge floor fog.
    for (final point in [quad[2], quad[3]]) {
      final bounds = Rect.fromCircle(center: point, radius: performanceMode ? 8 : 14);
      canvas.drawCircle(point, performanceMode ? 8 : 14,
        Paint()..shader = RadialGradient(colors: [
          Colors.white.withOpacity(.72 * strength),
          accent.withOpacity(.48 * strength),
          Colors.transparent,
        ]).createShader(bounds));
    }
  }

  @override
  bool shouldRepaint(covariant _CoverflowCoverGlow old) =>
      old.accent != accent || old.strength != strength ||
      old.performanceMode != performanceMode || old.quad[0] != quad[0] ||
      old.quad[1] != quad[1] || old.quad[2] != quad[2];
}
