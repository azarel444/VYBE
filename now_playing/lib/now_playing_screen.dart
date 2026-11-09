import 'onboarding.dart';
import 'vybe_link.dart';
import 'dart:async';
import 'dart:typed_data';
import 'artist_fanart.dart';
import 'local_artwork.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';

import 'effects.dart';
import 'golden_hour_background.dart';
import 'refraction_shader.dart';
import 'fx_adaptive.dart';
import 'fx_profile.dart';
import 'native.dart';
import 'now_playing_model.dart';
import 'orbit.dart';
import 'palette.dart';
import 'settings.dart';
import 'settings_screen.dart';
import 'song_title_marquee.dart';
import 'quick_customize.dart';
import 'fx_library.dart';
import 'spectrum.dart';
import 'theme_parts.dart';
import 'theme_library.dart';
import 'template_background.dart';
import 'club_background.dart';
import 'laser_tunnel_background.dart';
import 'fx_composite.dart';

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
  final _fanart = ArtistFanartCache();
  Uint8List? _fanartBytes;
  Uint8List? _clearLogoBytes;
  bool _clearLogoIsLocal = false;
  String _clearLogoArtist = '';
  int _clearLogoRequest = 0;
  Timer? _clearLogoRetryTimer;
  String _clearLogoLoadingArtist = '';
  int _clearLogoRetryCount = 0;
  List<Uint8List> _fanartGallery = [];
  Timer? _fanartCycleTimer;
  int _activeFanartCycleSeconds = 0;
  final math.Random _fanartRandom = math.Random();
  int _fanartGalleryIndex = 0;
  bool _fanartGalleryIsLocal = false;
  String _fanartArtist = '';
  int _seenLocalScanGeneration = 0;
  String _fanartLoadingArtist = '';
  int _fanartRequest = 0;
  DateTime? _fanartLastFailure;
  Timer? _fanartRetryTimer;
  int _fanartRetryCount = 0;
  final particles = ParticleField();
  final glitch = GlitchState();
  final grid = GridState();
  final _rng = math.Random();
  final Map<String, double> _artistWidthCache = {};


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

  // Brand colors are the idle fallback only; active tracks retain their
  // extracted album-art colors and existing custom/VHS palette overrides.
  static const ArtPalette _brandPalette = ArtPalette(
    Color(0xFFFF005E), Color(0xFF8A00FF), Color(0xFFCB32FF));

  ArtPalette get _palette {
    if (settings.useVybePalette) return _brandPalette;
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
    if (!model.active) return _brandPalette;
    // Between tracks the art is briefly missing. Keep the last colors for a
    // few seconds instead of flashing a different palette, then go neutral.
    if (_artNullSince < 0) _artNullSince = _time;
    if (_lastArtPalette != null && _time - _artNullSince < 4) {
      return _lastArtPalette!;
    }
    return _brandPalette;
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
    if (!widget.driveHost) {
      VybeLink.instance.addListener(_onLinkFanart);
      VybeLink.instance.initialize(model);
    }
    _ticker = createTicker(_onTick)..start();
    if (widget.driveHost) {
      _dirTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        final a = await Native.navActive();
        if (mounted && a != _dirActive) setState(() => _dirActive = a);
      });
    }
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(_updateClock);
    });
    makeNoiseImage().then((img) {
      if (mounted) setState(() => _noise = img);
    });
    _updateClock();
    settings.load().then((_) async {
      if (!mounted) return;
      if (!widget.driveHost) {
        final selections = OnboardingScreen.launchSelections;
        if (selections != null) {
          OnboardingScreen.launchSelections = null;
          for (final choice in selections.entries) {
            await settings.setLaunchOrContentChoice(choice.key, choice.value);
          }
        }
      }
      if (widget.driveHost) {
        // The Drive window always shows the Drive theme.
        // Force the Drive view only for this engine, without saving the
        // selected theme to the normal app preferences.
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
    if (!widget.driveHost) VybeLink.instance.removeListener(_onLinkFanart);
    model.removeListener(_onModel);
    settings.removeListener(_onSettings);
    _ticker.dispose();
    _hideTimer?.cancel();
    _brightnessChannel.invokeMethod<void>('setNight', false).catchError((Object _) {});
    _clockTimer?.cancel();
    _fanartCycleTimer?.cancel();
    _fanartRetryTimer?.cancel();
    _clearLogoRetryTimer?.cancel();
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
      _fxGovernor.enabled = settings.fxPerformanceMode == 0 && !settings.performance;
      model.refresh();
      if (!widget.driveHost) VybeLink.instance.onResumed();
      // The Drive window may have changed the theme while VYBE was away.
      // Avoid racing an in-flight settings write with a stale preference reload.
      // The Drive engine never writes launch/content preferences.
      // Reload on resume so switches reflect the persisted user choices.
      // Drive uses a separate Flutter engine: restore its own appearance
      // after loading the normal window's last selected theme.
      settings.load().then((_) {
        if (mounted && widget.driveHost) {
          settings.update(() => settings.theme = 4, persist: false);
        }
      });
    }
  }

  void _onLinkFanart() {
    if (!mounted) return;
    final link = VybeLink.instance;
    if (link.role == 'sender') {
      // Replay the current logo after initial metadata is sent on reconnect.
      if (settings.useArtistClearLogo &&
          _clearLogoArtist == model.artist.trim()) {
        link.sendClearLogo(_clearLogoArtist, _clearLogoBytes);
      }
      return;
    }
    if (link.role != 'receiver') return;
    final artist = model.artist.trim();
    final logo = link.receivedClearLogo;
    // Local head-unit art always takes priority over the phone.
    if (settings.useArtistClearLogo &&
        link.receivedClearLogoArtist == artist &&
        logo != null && logo.isNotEmpty && !_clearLogoIsLocal &&
        !identical(logo, _clearLogoBytes)) {
      _clearLogoArtist = artist;
      _clearLogoRetryTimer?.cancel();
      _clearLogoRetryCount = 0;
      setState(() => _clearLogoBytes = logo);
    }
    if (link.receivedFanartArtist != model.artist ||
        (_fanartGalleryIsLocal && _fanartArtist == model.artist && _fanartGallery.isNotEmpty)) return;
    final incoming = link.receivedFanart;
    if (!identical(incoming, _fanartBytes)) {
      _fanartArtist = model.artist;
      _fanartBytes = incoming;
      setState(() {});
    }
  }

  void _onModel() {
    if (!mounted) return;
    _checkTrack();
    _loadFanart();
    setState(() {});
  }

  void _onSettings() {
    if (!mounted) return;
    if (model.visualizerEnabled != settings.visualizer) {
      model.setVisualizer(settings.visualizer);
    }
    _fxGovernor.enabled = settings.fxPerformanceMode == 0;
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
    if (_fanartGallery.length > 1) _startFanartCycle();
    _loadFanart();
    if (widget.driveHost) {
      // Leaving Drive is coordinated by _pickTheme, after its awaited save.
      // Exiting here races SharedPreferences writes across Flutter engines.
    } else if (_themeReady) {
      if (settings.theme == 4 && _prevTheme != 4) {
        // Commit the selected theme/profile before launching the separate
        // Drive Flutter engine, which loads preferences on its first frame.
        settings.saveTheme().then((_) {
          if (mounted && settings.theme == 4) _startDrive();
        }).catchError((Object error) {
          debugPrint('VYBE could not persist Drive theme: $error');
        });
      }
      _prevTheme = settings.theme;
    }
    setState(() {});
  }

  /// Night mode and the burn-in shift only need updating every so often.
  static const _brightnessChannel = MethodChannel('vybe/window_brightness');
  bool? _lastNightBrightness;

  void _updateClock() {
    final now = DateTime.now();
    if (settings.night == 0) {
      _night = false;
    } else if (settings.night == 1) {
      _night = now.hour >= 20 || now.hour < 6;
    } else {
      _night = true;
    }
    if (_lastNightBrightness != _night) {
      _lastNightBrightness = _night;
      _brightnessChannel.invokeMethod<void>('setNight', _night).catchError((Object _) {});
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
    ripples.update(_time, bass, model.playing, liveAudio: model.realActive && model.fft != null);

    // Record Cut and Drive: 33 1/3 rpm is one turn every 1.8 seconds. It speeds up
    // over about 0.75 s, slows over about 1.5 s, and keeps its angle.
    if (settings.theme == AppSettings.tRecord ||
        settings.theme == AppSettings.tEditorial || settings.theme == 4) {
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

  /// Customize is hidden until the floating button is tapped. The bottom
  /// sheet route handles the smooth slide-up / slide-down animation; no
  /// always-visible handle or drag-to-open interaction is offered.
  void _openQuickCustomize() {
    _hideTimer?.cancel();
    setState(() => _showControls = false);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      enableDrag: false,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      constraints: const BoxConstraints(maxWidth: 860),
      builder: (sheetContext) => Padding(
        // Quick Customize floats above the bottom edge, unlike the playback
        // controls. Corners match the subtle album-cover rounding.
        padding: EdgeInsets.fromLTRB(
          12, 0, 12, math.max(12.0, MediaQuery.viewPaddingOf(sheetContext).bottom)),
        child: QuickCustomizeSheet(
          settings: settings,
          accent: _palette.a,
          onOpenFx: () {
            Navigator.of(sheetContext).pop();
            Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => FxLibraryScreen(settings: settings)));
          },
        ),
      ),
    );
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
    final heavy = true; // FX budget governs layers; never freeze the scene.

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
            if (!widget.driveHost && false && settings.theme == AppSettings.tCinematic &&
                settings.backgroundSource >= 2 && settings.backgroundSource <= 5)
              _cinematicLightShow(),
            // Uniform darkness for every theme and background source.
            // Applied once, after background rendering, before foreground FX/UI.
            Positioned.fill(child: IgnorePointer(child: ColoredBox(
              color: Colors.black.withOpacity(((settings.theme == AppSettings.tCinematic || settings.theme == AppSettings.tEditorial) && !widget.driveHost ? 0.0 : settings.bgOverlay).clamp(0.0, 1.0))))),
            if (heavy) _shaderFxLayer(),
            if (heavy) ..._extraFx(),
            if (vhs) FxComposite(mode: settings.fxBlendMode['VHS'] ?? 0,
              opacity: settings.fxBlendOpacity['VHS'] ?? 1.0,
              child: Transform.scale(scale: settings.fxSize['VHS'] ?? 1.0,
                child: Stack(fit: StackFit.expand, children: _vhsBackdrop(fx)))),
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
                if (widget.driveHost) {
                  // The transparent Drive activity has its own Flutter engine.
                  // Never render a persisted normal theme (Focused, etc.) here.
                  layout = _driveLayout(w, h, narrow);
                } else if (settings.theme == AppSettings.tCinematic) {
                  layout = _cinematicLayout(w, h);
                } else if (settings.theme == AppSettings.tEditorial) {
                  layout = _editorialLayout(w, h);
                } else if (settings.theme == AppSettings.tRecord) {
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
                  offset: (widget.driveHost || settings.theme >= 3 || settings.theme == 1) ? Offset.zero : _shift,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      layout,
                      // Clock is displayed only with the popup controls.
                      if (vhs && !widget.driveHost && settings.theme != 4) _osd(h, compact: narrow),
                    ],
                  ),
                );
              }),
            // These sit on top of everything, so they must not catch touches.
            if (vhs)
              IgnorePointer(
                child: FxComposite(
                  mode: settings.fxBlendMode['VHS'] ?? 0,
                  opacity: settings.fxBlendOpacity['VHS'] ?? 1.0,
                  child: Transform.scale(
                    scale: settings.fxSize['VHS'] ?? 1.0,
                    child: Stack(fit: StackFit.expand,
                      children: _vhsOverlay(fx, heavy)),
                  ),
                ),
              ),
            // Night Mode uses window brightness, never a text-dimming overlay.
            _progressLine(),
            if (controlsInside) ...[
              if (_showControls && settings.showClock) _controlsClockHeader(),
              _controls(),
            ],
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
            if (_showControls && settings.showClock) _controlsClockHeader(),
            _controls(),
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

  void _scheduleClearLogoRetry(String artist) {
    _clearLogoRetryTimer?.cancel();
    final seconds = [5, 10, 20, 40, 60][_clearLogoRetryCount.clamp(0, 4)];
    if (_clearLogoRetryCount < 4) _clearLogoRetryCount++;
    _clearLogoRetryTimer = Timer(Duration(seconds: seconds), () {
      if (!mounted || !settings.useArtistClearLogo ||
          model.artist.trim() != artist) return;
      _loadClearLogo();
    });
  }

  /// Fanart.tv ClearLogo PNGs often contain large transparent borders.
  /// BoxFit.contain scales the entire PNG canvas, making the visible logo
  /// tiny even in a wide layout. Trim alpha-only padding once when loaded;
  /// keep the original bytes if decoding or trimming is too expensive.
  Future<Uint8List> _trimClearLogoPadding(Uint8List original) async {
    ui.Codec? codec;
    ui.Image? decoded;
    ui.Image? cropped;
    ui.Picture? picture;
    try {
      codec = await ui.instantiateImageCodec(original);
      final frame = await codec.getNextFrame();
      decoded = frame.image;
      final width = decoded.width, height = decoded.height;
      if (width <= 0 || height <= 0 || width * height > 3000000) {
        return original;
      }
      final rgba = await decoded.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) return original;
      final pixels = rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes);
      int left = width, right = -1, top = height, bottom = -1;
      for (var y = 0; y < height; y++) {
        final row = y * width * 4;
        for (var x = 0; x < width; x++) {
          if (pixels[row + x * 4 + 3] <= 12) continue;
          if (x < left) left = x;
          if (x > right) right = x;
          if (y < top) top = y;
          if (y > bottom) bottom = y;
        }
      }
      if (right < left || bottom < top) return original;
      final contentW = right - left + 1, contentH = bottom - top + 1;
      // Retain a small margin around antialiased logo edges.
      final padX = math.max(2, (contentW * .025).round());
      final padY = math.max(2, (contentH * .025).round());
      left = math.max(0, left - padX);
      right = math.min(width - 1, right + padX);
      top = math.max(0, top - padY);
      bottom = math.min(height - 1, bottom + padY);
      final cropW = right - left + 1, cropH = bottom - top + 1;
      if (cropW * cropH > width * height * .88) return original;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        decoded,
        ui.Rect.fromLTWH(left.toDouble(), top.toDouble(),
            cropW.toDouble(), cropH.toDouble()),
        ui.Rect.fromLTWH(0, 0, cropW.toDouble(), cropH.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      picture = recorder.endRecording();
      cropped = await picture.toImage(cropW, cropH);
      final encoded = await cropped.toByteData(format: ui.ImageByteFormat.png);
      return encoded?.buffer.asUint8List() ?? original;
    } catch (error) {
      debugPrint('VYBE clearlogo alpha trim skipped: $error');
      return original;
    } finally {
      cropped?.dispose();
      picture?.dispose();
      decoded?.dispose();
      codec?.dispose();
    }
  }

  Future<void> _loadClearLogo() async {
    final artist = model.artist.trim();
    if (!settings.useArtistClearLogo || artist.isEmpty) {
      _clearLogoRetryTimer?.cancel();
      _clearLogoRetryCount = 0;
      _clearLogoIsLocal = false;
      if (_clearLogoBytes != null || _clearLogoArtist.isNotEmpty) {
        ++_clearLogoRequest;
        _clearLogoArtist = '';
        if (mounted) setState(() => _clearLogoBytes = null);
      }
      return;
    }
    if (_clearLogoArtist == artist && _clearLogoBytes != null) {
      if (!widget.driveHost && VybeLink.instance.enabled &&
          VybeLink.instance.role == 'sender') {
        VybeLink.instance.sendClearLogo(artist, _clearLogoBytes);
      }
      return;
    }
    if (_clearLogoLoadingArtist == artist) return;
    if (_clearLogoArtist != artist) {
      _clearLogoRetryTimer?.cancel();
      _clearLogoRetryCount = 0;
      _clearLogoArtist = artist;
      _clearLogoIsLocal = false;
      if (_clearLogoBytes != null && mounted) {
        setState(() => _clearLogoBytes = null);
      }
    }
    _clearLogoLoadingArtist = artist;
    final request = ++_clearLogoRequest;
    Uint8List? bytes;
    bool localLogo = false;
    bool transferred = false;
    try {
      // The receiver's own on-disk logo is the first choice.
      bytes = await LocalArtwork.instance.clearLogo(artist);
      localLogo = bytes != null && bytes.isNotEmpty;
      if (!localLogo && !widget.driveHost) {
        final link = VybeLink.instance;
        if (link.enabled && link.role == 'receiver' &&
            link.receivedClearLogoArtist == artist &&
            link.receivedClearLogo?.isNotEmpty == true) {
          bytes = link.receivedClearLogo;
          transferred = true;
        }
      }
      if ((bytes == null || bytes.isEmpty) && settings.fanartProjectKey.isNotEmpty) {
        bytes = await _fanart.getClearLogo(artist, settings.fanartProjectKey,
            personalKey: settings.fanartApiKey);
        transferred = false;
      }
      // Keep the latest Riot ClearLogo alpha-padding trim for local/online
      // artwork. The sender has already trimmed transferred images.
      if (!transferred && bytes != null && bytes.isNotEmpty) {
        bytes = await _trimClearLogoPadding(bytes);
      }
      // A logo could arrive while an online lookup was pending.
      if (!localLogo && !widget.driveHost) {
        final link = VybeLink.instance;
        if (link.enabled && link.role == 'receiver' &&
            link.receivedClearLogoArtist == artist &&
            link.receivedClearLogo?.isNotEmpty == true) {
          bytes = link.receivedClearLogo;
        }
      }
    } catch (e) {
      debugPrint('VYBE clearlogo lookup failed for $artist: $e');
    } finally {
      if (_clearLogoLoadingArtist == artist) _clearLogoLoadingArtist = '';
    }
    if (!mounted || request != _clearLogoRequest ||
        _clearLogoArtist != artist || !settings.useArtistClearLogo) return;
    if (bytes != null && bytes.isNotEmpty) {
      _clearLogoRetryTimer?.cancel();
      _clearLogoRetryCount = 0;
      _clearLogoIsLocal = localLogo;
      setState(() => _clearLogoBytes = bytes);
      if (!widget.driveHost && VybeLink.instance.enabled &&
          VybeLink.instance.role == 'sender') {
        VybeLink.instance.sendClearLogo(artist, bytes);
      }
    } else {
      _scheduleClearLogoRetry(artist);
    }
  }

  void _startFanartCycle() {
    final seconds = settings.fanartCycleSeconds.clamp(5, 300);
    if (_fanartCycleTimer?.isActive == true && _activeFanartCycleSeconds == seconds) return;
    _fanartCycleTimer?.cancel();
    if (_fanartGallery.length < 2) return;
    _activeFanartCycleSeconds = seconds;
    _fanartCycleTimer = Timer.periodic(Duration(seconds: seconds), (_) {
      if (!mounted || _fanartGallery.length < 2) return;
      // Shuffle local and downloaded galleries alike. Pick uniformly from
      // every image except the current one so the slideshow never repeats
      // the same image on consecutive ticks.
      var next = _fanartRandom.nextInt(_fanartGallery.length - 1);
      if (next >= _fanartGalleryIndex) next++;
      _fanartGalleryIndex = next;
      setState(() => _fanartBytes = _fanartGallery[next]);
      final link = VybeLink.instance;
      if (!widget.driveHost && link.enabled && link.role == 'sender') {
        link.sendFanart(_fanartArtist, _fanartBytes);
      }
    });
  }

  void _scheduleFanartRetry(String artist) {
    _fanartRetryTimer?.cancel();
    // Retry transient HTTP/network failures without requiring a track skip.
    // Exponential backoff avoids hammering Fanart.tv during an outage.
    final seconds = [5, 10, 20, 40, 60][_fanartRetryCount.clamp(0, 4)];
    if (_fanartRetryCount < 4) _fanartRetryCount++;
    _fanartRetryTimer = Timer(Duration(seconds: seconds), () {
      if (!mounted || model.artist.trim() != artist) return;
      _fanartLastFailure = null;
      _loadFanart();
    });
  }

  Future<void> _loadFanart() async {
    // A user-initiated library rescan must invalidate the current artist,
    // including online fallback artwork that was already cached in this view.
    // Otherwise new local files remain invisible until a different artist plays.
    final scanGeneration = LocalArtwork.instance.manualScanGeneration;
    if (_seenLocalScanGeneration != scanGeneration) {
      _seenLocalScanGeneration = scanGeneration;
      ++_fanartRequest;
      _fanartRetryTimer?.cancel();
      _fanartCycleTimer?.cancel();
      _fanartArtist = '';
      _fanartLoadingArtist = '';
      _fanartGallery = [];
      _fanartGalleryIsLocal = false;
      _fanartBytes = null;
      _fanartLastFailure = null;
      _clearLogoRetryTimer?.cancel();
      ++_clearLogoRequest;
      _clearLogoArtist = '';
      _clearLogoLoadingArtist = '';
      _clearLogoIsLocal = false;
      _clearLogoBytes = null;
    }
    _loadClearLogo();
    final artist = model.artist.trim();
    final link = VybeLink.instance;
    if (!widget.driveHost && link.enabled && link.role == 'receiver') {
      if (_fanartArtist == artist && _fanartGalleryIsLocal && _fanartGallery.isNotEmpty) return;
      if (_fanartLoadingArtist == artist) return;
      if (_fanartArtist != artist) {
        _fanartArtist = artist;
        _fanartGallery = [];
        _fanartGalleryIsLocal = false;
        _fanartCycleTimer?.cancel();
        _fanartLoadingArtist = artist;
        final request = ++_fanartRequest;
        LocalArtwork.instance.fanartGallery(artist).then((gallery) {
          if (!mounted || request != _fanartRequest || _fanartArtist != artist) return;
          if (gallery.isNotEmpty) {
            _fanartGallery = gallery;
            _fanartGalleryIsLocal = true;
            _fanartGalleryIndex = _fanartRandom.nextInt(gallery.length);
            setState(() => _fanartBytes = gallery[_fanartGalleryIndex]);
            if (gallery.length > 1) _startFanartCycle();
          } else {
            _onLinkFanart();
          }
        }).whenComplete(() { if (_fanartLoadingArtist == artist) _fanartLoadingArtist = ''; });
      } else {
        _onLinkFanart();
      }
      return;
    }
    // Keep fetching artist backgrounds for the head unit even when the
    // sender's current theme uses album art or an animated scene.
    final linkSender = !widget.driveHost && link.enabled && link.role == 'sender';
    if (linkSender) link.setFanartArtist(artist);
    final isFanartTheme = settings.theme == AppSettings.tCinematic ||
        settings.theme == AppSettings.tEditorial;
    final needsLocalFanart = isFanartTheme
        ? !settings.fanartOverride
        : settings.backgroundSource == 6 ||
            (settings.backgroundSource == 0 && settings.fanartMode == 1);
    final needsFanart = needsLocalFanart || linkSender;
    if (!needsFanart || artist.isEmpty) {
      _fanartRetryTimer?.cancel();
      _fanartRetryCount = 0;
      _fanartCycleTimer?.cancel();
      _fanartGallery = [];
      if (_fanartArtist.isNotEmpty || _fanartBytes != null) {
        ++_fanartRequest;
        _fanartArtist = '';
        _fanartBytes = null;
        _fanartLoadingArtist = '';
      }
      return;
    }
    if (_fanartArtist == artist && _fanartBytes != null) {
      if (linkSender) link.sendFanart(artist, _fanartBytes);
      return;
    }
    if (_fanartLoadingArtist == artist) return;
    if (_fanartArtist == artist && _fanartLastFailure != null &&
        DateTime.now().difference(_fanartLastFailure!) <
            const Duration(seconds: 25)) return;
    _fanartCycleTimer?.cancel();
    _fanartRetryTimer?.cancel();
    _fanartGallery = [];
    _fanartGalleryIsLocal = false;
    _fanartGalleryIndex = 0;
    if (_fanartArtist != artist) {
      _fanartRetryTimer?.cancel();
      _fanartRetryCount = 0;
    }
    _fanartArtist = artist;
    _fanartBytes = null;
    _fanartLoadingArtist = artist;
    final request = ++_fanartRequest;
    try {
      final localGallery = await LocalArtwork.instance.fanartGallery(artist);
      final localBytes = localGallery.isEmpty ? null : localGallery.first;
      final bytes = localBytes ?? (settings.fanartProjectKey.isEmpty ? null :
          await _fanart.get(artist, settings.fanartProjectKey,
              personalKey: settings.fanartApiKey));
      if (mounted && request == _fanartRequest && _fanartArtist == artist) {
        _fanartLastFailure = bytes == null ? DateTime.now() : null;
        if (bytes == null) _scheduleFanartRetry(artist);
        else { _fanartRetryTimer?.cancel(); _fanartRetryCount = 0; }
        setState(() => _fanartBytes = bytes);
        if (linkSender && bytes != null) link.sendFanart(artist, bytes);
        if (localGallery.length > 1) {
          _fanartGallery = localGallery;
          _fanartGalleryIsLocal = true;
          _fanartGalleryIndex = _fanartRandom.nextInt(localGallery.length);
          setState(() => _fanartBytes = localGallery[_fanartGalleryIndex]);
          if (linkSender) link.sendFanart(artist, _fanartBytes);
          _startFanartCycle();
        }
        if (localBytes == null && bytes != null && settings.fanartProjectKey.isNotEmpty) {
          // Gallery retrieval runs after the first background is visible.
          // A slow additional download must never delay normal fanart.
          _fanart.getGallery(artist, settings.fanartProjectKey,
              personalKey: settings.fanartApiKey).then((gallery) {
            if (!mounted || request != _fanartRequest ||
                _fanartArtist != artist || gallery.length < 2) return;
            _fanartGallery = gallery;
            _fanartGalleryIsLocal = false;
            _fanartGalleryIndex = 0;
            _startFanartCycle();
          }).catchError((Object error) {
            debugPrint('VYBE fanart gallery unavailable: $error');
          });
        }
      }
    } catch (e) {
      if (mounted && request == _fanartRequest && _fanartArtist == artist) {
        _fanartLastFailure = DateTime.now();
        _scheduleFanartRetry(artist);
        setState(() => _fanartBytes = null);
        debugPrint('VYBE fanart lookup failed for $artist: $e');
      }
    } finally {
      if (_fanartLoadingArtist == artist) _fanartLoadingArtist = '';
    }
  }

  /// Normalized Golden Hour environment light position. This is NOT the
  /// origin for artwork-attached FX (rays, bass ripples or shockwaves).
  /// Other premium scenes retain their own native lighting coordinates.
  Offset _goldenHourLightOrigin() {
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < size.height * 1.3;
    final swapped = settings.layoutSwap;
    switch (settings.theme) {
      case 4: // Drive: sun radiates from behind the record / cover.
        return narrow ? const Offset(.50, .26)
            : Offset(.26, .65);
      case AppSettings.tTypo: // A little above the headline.
        return narrow ? const Offset(.50, .20)
            : Offset(swapped ? .72 : .28, .25);
      case AppSettings.tRecord: // Vinyl/Record Cut: clear of large disc.
        return narrow ? const Offset(.50, .82)
            : Offset(swapped ? .84 : .16, .60);
      case 1: // Side by Side
      case 3: // Edge to Edge
        return narrow ? const Offset(.50, .72)
            : Offset(swapped ? .27 : .73, .60);
      case AppSettings.tEditorial: // Muzine: away from the sleeve.
        return narrow ? const Offset(.50, .73)
            : Offset(swapped ? .27 : .73, .66);
      case AppSettings.tFan:
        return narrow ? const Offset(.50, .70)
            : Offset(swapped ? .30 : .70, .52);
      case AppSettings.tDiagonal:
        return narrow ? const Offset(.50, .66)
            : Offset(swapped ? .30 : .70, .66);
      default:
        return const Offset(.515, .69);
    }
  }

  /// Active premium scenes with stable selection IDs. Rave was retired:
  /// preserve Neon Club's ID (19) instead of shifting all saved choices.
  Widget _premiumAnimatedBackground(double motion) {
    const sceneAssets = <String>[
      'shaders/golden_hour.frag',
      'shaders/neon_ribbons.frag',
      'shaders/club_stage.frag',
      'shaders/lightstorm.frag',
      'shaders/neon_club.frag',
    ];
    final selected = AppSettings.premiumSceneIds.indexOf(settings.cinematicPalette);
    final sceneIndex = selected < 0 ? 2 : selected;
    // Give each environment its own lighting identity.
    const scenePalettes = <ArtPalette>[
      ArtPalette(Color(0xFFFFC76B), Color(0xFFFF8A35), Color(0xFFFFE0A1)),
      ArtPalette(Color(0xFF00E7FF), Color(0xFFFF36A8), Color(0xFF665CFF)),
      ArtPalette(Color(0xFF00AFFF), Color(0xFFFF2B70), Color(0xFF83E9FF)),
      ArtPalette(Color(0xFF436BFF), Color(0xFFFF214F), Color(0xFFAD4CFF)),
      ArtPalette(Color(0xFFFFB836), Color(0xFFE843EE), Color(0xFF18DEFF)),
    ];
    // Use the decoded artwork's palette, regardless of the UI accent palette.
    // Hold the last successful colors briefly across MediaSession track swaps.
    final albumPalette = model.art?.palette ?? _lastArtPalette ?? ArtPalette.fallback;
    return RepaintBoundary(child: GoldenHourBackground(
      key: ValueKey(sceneAssets[sceneIndex]),
      time: _time,
      motion: motion,
      palette: settings.animationUseAlbumColors ? albumPalette : scenePalettes[sceneIndex],
      bass: sim.bass,
      // Read the live bass on every shader repaint, not a stale build-time value.
      bassSample: () => model.playing ? sim.bass : 0.0,
      lightOrigin: sceneIndex == 0 ? _goldenHourLightOrigin() : null,
      shaderAsset: sceneAssets[sceneIndex],
    ));
  }

  /// Lightweight animated neon backdrop for the idle player. The portrait and
  /// landscape splash illustrations remain exclusive to startup so their
  /// baked-in lettering never competes with live track information.
  Widget _edgyStandbyBackground() => AnimatedBuilder(
    animation: _slow,
    builder: (context, _) => CustomPaint(
      painter: _EdgyStandbyPainter(
        time: _time,
        bass: sim.bass,
        motion: settings.templateBackgroundMotion,
      ),
      child: const SizedBox.expand(),
    ),
  );

  Widget _background() {
    if (!model.active && !widget.driveHost) {
      return _edgyStandbyBackground();
    }
    if (!widget.driveHost &&
        (settings.theme == AppSettings.tCinematic ||
         settings.theme == AppSettings.tEditorial)) {
      return _cinematicBackdrop();
    }
    if (settings.backgroundSource == 1) {
      return _premiumAnimatedBackground(settings.templateBackgroundMotion);
    }
    return _albumBackdrop();
  }

  /// Keep Cinematic fanart visible beneath the optional club/laser lights.
  Widget _cinematicLightShow() {
    const blends = <BlendMode>[
      BlendMode.srcOver, BlendMode.plus, BlendMode.screen,
      BlendMode.lighten, BlendMode.overlay, BlendMode.softLight,
      BlendMode.difference, BlendMode.exclusion,
      BlendMode.colorDodge, BlendMode.hardLight,
    ];
    return IgnorePointer(child: RepaintBoundary(
      child: AnimatedBuilder(
        animation: _slow,
        builder: (context, _) => CustomPaint(
          painter: settings.backgroundSource >= 4
            ? LaserTunnelBackgroundPainter(
                palette: _clubPalette, time: _time,
                transparentStage: true,
                motion: settings.templateBackgroundMotion,
                darkness: 0.0,
                lightingBlend: blends[settings.clubBlendMode.clamp(0, 9)])
            : ClubBackgroundPainter(
                palette: _clubPalette, time: _time,
                transparentStage: true,
                motion: settings.templateBackgroundMotion,
                darkness: 0.0,
                lightingBlend: blends[settings.clubBlendMode.clamp(0, 9)]),
          child: const SizedBox.expand(),
        ),
      ),
    ));
  }

  Widget _albumBackdrop() {
    if ((settings.backgroundSource == 6 ||
        (settings.backgroundSource == 0 && settings.fanartMode == 1)) &&
        _fanartBytes != null) {
      Widget fanart = Stack(fit: StackFit.expand, children: [
        // Fanart was unblurred before this setting. Keep that original look
        // at the default value while allowing additional softening.
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: (settings.bgBlur - 6.0).clamp(0.0, 12.0).toDouble(),
            sigmaY: (settings.bgBlur - 6.0).clamp(0.0, 12.0).toDouble(),
            tileMode: TileMode.clamp),
          child: Image.memory(_fanartBytes!, fit: BoxFit.cover, gaplessPlayback: true,
            filterQuality: FilterQuality.low),
        ),
        // Independent fanart darkness for themes using artist photos.
        ColoredBox(color: Colors.black.withOpacity(
          settings.cinematicDarkness.clamp(0.0, 1.0))),
      ]);
      if (settings.bgEffects) {
        fanart = FxComposite(
          mode: settings.fxBlendMode['Background Motion'] ?? 0,
          opacity: settings.fxBlendOpacity['Background Motion'] ?? 1.0,
          child: _drift(fanart, speed: settings.cinematicAnimationSpeed * 2.5));
      }
      return fanart;
    }
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
              animate: true,
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
                sigmaX: settings.bgBlur, sigmaY: settings.bgBlur, tileMode: TileMode.clamp),
            child: RawImage(
              image: art.tiny,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.high,
            ),
          ),
        ),
      );
      if (settings.bgEffects) {
        blurred = FxComposite(
          mode: settings.fxBlendMode['Background Motion'] ?? 0,
          opacity: settings.fxBlendOpacity['Background Motion'] ?? 1.0,
          child: _drift(blurred));
      }
      child = SizedBox.expand(
        key: ValueKey(art),
        child: Stack(
          fit: StackFit.expand,
          children: [
            blurred,
            // Same single user-controlled darkness layer as fanart.

          ],
        ),
      );
    }
    return ClipRect(child: SizedBox.expand(child: AnimatedSwitcher(
        layoutBuilder: (currentChild, previousChildren) => Stack(
          fit: StackFit.expand,
          children: [...previousChildren, if (currentChild != null) currentChild]),
        duration: const Duration(milliseconds: 800), child: child)));
  }

  /// Slow pan and zoom. The blurred image is cached, so this only moves a
  /// finished layer around.
  Widget _drift(Widget child, {double speed = 1.0}) {
    return AnimatedBuilder(
      animation: _tick,
      child: child,
      builder: (context, c) {
        final size = MediaQuery.of(context).size;
        final m = settings.kMotion;
        final motionSize = settings.fxSize['Background Motion'] ?? 1.0;
        final dx = math.sin(_time * 0.08 * speed) * size.width * 0.085 * m * motionSize;
        final dy = math.cos(_time * 0.06 * speed) * size.height * 0.075 * m * motionSize;
        return Transform.translate(
          offset: Offset(dx, dy),
          child: Transform.scale(
            // Overscan must cover the maximum pan in both axes, otherwise
            // the top/right edges can expose empty strips during motion.
            scale: 1.0 + math.max(0.28 * motionSize.abs(),
                0.24 * m.abs() * motionSize.abs()),
            child: c),
        );
      },
    );
  }

  // Never start a GPU-heavy scene while artwork is pending unless the user
  // explicitly selected Animated Background as the fanart fallback.
  Widget _cinematicAnimatedFallback() =>
      settings.fanartFallbackSource == 1
          ? _premiumAnimatedBackground(settings.templateBackgroundMotion)
          : const ColoredBox(color: Color(0xFF10121B));

  Widget _cinematicBackdrop() => AnimatedBuilder(
    animation: _slow,
    builder: (context, _) => _buildCinematicBackdrop(),
  );

  Widget _buildCinematicBackdrop() {
    final fanart = _fanartBytes;
    final art = model.art;
    final hasAlbum = art != null && !art.flat;
    // Fanart first unless explicitly overridden. The two options below are
    // FALLBACKS when fanart is missing, not competing fanart sources.
    final showFanart = !settings.fanartOverride && fanart != null;
    final useAlbum = !showFanart &&
        settings.fanartFallbackSource == 0 && hasAlbum;
    final hasImage = showFanart || useAlbum;
    final Widget background = showFanart
        ? Image.memory(fanart, fit: BoxFit.cover,
            alignment: Alignment.topCenter, gaplessPlayback: true)
        : useAlbum
            ? RawImage(image: art.tiny, fit: BoxFit.cover)
            : _cinematicAnimatedFallback();
    final image = hasImage
        ? ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: settings.cinematicBlur + (useAlbum ? 6.0 : 0.0),
              sigmaY: settings.cinematicBlur + (useAlbum ? 6.0 : 0.0)),
            child: ColorFiltered(
              colorFilter: _contrastFilter(settings.cinematicContrast),
              child: background))
        : ColorFiltered(
            colorFilter: _contrastFilter(settings.cinematicContrast),
            child: background);
    // Bigfan/Muzine fanart must respond to Background Motion; only the
    // cached image moves, leaving album sleeve, vinyl and info stationary.
    final movingImage = showFanart && settings.bgEffects &&
            settings.cinematicAnimationSpeed > 0
        ? _drift(RepaintBoundary(child: image),
            speed: settings.cinematicAnimationSpeed * 2.5)
        : image;
    // Muzine portrait hides the upper fifth behind its album-art backing.
    // Start fanart at the actual horizontal divider instead of fitting it
    // across the unseen area above: people's heads are no longer cropped
    // away behind the top artwork panel. Do not affect landscape or Bigfan.
    final viewport = MediaQuery.sizeOf(context);
    final muzinePortraitFanart = showFanart &&
        settings.theme == AppSettings.tEditorial &&
        viewport.height > viewport.width * 1.1;
    final fanartTop = muzinePortraitFanart ? viewport.height * .20 : 0.0;
    return Stack(fit: StackFit.expand, children: [
      Positioned.fill(
        top: fanartTop,
        child: ClipRect(child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 700),
          child: SizedBox.expand(
            key: ValueKey(showFanart ? 'fanart:${_fanartArtist}:$_fanartGalleryIndex' :
                useAlbum ? 'cinematic-album:${model.artist}:${model.album}' :
                'cinematic-template:${settings.cinematicPalette}'),
            child: movingImage))),
      ),
      // A blurred copy of the artwork, masked to the outer edges.
      // The middle stays sharp and the blur fades inward smoothly.
      if (hasImage)
        Positioned.fill(
          top: fanartTop,
          child: ClipRect(child: IgnorePointer(child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) => const LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              stops: [0.0, .22, .35, .65, .78, 1.0],
              colors: [Colors.white, Colors.transparent, Colors.transparent,
                Colors.transparent, Colors.transparent, Colors.white],
            ).createShader(bounds),
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: SizedBox.expand(child: showFanart
                  ? Image.memory(fanart, fit: BoxFit.cover,
                      alignment: Alignment.topCenter, gaplessPlayback: true)
                  : RawImage(image: art?.tiny, fit: BoxFit.cover)),
            ),
          ))),
        ),
      // Shared fanart darkness, independent of the intentional bottom fade.
      ColoredBox(color: Colors.black.withOpacity(
        settings.cinematicDarkness.clamp(0.0, 1.0))),
      // Cinematic's deliberate bottom-to-transparent readability fade is
      // independent of the user-controlled full-screen darkness overlay.
      // Limit it to the lower portion so the rest of the fanart stays clear.
      IgnorePointer(child: Align(
        alignment: Alignment.bottomCenter,
        child: FractionallySizedBox(
          widthFactor: 1.0,
          heightFactor: .42,
          child: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                stops: [0.0, .36, 1.0],
                colors: [
                  Color(0xFF000000),
                  Color(0xB0000000),
                  Color(0x00000000),
                ],
              ),
            ),
          ),
        ),
      )),

    ]);
  }

  // Muzine and Bigfan both use 84% of portrait width for song details.
  // Keep their artist, song, and album font sizes identical.
  static const double _portraitFeatureArtistRatio = .067;
  // Consistent readable typography floor for every Now Playing theme:
  // artist remains the headline; song text outranks the album label.
  static const double _portraitFeatureTitleRatio = .042;
  static const double _portraitFeatureAlbumRatio = .021;
  static const double _landscapeSongMinRatio = .065;
  static const double _landscapeAlbumMaxRatio = .025;
  // Artist fallback lettering is a headline on every theme, not just
  // Focused. Keep one orientation-specific minimum independent of layout.
  static const double _landscapeArtistMinRatio = .112;
  static const double _portraitArtistMinRatio = .073;

  double _artistFontSize(double requested) {
    final screen = MediaQuery.sizeOf(context);
    final portrait = screen.height > screen.width * 1.1;
    return math.max(requested, screen.height *
        (portrait ? _portraitArtistMinRatio : _landscapeArtistMinRatio))
        .toDouble();
  }

  double _songFontSize(double requested) {
    final screen = MediaQuery.sizeOf(context);
    final portrait = screen.height > screen.width * 1.1;
    final floor = screen.height *
        (portrait ? _portraitFeatureTitleRatio : _landscapeSongMinRatio);
    // This floor never lowers themes that deliberately use larger type.
    return math.max(requested, floor).toDouble();
  }

  double _albumFontSize(double requested) {
    final screen = MediaQuery.sizeOf(context);
    final portrait = screen.height > screen.width * 1.1;
    // All themes share the exact album-label font size for this orientation.
    // Length affects scroll distance, NEVER type size or frame scaling.
    return screen.height *
        (portrait ? _portraitFeatureAlbumRatio : _landscapeAlbumMaxRatio);
  }

  /// Editorial: an angled, recognizable album sleeve over full-bleed
  /// artist photography. Both orientations have their own composition.
  /// Editorial: full-bleed fanart, a grayscale album-art backing and a
  /// separate rotated color sleeve. The two orientations are art-directed.
  Widget _editorialLayout(double w, double h) {
    final portrait = h > w * 1.1;
    final flipped = settings.layoutSwap && !portrait;
    Widget readable(Widget child) => flipped
        ? Transform(alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(-1, 1, 1), child: child)
        : child;
    final accent = _palette.a;
    final art = model.art;
    final hasCover = art != null && !art.flat;
    final sleeveSize = portrait ? w * .89 : h * .86;
    final sleeveCenterX = portrait ? w * .48 : w * .235 - sleeveSize * .707;
    // The landscape sleeve's right-hand diamond tip sits just ABOVE the
    // visualizer (which begins at h * .78). It is not anchored mid-screen.
    final sleeveCenterY = portrait ? h * .275 - sleeveSize * .707 : h * .72;
    final musiczineVinylSize = portrait ? sleeveSize * .83 : sleeveSize * .76;
    // Center the vinyl on the MIDPOINT of the appropriate diamond edge,
    // not toward a corner. The sleeve is rotated 45 degrees, so the
    // midpoints of its diagonal edges are at (+/- .3536, +/- .3536)
    // times the original square side. Pull the record center slightly
    // inside the sleeve so its label stays covered, leaving roughly
    // half the disc exposed. Natural screen clipping is intentional.
    // Landscape: upper-right edge. Portrait: lower-left edge.
    // Portrait needs a little more tuck so the visible vinyl stays aligned
    // with the diagonal sleeve's leading edge rather than hanging below it.
    final vinylEdgeInset = portrait ? .090 : .055;
    final vinylEdgeOffset = .3535533905932738 - vinylEdgeInset;
    final musiczineVinylCenterX =
        sleeveCenterX + sleeveSize * (portrait ? -vinylEdgeOffset : vinylEdgeOffset);
    final musiczineVinylCenterY =
        sleeveCenterY + sleeveSize * (portrait ? vinylEdgeOffset : -vinylEdgeOffset);
    final musiczineVinylX = musiczineVinylCenterX - musiczineVinylSize * .5;
    final musiczineVinylY = musiczineVinylCenterY - musiczineVinylSize * .5;
    // The sleeve must use full-resolution artwork. art.tiny is a 96px
    // palette/background thumbnail and becomes visibly pixelated here.
    final cover = hasCover
        ? Image.memory(art.bytes, fit: BoxFit.cover,
            gaplessPlayback: true, filterQuality: FilterQuality.high)
        : Image.asset('assets/vybe_album_placeholder.png', fit: BoxFit.cover);
    // The enlarged monochrome album artwork is a SECOND visual layer behind
    // the diagonal cover, not the artist fanart and not an empty black wedge.
    final backing = Stack(fit: StackFit.expand, children: [
      if (hasCover)
        ColorFiltered(
          colorFilter: const ColorFilter.matrix(<double>[
            .2126,.7152,.0722,0,0,
            .2126,.7152,.0722,0,0,
            .2126,.7152,.0722,0,0,
            0,0,0,1,0,
          ]),
          child: Transform.scale(
            scale: 1.7,
            child: readable(RawImage(image: art.tiny, fit: BoxFit.cover,
              filterQuality: FilterQuality.high)))),
      // Deepen only the grayscale backing, leaving the cover and fanart untouched.
      const ColoredBox(color: Color(0x99000000)),
    ]);
    final sleeve = Transform.rotate(
      // The flipped composition counter-mirrors the artwork to keep album
      // typography readable. Its rotation must also reverse so the sleeve's
      // top edge angles toward the record on the mirrored side.
      angle: (portrait || flipped) ? -math.pi / 4 : math.pi / 4,
      child: Container(
        width: sleeveSize, height: sleeveSize,
        decoration: BoxDecoration(
          color: const Color(0xFF080C10),
          borderRadius: BorderRadius.circular(sleeveSize * .065),
          border: Border.all(color: accent.withOpacity(.85), width: 2),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(.83),
              offset: Offset(portrait ? 0 : 12, portrait ? 12 : 11), blurRadius: 19),
            BoxShadow(color: accent.withOpacity(.23),
              offset: Offset(portrait ? 0 : 5, portrait ? 5 : 4), blurRadius: 9),
          ],
        ),
        child: ClipRRect(borderRadius: BorderRadius.circular(sleeveSize * .061),
          child: portrait
            // The record emerges from the lower-left diagonal sleeve edge.
            // Turn the COVER'S TOP toward that opening. Its former 180-degree
            // rotation pointed the top away from the vinyl in portrait.
            ? Transform.rotate(angle: -math.pi / 2, child: cover)
            : cover),
      ),
    );
    final artist = model.active ? model.artist.toUpperCase() : 'START MUSIC IN ANY PLAYER APP';
    final song = model.title.isEmpty ? 'Nothing playing' : model.title;
    final titleStyle = TextStyle(
      fontFamily: 'VYBERiot',
      fontFamilyFallback: const ['Roboto'],
      color: Colors.white, fontSize: portrait ? w * .070 : h * .078,
      fontWeight: FontWeight.w400, letterSpacing: portrait ? -w * .015 : -h * .018,
      shadows: _artistNeonShadows);
    // Muzine and Bigfan use the same shared portrait branding renderer,
    // including the user's clearlogo-size setting.
    final songStyle = TextStyle(
      color: Colors.white,
      fontSize: _songFontSize(
          portrait ? h * _portraitFeatureTitleRatio : h * _landscapeSongMinRatio),
      shadows: const [Shadow(color: Colors.black, blurRadius: 8),
        Shadow(color: Colors.black, blurRadius: 16, offset: Offset(1, 2))]);
    final composition = Stack(fit: StackFit.expand, children: [
      // Muzine shares Bigfan's fanart darkness slider. Zero adds no
      // overall dimming, but the theme's bottom readability fade remains.
      Positioned.fill(child: IgnorePointer(child: ColoredBox(
        color: Colors.black.withOpacity(
          settings.cinematicDarkness.clamp(0.0, 1.0))))),
      if (portrait) ...[
        Positioned(left: 0, right: 0, top: 0, height: h * .20,
          child: ClipRect(child: backing)),
        Positioned(left: 0, right: 0, top: h * .20,
          child: Container(height: 2, decoration: BoxDecoration(
            color: accent.withOpacity(.88),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(.68),
              offset: const Offset(0, 4), blurRadius: 8, spreadRadius: 2)]))),
        // A black gradient falls away from the divider behind the portrait
        // visualizer, preserving contrast without obscuring the lower fanart.
        Positioned(left: 0, right: 0, top: h * .20, height: h * .145,
          child: const IgnorePointer(child: DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Color(0xB8000000), Color(0x65000000), Color(0x00000000)],
              stops: [0.0, .38, 1.0]))))),
        Positioned(left: 0, right: 0, bottom: 0, height: h * .31,
          child: const DecoratedBox(decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xFF000000), Color(0x00000000)])))),
      ] else ...[
        Positioned(left: 0, top: 0, bottom: 0, width: w * .20,
          child: ClipRect(child: backing)),
        Positioned(left: w * .198, top: 0, bottom: 0,
          child: Container(width: 3, decoration: BoxDecoration(
            color: accent.withOpacity(.85),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(.68),
              offset: const Offset(5, 0), blurRadius: 9, spreadRadius: 2)]))),
        // Musiczine landscape's intentional bottom readability fade.
        // Independent of Background darkness, just like portrait.
        Positioned(left: 0, right: 0, bottom: 0, height: h * .36,
          child: const IgnorePointer(child: DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              stops: [0.0, .38, 1.0],
              colors: [
                Color(0xE6000000),
                Color(0x96000000),
                Color(0x00000000),
              ],
            )),
          ))),
      ],
      if (portrait) ...[
        // Full-width artist branding, followed by vertically stacked metadata.
        Positioned(left: w * .08, right: w * .08, bottom: h * .046,
          child: Column(crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min, children: [
              // Use exactly the same artist/clearlogo rendering and font
              // ratio as Bigfan; only their artwork compositions differ.
              _artist(h * _portraitFeatureArtistRatio, Alignment.center, false),
              SizedBox(height: h * .006),
              SongTitleMarquee(
                title: song, alignment: Alignment.center, style: songStyle,
                animation: _tick, elapsedSeconds: () => _time),
              if (_showAlbumLabel) ...[
                SizedBox(height: h * .006),
                Align(alignment: Alignment.center,
                  child: _albumText(h * _portraitFeatureAlbumRatio)),
              ],
            ])),
        if (_hasLyrics)
          Positioned(left: w * .08, right: w * .08, top: h * .50,
            height: h * .17,
            child: _lyricBlock(h, Alignment.center, vhs: false)),
      ] else ...[
        // Landscape Muzine: the artist/logo, song and album must live
        // together. The earlier split positioning left the artist near the
        // left divider and the title disconnected at the far right.
        Positioned(right: w * .04, top: h * .055, width: w * .56,
          child: readable(Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: flipped
                ? CrossAxisAlignment.start : CrossAxisAlignment.end,
            children: [
              if (settings.useArtistClearLogo &&
                  _clearLogoBytes != null && model.active)
                SizedBox(width: w * .44, height: h * .19,
                  child: _scaledClearLogo(alignment: flipped
                      ? Alignment.centerLeft : Alignment.centerRight))
              else
                _artist(h * .085,
                  flipped ? Alignment.centerLeft : Alignment.centerRight,
                  false),
              SizedBox(height: h * .009),
              SongTitleMarquee(
                title: song,
                alignment: flipped ? Alignment.centerLeft : Alignment.centerRight,
                style: songStyle,
                animation: _tick, elapsedSeconds: () => _time),
              if (_showAlbumLabel) ...[
                SizedBox(height: h * .008),
                _albumText(songStyle.fontSize! * .39,
                  flushFrame: flipped ? Alignment.centerLeft
                      : Alignment.centerRight),
              ],
            ]))),
        if (_hasLyrics)
          Positioned(left: w * .37, right: w * .06, top: h * .43,
            height: h * .19,
            child: readable(_lyricBlock(h, Alignment.center, vhs: false))),
      ],
      // Same Record Cut disc and playback-driven inertia, layered behind
      // the diagonal sleeve. The Stack clips naturally at screen edges.
      Positioned(left: musiczineVinylX, top: musiczineVinylY,
        width: musiczineVinylSize, height: musiczineVinylSize,
        child: IgnorePointer(child: _vinyl(musiczineVinylSize))),
      if (settings.visualizer)
        if (portrait)
          // The divider is the waveform's origin. Draw downward from it,
          // beneath the angled sleeve and without any mirrored reflection.
          Positioned(left: 0, right: 0, top: h * .20,
            height: h * .082,
            child: IgnorePointer(child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.diagonal3Values(1, -1, 1),
              child: CustomPaint(
                painter: BarsPainter(
                  sim: sim, palette: _palette,
                  count: settings.barCount,
                  gain: settings.sensitivity,
                  style: settings.cinematicWaveStyle,
                  baseFrac: 1.0,
                  repaint: _tick)))))
        else
          Positioned(left: w * .20, right: w * .035,
            bottom: h * .07, height: h * .15,
            child: IgnorePointer(child: CustomPaint(
              painter: BarsPainter(
                sim: sim, palette: _palette,
                count: settings.barCount,
                style: settings.cinematicWaveStyle,
                gain: settings.sensitivity, repaint: _tick)))),
      Positioned(
        left: sleeveCenterX - sleeveSize * .5,
        top: sleeveCenterY - sleeveSize * .5,
        width: sleeveSize, height: sleeveSize,
        child: GestureDetector(onTap: _openPlayer, child: readable(sleeve))),
    ]);
    return flipped ? Transform(alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1, 1, 1), child: composition)
        : composition;
  }

  Widget _cinematicLayout(double w, double h) {
    final portrait = h > w * 1.1;
    final coverSize = portrait ? math.min(w * 0.22, h * 0.15) :
        math.min(h * 0.22, w * 0.16);
    final textWidth = portrait ? w * 0.57 : w * 0.34;
    final titleSize = portrait ? w * 0.052 : h * 0.065;
    final swap = settings.layoutSwap && !portrait;
    final textAlign = swap ? Alignment.centerRight : Alignment.centerLeft;
    final details = SizedBox(width: textWidth, child: Column(
      crossAxisAlignment: swap ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min, children: [
        _artist(titleSize * 1.35, textAlign, false),
        SizedBox(height: h * 0.008),
        _title(titleSize, textAlign, false),
        SizedBox(height: h * 0.008),
        if (_showAlbumLabel)
          Align(alignment: textAlign,
            child: _albumText(titleSize * .7)),
      ]));
    final cover = GestureDetector(
      key: _artKey,
      behavior: HitTestBehavior.opaque,
      onTap: _openPlayer, child: _artCard(coverSize));
    final spacing = SizedBox(width: portrait ? w * 0.025 : w * 0.018);
    final info = Row(mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: swap ? [details, spacing, cover] : [cover, spacing, details]);
    final waveHeight = portrait ? h * 0.14 : h * 0.25;
    final wave = settings.visualizer ? IgnorePointer(child: CustomPaint(
      painter: BarsPainter(sim: sim, palette: _palette,
        count: settings.barCount,
        style: settings.cinematicWaveStyle,
        gain: settings.sensitivity, repaint: _tick))) :
        const SizedBox.shrink();
    return Stack(children: [
      if (portrait) ...[
        if (_hasLyrics) Positioned(
          left: w * 0.07, right: w * 0.07,
          top: h * 0.32, height: h * 0.17,
          child: _lyricBlock(h, Alignment.center, vhs: false)),
        // Big Fan portrait: stack the album cover above centered metadata.
        // The waveform remains independently anchored at the bottom.
        Positioned(left: w * .08, right: w * .08,
          bottom: h * .205,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            GestureDetector(key: _artKey, onTap: _openPlayer,
              // Approximately as wide as the prominent artist wordmark.
              child: _artCard(math.min(w * .64, h * .34))),
            SizedBox(height: h * .014),
            SizedBox(width: w * .84,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _artist(h * _portraitFeatureArtistRatio, Alignment.center, false),
                SizedBox(height: h * .008),
                _title(h * _portraitFeatureTitleRatio, Alignment.center, false),
                if (_showAlbumLabel) ...[
                  SizedBox(height: h * .006),
                  _fixedAlbum(h * _portraitFeatureAlbumRatio, Alignment.center),
                ],
              ])),
          ])),
        Positioned(left: w * 0.02, right: w * 0.02,
          bottom: h * 0.035, height: waveHeight, child: wave),
      ] else ...[
        if (_hasLyrics) Positioned(
          left: w * 0.22, right: w * 0.22,
          top: h * 0.31, height: h * 0.30,
          child: _lyricBlock(h * 1.5, Alignment.center, vhs: false)),
        Positioned(left: swap ? null : w * 0.02,
          right: swap ? w * 0.02 : null,
          bottom: h * 0.035, child: info),
        Positioned(left: swap ? w * 0.025 : w * 0.43,
          right: swap ? w * 0.43 : w * 0.025,
          bottom: h * 0.035, height: waveHeight, child: wave),
      ],
    ]);
  }

  /// Shared clock label for the playback-controls overlay.
  String _clockLabel() {
    final now = DateTime.now();
    final hour = settings.clock24h ? now.hour : (now.hour % 12 == 0 ? 12 : now.hour % 12);
    return '${hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}${settings.clock24h ? '' : (now.hour < 12 ? ' AM' : ' PM')}';
  }


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
    final tier = settings.fxPerformanceMode == 2 ? 2 : settings.fxPerformanceMode == 1 ? 0 : _fxTier;
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
        effectSize: settings.fxSize[name] ?? 1.0,
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
      // Keep the FX canvas full-screen. Scaling the widget itself exposes
      // its rectangular bounds when Size drops below 100%.
      final fullCanvas = name == 'Aurora Sweep' || name == 'Moving Bokeh';
      return IgnorePointer(child: fullCanvas
        ? RepaintBoundary(child: CustomPaint(
            key: layerKey,
            painter: _FxBlendPainter(painter, blend, opacity),
          ))
        : Transform.scale(
            scale: 1.18 * size,
            child: RepaintBoundary(child: CustomPaint(
              key: layerKey,
              painter: _FxBlendPainter(painter, blend, opacity),
            )),
          ));
    }
    // Budget optional layers without changing the user's saved FX choices.
    // Auto responds to observed frame timings; Performance always uses the
    // conservative budget. Maximum preserves every selected layer.
    final tier = settings.fxPerformanceMode == 2 ? 2
        : (settings.performance || settings.fxPerformanceMode == 1) ? 0 : _fxTier;
    final maxLayers = tier == 0 ? 2 : tier == 1 ? 4 : 100;
    final layers = <Widget>[
      for (var i = 0; i < AppSettings.extraFxNames.length; i++)
        if ((settings.extraFx[AppSettings.extraFxNames[i]] ?? false) &&
            // Distortion-only FX are rendered by the GPU backdrop shader.
            // Never draw their old decorative strokes or polygon outlines.
            !(ui.ImageFilter.isShaderFilterSupported &&
              (i == 0 || i == 3 || i == 5 || i == 9)))
          layer(AppSettings.extraFxNames[i], ExpandedFxPainter(mode: i, clock: fxClock, palette: p,
            artKey: i == 1 ? _artKey : null,
            layerKey: i == 1 ? _shockLayerKey : null,
            bassOnsets: i == 1 ? ripples : null,
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
        layer('Moving Bokeh', GlowPainter(
            clock: fxClock, palette: p, k: settings.kGlow,
            effectSize: settings.fxSize['Moving Bokeh'] ?? 1.0, repaint: _tick)),
      if (settings.fxSweep)
        layer('Aurora Sweep', SweepPainter(
            clock: fxClock, palette: p, k: settings.kSweep,
            effectSize: settings.fxSize['Aurora Sweep'] ?? 1.0, repaint: _tick)),
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
    return layers.take(maxLayers).toList();
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
            child: info,
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
    final barsMode = settings.focusedStyleFor(h > w * 1.1) == 1;
    final lyricSlot = _lyricTheme && settings.lyrics ? h * 0.05 : 0.0;
    final lyricGap = _lyricTheme && settings.lyrics ? _lyricGap(h) : 0.0;
    final textH = h * 0.14 + lyricSlot + lyricGap; // artist header is separate
    final wLimit = portrait ? (barsMode ? w * 0.76 : w * 0.54) : (barsMode ? w * 0.55 : w * 0.4);

    final double art;
    if (barsMode) {
      final avail = h * 0.77 - textH - h * 0.045; // artwork and reflection
      art = math.min(wLimit, avail / 1.28); // enlarged art without the ring
    } else {
      final avail = h * 0.77 - textH - h * 0.03;
      art = math.min(wLimit, avail / 1.72); // ring box is 1.72 x art
    }
    final outer = art * 0.86; // ring radius including the tallest bars

    final Widget top;
    if (barsMode) {
      top = _artWithReflection(art);
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
                  style: settings.diagonalWaveStyle,
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
          if (_showAlbumLabel)
            _shaded(_albumText(h * .028)),
          if (_lyricTheme && settings.lyrics) SizedBox(height: lyricGap),
          if (_lyricTheme && settings.lyrics)
            SizedBox(
              height: lyricSlot,
              child: _hasLyrics
                  ? Center(child: _lyricLine(h * 0.03, Alignment.center))
                  : null,
            ),
        ],
      ),
    );

    // Keep the artist visually dominant. Long names break at word
    // boundaries into two display-lettering lines rather than scaling down.
    final artistName = _artistStr.trim();
    final artistWords = artistName.split(RegExp(r'\s+'));
    final useTwoLines = model.active &&
        _clearLogoBytes == null &&
        artistWords.length > 1 &&
        artistName.length > (portrait ? 14 : 20);
    String firstLine = artistName;
    String secondLine = '';
    if (useTwoLines) {
      var bestSplit = 1;
      var bestDifference = 1 << 30;
      for (var i = 1; i < artistWords.length; i++) {
        final left = artistWords.take(i).join(' ');
        final right = artistWords.skip(i).join(' ');
        final difference = (left.length - right.length).abs();
        if (difference < bestDifference) {
          bestDifference = difference;
          bestSplit = i;
        }
      }
      firstLine = artistWords.take(bestSplit).join(' ');
      secondLine = artistWords.skip(bestSplit).join(' ');
    }
    // A clearlogo can use the full portrait header height; reserve a real
    // gap before the artwork instead of centering that tall logo on top of it.
    final hasArtistLogo = model.active &&
        settings.useArtistClearLogo && _clearLogoBytes != null;
    final artistHeader = SizedBox(
      width: w * (portrait ? .94 : .88),
      height: h * (portrait ? .20 : .25),
      child: Center(
        child: useTwoLines
            ? _compactRiotLines(
                [firstLine, secondLine],
                h * (portrait ? .061 : .073),
                Alignment.center,
                (line) => _artistText(h * (portrait ? .061 : .073),
                    letteringOverride: line),
              )
            : _artist(h * (portrait ? .10 : .115), Alignment.center, false),
      ),
    );

    if (portrait) {
      // Focused: lower the album/ring assembly and let its reflection extend
      // behind the song labels. Draw text last so it stays on top.
      final content = Stack(clipBehavior: Clip.none, children: [
        _focusedBottomBlend(h),
        Positioned(
          left: 0, right: 0,
          // Header is .20h high and artwork begins at .265h. Moving a
          // clearlogo to .045h keeps its full box above the cover (.245h).
          top: h * (hasArtistLogo ? .045 : (useTwoLines ? .080 : .105)),
          child: Center(child: artistHeader)),
        Positioned(
          left: 0, right: 0, top: h * 0.265,
          child: Center(child: FittedBox(
            fit: BoxFit.scaleDown, child: top)),
        ),
        Positioned(
          left: 0, right: 0, top: h * 0.79,
          child: Center(child: text),
        ),
      ]);
      if (!barsMode || !settings.visualizer) return content;
      final edge = w * 0.075;
      return Stack(children: [
        _focusedEdgeShadows(edge),
        Positioned(left: 0, top: 0, bottom: 0, width: edge,
          child: _edgeBars(edge, leftEdge: true)),
        Positioned(right: 0, top: 0, bottom: 0, width: edge,
          child: _edgeBars(edge, leftEdge: false)),
        Positioned.fill(child: content),
      ]);
    }

    // Landscape Focused: reserve the upper center for a readable artist logo.
    // Keep the album reflection behind (rather than above) the song info.
    // Paint the text last so it remains legible over the reflection.
    final centered = Stack(clipBehavior: Clip.none, children: [
      _focusedBottomBlend(h),
      Positioned(top: h * .025, left: 0, right: 0,
        child: Center(child: artistHeader)),
      Positioned(
        top: h * 0.32, left: 0, right: 0,
        child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: top)),
      ),
      Positioned(
        bottom: h * 0.035, left: 0, right: 0,
        child: Center(child: text),
      ),
    ]);
    if (!barsMode || !settings.visualizer) return centered;
    final edge = w * 0.115;
    return Stack(children: [
      _focusedEdgeShadows(edge),
      Positioned(left: 0, top: 0, bottom: 0, width: edge,
        child: _edgeBars(edge, leftEdge: true)),
      Positioned(right: 0, top: 0, bottom: 0, width: edge,
        child: _edgeBars(edge, leftEdge: false)),
      Positioned.fill(child: centered),
    ]);
  }

  // Feather the bottom edge of Focused's blurred artwork background instead
  // of leaving an abrupt dark seam at the screen boundary.
  Widget _focusedBottomBlend(double h) => Positioned(
    left: 0, right: 0, bottom: 0, height: h * 0.14,
    child: const IgnorePointer(child: DecoratedBox(
      decoration: BoxDecoration(gradient: LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [Color(0x00000000), Color(0x55000000), Color(0x00000000)],
        stops: [0.0, 0.48, 1.0])))),
  );

  /// Art on the left, text and bars on the right (Side by Side and VHS).
  /// The art card is centered on the screen. The bottom of the bars lines up
  /// with the bottom of the art, and the bar reflection lines up with the
  /// art reflection. Song info and lyrics sit above the bars.
  Widget _sideLayout(double w, double h, {required bool vhs}) {
    // Center the complete artist/title/album block in the space beside
    // the cover. Alignment is independent of which side the art occupies.
    final textAlignment = Alignment.center;
    final textCrossAlignment = CrossAxisAlignment.center;
    final s = math.min(h * 0.62, w * 0.36);
    final u = s / 0.62; // text scale: equals h unless the screen is narrow
    final artTop = (h - s) / 2;
    final artBottom = artTop + s;
    final barsMax = s * 0.40; // tallest bar
    final reflH = s * 0.28; // same height as the art's reflection
    final barsBox = barsMax + reflH;
    final children = <Widget>[
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
                  height: math.max(1.0, artBottom - barsMax - artTop),
                  child: Center(
                    // Give Riot lettering a finite width so long names wrap
                    // rather than laying out wider than the metadata panel.
                    child: SizedBox(
                      width: double.infinity,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: textCrossAlignment,
                        children: [
                          _artist(u * 0.087, textAlignment, vhs),
                          SizedBox(height: u * 0.009),
                          _fixedTitle(u * 0.044, textAlignment),
                          if (_showAlbumLabel) ...[
                            SizedBox(height: u * 0.006),
                            _fixedAlbum(u * 0.032, textAlignment),
                          ],
                          if (_hasLyrics) ...[
                            SizedBox(height: _lyricGap(u)),
                            _lyricBlock(u, textAlignment, vhs: vhs),
                          ],
                        ],
                      ),
                    ),
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
        // Balanced exterior padding; the metadata group is centered
        // within its own column rather than pushed against this edge.
        SizedBox(width: w * 0.05),
    ];
    return Row(children: settings.layoutSwap ? children.reversed.toList() : children);
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
    final showAlbum = _showAlbumLabel;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (settings.visualizer) _topBars(barsH),
        Positioned.fill(
          top: barsH,
          child: Center(
            child: SizedBox(
                width: cw,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Keep portrait metadata readable and artist-first,
                    // consistent with the other portrait artwork themes.
                    // Scale only the artwork, never the text column.
                    _artist(h * 0.071, Alignment.center, vhs),
                    SizedBox(height: h * 0.009),
                    _fixedTitle(h * 0.037, Alignment.center),
                    if (showAlbum) ...[
                      SizedBox(height: h * 0.008),
                      _fixedAlbum(h * 0.026, Alignment.center),
                    ],
                    SizedBox(height: gap),
                    _artWithReflection(s, vhs: vhs),
                    if (_hasLyrics) ...[
                      SizedBox(height: _lyricGap(h)),
                      _lyricBlock(h * 0.75, Alignment.center, vhs: vhs),
                    ],
                  ],
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
    return Rect.fromLTWH(w - m - cw, m, cw, h * 0.92);
  }

  /// The Drive theme. In the Drive window the map shows through the hole; in
  /// the normal VYBE window (after leaving Drive) the same screen is drawn
  /// with a framed box where the map would be, and tapping it starts Drive.
  Widget _driveLayout(double w, double h, bool narrow) {
    const swap = false;
    final hole = _driveHole(w, h, narrow);
    final host = widget.driveHost;

    if (narrow) {
      // Both the overlay and the standalone Drive view use the SAME map
      // boundary. Previously the info was sized for 50% of the screen while
      // the transparent map opening began at 44.5%, clipping the song title
      // underneath Google Maps on portrait devices.
      final mapClearance = h * .014;
      final topHeight = math.max(1.0, hole.top - mapClearance).toDouble();
      final safeTop = math.max(
        MediaQuery.of(context).viewPadding.top + 6.0, h * .018).toDouble();
      final bottomInset = h * .008;
      final hasLogo = settings.useArtistClearLogo &&
          _clearLogoBytes != null && model.active;
      final brandingHeight = math.min(h * .105, w * .24).toDouble();
      final songFontSize = h * .031;
      final songHeight = h * .053;
      final albumHeight = _showAlbumLabel ? h * .038 : 0.0;
      final brandArtGap = h * .006;
      final artSongGap = h * .009;
      final songAlbumGap = _showAlbumLabel ? h * .003 : 0.0;
      final reserved = brandingHeight + songHeight + albumHeight +
          brandArtGap + artSongGap + songAlbumGap;
      // Give album artwork all the space left AFTER both metadata labels
      // have been reserved. Never move or shrink the song title into the map.
      final artworkRoom = math.max(
          0.0, topHeight - safeTop - bottomInset - reserved).toDouble();
      final artSide = math.min(
          math.min(w * .48, h * .225), artworkRoom).toDouble();
      final top = SizedBox(
        height: topHeight,
        child: Padding(
          padding: EdgeInsets.only(top: safeTop, bottom: bottomInset),
          child: Column(mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(width: w * .86, height: brandingHeight,
                child: hasLogo
                    ? _scaledClearLogo()
                    : Center(child: _artist(
                        h * .058, Alignment.center, false))),
              SizedBox(height: brandArtGap),
              _driveArtwork(artSide),
              SizedBox(height: artSongGap),
              SizedBox(width: w * .90, height: songHeight,
                child: Center(child: _title(
                    songFontSize, Alignment.center, false))),
              if (_showAlbumLabel) ...[
                SizedBox(height: songAlbumGap),
                SizedBox(width: w * .90, height: albumHeight,
                  child: Center(child: _albumText(h * .018))),
              ],
            ],
          ),
        ),
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
    final d = math.min(infoW * 0.9, h * 0.33).toDouble();
    final reserve = settings.visualizer ? h * settings.driveBarsH * 0.75 : h * 0.03;
    final panel = Positioned(
      left: swap ? hole.right + m : 0,
      width: panelW,
      top: h * 0.11,
      bottom: reserve,
      child: Center(
        child: SizedBox(
            width: infoW,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Stable artist-first hierarchy, even while logo is loading.
                SizedBox(width: infoW * .9, height: h * .25,
                  child: settings.useArtistClearLogo && _clearLogoBytes != null && model.active
                    ? _scaledClearLogo()
                    : Center(child: _artist(h * 0.082, Alignment.center, false))),
                SizedBox(height: h * .008),
                _title(h * 0.05, Alignment.center, false),
                if (_showAlbumLabel) ...[
                  SizedBox(height: h * 0.008),
                  _shaded(_albumText(h * 0.02)),
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
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        panel,
        // No persistent Drive clock: it appears with the controls.
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
    // Drive's cover frame was hardcoded to brand pink/purple even when album
    // art had a different palette. Use the cover's own extracted colors.
    final artColors = art?.palette ?? _lastArtPalette ?? _palette;
    final radius = BorderRadius.circular(size * 0.018);
    return RepaintBoundary(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: radius,
          color: const Color(0xFF0B0B0F),
          border: Border.all(color: artColors.a.withOpacity(.65), width: 1),
          boxShadow: [BoxShadow(
            color: artColors.b.withOpacity(.24),
            blurRadius: size * 0.10,
          )],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: art == null || art.flat
              ? Image.asset('assets/vybe_album_placeholder.png', width: size, height: size, fit: BoxFit.cover)
              : Image.memory(
                  art.bytes,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (context, error, stackTrace) =>
                      Image.asset('assets/vybe_album_placeholder.png', width: size, height: size, fit: BoxFit.contain),
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
      right = w - hole.left;
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
                  child: Image.asset('assets/vybe_album_placeholder.png',
                     width: w, height: h, fit: BoxFit.cover),
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
    final swapped = settings.layoutSwap;
    final artPanel = SizedBox(
      width: w * 0.5,
      height: h,
      child: _edgeArt(w * 0.5, h),
    );
    // The bars stay against the inner edge of the artwork. Their direction
    // and gradient must mirror when the panels exchange sides.
    final barsPanel = SizedBox(
      width: w * 0.09,
      height: h,
      child: _edgeBars(w * 0.09, leftEdge: !swapped),
    );
    final textAlign = Alignment.center;
    final infoPanel = Expanded(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          swapped ? w * 0.04 : w * 0.02,
          h * 0.06,
          swapped ? w * 0.02 : w * 0.04,
          h * 0.06,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _artist(h * 0.098, textAlign, false),
            SizedBox(height: h * 0.012),
            _title(h * 0.08, textAlign, false),
            if (_showAlbumLabel) ...[
              SizedBox(height: h * 0.012),
              _shaded(_albumText(h * 0.026, flushFrame: textAlign)),
            ],
            if (_hasLyrics) ...[
              SizedBox(height: _lyricGap(h)),
              _lyricBlock(h, textAlign, vhs: false),
            ],
          ],
        ),
      ),
    );
    return Row(
      children: swapped
          ? [infoPanel, if (settings.visualizer) barsPanel, artPanel]
          : [artPanel, if (settings.visualizer) barsPanel, infoPanel],
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
                  style: settings.diagonalWaveStyle,
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
          child: Padding(
            // Keep the metadata visually centered in the lower panel,
            // with breathing room above the bottom screen edge.
            padding: EdgeInsets.only(top: h * 0.025, bottom: h * 0.045),
            child: Center(
            child: SizedBox(
                width: w * 0.84,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _artist(h * 0.073, Alignment.center, false),
                    SizedBox(height: h * 0.009),
                    _title(h * 0.037, Alignment.center, false),
                    if (_showAlbumLabel) ...[
                        SizedBox(height: h * 0.008),
                        _fixedAlbum(h * 0.026, Alignment.center),
                      ],
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

  /// Diagonal's cover-side backdrop is deliberately more recessed than the
  /// full-screen blur. Keep this separate from Record Cut's grayscale filter.
  static const _diagonalGrayDark = ColorFilter.matrix(<double>[
    .0765, .2575, .0260, 0, 0,
    .0765, .2575, .0260, 0, 0,
    .0765, .2575, .0260, 0, 0,
    0, 0, 0, 1, 0,
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
                  style: settings.diagonalWaveStyle,
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
                  style: settings.diagonalWaveStyle,
            count: settings.barCount,
            gain: settings.sensitivity,
            repaint: _tick,
          ),
        ),
      );

  /// A strip of vertical bars on a black shadow that is darkest at the screen
  /// (or art) edge and fades out as it goes inward, so the bars pop.
  // Full-height edge fades are siblings of the visualizer bars, not
  // overflowing children of a narrow edge box. This prevents hard seams
  // where the shadow was clipped at the edge-bar widget boundary.
  Widget _focusedEdgeShadows(double edge) => Positioned.fill(
    child: IgnorePointer(child: Stack(clipBehavior: Clip.none, fit: StackFit.expand, children: [
      Positioned(left: 0, top: -12, bottom: -12, width: edge * 2.8,
        child: const DecoratedBox(decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft, end: Alignment.centerRight,
            colors: [Color(0xE6000000), Color(0x99000000), Color(0x00000000)],
            stops: [0.0, .45, 1.0])))),
      Positioned(right: 0, top: -12, bottom: -12, width: edge * 2.8,
        child: const DecoratedBox(decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerRight, end: Alignment.centerLeft,
            colors: [Color(0xE6000000), Color(0x99000000), Color(0x00000000)],
            stops: [0.0, .45, 1.0])))),
    ])),
  );

  Widget _edgeBars(double edge, {required bool leftEdge}) {
    return SizedBox(
      width: edge,
      child: leftEdge ? _vBars() : _flipX(_vBars()),
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
                  ? Image.asset('assets/vybe_album_placeholder.png', width: lab, height: lab, fit: BoxFit.cover)
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
    // The full-screen background is already painted below the Record Cut
    // layout. An opaque disc here used to hide it behind a hard circular
    // boundary. With artist fanart active, keep the disc's subdued styling
    // but let the *same continuous background* show through its surface.
    final showFanartThroughDisc = false; // Keep grayscale artwork visible behind the record.
    if (showFanartThroughDisc) {
      return RepaintBoundary(
        child: Container(
          width: big,
          height: big,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0x77000000),
            border: Border.all(color: const Color(0xBB000000), width: rim),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.35),
                  blurRadius: d * 0.06),
            ],
          ),
        ),
      );
    }
    final Widget inner = ClipOval(
      child: art == null ? Image.asset('assets/vybe_album_placeholder.png', width: big, height: big, fit: BoxFit.cover)
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
        child: ClipOval(child: Stack(fit: StackFit.expand, children: [
          inner,
          const ColoredBox(color: Color(0xA6000000)),
        ])),
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
                  style: settings.diagonalWaveStyle,
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
              child: SizedBox(
                  width: w * 0.88,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _artist(h * 0.073, Alignment.center, false),
                      SizedBox(height: h * 0.009),
                      _title(h * 0.037, Alignment.center, false),
                      if (_showAlbumLabel) ...[
                        SizedBox(height: h * 0.008),
                        _fixedAlbum(h * 0.026, Alignment.center),
                      ],
                      if (_hasLyrics) ...[
                        SizedBox(height: _lyricGap(h)),
                        _lyricBlock(h * 0.75, Alignment.center, vhs: false),
                      ],
                    ],
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
    final rcx = settings.layoutSwap ? d * 0.64 : w - d * 0.64;
    final cx = settings.layoutSwap
        ? rcx + d / 2 + _discGap(d) - r * 1.35
        : rcx - d / 2 - _discGap(d) + r * 1.35;
    final cy = h / 2;
    final maxLen = d * 0.16;
    // Keep metadata outside the vinyl's actual bounds, with a visible gutter
    // in both normal and flipped landscape layouts.
    final recordGutter = math.max(24.0, w * 0.035);
    final metadataWidth = settings.layoutSwap
        ? w - w * 0.06 - (rcx + d / 2) - recordGutter
        : (rcx - d / 2) - w * 0.06 - recordGutter;
    return Stack(
      children: [
        ..._discStack(cx, cy, r, d, h, settings.layoutSwap ? 0 : math.pi),
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
          left: settings.layoutSwap ? null : w * 0.06,
          right: settings.layoutSwap ? w * 0.06 : null,
          width: math.max(1.0, metadataWidth),
          top: 0,
          bottom: 0,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _artist(h * 0.090, Alignment.center, false),
              SizedBox(height: h * 0.012),
              _title(h * 0.085, Alignment.center, false),
              if (_showAlbumLabel) ...[
                SizedBox(height: h * 0.012),
                _shaded(_albumText(h * 0.028)),
              ],
              if (_hasLyrics) ...[
                SizedBox(height: _lyricGap(h)),
                _lyricBlock(h, Alignment.center, vhs: false),
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
                      borderRadius: BorderRadius.circular(s * 0.018),
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
              child: SizedBox(
                  width: w * 0.9,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _fanCards(s),
                      SizedBox(height: h * 0.025),
                      _artist(h * 0.073, Alignment.center, false),
                      SizedBox(height: h * 0.009),
                      _title(h * 0.037, Alignment.center, false),
                      if (_showAlbumLabel) ...[
                        SizedBox(height: h * 0.008),
                        _fixedAlbum(h * 0.026, Alignment.center),
                      ],
                      if (_hasLyrics) ...[
                        SizedBox(height: _lyricGap(h)),
                        _lyricBlock(h * 0.75, Alignment.center, vhs: false),
                      ],
                    ],
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
    // Center metadata in the *actual remaining gap*: from the far edge of
    // the fanned sleeves to the inner edge of the visualizer. The previous
    // w*.61 minimum pushed text right and unnecessarily narrowed its marquee.
    final textLeft = fanLeftInset + s * 1.45 + w * .014;
    final textRight = (settings.visualizer ? edge : 0.0) + w * .014;
    return Stack(
      children: [
        Positioned.fill(child: _bottomArtworkFade()),
        Positioned(left: settings.layoutSwap ? null : fanLeftInset, right: settings.layoutSwap ? fanLeftInset : null, top: (h - s * 1.25) / 2, child: _fanCards(s)),
        if (settings.visualizer)
          Positioned(
            left: settings.layoutSwap ? 0 : null,
            right: settings.layoutSwap ? null : 0,
            top: 0,
            bottom: 0,
            width: edge,
            child: _edgeBars(edge, leftEdge: settings.layoutSwap),
          ),
        Positioned(
          left: settings.layoutSwap ? textRight : textLeft,
          right: settings.layoutSwap ? textLeft : textRight,
          top: 0,
          bottom: 0,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _artist(h * 0.090, Alignment.center, false),
              SizedBox(height: h * 0.012),
              _title(h * 0.085, Alignment.center, false),
              if (_showAlbumLabel) ...[
                SizedBox(height: h * 0.012),
                _shaded(_albumText(h * 0.028)),
              ],
              if (_hasLyrics) ...[
                SizedBox(height: _lyricGap(h)),
                _lyricBlock(h, Alignment.center, vhs: false),
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
    if (settings.layoutSwap && !narrow) {
      // Build the normal composition in a reflected coordinate system;
      // restore text orientation inside the information panel below.
      return Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1, 1, 1),
        child: _diagonalCore(w, h, narrow, counterFlipText: true),
      );
    }
    return _diagonalCore(w, h, narrow);
  }

  Widget _diagonalCore(double w, double h, bool narrow, {bool counterFlipText = false}) {
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
    // The artwork in the grayscale wedge is a recessed, atmospheric layer,
    // not another sharp cover. Match the main album blur and add extra
    // softness regardless of the user's background-blur setting.
    final diagonalGrayBlur = math.max(14.0, settings.bgBlur + 7.0).toDouble();
    final grayImage = art == null
        ? Image.asset('assets/vybe_album_placeholder.png',
            fit: BoxFit.cover)
        : Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(
                counterFlipText ? -1 : 1, 1, 1),
            child: RawImage(
              // A cached low-resolution backing avoids repeatedly blurring
              // the full-resolution cover on less powerful head units.
              image: art.tiny,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.high,
            ));
    final gray = ClipPath(
      clipper: PolyClipper(poly),
      child: RepaintBoundary(
        child: ColorFiltered(
          colorFilter: _diagonalGrayDark,
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: diagonalGrayBlur,
              sigmaY: diagonalGrayBlur,
              tileMode: TileMode.clamp),
            child: SizedBox.expand(child: grayImage),
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
                        style: settings.diagonalWaveStyle,
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
          Positioned(left: 0, right: 0, bottom: 0, height: h * 0.18, child: _diagonalBottomFade()),
          bars,
          line,
          Positioned(
              left: mid.dx - s / 2, top: mid.dy - s / 2, child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(counterFlipText ? -1 : 1, 1, 1),
            child: _front(s, false),
          )),
          Positioned(
            left: w * 0.08,
            right: w * 0.08,
            top: h * 0.575,
            bottom: h * 0.105,
            child: Center(
              child: SizedBox(
                  width: w * 0.84,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _artist(h * 0.073, Alignment.center, false),
                      SizedBox(height: h * 0.009),
                      _title(h * 0.037, Alignment.center, false),
                                            if (_hasLyrics) ...[
                        SizedBox(height: _lyricGap(h)),
                        _lyricBlock(h * 0.75, Alignment.center, vhs: false),
                      ],
                    ],
                  ),
                ),
            ),
          ),
          if (_showAlbumLabel)
            Positioned(
              left: w * .10, right: w * .10, bottom: h * .045,
              child: Center(child: _shaded(_albumText(h * .026))),
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
        Positioned(left: 0, right: 0, bottom: 0, height: h * 0.18, child: _diagonalBottomFade()),
        bars,
        line,
        Positioned(left: w * 0.046, top: (h - s) / 2, child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(counterFlipText ? -1 : 1, 1, 1),
            child: _front(s, false),
          )),
        Positioned(
          left: infoLeft,
          right: w * 0.05,
          top: infoTop,
          bottom: h * 0.07,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(counterFlipText ? -1 : 1, 1, 1),
            child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _artist(h * 0.090, Alignment.center, false),
              SizedBox(height: h * 0.012),
              _title(h * 0.085, Alignment.center, false),
              if (_showAlbumLabel) ...[
                SizedBox(height: h * 0.012),
                _shaded(_albumText(h * 0.028)),
              ],
              if (_hasLyrics) ...[
                SizedBox(height: _lyricGap(h)),
                _lyricBlock(h, Alignment.center, vhs: false),
              ],
            ],
          ),
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
                    child: Image.asset('assets/vybe_album_placeholder.png', width: inner, height: inner, fit: BoxFit.cover),
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
        begin: narrow ? Alignment.topCenter : (settings.layoutSwap ? Alignment.centerRight : Alignment.centerLeft),
        end: narrow ? Alignment.bottomCenter : (settings.layoutSwap ? Alignment.centerLeft : Alignment.centerRight),
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
      // Give the title group breathing room above the orbit assembly.
      c = Offset(w / 2, h * 0.615);
    } else {
      artR = math.min(h * 0.29, w * 0.17).toDouble();
      c = Offset(w * (settings.layoutSwap ? 0.74 : 0.26), h / 2);
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
          left: settings.layoutSwap ? null : 0,
          right: settings.layoutSwap ? 0 : null,
          top: 0, bottom: 0,
          width: w * 0.57,
          child: IgnorePointer(child: DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(
              begin: settings.layoutSwap ? Alignment.centerRight : Alignment.centerLeft,
              end: settings.layoutSwap ? Alignment.centerLeft : Alignment.centerRight,
              colors: const [Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
              stops: const [0.0, 0.38, 1.0],
            )),
          )),
        ),
      if (settings.backgroundSource != 1 && settings.backgroundSource != 6) _orbitGhost(w, h, narrow),
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
                  style: settings.diagonalWaveStyle,
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
          child: _orbitArt(artR * 2),
        ),
      ),
    ];

    if (narrow) {
      final ringEdge = artR * 1.72;
      // The theme is now clock-free; use the available upper space.
      final infoTop = h * 0.03;
      layers.add(
        Positioned(
          left: w * 0.06,
          right: w * 0.06,
          top: infoTop,
          height: math.max(1.0, c.dy - ringEdge - infoTop).toDouble(),
          child: Align(
            alignment: Alignment.center,
            child: SizedBox(
                width: w * 0.88,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _artist(h * 0.073, Alignment.center, false),
                    SizedBox(height: h * 0.009),
                    _title(h * 0.037, Alignment.center, false),
                    if (_showAlbumLabel) ...[
                      SizedBox(height: h * 0.008),
                      _fixedAlbum(h * 0.026, Alignment.center),
                    ],
                  ],
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
          left: settings.layoutSwap ? w * 0.055 : math.min(w * 0.77, c.dx + artR * 1.90 + w * 0.035),
          right: settings.layoutSwap ? w * 0.56 : w * 0.05,
          top: 0,
          bottom: 0,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _artist(h * 0.080, Alignment.center, false),
              SizedBox(height: h * 0.014),
              _title(h * 0.06, Alignment.center, false),
              if (_showAlbumLabel) ...[
                SizedBox(height: h * 0.014),
                _shaded(_albumText(h * 0.022)),
              ],
              SizedBox(height: h * 0.035),
              if (_hasLyrics) ...[
                SizedBox(height: _lyricGap(h) * 1.2),
                _lyricBlock(h, settings.layoutSwap ? Alignment.centerRight : Alignment.centerLeft, vhs: false),
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
    final artistSize = center ? h * 0.080 : h * 0.096;
    final albumSize = center ? h * 0.031 : h * 0.031;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: cross,
      children: [
        _artist(artistSize, center ? Alignment.center : Alignment.centerRight,
          false, textColor: _readableText(.82)),
        SongTitleMarquee(
          title: _titleStr,
          alignment: center ? Alignment.center : Alignment.centerRight,
          animation: _tick, elapsedSeconds: () => _time,
          style: TextStyle(
            fontSize: h * 0.075,
            fontWeight: FontWeight.w300,
            height: 1.05,
            color: _readableText(1),
            shadows: _cleanTextShadows,
          ),
        ),
        SizedBox(height: h * 0.008),
        if (_showAlbumLabel) ...[
          SizedBox(height: h * 0.005),
          Align(
            alignment: center ? Alignment.center : Alignment.centerRight,
            child: _albumText(albumSize),
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
            : 'Lyrics are off.\\nTurn them on in Settings.',
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
                style: TextStyle(fontSize: big * 0.55, color: Colors.white30, shadows: _lyricShadows),
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
                  shadows: _lyricShadows,
                ),
              ),
              SizedBox(height: big * 0.25),
              Text(
                _lyricAt(1),
                textAlign: ta,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: big * 0.6, color: Colors.white38, shadows: _lyricShadows),
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
            // No persistent clock: center metadata in the full panel.
            top: 0,
            bottom: 0,
            child: Center(
              child: SizedBox(
                  width: cw,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _typoInfo(h, center: true),
                      SizedBox(height: h * 0.016),
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
                      SizedBox(height: h * 0.016),
                      _typoRight(h, center: true, side: math.min(cw * 0.9, h * 0.3).toDouble()),
                    ],
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
            textDirection: settings.layoutSwap ? TextDirection.rtl : TextDirection.ltr,
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.center,
                  child: _typoInfo(h, center: true),
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

  bool get _lyricTheme => settings.theme == AppSettings.tTypo;

  bool get _hasLyrics =>
      _lyricTheme && settings.lyrics && (model.lyrics?.isNotEmpty ?? false);

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
            shadows: _lyricShadows,
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
                              Shadow(color: Color(0xE6000000),
                                  offset: Offset(1, 2), blurRadius: 4),
                              Shadow(color: Color(0xC0000000),
                                  offset: Offset(0, 3), blurRadius: 11),
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
                      shadows: _lyricShadows,
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
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: BarsPainter(
                  sim: sim,
                  palette: _palette,
                  style: settings.diagonalWaveStyle,
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

  // Stable white typography across all artwork and fanart backgrounds.
  // Do not switch foreground text to black based on album-cover pixels.
  bool get _nearWhiteText => false;
  Color _readableText(double opacity) => Colors.white.withOpacity(opacity);
  List<Shadow> get _cleanTextShadows => const [
    Shadow(color: Color(0xB0000000), offset: Offset(0, 1), blurRadius: 3.5),
    Shadow(color: Color(0x77000000), offset: Offset(0, 2), blurRadius: 8),
  ];

  // Readable white lyrics on bright fanart and pale album art.
  static const List<Shadow> _lyricShadows = [
    Shadow(color: Color(0xE6000000), offset: Offset(1, 2), blurRadius: 4),
    Shadow(color: Color(0xC0000000), offset: Offset(0, 3), blurRadius: 11),
  ];

  // Artist-name-only neon is sampled from the current album cover, even
  // when the user's theme palette uses the separate VYBE brand colors.
  ArtPalette get _artistNeonPalette =>
      model.art?.palette ?? _lastArtPalette ?? ArtPalette.neutral;

  List<Shadow> get _artistNeonShadows {
    if (!model.active) return _cleanTextShadows;
    final p = _artistNeonPalette;
    return [
      const Shadow(color: Color(0xAA000000),
          offset: Offset(1, 2), blurRadius: 3),
      Shadow(color: p.a.withOpacity(.60), offset: const Offset(0, 2),
          blurRadius: 5),
      Shadow(color: p.b.withOpacity(.35), blurRadius: 13),
    ];
  }

  /// Compositional fade (not a text backdrop), placed beneath foreground art.
  Widget _bottomArtworkFade() => const IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              // Fan: keep the upper 68% fully clear so environmental rays
              // and haze aren't darkened by the readability gradient.
              stops: [0.0, 0.68, 0.88, 1.0],
              colors: [
                Color(0x00000000),
                Color(0x00000000),
                Color(0x60000000),
                Color(0xD9000000),
              ],
            ),
          ),
        ),
      );

  /// A short bottom-edge fade for Diagonal only; transparent above the
  /// bottom 18% so it cannot darken the central background or waveform.
  Widget _diagonalBottomFade() => const IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0x8C000000), Colors.transparent],
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
    final Widget moving = false
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

  // Build the artist wordmark from individually sized word initials. Tight
  // tracking and a shear give the original vector brush shapes the connected,
  // forward-sweeping character of the approved reference.
  // The alpha TTF has uneven side bearings. Position glyphs by measured
  // advances with a controlled overlap instead of Flutter's letterSpacing
  // (which produced large D/A and E/A gaps in the preview).
  // Optical pair spacing for the custom Riot lettering. The font's F has
  // a long empty right-side bearing; E also leaves too much whitespace.
  // This one method is used by both glyph placement and line measurement.
  double _riotPairOverlap(String previous, String character,
      double fontSize, double glyphWidth) {
    final pair = previous + character;
    // Limited optical corrections only. These four gaps were reported in
    // screenshots, so leave every OTHER pair at the tested build #605 values.
    // Avoid the broad overlap/cap increase that made build #606 run together.
    if (pair == 'FL') {
      return math.min(fontSize * .47, glyphWidth * .82);
    }
    if (pair == 'TH') {
      return math.min(fontSize * .26, glyphWidth * .50);
    }
    if (pair == 'JA') {
      return math.min(fontSize * .26, glyphWidth * .50);
    }
    if (pair == 'OS') {
      return math.min(fontSize * .23, glyphWidth * .52);
    }
    // Riot's W has visible space inside its measured advance. Tighten only
    // the W→O (WORLD) and W→N (RENOWN) transitions seen in testing.
    if (pair == 'WO' || pair == 'WN') {
      return math.min(fontSize * .28, glyphWidth * .57);
    }
    // BROVAZ: the generic V correction pulled V halfway through O.
    // Keep the letters close without placing the V over the O's body.
    if (pair == 'OV') {
      return math.min(fontSize * .075, glyphWidth * .22);
    }
    // F's brush silhouette is much narrower than its glyph advance. FL
    // needs slightly more correction than FE; both occur in FEARLESS FLYERS.
    if (pair == 'FE') {
      return math.min(fontSize * .41, glyphWidth * .70);
    }
    if (previous == 'F') {
      return math.min(fontSize * .34, glyphWidth * .61);
    }
    // Close the unnatural trailing gaps after E without altering the
    // already-approved interlocking diagonal/T/A pairs.
    if (previous == 'E') {
      return math.min(fontSize * .30, glyphWidth * .62);
    }
    // Preserve the previously accepted kerning everywhere else.
    final overlap = pair == 'TA' ? .42 : (pair == 'AT' || pair == 'AV' ||
            pair == 'VA' || pair == 'WA' || pair == 'AW' ||
            pair == 'YA' || pair == 'AY' || pair == 'LT' ||
            pair == 'LY' || pair == 'TY')
        ? .29
        : (previous == 'T' || previous == 'L' ||
                character == 'A' || character == 'V' || character == 'Y')
            ? .21
            : .14;
    return math.min(fontSize * overlap, glyphWidth * (pair == 'TA' ? .66 : .45));
  }

  // The first glyph in each WORD is larger, with equal extension above and
  // below the rest of the word. Keep the approved per-pair optical kerning.
  static const double _riotWordInitialScale = 1.27;

  Widget _artistText(double size, {Color? color, String? letteringOverride}) {
    final lettering = (letteringOverride ?? _artistStr).toUpperCase();
    final fontSize = size * 1.45;
    final style = TextStyle(
      fontFamily: 'VYBERiot',
      fontFamilyFallback: const ['Roboto'],
      fontSize: fontSize,
      height: 1.0,
      letterSpacing: 0,
      wordSpacing: 0,
      color: color ?? Colors.white,
      shadows: _artistNeonShadows,
    );
    // Measure glyphs first, then center every glyph within the tallest line
    // box. This centers the enlarged initial both above and below its word.
    final glyphCharacters = <String>[];
    final glyphStyles = <TextStyle>[];
    final glyphPositions = <double>[];
    final glyphHeights = <double>[];
    var x = 0.0;
    var previous = '';
    var maxHeight = fontSize;
    for (final rune in lettering.runes) {
      final character = String.fromCharCode(rune);
      // Use an explicit, modest word gap. Measuring a fallback-font space
      // previously added too much whitespace between words.
      if (character == ' ') {
        if (previous.isNotEmpty && previous != ' ') {
          x += fontSize * .22;
          previous = ' ';
        }
        continue;
      }
      final isWordInitial = previous.isEmpty || previous == ' ';
      final glyphStyle = isWordInitial
          ? style.copyWith(fontSize: fontSize * _riotWordInitialScale)
          : style;
      final painter = TextPainter(
        text: TextSpan(text: character, style: glyphStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final glyphWidth = painter.width;
      maxHeight = math.max(maxHeight, painter.height);
      if (previous.isNotEmpty && previous != ' ') {
        x -= _riotPairOverlap(previous, character, fontSize, glyphWidth);
      }
      glyphCharacters.add(character);
      glyphStyles.add(glyphStyle);
      glyphPositions.add(x);
      glyphHeights.add(painter.height);
      x += glyphWidth;
      previous = character;
    }
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.skewX(-.16),
      child: SizedBox(
        width: math.max(1, x),
        height: maxHeight,
        child: Stack(clipBehavior: Clip.none, children: [
          for (var i = 0; i < glyphCharacters.length; i++)
            Positioned(
              left: glyphPositions[i],
              top: (maxHeight - glyphHeights[i]) / 2,
              child: Text(glyphCharacters[i], maxLines: 1,
                  softWrap: false, style: glyphStyles[i]),
            ),
        ]),
      ),
    );
  }


  // The Riot font's line box is taller than the visible brush strokes.
  // A normal Column leaves a huge gap between stacked artist-name words.
  // Position the lines at a compact optical pitch instead, while keeping
  // their individual font sizes, first-letter scale, and kerning unchanged.
  Widget _compactRiotLines(List<String> lines, double size, Alignment align,
      Widget Function(String) buildLine) {
    if (lines.isEmpty) return const SizedBox.shrink();
    if (lines.length == 1) return Align(alignment: align, child: buildLine(lines.first));
    final lineHeight = size * 1.45 * _riotWordInitialScale;
    // Keep consecutive wordmarks close; the tall font metrics previously
    // created conspicuous blank strips between wrapped lines.
    final lineStep = lineHeight * .47;
    return SizedBox(
      height: lineHeight + lineStep * (lines.length - 1),
      child: Stack(clipBehavior: Clip.none, children: [
        for (var i = 0; i < lines.length; i++)
          Positioned(
            left: 0,
            right: 0,
            top: i * lineStep,
            child: Align(alignment: align, child: buildLine(lines[i])),
          ),
      ]),
    );
  }

  // Calculate widths with the SAME optical overlaps as the approved glyphs.
  // Width measurement is cached so visualizer frames don't repeatedly measure.
  double _artistRunWidth(String lettering, double size) {
    final key = size.toStringAsFixed(2) + '|' + lettering;
    final saved = _artistWidthCache[key];
    if (saved != null) return saved;
    final fontSize = size * 1.45;
    final style = TextStyle(fontFamily: 'VYBERiot',
        fontFamilyFallback: const ['Roboto'],
        fontSize: fontSize, letterSpacing: 0, wordSpacing: 0);
    var x = 0.0;
    var prev = '';
    for (final rune in lettering.runes) {
      final c = String.fromCharCode(rune);
      // Match the exact gap and initial sizing used in _artistText so
      // line-breaking widths stay faithful to what is drawn on screen.
      if (c == ' ') {
        if (prev.isNotEmpty && prev != ' ') {
          x += fontSize * .22;
          prev = ' ';
        }
        continue;
      }
      final isWordInitial = prev.isEmpty || prev == ' ';
      final glyphStyle = isWordInitial
          ? style.copyWith(fontSize: fontSize * _riotWordInitialScale)
          : style;
      final p = TextPainter(text: TextSpan(text: c, style: glyphStyle),
          textDirection: TextDirection.ltr, maxLines: 1)..layout();
      final width = p.width;
      if (prev.isNotEmpty && prev != ' ') {
        x -= _riotPairOverlap(prev, c, fontSize, width);
      }
      x += width;
      prev = c;
    }
    if (_artistWidthCache.length > 256) _artistWidthCache.clear();
    _artistWidthCache[key] = x;
    return x;
  }

  // Prefer two balanced lines. Never shrink the lettering to make it fit.
  // Muzine portrait has a broad, centered info area. The generic size*.8
  // side reserve can consume 80+ logical pixels on a phone and orphan the
  // final letter of an otherwise fitting artist name. Use only a small
  // optical allowance for the sheared brush strokes in that layout.
  List<String> _artistLines(String text, double size, double width,
      {bool useFullPortraitWidth = false}) {
    if (text.isEmpty) return const [''];
    final safety = useFullPortraitWidth
        ? math.min(size * .12, width * .015)
        : size * .8;
    final limit = math.max(1.0, width - safety);
    if (_artistRunWidth(text, size) <= limit) return [text];
    final words = text.split(RegExp(r'\s+'));
    List<String>? best;
    var smallestDifference = double.infinity;
    for (var i = 1; i < words.length; i++) {
      final a = words.take(i).join(' '), b = words.skip(i).join(' ');
      final aw = _artistRunWidth(a, size), bw = _artistRunWidth(b, size);
      if (aw <= limit && bw <= limit &&
          (aw - bw).abs() < smallestDifference) {
        best = [a, b];
        smallestDifference = (aw - bw).abs();
      }
    }
    if (best != null) return best;
    final lines = <String>[];
    var line = '';
    for (final word in words) {
      final joined = line.isEmpty ? word : '$line $word';
      if (line.isNotEmpty && _artistRunWidth(joined, size) > limit) {
        lines.add(line);
        line = word;
      } else {
        line = joined;
      }
      // Never split a word in the middle. If an individual word exceeds
      // the slot it stays intact and the renderer scrolls that whole word
      // through a clipped, edge-faded viewport at its original font size.
    }
    if (line.isNotEmpty) lines.add(line);
    return lines.isEmpty ? [text] : lines;
  }

  /// Very long single words retain their full Riot typography and scroll
  /// as ONE word instead of wrapping the last letter onto the next line.
  /// Reuse the capped VYBE frame ticker rather than creating a new ticker
  /// for every artist line on the ATOTO head unit.
  Widget _overflowRiotWord(String line, double size, double available,
      Widget Function(String) render) {
    final wordWidth = _artistRunWidth(line, size) + size * .10;
    final travel = math.max(0.0, wordWidth - available);
    final lineHeight = size * 1.45 * _riotWordInitialScale * 1.12;
    final seconds = (travel / 42.0 + 4.0).clamp(9.0, 40.0).toDouble();
    return SizedBox(
      width: available,
      height: lineHeight,
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => const LinearGradient(
          colors: [Colors.transparent, Colors.white,
            Colors.white, Colors.transparent],
          stops: [0, .035, .965, 1],
        ).createShader(bounds),
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _tick,
            builder: (context, _) {
              final t = (_time % seconds) / seconds;
              final p = t < .17
                  ? 0.0
                  : t < .70
                      ? Curves.easeInOut.transform((t - .17) / .53)
                      : t < .86
                          ? 1.0
                          : 1.0 - Curves.easeInOut.transform((t - .86) / .14);
              return Stack(clipBehavior: Clip.hardEdge, children: [
                Positioned(
                  left: -(travel * p),
                  top: 0,
                  width: wordWidth,
                  child: render(line),
                ),
              ]);
            },
          ),
        ),
      ),
    );
  }

  TextStyle _albumLabelTextStyle(double size) => TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w400,
        letterSpacing: size * 0.14,
        fontStyle: FontStyle.italic,
        color: Colors.white,
      );

  // A single album-label rule for every layout and both orientations.
  // Singles legitimately have the same song and album name: don't hide them.
  // If a media player omits the album, show an honest fallback rather than
  // silently removing the entire framed label.
  bool get _showAlbumLabel => model.active;
  String get _albumDisplayName =>
      model.displayAlbumTitle.toUpperCase();

  // Compact high-contrast album label; never stretch the black backing
  // across the entire metadata panel.
  // Angular neon treatment belongs to the ALBUM NAME label, not the cover.
  Widget _albumText(double size, {Alignment? flushFrame}) {
    final labelSize = _albumFontSize(size);
    final albumStyle = _albumLabelTextStyle(labelSize);
    return LayoutBuilder(builder: (context, bounds) {
      final screen = MediaQuery.sizeOf(context);
      final available = bounds.maxWidth.isFinite
          ? math.max(1.0, bounds.maxWidth)
          : math.max(1.0, screen.width * .86);
      // Only the lettering moves inside its fixed neon frame. Compute the
      // label's natural width, then cap its viewport to the real column.
      // This avoids an oversized frame for short names and keeps all long
      // names readable at exactly the same font size across every theme.
      final painter = TextPainter(
        text: TextSpan(text: _albumDisplayName, style: albumStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final letteringWidth = painter.width + 3.0;
      painter.dispose();
      final leftPad = flushFrame == Alignment.centerLeft
          ? labelSize * 1.55 : labelSize * 3.30;
      final rightPad = flushFrame == Alignment.centerRight
          ? labelSize * 1.55 : labelSize * 3.30;
      final badgeWidth = math.min(
          available, letteringWidth + leftPad + rightPad).toDouble();
      final left = math.min(leftPad, badgeWidth * .30).toDouble();
      final right = math.min(rightPad, badgeWidth * .30).toDouble();
      return Align(
        alignment: flushFrame ?? Alignment.center,
        child: SizedBox(
          width: math.max(1.0, badgeWidth),
          child: CustomPaint(
            painter: _VybeAlbumLabelFrame(_palette.a,
              flushRight: flushFrame == Alignment.centerRight,
              flushLeft: flushFrame == Alignment.centerLeft),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                left, labelSize * .24, right, labelSize * .24),
              child: SongTitleMarquee(
                title: _albumDisplayName,
                style: albumStyle,
                alignment: Alignment.center,
                animation: _tick,
                elapsedSeconds: () => _time,
              ),
            ),
          ),
        ),
      );
    });
  }

  // Keep titles at their designed font size. Long songs scroll horizontally
  // inside their available column with feathered edges, never scale down.
  Widget _fixedTitle(double size, Alignment align) => _shaded(
    SongTitleMarquee(title: _titleStr,
      style: _titleText(_songFontSize(size)).style!, alignment: align,
      animation: _tick, elapsedSeconds: () => _time));

  Widget _fixedAlbum(double size, Alignment align,
      {bool flushFrame = false}) => Align(
        alignment: align,
        child: _albumText(size, flushFrame: flushFrame ? align : null),
      );

  Widget _title(double size, Alignment a, bool vhs) {
    final standard = _titleText(_songFontSize(size)).style!;
    final activeStyle = (vhs || _vhsOn)
        ? standard.copyWith(shadows: [
            ..._cleanTextShadows,
            Shadow(color: const Color(0x99FF2E93),
              offset: Offset(-1.5 - settings.vhsEffects, 0)),
            Shadow(color: const Color(0x9905D9FF),
              offset: Offset(1.5 + settings.vhsEffects, 0)),
          ])
        : standard;
    return _shaded(SongTitleMarquee(
      title: _titleStr, style: activeStyle, alignment: a,
      animation: _tick, elapsedSeconds: () => _time));
  }

  // Shared responsive clearlogo renderer. Scale in both directions within
  // the allocated artist slot; never let larger logos cover album art.
  Widget _scaledClearLogo({Alignment alignment = Alignment.center}) {
    return LayoutBuilder(builder: (context, box) {
      final screen = MediaQuery.sizeOf(context);
      final slotWidth = box.maxWidth.isFinite ? box.maxWidth : screen.width * .90;
      final slotHeight = box.maxHeight.isFinite ? box.maxHeight : screen.height * .22;
      // The entire 50%-200% slider range is active inside safe bounds.
      final fraction =
          (0.44 + 0.28 * settings.artistLogoScale).clamp(.58, 1.0).toDouble();
      return Align(
        alignment: alignment,
        child: SizedBox(
          width: math.max(1.0, slotWidth * fraction),
          height: math.max(1.0, slotHeight * fraction),
          child: Image.memory(_clearLogoBytes!, fit: BoxFit.contain,
              alignment: alignment, gaplessPlayback: true,
              filterQuality: FilterQuality.medium),
        ),
      );
    });
  }

  Widget _artist(double size, Alignment a, bool vhs, {Color? textColor}) {
    // Apply typography minimum centrally, preserving logo-specific scaling.
    final fontSize = _artistFontSize(size);
    if (settings.useArtistClearLogo && _clearLogoBytes != null && model.active) {
      return _shaded(LayoutBuilder(builder: (context, box) {
        final screen = MediaQuery.sizeOf(context);
        final maxWidth = box.maxWidth.isFinite
            ? math.min(box.maxWidth, screen.width * .94)
            : screen.width * .90;
        final naturalHeight = math.min(screen.height * .25,
            math.max(screen.height * .14, size * 3.0));
        final maxHeight = box.maxHeight.isFinite
            ? math.min(box.maxHeight, naturalHeight)
            : naturalHeight;
        return SizedBox(
          width: math.max(1.0, maxWidth),
          height: math.max(1.0, maxHeight),
          child: _scaledClearLogo(alignment: a),
        );
      }));
    }
    Widget lineWidget(String line) => (vhs || _vhsOn)
        ? _split((c) => _artistText(fontSize, color: c, letteringOverride: line),
            main: textColor ?? Colors.white70,
            leftGhost: _artistNeonPalette.a.withOpacity(.60),
            rightGhost: _artistNeonPalette.b.withOpacity(.60))
        : _artistText(fontSize, color: textColor, letteringOverride: line);
    return LayoutBuilder(builder: (context, box) {
      final screen = MediaQuery.sizeOf(context);
      final available = box.maxWidth.isFinite
          ? math.max(1.0, box.maxWidth) : math.max(1.0, screen.width * .88);
      final muzinePortrait = settings.theme == AppSettings.tEditorial &&
          screen.height > screen.width * 1.1;
      final lines = _artistLines(_artistStr.toUpperCase().trim(),
          fontSize, available, useFullPortraitWidth: muzinePortrait);
      // Break only at word boundaries; an oversized single word scrolls.
      // Do not use FittedBox on any artist text, including Focused.
      Widget renderedLine(String line) =>
          _artistRunWidth(line, fontSize) > available
              ? _overflowRiotWord(line, fontSize, available, lineWidget)
              : lineWidget(line);
      return _shaded(
        lines.length > 1
            ? _compactRiotLines(lines, fontSize, a, renderedLine)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [Align(alignment: a, child: renderedLine(lines.first))],
              ),
      );
    });
  }

  /// RGB split: a pink and a cyan ghost behind the sharp text.
  Widget _split(Widget Function(Color) build, {
      Color main = Colors.white,
      Color leftGhost = const Color(0x99FF005E),
      Color rightGhost = const Color(0x998A00FF)}) {
    final d = 1.0 + 2.5 * settings.vhsEffects;
    return Stack(
      children: [
        Transform.translate(
            offset: Offset(-d, 0), child: build(leftGhost)),
        Transform.translate(
            offset: Offset(d, 0), child: build(rightGhost)),
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
    final radius = s * 0.018;
    return ClipRRect(
      key: ValueKey<Object>(art ?? 'placeholder'),
      borderRadius: BorderRadius.circular(radius),
      child: art == null
          ? Image.asset(
              'assets/vybe_album_placeholder.png',
              width: s,
              height: s,
              fit: BoxFit.cover,
              alignment: const Alignment(0, -0.16),
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
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
    // The secondary album-art hue keeps the halo distinct from the cover.
    // Only the explicit VYBE palette override uses the brand neon colors.
    final glow = settings.useVybePalette ? _brandPalette.b : _palette.b;
    final glowSecondary = settings.useVybePalette ? _brandPalette.a : _palette.c;
    return RepaintBoundary(
      child: Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(s * 0.018),
          border: Border.all(color: _palette.a.withOpacity(0.68), width: 1),
          boxShadow: [
            BoxShadow(
                color: glow.withOpacity(0.20),
                blurRadius: s * 0.12,
                spreadRadius: 1),
            BoxShadow(
                color: glowSecondary.withOpacity(0.17),
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
            ghost(const Color(0xFF8A00FF), d),
            _artCard(s),
          ],
        ),
      ),
    );
  }

  /// Tapping the cover opens the player app that is playing.
  Widget _front(double s, bool vhs) => GestureDetector(
        key: _artKey,
        behavior: HitTestBehavior.opaque,
        onTap: _openPlayer,
        child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (settings.fxBloom && settings.fxPerformanceMode == 2)
                FxComposite(mode: settings.fxBlendMode['Cover Bloom'] ?? 0,
                  opacity: settings.fxBlendOpacity['Cover Bloom'] ?? 1.0,
                  child: _bloom(s)),
              (vhs || _vhsOn) ? _splitArt(s) : _artCard(s),
            ],
          ),
      );

  /// Soft glow: a blurred, slightly larger copy of the cover behind it.
  Widget _bloom(double s) => RepaintBoundary(
        child: Transform.scale(
          scale: 1.0 + 0.06 * (settings.fxSize['Cover Bloom'] ?? 1.0),
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: s * 0.04 * (settings.fxSize['Cover Bloom'] ?? 1.0), sigmaY: s * 0.04 * (settings.fxSize['Cover Bloom'] ?? 1.0)),
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
                          borderRadius: BorderRadius.circular(s * 0.018),
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
            left: s * 0.018,
            right: s * 0.018,
            height: s * 0.018,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius:
                    BorderRadius.vertical(bottom: Radius.circular(s * 0.018)),
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

  /// One clock for every theme, visible only while the controls are open.
  /// The top fade keeps the time legible over bright fanart without
  /// introducing a permanent obstruction into any composition.
  Widget _controlsClockHeader() {
    final h = MediaQuery.sizeOf(context).height;
    return Positioned(
      left: 0, right: 0, top: 0,
      height: math.min(h * .24, 190.0),
      child: IgnorePointer(child: Stack(children: [
        const Positioned.fill(child: DecoratedBox(
          decoration: BoxDecoration(gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Color(0xC9000000), Color(0x77000000),
              Color(0x00000000)],
            stops: [0, .40, 1])))),
        Positioned(left: 0, right: 0,
          top: math.max(12.0, MediaQuery.of(context).viewPadding.top + 8.0),
          child: Center(child: Text(_clockLabel(),
            style: TextStyle(color: Colors.white,
              fontSize: (h * .065).clamp(27.0, 48.0).toDouble(),
              fontWeight: FontWeight.w500,
              shadows: const [Shadow(color: Colors.black, blurRadius: 8)])))),
      ])),
    );
  }


  /// Full-width bottom controls. No bubble or pill background: a thin
  /// VYBE-magenta/purple/cyan rule and rising shadow separate it from the art.
  /// The persistent AnimatedSlide can animate both entrance AND exit.
  Widget _controls() {
    final screen = MediaQuery.sizeOf(context);
    final compact = screen.width < 610;
    final iconSize = compact ? 23.0 : 29.0;
    final playSize = compact ? 34.0 : 45.0;

    Widget btn(IconData icon, String tooltip, VoidCallback onTap,
        {double? size}) => Tooltip(
      message: tooltip,
      child: IconButton(
        iconSize: size ?? iconSize,
        constraints: BoxConstraints(
          minWidth: compact ? 41 : 48,
          minHeight: compact ? 41 : 48),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
        color: Colors.white,
        icon: Icon(icon),
        onPressed: () {
          onTap();
          if (mounted && _showControls) _poke();
        },
      ),
    );

    return Positioned(
      left: 0, right: 0, bottom: 0,
      child: IgnorePointer(
        ignoring: !_showControls,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 285),
          curve: Curves.easeOutCubic,
          offset: _showControls ? Offset.zero : const Offset(0, 1.15),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _showControls ? 1 : 0,
            child: Container(
              decoration: const BoxDecoration(
                color: Color(0xE5101219),
                boxShadow: [
                  BoxShadow(
                    color: Color(0xC9000000),
                    blurRadius: 32,
                    spreadRadius: 5,
                    offset: Offset(0, -12)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Stable VYBE brand gradient, not the album's palette.
                  Container(height: 3,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(colors: [
                        Color(0xFFFF27A8), Color(0xFF995CFF),
                        Color(0xFF05E2F3)]))),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        compact ? 8 : 22, 3, compact ? 8 : 22, 5),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _seekBar(width: double.infinity),
                          const SizedBox(height: 2),
                          Row(children: [
                            btn(Icons.grid_view_rounded, 'Themes', _pickTheme),
                            btn(Icons.tune_rounded, 'Customize', _openQuickCustomize),
                            btn(Icons.settings_outlined, 'Settings', _openSettings),
                            if (screen.width > screen.height &&
                                const [1, 3, 5, 6, 7, 8, 9, 10, 11]
                                    .contains(settings.theme))
                              btn(Icons.swap_horiz_rounded, 'Flip layout', () {
                                settings.update(() {
                                  settings.layoutSwap = !settings.layoutSwap;
                                });
                              }),
                            if (widget.driveHost) ...[
                              btn(Icons.map_outlined, 'Show map', _hideDrive),
                              btn(Icons.close_rounded, 'Close Drive', _exitDrive),
                            ] else
                              btn(Icons.navigation_rounded, 'Drive', _startDrive),
                            const Spacer(),
                            btn(Icons.skip_previous_rounded, 'Previous',
                                model.previous, size: playSize),
                            btn(
                              model.playing
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_filled,
                              model.playing ? 'Pause' : 'Play',
                              model.playPause, size: playSize + 10),
                            btn(Icons.skip_next_rounded, 'Next',
                                model.next, size: playSize),
                            if (!compact) ...[
                              const SizedBox(width: 18),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${_fmt(model.positionMs)} / ${_fmt(model.durationMs)}',
                                    style: const TextStyle(
                                      color: Colors.white70, fontSize: 14)),
                                  Text(
                                    AppSettings.themeNames[settings.theme],
                                    style: const TextStyle(
                                      color: Colors.white54, fontSize: 11)),
                                ],
                              ),
                            ],
                          ]),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
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
        child: SvgPicture.asset(
          'assets/vybe_edgy_icon.svg',
          width: size,
          height: size,
          fit: BoxFit.contain,
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
              SvgPicture.asset('assets/vybe_edgy_logo.svg', width: 300),
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


/// Thin, smoothed audio-reactive waveform for Cinematic.
/// Editorial portrait waveform: zero baseline at the grayscale divider,
/// positive Y deformation only, with no reflected/mirrored duplicate.
class _EditorialDividerWavePainter extends CustomPainter {
  final SpectrumSim sim;
  final Color color;
  final double gain;
  final int style;
  _EditorialDividerWavePainter({
    required this.sim, required this.color, required this.gain,
    required this.style, required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    const samples = 96;
    final points = <Offset>[];
    for (var i = 0; i < samples; i++) {
      final x = i / (samples - 1);
      final band = (x * (SpectrumSim.bars - 1)).round();
      final raw = sim.level(band, gain).clamp(0.0, 1.0);
      final energy = math.pow(raw, 0.58).toDouble();
      points.add(Offset(x * size.width, size.height * .84 * energy));
    }
    final fade = LinearGradient(
      colors: [color.withOpacity(0), color.withOpacity(.85),
        color.withOpacity(.85), color.withOpacity(0)],
      stops: const [0, .13, .87, 1],
    ).createShader(Offset.zero & size);
    if (style == 0) {
      // Bars follow the divider, with dense samples rather than widely
      // spaced strokes stretched across the screen.
      final paint = Paint()..shader = fade
        ..strokeWidth = (size.width / samples * .52).clamp(1.2, 4.0)
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < points.length; i++) {
        canvas.drawLine(Offset(points[i].dx, 0), points[i], paint);
      }
    } else if (style == 2) {
      for (final point in points) {
        final opacity = (.85 * (1 - (point.dx / size.width * 2 - 1).abs()))
            .clamp(0.0, 1.0);
        canvas.drawCircle(point, 1.7, Paint()..color = color.withOpacity(opacity));
      }
    } else {
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (var i = 1; i < points.length - 1; i++) {
        final mid = Offset((points[i].dx + points[i + 1].dx) / 2,
            (points[i].dy + points[i + 1].dy) / 2);
        path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
      }
      path.lineTo(points.last.dx, points.last.dy);
      canvas.drawPath(path, Paint()..shader = fade
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke);
    }
  }

  @override
  bool shouldRepaint(_EditorialDividerWavePainter old) =>
      old.color != color || old.gain != gain || old.style != style;
}

class _CinematicWavePainter extends CustomPainter {
  final SpectrumSim sim;
  final Color color;
  final double gain;
  final int style;
  _CinematicWavePainter({required this.sim, required this.color,
    required this.gain, required this.style, required Listenable repaint}) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    const samples = 96;
    final points = <Offset>[];
    for (var i = 0; i < samples; i++) {
      final x = i / (samples - 1);
      final band = (i * (SpectrumSim.bars - 1) / (samples - 1)).round();
      // Expand quieter live-audio peaks without clipping the louder ones.
      // Preserve the relative spectral differences instead of flattening bars.
      final raw = sim.level(band, gain).clamp(0.0, 1.0);
      final energy = math.pow(raw, 0.58).toDouble();
      final y = size.height * (0.55 - 0.44 * energy);
      points.add(Offset(x * size.width, y));
    }
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length - 1; i++) {
      final mid = Offset((points[i].dx + points[i + 1].dx) / 2,
          (points[i].dy + points[i + 1].dy) / 2);
      path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(points.last.dx, points.last.dy);
    final fade = LinearGradient(
      colors: [color.withOpacity(0.0), color.withOpacity(0.85),
               color.withOpacity(0.85), color.withOpacity(0.0)],
      stops: const [0.0, 0.13, 0.87, 1.0],
    ).createShader(Offset.zero & size);
    final paint = Paint()
      ..shader = fade
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (style == 0) {
      paint.strokeWidth = (size.width / samples * .55).clamp(1.2, 4.0);
      for (var i = 0; i < points.length; i++) {
        canvas.drawLine(Offset(points[i].dx, size.height * 0.60),
          points[i], paint);
      }
    } else if (style == 2) {
      for (final point in points) {
        canvas.drawCircle(point, 2.2, Paint()..color =
          color.withOpacity((0.85 * (1 - (point.dx / size.width * 2 - 1).abs())).clamp(0.0, 1.0)));
      }
    } else {
      canvas.drawPath(path, paint);
    }
    // A subtle, vertically compressed reflection underneath the waveform.
    canvas.save();
    canvas.translate(0, size.height * 1.10);
    canvas.scale(1.0, -0.48);
    final reflection = LinearGradient(
      colors: [color.withOpacity(0.0), color.withOpacity(0.23),
               color.withOpacity(0.23), color.withOpacity(0.0)],
      stops: const [0.0, 0.13, 0.87, 1.0],
    ).createShader(Offset.zero & size);
    if (style == 1) {
      canvas.drawPath(path, Paint()
        ..shader = reflection
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round);
    } else if (style == 0) {
      final rp = Paint()..shader = reflection..strokeWidth = 1.8;
      for (var i = 0; i < points.length; i++) {
        canvas.drawLine(Offset(points[i].dx, size.height * 0.60), points[i], rp);
      }
    } else {
      for (final point in points) {
        canvas.drawCircle(point, 1.7, Paint()..color = color.withOpacity(0.12));
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CinematicWavePainter old) =>
      old.color != color || old.gain != gain || old.style != style;
}

/// Obsidian / neon pink / electric purple idle animation. No shaders or
/// offscreen blurs: safe for low-powered Android head units.
class _EdgyStandbyPainter extends CustomPainter {
  final double time;
  final double bass;
  final double motion;
  const _EdgyStandbyPainter({
    required this.time, required this.bass, required this.motion});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final phase = time * motion.clamp(0.0, 1.0);
    canvas.drawRect(rect, Paint()..color = const Color(0xFF0B0B0F));
    canvas.drawRect(rect, Paint()..shader = ui.Gradient.radial(
      Offset(size.width * .48, size.height * .4),
      size.longestSide * .8,
      [const Color(0xFF340745), const Color(0xFF18051F),
       const Color(0xFF0B0B0F)],
      [0, .52, 1]));

    // Broad translucent overlapping clouds approximate the smoke and
    // illuminated atmosphere of the campaign art without GPU blur filters.
    for (var i = 0; i < 9; i++) {
      final k = i.toDouble();
      final dx = math.sin(phase * .11 + k * 1.7) * size.width * .045;
      final dy = math.cos(phase * .09 + k * 1.3) * size.height * .04;
      final center = Offset(
        size.width * (.12 + (i % 4) * .24) + dx,
        size.height * (.16 + (i ~/ 4) * .28) + dy);
      final radius = size.longestSide * (.25 + (i % 3) * .065);
      final color = i.isEven
          ? const Color(0xFFFF005E) : const Color(0xFF8A00FF);
      canvas.drawRect(rect, Paint()..shader = ui.Gradient.radial(
        center, radius,
        [color.withOpacity(.20), color.withOpacity(.07),
         color.withOpacity(0)],
        [0, .43, 1]));
    }

    // Diagonal, gently drifting neon strokes: bright core, colored halo,
    // and fine highlight. Their geometry stays fixed in performance mode.
    final drift = math.sin(phase * .19) * size.width * .035;
    for (var i = 0; i < 3; i++) {
      final start = Offset(size.width * (.69 + i * .07) + drift,
          -size.height * .07);
      final end = Offset(size.width * (.23 + i * .075) + drift,
          size.height * (.48 + i * .065));
      final color = i == 1
          ? const Color(0xFF8A00FF) : const Color(0xFFFF005E);
      for (final widthFactor in <double>[.028, .012, .003]) {
        canvas.drawLine(start, end, Paint()
          ..color = color.withOpacity(widthFactor == .003 ? .83 : .18)
          ..strokeWidth = math.max(1.0, size.shortestSide * widthFactor)
          ..strokeCap = StrokeCap.round);
      }
    }
    final shine = Offset(size.width * .9, size.height * .76);
    canvas.drawRect(rect, Paint()..shader = ui.Gradient.radial(
      shine, size.longestSide * .35,
      [const Color(0xFFFF005E).withOpacity(.22),
       const Color(0xFF8A00FF).withOpacity(0)]));
  }

  @override
  bool shouldRepaint(covariant _EdgyStandbyPainter old) =>
      old.time != time || old.bass != bass || old.motion != motion;
}



class _VybeAlbumLabelFrame extends CustomPainter {
  final Color accent;
  final bool flushRight;
  final bool flushLeft;
  const _VybeAlbumLabelFrame(this.accent,
      {this.flushRight = false, this.flushLeft = false});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // Reference: steep parallelogram with two *separate*, parallel
    // diagonal accent strokes. No horizontal joining bars on the wings.
    final wing = math.min(h * 1.05, w * .13);
    final cut = h * .64;
    final offset = h * .26;
    final edgeMargin = math.max(1.5, h * .05);
    // Side-by-Side's outside-facing accent slash ends at the same edge
    // as the text column, without the unused wing margin.
    final left = flushLeft ? offset + edgeMargin : wing;
    final right = flushRight ? w - offset - edgeMargin : w - wing;
    final top = h * .08;
    final bottom = h * .90;
    final frame = Path()
      ..moveTo(left + cut, top)
      ..lineTo(right, top)
      ..lineTo(right - cut, bottom)
      ..lineTo(left, bottom)
      ..close();

    final fill = Paint()..color = Colors.black.withOpacity(.92);
    canvas.drawPath(frame, fill);

    final strokeWidth = math.max(1.4, h * .045);
    final line = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.square
      ..strokeJoin = StrokeJoin.miter;
    final glow = Paint()
      ..color = accent.withOpacity(.65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2.2, h * .11)
      ..strokeCap = StrokeCap.square
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);

    // Accent slashes run alongside the two slanted frame edges, with a
    // deliberate narrow gap; they do not touch the frame or each other.
    final wings = Path()
      ..moveTo(left + cut - offset, top)
      ..lineTo(left - offset, bottom)
      ..moveTo(right + offset, top)
      ..lineTo(right - cut + offset, bottom);
    canvas.drawPath(frame, glow);
    canvas.drawPath(wings, glow);
    canvas.drawPath(frame, line);
    canvas.drawPath(wings, line);
  }

  @override
  bool shouldRepaint(covariant _VybeAlbumLabelFrame old) =>
      old.accent != accent || old.flushRight != flushRight ||
      old.flushLeft != flushLeft;
}

/// Restricts neon underpainting to the lower tips of brush lettering.
class _VybeLowerEdgeClipper extends CustomClipper<Rect> {
  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, size.height * .70, size.width, size.height * .30);
  @override
  bool shouldReclip(covariant _VybeLowerEdgeClipper oldClipper) => false;
}
