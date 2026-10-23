import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'palette.dart';

/// Simulated spectrum. Looks like music, follows play/pause, but is not
/// tied to the actual audio signal.
class SpectrumSim {
  static const int bars = 96;

  final List<double> levels = List<double>.filled(bars, 0.03);
  final List<double> _phase;
  final List<double> _freq;
  double _t = 0;
  double _energy = 0;

  SpectrumSim()
      : _phase = _rand(bars, 6.283, 0, 11),
        _freq = _rand(bars, 5.0, 1.5, 23);

  static List<double> _rand(int n, double scale, double offset, int seed) {
    final r = math.Random(seed);
    return List<double>.generate(n, (_) => offset + r.nextDouble() * scale);
  }

  static double _envelope(double x) {
    final d = (x - 0.3) / 0.28;
    return 0.35 + 0.65 * math.exp(-d * d);
  }

  /// Average of the lowest bands, 0..1. Drives the beat pulse and effects.
  double get bass {
    var sum = 0.0;
    for (int i = 0; i < 8; i++) {
      sum += levels[i];
    }
    return sum / 8;
  }

  /// Level of band [i] with the sensitivity [gain] applied.
  double level(int i, double gain) {
    final v = 0.03 + (levels[i] - 0.03) * gain;
    return v.clamp(0.0, 1.0).toDouble();
  }

  /// [real]: optional frequency bands (0..255 each, [bars] long) from the
  /// device's audio output. When given, the bars follow it; otherwise the
  /// simulation runs.
  void update(double dt, bool playing, {Uint8List? real}) {
    _t += dt;

    if (real != null && real.length >= bars) {
      _energy = 1.0;
      for (int i = 0; i < bars; i++) {
        final v = math.pow(real[i] / 255.0, 0.9).toDouble();
        final target = 0.03 + 0.97 * v;
        final rate = target > levels[i] ? 24.0 : 10.0;
        levels[i] += (target - levels[i]) * math.min(1.0, dt * rate);
      }
      return;
    }

    _energy += ((playing ? 1.0 : 0.0) - _energy) * math.min(1.0, dt * 3.0);

    final beatPhase = (_t * 2.0) % 1.0; // ~120 bpm
    final beat =
        math.pow(math.max(0.0, 1.0 - beatPhase * 3.0), 2.0).toDouble();
    final swell = 0.5 + 0.5 * math.sin(_t * 0.45);

    for (int i = 0; i < bars; i++) {
      final x = i / (bars - 1);
      final env = _envelope(x);
      final wob = 0.5 + 0.5 * math.sin(_t * _freq[i] + _phase[i]);
      final bass = math.max(0.0, 1.0 - x * 3.0);

      var target = env * (0.22 + 0.5 * wob + 0.28 * swell * wob) +
          0.45 * beat * bass * env +
          0.15 * beat * (1 - bass) * wob * env;
      target = target.clamp(0.0, 1.0).toDouble();
      target = 0.03 + _energy * target * 0.97;

      final rate = target > levels[i] ? 16.0 : 6.0;
      levels[i] += (target - levels[i]) * math.min(1.0, dt * rate);
    }
  }
}

/// Circular ring of bars that wraps around the album art. Open at the
/// bottom so the title can sit underneath.
///
/// Cheaper than before: no glow pass (half the draw calls), and the angles
/// and colors are worked out once instead of every frame.

// Shared circular spectrum rendering: bars, continuous waveform, or dots.
void _paintCircularSpectrum(Canvas canvas, Offset center, List<Offset> roots,
    List<Offset> tips, List<Color> colors, double width, int style) {
  if (style == 1) {
    final path = Path();
    for (var i = 0; i < tips.length; i++) {
      if (i == 0) path.moveTo(tips[i].dx, tips[i].dy);
      else path.lineTo(tips[i].dx, tips[i].dy);
    }
    canvas.drawPath(path, Paint()
      ..color = colors[colors.length ~/ 2]
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);
  } else {
    for (var i = 0; i < tips.length; i++) {
      final paint = Paint()..color = colors[i]
        ..strokeWidth = width..strokeCap = StrokeCap.round;
      if (style == 2) {
        canvas.drawCircle(tips[i], math.max(1.5, width * 0.43), paint);
      } else {
        canvas.drawLine(roots[i], tips[i], paint);
      }
    }
  }
}
class RingPainter extends CustomPainter {
  final SpectrumSim sim;
  final ArtPalette palette;
  final double innerRadius;
  final double maxLen;
  final int count;
  final double gain;
  final int style;

