import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'coverflow_floor_grain.dart';

import 'package:flutter/material.dart';

import 'coverflow_queue.dart';
import 'palette.dart';

// Decode the supplied floor photograph exactly once, instead of decoding
// a texture on every playback frame. All art and color glows remain dynamic.
final Future<ui.Image> _coverflowGrainImage = () async {
  final codec = await ui.instantiateImageCodec(coverflowFloorGrainBytes);
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
  }
}();

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
  final GlobalKey? artAnchorKey;
  final VoidCallback? onTapCover;
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
    this.artAnchorKey,
    this.onTapCover,
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
      final selectedQuad = _coverQuad(w, floorY, centerSize,
          slot: 0, portrait: portrait);
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
              child: FutureBuilder<ui.Image>(
                future: _coverflowGrainImage,
                builder: (context, frame) => CustomPaint(
                  painter: _CoverflowAtmosphere(
                    palette, floorY / h, grain: frame.data,
                  ),
                ),
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
              // The foreground sleeve shades ONLY the actual rear sleeve.
              // Draw after the rear sleeve and before the nearer one.
              if (entry.slot.abs() <= 2 &&
                  side.any((e) => e.slot ==
                    (entry.slot < 0 ? -1 : 1) *
                        (entry.slot.abs() + 1)))
                Positioned.fill(child: IgnorePointer(
                  child: CustomPaint(painter: _CoverflowGapShadow(
                    front: _coverQuad(w, floorY, centerSize,
                      slot: entry.slot, portrait: portrait),
                    rear: _coverQuad(w, floorY, centerSize,
                      slot: (entry.slot < 0 ? -1 : 1) *
                          (entry.slot.abs() + 1), portrait: portrait),
                    side: entry.slot < 0 ? -1 : 1,
                    unit: centerSize,
                  )),
                )),
              _sceneCover(entry.thumb, centerSize,
                _coverQuad(w, floorY, centerSize,
                  slot: entry.slot, portrait: portrait),
                distance: entry.slot.abs(), left: entry.slot < 0),
              Positioned.fill(child: IgnorePointer(
                // Each side album touches the polished floor at its outward
                // bottom corner. Light there, NOT around the full quad.
                child: CustomPaint(painter: _CoverflowCoverGlow(
                  quad: _coverQuad(w, floorY, centerSize,
                    slot: entry.slot, portrait: portrait),
                  accent: palette.a, performanceMode: performanceMode,
                  strength: entry.slot.abs() == 1 ? .95
                      : entry.slot.abs() == 2 ? .45 : .22,
                  selected: false, side: entry.slot < 0 ? -1 : 1)),
              )),
            ],
            // Central cover shadows touch the two nearest side covers,
            // but must never cast above those sleeves' top edges.
            for (final sign in const [-1, 1])
              if (side.any((e) => e.slot == sign))
                Positioned.fill(child: IgnorePointer(
                  child: CustomPaint(painter: _CoverflowGapShadow(
                    front: _coverQuad(w, floorY, centerSize,
                      slot: 0, portrait: portrait),
                    rear: _coverQuad(w, floorY, centerSize,
                      slot: sign, portrait: portrait),
                    side: sign, unit: centerSize,
                  )),
                )),
            _sceneCover(activeCover, centerSize,
              _coverQuad(w, floorY, centerSize,
                slot: 0, portrait: portrait),
              distance: 0, left: false),
            // Explicit artwork geometry anchor for global FX layers.
            // Without this, Rays/Ripples/Shockwave fall back to .25 screen
            // width and appear to launch at unrelated places.
            if (artAnchorKey != null || onTapCover != null)
              Positioned(
                left: selectedQuad[3].dx,
                top: math.min(selectedQuad[0].dy, selectedQuad[1].dy),
                width: selectedQuad[2].dx - selectedQuad[3].dx,
                height: floorY -
                    math.min(selectedQuad[0].dy, selectedQuad[1].dy),
                // An actual hit-test surface is needed: the projective
                // sleeve uses transformHitTests:false, and previously had
                // no onTap at all. A center-cover tap opens the source app.
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTapCover,
                  child: SizedBox.expand(key: artAnchorKey),
                ),
              ),
            // The selected sleeve gets a continuous palette-colored stroke
            // ABOVE the image, with a tight glow and corner pin lights.
            Positioned.fill(child: IgnorePointer(
              child: CustomPaint(painter: _CoverflowCoverGlow(
                quad: _coverQuad(w, floorY, centerSize,
                  slot: 0, portrait: portrait),
                accent: palette.a, performanceMode: performanceMode,
                strength: 1.0, selected: true, side: 0)),
            )),
            // The texture must be composited OVER the mirrored sleeves,
            // not buried under them. Clip it to the FLOOR only so it
            // cannot fog or darken artwork above the point of contact.
            Positioned.fill(child: IgnorePointer(
              child: FutureBuilder<ui.Image>(
                future: _coverflowGrainImage,
                builder: (context, frame) => CustomPaint(
                  painter: _CoverflowFloorFinish(
                    palette, floorY / h, frame.data),
                ),
              ),
            )),

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
        Offset(cx - size * .475, floor - size * .936),
        Offset(cx + size * .485, floor - size * .916),
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
    // Distant sleeves are nested tightly: only a slim 15-23% strip
    // remains visible beyond the nearer sleeve on either side.
    final v = d == 1
        ? [-1.09, -.46, -1.225, -.45, -.82, -.69, -.008, -.008]
        : d == 2
            ? [-1.225, -.90, -1.355, -.935, -.66, -.56, -.025, -.025]
            : [-1.345, -1.12, -1.475, -1.16, -.51, -.44, -.043, -.043];
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
        // Keep every distant sleeve fully opaque. Depth is achieved by
        // progressively BLACKENING the art, not fading it into fanart.
        child: RepaintBoundary(
          child: _coverAndReflection(bytes, size,
            distance: distance, left: left),
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
    final reflectionHeight = size * (active ? .33
        : distance == 1 ? .30 : .22);
    Widget coverFace() => ClipRRect(
      borderRadius: borderRadius,
      child: bytes != null
          ? Image.memory(bytes, width: size, height: size,
              fit: BoxFit.cover,
              cacheWidth: active ? 1024 : distance == 1 ? 768
                  : distance == 2 ? 640 : 512,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true)
          : Image.asset('assets/vybe_album_placeholder.png',
              width: size, height: size, fit: BoxFit.cover),
    );

    return Stack(clipBehavior: Clip.none, children: [
      Positioned(left: 1, top: size + 3,
        width: size - 2, height: reflectionHeight,
        child: Opacity(
          opacity: active ? .88 : distance == 1 ? .69
              : distance == 2 ? .39 : .25,
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xF2FFFFFF), Color(0xAAFFFFFF),
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
            // No rectangular BoxDecoration border whatsoever. The selected
            // album's projected stroke belongs to the scene painter instead.
            // Side albums get only tiny contact glares and select segments.
            // Never cast a rectangular BoxShadow above the sleeve tops.
            // Gap shading is clipped to the projected rear-cover faces.
            boxShadow: const [],
          ),
          child: Stack(fit: StackFit.expand, children: [
            coverFace(),
            // One progressive BLACK lighting layer per sleeve. The older
            // two stacked black overlays compounded to almost full black,
            // hiding the actual artwork. This single clipped gradient always
            // leaves the artwork and its colors visible at every distance.
            // Black cast shadow is strongest along the INNER edge behind
            // the nearer cover, fading to a gentle overall depth shade.
            if (!active)
              Positioned.fill(child: ClipRRect(
                borderRadius: borderRadius,
                child: IgnorePointer(child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: left ? Alignment.centerRight : Alignment.centerLeft,
                      end: left ? Alignment.centerLeft : Alignment.centerRight,
                      stops: const [0, .13, .43, 1],
                      colors: distance == 1
                          ? const [
                              Color(0x89000000), // 54% max at overlap
                              Color(0x67000000),
                              Color(0x21000000),
                              Color(0x0A000000), // 4% on exposed edge
                            ]
                          : distance == 2
                              ? const [
                                  Color(0x9E000000), // 62% inner shadow
                                  Color(0x85000000),
                                  Color(0x4A000000),
                                  Color(0x2E000000), // 18% exposed
                                ]
                              : const [
                                  Color(0xAE000000), // 68% inner shadow
                                  Color(0x99000000),
                                  Color(0x69000000),
                                  Color(0x4D000000), // 30% exposed
                                ],
                    ),
                  ),
                )),
              )),
            // Light is painted at projected contact corners instead; do
            // not add a horizontal rectangle across the sleeve's top.
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

/// The reflective stage overlays fanart without a hard rectangular horizon.
/// A feathered gradient begins slightly ABOVE the covers' shared baseline,
/// peaks near their feet, then disappears by the bottom of the screen.
class _CoverflowAtmosphere extends CustomPainter {
  final ArtPalette p;
  final double contactFraction;
  final ui.Image? grain;
  const _CoverflowAtmosphere(this.p, this.contactFraction, {this.grain});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final contactY = h * contactFraction;

    // Soft stage surface starts ABOVE the sleeve feet: no bar-like
    // transition at the bottom edge of the covers.
    final topY = math.max(0.0, contactY - h * .155);
    final surface = Rect.fromLTWH(0, topY, w, h - topY);
    canvas.drawRect(surface, Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: [0, .13, .32, .55, .82, 1],
        colors: [
          Color(0x00000000),
          Color(0x19000000),
          Color(0x65000000),
          Color(0x92000000),
          Color(0x76000000),
          Color(0x38000000),
        ],
      ).createShader(surface));

    // The horizon and rear surface need the SAME photograph behind the
    // albums as the reflection finish uses below them. A projected,
    // low-opacity copy is composited here BEFORE any album is painted,
    // so the floor visibly recedes behind the standing sleeves.
    if (grain != null) {
      final source = grain!;
      final src = Rect.fromLTWH(
        0, 0, source.width.toDouble(), source.height.toDouble());
      final m = _CoverflowFloorGeometry.transform(size, src.size, topY);
      const restoredAlpha = ColorFilter.matrix([
        1.22, 0, 0, 0, -18,
        0, 1.22, 0, 0, -18,
        0, 0, 1.22, 0, -18,
        0, 0, 0, 0, 96,
      ]);
      canvas.save();
      canvas.clipRect(surface);
      canvas.saveLayer(surface, Paint()..blendMode = BlendMode.overlay);
      canvas.save();
      canvas.transform(m.storage);
      canvas.drawImageRect(source, src, src, Paint()
        ..colorFilter = restoredAlpha
        ..filterQuality = FilterQuality.medium);
      canvas.restore();
      canvas.drawRect(surface, Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0, .14, .34, .53, .80, 1],
          colors: [
            Color(0x00FFFFFF),
            Color(0x4AFFFFFF),
            Color(0xBEFFFFFF),
            Color(0xC9FFFFFF),
            Color(0xA6FFFFFF),
            Color(0x00FFFFFF),
          ],
        ).createShader(surface));
      canvas.restore();
      canvas.restore();
    }

    // Diffuse album-colored light is pooled near contact points. This
    // illuminates the grain but does not create a hard straight horizon.
    for (final pool in const <List<double>>[
      [.50, .38, .27],
      [.32, .23, .19],
      [.68, .23, .19],
    ]) {
      final rect = Rect.fromCenter(
        center: Offset(w * pool[0], contactY + h * .018),
        width: w * pool[1], height: h * .105);
      canvas.drawOval(rect, Paint()
        ..shader = RadialGradient(
          colors: [
            p.a.withOpacity(pool[2]),
            p.b.withOpacity(pool[2] * .22),
            Colors.transparent,
          ],
          stops: const [0, .32, 1],
        ).createShader(rect));
    }
  }

  @override
  bool shouldRepaint(covariant _CoverflowAtmosphere old) =>
      old.grain != grain || old.contactFraction != contactFraction ||
      old.p.a != p.a || old.p.b != p.b || old.p.c != p.c;
}

