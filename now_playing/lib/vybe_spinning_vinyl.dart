import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'theme_parts.dart';

/// The SAME disc construction used by VYBE's Record Cut/Muzine themes:
/// grayscale cover under black vinyl, exact groove and stationary-light
/// painters, coloured central cover label, centre hole and spinning face.
/// Only the animation driver is local to Music Video's independent widget.
class VybeSpinningVinyl extends StatefulWidget {
  final double diameter;
  final Uint8List? artwork;
  final bool playing;
  final bool animate;

  const VybeSpinningVinyl({
    super.key,
    required this.diameter,
    required this.artwork,
    required this.playing,
    this.animate = true,
  });

  @override
  State<VybeSpinningVinyl> createState() => _VybeSpinningVinylState();
}

class _VybeSpinningVinylState extends State<VybeSpinningVinyl>
    with SingleTickerProviderStateMixin {
  static const double _labelFrac = .40;
  static const _grayDark = ColorFilter.matrix(<double>[
    .117, .393, .040, 0, 0,
    .117, .393, .040, 0, 0,
    .117, .393, .040, 0, 0,
    0, 0, 0, 1, 0,
  ]);
  final ValueNotifier<double> _angle = ValueNotifier<double>(0.0);
  late final Ticker _ticker;
  Duration? _lastElapsed;
  double _turns = 0;
  double _speed = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_step);
    if (widget.animate && widget.playing) _startTicker();
  }

  @override
  void didUpdateWidget(covariant VybeSpinningVinyl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing ||
        oldWidget.animate != widget.animate) _startTicker();
  }

  void _startTicker() {
    if (!_ticker.isActive) {
      _lastElapsed = null;
      _ticker.start();
    }
  }

  // Identical to the existing Record Cut/Drive motion: 33 1/3 RPM,
  // 0.75 s spin-up, 1.5 s coast-down, and no reset of the platter angle.
  void _step(Duration elapsed) {
    final last = _lastElapsed;
    _lastElapsed = elapsed;
    if (last == null) return;
    final dt = ((elapsed - last).inMicroseconds / 1000000.0)
        .clamp(0.0, 0.07).toDouble();
    const full = 1 / 1.8;
    final target = widget.animate && widget.playing ? full : 0.0;
    if (_speed < target) {
      _speed = math.min(target, _speed + full / .75 * dt);
    } else if (_speed > target) {
      _speed = math.max(target, _speed - full / 1.5 * dt);
    }
    if (_speed > 0) {
      _turns = (_turns + _speed * dt) % 1.0;
      _angle.value = _turns;
    } else if (target == 0) {
      _ticker.stop(canceled: false);
      _lastElapsed = null;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _angle.dispose();
    super.dispose();
  }

  Widget _face(double d) {
    final art = widget.artwork;
    final lab = d * _labelFrac;
    final Widget surface = art == null
        ? const DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Color(0xFF23262E), Color(0xFF0B0C10)],
              ),
            ),
          )
        : ClipOval(
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                ColorFiltered(
                  colorFilter: _grayDark,
                  child: Image.memory(
                    art,
                    width: d,
                    height: d,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                Positioned.fill(
                  child: ColoredBox(color: Colors.black.withOpacity(.5)),
                ),
              ],
            ),
          );
    final ring = math.max(2.0, d * .007).toDouble();
    return SizedBox(
      width: d,
      height: d,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(child: surface),
          Positioned.fill(child: CustomPaint(
            painter: VinylGroovesPainter(labelFrac: _labelFrac),
          )),
          Container(
            width: lab, height: lab,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF111827),
              border: Border.all(color: Colors.white, width: ring),
            ),
            child: ClipOval(child: art == null
                ? Image.asset('assets/vybe_album_placeholder.png',
                    width: lab, height: lab, fit: BoxFit.cover)
                : Image.memory(art, width: lab, height: lab,
                    fit: BoxFit.cover, gaplessPlayback: true,
                    filterQuality: FilterQuality.medium)),
          ),
          Container(
            width: d * .055, height: d * .055,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF050608),
              border: Border.all(
                  color: Colors.white,
                  width: math.max(1.5, d * .005).toDouble()),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.diameter;
    final face = RepaintBoundary(child: _face(d));
    return SizedBox(
      width: d, height: d,
      child: Stack(children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(.6),
                  blurRadius: d * .07,
                  offset: Offset(0, d * .02),
                ),
              ],
            ),
          ),
        ),
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _angle,
            child: face,
            builder: (context, child) => Transform.rotate(
              angle: _angle.value * 2 * math.pi,
              child: child,
            ),
          ),
        ),
        const Positioned.fill(child: IgnorePointer(
          child: CustomPaint(painter: VinylLightPainter()),
        )),
      ]),
    );
  }
}