  List<double>? _cos;
  List<double>? _sin;
  List<int>? _idx;
  List<Color>? _colors;

  RingPainter({
    required this.sim,
    required this.palette,
    required this.innerRadius,
    required this.maxLen,
    required this.count,
    required this.gain,
    this.style = 0,
    required Listenable repaint,
  }) : super(repaint: repaint);

  void _prepare() {
    if (_cos != null) return;
    const gap = 0.30;
    const start = math.pi / 2 + gap;
    const sweep = 2 * math.pi - 2 * gap;
    final cs = List<double>.filled(count, 0.0);
    final sn = List<double>.filled(count, 0.0);
    final ix = List<int>.filled(count, 0);
    final cl = List<Color>.filled(count, Colors.white);
    for (int i = 0; i < count; i++) {
      final f = count > 1 ? i / (count - 1) : 0.0;
      final ang = start + sweep * f;
      final u = (f - 0.5).abs() * 2; // 0 at top, 1 at the bottom ends
      cs[i] = math.cos(ang);
      sn[i] = math.sin(ang);
      ix[i] = (u * (SpectrumSim.bars - 1)).round();
      cl[i] = palette.at((1 + math.cos(ang)) / 2);
    }
    _cos = cs;
    _sin = sn;
    _idx = ix;
    _colors = cl;
  }

  @override
  void paint(Canvas canvas, Size size) {
    _prepare();
    final cs = _cos!, sn = _sin!, ix = _idx!, cl = _colors!;
    final c = size.center(Offset.zero);
    final width = innerRadius * 0.045 * math.sqrt(SpectrumSim.bars / count);

    final bar = Paint()
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;

    final roots = <Offset>[];
    final tips = <Offset>[];
    final colors = <Color>[];
    for (int i = 0; i < count; i++) {
      final len = width + maxLen * sim.level(ix[i], gain);
      bar.color = cl[i];
      roots.add(Offset(c.dx + cs[i] * innerRadius, c.dy + sn[i] * innerRadius));
      tips.add(Offset(c.dx + cs[i] * (innerRadius + len),
          c.dy + sn[i] * (innerRadius + len)));
      colors.add(bar.color);
    }
    _paintCircularSpectrum(canvas, c, roots, tips, colors, width, style);
  }

  @override
  bool shouldRepaint(RingPainter old) =>
      old.palette != palette ||
      old.innerRadius != innerRadius ||
      old.maxLen != maxLen ||
      old.count != count ||
      old.gain != gain || old.style != style;
}

/// Horizontal spectrum with a soft reflection underneath.
class BarsPainter extends CustomPainter {
  final SpectrumSim sim;
  final ArtPalette palette;
  final int count;
  final double gain;
  final int style;

  /// Wide square-ended bars (used by the VHS theme).
  final bool blocky;

  /// Where the baseline sits, as a fraction of the height (the rest is the
  /// reflection area).
  final double baseFrac;

  BarsPainter({
    required this.sim,
    required this.palette,
    required this.count,
    required this.gain,
    this.style = 0,
    this.blocky = false,
    this.baseFrac = 0.72,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final n = count;
    final barsH = size.height * baseFrac;
    final baseY = barsH;
    final step = size.width / n;
    final bw = step * (blocky ? 0.68 : 0.42);
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);

    final bar = Paint()
      ..strokeCap = blocky ? StrokeCap.butt : StrokeCap.round
      ..strokeWidth = bw
      ..shader = LinearGradient(colors: palette.colors).createShader(rect);
    final refl = Paint()
      ..strokeCap = StrokeCap.butt
      ..strokeWidth = bw
      ..shader = LinearGradient(
        colors: palette.colors.map((c) => c.withOpacity(0.2)).toList(),
      ).createShader(rect);

    final wave = Path();
    final reflection = Path();
    for (int i = 0; i < n; i++) {
      final idx = n > 1 ? (i * (SpectrumSim.bars - 1) / (n - 1)).round() : 0;
      final x = step * (i + 0.5);
      final f = n > 1 ? i / (n - 1) : 0.5;
      final t = (math.min(f, 1 - f) / 0.12).clamp(0.0, 1.0).toDouble();
      final opacity = t * t * (3 - 2 * t);
      bar.color = Colors.white.withOpacity(opacity);
      refl.color = Colors.white.withOpacity(opacity);
      final h = math.max(bw, sim.level(idx, gain) * barsH);
      if (style == 0) { canvas.drawLine(Offset(x, baseY), Offset(x, baseY - h), bar); }
      else if (style == 2) { canvas.drawCircle(Offset(x, baseY - h), math.max(1.5, bw * 0.35), Paint()..color = palette.at(f).withOpacity(opacity)); }
      else { if (i == 0) wave.moveTo(x, baseY-h); else wave.lineTo(x, baseY-h); }

      final rh = math.min(h * 0.4, size.height - baseY - 2);
      if (rh > 0) {
        if (style == 0) canvas.drawLine(Offset(x, baseY + 3), Offset(x, baseY + 3 + rh), refl);
        else if (style == 1) { if (i == 0) reflection.moveTo(x, baseY+3+rh); else reflection.lineTo(x, baseY+3+rh); }
      }
    }
    if (style == 1) {
      final gradient = LinearGradient(colors: [palette.a.withOpacity(0), palette.a, palette.b, palette.c, palette.c.withOpacity(0)], stops: const [0, .12, .5, .88, 1]).createShader(rect);
      canvas.drawPath(wave, Paint()..style=PaintingStyle.stroke..strokeWidth=math.max(2, bw*.65)..strokeCap=StrokeCap.round..strokeJoin=StrokeJoin.round..shader=gradient);
      canvas.drawPath(reflection, Paint()..style=PaintingStyle.stroke..strokeWidth=math.max(1, bw*.45)..shader=gradient..color=Colors.white.withOpacity(.2));
    }
  }