/// Blend grunge INTO the actual reflected floor, not onto album faces.
/// The previous version clipped everything at the feet and produced a
/// horizontal cut, while the low-alpha source was multiplied invisibly.
class _CoverflowFloorFinish extends CustomPainter {
  final ArtPalette p;
  final double contactFraction;
  final ui.Image? grain;
  const _CoverflowFloorFinish(this.p, this.contactFraction, this.grain);

  @override
  void paint(Canvas canvas, Size size) {
    final source = grain;
    if (source == null) return;
    final w = size.width, h = size.height;
    final baseline = h * contactFraction;

    // Begin the texture *behind* the cover feet with zero alpha,
    // then ease it into the reflection. The visual floor has no
    // sharp horizontal y-clip and no rectangle above/below the art.
    final topY = math.max(0.0, baseline - h * .125);
    final floor = Rect.fromLTRB(0, topY, w, h);
    final textureMask = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: [0, .15, .28, .39, .57, .77, 1],
      colors: [
        Color(0x00FFFFFF),
        Color(0x05FFFFFF),
        Color(0x24FFFFFF),
        Color(0xA9FFFFFF),
        Color(0xF1FFFFFF),
        Color(0xA6FFFFFF),
        Color(0x00FFFFFF),
      ],
    ).createShader(floor);

