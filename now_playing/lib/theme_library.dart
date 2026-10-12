import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'now_playing_model.dart';
import 'palette.dart';
import 'settings.dart';

/// Lightweight animated representations of the real theme layouts.
/// They share the live artwork, palette and FFT but intentionally do not
/// instantiate nine full-screen players or launch the Drive overlay.
class ThemeLibrary extends StatefulWidget {
  final NowPlayingModel model;
  final AppSettings settings;
  final ArtPalette palette;
  const ThemeLibrary({
    super.key, required this.model, required this.settings,
    required this.palette,
  });

  @override
  State<ThemeLibrary> createState() => _ThemeLibraryState();
}

class _ThemeLibraryState extends State<ThemeLibrary>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock;
  int? _preview;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(
      vsync: this, duration: const Duration(seconds: 12),
    )..repeat();
    widget.model.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.model.removeListener(_refresh);
    _clock.dispose();
    super.dispose();
  }

  void _apply(int id) {
    widget.settings.update(() => widget.settings.theme = id);
    Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    final portrait = MediaQuery.of(context).size.height >
        MediaQuery.of(context).size.width;
    final accent = widget.palette.a;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      backgroundColor: const Color(0xFF101019),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000, maxHeight: 850),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 8, 10),
            child: Row(children: [
              Icon(Icons.grid_view_rounded, color: accent),
              const SizedBox(width: 10),
              const Expanded(child: Text('THEME LIBRARY',
                style: TextStyle(fontSize: 19, letterSpacing: 2,
                    fontWeight: FontWeight.w600))),
              IconButton(icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context)),
            ]),
          ),
          Expanded(child: AnimatedBuilder(
            animation: _clock,
            builder: (context, _) {
              final ids = AppSettings.pickable;
              return GridView.builder(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: portrait ? 2 : 3,
                  mainAxisSpacing: 12, crossAxisSpacing: 12,
                  childAspectRatio: portrait ? 0.95 : 1.45,
                ),
                itemCount: ids.length,
                itemBuilder: (context, index) {
                  final id = ids[index];
                  final active = widget.settings.theme == id;
                  return InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() => _preview = id),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: active ? accent : Colors.white24,
                          width: active ? 2 : 1,
                        ),
                        color: const Color(0xFF1B1B29),
                      ),
                      child: Column(children: [
                        Expanded(child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(12)),
                          child: _ThemeMiniature(
                            id: id, model: widget.model,
                            palette: widget.palette,
                            phase: _clock.value,
                          ),
                        )),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          child: Row(children: [
                            Expanded(child: Text(
                              AppSettings.themeNames[id],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13))),
                            if (active) Icon(Icons.check_circle,
                                size: 17, color: accent)
                            else const Icon(Icons.open_in_full,
                                size: 14, color: Colors.white54),
                          ]),
                        ),
                      ]),
                    ),
                  );
                },
              );
            },
          )),
          if (_preview != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Colors.white24))),
              child: Row(children: [
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(AppSettings.themeNames[_preview!],
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600)),
                    const Text('Preview uses the current song',
                      style: TextStyle(fontSize: 11,
                          color: Colors.white60)),
                  ],
                )),
                TextButton(onPressed: () => setState(() => _preview = null),
                  child: const Text('Back')),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent, foregroundColor: Colors.black),
                  onPressed: () => _apply(_preview!),
                  child: const Text('Apply theme'),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _ThemeMiniature extends StatelessWidget {
  final int id;
  final NowPlayingModel model;
  final ArtPalette palette;
  final double phase;
  const _ThemeMiniature({
    required this.id, required this.model,
    required this.palette, required this.phase,
  });

  @override
  Widget build(BuildContext context) {
    final art = model.art;
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      final h = constraints.maxHeight;
      final artSize = math.min(w * .43, h * .77);
      final isRight = id == 3 || id == 8;
      final isCentered = id == 0 || id == 5 || id == 9;
      final left = isCentered ? (w - artSize) / 2
          : isRight ? w - artSize - 9 : 9.0;
      final top = (h - artSize) / 2;
      final showArt = id != 8;
      final title = model.title.isEmpty ? 'NOW PLAYING' : model.title;
      return Stack(fit: StackFit.expand, children: [
        CustomPaint(painter: _MiniFx(
          id: id, palette: palette, phase: phase,
          fft: model.fft,
          artCenter: Offset(left + artSize / 2, top + artSize / 2),
        )),
        if (id == 4)
          Positioned(right: 6, top: 8, bottom: 8, width: w * .53,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: const Color(0xFF35465D),
                border: Border.all(color: palette.a.withOpacity(.7)),
              ),
              child: CustomPaint(painter: _MiniMapPainter(palette.a)),
            )),
        if (showArt)
          Positioned(left: left, top: top, width: artSize,
            height: artSize,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                id == 0 || id == 9 ? artSize : 7),
              child: art == null
                  ? Container(color: palette.b.withOpacity(.35),
                      child: const Icon(Icons.music_note, color: Colors.white70))
                  : Image.memory(art.bytes, fit: BoxFit.cover,
                      gaplessPlayback: true),
            ),
          ),
        if (id == 7)
          Positioned(left: left + artSize * .25,
            top: top + artSize * .25,
            child: Icon(Icons.album, size: artSize * .5,
              color: Colors.black54)),
        if (id != 0 && id != 9 && id != 4)
          Positioned(
            left: isRight ? 7 : id == 8 ? 8 : w * .54,
            right: isRight ? w * .48 : 5,
            top: id == 8 ? h * .3 : h * .37,
            child: Column(
              crossAxisAlignment: isRight
                ? CrossAxisAlignment.start : CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white,
                    fontSize: (w * .065).clamp(10, 18),
                    fontWeight: FontWeight.w400)),
                const SizedBox(height: 4),
                Text(model.artist.isEmpty ? 'ARTIST' : model.artist,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white60,
                    fontSize: (w * .045).clamp(8, 11),
                    letterSpacing: 1)),
              ],
            ),
          ),
        if (id == 4)
          Positioned(left: 7, right: w * .57, bottom: 7,
            child: Text(title, maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 10))),
      ]);
    });
  }
}