  @override
  bool shouldRepaint(BarsPainter old) =>
      old.palette != palette ||
      old.count != count ||
      old.gain != gain ||
      old.blocky != blocky ||
      old.baseFrac != baseFrac || old.style != style;
}

/// Vertical spectrum for the Edge to Edge theme: bars are stacked top to
/// bottom along the edge of the art and grow to the right. Bass is at the
/// bottom, treble at the top.
class VerticalBarsPainter extends CustomPainter {
  final SpectrumSim sim;
  final ArtPalette palette;
  final int count;
  final double gain;
  final int style;

  VerticalBarsPainter({
    required this.sim,
    required this.palette,
    required this.count,
    required this.gain,
    this.style = 0,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final n = count;
    final step = size.height / n;
    final th = step * 0.55;
    final maxLen = size.width * 0.92;
    final p = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = th;
    final wave = Path();
    for (int i = 0; i < n; i++) {
      final f = n > 1 ? i / (n - 1) : 0.0; // 0 = bottom
      final idx = (f * (SpectrumSim.bars - 1)).round();
      final len = math.max(th, sim.level(idx, gain) * maxLen);
      final y = size.height - step * (i + 0.5);
      final t = (math.min(f, 1 - f) / 0.12).clamp(0.0, 1.0).toDouble();
      p.color = palette.at(f).withOpacity(t * t * (3 - 2 * t));
      if (style == 0) canvas.drawLine(Offset(th / 2, y), Offset(th / 2 + len, y), p);
      else if (style == 2) canvas.drawCircle(Offset(th/2+len,y), math.max(1.5,th*.35), p..style=PaintingStyle.fill);
      else { if (i==0) wave.moveTo(th/2+len,y); else wave.lineTo(th/2+len,y); }
    }
    if (style == 1) canvas.drawPath(wave, Paint()..style=PaintingStyle.stroke..strokeWidth=math.max(2,th*.65)..strokeCap=StrokeCap.round..strokeJoin=StrokeJoin.round..shader=LinearGradient(begin:Alignment.bottomCenter,end:Alignment.topCenter,colors:[palette.a.withOpacity(0),palette.a,palette.b,palette.c.withOpacity(0)],stops:const [0,.12,.85,1]).createShader(Offset.zero & size));
  }

  @override
  bool shouldRepaint(VerticalBarsPainter old) =>
      old.palette != palette || old.count != count || old.gain != gain || old.style != style;
}

/// Bars hanging down from the top edge of their box. Used under the cover
/// in the narrow Edge to Edge layout, so the bars grow away from the art's
/// bottom edge. Bass is on the left.
class DownBarsPainter extends CustomPainter {
  final SpectrumSim sim;
  final ArtPalette palette;
  final int count;
  final double gain;
  final int style;