    final src = Rect.fromLTWH(
        0, 0, source.width.toDouble(), source.height.toDouble());
    final projection = _CoverflowFloorGeometry.transform(
        size, src.size, topY);

    // Old texture was pre-feathered to only ~55% max alpha and could
    // disappear entirely after repeated opacity masks. The color matrix
    // restores a uniform usable alpha and contrast in the actual photo.
    // The *screen-space mask above* is the only feather.
    const darkGrain = ColorFilter.matrix([
      1.27, 0, 0, 0, -26,
      0, 1.27, 0, 0, -26,
      0, 0, 1.27, 0, -26,
      0, 0, 0, 0, 142,
    ]);
    // White mineral marks catch light; black portions never create fog.
    const highlightGrain = ColorFilter.matrix([
      2.1, 0, 0, 0, -210,
      0, 2.1, 0, 0, -210,
      0, 0, 2.1, 0, -210,
      0, 0, 0, 0, 72,
    ]);

    void blendPass(BlendMode blend, ColorFilter filter) {
      canvas.save();
      canvas.clipRect(floor);
      canvas.saveLayer(floor, Paint()..blendMode = blend);
      canvas.save();
      canvas.transform(projection.storage);
      canvas.drawImageRect(source, src, src, Paint()
        ..colorFilter = filter
        ..filterQuality = FilterQuality.medium);
      canvas.restore();
      // Apply the feather while the blended image is still isolated.
      canvas.drawRect(floor, Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = textureMask);
      canvas.restore(); // composite with actual reflected artwork
      canvas.restore();
    }

