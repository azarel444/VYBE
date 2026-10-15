import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'effects.dart';
import 'refraction_shader.dart';
import 'fx_adaptive.dart';
import 'fx_profile.dart';
import 'native.dart';
import 'now_playing_model.dart';
import 'orbit.dart';
import 'palette.dart';
import 'settings.dart';
import 'settings_screen.dart';
import 'spectrum.dart';
import 'theme_parts.dart';
import 'theme_library.dart';
import 'template_background.dart';
import 'club_background.dart';

class NowPlayingScreen extends StatefulWidget {
  /// True when this is the see-through Drive window that sits over the map.
  final bool driveHost;

  const NowPlayingScreen({super.key, this.driveHost = false});

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final model = NowPlayingModel();
  final settings = AppSettings();
  final sim = SpectrumSim();
  final particles = ParticleField();
  final glitch = GlitchState();
  final grid = GridState();
  final _rng = math.Random();

  final _tick = ValueNotifier<int>(0); // every drawn frame (30 fps)
  final _slow = ValueNotifier<int>(0); // about 10 times a second
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _time = 0;
  double _slowAcc = 0;

  double _nextGlitch = 5;
  double _glitchStart = -10;
  double _glitchDur = 0.35;
  double _glitchBaseY = 0.5;
  String _lastTrack = '';

  ui.Image? _noise;
  bool _night = false;
  Offset _shift = Offset.zero;
  double? _drag; // seek bar position while the finger is on it

  final fxClock = FxClock();
  final _fxGovernor = FxAdaptiveGovernor();
  final _fxProfiler = FxFrameProfiler();
  int _fxTier = 2;
  final ripples = RippleState();
  final _artKey = GlobalKey(); // lets rings and rays find the cover
  final _raysLayerKey = GlobalKey();
  final _ripplesLayerKey = GlobalKey();
  final _shockLayerKey = GlobalKey();
  // Record Cut: the spin is kept apart from the layout so only a cached
  // layer is turned each frame.
  final _recAngle = ValueNotifier<double>(0); // turns, 0..1
  double _recSpeed = 0; // turns per second
  double _recTurns = 0;
  static const double _labelFrac = 0.40; // label size / record size

  ArtPalette? _lastArtPalette;
  double _artNullSince = -1;

  // Drive: selecting the Drive theme starts it. These stop the first load
  // (and a reload after coming back) from counting as a selection.
  bool _themeReady = false;
  int _prevTheme = -1;
  bool _hostReady = false;

  // Drive: true while the map app is showing turn-by-turn directions. The
  // bottom visualizer shrinks to make room for them.
  bool _dirActive = false;
  Timer? _dirTimer;

  // A track change requires an intentional horizontal gesture with sufficient
  // distance; a quick vertical/diagonal movement must never skip music.
  double _horizontalSwipeDistance = 0;
  bool _showControls = false;
  Timer? _hideTimer;
  Timer? _clockTimer;

  /// The VHS look is an effect now: it can sit over any theme.
  bool get _vhsOn => settings.fxVhs;