  DownBarsPainter({
    required this.sim,
    required this.palette,
    required this.count,
    required this.gain,
    this.style = 0,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final n = count;
    final step = size.width / n;
    final p = Paint()
      ..strokeCap = StrokeCap.butt
      ..strokeWidth = step * 0.62
      ..shader = LinearGradient(colors: palette.colors)
          .createShader(Offset.zero & size);
    final wave = Path();
    for (int i = 0; i < n; i++) {
      final idx = n > 1 ? (i * (SpectrumSim.bars - 1) / (n - 1)).round() : 0;
      final len = math.max(2.0, sim.level(idx, gain) * size.height);
      final x = step * (i + 0.5);
      final f = n > 1 ? i / (n - 1) : 0.5;
      final t = (math.min(f, 1 - f) / 0.12).clamp(0.0, 1.0).toDouble();
      p.color = Colors.white.withOpacity(t * t * (3 - 2 * t));
      if (style == 0) canvas.drawLine(Offset(x,0), Offset(x,len),p);
      else if (style == 2) canvas.drawCircle(Offset(x,len),math.max(1.5,step*.22),p..style=PaintingStyle.fill);
      else { if(i==0) wave.moveTo(x,len); else wave.lineTo(x,len); }
    }
    if (style == 1) canvas.drawPath(wave,Paint()..style=PaintingStyle.stroke..strokeWidth=math.max(2,step*.4)..strokeCap=StrokeCap.round..strokeJoin=StrokeJoin.round..shader=LinearGradient(colors:[palette.a.withOpacity(0),palette.a,palette.b,palette.c.withOpacity(0)],stops:const [0,.12,.85,1]).createShader(Offset.zero & size));
  }

  @override
  bool shouldRepaint(DownBarsPainter old) =>
      old.palette != palette || old.count != count || old.gain != gain || old.style != style;
}

/// A closed circle of bars growing outward from [innerRadius], used around
/// the record in the Record Cut theme. Bass is at the top, treble at the
/// bottom, mirrored left and right.
class FullRingPainter extends CustomPainter {
  final SpectrumSim sim;
  final ArtPalette palette;
  final double innerRadius;
  final double maxLen;
  final int count;
  final double gain;
  final int style;

  List<double>? _cos;
  List<double>? _sin;
  List<int>? _idx;
  List<Color>? _colors;

  FullRingPainter({
    required this.sim,
    required this.palette,
    required this.innerRadius,
    required this.maxLen,
    required this.count,
    required this.gain,
    this.style = 0,
    required Listenable repaint,
  }) : super(repaint: repaint);

  void _prepare() {
    if (_cos != null) return;
    final cs = List<double>.filled(count, 0.0);
    final sn = List<double>.filled(count, 0.0);
    final ix = List<int>.filled(count, 0);
    final cl = List<Color>.filled(count, Colors.white);
    for (int i = 0; i < count; i++) {
      final f = i / count;
      final ang = math.pi / 2 + 2 * math.pi * f;
      final u = (f - 0.5).abs() * 2; // 0 at the top, 1 at the bottom
      cs[i] = math.cos(ang);
      sn[i] = math.sin(ang);
      ix[i] = (u * (SpectrumSim.bars - 1)).round();
      cl[i] = palette.at((1 + math.cos(ang)) / 2);
    }
    _cos = cs;
    _sin = sn;
    _idx = ix;
    _colors = cl;
  }

  @override
  void paint(Canvas canvas, Size size) {
    _prepare();
    final cs = _cos!, sn = _sin!, ix = _idx!, cl = _colors!;
    final c = size.center(Offset.zero);
    final width =
        math.max(2.0, 2 * math.pi * innerRadius / count * 0.55).toDouble();
    final bar = Paint()
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    final roots = <Offset>[];
    final tips = <Offset>[];
    final colors = <Color>[];
    for (int i = 0; i < count; i++) {
      final len = width + maxLen * sim.level(ix[i], gain);
      bar.color = cl[i];
      roots.add(Offset(c.dx + cs[i] * innerRadius, c.dy + sn[i] * innerRadius));
      tips.add(Offset(c.dx + cs[i] * (innerRadius + len),
          c.dy + sn[i] * (innerRadius + len)));
      colors.add(bar.color);
    }
    _paintCircularSpectrum(canvas, c, roots, tips, colors, width, style);
  }

  @override
  bool shouldRepaint(FullRingPainter old) =>
      old.palette != palette ||
      old.innerRadius != innerRadius ||
      old.maxLen != maxLen ||
      old.count != count ||
      old.gain != gain || old.style != style;
}

/// Bars along the left half of a circle, growing outward (to the left).
/// Bass is at the middle of the arc, treble at the top and bottom ends.
class HalfRingPainter extends CustomPainter {
  final SpectrumSim sim;
  final ArtPalette palette;
  final double innerRadius;
  final double maxLen;
  final int count;
  final double gain;
  final int style;

  /// The direction the bars face, in radians (pi = left, pi / 2 = down), and
  /// how far the arc reaches to either side of that direction.
  final double centerAngle;
  final double span;