    // Irregular charcoal pits darken reflections; paler scuffs lift only
    // illuminated areas. Both reuse the real user-supplied grunge image.
    blendPass(BlendMode.multiply, darkGrain);
    blendPass(BlendMode.screen, highlightGrain);
  }

  @override
  bool shouldRepaint(covariant _CoverflowFloorFinish old) =>
      old.grain != grain || old.contactFraction != contactFraction ||
      old.p.a != p.a || old.p.b != p.b;
}

/// Perspective warp shared by the textured upper floor and its finish.
/// The projected far edge is narrower than the near edge.
class _CoverflowFloorGeometry {
  static Matrix4 transform(Size size, Size src, double topY) {
    final w = size.width, h = size.height;
    final q = <Offset>[
      Offset(-w * .08, topY),
      Offset(w * 1.08, topY),
      Offset(w * 1.40, h * 1.16),
      Offset(-w * .40, h * 1.16),
    ];
    final tl = q[0], tr = q[1], br = q[2], bl = q[3];
    final dx1 = tr.dx - br.dx, dx2 = bl.dx - br.dx;
    final dx3 = tl.dx - tr.dx + br.dx - bl.dx;
    final dy1 = tr.dy - br.dy, dy2 = bl.dy - br.dy;
    final dy3 = tl.dy - tr.dy + br.dy - bl.dy;
    final det = dx1 * dy2 - dx2 * dy1;
    final g = det.abs() < .000001 ? 0.0
        : (dx3 * dy2 - dx2 * dy3) / det;
    final j = det.abs() < .000001 ? 0.0
        : (dx1 * dy3 - dx3 * dy1) / det;
    return Matrix4.identity()
      ..setEntry(0, 0, (tr.dx - tl.dx + g * tr.dx) / src.width)
      ..setEntry(0, 1, (bl.dx - tl.dx + j * bl.dx) / src.height)
      ..setEntry(0, 3, tl.dx)
      ..setEntry(1, 0, (tr.dy - tl.dy + g * tr.dy) / src.width)
      ..setEntry(1, 1, (bl.dy - tl.dy + j * bl.dy) / src.height)
      ..setEntry(1, 3, tl.dy)
      ..setEntry(3, 0, g / src.width)
      ..setEntry(3, 1, j / src.height);
  }
}