  ArtPalette get _palette {
    final custom = settings.accentPalette;
    if (custom != null) return custom;
    if (_vhsOn && settings.vhsVaporwave) {
      return AppSettings.vaporwave;
    }
    final fromArt = model.art?.palette;
    if (fromArt != null) {
      _lastArtPalette = fromArt;
      _artNullSince = -1;
      return fromArt;
    }
    if (!model.active) return ArtPalette.fallback;
    // Between tracks the art is briefly missing. Keep the last colors for a
    // few seconds instead of flashing a different palette, then go neutral.
    if (_artNullSince < 0) _artNullSince = _time;
    if (_lastArtPalette != null && _time - _artNullSince < 4) {
      return _lastArtPalette!;
    }
    return ArtPalette.fallback;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fxGovernor.onTierChanged = (tier) {
      if (mounted) setState(() => _fxTier = tier);
    };
    _fxGovernor.start();
    FxProfileStore.load();
    _fxProfiler.signature = () {
      if (!mounted) return null;
      final size = MediaQuery.maybeSizeOf(context);
      if (size == null) return null;
      return FxProfileStore.signature(settings, size.width, size.height);
    };
    _fxProfiler.start();
    model.addListener(_onModel);
    settings.addListener(_onSettings);
    model.start();
    _ticker = createTicker(_onTick)..start();
    if (widget.driveHost) {
      _dirTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        final a = await Native.navActive();
        if (mounted && a != _dirActive) setState(() => _dirActive = a);
      });
    }
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(_updateClock);
    });
    makeNoiseImage().then((img) {
      if (mounted) setState(() => _noise = img);
    });
    _updateClock();
    settings.load().then((_) {
      if (!mounted) return;
      if (widget.driveHost) {
        // The Drive window always shows the Drive theme.
        settings.update(() => settings.theme = 4, persist: false);
        _hostReady = true;
      } else {
        _prevTheme = settings.theme;
        _themeReady = true;
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fxGovernor.stop();
    _fxProfiler.stop();
    model.removeListener(_onModel);
    settings.removeListener(_onSettings);
    _ticker.dispose();
    _hideTimer?.cancel();
    _clockTimer?.cancel();
    _dirTimer?.cancel();
    _noise?.dispose();
    _recAngle.dispose();
    model.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _fxGovernor.enabled = false;
    if (state == AppLifecycleState.resumed) {
      _fxGovernor.enabled = settings.autoFxQuality && settings.fxPerformanceMode != 2 && !settings.performance;
      model.refresh();
      // The Drive window may have changed the theme while VYBE was away.
      if (!widget.driveHost && _themeReady) settings.load();
    }
  }

  void _onModel() {
    if (!mounted) return;
    _checkTrack();
    setState(() {});
  }

  void _onSettings() {
    if (!mounted) return;
    if (model.visualizerEnabled != settings.visualizer) {
      model.setVisualizer(settings.visualizer);
    }
    _fxGovernor.enabled = settings.autoFxQuality && settings.fxPerformanceMode != 2 && !settings.performance;
    if (!_fxGovernor.enabled) _fxTier = 2;
    model.setArtLookup(settings.artLookup);
    if (model.lyricsEnabled != settings.lyrics) {
      model.setLyricsEnabled(settings.lyrics);
    }
    model.setLaunchSettings(
      boot: settings.bootStart,
      music: settings.musicStart,
      graceSec: settings.graceSec,
      allowVideo: settings.allowVideo,
      allowNav: settings.allowNavAudio,
      avoidNav: settings.avoidNav,
      navPkg: settings.navPkg,
    );
    _updateClock();
    if (widget.driveHost) {
      // Leaving Drive is coordinated by _pickTheme, after its awaited save.
      // Exiting here races SharedPreferences writes across Flutter engines.
    } else if (_themeReady) {
      if (settings.theme == 4 && _prevTheme != 4) _startDrive();
      _prevTheme = settings.theme;
    }
    setState(() {});
  }

  /// Night mode and the burn-in shift only need updating every so often.
  void _updateClock() {
    final now = DateTime.now();
    if (settings.night == 0) {
      _night = false;
    } else if (settings.night == 1) {
      _night = now.hour >= 20 || now.hour < 6;
    } else {
      _night = true;
    }
    if (settings.burnIn) {
      final t = now.millisecondsSinceEpoch / 60000.0;
      _shift = Offset(6 * math.sin(t * 0.7), 4 * math.sin(t * 0.5 + 1.0));
    } else {
      _shift = Offset.zero;
    }
  }

  void _checkTrack() {
    final key = model.active ? '${model.title}|${model.artist}' : '';
    if (key == _lastTrack) return;
    final hadTrack = _lastTrack.isNotEmpty;
    _lastTrack = key;
    if (hadTrack &&
        key.isNotEmpty &&
        _vhsOn &&
        !settings.performance) {
      _startGlitch(0.8, 4);
    }
  }

  void _startGlitch(double dur, int bands) {
    _glitchStart = _time;
    _glitchDur = dur;
    _glitchBaseY = _rng.nextDouble();
    glitch.bands = bands;
    glitch.seed = _rng.nextInt(100000);
  }

  void _stepGlitch() {
    if (!_vhsOn || settings.performance) {
      glitch.active = 0;
      return;
    }
    if (_time >= _nextGlitch) {
      _startGlitch(0.35, 1);
      _nextGlitch = _time + 4 + _rng.nextDouble() * 6;
    }
    final p = (_time - _glitchStart) / _glitchDur;
    if (p < 0 || p > 1) {
      glitch.active = 0;
    } else {
      glitch.active = math.sin(p * math.pi);
      glitch.y = (_glitchBaseY + p * 0.12) % 1.0;
    }
  }

  void _onTick(Duration elapsed) {
    var dt = (elapsed - _last).inMicroseconds / 1e6;
    if (dt < 0.029) return; // cap at about 30 fps to go easy on weak units
    _last = elapsed;
    dt = dt.clamp(0.0, 0.1).toDouble();
    _time += dt;

    sim.update(dt, model.playing, real: model.realActive ? model.fft : null);
    final bass = sim.bass;
    particles.t += dt * (0.25 + 1.2 * bass);
    grid.scroll += dt * (0.12 + 0.9 * bass);
    _stepGlitch();
    fxClock.t = _time;
    fxClock.bass = bass;
    ripples.update(_time, bass, settings.fxRipples && model.playing);

    // Record Cut and Drive: 33 1/3 rpm is one turn every 1.8 seconds. It speeds up
    // over about 0.75 s, slows over about 1.5 s, and keeps its angle.
    if (settings.theme == AppSettings.tRecord || settings.theme == 4) {
      const full = 1 / 1.8;
      final target = model.playing ? full : 0.0;
      if (_recSpeed < target) {
        _recSpeed = math.min(target, _recSpeed + full / 0.75 * dt);
      } else if (_recSpeed > target) {
        _recSpeed = math.max(target, _recSpeed - full / 1.5 * dt);
      }
      if (_recSpeed > 0) {
        _recTurns = (_recTurns + _recSpeed * dt) % 1.0;
        _recAngle.value = _recTurns;
      }
    }

    _slowAcc += dt;
    if (_slowAcc >= 0.1) {
      _slowAcc = 0;
      _slow.value++;
    }
    _tick.value++;
  }

  Future<void> _openPlayer() async {
    final r = await model.openPlayer();
    if (r == null || r == 'ok' || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(r), duration: const Duration(seconds: 3)),
    );
  }

  /// Visual theme library with lightweight live audio/artwork previews.
  Future<void> _pickTheme() async {
    final selected = await showDialog<int>(
      context: context,
      builder: (_) => ThemeLibrary(
        model: model,
        settings: settings,
        palette: _palette,
      ),
    );
    if (!mounted) return;
    if (widget.driveHost && selected != null && selected != 4) {
      await Native.exitDrive();
    }
    if (mounted) _poke();
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SettingsScreen(settings: settings, model: model),
    ));
  }

  void _poke() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _poke();
  }

  @override
  Widget build(BuildContext context) {
    final vhs = _vhsOn;
    final fx = vhs ? settings.vhsEffects : 0.0;
    final heavy = !settings.performance;

    Widget content(bool controlsInside) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        onHorizontalDragStart: (_) => _horizontalSwipeDistance = 0,
        onHorizontalDragUpdate: (d) =>
            _horizontalSwipeDistance += d.delta.dx,
        onHorizontalDragCancel: () => _horizontalSwipeDistance = 0,
        onHorizontalDragEnd: (d) {
          final distance = _horizontalSwipeDistance;
          _horizontalSwipeDistance = 0;
          // Flutter's horizontal drag recognizer rejects vertical gestures;
          // the extra distance threshold also rejects incidental diagonals.
          if (distance.abs() < 72) return;
          final velocity = d.primaryVelocity ?? 0;
          if (velocity.abs() < 180) return;
          if (distance < 0 && velocity < 0) model.next();
          if (distance > 0 && velocity > 0) model.previous();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            _background(),
            if (heavy) _shaderFxLayer(),
            if (heavy) ..._extraFx(),
            if (vhs) ..._vhsBackdrop(fx),
            if (settings.bgEffects && settings.particles && heavy)
              IgnorePointer(
                child: Transform.scale(
                  scale: settings.fxSize['Floating Particles'] ?? 1.0,
                  child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _FxBlendPainter(ParticlesPainter(
                        field: particles,
                        palette: _palette,
                        k: settings.kParticles,
                        repaint: _tick),
                        settings.fxBlendMode['Floating Particles'] ?? 0,
                        settings.fxBlendOpacity['Floating Particles'] ?? 1.0),
                  ),
                )),
              ),
            if (!model.accessGranted)
              _accessPrompt()
            else
              LayoutBuilder(builder: (context, box) {
                final w = box.maxWidth, h = box.maxHeight;
                // Side by Side and VHS switch to a stacked layout (art, bars,
                // then song info and lyrics) when the screen gets narrow.
                final narrow = w < h * 1.3;
                final Widget layout;
                if (settings.theme == AppSettings.tRecord) {
                  layout = _recordLayout(w, h, narrow);
                } else if (settings.theme == AppSettings.tFan) {
                  layout = _fanLayout(w, h, narrow);
                } else if (settings.theme == AppSettings.tDiagonal) {
                  layout = _diagonalLayout(w, h, narrow);
                } else if (settings.theme == AppSettings.tTypo) {
                  layout = _typoLayout(w, h, narrow);
                } else if (settings.theme == AppSettings.tOrbit) {
                  layout = _orbitLayout(w, h, narrow);
                } else if (settings.theme == 4) {
                  layout = _driveLayout(w, h, narrow);
                } else if (settings.theme == 3) {
                  layout = narrow ? _edgeNarrow(w, h) : _edgeLayout(w, h);
                } else if (settings.theme == 1) {
                  layout = narrow
                      ? _stackedLayout(w, h, vhs: false)
                      : _sideLayout(w, h, vhs: false);
                } else {
                  layout = _focused(w, h);
                }
                return Transform.translate(
                  offset: settings.theme >= 3 ? Offset.zero : _shift,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      layout,
                      if (settings.showClock && !widget.driveHost && settings.theme != 4) _themeClock(w, h, narrow),
                      if (vhs && settings.theme != 4) _osd(h, compact: narrow),
                    ],
                  ),
                );
              }),
            // These sit on top of everything, so they must not catch touches.
            if (vhs)
              IgnorePointer(
                child: Stack(
                  fit: StackFit.expand,
                  children: _vhsOverlay(fx, heavy),
                ),
              ),
            if (_night)
              const IgnorePointer(child: ColoredBox(color: Color(0x80000000))),
            _progressLine(),
            if (controlsInside && _showControls) _controls(),
          ],
        ),
      );

    if (!widget.driveHost) {
      return Scaffold(backgroundColor: Colors.black, body: content(true));
    }

    // Drive host: this window is see-through. Everything is drawn except a
    // rounded hole, so the map app underneath shows there.
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth, h = box.maxHeight;
        final hole = _driveHole(w, h, w < h * 1.3);
        final radius = h * 0.03;
        return Stack(
          fit: StackFit.expand,
          children: [
            ClipPath(
              clipper: _HoleClipper(hole, radius),
              child: content(false),
            ),
            IgnorePointer(
              child: CustomPaint(
                painter: _HoleBorderPainter(hole, radius, _palette.a),
              ),
            ),
            // A tap in the map window sends VYBE to the back so the map app
            // can be used. Taps anywhere else show or hide the controls.
            Positioned.fromRect(
              rect: hole,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _hideDrive,
              ),
            ),
            if (w >= h * 1.3) _driveBottomBars(w, h, hole),
            if (_showControls) _controls(),
          ],
        );
      }),
    );
  }

  // Auto accent is sampled from artwork and can be nearly black. Keep the
  // club lighting visibly luminous without changing other themes' palettes.
  ArtPalette get _clubPalette {
    final p = _palette;
    if (settings.accent != 0) return p;
    Color stageLight(Color color) {
      final hsv = HSVColor.fromColor(color);
      return hsv.withSaturation(hsv.saturation.clamp(0.55, 1.0))
          .withValue(hsv.value.clamp(0.78, 1.0)).toColor();
    }
    return ArtPalette(stageLight(p.a), stageLight(p.b), stageLight(p.c));
  }

  // ---------------------------------------------------------------- background

  Widget _background() {
    if (settings.backgroundSource == 2 || settings.backgroundSource == 3) {
      return Stack(fit: StackFit.expand, children: [
        if (settings.backgroundSource == 3) _albumBackdrop(),
        RepaintBoundary(child: AnimatedBuilder(
        animation: _slow,
        builder: (context, _) => CustomPaint(
          painter: ClubBackgroundPainter(
            palette: _clubPalette, time: _time,
            transparentStage: settings.backgroundSource == 3,
            motion: settings.performance ? 0 : settings.templateBackgroundMotion,
            darkness: settings.bgOverlay,
            lightingBlend: const [
              BlendMode.srcOver, BlendMode.plus, BlendMode.screen,
              BlendMode.lighten, BlendMode.overlay, BlendMode.softLight,
              BlendMode.difference, BlendMode.exclusion,
              BlendMode.colorDodge, BlendMode.hardLight,
            ][settings.clubBlendMode.clamp(0, 9)],
          ),
          child: const SizedBox.expand(),
        ),
      )),
      ]);
    }
    if (settings.backgroundSource == 1) {
      return RepaintBoundary(child: AnimatedBuilder(
        animation: _slow,
        builder: (context, _) => CustomPaint(
          painter: TemplateBackgroundPainter(
            palette: _palette,
            preset: settings.accent,
            time: _time,
            motion: settings.performance ? 0 : settings.templateBackgroundMotion,
            darkness: settings.bgOverlay,
          ),
          child: const SizedBox.expand(),
        ),
      ));
    }
    return _albumBackdrop();
  }

  Widget _albumBackdrop() {
    final art = model.art;
    final Widget child;
    // A flat placeholder picture (a logo on one color) counts as no cover.
    if (art == null || art.flat) {
      child = SizedBox.expand(
        key: const ValueKey('empty'),
        child: RepaintBoundary(
          child: CustomPaint(
            painter: IdleBackdropPainter(
              clock: fxClock,
              palette: _palette,
              animate: !settings.performance,
              repaint: _tick,
            ),
          ),
        ),
      );
    } else {
      Widget blurred = RepaintBoundary(
        child: ColorFiltered(
          colorFilter: _contrastFilter(settings.bgContrast),
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
                sigmaX: 6, sigmaY: 6, tileMode: TileMode.clamp),
            child: RawImage(
              image: art.tiny,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.high,
            ),
          ),
        ),
      );
      if (settings.bgEffects && !settings.performance) {
        blurred = _drift(blurred);
      }
      child = SizedBox.expand(
        key: ValueKey(art),
        child: Stack(
          fit: StackFit.expand,
          children: [
            blurred,
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color.fromARGB((140 * settings.bgOverlay).round().clamp(0, 255).toInt(), 0, 0, 0),
                    Color.fromARGB((89 * settings.bgOverlay).round().clamp(0, 255).toInt(), 0, 0, 0),
                    Color.fromARGB((179 * settings.bgOverlay).round().clamp(0, 255).toInt(), 0, 0, 0),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return AnimatedSwitcher(
        duration: const Duration(milliseconds: 800), child: child);
  }

  /// Slow pan and zoom. The blurred image is cached, so this only moves a
  /// finished layer around.
  Widget _drift(Widget child) {
    return AnimatedBuilder(
      animation: _tick,
      child: child,
      builder: (context, c) {
        final size = MediaQuery.of(context).size;
        final m = settings.kMotion;
        final dx = math.sin(_time * 0.08) * size.width * 0.065 * m;
        final dy = math.cos(_time * 0.06) * size.height * 0.055 * m;
        return Transform.translate(
          offset: Offset(dx, dy),
          child: Transform.scale(scale: 1.18, child: c),
        );
      },
    );
  }

  /// Each layout gets an independent clock anchor in portrait and landscape.
  /// Keep the clock over negative space, not album artwork or song information.
  String _clockLabel() {
    final now = DateTime.now();
    final hour = settings.clock24h ? now.hour : (now.hour % 12 == 0 ? 12 : now.hour % 12);
    return '${hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}${settings.clock24h ? '' : (now.hour < 12 ? ' AM' : ' PM')}';
  }

  Widget _themeClock(double w, double h, bool portrait) {
    final now = DateTime.now();
    final hour = settings.clock24h
        ? now.hour
        : (now.hour % 12 == 0 ? 12 : now.hour % 12);
    final value = '${hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}${settings.clock24h ? '' : (now.hour < 12 ? ' AM' : ' PM')}';

    // Portrait positions are art-directed per theme (October 2026 review).
    // Landscape clocks follow the music-information side, not the artwork.
    final theme = settings.theme;
    // Typo: lyrics use the upper center; album-art mode keeps the clock
    // upper-left, clear of the artwork. Other landscape themes retain sides.
    final typoLyricsCentered = !portrait &&
        theme == AppSettings.tTypo && _hasLyrics;
    final centered = portrait || typoLyricsCentered;
    bool onRight = true;
    double topInset = portrait ? h * 0.055 : 18.0;
    double? bottomInset;
    if (portrait) {
      switch (theme) {
        case 1: // Side by Side: centered along the bottom.
        case 3: // Edge to Edge: centered along the bottom.
          bottomInset = math.max(22.0, h * 0.022);
          break;
        case 4: // Drive: above the album, not over the map.
          topInset = math.max(h * 0.042, 48.0);
          break;
        case 5: // Fan: between the top spectrum and song information.
          topInset = h * 0.135;
          break;
        case 7: // Record Cut: above the lowered record.
          topInset = h * 0.025;
          break;
        case 8: // Typo: clock gets its own camera-safe header above the title.
          topInset = math.max(48.0, MediaQuery.of(context).viewPadding.top) + 14.0;
          break;
        case 9: // Orbit: directly above the artist/title group.
          topInset = h * 0.075;
          break;
        case 0: // Focused: above the ring/art assembly.
          topInset = h * 0.025;
          break;
        default: // Other portrait compositions: above song information.
          topInset = h * 0.08;
      }
    } else {
      // Mirrored Drive places its music panel on the opposite side.
      if (theme == 4) onRight = settings.driveSwap;
      // Fan and Record Cut landscape have the artwork on the left/right.
      if (theme == 7 || theme == AppSettings.tTypo) onRight = false;
      // Typo uses upper-center when lyrics actually display, upper-left
      // when the right pane contains artwork (including disabled lyrics).
    }
    // Android's status bar can be hidden in immersive mode while the physical
    // hole-punch camera remains. Reserve a minimum camera-safe band as well as
    // any real system inset supplied by the device.
    final cameraSafeTop = math.max(48.0, MediaQuery.of(context).viewPadding.top);
    if (portrait && bottomInset == null) {
      topInset = math.max(topInset, cameraSafeTop + 14.0);
    }
    if (typoLyricsCentered) topInset = 22.0;
    final inset = portrait ? 18.0 : 30.0;
    return Positioned(
      left: centered ? 0 : (onRight ? null : inset),
      right: centered ? 0 : (onRight ? inset : null),
      top: bottomInset == null ? topInset : null,
      bottom: bottomInset,
      child: IgnorePointer(
        child: Center(widthFactor: centered ? null : 1, heightFactor: 1,
          child: Text(value, style: TextStyle(
          color: Colors.white.withOpacity(0.93),
          fontSize: portrait ? 12 : 14,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.5,
          fontFeatures: const [ui.FontFeature.tabularFigures()],
          shadows: const [
            Shadow(color: Color(0xDD000000), blurRadius: 7, offset: Offset(0, 2)),
            Shadow(color: Color(0x99000000), blurRadius: 14, offset: Offset(0, 3)),
          ],
        )),
        ),
      ),
    );
  }

  // -------------------------------------------------------------- VHS layers

  /// GPU backdrop displacement occurs after blurred art, before visualizers,
  /// artwork and labels. On Skia the legacy canvas treatment remains available.
  Widget _shaderFxLayer() {
    int mode = -1;
    String name = '';
    for (final candidate in const <String>[
      'Liquid Refraction', 'Vortex Tunnel', 'Prism Shards',
      'Holographic Interference',
    ]) {
      if (settings.extraFx[candidate] ?? false) {
        name = candidate;
        mode = candidate == 'Liquid Refraction' ? 0
          : candidate == 'Vortex Tunnel' ? 1
          : candidate == 'Prism Shards' ? 2 : 3;
        break;
      }
    }
    if (mode < 0 || !ui.ImageFilter.isShaderFilterSupported) {
      return const SizedBox.shrink();
    }
    final tier = settings.fxPerformanceMode == 2 ? 2 : settings.fxPerformanceMode == 1 ? 0 : (settings.autoFxQuality ? _fxTier : 2);
    if (tier == 0) return const SizedBox.shrink();
    final intensity = (settings.extraStrength[name] ?? 0.8) *
      (tier == 1 ? 0.45 : 1.0);
    return IgnorePointer(child: AnimatedBuilder(
      animation: _tick,
      builder: (context, _) => RefractionShaderLayer(
        time: fxClock.t, bass: fxClock.bass,
        strength: intensity, mode: mode,
        blendMode: const [0, 1, 1, 2, 3, 4, 3, 1, 2, 5, 5, 6, 6, 7, 7, 7, 7, 0, 0, 0, 0, 0, 2, 0][(settings.fxBlendMode[name] ?? 0).clamp(0, 23)],
        blendOpacity: settings.fxBlendOpacity[name] ?? 1.0,
        child: const SizedBox.expand(),
      ),
    ));
  }

  /// The optional effects, each switched on or off in settings.
  List<Widget> _extraFx() {
    final p = _palette;
    Widget layer(String name, CustomPainter painter, {GlobalKey? layerKey}) {
      final blend = settings.fxBlendMode[name] ?? 0;
      final opacity = settings.fxBlendOpacity[name] ?? 1.0;
      final size = settings.fxSize[name] ?? 1.0;
      return IgnorePointer(child: Transform.scale(
        scale: 1.18 * size,
        child: RepaintBoundary(child: CustomPaint(
          key: layerKey,
          painter: _FxBlendPainter(painter, blend, opacity),
        )),
      ));
    }
    return [
      for (var i = 0; i < AppSettings.extraFxNames.length; i++)
        if ((settings.extraFx[AppSettings.extraFxNames[i]] ?? false) &&
            // Distortion-only FX are rendered by the GPU backdrop shader.
            // Never draw their old decorative strokes or polygon outlines.
            !(ui.ImageFilter.isShaderFilterSupported &&
              (i == 0 || i == 3 || i == 5 || i == 9)))
          layer(AppSettings.extraFxNames[i], ExpandedFxPainter(mode: i, clock: fxClock, palette: p,
            artKey: i == 1 ? _artKey : null,
            layerKey: i == 1 ? _shockLayerKey : null,
            k: settings.extraStrength[AppSettings.extraFxNames[i]] ?? 0.8, repaint: _tick),
            layerKey: i == 1 ? _shockLayerKey : null),
      if (settings.fxNebula)
        layer('Nebula Haze', AtmospherePainter(mode: 0, clock: fxClock, palette: p,
            k: settings.kNebula, repaint: _tick)),
      if (settings.fxGrid)
        layer('Perspective Grid', AtmospherePainter(mode: 1, clock: fxClock, palette: p,
            k: settings.kGrid, repaint: _tick)),
      if (settings.fxStars)
        layer('Twinkling Stars', AtmospherePainter(mode: 2, clock: fxClock, palette: p,
            k: settings.kStars, repaint: _tick)),
      if (settings.fxGlow)
        layer('Breathing Glow', GlowPainter(
            clock: fxClock, palette: p, k: settings.kGlow, repaint: _tick)),
      if (settings.fxSweep)
        layer('Aurora Sweep', SweepPainter(
            clock: fxClock, palette: p, k: settings.kSweep, repaint: _tick)),
      if (settings.fxRays)
        layer('Light Rays', RaysPainter(
            clock: fxClock,
            artKey: _artKey,
            layerKey: _raysLayerKey,
            palette: p,
            k: settings.kRays,
            topOrigin: settings.theme == AppSettings.tTypo,
            repaint: _tick), layerKey: _raysLayerKey),
      if (settings.fxRipples)
        layer('Beat Ripples', RipplesPainter(
            state: ripples,
            clock: fxClock,
            artKey: _artKey,
            layerKey: _ripplesLayerKey,
            palette: p,
            k: settings.kRipples,
            repaint: _tick), layerKey: _ripplesLayerKey),
      if (settings.fxWater)
        layer('Water Shimmer', WaterPainter(
            clock: fxClock, palette: p, k: settings.kWater, repaint: _tick)),
    ];
  }

  List<Widget> _vhsBackdrop(double fx) => [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.fromRGBO(120, 40, 200, 0.28 * fx),
                Color.fromRGBO(255, 46, 147, 0.16 * fx),
              ],
            ),
          ),
        ),
        RepaintBoundary(
          child: CustomPaint(
            painter: HorizonGlowPainter(
                clock: fxClock, palette: _palette, k: fx, repaint: _tick),
          ),
        ),
        RepaintBoundary(
          child: CustomPaint(
              painter: GridPainter(state: grid, k: fx, repaint: _tick)),
        ),
      ];

  List<Widget> _vhsOverlay(double fx, bool heavy) => [
        RepaintBoundary(
          child: CustomPaint(painter: ScanlinePainter(alpha: 0.16 * fx)),
        ),
        if (heavy && _noise != null)
          RepaintBoundary(
            child: CustomPaint(
              painter:
                  GrainPainter(noise: _noise, k: 0.9 * fx, tick: _slow),
            ),
          ),
        if (heavy)
          RepaintBoundary(
            child: CustomPaint(
              painter: GlitchPainter(g: glitch, k: fx, repaint: _tick),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              radius: 1.0,
              colors: [
                const Color(0x00000000),
                Color.fromRGBO(0, 0, 0, 0.6 * fx),
              ],
              stops: const [0.5, 1.0],
            ),
          ),
        ),
      ];

  /// Old-VCR on-screen display (top right): PLAY / PAUSE and a tape counter.
  Widget _osd(double h, {required bool compact}) {
    // On narrow (stacked) screens it is small and tucked into the corner.
    final size = compact
        ? (h * 0.02).clamp(11.0, 15.0).toDouble()
        : (h * 0.05).clamp(18.0, 40.0).toDouble();
    return Positioned(
      right: compact ? 14 : size,
      top: compact ? 10 : size * 0.8,
      child: AnimatedBuilder(
        animation: _slow,
        builder: (context, _) {
          final blinkOff = !model.playing && (_slow.value ~/ 5) % 2 == 1;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Opacity(
                opacity: blinkOff ? 0.0 : 1.0,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(model.playing ? Icons.play_arrow : Icons.pause,
                        size: size * 1.1, color: Colors.white),
                    SizedBox(width: size * 0.2),
                    _osdText(model.playing ? 'PLAY' : 'PAUSE', size),
                  ],
                ),
              ),
              SizedBox(height: size * 0.15),
              _osdText(_tape(model.positionMs), size * 0.8),
            ],
          );
        },
      ),
    );
  }

  Text _osdText(String s, double size) => Text(
        s,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: size,
          fontWeight: FontWeight.w700,
          letterSpacing: size * 0.12,
          color: Colors.white,
          shadows: const [
            Shadow(color: Color(0xCCFF2E93), offset: Offset(-2, 0)),
            Shadow(color: Color(0xCC05D9FF), offset: Offset(2, 0)),
          ],
        ),
      );

  String _tape(int ms) {
    final s = ms ~/ 1000;
    final m = ((s % 3600) ~/ 60).toString().padLeft(2, '0');
    final sec = (s % 60).toString().padLeft(2, '0');
    return '${s ~/ 3600}:$m:$sec';
  }

  // ------------------------------------------------------------------- themes

  /// Portrait layouts: the art sits near the top, and the song info and
  /// lyrics are centered in the space under it, so the lower part of the
  /// screen is used instead of being left empty.
  Widget _portraitStack(double h, Widget art, Widget info) {
    return Column(
      children: [
        SizedBox(height: h * 0.04),
        Center(child: FittedBox(fit: BoxFit.scaleDown, child: art)),
        Expanded(
          child: Center(
            child: FittedBox(fit: BoxFit.scaleDown, child: info),
          ),
        ),
        SizedBox(height: h * 0.05),
      ],
    );
  }

  /// Ring (or bars) with the art, then song info and the lyric line, all
  /// stacked as one group that is centered on the screen.
  Widget _focused(double w, double h) {
    final portrait = h > w * 1.1;
    final barsMode = settings.vizStyle == 1;
    final lyricSlot = settings.lyrics ? h * 0.05 : 0.0;
    final lyricGap = settings.lyrics ? _lyricGap(h) : 0.0;
    final textH = h * 0.115 + lyricSlot + lyricGap; // title + artist (+ lyrics)
    final wLimit = portrait ? (barsMode ? w * 0.8 : w * 0.54) : w * 0.4;

    final double art;
    if (barsMode) {
      final avail = h * 0.94 - textH - h * 0.12 - h * 0.05; // bars + gaps
      art = math.min(wLimit, avail / 1.28); // art + reflection
    } else {
      final avail = h * 0.94 - textH - h * 0.03;
      art = math.min(wLimit, avail / 1.72); // ring box is 1.72 x art
    }
    final outer = art * 0.86; // ring radius including the tallest bars

    final Widget top;
    if (barsMode) {
      top = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _artWithReflection(art),
          if (settings.visualizer) ...[
            SizedBox(height: h * 0.025),
            SizedBox(width: art, child: _bars(h * 0.12)),
          ],
          SizedBox(height: h * 0.025),
        ],
      );
    } else {
      top = SizedBox(
        width: outer * 2,
        height: outer * 2,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (settings.visualizer)
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: RingPainter(
                      sim: sim,
                      palette: _palette,
                      innerRadius: art * 0.66,
                      maxLen: art * 0.2,
                      count: settings.barCount,
                      gain: settings.sensitivity,
                      repaint: _tick,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: outer - art / 2,
              top: outer - art / 2,
              width: art,
              child: _artWithReflection(art),
            ),
          ],
        ),
      );
    }

    final text = SizedBox(
      width: w * 0.8,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _title(h * 0.062, Alignment.center, false),
          SizedBox(height: h * 0.012),
          _artist(h * 0.026, Alignment.center, false),
          if (settings.lyrics) SizedBox(height: lyricGap),
          if (settings.lyrics)
            SizedBox(
              height: lyricSlot,
              child: _hasLyrics
                  ? Center(child: _lyricLine(h * 0.03, Alignment.center))
                  : null,
            ),
        ],
      ),
    );

    if (portrait) return Padding(
      padding: EdgeInsets.only(top: h * 0.075),
      child: _portraitStack(h * 0.925, top, text),
    );

    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          width: w,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [top, SizedBox(height: h * 0.03), text],
          ),
        ),
      ),
    );
  }

  /// Art on the left, text and bars on the right (Side by Side and VHS).
  /// The art card is centered on the screen. The bottom of the bars lines up
  /// with the bottom of the art, and the bar reflection lines up with the
  /// art reflection. Song info and lyrics sit above the bars.
  Widget _sideLayout(double w, double h, {required bool vhs}) {
    final s = math.min(h * 0.62, w * 0.36);
    final u = s / 0.62; // text scale: equals h unless the screen is narrow
    final artTop = (h - s) / 2;
    final artBottom = artTop + s;
    final barsMax = s * 0.40; // tallest bar
    final reflH = s * 0.28; // same height as the art's reflection
    final barsBox = barsMax + reflH;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(width: w * 0.07),
        _artCentered(s, vhs: vhs),
        SizedBox(width: w * 0.05),
        Expanded(
          child: SizedBox(
            height: h,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: artTop,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _artist(u * 0.032, Alignment.centerLeft, vhs),
                      SizedBox(height: u * 0.012),
                      _title(u * 0.085, Alignment.centerLeft, vhs),
                      if (model.album.isNotEmpty &&
                          model.album != model.title) ...[
                        SizedBox(height: u * 0.012),
                        _shaded(_fit(_albumText(u * 0.028), Alignment.centerLeft)),
                      ],
                      if (_hasLyrics) ...[
                        SizedBox(height: _lyricGap(u)),
                        _lyricBlock(u, Alignment.centerLeft, vhs: vhs),
                      ],
                    ],
                  ),
                ),
                if (settings.visualizer)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: artBottom - barsMax,
                    height: barsBox,
                    child: _bars(barsBox,
                        blocky: vhs, baseFrac: barsMax / barsBox),
                  ),
              ],
            ),
          ),
        ),
        SizedBox(width: w * 0.05),
      ],
    );
  }

  /// A thin fading line used between the sections of the stacked layout.
  Widget _divider(double width, {required bool vhs}) {
    final c = vhs ? const Color(0xFFFF2E93) : _palette.a;
    return SizedBox(
      width: width,
      height: vhs ? 2.0 : 1.2,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: vhs
                ? [
                    Colors.transparent,
                    c.withOpacity(0.7),
                    const Color(0xB305D9FF),
                    Colors.transparent,
                  ]
                : [Colors.transparent, c.withOpacity(0.5), Colors.transparent],
          ),
        ),
      ),
    );
  }

  /// Narrow screens: the visualizer hangs down from the top edge of the
  /// screen, the album art sits under it, then the song info and the lyrics.
  /// The group is centered below the bars, and scales down if it would not
  /// fit.
  Widget _stackedLayout(double w, double h, {required bool vhs}) {
    final barsH = settings.visualizer ? h * 0.1 : 0.0;
    final s = math.min(w * 0.62, h * 0.34);
    final cw = w * 0.84;
    final gap = h * 0.018;
    final showAlbum =
        !vhs && model.album.isNotEmpty && model.album != model.title;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (settings.visualizer) _topBars(barsH),
        Positioned.fill(
          top: barsH,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: cw,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _artWithReflection(s, vhs: vhs),
                    SizedBox(height: gap * 2),
                    _title(h * 0.05, Alignment.center, vhs),
                    SizedBox(height: h * 0.01),
                    _artist(h * 0.022, Alignment.center, vhs),
                    if (showAlbum) ...[
                      SizedBox(height: h * 0.008),
                      _shaded(_fit(_albumText(h * 0.02), Alignment.center)),
                    ],
                    if (_hasLyrics) ...[
                      SizedBox(height: _lyricGap(h)),
                      _lyricBlock(h * 0.75, Alignment.center, vhs: vhs),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ drive

  /// Starts Drive: opens the map app, then puts VYBE's see-through Drive
  /// window in front of it so the map shows in the middle.
  Future<void> _startDrive() async {
    final r = await Native.startDriveScreen(pkg: settings.navPkg);
    if (!mounted) return;
    String? msg;
    if (r == 'permission') {
      msg = 'Allow "Display over other apps" for VYBE first (Settings > Permissions).';
      Native.openOverlaySettings();
    } else if (r == 'nopkg') {
      msg = 'Choose a navigation app in Settings > Navigation first.';
    } else if (r == 'none') {
      msg = 'The navigation app could not be opened.';
    }
    if (msg != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 5)),
      );
    }
  }

  /// Leaves the Drive window and goes back to normal VYBE.
  void _exitDrive() => Native.exitDrive();

  /// Hides the Drive window so the map app can be touched.
  void _hideDrive() => Native.hideDrive(bubble: settings.driveBubble);

  /// Where the map shows through in the Drive window.
  Rect _driveHole(double w, double h, bool narrow) {
    if (narrow) {
      return Rect.fromLTRB(w * 0.04, h * 0.445, w * 0.96, h - w * 0.04);
    }
    // The map window sits against the right side (the left with "swap"), so
    // the car and the route are centered in it.
    final cw = w * settings.driveCardWidth;
    final m = h * 0.04;
    return Rect.fromLTWH(settings.driveSwap ? m : w - m - cw, m, cw, h * 0.92);
  }

  /// The Drive theme. In the Drive window the map shows through the hole; in
  /// the normal VYBE window (after leaving Drive) the same screen is drawn
  /// with a framed box where the map would be, and tapping it starts Drive.
  Widget _driveLayout(double w, double h, bool narrow) {
    final swap = settings.driveSwap;
    final hole = _driveHole(w, h, narrow);
    final host = widget.driveHost;

    if (narrow) {
      // Clock belongs to the song-information group, not the artwork.
      // Moving the map boundary now moves the clock with the metadata.
      // One clock only, in the same responsive column as the artwork and
      // metadata. It stays above the art as the map opening changes height.
      final cameraTop = math.max(48.0, MediaQuery.of(context).viewPadding.top);
      final availableTop = h * 0.425;
      final topSpace = math.max(cameraTop + 12.0, h * 0.065);
      final reservedText = h * 0.065 + (settings.showClock ? 36.0 : 0.0);
      final artSide = math.max(48.0,
        math.min(math.min(w * 0.48, h * 0.225),
          availableTop - topSpace - reservedText)).toDouble();
      final top = SizedBox(
        height: availableTop,
        child: Column(children: [
          SizedBox(height: topSpace),
          if (settings.showClock) ...[
            Text(_clockLabel(), textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14,
                fontWeight: FontWeight.w500,
                shadows: [Shadow(color: Colors.black, blurRadius: 8)])),
            SizedBox(height: 10),
          ],
          _driveArtwork(artSide),
          SizedBox(height: h * 0.012),
          _title(h * 0.031, Alignment.center, false),
          SizedBox(height: h * 0.004),
          _artist(h * 0.017, Alignment.center, false),
        ]),
      );
      if (host) {
        return Column(children: [top, const Expanded(child: SizedBox())]);
      }
      return Column(
        children: [
          top,
          Expanded(
            child: Padding(
              padding: EdgeInsets.all(w * 0.04),
              child: _driveFrame(h),
            ),
          ),
        ],
      );
    }

    // Song info, then the record, then the lyrics, centered in the space
    // beside the map window.
    final m = h * 0.04;
    final panelW = math.max(1.0, w - hole.width - m * 2).toDouble();
    final infoW = panelW * 0.92;
    final d = math.min(infoW * 0.9, h * 0.42).toDouble();
    final reserve = settings.visualizer ? h * settings.driveBarsH * 0.75 : h * 0.03;
    final panel = Positioned(
      left: swap ? hole.right + m : 0,
      width: panelW,
      top: h * 0.02,
      bottom: reserve,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: infoW,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (settings.showClock) ...[
                  Text(_clockLabel(), textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 14,
                      fontWeight: FontWeight.w500,
                      shadows: [Shadow(color: Colors.black, blurRadius: 8)])),
                  SizedBox(height: h * 0.018),
                ],
                _title(h * 0.05, Alignment.center, false),
                SizedBox(height: h * 0.008),
                _artist(h * 0.026, Alignment.center, false),
                if (model.album.isNotEmpty && model.album != model.title) ...[
                  SizedBox(height: h * 0.008),
                  _shaded(_fit(_albumText(h * 0.02), Alignment.center)),
                ],
                SizedBox(height: h * 0.035),
                _driveArtwork(d),
                if (_hasLyrics) ...[
                  SizedBox(height: _lyricGap(h)),
                  _lyricBlock(h * 0.85, Alignment.center, vhs: false),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        panel,
        if (!host) ...[
          Positioned.fromRect(rect: hole, child: _driveFrame(h)),
          _driveBottomBars(w, h, hole),
        ],
      ],
    );
  }

  /// Drive art selection is shared by portrait and landscape.
  // Drive artwork is a direct music-player shortcut, independent of the
  // background control toggle. Avoid _front's pulse/bloom and crossfade layers.
  Widget _driveArtwork(double size) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _openPlayer,
      child: _driveArtworkVisual(size),
    );
  }

  Widget _driveArtworkVisual(double size) {
    if (!settings.driveAlbumCover) return SizedBox(
      width: size, height: size, child: _vinyl(size));

    // Keep Drive's cover independent of the shared AnimatedSwitcher.
    // Rebuilding the screen-wide controls after a background tap must not
    // restart an image crossfade or temporarily replace the album cover.
    final art = model.art;
    final radius = BorderRadius.circular(size * 0.07);
    return RepaintBoundary(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: radius,
          color: const Color(0xFF111827),
          border: Border.all(color: _palette.a.withOpacity(0.85), width: 1.5),
          boxShadow: [BoxShadow(
            color: _palette.a.withOpacity(0.28),
            blurRadius: size * 0.10,
          )],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: art == null || art.flat
              ? Center(child: _brandIcon(size * 0.48))
              : Image.memory(
                  art.bytes,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (context, error, stackTrace) =>
                      Center(child: _brandIcon(size * 0.48)),
                ),
        ),
      ),
    );
  }

  /// The visualizer along the bottom of the screen, in front of everything.
  /// With no directions showing it runs the whole width. While the map app
  /// shows turn-by-turn directions it shrinks to the space beside the map
  /// window, so it does not sit on top of them.
  Widget _driveBottomBars(double w, double h, Rect hole) {
    if (!settings.visualizer) return const SizedBox.shrink();
    final bh = h * settings.driveBarsH;
    var left = 0.0;
    var right = 0.0;
    if (_dirActive) {
      if (settings.driveSwap) {
        left = hole.right;
      } else {
        right = w - hole.left;
      }
    }
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeInOut,
      left: left,
      right: right,
      bottom: 0,
      height: bh,
      child: IgnorePointer(child: _bars(bh)),
    );
  }

  /// The framed box where the map shows in the Drive window. In normal VYBE
  /// it is a button that starts Drive.
  Widget _driveFrame(double h) {
    final p = _palette;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _startDrive,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(h * 0.03),
          border: Border.all(color: p.a.withOpacity(0.7), width: 1.5),
          color: const Color(0x33000000),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.navigation_rounded,
                  size: (h * 0.1).clamp(32.0, 84.0).toDouble(), color: p.a),
              SizedBox(height: h * 0.012),
              Text('Tap to start Drive',
                  style: TextStyle(
                      fontSize: (h * 0.03).clamp(14.0, 22.0).toDouble(),
                      color: Colors.white70)),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------- edge to edge

  /// The cover fills the whole area given, cropped to fit, no frame.
  Widget _edgeArt(double w, double h) {
    final art = model.art;
    return GestureDetector(
      key: _artKey,
      behavior: HitTestBehavior.opaque,
      onTap: _openPlayer,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 500),
        child: SizedBox(
          key: ValueKey<Object>(art ?? 'placeholder'),
          width: w,
          height: h,
          child: art == null
              ? Container(
                  color: const Color(0xFF111827),
                  child: Center(
                    child: _brandIcon(h * 0.3),
                  ),
                )
              : Image.memory(
                  art.bytes,
                  width: w,
                  height: h,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.high,
                ),
        ),
      ),
    );
  }

  /// Cover on the left half of the screen, edge to edge. A vertical
  /// visualizer runs along the cover's edge, and the song info and lyrics
  /// are right-aligned in the space to the right of it.
  Widget _edgeLayout(double w, double h) {
    return Row(
      children: [
        SizedBox(width: w * 0.5, height: h, child: _edgeArt(w * 0.5, h)),
        if (settings.visualizer)
          SizedBox(
            width: w * 0.09,
            height: h,
            child: _edgeBars(w * 0.09, leftEdge: true),
          ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(w * 0.02, h * 0.06, w * 0.04, h * 0.06),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _artist(h * 0.03, Alignment.centerRight, false),
                SizedBox(height: h * 0.012),
                _title(h * 0.08, Alignment.centerRight, false),
                if (model.album.isNotEmpty && model.album != model.title) ...[
                  SizedBox(height: h * 0.012),
                  _shaded(_fit(_albumText(h * 0.026), Alignment.centerRight)),
                ],
                if (_hasLyrics) ...[
                  SizedBox(height: _lyricGap(h)),
                  _lyricBlock(h, Alignment.centerRight, vhs: false),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Narrow screens: the cover takes the top half edge to edge, with the
  /// visualizer, song info and lyrics centered below it.
  Widget _edgeNarrow(double w, double h) {
    return Column(
      children: [
        SizedBox(width: w, height: h * 0.5, child: _edgeArt(w, h * 0.5)),
        // The bars hang straight down from the bottom edge of the cover.
        if (settings.visualizer)
          SizedBox(
            width: w,
            height: h * 0.08,
            child: _downShade(
              RepaintBoundary(
                child: CustomPaint(
                  painter: DownBarsPainter(
                    sim: sim,
                    palette: _palette,
                    count: settings.barCount,
                    gain: settings.sensitivity,
                    repaint: _tick,
                  ),
                ),
              ),
              h * 0.08,
            ),
          ),
        Expanded(
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: w * 0.84,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _title(h * 0.05, Alignment.center, false),
                    SizedBox(height: h * 0.01),
                    _artist(h * 0.022, Alignment.center, false),
                    if (_hasLyrics) ...[
                      SizedBox(height: _lyricGap(h)),
                      _lyricBlock(h * 0.75, Alignment.center, vhs: false),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ----------------------------------------------------- v1.6 themes

  /// Black and white, and dimmed: the big copy of the cover behind things.
  static const _grayDark = ColorFilter.matrix(<double>[
    0.117, 0.393, 0.040, 0, 0, //
    0.117, 0.393, 0.040, 0, 0, //
    0.117, 0.393, 0.040, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  /// Bars that hang down from the top edge of the screen, on a black shadow
  /// that is darkest at the edge and fades as it goes down.
  Widget _topBars(double barsH) => Positioned(
        left: 0,
        right: 0,
        top: 0,
        height: barsH,
        child: _downShade(
          RepaintBoundary(
            child: CustomPaint(
              painter: DownBarsPainter(
                sim: sim,
                palette: _palette,
                count: settings.barCount,
                gain: settings.sensitivity,
                repaint: _tick,
              ),
            ),
          ),
          barsH,
        ),
      );

  Widget _vBars() => RepaintBoundary(
        child: CustomPaint(
          painter: VerticalBarsPainter(
            sim: sim,
            palette: _palette,
            count: settings.barCount,
            gain: settings.sensitivity,
            repaint: _tick,
          ),
        ),
      );

  /// A strip of vertical bars on a black shadow that is darkest at the screen
  /// (or art) edge and fades out as it goes inward, so the bars pop.
  Widget _edgeBars(double edge, {required bool leftEdge}) {
    final shade = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: leftEdge ? Alignment.centerLeft : Alignment.centerRight,
          end: leftEdge ? Alignment.centerRight : Alignment.centerLeft,
          colors: const [Color(0xE6000000), Color(0x99000000), Color(0x00000000)],
          stops: const [0.0, 0.45, 1.0],
        ),
      ),
    );
    return SizedBox(
      width: edge,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: leftEdge ? 0 : null,
            right: leftEdge ? null : 0,
            top: 0,
            bottom: 0,
            width: edge * 1.9,
            child: IgnorePointer(child: shade),
          ),
          Positioned.fill(child: leftEdge ? _vBars() : _flipX(_vBars())),
        ],
      ),
    );
  }

  /// The same shadow for bars that hang down from a top edge.
  Widget _downShade(Widget bars, double h) => Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: h * 1.8,
            child: const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xE6000000), Color(0x99000000), Color(0x00000000)],
                    stops: [0.0, 0.45, 1.0],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(child: bars),
        ],
      );

  /// Mirrors a child left to right, so bars that grow from the left edge
  /// can grow from the right edge instead.
  Widget _flipX(Widget child) => Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1.0, 1.0, 1.0),
        child: child,
      );

  // ------------------------------------------------------------ record cut

  /// Recessed grayscale artwork, roughly 30% darker than before.
  /// The vinyl itself uses a separate filter and remains unchanged.
  static const _grayDisc = ColorFilter.matrix(<double>[
    0.119, 0.399, 0.042, 0, 0, //
    0.119, 0.399, 0.042, 0, 0, //
    0.119, 0.399, 0.042, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  /// The turning part: the cover in black and white as the record surface,
  /// grooves over it, and the cover in color as the label. Built once and
  /// handed to the rotation as a cached child.
  Widget _vinylFace(double d) {
    final art = model.art;
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
                    art.bytes,
                    width: d,
                    height: d,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                // Darker, so the record reads as black vinyl.
                Positioned.fill(
                  child: ColoredBox(color: Colors.black.withOpacity(0.5)),
                ),
              ],
            ),
          );
    final ring = math.max(2.0, d * 0.007).toDouble();
    return SizedBox(
      width: d,
      height: d,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(child: surface),
          Positioned.fill(
            child: CustomPaint(
              painter: VinylGroovesPainter(labelFrac: _labelFrac),
            ),
          ),
          Container(
            width: lab,
            height: lab,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF111827),
              border: Border.all(color: Colors.white, width: ring),
            ),
            child: ClipOval(
              child: art == null
                  ? Center(child: _brandIcon(lab * 0.7))
                  : Image.memory(
                      art.bytes,
                      width: lab,
                      height: lab,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.medium,
                    ),
            ),
          ),
          Container(
            width: d * 0.055,
            height: d * 0.055,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF050608),
              border: Border.all(color: Colors.white, width: math.max(1.5, d * 0.005).toDouble()),
            ),
          ),
        ],
      ),
    );
  }

  /// The record: a shadow, the turning face, and a light that stays still.
  Widget _vinyl(double d) {
    final face = RepaintBoundary(child: _vinylFace(d));
    return SizedBox(
      width: d,
      height: d,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.6),
                    blurRadius: d * 0.07,
                    offset: Offset(0, d * 0.02),
                  ),
                ],
              ),
            ),
          ),
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _recAngle,
              child: face,
              builder: (context, c) => Transform.rotate(
                angle: _recAngle.value * 2 * math.pi,
                child: c,
              ),
            ),
          ),
          const Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: VinylLightPainter()),
            ),
          ),
        ],
      ),
    );
  }

  // Record Cut geometry, all measured from the record's diameter d. The big
  // disc behind it is larger than the record and off-centre, so only a
  // half circle shows: its edge runs just outside the record, on the side
  // facing the song info, and fills the rest of that side of the screen.

  /// Radius of the big disc. [room] is the screen size across the disc.
  double _discR(double d, double room) => math.max(d * 1.04, room * 0.56);

  /// Space between the record's edge and the disc's edge.
  double _discGap(double d) => d * 0.157;

  /// The big disc: black rim, then blurred greyscale cover. Less blurred
  /// than the screen background so the picture still shows.
  Widget _recordDisc(double r, double d) {
    final art = model.art;
    final big = r * 2;
    final rim = math.max(4.0, d * 0.03).toDouble();
    final Widget inner = ClipOval(
      child: art == null
          ? const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [Color(0xFF2A2440), Color(0xFF0B0A18)],
                ),
              ),
            )
          : ColorFiltered(
              colorFilter: _grayDisc,
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                    sigmaX: r * 0.014, sigmaY: r * 0.014, tileMode: TileMode.clamp),
                child: Image.memory(
                  art.bytes,
                  width: big,
                  height: big,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.low,
                ),
              ),
            ),
    );
    return RepaintBoundary(
      child: Container(
        width: big,
        height: big,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black,
          border: Border.all(color: Colors.black, width: rim),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.75), blurRadius: d * 0.1),
          ],
        ),
        child: inner,
      ),
    );
  }

  /// A black glow just outside the disc's edge, so the bars stand out.
  Widget _discShade(double r, double fade) {
    final total = (r + fade) * 2;
    return IgnorePointer(
      child: Container(
        width: total,
        height: total,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: const [Color(0xCC000000), Color(0xCC000000), Color(0x00000000)],
            stops: [0.0, r / (r + fade), 1.0],
          ),
        ),
      ),
    );
  }

  /// The disc, its glow and the bars along its edge, centered on (cx, cy).
  /// The bars face [angle] (pi is left, pi / 2 is down) over [room], the
  /// screen length across the disc, which decides how much of the arc shows.
  List<Widget> _discStack(double cx, double cy, double r, double d,
      double room, double angle) {
    final maxLen = d * 0.16;
    final fade = maxLen * 1.8;
    final half = room / 2;
    final span = half >= r
        ? math.pi / 2
        : math.min(math.pi / 2, math.asin(half / r) + 0.05).toDouble();
    final reach = r + maxLen + 4;
    return [
      if (settings.visualizer)
        Positioned(
          left: cx - r - fade,
          top: cy - r - fade,
          width: (r + fade) * 2,
          height: (r + fade) * 2,
          child: _discShade(r, fade),
        ),
      Positioned(
        left: cx - r,
        top: cy - r,
        width: r * 2,
        height: r * 2,
        child: _recordDisc(r, d),
      ),
      // A localized recessed shadow cast inward from the exposed curved
      // boundary near the vinyl. Never shade the disc's entire perimeter.
      Positioned(
        left: cx - r,
        top: cy - r,
        width: r * 2,
        height: r * 2,
        child: IgnorePointer(
          child: CustomPaint(
            painter: _RecordCurveShadowPainter(
              centerAngle: angle,
              span: span,
              depth: d * 0.15,
            ),
          ),
        ),
      ),
      if (settings.visualizer)
        Positioned(
          left: cx - reach,
          top: cy - reach,
          width: reach * 2,
          height: reach * 2,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: HalfRingPainter(
                sim: sim,
                palette: _palette,
                innerRadius: r + 2,
                maxLen: maxLen,
                count: math.max(24, settings.barCount ~/ 2),
                gain: settings.sensitivity,
                repaint: _tick,
                centerAngle: angle,
                span: span,
              ),
            ),
          ),
        ),
    ];
  }

  Widget _recordLayout(double w, double h, bool narrow) {
    if (narrow) {
      // Portrait: position the vinyl independently from the grayscale outer
      // disc. The outer disc's LOWER circular edge crosses the vinyl at its
      // vertical midpoint, behind the vinyl, rather than moving with it.
      final d = math.min(w * 0.62, h * 0.30).toDouble();
      final r = _discR(d, w);
      final cameraSafeTop = math.max(48.0, MediaQuery.of(context).viewPadding.top);
      final vinylTop = math.max(cameraSafeTop + 88.0, h * 0.095);
      final rcy = vinylTop + d / 2;
      final cy = rcy - r;
      final maxLen = d * 0.16;
      // Metadata must remain below the actual record, not the disc boundary.
      final metadataTop = vinylTop + d + h * 0.065;
      return Stack(
        children: [
          ..._discStack(w / 2, cy, r, d, w, math.pi / 2),
          Positioned(
            left: w / 2 - d / 2,
            top: rcy - d / 2,
            width: d,
            height: d,
            child: GestureDetector(
              key: _artKey,
              behavior: HitTestBehavior.opaque,
              onTap: _openPlayer,
              child: _vinyl(d),
            ),
          ),
          Positioned(
            left: w * 0.06,
            right: w * 0.06,
            top: metadataTop,
            bottom: h * 0.02,
            child: Align(
              alignment: Alignment.center,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: w * 0.88,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _title(h * 0.05, Alignment.center, false),
                      SizedBox(height: h * 0.01),
                      _artist(h * 0.022, Alignment.center, false),
                      if (_hasLyrics) ...[
                        SizedBox(height: _lyricGap(h)),
                        _lyricBlock(h * 0.75, Alignment.center, vhs: false),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    // Landscape: the record sits to the right, the disc's left edge runs
    // just outside it and the bars come off that curve.
    final d = math.min(h * 0.72, w * 0.36).toDouble();
    final r = _discR(d, h);
    final rcx = w - d * 0.64;
    final cx = rcx - d / 2 - _discGap(d) + r;
    final cy = h / 2;
    final maxLen = d * 0.16;
    return Stack(
      children: [
        ..._discStack(cx, cy, r, d, h, math.pi),
        Positioned(
          left: rcx - d / 2,
          top: cy - d / 2,
          width: d,
          height: d,
          child: GestureDetector(
            key: _artKey,
            behavior: HitTestBehavior.opaque,
            onTap: _openPlayer,
            child: _vinyl(d),
          ),
        ),
        Positioned(
          left: w * 0.06,
          width: math.max(w * 0.2, cx - r - maxLen - w * 0.08),
          top: 0,
          bottom: 0,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _artist(h * 0.032, Alignment.centerLeft, false),
              SizedBox(height: h * 0.012),
              _title(h * 0.085, Alignment.centerLeft, false),
              if (model.album.isNotEmpty && model.album != model.title) ...[
                SizedBox(height: h * 0.012),
                _shaded(_fit(_albumText(h * 0.028), Alignment.centerLeft)),
              ],
              if (_hasLyrics) ...[
                SizedBox(height: _lyricGap(h)),
                _lyricBlock(h, Alignment.centerLeft, vhs: false),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------- fan

  /// Three covers fanned out, the sharp one in front. The box is laid out so
  /// the front cover's top-left corner is at (0, 0.25 s).
  Widget _fanCards(double s) {
    final yf = s * 0.25;
    // sigma 0 = sharp. Each cover further back is blurred more.
    Widget back(double left, double top, double deg, double alpha, double sigma) {
      Widget card = ColorFiltered(
        colorFilter: const ColorFilter.mode(Color(0x26000000), BlendMode.srcATop),
        child: _artContent(s),
      );
      card = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
            sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.decal),
        child: card,
      );
      return Positioned(
        left: left,
        top: top,
        child: Transform.rotate(
          angle: deg * math.pi / 180,
          alignment: Alignment.topLeft,
          child: Opacity(
            opacity: alpha,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Drop shadow under the cover, for depth.
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(s * 0.07),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.7),
                          blurRadius: s * 0.1,
                          offset: Offset(s * 0.02, s * 0.03),
                        ),
                      ],
                    ),
                  ),
                ),
                card,
              ],
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: s * 1.45,
      height: s * 1.3,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          back(s * 0.5, yf - s * 0.246, 21, 0.90, s * 0.008),
          back(s * 0.237, yf - s * 0.175, 11, 0.97, s * 0.003),
          Positioned(
            left: 0,
            top: yf,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(s * 0.07),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.75),
                          blurRadius: s * 0.12,
                          offset: Offset(s * 0.015, s * 0.035),
                        ),
                      ],
                    ),
                  ),
                ),
                _front(s, false),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fanLayout(double w, double h, bool narrow) {
    if (narrow) {
      // Portrait: the visualizer hangs from the top edge, then the song
      // info, the fanned covers and the lyrics.
      final s = math.min(w * 0.62, h * 0.30).toDouble();
      final barsH = settings.visualizer ? h * 0.1 : 0.0;
      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: _bottomArtworkFade()),
          if (settings.visualizer) _topBars(barsH),
          Positioned.fill(
            top: barsH,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: w * 0.9,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _title(h * 0.05, Alignment.center, false),
                      SizedBox(height: h * 0.01),
                      _artist(h * 0.022, Alignment.center, false),
                      if (model.album.isNotEmpty &&
                          model.album != model.title) ...[
                        SizedBox(height: h * 0.008),
                        _shaded(_fit(_albumText(h * 0.02), Alignment.center)),
                      ],
                      SizedBox(height: h * 0.035),
                      _fanCards(s),
                      if (_hasLyrics) ...[
                        SizedBox(height: _lyricGap(h)),
                        _lyricBlock(h * 0.75, Alignment.center, vhs: false),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    // As big as the height allows, so the stack fills the screen top to
    // bottom; the song info moves right to make room if it has to.
    final s = math.min(h * 0.72, w * 0.40).toDouble();
    final edge = w * 0.105;
    // Match the bottom breathing room on the lead cover at the left edge.
    final fanLeftInset = h * 0.04;
    final textLeft = math.max(w * 0.58, fanLeftInset + s * 1.45 + w * 0.03).toDouble();
    return Stack(
      children: [
        Positioned.fill(child: _bottomArtworkFade()),
        Positioned(left: fanLeftInset, top: (h - s * 1.25) / 2, child: _fanCards(s)),
        if (settings.visualizer)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: edge,
            child: _edgeBars(edge, leftEdge: false),
          ),
        Positioned(
          left: textLeft,
          right: edge + w * 0.03,
          top: 0,
          bottom: 0,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _artist(h * 0.032, Alignment.centerLeft, false),
              SizedBox(height: h * 0.012),
              _title(h * 0.085, Alignment.centerLeft, false),
              if (model.album.isNotEmpty && model.album != model.title) ...[
                SizedBox(height: h * 0.012),
                _shaded(_fit(_albumText(h * 0.028), Alignment.centerLeft)),
              ],
              if (_hasLyrics) ...[
                SizedBox(height: _lyricGap(h)),
                _lyricBlock(h, Alignment.centerLeft, vhs: false),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------- diagonal

  /// A black and white copy of the cover fills one side of a diagonal cut
  /// with a glowing white edge. The sharp cover floats on it, and the song
  /// info sits on the blurred side. The visualizer's bars grow off the white
  /// line, on the blurred side, and sit behind the cover.
  Widget _diagonalLayout(double w, double h, bool narrow) {
    final List<Offset> poly;
    final List<Offset> other; // the blurred side of the line
    final Offset a;
    final Offset b;
    if (narrow) {
      a = Offset(0, h * 0.55);
      b = Offset(w, h * 0.30);
      poly = [Offset.zero, Offset(w, 0), b, a];
      other = [a, b, Offset(w, h), Offset(0, h)];
    } else {
      a = Offset(w * 0.703, 0);
      b = Offset(0, h);
      poly = [Offset.zero, a, b];
      other = [a, Offset(w, 0), Offset(w, h), b];
    }
    final art = model.art;
    final gray = ClipPath(
      clipper: PolyClipper(poly),
      child: art == null
          ? const ColoredBox(color: Color(0xFF14161B))
          : SizedBox.expand(
              child: ColorFiltered(
                colorFilter: _grayDark,
                child: Image.memory(
                  art.bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
    );
    final line = IgnorePointer(
      child: CustomPaint(painter: CutLinePainter(a: a, b: b)),
    );

    // Unit vector along the line, and the one pointing off it to the blurred
    // side (down and right in landscape, straight down in portrait).
    final dist = (b - a).distance;
    final dir = (b - a) / dist;
    final normal = narrow ? Offset(-dir.dy, dir.dx) : Offset(dir.dy, -dir.dx);
    final barMax = narrow ? h * 0.07 : h * 0.13;

    // The shadow and the bars, clipped to the blurred side so nothing leaks
    // over the grey part.
    final bars = settings.visualizer
        ? ClipPath(
            clipper: PolyClipper(other),
            child: Stack(
              fit: StackFit.expand,
              children: [
                IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: CutShadePainter(
                          a: a, b: b, normal: normal, reach: barMax * 1.9),
                    ),
                  ),
                ),
                IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: LineBarsPainter(
                        sim: sim,
                        palette: _palette,
                        a: a,
                        b: b,
                        normal: normal,
                        maxLen: barMax,
                        count: settings.barCount,
                        gain: settings.sensitivity,
                        mirror: narrow,
                        repaint: _tick,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          )
        : const SizedBox.shrink();

    if (narrow) {
      // The cover is big and sits on the line, centered between the grey
      // area above and the area below. The song info fills the lower part.
      final s = math.min(w * 0.76, h * 0.36).toDouble();
      final mid = (a + b) / 2;
      return Stack(
        fit: StackFit.expand,
        children: [
          gray,
          Positioned.fill(child: _bottomArtworkFade()),
          bars,
          line,
          Positioned(
              left: mid.dx - s / 2, top: mid.dy - s / 2, child: _front(s, false)),
          Positioned(
            left: w * 0.08,
            right: w * 0.08,
            top: h * 0.64,
            bottom: h * 0.03,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: w * 0.84,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _title(h * 0.05, Alignment.center, false),
                      SizedBox(height: h * 0.01),
                      _artist(h * 0.022, Alignment.center, false),
                      if (_hasLyrics) ...[
                        SizedBox(height: _lyricGap(h)),
                        _lyricBlock(h * 0.75, Alignment.center, vhs: false),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final s = math.min(w * 0.37, h * 0.8).toDouble();
    // The info starts to the right of the tallest bars, so they never touch.
    final infoTop = h * 0.36;
    final root = math.max(0.0, infoTop - normal.dy * barMax).toDouble();
    final lineX = a.dx + (b.dx - a.dx) * (root - a.dy) / (b.dy - a.dy);
    final infoLeft = math.max(w * 0.47,
            lineX + (settings.visualizer ? normal.dx * barMax : 0.0) + w * 0.035)
        .toDouble();
    return Stack(
      fit: StackFit.expand,
      children: [
        gray,
        Positioned.fill(child: _bottomArtworkFade()),
        bars,
        line,
        Positioned(left: w * 0.046, top: (h - s) / 2, child: _front(s, false)),
        Positioned(
          left: infoLeft,
          right: w * 0.05,
          top: infoTop,
          bottom: h * 0.07,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _artist(h * 0.032, Alignment.centerLeft, false),
              SizedBox(height: h * 0.012),
              _title(h * 0.085, Alignment.centerLeft, false),
              if (model.album.isNotEmpty && model.album != model.title) ...[
                SizedBox(height: h * 0.012),
                _shaded(_fit(_albumText(h * 0.028), Alignment.centerLeft)),
              ],
              if (_hasLyrics) ...[
                SizedBox(height: _lyricGap(h)),
                _lyricBlock(h, Alignment.centerLeft, vhs: false),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ----------------------------------------------------------------- orbit

  /// The round cover with a glowing white ring around it.
  Widget _orbitArt(double d) {
    final art = model.art;
    final p = _palette;
    final bw = math.max(2.0, d * 0.006).toDouble();
    final inner = d - 2 * bw;
    return RepaintBoundary(
      child: Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withOpacity(0.6), width: bw),
          boxShadow: [
            BoxShadow(
                color: p.a.withOpacity(0.55),
                blurRadius: d * 0.06,
                spreadRadius: d * 0.004),
            BoxShadow(
                color: p.a.withOpacity(0.25),
                blurRadius: d * 0.18,
                spreadRadius: d * 0.02),
          ],
        ),
        child: ClipOval(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: art == null
                ? Container(
                    key: const ValueKey<Object>('placeholder'),
                    width: inner,
                    height: inner,
                    color: const Color(0xFF111827),
                    child: Center(child: _brandIcon(inner * 0.55)),
                  )
                : Image.memory(
                    art.bytes,
                    key: ValueKey<Object>(art),
                    width: inner,
                    height: inner,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.high,
                  ),
          ),
        ),
      ),
    );
  }

  /// The cover again, big and lightly blurred, fading out toward the circle.
  /// It fills the whole screen and only fades through a soft gradient, so it
  /// has no edge of its own anywhere.
  Widget _orbitGhost(double w, double h, bool narrow) {
    final art = model.art;
    if (art == null || art.flat) return const SizedBox.shrink();
    final Widget picture = ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => LinearGradient(
        begin: narrow ? Alignment.topCenter : Alignment.centerLeft,
        end: narrow ? Alignment.bottomCenter : Alignment.centerRight,
        colors: const [
          Color(0x00FFFFFF),
          Color(0x00FFFFFF),
          Color(0xFFFFFFFF),
          Color(0xFFFFFFFF),
        ],
        stops: narrow
            ? const [0.0, 0.45, 0.85, 1.0]
            : const [0.0, 0.38, 0.74, 1.0],
      ).createShader(rect),
      child: Opacity(
        opacity: narrow ? 0.35 : 0.42,
        child: ImageFiltered(
          imageFilter:
              ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4, tileMode: TileMode.clamp),
          child: Image.memory(
            art.bytes,
            width: w,
            height: h,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
          ),
        ),
      ),
    );
    return Positioned.fill(
      child: IgnorePointer(child: RepaintBoundary(child: picture)),
    );
  }

  /// A thin progress line, as long as [width].
  Widget _miniProgress(double width) {
    return SizedBox(
      width: width,
      height: 3,
      child: AnimatedBuilder(
        animation: _tick,
        builder: (context, _) {
          final d = model.durationMs;
          final f = d > 0 ? (model.positionMs / d).clamp(0.0, 1.0).toDouble() : 0.0;
          return Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: Color(0x40FFFFFF))),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: width * f,
                child: ColoredBox(color: _palette.a),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Round cover with a circular visualizer, orbit rings with glowing orbs
  /// and light rays around it. Landscape: the song info, a small progress
  /// line and the lyrics sit to the right. Portrait: the whole circle group
  /// is centered, with the song info above it, the lyrics under it and the
  /// progress line below the lyrics.
  Widget _orbitLayout(double w, double h, bool narrow) {
    final p = _palette;
    final double artR;
    final Offset c;
    if (narrow) {
      artR = math.min(w * 0.27, h * 0.15).toDouble();
      c = Offset(w / 2, h / 2);
    } else {
      artR = math.min(h * 0.29, w * 0.17).toDouble();
      c = Offset(w * 0.275, h / 2);
    }
    final barsInner = artR * 1.08;
    final barsMax = artR * 0.40;
    final reach = barsInner + barsMax + 6;
    final shadeFade = artR * 0.75;
    final glowA = Color.lerp(p.a, Colors.white, 0.55)!;
    final glowB = Color.lerp(p.b, Colors.white, 0.5)!;
    final glowC = Color.lerp(p.c, Colors.white, 0.5)!;

    final layers = <Widget>[
      // Confine the atmospheric fade to the artwork side of landscape Orbit.
      // It ends before the text panel and does not darken the whole backdrop.
      if (!narrow)
        Positioned(
          left: 0, top: 0, bottom: 0,
          width: math.min(w * 0.57, c.dx + artR * 1.94),
          child: IgnorePointer(child: DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(
              begin: Alignment.centerLeft, end: Alignment.centerRight,
              colors: const [Color(0x99000000), Color(0x66000000), Color(0x00000000)],
              stops: const [0.0, 0.48, 1.0],
            )),
          )),
        ),
      if (settings.backgroundSource == 0 || settings.backgroundSource == 3) _orbitGhost(w, h, narrow),
      // Light Rays are an optional FX-library effect, not an intrinsic
      // Orbit theme layer. The shared _extraFx() pipeline draws them only
      // when settings.fxRays is enabled. Orbit keeps its signature rings.

      // A soft black glow behind the bars so they stand out.
      if (settings.visualizer)
        Positioned(
          left: c.dx - artR - shadeFade,
          top: c.dy - artR - shadeFade,
          width: (artR + shadeFade) * 2,
          height: (artR + shadeFade) * 2,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: const [
                    Color(0x99000000),
                    Color(0x99000000),
                    Color(0x00000000),
                  ],
                  stops: [0.0, artR / (artR + shadeFade), 1.0],
                ),
              ),
            ),
          ),
        ),
      IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: OrbitRingsPainter(
              clock: fxClock,
              palette: p,
              center: c,
              artR: artR,
              lite: settings.performance,
              streaks: !narrow,
              repaint: _tick,
            ),
          ),
        ),
      ),
      // The thin orbit rings glow, with a light that runs round each one.
      _glowRing(c, artR * 1.46, artR * 0.016, glowA,
          turnsPerSec: 0.05, base: 0.22, arc: 0.9),
      _glowRing(c, artR * 1.62, artR * 0.013, glowB,
          turnsPerSec: -0.038, base: 0.14, arc: 0.8),
      _glowRing(c, artR * 1.9, artR * 0.01, glowC,
          turnsPerSec: 0.026, base: 0.0, arc: 0.55),
      if (settings.visualizer)
        Positioned(
          left: c.dx - reach,
          top: c.dy - reach,
          width: reach * 2,
          height: reach * 2,
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: FullRingPainter(
                  sim: sim,
                  palette: p,
                  innerRadius: barsInner,
                  maxLen: barsMax,
                  count: settings.barCount,
                  gain: settings.sensitivity,
                  repaint: _tick,
                ),
              ),
            ),
          ),
        ),
      // The ring around the cover: a soft glow with a bright arc traveling
      // round it.
      _glowRing(c, artR * 1.012, artR * 0.03, Color.lerp(p.a, Colors.white, 0.7)!,
          turnsPerSec: 0.12, base: 0.5, arc: 1.0),
      Positioned(
        left: c.dx - artR,
        top: c.dy - artR,
        width: artR * 2,
        height: artR * 2,
        child: GestureDetector(
          key: _artKey,
          behavior: HitTestBehavior.opaque,
          onTap: _openPlayer,
          child: _pulse(_orbitArt(artR * 2)),
        ),
      ),
    ];

    if (narrow) {
      final ringEdge = artR * 1.72;
      layers.add(
        Positioned(
          left: w * 0.06,
          right: w * 0.06,
          top: h * 0.03,
          height: math.max(1.0, c.dy - ringEdge - h * 0.03).toDouble(),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: w * 0.88,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _artist(h * 0.022, Alignment.center, false),
                    SizedBox(height: h * 0.01),
                    _title(h * 0.05, Alignment.center, false),
                    if (model.album.isNotEmpty && model.album != model.title) ...[
                      SizedBox(height: h * 0.008),
                      _shaded(_fit(_albumText(h * 0.02), Alignment.center)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      layers.add(
        Positioned(
          left: w * 0.06,
          right: w * 0.06,
          top: c.dy + ringEdge,
          bottom: h * 0.03,
          child: Align(
            alignment: Alignment.topCenter,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: w * 0.88,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_hasLyrics) ...[
                      _lyricBlock(h * 0.75, Alignment.center, vhs: false),
                      SizedBox(height: h * 0.02),
                    ],
                    // Orbit deliberately has no playback progress bar.
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    } else {
      layers.add(
        Positioned(
          left: math.min(w * 0.77, c.dx + artR * 1.90 + w * 0.035),
          right: w * 0.05,
          top: 0,
          bottom: 0,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _artist(h * 0.024, Alignment.centerLeft, false),
              SizedBox(height: h * 0.014),
              _title(h * 0.06, Alignment.centerLeft, false),
              if (model.album.isNotEmpty && model.album != model.title) ...[
                SizedBox(height: h * 0.014),
                _shaded(_fit(_albumText(h * 0.022), Alignment.centerLeft)),
              ],
              SizedBox(height: h * 0.035),
              if (_hasLyrics) ...[
                SizedBox(height: _lyricGap(h) * 1.2),
                _lyricBlock(h, Alignment.centerLeft, vhs: false),
              ],
            ],
          ),
        ),
      );
    }
    return Stack(fit: StackFit.expand, children: layers);
  }

  // ------------------------------------------------------------------ typo

  Widget _typoInfo(double h, {required bool center}) => _shaded(_typoInfoRaw(h, center: center));

  Widget _typoInfoRaw(double h, {required bool center}) {
    final ta = center ? TextAlign.center : TextAlign.right;
    final cross = center ? CrossAxisAlignment.center : CrossAxisAlignment.end;
    final artistSize = center ? h * 0.022 : h * 0.034;
    final albumSize = center ? h * 0.018 : h * 0.026;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: cross,
      children: [
        Text(
          _titleStr,
          textAlign: ta,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: center ? h * 0.06 : h * 0.115,
            fontWeight: FontWeight.w300,
            height: 1.05,
            color: _readableText(1),
            shadows: _cleanTextShadows,
          ),
        ),
        SizedBox(height: h * 0.025),
        Text(
          _artistStr.toUpperCase(),
          textAlign: ta,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: artistSize,
            letterSpacing: artistSize * 0.3,
            color: _readableText(.82),
            shadows: _cleanTextShadows,
          ),
        ),
        if (model.album.isNotEmpty && model.album != model.title) ...[
          SizedBox(height: h * 0.012),
          Text(
            model.album.toUpperCase(),
            textAlign: ta,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: albumSize,
              letterSpacing: albumSize * 0.3,
              color: _readableText(.66),
              shadows: _cleanTextShadows,
            ),
          ),
        ],
      ],
    );
  }

  /// Lyrics set large: the line before, the current line, the line after.
  Widget _typoLyrics(double h, {required bool center}) =>
      _shaded(_typoLyricsRaw(h, center: center));

  Widget _typoLyricsRaw(double h, {required bool center}) {
    final ta = center ? TextAlign.center : TextAlign.left;
    final cross = center ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    if (!_hasLyrics) {
      return Text(
        settings.lyrics
            ? '♪'
            : 'Lyrics are off.\nTurn them on in Settings.',
        textAlign: ta,
        style: TextStyle(
          fontSize: center ? h * 0.026 : h * 0.036,
          color: Colors.white38,
          height: 1.3,
        ),
      );
    }
    final big = center ? h * 0.04 : h * 0.07;
    return AnimatedBuilder(
      animation: _slow,
      builder: (context, _) {
        final i = model.lyricIndexAt(model.positionMs + 150);
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          layoutBuilder: (current, previous) => Stack(
            alignment: center ? Alignment.topCenter : Alignment.topLeft,
            children: [...previous, if (current != null) current],
          ),
          child: Column(
            key: ValueKey<int>(i),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: cross,
            children: [
              Text(
                _lyricAt(-1),
                textAlign: ta,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: big * 0.55, color: Colors.white30),
              ),
              SizedBox(height: big * 0.25),
              Text(
                _lyricAt(0),
                textAlign: ta,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: big,
                  fontWeight: FontWeight.w400,
                  height: 1.15,
                  color: Colors.white,
                ),
              ),
              SizedBox(height: big * 0.25),
              Text(
                _lyricAt(1),
                textAlign: ta,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: big * 0.6, color: Colors.white38),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The lyrics, or a large cover with its shadow and reflection when there
  /// are no lyrics to show.
  Widget _typoRight(double h, {required bool center, required double side}) {
    final lyrics = _hasLyrics;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      child: KeyedSubtree(
        key: ValueKey<bool>(lyrics),
        child: lyrics
            ? _typoLyrics(h, center: center)
            : SizedBox(
                width: side,
                child: Center(child: _artWithReflection(side)),
              ),
      ),
    );
  }

  /// A text-focused theme: no cover in front, only the blurred cover behind.
  /// Bars run down both edges, and a divider that fades out at both ends
  /// separates the song info (left) from the lyrics (right).
  Widget _typoLayout(double w, double h, bool narrow) {
    final edge = narrow ? w * 0.07 : w * 0.105;
    final strips = <Widget>[
      if (settings.visualizer) ...[
        Positioned(
            left: 0, top: 0, bottom: 0, width: edge,
            child: _edgeBars(edge, leftEdge: true)),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: edge,
          child: _edgeBars(edge, leftEdge: false),
        ),
      ],
    ];
    const fade = Color(0xCCFFFFFF);
    const clear = Color(0x00FFFFFF);
    if (narrow) {
      final cw = w - 2 * (edge + w * 0.04);
      return Stack(
        children: [
          ...strips,
          Positioned(
            left: edge + w * 0.04,
            right: edge + w * 0.04,
            // Reserve a dedicated top band for the portrait Typo clock.
            // Center/scale metadata and artwork only in the remaining area.
            top: settings.showClock
                ? math.max(48.0, MediaQuery.of(context).viewPadding.top) + 62.0
                : 0,
            bottom: 0,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: cw,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _typoInfo(h, center: true),
                      SizedBox(height: h * 0.03),
                      const SizedBox(
                        height: 3,
                        width: double.infinity,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [clear, fade, fade, clear],
                              stops: [0.0, 0.2, 0.8, 1.0],
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: h * 0.03),
                      _typoRight(h, center: true, side: math.min(cw * 0.9, h * 0.3).toDouble()),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    final side = edge + w * 0.03;
    return Stack(
      children: [
        ...strips,
        Positioned(
          left: side,
          right: side,
          top: 0,
          bottom: 0,
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _typoInfo(h, center: false),
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: w * 0.03),
                child: SizedBox(
                  width: 3,
                  height: h * 0.82,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [clear, fade, fade, clear],
                        stops: [0.0, 0.2, 0.8, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final side = math
                        .min(box.maxWidth * 0.96, box.maxHeight * 0.92 / 1.28)
                        .toDouble();
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: _typoRight(h, center: false, side: side),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ lyrics

  /// The space between the song info and the lyrics, the same on every theme.
  double _lyricGap(double h) => h * 0.045;

  bool get _hasLyrics =>
      settings.lyrics && (model.lyrics?.isNotEmpty ?? false);

  String _lyricAt(int delta) {
    final l = model.lyrics;
    if (l == null || l.isEmpty) return '';
    final k = model.lyricIndexAt(model.positionMs + 150) + delta;
    if (k < 0 || k >= l.length) return '';
    return l[k].text.isEmpty ? '...' : l[k].text;
  }

  /// Current line only (used by the Focused theme).
  Widget _lyricLine(double size, Alignment a) {
    return _shaded(AnimatedBuilder(
      animation: _slow,
      builder: (context, _) => _fit(
        Text(
          _lyricAt(0),
          maxLines: 1,
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w400,
            color: Colors.white.withOpacity(0.85),
            shadows: _cleanTextShadows,
          ),
        ),
        a,
      ),
    ));
  }

  /// Current line large, next line small. Fixed height so nothing jumps.
  Widget _lyricBlock(double h, Alignment a, {required bool vhs}) {
    final cross = a == Alignment.center
        ? CrossAxisAlignment.center
        : (a == Alignment.centerRight
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start);
    return _shaded(SizedBox(
      height: h * 0.12,
      child: AnimatedBuilder(
        animation: _slow,
        builder: (context, _) {
          final i = model.lyricIndexAt(model.positionMs + 150);
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Column(
              key: ValueKey<int>(i),
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: cross,
              children: [
                _fit(
                  Text(
                    _lyricAt(0),
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: h * 0.04,
                      fontWeight: FontWeight.w400,
                      color: Colors.white,
                      shadows: (vhs || _vhsOn)
                          ? const [
                              Shadow(
                                  color: Color(0x99FF2E93), offset: Offset(-1.5, 0)),
                              Shadow(
                                  color: Color(0x9905D9FF), offset: Offset(1.5, 0)),
                            ]
                          : _cleanTextShadows,
                    ),
                  ),
                  a,
                ),
                SizedBox(height: h * 0.008),
                _fit(
                  Text(
                    _lyricAt(1),
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: h * 0.026,
                      color: Colors.white38,
                      shadows: _cleanTextShadows,
                    ),
                  ),
                  a,
                ),
              ],
            ),
          );
        },
      ),
    ));
  }

  Widget _bars(double height, {bool blocky = false, double baseFrac = 0.72}) {
    if (!settings.visualizer) return SizedBox(height: height);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Soft black oval behind the bars, faded on every side so it never
          // reads as a rectangle.
          Positioned(
            left: -height * 0.9,
            right: -height * 0.9,
            top: -height * 0.35,
            bottom: -height * 0.15,
            child: IgnorePointer(child: _softShade()),
          ),
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: BarsPainter(
                  sim: sim,
                  palette: _palette,
                  count: settings.barCount,
                  gain: settings.sensitivity,
                  blocky: blocky || _vhsOn,
                  baseFrac: baseFrac,
                  repaint: _tick,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A black oval that is darkest in the middle and fades out all round.
  Widget _softShade() => RepaintBoundary(
        child: LayoutBuilder(
          builder: (context, box) {
            final hh = math.max(1.0, box.maxHeight).toDouble();
            final sx = math.max(1.0, box.maxWidth) / hh;
            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: const [
                    Color(0xB8000000),
                    Color(0x73000000),
                    Color(0x00000000),
                  ],
                  stops: const [0.0, 0.55, 1.0],
                  transform: _EllipseStretch(sx),
                ),
              ),
            );
          },
        ),
      );

  /// Text readability comes from a small glyph shadow, not a black panel.
  /// Keep this wrapper for existing theme call sites; it draws no backdrop.
  Widget _shaded(Widget child) => child;

  // Switch only for largely near-white, low-saturation art, not bright colors.
  // Evaluated from the already decoded 96px artwork, never per frame.
  bool get _nearWhiteText => (model.art?.nearWhiteTextCoverage ?? 0) >= 0.46;
  Color _readableText(double opacity) =>
      (_nearWhiteText ? Colors.black : Colors.white).withOpacity(opacity);
  List<Shadow> get _cleanTextShadows => [
    Shadow(color: _nearWhiteText ? const Color(0x88FFFFFF) : const Color(0x55000000),
        offset: const Offset(0, 1), blurRadius: 2.5),
  ];

  /// Compositional fade (not a text backdrop), placed beneath foreground art.
  Widget _bottomArtworkFade() => const IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0.0, 0.38, 0.68, 1.0],
              colors: [
                Color(0x00000000),
                Color(0x00000000),
                Color(0x7A000000),
                Color(0xF5000000),
              ],
            ),
          ),
        ),
      );

  /// More contrast for the blurred background. 1.0 leaves it as it is.
  ColorFilter _contrastFilter(double c) {
    final t = 128.0 * (1 - c);
    return ColorFilter.matrix(<double>[
      c, 0, 0, 0, t, //
      0, c, 0, 0, t, //
      0, 0, c, 0, t, //
      0, 0, 0, 1, 0, //
    ]);
  }

  /// A glowing ring with a bright arc that travels round it. The glow is
  /// painted once into a cached layer and the layer is turned, so nothing
  /// is blurred while it moves. Performance mode keeps it still.
  Widget _glowRing(Offset c, double radius, double stroke, Color color,
      {required double turnsPerSec, double base = 0.35, double arc = 1.0}) {
    final box = (radius + stroke * 8) * 2;
    final ring = RepaintBoundary(
      child: CustomPaint(
        size: Size(box, box),
        painter: GlowRingPainter(
          radius: radius,
          stroke: stroke,
          color: color,
          base: base,
          arc: arc,
        ),
      ),
    );
    final Widget moving = settings.performance
        ? Transform.rotate(angle: 0.9, child: ring)
        : AnimatedBuilder(
            animation: _tick,
            child: ring,
            builder: (context, child) => Transform.rotate(
              angle: _time * turnsPerSec * 2 * math.pi,
              child: child,
            ),
          );
    return Positioned(
      left: c.dx - box / 2,
      top: c.dy - box / 2,
      width: box,
      height: box,
      child: IgnorePointer(child: moving),
    );
  }

  // ------------------------------------------------------------------- pieces

  String get _titleStr => model.active && model.title.isNotEmpty
      ? model.title
      : 'Nothing playing';

  String get _artistStr => model.active
      ? model.artist
      : 'Start music in any player app';

  Text _titleText(double size, {Color? color}) => Text(
        _titleStr,
        maxLines: 1,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w300,
          color: color ?? _readableText(1),
          shadows: _cleanTextShadows,
          height: 1.1,
        ),
      );

  Text _artistText(double size, {Color? color}) => Text(
        _artistStr.toUpperCase(),
        maxLines: 1,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w400,
          letterSpacing: model.active ? size * 0.38 : size * 0.12,
          color: color ?? _readableText(_nearWhiteText ? .82 : .62),
          shadows: _cleanTextShadows,
        ),
      );

  Text _albumText(double size) => Text(
        model.album.toUpperCase(),
        maxLines: 1,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w400,
          letterSpacing: size * 0.38,
          color: _readableText(_nearWhiteText ? .70 : .45),
          shadows: _cleanTextShadows,
        ),
      );

  Widget _title(double size, Alignment a, bool vhs) => _shaded(_fit(
        (vhs || _vhsOn) ? _split((c) => _titleText(size, color: c)) : _titleText(size),
        a,
      ));

  Widget _artist(double size, Alignment a, bool vhs) => _shaded(_fit(
        (vhs || _vhsOn)
            ? _split((c) => _artistText(size, color: c), main: Colors.white70)
            : _artistText(size),
        a,
      ));

  /// RGB split: a pink and a cyan ghost behind the sharp text.
  Widget _split(Widget Function(Color) build, {Color main = Colors.white}) {
    final d = 1.0 + 2.5 * settings.vhsEffects;
    return Stack(
      children: [
        Transform.translate(
            offset: Offset(-d, 0), child: build(const Color(0x99FF2E93))),
        Transform.translate(
            offset: Offset(d, 0), child: build(const Color(0x9905D9FF))),
        build(main),
      ],
    );
  }

  Widget _fit(Widget child, Alignment align) {
    final size = MediaQuery.sizeOf(context);
    final portrait = size.width < size.height * 1.3;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: portrait ? math.max(1.0, size.width - 48.0) : double.infinity,
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: align,
        child: child,
      ),
    );
  }

  /// The clipped album image (or a placeholder), keyed so it can crossfade.
  Widget _artContent(double s) {
    final art = model.art;
    final radius = s * 0.07;
    return ClipRRect(
      key: ValueKey<Object>(art ?? 'placeholder'),
      borderRadius: BorderRadius.circular(radius),
      child: art == null
          ? Container(
              width: s,
              height: s,
              color: const Color(0xFF111827),
              child: Center(child: _brandIcon(s * 0.55)),
            )
          : Image.memory(
              art.bytes,
              width: s,
              height: s,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.high,
            ),
    );
  }

  Widget _artCard(double s) {
    final p = _palette;
    return RepaintBoundary(
      child: Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(s * 0.07),
          border: Border.all(color: p.a.withOpacity(0.85), width: 1.5),
          boxShadow: [
            BoxShadow(
                color: p.a.withOpacity(0.35),
                blurRadius: s * 0.12,
                spreadRadius: 1),
            BoxShadow(
                color: p.c.withOpacity(0.22),
                blurRadius: s * 0.2,
                offset: Offset(s * 0.03, 0)),
          ],
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          child: _artContent(s),
        ),
      ),
    );
  }

  /// Art card with a pink ghost to one side and a cyan ghost to the other.
  Widget _splitArt(double s) {
    final d = s * (0.006 + 0.014 * settings.vhsEffects);
    Widget ghost(Color c, double dx) => Transform.translate(
          offset: Offset(dx, 0),
          child: Opacity(
            opacity: 0.55,
            child: ColorFiltered(
              colorFilter: ColorFilter.mode(c, BlendMode.srcATop),
              child: _artContent(s),
            ),
          ),
        );
    return RepaintBoundary(
      child: SizedBox(
        width: s,
        height: s,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ghost(const Color(0xFFFF2E93), -d),
            ghost(const Color(0xFF05D9FF), d),
            _artCard(s),
          ],
        ),
      ),
    );
  }

  /// Small scale-up on bass hits. Only moves a cached layer.
  Widget _pulse(Widget child) {
    if (!settings.bgEffects) return child;
    return AnimatedBuilder(
      animation: _tick,
      child: child,
      builder: (context, c) {
        final b = ((sim.bass - 0.15) / 0.6).clamp(0.0, 1.0).toDouble();
        return Transform.scale(
            scale: 1.0 + 0.03 * b * settings.kMotion, child: c);
      },
    );
  }

  /// Tapping the cover opens the player app that is playing.
  Widget _front(double s, bool vhs) => GestureDetector(
        key: _artKey,
        behavior: HitTestBehavior.opaque,
        onTap: _openPlayer,
        child: _pulse(
          Stack(
            clipBehavior: Clip.none,
            children: [
              if (settings.fxBloom && !settings.performance) _bloom(s),
              (vhs || _vhsOn) ? _splitArt(s) : _artCard(s),
            ],
          ),
        ),
      );

  /// Soft glow: a blurred, slightly larger copy of the cover behind it.
  Widget _bloom(double s) => RepaintBoundary(
        child: Transform.scale(
          scale: 1.06,
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: s * 0.04, sigmaY: s * 0.04),
            child: Opacity(
                opacity: (0.75 * settings.kBloom).clamp(0.0, 1.0).toDouble(),
                child: _artContent(s)),
          ),
        ),
      );

  /// Mirrored, fading copy of the art plus a thin contact shadow, so the
  /// card looks like it is standing on a glass surface.
  Widget _reflection(double s) {
    final h = s * 0.28;
    return SizedBox(
      width: s,
      height: h,
      child: Stack(
        children: [
          Positioned.fill(
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x66FFFFFF), Color(0x00FFFFFF)],
              ).createShader(rect),
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minWidth: s,
                  maxWidth: s,
                  minHeight: s,
                  maxHeight: s,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 500),
                    child: Transform(
                      key: ValueKey<Object>(model.art ?? 'placeholder'),
                      alignment: Alignment.center,
                      transform: Matrix4.diagonal3Values(1.0, -1.0, 1.0),
                      // Same rounded corners and stroke as the cover.
                      child: Container(
                        width: s,
                        height: s,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(s * 0.07),
                          border: Border.all(
                              color: _palette.a.withOpacity(0.85), width: 1.5),
                        ),
                        child: _artContent(s),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Rounded to match the cover: it starts where the cover's straight
          // bottom edge starts, so no square corners poke out.
          Positioned(
            top: 0,
            left: s * 0.07,
            right: s * 0.07,
            height: s * 0.06,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius:
                    BorderRadius.vertical(bottom: Radius.circular(s * 0.05)),
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xA6000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Art with its reflection stacked underneath (used by Focused and the
  /// portrait VHS layout).
  Widget _artWithReflection(double s, {bool vhs = false}) {
    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _front(s, vhs),
          const SizedBox(height: 3),
          _reflection(s),
        ],
      ),
    );
  }

  /// The art card occupies exactly s x s so a Row centers the card itself.
  /// The reflection hangs below and is allowed to overflow downward.
  Widget _artCentered(double s, {required bool vhs}) {
    return SizedBox(
      width: s,
      height: s,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _front(s, vhs),
          Positioned(left: 0, top: s + 3, width: s, child: _reflection(s)),
        ],
      ),
    );
  }

  Widget _progressLine() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: 3,
      child: AnimatedBuilder(
        animation: _tick,
        builder: (context, _) {
          final d = model.durationMs;
          final f = d > 0 ? model.positionMs / d : 0.0;
          return Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: f.clamp(0.0, 1.0).toDouble(),
              child: DecoratedBox(
                decoration:
                    BoxDecoration(gradient: LinearGradient(colors: _palette.colors)),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _controls() {
    Widget btn(IconData icon, double size, VoidCallback onTap) => IconButton(
          iconSize: size,
          padding: const EdgeInsets.all(14),
          color: Colors.white,
          icon: Icon(icon),
          onPressed: () {
            onTap();
            _poke();
          },
        );

    return Positioned(
      left: 0,
      right: 0,
      bottom: 28,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xCC000000),
              borderRadius: BorderRadius.circular(60),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _seekBar(),
                Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                btn(Icons.grid_view_rounded, 36, _pickTheme),
                btn(Icons.settings, 36, _openSettings),
                if (widget.driveHost) ...[
                  btn(Icons.map_outlined, 36, _hideDrive),
                  btn(Icons.close_rounded, 36, _exitDrive),
                ] else
                  btn(Icons.navigation_rounded, 36, _startDrive),
                const SizedBox(width: 12),
                btn(Icons.skip_previous_rounded, 56, model.previous),
                btn(
                    model.playing
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    76,
                    model.playPause),
                btn(Icons.skip_next_rounded, 56, model.next),
                const SizedBox(width: 16),
                AnimatedBuilder(
                  animation: _tick,
                  builder: (context, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_fmt(model.positionMs)} / ${_fmt(model.durationMs)}',
                        style:
                            const TextStyle(color: Colors.white70, fontSize: 16),
                      ),
                      Text(
                        model.realActive ? 'live audio' : 'simulated',
                        style: TextStyle(
                          color: model.realActive ? _palette.a : Colors.white38,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        AppSettings.themeNames[settings.theme],
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _seekBar({double width = 560}) {
    return AnimatedBuilder(
      animation: _tick,
      builder: (context, _) {
        final d = model.durationMs;
        final frac = d > 0 ? (model.positionMs / d).clamp(0.0, 1.0).toDouble() : 0.0;
        return SizedBox(
          width: width,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 26),
            ),
            child: Slider(
              value: _drag ?? frac,
              activeColor: _palette.a,
              inactiveColor: Colors.white24,
              onChanged: d > 0
                  ? (v) {
                      setState(() => _drag = v);
                      _poke();
                    }
                  : null,
              onChangeEnd: d > 0
                  ? (v) {
                      model.seekTo((v * d).round());
                      _poke();
                      // Keep the thumb where it was dropped until the
                      // player reports the new position.
                      Timer(const Duration(milliseconds: 700), () {
                        if (mounted) setState(() => _drag = null);
                      });
                    }
                  : null,
            ),
          ),
        );
      },
    );
  }

  /// The VYBE icon, shown where there is no album art.
  Widget _brandIcon(double size) => Opacity(
        opacity: 0.9,
        child: Image.asset(
          'assets/vybe_icon.png',
          width: size,
          height: size,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stack) =>
              Icon(Icons.music_note, size: size * 0.6, color: Colors.white24),
        ),
      );

  Widget _accessPrompt() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/vybe_logo.png',
                width: 300,
                errorBuilder: (context, error, stack) => const Icon(
                    Icons.music_note,
                    size: 56,
                    color: Colors.white54),
              ),
              const SizedBox(height: 20),
              const Text(
                'Allow notification access',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w300),
              ),
              const SizedBox(height: 12),
              const Text(
                'Android only shares what is playing with apps that have '
                'notification access. Turn it on for VYBE, then come back.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.white70),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: model.openAccessSettings,
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  backgroundColor: _palette.a,
                  foregroundColor: Colors.black,
                ),
                child: const Text('Open settings', style: TextStyle(fontSize: 18)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(int ms) {
    final s = ms ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

/// Stretches a radial gradient sideways so it fills a wide box as an oval.
/// Stretches a round gradient into an ellipse that fits its box.
class _EllipseFit extends GradientTransform {
  final double sx;
  final double sy;
  const _EllipseFit(this.sx, this.sy);

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    final c = bounds.center;
    return Matrix4.translationValues(c.dx, c.dy, 0.0) *
        Matrix4.diagonal3Values(sx, sy, 1.0) *
        Matrix4.translationValues(-c.dx, -c.dy, 0.0);
  }
}

class _EllipseStretch extends GradientTransform {
  final double sx;
  const _EllipseStretch(this.sx);

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    final c = bounds.center;
    return Matrix4.translationValues(c.dx, c.dy, 0.0) *
        Matrix4.diagonal3Values(sx, 1.0, 1.0) *
        Matrix4.translationValues(-c.dx, -c.dy, 0.0);
  }
}