  HalfRingPainter({
    required this.sim,
    required this.palette,
    required this.innerRadius,
    required this.maxLen,
    required this.count,
    required this.gain,
    this.style = 0,
    required Listenable repaint,
    this.centerAngle = math.pi,
    this.span = math.pi / 2,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final n = count;
    final width =
        math.max(2.0, 2 * span * innerRadius / n * 0.55).toDouble();
    final bar = Paint()
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    final roots = <Offset>[];
    final tips = <Offset>[];
    final colors = <Color>[];
    for (int i = 0; i < n; i++) {
      final f = n > 1 ? i / (n - 1) : 0.5; // 0 = bottom end, 1 = top end
      final ang = centerAngle + (f - 0.5) * 2 * span;
      final u = (f - 0.5).abs() * 2; // 0 at the middle, 1 at the ends
      final idx = (u * (SpectrumSim.bars - 1)).round();
      final len = width + maxLen * sim.level(idx, gain);
      final cs = math.cos(ang), sn = math.sin(ang);
      bar.color = palette.at(1 - u);
      roots.add(Offset(c.dx + cs * innerRadius, c.dy + sn * innerRadius));
      tips.add(Offset(c.dx + cs * (innerRadius + len), c.dy + sn * (innerRadius + len)));
      colors.add(bar.color);
    }
    _paintCircularSpectrum(canvas, c, roots, tips, colors, width, style);
  }

  @override
  bool shouldRepaint(HalfRingPainter old) =>
      old.palette != palette ||
      old.innerRadius != innerRadius ||
      old.maxLen != maxLen ||
      old.count != count ||
      old.centerAngle != centerAngle ||
      old.span != span ||
      old.gain != gain || old.style != style;
}

/// Bars standing on a straight line from [a] to [b], growing off it in the
/// direction [normal] (a unit vector). Used by the Diagonal theme.
/// Bass is at [a]. With [mirror], bass is at both ends and treble in the
/// middle, so the middle can hide behind the cover.
class LineBarsPainter extends CustomPainter {
  final SpectrumSim sim;
  final ArtPalette palette;
  final Offset a;
  final Offset b;
  final Offset normal;
  final double maxLen;
  final int count;
  final double gain;
  final bool mirror;
  final int style;

  LineBarsPainter({
    required this.sim,
    required this.palette,
    required this.a,
    required this.b,
    required this.normal,
    required this.maxLen,
    required this.count,
    required this.gain,
    required this.mirror,
    this.style = 0,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final n = count;
    final d = b - a;
    final len = d.distance;
    final dir = d / len;
    final step = len / n;
    final width = math.max(2.0, step * 0.55).toDouble();
    final bar = Paint()
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    final wavePath = Path();
    for (int i = 0; i < n; i++) {
      final f = n > 1 ? i / (n - 1) : 0.0;
      final u = mirror ? (1 - (f - 0.5).abs() * 2) : f; // 0 = bass
      final idx = (u * (SpectrumSim.bars - 1)).round();
      final l = width + maxLen * sim.level(idx, gain);
      final root = a + dir * (step * (i + 0.5));
      final edge = math.min(1.0, math.min(f, 1 - f) / 0.12).clamp(0.0, 1.0).toDouble();
      final alpha = edge * edge * (3 - 2 * edge);
      bar.color = palette.at(1 - u).withOpacity(alpha);
      if (style == 0) {
        canvas.drawLine(root, root + normal * l, bar);
      } else if (style == 2) {
        final dot = Paint()..color = bar.color;
        canvas.drawCircle(root + normal * l, math.max(1.5, width * 0.4), dot);
      } else {
        final point = root + normal * l;
        if (i == 0) wavePath.moveTo(point.dx, point.dy);
        else wavePath.lineTo(point.dx, point.dy);
      }
    }
    if (style == 1) {
      final wave = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = math.max(2.0, width * 0.65)
        ..shader = LinearGradient(
          colors: [palette.a.withOpacity(0), palette.a, palette.b, palette.c, palette.c.withOpacity(0)],
          stops: const [0, 0.12, 0.5, 0.88, 1],
        ).createShader(Rect.fromPoints(a, b).inflate(maxLen));
      canvas.drawPath(wavePath, wave);
    }
  }

  @override
  bool shouldRepaint(LineBarsPainter old) =>
      old.palette != palette ||
      old.a != a ||
      old.b != b ||
      old.normal != normal ||
      old.maxLen != maxLen ||
      old.count != count ||
      old.gain != gain ||
      old.mirror != mirror ||
      old.style != style;
}