/// Screen-space black cast shadow from a front sleeve into the album
/// immediately behind it. The shadow is clipped to the rear cover's
/// four-corner plane and never continues above its top edge. No floating
/// rectangular shadows, no halo above the album stack.
class _CoverflowGapShadow extends CustomPainter {
  final List<Offset> front;
  final List<Offset> rear;
  final int side;
  final double unit;
  const _CoverflowGapShadow({
    required this.front, required this.rear,
    required this.side, required this.unit,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rearPath = Path()
      ..moveTo(rear[0].dx, rear[0].dy)
      ..lineTo(rear[1].dx, rear[1].dy)
      ..lineTo(rear[2].dx, rear[2].dy)
      ..lineTo(rear[3].dx, rear[3].dy)
      ..close();

    // Use a fully FEATHERED cast light occlusion, not a four-sided band:
    // that band's top and outer edges created the visible hard cutoff.
    // The rear album's projected silhouette is the *only* clip boundary.
    final edgeTop = side < 0 ? front[0] : front[1];
    final edgeBottom = side < 0 ? front[3] : front[2];
    final midX = (edgeTop.dx + edgeBottom.dx) * .5;
    final topY = math.min(rear[0].dy, rear[1].dy);
    final bottomY = math.max(rear[2].dy, rear[3].dy);
    final midY = (topY + bottomY) * .5;
    final falloff = Rect.fromCenter(
      center: Offset(midX + (side < 0 ? -.07 : .07) * unit, midY),
      width: unit * .72,
      height: math.max(1.0, (bottomY - topY) * 1.62),
    );

    canvas.save();
    canvas.clipPath(rearPath);
    canvas.drawOval(falloff, Paint()
      ..shader = const RadialGradient(
        stops: [0, .27, .63, 1],
        colors: [
          Color(0xBB000000),
          Color(0xA4000000),
          Color(0x51000000),
          Color(0x00000000),
        ],
      ).createShader(falloff));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CoverflowGapShadow old) =>
      old.unit != unit || old.side != side ||
      old.front[0] != front[0] || old.front[1] != front[1] ||
      old.front[2] != front[2] || old.front[3] != front[3] ||
      old.rear[0] != rear[0] || old.rear[1] != rear[1] ||
      old.rear[2] != rear[2] || old.rear[3] != rear[3];
}

/// Bright pin-point corner glints with tiny specular edges.
/// Unlike the previous implementation, there is NO blurred full-outline halo.
class _CoverflowCoverGlow extends CustomPainter {
  final List<Offset> quad;
  final Color accent;
  final double strength;
  final bool performanceMode;
  final bool selected;
  final int side;

  const _CoverflowCoverGlow({
    required this.quad, required this.accent, required this.strength,
    required this.performanceMode, required this.selected,
    required this.side,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // A localized radial reflection, never sharp light rays or hard lines.
    void contact(Offset point, double radius, double power) {
      final bounds = Rect.fromCircle(center: point, radius: radius);
      canvas.drawCircle(point, radius, Paint()
        ..shader = RadialGradient(
          stops: const [0, .13, .36, .75, 1],
          colors: [
            Color.lerp(accent, Colors.white, .55)!
                .withOpacity(.74 * power * strength),
            accent.withOpacity(.43 * power * strength),
            accent.withOpacity(.19 * power * strength),
            accent.withOpacity(.035 * power * strength),
            Colors.transparent,
          ],
        ).createShader(bounds));
    }

    if (selected) {
      // Rounded projected QUAD: preserve the angled-back perspective, but
      // replace the rectangular sharp-cornered path with curved transitions.
      // Thin album-palette stroke and only a small glow surrounding that
      // rounded contour, matching the sleeve's visible curved corners.
      final points = quad;
      final contour = Path();
      const round = .026;
      Offset entry(int i) =>
          Offset.lerp(points[i], points[(i + 3) % 4], round)!;
      Offset leave(int i) =>
          Offset.lerp(points[i], points[(i + 1) % 4], round)!;
      contour.moveTo(entry(0).dx, entry(0).dy);
      for (var i = 0; i < 4; i++) {
        contour.quadraticBezierTo(points[i].dx, points[i].dy,
            leave(i).dx, leave(i).dy);
        final next = (i + 1) % 4;
        contour.lineTo(entry(next).dx, entry(next).dy);
      }
      contour.close();
      canvas.drawPath(contour, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = performanceMode ? 2.4 : 3.2
        ..maskFilter = MaskFilter.blur(
            BlurStyle.normal, performanceMode ? 1.9 : 2.6)
        ..color = accent.withOpacity(.55 * strength));
      canvas.drawPath(contour, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round
        ..color = accent.withOpacity(.83 * strength));
      contact(quad[3], performanceMode ? 9 : 14, .65);
      contact(quad[2], performanceMode ? 9 : 14, .65);
      return;
    }

    // The outer side sleeves have NO stroke of any kind. Their lower
    // outside corner touches the stage: a soft, diffuse elliptical bloom.
    final foot = side < 0 ? quad[3] : quad[2];
    final insideFoot = side < 0 ? quad[2] : quad[3];
    contact(foot, performanceMode ? 13 : 23, .97);
    contact(insideFoot, performanceMode ? 7 : 11, .24);
  }

  @override
  bool shouldRepaint(covariant _CoverflowCoverGlow old) =>
      old.accent != accent || old.strength != strength ||
      old.performanceMode != performanceMode || old.selected != selected ||
      old.side != side ||
      old.quad[0] != quad[0] || old.quad[1] != quad[1] ||
      old.quad[2] != quad[2] || old.quad[3] != quad[3];
}