/// Clips away a rounded rectangle so whatever is behind the window shows.
class _HoleClipper extends CustomClipper<Path> {
  final Rect hole;
  final double radius;
  const _HoleClipper(this.hole, this.radius);

  @override
  Path getClip(Size size) {
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(hole, Radius.circular(radius)));
  }

  @override
  bool shouldReclip(_HoleClipper old) =>
      old.hole != hole || old.radius != radius;
}

/// The thin accent border around the map window.
class _HoleBorderPainter extends CustomPainter {
  final Rect hole;
  final double radius;
  final Color color;
  const _HoleBorderPainter(this.hole, this.radius, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final rim = RRect.fromRectAndRadius(hole, Radius.circular(radius));
    // Clip the shadow to the map opening: darkening only the inner edge,
    // while keeping the navigation app fully visible and interactive.
    canvas.save();
    canvas.clipRRect(rim);
    canvas.drawRRect(
      rim.inflate(11),
      Paint()..color = const Color(0xB8000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 23
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    canvas.restore();
    canvas.drawRRect(
      rim,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color.withOpacity(0.7),
    );
  }

  @override
  bool shouldRepaint(_HoleBorderPainter old) =>
      old.hole != hole || old.radius != radius || old.color != color;
}

/// Shadow that falls inward from only the curved, vinyl-facing portion of
/// Record Cut's grayscale disc. The remainder of its perimeter stays clean.
class _RecordCurveShadowPainter extends CustomPainter {
  final double centerAngle;
  final double span;
  final double depth;

  const _RecordCurveShadowPainter({
    required this.centerAngle,
    required this.span,
    required this.depth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
    final shadowDepth = math.min(depth, radius * 0.28);
    final steps = math.max(12, (shadowDepth / 2).ceil());
    for (var i = 0; i < steps; i++) {
      final t = i / steps;
      final opacity = 0.36 * math.pow(1 - t, 2).toDouble();
      final rr = radius - t * shadowDepth - 0.75;
      final rect = Rect.fromCircle(center: center, radius: rr);
      // Flutter's drawArc angles start at the right and run clockwise.
      // Narrowing the arc at greater depths keeps the shadow localized.
      final arcSpan = span * (1 - 0.18 * t);
      canvas.drawArc(
        rect,
        centerAngle - arcSpan,
        arcSpan * 2,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = shadowDepth / steps + 1.5
          ..color = Colors.black.withOpacity(opacity),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RecordCurveShadowPainter oldDelegate) =>
      oldDelegate.centerAngle != centerAngle ||
      oldDelegate.span != span ||
      oldDelegate.depth != depth;
}


// Isolate each painter before compositing it with the underlying scene.
// Normal at full opacity avoids the expensive saveLayer on entry-level GPUs.
class _FxBlendPainter extends CustomPainter {
  final CustomPainter delegate;
  final int mode;
  final double opacity;
  _FxBlendPainter(this.delegate, this.mode, this.opacity) : super(repaint: delegate);
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
  void paint(Canvas canvas, Size size) {
    if (mode == 0 && opacity >= .999) {
      delegate.paint(canvas, size);
      return;
    }
    canvas.saveLayer(Offset.zero & size, Paint()
      ..blendMode = modes[mode.clamp(0, modes.length - 1)]
      ..color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0)));
    delegate.paint(canvas, size);
    canvas.restore();
  }
  @override
  bool shouldRepaint(covariant _FxBlendPainter old) =>
      mode != old.mode || opacity != old.opacity ||
      delegate != old.delegate || delegate.shouldRepaint(old.delegate);
}