class _MiniMapPainter extends CustomPainter {
  final Color accent;
  _MiniMapPainter(this.accent);
  @override
  void paint(Canvas canvas, Size size) {
    final road = Paint()..color = Colors.white24
      ..strokeWidth = 3..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(size.width * .2, size.height)
      ..lineTo(size.width * .5, size.height * .55)
      ..lineTo(size.width * .8, size.height * .15);
    canvas.drawPath(path, road);
    canvas.drawPath(path, Paint()..color = accent
      ..strokeWidth = 2..style = PaintingStyle.stroke);
    canvas.drawCircle(Offset(size.width * .5, size.height * .55),
      5, Paint()..color = Colors.white);
  }
  @override
  bool shouldRepaint(covariant _MiniMapPainter old) =>
      old.accent != accent;
}

class _MiniFx extends CustomPainter {
  final int id;
  final ArtPalette palette;
  final double phase;
  final List<int>? fft;
  final Offset artCenter;
  _MiniFx({required this.id, required this.palette,
    required this.phase, required this.fft, required this.artCenter});
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..shader = LinearGradient(
      colors: [palette.a.withOpacity(.33),
        const Color(0xFF10101C), palette.b.withOpacity(.32)],
      begin: Alignment.topLeft, end: Alignment.bottomRight,
    ).createShader(bounds));
    final center = id == 8
      ? Offset(size.width * .5, -size.height * .12)
      : artCenter;
    final rays = Paint()..color = palette.a.withOpacity(.11);
    for (var i = 0; i < 16; i++) {
      final a = i * math.pi / 8 + phase * .12;
      final p = Path()..moveTo(center.dx, center.dy)
        ..lineTo(center.dx + math.cos(a) * size.width * 1.7,
          center.dy + math.sin(a) * size.width * 1.7)
        ..lineTo(center.dx + math.cos(a + .11) * size.width * 1.7,
          center.dy + math.sin(a + .11) * size.width * 1.7)
        ..close();
      canvas.drawPath(p, rays);
    }
    if (id == 0 || id == 9 || id == 7) {
      final radius = math.min(size.width, size.height) * .35;
      for (var i = 0; i < 36; i++) {
        final a = i * math.pi / 18;
        final v = _level(i);
        final r1 = radius * .76;
        final r2 = r1 + 3 + v * 13;
        canvas.drawLine(
          center + Offset(math.cos(a) * r1, math.sin(a) * r1),
          center + Offset(math.cos(a) * r2, math.sin(a) * r2),
          Paint()..color = palette.a..strokeWidth = 2
            ..strokeCap = StrokeCap.round);
      }
      if (id == 9) {
        canvas.drawCircle(center, radius, Paint()
          ..color = palette.b.withOpacity(.5)
          ..style = PaintingStyle.stroke..strokeWidth = 1);
      }
    } else if (id == 6) {
      canvas.drawLine(Offset(size.width * .3, size.height),
        Offset(size.width * .75, 0),
        Paint()..color = palette.a..strokeWidth = 3);
    } else if (id == 8) {
      for (var i = 0; i < 30; i++) {
        final y = i * size.height / 30;
        final len = 3 + _level(i) * 14;
        final p = Paint()..color = palette.a..strokeWidth = 2;
        canvas.drawLine(Offset(0, y), Offset(len, y), p);
        canvas.drawLine(Offset(size.width, y),
          Offset(size.width - len, y), p);
      }
    } else {
      for (var i = 0; i < 28; i++) {
        final x = i * size.width / 28;
        final len = 2 + _level(i) * 13;
        canvas.drawLine(Offset(x, size.height),
          Offset(x, size.height - len),
          Paint()..color = palette.a..strokeWidth = 2);
      }
    }
  }
  double _level(int i) {
    if (fft != null && fft!.isNotEmpty) {
      return fft![i % fft!.length] / 255.0;
    }
    return .25 + .3 * (1 + math.sin(i * .8 + phase * math.pi * 24)) / 2;
  }
  @override
  bool shouldRepaint(covariant _MiniFx old) =>
      old.phase != phase || old.palette != palette ||
      old.fft != fft || old.id != id;
}
