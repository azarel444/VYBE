import 'onboarding.dart';
import 'vybe_link.dart';
import 'vybe_link_artist_art_cache.dart';
import 'dart:async';
import 'dart:typed_data';
import 'artist_fanart.dart';
import 'artist_artwork_match.dart';
import 'coverflow_queue.dart';
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
import 'coverflow_theme.dart';
import 'music_video_theme.dart';
import 'music_video_vhs.dart';
import 'riot_fixed_spacing.dart';
import 'riot_approved_spacing.dart';
import 'riot_spacing_store.dart';
import 'riot_spacing_editor.dart';
import 'artist_logo_shader.dart';
import 'laser_tunnel_background.dart';
import 'fx_composite.dart';

enum _VybeTextRole { artist, title, album }

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
  // Prepare only the next two actually published queue entries.
  final Map<String, Uint8List> _smartPrefetchFanart = {};
  final Map<String, Uint8List> _smartPrefetchLogos = {};
  Timer? _smartPrefetchTimer;
  String _smartPrefetchSignature = '';
  int _smartPrefetchGeneration = 0;
  static String _smartArtistKey(String artist) => artist.toLowerCase().trim();

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
  double _artistLogoPhase = 0; // integrated, continuous when speed changes
  final _artworkMotionPhase = ValueNotifier<double>(0);
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
  final _fxViewportKey = GlobalKey(); // coordinate space for every shader pass
  final _bokehLayerKey = GlobalKey();
  final _particlesLayerKey = GlobalKey();
  final _expandedFxLayerKeys = List<GlobalKey>.generate(
      AppSettings.extraFxNames.length, (_) => GlobalKey());
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
  Timer? _driveConnectArtTimer;
  String _driveConnectArtist = '';
  String? _driveConnectFanartVersion;
  String? _driveConnectLogoVersion;
  bool _driveConnectCheckInProgress = false;

  // A track change requires an intentional horizontal gesture with sufficient
  // distance; a quick vertical/diagonal movement must never skip music.
  double _horizontalSwipeDistance = 0;
  bool _showControls = false;
  // The embedded player owns playback while YouTube Music is paused.
  // The same Record Cut animation is allowed to keep spinning in this theme.
  bool _musicVideoIsPlaying = false;
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
    RiotSpacingStore.instance.addListener(_onRiotSpacingChanged);
    unawaited(RiotSpacingStore.instance.load());
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
      // Drive has its own Flutter engine. Listen for artist artwork shared
      // by the primary VYBE Connect receiver, without binding another socket.
      _driveConnectArtTimer = Timer.periodic(
          const Duration(seconds: 2), (_) => unawaited(_syncDriveConnectArt()));
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
    RiotSpacingStore.instance.removeListener(_onRiotSpacingChanged);
    _ticker.dispose();
    _hideTimer?.cancel();
    _brightnessChannel.invokeMethod<void>('setNight', false).catchError((Object _) {});
    _clockTimer?.cancel();
    _fanartCycleTimer?.cancel();
    _smartPrefetchTimer?.cancel();
    _smartPrefetchGeneration++;
    _fanartRetryTimer?.cancel();
    _clearLogoRetryTimer?.cancel();
    _dirTimer?.cancel();
    _driveConnectArtTimer?.cancel();
    _noise?.dispose();
    _recAngle.dispose();
    _artworkMotionPhase.dispose();
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
    final head = link.deviceType == 'head_unit';
    if (settings.headUnitDevice != head) {
      setState(() => settings.headUnitDevice = head);
    }
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

  /// The Connect receiver belongs to the normal Flutter engine, while Drive
  /// uses a separate Flutter engine. The received images are published to a
  /// small shared app-private cache; read only changes for the current artist.
  Future<void> _syncDriveConnectArt() async {
    if (!widget.driveHost || !mounted || _driveConnectCheckInProgress) return;
    final artist = model.artist.trim();
    if (!model.active || artist.isEmpty) return;
    if (_driveConnectArtist != artist) {
      _driveConnectArtist = artist;
      _driveConnectFanartVersion = null;
      _driveConnectLogoVersion = null;
    }
    _driveConnectCheckInProgress = true;
    try {
      final logo = await LinkArtistArtworkCache.readChanged(
          artist, 'clearlogo', _driveConnectLogoVersion);
      if (!mounted || model.artist.trim() != artist) return;
      if (logo != null) {
        _driveConnectLogoVersion = logo.version;
        if (settings.useArtistClearLogo && !_clearLogoIsLocal) {
          // Cancel a slower online lookup, which otherwise could overwrite
          // the logo VYBE Connect has already delivered.
          ++_clearLogoRequest;
          _clearLogoLoadingArtist = '';
          _clearLogoRetryTimer?.cancel();
          _clearLogoRetryCount = 0;
          _clearLogoArtist = artist;
          setState(() => _clearLogoBytes = logo.bytes);
        }
      }
      final fanart = await LinkArtistArtworkCache.readChanged(
          artist, 'fanart', _driveConnectFanartVersion);
      if (!mounted || model.artist.trim() != artist) return;
      if (fanart != null) {
        _driveConnectFanartVersion = fanart.version;
        if (!_fanartGalleryIsLocal) {
          ++_fanartRequest;
          _fanartLoadingArtist = '';
          _fanartRetryTimer?.cancel();
          _fanartRetryCount = 0;
          _fanartLastFailure = null;
          _fanartCycleTimer?.cancel();
          _fanartGallery = [];
          _fanartArtist = artist;
          setState(() => _fanartBytes = fanart.bytes);
        }
      }
    } finally {
      _driveConnectCheckInProgress = false;
    }
  }

  /// Begin fanart and clearlogo lookup immediately in parallel with album
  /// lookup. Fast caches should never wait on the cover search.
  void _loadArtistArtAfterCover() {
    _loadFanart();
  }

  void _onModel() {
    if (!mounted) return;
    _checkTrack();
    _scheduleSmartPrefetch();
    _loadArtistArtAfterCover();
    if (widget.driveHost) unawaited(_syncDriveConnectArt());
    setState(() {});
  }

  /// Smart Prefetch uses real Android Up Next entries, never inferred
  /// playlist songs. A changed generation cancels further stale work.
  void _scheduleSmartPrefetch() {
    if (widget.driveHost || !model.active || !model.playing ||
        !settings.artLookup || model.isSpotifyAdvertisement) {
      _smartPrefetchTimer?.cancel();
      if (_smartPrefetchSignature.isNotEmpty) ++_smartPrefetchGeneration;
      _smartPrefetchSignature = '';
      return;
    }
    final next = model.smartPrefetchQueue;
    if (next.isEmpty) {
      _smartPrefetchTimer?.cancel();
      if (_smartPrefetchSignature.isNotEmpty) ++_smartPrefetchGeneration;
      _smartPrefetchSignature = '';
      return;
    }
    final signature = '${model.artist}|${model.title}|' +
        next.map((e) => '${e.id}:${e.slot}:${e.artist}:${e.title}').join('|');
    if (signature == _smartPrefetchSignature) return;
    _smartPrefetchSignature = signature;
    final generation = ++_smartPrefetchGeneration;
    _smartPrefetchTimer?.cancel();
    _smartPrefetchTimer = Timer(const Duration(milliseconds: 1500), () {
      unawaited(_runSmartPrefetch(next, generation));
    });
  }

  bool _smartPrefetchAllowed(int generation) =>
      mounted && !widget.driveHost && model.active && model.playing &&
      settings.artLookup && !model.isSpotifyAdvertisement &&
      generation == _smartPrefetchGeneration;

  void _retainPreparedArtist(
      Map<String, Uint8List> cache, String key, Uint8List bytes) {
    if (bytes.isEmpty) return;
    cache.remove(key);
    cache[key] = bytes;
    while (cache.length > 3) cache.remove(cache.keys.first);
  }

  Future<void> _runSmartPrefetch(
      List<CoverflowCover> upcoming, int generation) async {
    try {
      // The current song must finish its own cover load before background
      // network work starts, especially on the 2 GB A5L.
      for (var attempt = 0; attempt < 12; attempt++) {
        if (!_smartPrefetchAllowed(generation)) return;
        if (!model.albumArtPriorityPending && model.art != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (!_smartPrefetchAllowed(generation) ||
          model.albumArtPriorityPending || model.art == null) return;
      for (final entry in upcoming.take(2)) {
        if (!_smartPrefetchAllowed(generation)) return;
        // Sequential requests avoid overwhelming the network and VYBE Link.
        await model.prefetchQueueAlbum(entry);
        if (!_smartPrefetchAllowed(generation)) return;
        await _prefetchArtistAssets(entry.artist, generation);
      }
    } catch (error) {
      debugPrint('VYBE Smart Prefetch unavailable: $error');
    }
  }

  Future<void> _prefetchArtistAssets(String artist, int generation) async {
    final key = _smartArtistKey(artist);
    if (key.isEmpty || !_smartPrefetchAllowed(generation)) return;
    final apiKey = settings.fanartProjectKey;
    final personalKey = settings.fanartApiKey;
    if (!_smartPrefetchFanart.containsKey(key)) {
      Uint8List? bytes = await _fanart.getCachedFanart(artist);
      if (!_smartPrefetchAllowed(generation)) return;
      final local = await LocalArtwork.instance.fanartGallery(
          artist, rescanOnMiss: false);
      if (!_smartPrefetchAllowed(generation)) return;
      if (local.isNotEmpty) bytes = local.first;
      if (bytes == null && apiKey.isNotEmpty) {
        bytes = await _fanart.get(artist, apiKey,
            personalKey: personalKey, cacheChecked: true);
      }
      if (!_smartPrefetchAllowed(generation)) return;
      if (bytes != null && bytes.isNotEmpty) {
        _retainPreparedArtist(_smartPrefetchFanart, key, bytes);
        debugPrint('VYBE Smart Prefetch: ready fanart for $artist');
      }
    }

    if (!settings.useArtistClearLogo || !_smartPrefetchAllowed(generation) ||
        _smartPrefetchLogos.containsKey(key)) return;
    Uint8List? logo = await _fanart.getCachedClearLogo(artist);
    if (!_smartPrefetchAllowed(generation)) return;
    final localLogo = await LocalArtwork.instance.clearLogo(
        artist, rescanOnMiss: false);
    if (!_smartPrefetchAllowed(generation)) return;
    if (localLogo != null && localLogo.isNotEmpty) logo = localLogo;
    if (logo == null && apiKey.isNotEmpty) {
      logo = await _fanart.getClearLogo(artist, apiKey,
          personalKey: personalKey, cacheChecked: true);
    }
    if (!_smartPrefetchAllowed(generation)) return;
    if (logo != null && logo.isNotEmpty) {
      _retainPreparedArtist(_smartPrefetchLogos, key, logo);
      debugPrint('VYBE Smart Prefetch: ready clearlogo for $artist');
    }
  }

  void _onSettings() {
    if (!mounted) return;
    // A material change adds/removes padding around the synthetic logo.
    // Recompute wrap/marquee measurements so no old widths are reused.
    _artistWidthCache.clear();
    if (model.visualizerEnabled != settings.visualizer) {
      model.setVisualizer(settings.visualizer);
    }
    _fxGovernor.enabled = settings.fxPerformanceMode == 0;
    if (!_fxGovernor.enabled) _fxTier = 2;
    model.setArtLookup(settings.artLookup);
    _scheduleSmartPrefetch();
    // The lyric-led Typo theme must request synced lyrics even when the
    // global lyrics toggle is off. The other themes retain the toggle.
    final wantsLyrics = settings.lyrics || settings.theme == AppSettings.tTypo;
    if (model.lyricsEnabled != wantsLyrics) {
      model.setLyricsEnabled(wantsLyrics);
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
    _loadArtistArtAfterCover();
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
      _night = settings.isScheduledNight(now.hour * 60 + now.minute);
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
    if (dt < 0.014) return; // target 60 fps on capable Android displays; adaptive GPU FX handles slower hardware
    _last = elapsed;
    dt = dt.clamp(0.0, 0.1).toDouble();
    _time += dt;
    if (settings.artistLogoMotion > 0) {
      _artistLogoPhase +=
          dt * settings.artistLogoMotion.clamp(0.0, 2.0).toDouble();
    }
    // A shared clock keeps album-art and fanart motion identical. Integrate
    // the speed rather than multiplying elapsed time: dragging the slider
    // must never jump the photo to a different position.
    if (settings.cinematicAnimationSpeed > 0) {
      _artworkMotionPhase.value += dt *
          settings.cinematicAnimationSpeed.clamp(0.0, 3.0);
    }

    // Visualizer bars may simulate if Android denies audio capture.
    // Lighting/Beat Pulse MUST NOT use that fake bass or random beat clock.
    sim.update(dt, model.playing, real: model.realActive ? model.fft : null);
    ripples.update(_time, model.realActive ? model.fft : null,
        model.fftFrame, model.playing);
    final kickPulse = ripples.pulseAt(_time);
    particles.t += dt * (0.25 + 1.2 * kickPulse);
    grid.scroll += dt * (0.12 + 0.9 * kickPulse);
    _stepGlitch();
    fxClock.t = _time;
    fxClock.bass = kickPulse;
    // Accumulate ray rotation independently of playback and the other FX.
    // This keeps its angle continuous when the speed slider changes,
    // and holds the beams in place at 0 rather than resetting their angle.
    fxClock.rayPhase += dt *
        settings.rayRotationSpeed.clamp(0.0, 2.0).toDouble();

    // Record Cut and Drive: 33 1/3 rpm is one turn every 1.8 seconds. It speeds up
    // over about 0.75 s, slows over about 1.5 s, and keeps its angle.
    if (settings.theme == AppSettings.tRecord ||
        settings.theme == AppSettings.tEditorial ||
        settings.theme == AppSettings.tMusicVideo || settings.theme == 4) {
      const full = 1 / 1.8;
      final target = (model.playing ||
          (settings.theme == AppSettings.tMusicVideo && _musicVideoIsPlaying))
          ? full : 0.0;
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
        artistClearLogo: _clearLogoBytes,
        fanartBytes: _fanartBytes,
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
      builder: (_) => SettingsScreen(settings: settings, model: model,
        onOpenRiotEditor: _openRiotSpacingEditor),
    ));
  }

  void _onRiotSpacingChanged() {
    // Both rendering and wrapping use the same saved measurements.
    _artistWidthCache.clear();
    if (mounted) setState(() {});
  }

  void _openRiotSpacingEditor() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RiotSpacingEditor(
        initialText: model.active && model.artist.trim().isNotEmpty
            ? model.artist : 'A.B, C 2026',
        previewBuilder: (text, size) => _artistText(
          size, letteringOverride: text, color: Colors.white,
          logoTreatment: false),
      ),
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
          _headUnitControls ? 24 : 12, 0, _headUnitControls ? 24 : 12,
          math.max(_headUnitControls ? 24.0 : 12.0, MediaQuery.viewPaddingOf(sheetContext).bottom)),
        child: QuickCustomizeSheet(
          settings: settings,
          headUnit: _headUnitControls,
          accent: _palette.a,
          onOpenFx: () {
            Navigator.of(sheetContext).pop();
            Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => FxLibraryScreen(settings: settings)));
          },
          onOpenRiotEditor: () {
            Navigator.of(sheetContext).pop();
            _openRiotSpacingEditor();
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
        onTap: settings.theme == AppSettings.tMusicVideo && !widget.driveHost
            ? null : _toggleControls,
        onHorizontalDragStart: settings.theme == AppSettings.tMusicVideo &&
                !widget.driveHost ? null
            : (_) => _horizontalSwipeDistance = 0,
        onHorizontalDragUpdate: settings.theme == AppSettings.tMusicVideo &&
                !widget.driveHost ? null
            : (d) => _horizontalSwipeDistance += d.delta.dx,
        onHorizontalDragCancel: settings.theme == AppSettings.tMusicVideo &&
                !widget.driveHost ? null
            : () => _horizontalSwipeDistance = 0,
        onHorizontalDragEnd: settings.theme == AppSettings.tMusicVideo &&
                !widget.driveHost ? null
            : (d) {
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
          key: _fxViewportKey,
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
            // Video playback owns its visuals. Global shaders and spectrum FX
            // behind the WebView would be invisible but still cost frame time.
            // Coverflow background-image FX must process only the fanart
            // BEFORE any of the projected album sleeves are painted.
            // Emitted light/particles take the dedicated mid-depth stage.
            if (heavy && settings.theme != AppSettings.tMusicVideo)
              ..._shaderFxLayers(
                coverflowBackdropOnly:
                    settings.theme == AppSettings.tCoverflow),
            if (heavy && settings.theme != AppSettings.tMusicVideo)
              ..._extraFx(),
            if (vhs && !_gpuFxActive &&
                settings.theme != AppSettings.tMusicVideo)
              FxComposite(mode: settings.fxBlendMode['VHS'] ?? 0,
              opacity: settings.fxBlendOpacity['VHS'] ?? 1.0,
              child: Transform.scale(scale: settings.fxSize['VHS'] ?? 1.0,
                child: Stack(fit: StackFit.expand, children: _vhsBackdrop(fx)))),
            if (settings.bgEffects && settings.particles && heavy &&
                settings.theme != AppSettings.tMusicVideo &&
                settings.theme != AppSettings.tCoverflow && !_gpuFxActive)
              _floatingParticleLayer(),
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
                } else if (settings.theme == AppSettings.tCoverflow) {
                  layout = _coverflowLayout(w, h, heavy: heavy);
                } else if (settings.theme == AppSettings.tMusicVideo) {
                  layout = MusicVideoTheme(
                    title: model.title,
                    artist: model.artist,
                    album: model.displayAlbumTitle,
                    sourcePackage: model.sourcePlayerPackage,
                    sourceTrackTitle: model.sourceTrackTitle,
                    sourceTrackArtist: model.sourceTrackArtist,
                    artwork: model.art?.bytes,
                    fallbackArtwork: model.art?.bytes,
                    fanart: _fanartBytes,
                    clearLogo: settings.useArtistClearLogo ? _clearLogoBytes : null,
                    accent: _palette.a,
                    buildVinyl: _vinyl,
                    // Share the VYBE typography, ClearLogo, and fallback renderers.
                    buildArtist: (a) => _metadataText(_VybeTextRole.artist, a),
                    buildTitle: (a) => _metadataText(_VybeTextRole.title, a),
                    buildAlbum: (a) => _metadataText(_VybeTextRole.album, a),
                    buildFallbackBackground: _musicVideoFallbackBackground,
                    backgroundDarkness: settings.bgOverlay,
                    artistLogoScale: settings.artistLogoScale,
                    onVideoPlaybackChanged: (playing) {
                      _musicVideoIsPlaying = playing;
                    },
                    sourcePositionMs: model.positionMs,
                    sourceDurationMs: model.durationMs,
                    sourcePlaying: model.playing,
                    onSeekSource: model.seekTo,
                    onSourcePlayPause: model.playPause,
                    onCaptureSourceArtwork: model.captureYoutubeSongArtwork,
                    onOpenThemes: _pickTheme,
                    onToggleUtilityMenu: _toggleControls,
                    onOpenCustomize: _openQuickCustomize,
                    onOpenSettings: _openSettings,
                  );
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
                      // When Typo shows lyrics in place of a front cover, the
                      // full-bleed album background is the artwork. Give it
                      // an exact centered anchor for both GPU and Canvas FX.
                      if (settings.theme == AppSettings.tTypo && _hasLyrics)
                        Positioned.fill(child: IgnorePointer(
                          child: Center(child: SizedBox(
                            key: _artKey, width: 1, height: 1)))),
                      // Clock is displayed only with the popup controls.
                      if (vhs && !widget.driveHost && settings.theme != 4 &&
                          settings.theme != AppSettings.tMusicVideo)
                        _osd(h, compact: narrow),
                    ],
                  ),
                );
              }),
            // These sit on top of everything, so they must not catch touches.
            if (vhs && !_gpuFxActive &&
                settings.theme != AppSettings.tMusicVideo)
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
            // Music Video's independent VHS intensity starts at OFF (0).
            // Skip every VHS layer when zero; only draw overlays on demand.
            if (!widget.driveHost &&
                settings.theme == AppSettings.tMusicVideo &&
                settings.musicVideoVhs > 0.0)
              IgnorePointer(
                child: FxComposite(
                  mode: settings.fxBlendMode['VHS'] ?? 0,
                  opacity: settings.fxBlendOpacity['VHS'] ?? 1.0,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ..._vhsOverlay(settings.musicVideoVhs,
                          !settings.performance &&
                              settings.fxPerformanceMode == 0),
                      RepaintBoundary(
                        child: CustomPaint(
                          painter: MusicVideoTrackingPainter(
                            intensity: settings.musicVideoVhs,
                            clock: () => _time,
                            repaint: _tick,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            // Night Mode uses window brightness, never a text-dimming overlay.
            if (settings.theme != AppSettings.tMusicVideo || widget.driveHost)
              _progressLine(),
            // The embedded Music Video timeline must be the ONLY progress
            // line; the normal popup would control the wrong MediaSession.
            if (controlsInside && settings.theme == AppSettings.tMusicVideo)
              _musicVideoUtilityPopup(),
            if (controlsInside &&
                settings.theme != AppSettings.tMusicVideo) ...[
              if (settings.showClock) _controlsClockHeader(),
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
            if (settings.showClock) _controlsClockHeader(),
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

  /// Preserve the full credited artist whenever it is a real MusicBrainz
  /// artist, e.g. the duo Eli & Fur. For collaborations or explicit guest
  /// credits, only fall back to the lead artist after the full-name miss.
  bool _canTryLeadArtistArtwork(String creditedArtist) =>
      leadArtistArtworkFallback(creditedArtist) != null &&
      (hasExplicitFeaturedArtist(creditedArtist) ||
          _fanart.confirmedArtistNameMiss(creditedArtist));

  Future<void> _loadClearLogo() async {
    final artist = model.artist.trim();
    if (!settings.useArtistClearLogo || artist.isEmpty || model.isSpotifyAdvertisement) {
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
      // Show prepared logo immediately, then allow a manual local replacement.
      final preparedLogo = _smartPrefetchLogos[_smartArtistKey(artist)];
      if (mounted) setState(() => _clearLogoBytes = preparedLogo);
    }
    _clearLogoLoadingArtist = artist;
    final request = ++_clearLogoRequest;
    Uint8List? bytes;
    bool localLogo = false;
    bool transferred = false;
    try {
      // Read VYBE Cache BEFORE attempting the local artwork index scan.
      // Missing named local files previously caused a full music-folder
      // rescan before reaching this already-downloaded clearlogo.
      bytes = await _fanart.getCachedClearLogo(artist);
      if (bytes != null && bytes.isNotEmpty &&
          mounted && request == _clearLogoRequest &&
          _clearLogoArtist == artist) {
        // Publish instantly, before expensive alpha trimming or a manual
        // local-art scan. A manual artist logo may replace this image later.
        setState(() => _clearLogoBytes = bytes);
        final link = VybeLink.instance;
        if (!widget.driveHost && link.enabled && link.role == 'sender') {
          link.sendClearLogo(artist, bytes);
        }
      }
      final manualLogo = await LocalArtwork.instance.clearLogo(
          artist, rescanOnMiss: false);
      if (manualLogo != null && manualLogo.isNotEmpty) {
        bytes = manualLogo;
        localLogo = true;
      }
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
            personalKey: settings.fanartApiKey, cacheChecked: true);
        transferred = false;
      }
      if ((bytes == null || bytes.isEmpty) &&
          _canTryLeadArtistArtwork(artist)) {
        final lead = leadArtistArtworkFallback(artist)!;
        // Check existing offline artwork first. A missing full credit must
        // not force a new download when the main artist is already cached.
        final savedLead = await _fanart.getCachedClearLogo(lead);
        final localLead = await LocalArtwork.instance.clearLogo(lead,
            rescanOnMiss: false);
        if (localLead != null && localLead.isNotEmpty) {
          bytes = localLead;
          localLogo = true;
        } else if (savedLead != null && savedLead.isNotEmpty) {
          bytes = savedLead;
        } else if (settings.fanartProjectKey.isNotEmpty) {
          bytes = await _fanart.getClearLogo(lead, settings.fanartProjectKey,
              personalKey: settings.fanartApiKey, cacheChecked: true);
        }
        if (bytes != null && bytes.isNotEmpty) {
          debugPrint('VYBE clearlogo: using lead artist $lead for $artist');
        }
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
    if (model.isSpotifyAdvertisement) {
      // Spotify ad metadata is not an artist. Clear old artist imagery and
      // avoid querying MusicBrainz/Fanart.tv for "Advertisement 2 of 3".
      _fanartRetryTimer?.cancel();
      _fanartCycleTimer?.cancel();
      _fanartRetryCount = 0;
      _fanartLastFailure = null;
      _fanartGallery = [];
      if (_fanartArtist.isNotEmpty || _fanartBytes != null) {
        ++_fanartRequest;
        _fanartArtist = '';
        _fanartLoadingArtist = '';
        if (mounted) setState(() => _fanartBytes = null);
      }
      return;
    }
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
        LocalArtwork.instance.fanartGallery(
            artist, rescanOnMiss: false).then((gallery) {
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
        settings.theme == AppSettings.tEditorial ||
        settings.theme == AppSettings.tCoverflow ||
        settings.theme == AppSettings.tMusicVideo;
    final needsLocalFanart = isFanartTheme
        ? !settings.fanartOverride
        : settings.backgroundSource == 6 ||
            (settings.backgroundSource == 0 && settings.fanartMode == 1);
    final needsFanart = needsLocalFanart || linkSender;
    if (!needsFanart || artist.isEmpty) {
      // An explicitly selected album/palette background shouldn't erase
      // Connect artwork that Drive may need when switching to Fanart.
      if (widget.driveHost && artist.isNotEmpty &&
          _fanartArtist == artist && _fanartBytes != null) return;
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
    // Prepared fanart is immediately available without asynchronous disk I/O.
    _fanartBytes = _smartPrefetchFanart[_smartArtistKey(artist)];
    _fanartLoadingArtist = artist;
    final request = ++_fanartRequest;
    try {
      // Cache hits must be visible immediately, not after a potentially
      // expensive scan of the user's music-folder tree.
      final cached = await _fanart.getCachedFanart(artist);
      if (cached != null && cached.isNotEmpty && mounted &&
          request == _fanartRequest && _fanartArtist == artist) {
        setState(() => _fanartBytes = cached);
        if (linkSender) link.sendFanart(artist, cached);
      }
      var localGallery = await LocalArtwork.instance.fanartGallery(
          artist, rescanOnMiss: false);
      Uint8List? localBytes = localGallery.isEmpty ? null : localGallery.first;
      Uint8List? bytes = localBytes ?? cached ??
          (settings.fanartProjectKey.isEmpty ? null :
              await _fanart.get(artist, settings.fanartProjectKey,
                  personalKey: settings.fanartApiKey, cacheChecked: true));
      var resolvedArtist = artist;
      if ((bytes == null || bytes.isEmpty) &&
          _canTryLeadArtistArtwork(artist)) {
        final lead = leadArtistArtworkFallback(artist)!;
        final savedLead = await _fanart.getCachedFanart(lead);
        final galleryLead = await LocalArtwork.instance.fanartGallery(lead,
            rescanOnMiss: false);
        final localLead = galleryLead.isEmpty ? null : galleryLead.first;
        final foundLead = localLead ?? savedLead ??
            (settings.fanartProjectKey.isEmpty ? null :
                await _fanart.get(lead, settings.fanartProjectKey,
                    personalKey: settings.fanartApiKey, cacheChecked: true));
        if (foundLead != null && foundLead.isNotEmpty) {
          resolvedArtist = lead;
          localGallery = galleryLead;
          localBytes = localLead;
          bytes = foundLead;
          debugPrint('VYBE fanart: using lead artist $lead for $artist');
        }
      }
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
          _fanart.getGallery(resolvedArtist, settings.fanartProjectKey,
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
  // Shared real-FFT kick impulse. When audio capture is unavailable,
  // Beat Pulse is still rather than synthesizing a phantom drum.
  double get _kickPulse => model.playing && model.realActive
      ? ripples.pulseAt(_time) : 0.0;

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
      bass: _kickPulse,
      // Read real kick transients at each GPU repaint, not smoothed or
      // simulated visualizer bass at the last widget rebuild.
      bassSample: () => _kickPulse,
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
        bass: _kickPulse,
        motion: settings.templateBackgroundMotion,
      ),
      child: const SizedBox.expand(),
    ),
  );

  /// Only build fallback visuals when the Music Video embed is unavailable.
  /// Preserve album/fanart motion and source, plus all photo filters.
  Widget _musicVideoFallbackBackground() {
    if (settings.backgroundSource == 1) {
      return ColorFiltered(
        colorFilter: _contrastFilter(settings.bgContrast),
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: settings.bgBlur, sigmaY: settings.bgBlur,
            tileMode: TileMode.clamp),
          child: _premiumAnimatedBackground(settings.templateBackgroundMotion),
        ),
      );
    }
    final photo = _fanartBytes != null &&
        (settings.backgroundSource == 6 ||
         (settings.backgroundSource == 0 && settings.fanartMode == 1));
    final background = _albumBackdrop();
    // Album already has contrast; fanart needs it added here.
    return photo
        ? ColorFiltered(colorFilter: _contrastFilter(settings.bgContrast),
            child: background)
        : background;
  }

  Widget _background() {
    // The video theme owns its fallback so it can avoid rendering under video.
    // Do not render a second animated, blurred backdrop underneath WebView:
    // this is unnecessary GPU work on the ATOTO A5L.
    if (!widget.driveHost && settings.theme == AppSettings.tMusicVideo) {
      return const ColoredBox(color: Color(0xFF090911));
    }
    if (!model.active && !widget.driveHost) {
      return _edgyStandbyBackground();
    }
    if (!widget.driveHost &&
        (settings.theme == AppSettings.tCinematic ||
         settings.theme == AppSettings.tEditorial ||
         settings.theme == AppSettings.tCoverflow ||
         settings.theme == AppSettings.tMusicVideo)) {
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

  // Render from the ORIGINAL cover bytes at the screen's useful resolution.
  // The 96 px palette sample must never fill a backdrop.
  // A display-sized image-cache decode protects slow head units from decoding
  // enormous camera originals while avoiding blurry, blown-up thumbnails.
  Widget _albumBackgroundImage(ArtAssets art) {
    final screen = MediaQuery.sizeOf(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final decodeWidth = (screen.longestSide * pixelRatio * 1.15)
        .round().clamp(720, 2048).toInt();
    return Image.memory(
      art.bytes,
      fit: BoxFit.cover,
      cacheWidth: decodeWidth,
      gaplessPlayback: true,
      filterQuality: FilterQuality.high,
    );
  }

  Widget _albumBackdrop() {
    if ((settings.backgroundSource == 6 ||
        (settings.backgroundSource == 0 && settings.fanartMode == 1)) &&
        _fanartBytes != null) {
      // Keep artist photography sharp when the popup says "Off".
      final fanartBlur = (settings.bgBlur - 6.0)
          .clamp(0.0, 12.0).toDouble();
      final fanartImage = Image.memory(_fanartBytes!,
          fit: BoxFit.cover, gaplessPlayback: true,
          filterQuality: FilterQuality.high);
      Widget fanart = Stack(fit: StackFit.expand, children: [
        fanartBlur == 0 ? fanartImage : ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: fanartBlur, sigmaY: fanartBlur,
            tileMode: TileMode.clamp),
          child: fanartImage,
        ),
        // Independent fanart darkness for themes using artist photos.
        ColoredBox(color: Colors.black.withOpacity(
          settings.cinematicDarkness.clamp(0.0, 1.0))),
      ]);
      // Motion speed is controlled by the shared Artwork speed slider,
      // not by the unrelated FX enable switch.
      // A speed of zero pauses the photo in place, without a jump.
      fanart = _drift(RepaintBoundary(child: fanart));
      if (settings.bgEffects) {
        fanart = FxComposite(
          mode: settings.fxBlendMode['Background Motion'] ?? 0,
          opacity: settings.fxBlendOpacity['Background Motion'] ?? 1.0,
          child: fanart);
      }
      return fanart;
    }
    final art = model.art;
    final usingVybePlaceholder = art == null || art.flat;
    // A playing song with no cover still uses the same blurred-artwork
    // structure as a song with album art. The idle animation belongs to
    // the actual no-playback state, handled in _background().
    // True zero has no ImageFilter at all: the original cover is sharp.
    final albumBackdropImage = usingVybePlaceholder
        ? Image.asset('assets/vybe_album_placeholder.png',
            fit: BoxFit.cover, filterQuality: FilterQuality.high)
        : _albumBackgroundImage(art!);
    final albumBlur = settings.bgBlur.clamp(0.0, 18.0).toDouble();
    Widget blurred = RepaintBoundary(
      child: ColorFiltered(
        colorFilter: _contrastFilter(settings.bgContrast),
        child: albumBlur == 0
            ? albumBackdropImage
            : ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                    sigmaX: albumBlur, sigmaY: albumBlur,
                    tileMode: TileMode.clamp),
                child: albumBackdropImage,
              ),
      ),
    );
    // Keep the same transform when paused; only the shared phase stops.
    blurred = _drift(blurred);
    if (settings.bgEffects) {
      blurred = FxComposite(
        mode: settings.fxBlendMode['Background Motion'] ?? 0,
        opacity: settings.fxBlendOpacity['Background Motion'] ?? 1.0,
        child: blurred,
      );
    }
    final child = SizedBox.expand(
      key: usingVybePlaceholder
          ? const ValueKey('vybe-placeholder-artwork') : ValueKey(art),
      child: blurred,
    );
    return ClipRect(child: SizedBox.expand(child: AnimatedSwitcher(
        layoutBuilder: (currentChild, previousChildren) => Stack(
          fit: StackFit.expand,
          children: [...previousChildren, if (currentChild != null) currentChild]),
        duration: const Duration(milliseconds: 800), child: child)));
  }

  /// GPU-composited motion applied to the decoded artwork or fanart layer,
  /// never to metadata or transport controls. Motion selections are per-theme.
  /// Overscan prevents exposed edges even with rotation/perspective movement.
  Widget _drift(Widget child) {
    return AnimatedBuilder(
      animation: _artworkMotionPhase,
      child: child,
      builder: (context, c) {
        final size = MediaQuery.sizeOf(context);
        final phase = _artworkMotionPhase.value;
        final intensity = (settings.bgEffects
            ? settings.kMotion.clamp(0.0, 1.0) : 0.0).toDouble();
        double dx = 0, dy = 0, scale = 1.0, rotation = 0;
        double rotateX = 0, rotateY = 0;
        switch (settings.artworkMotionType) {
          case 1: // Ken Burns: drifting push/pull, not a continuous zoom.
            final push = (math.sin(phase * .17) + 1.0) * .5;
            scale = 1.17 + .16 * intensity * push;
            dx = math.sin(phase * .12) * size.width * .022 * intensity;
            dy = math.cos(phase * .10) * size.height * .022 * intensity;
            break;
          case 2: // Orbit: a smooth elliptical camera path.
            scale = 1.28;
            dx = math.cos(phase * .15) * size.width * .09 * intensity;
            dy = math.sin(phase * .15) * size.height * .078 * intensity;
            break;
          case 3: // Pendulum: gentle physical rocking with spatial drift.
            scale = 1.32;
            rotation = math.sin(phase * .19) * .035 * intensity;
            dx = math.sin(phase * .19) * size.width * .046 * intensity;
            dy = math.cos(phase * .11) * size.height * .025 * intensity;
            break;
          case 4: // Horizontal pan across a large, overscanned photo.
            scale = 1.30;
            dx = math.sin(phase * .14) * size.width * .11 * intensity;
            dy = math.sin(phase * .08) * size.height * .018 * intensity;
            break;
          case 5: // Breathing zoom. No hard cut at the scale extrema.
            scale = 1.15 + .18 * intensity *
                (.5 + .5 * math.sin(phase * .27));
            dx = math.sin(phase * .10) * size.width * .012 * intensity;
            dy = math.cos(phase * .10) * size.height * .012 * intensity;
            break;
          case 6: // Parallax: perspective tilt on an overscanned GPU layer.
            scale = 1.32;
            dx = math.sin(phase * .12) * size.width * .045 * intensity;
            dy = math.cos(phase * .15) * size.height * .03 * intensity;
            rotateX = math.cos(phase * .17) * .055 * intensity;
            rotateY = math.sin(phase * .14) * .070 * intensity;
            break;
          default: // Classic drift retains the existing look exactly at 100%.
            scale = 1.28;
            dx = math.sin(phase * .16) * size.width * .085 * intensity;
            dy = math.cos(phase * .12) * size.height * .075 * intensity;
        }
        final matrix = Matrix4.identity()
          ..setEntry(3, 2, .0005)
          ..translate(dx, dy)
          ..rotateX(rotateX)
          ..rotateY(rotateY)
          ..rotateZ(rotation)
          ..scale(scale);
        return Transform(
          alignment: Alignment.center,
          transform: matrix,
          child: c,
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
    // An unavailable album cover still has a designed VYBE image. An
    // explicitly selected animated fallback remains an intentional choice.
    final useVybePlaceholder = !showFanart && !hasAlbum &&
        settings.fanartFallbackSource == 0;
    final hasImage = showFanart || useAlbum || useVybePlaceholder;
    final Widget background = showFanart
        ? Image.memory(fanart, fit: BoxFit.cover,
            alignment: Alignment.topCenter, gaplessPlayback: true)
        : useAlbum
            ? _albumBackgroundImage(art)
            : useVybePlaceholder
                ? Image.asset('assets/vybe_album_placeholder.png',
                    fit: BoxFit.cover)
                : _cinematicAnimatedFallback();
    // Album and fanart have separate popup values. Previously album art
    // always added 6 to the blur, making zero impossible to reach.
    final cinematicActualBlur = showFanart
        ? settings.cinematicBlur
        : settings.cinematicAlbumBlur;
    final correctedImage = ColorFiltered(
      colorFilter: _contrastFilter(settings.cinematicContrast),
      child: background,
    );
    final image = hasImage && cinematicActualBlur > 0
        ? ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: cinematicActualBlur,
              sigmaY: cinematicActualBlur,
              tileMode: TileMode.clamp),
            child: correctedImage)
        : correctedImage;
    // In BigFan/Muzine, move the chosen fanart OR album background without
    // moving the sleeve, vinyl or metadata. Placeholder images stay still.
    final movingImage = showFanart || useAlbum
        ? _drift(RepaintBoundary(child: image))
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
                useVybePlaceholder ? 'cinematic-vybe-placeholder' :
                'cinematic-template:${settings.cinematicPalette}'),
            child: movingImage))),
      ),
      // Edge vignette follows album blur, too: its old fixed sigma=24
      // prevented a truly sharp album even when the main blur was zero.
      // Fanart retains its established cinematic side softening.
      if (hasImage && settings.theme != AppSettings.tCoverflow &&
          (showFanart || settings.cinematicAlbumBlur > 0))
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
              imageFilter: ui.ImageFilter.blur(
                sigmaX: showFanart ? 24.0
                    : (settings.cinematicAlbumBlur * 4.0).clamp(0.0, 24.0).toDouble(),
                sigmaY: showFanart ? 24.0
                    : (settings.cinematicAlbumBlur * 4.0).clamp(0.0, 24.0).toDouble()),
              child: SizedBox.expand(child: showFanart
                  ? Image.memory(fanart, fit: BoxFit.cover,
                      alignment: Alignment.topCenter, gaplessPlayback: true)
                  : useAlbum
                      ? _albumBackgroundImage(art!)
                      : Image.asset('assets/vybe_album_placeholder.png',
                          fit: BoxFit.cover)),
            ),
          ))),
        ),
      // Shared fanart darkness, independent of the intentional bottom fade.
      ColoredBox(color: Colors.black.withOpacity(
        settings.cinematicDarkness.clamp(0.0, 1.0))),
      // Coverflow's own floor shader handles its reflection horizon.
      // The cinematic bottom mask made its textured floor almost black.
      if (settings.theme != AppSettings.tCoverflow)
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

  // ONE typography scale for every theme. Layouts control placement, not
  // font sizes. Riot has smaller visible brush strokes than the title font,
  // so its base size must be twice the title size before Riot glyph scaling.
  // Keep this relationship in ONE place for portrait, landscape and idle.
  static const double _portraitFeatureTitleRatio = .033;
  static const double _portraitFeatureAlbumRatio = .021;
  static const double _landscapeTitleRatio = .050;
  static const double _landscapeAlbumRatio = .025;
  static const double _portraitIdleTitleRatio = .022;
  static const double _landscapeIdleTitleRatio = .029;
  static const double _artistToTitleBaseRatio = 2.0;

  bool get _textPortrait {
    final screen = MediaQuery.sizeOf(context);
    return screen.height > screen.width * 1.1;
  }

  // All themes use the SAME artist renderer and proportional size. Riot's
  // existing 1.45 glyph scaling and custom kerning remain untouched.
  double _artistFontSize(double unusedRequested) =>
      _songFontSize(0) * _artistToTitleBaseRatio;

  double _songFontSize(double unusedRequested) {
    final screen = MediaQuery.sizeOf(context);
    return screen.height * (model.active
        ? (_textPortrait ? _portraitFeatureTitleRatio : _landscapeTitleRatio)
        : (_textPortrait ? _portraitIdleTitleRatio : _landscapeIdleTitleRatio));
  }

  double _albumFontSize(double unusedRequested) {
    final screen = MediaQuery.sizeOf(context);
    return screen.height * (_textPortrait
        ? _portraitFeatureAlbumRatio : _landscapeAlbumRatio);
  }

  // Single role-aware widget used by every theme. No local per-theme
  // typography decisions: artist, song, and album are rendered identically
  // in a given orientation, including the complete idle fallback text.
  Widget _metadataText(_VybeTextRole role, Alignment alignment,
      {bool vhs = false, Color? textColor, Alignment? flushFrame}) {
    switch (role) {
      case _VybeTextRole.artist:
        return _drawArtist(alignment, vhs, textColor: textColor);
      case _VybeTextRole.title:
        return _drawTitle(alignment, vhs);
      case _VybeTextRole.album:
        return _drawAlbum(alignment: alignment, flushFrame: flushFrame);
    }
  }

  /// Approved VYBE Coverflow: fanart + real receding MediaSession covers,
  /// luminous edges, layered shadows and a textured mirrored floor.
  /// The visual treatment is fixed; EVERY illuminated accent follows the
  /// current album's extracted palette or the user-selected VYBE override.
  Widget _coverflowLayout(double w, double h, {required bool heavy}) {
    // Coverflow's reference has a large, near-full-width artist logo.
    // _scaledClearLogo reserves a smaller fraction of its box for ordinary
    // themes, which made this logo roughly HALF the intended size.
    // Respect the existing clearlogo size control without shrinking it down.
    final logo = settings.useArtistClearLogo &&
            _clearLogoBytes != null && model.active
        ? Transform.scale(
            scale: (0.77 + 0.23 * settings.artistLogoScale)
                .clamp(.72, 1.17).toDouble(),
            child: Image.memory(
              _clearLogoBytes!,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
            ))
        : _metadataText(_VybeTextRole.artist, Alignment.center);
    final trackKey = '${model.artist}|${model.album}|${model.title}';
    return CoverflowScene(
      trackKey: trackKey,
      activeCover: model.art?.bytes,
      queue: model.coverflowCovers,
      palette: _palette,
      // Coverflow projects its own sleeves; it does not use _front().
      // Wire Cover Bloom to the actual Coverflow stage instead.
      coverBloom: settings.fxBloom,
      bloomStrength: (settings.kBloom *
          (settings.fxBlendOpacity['Cover Bloom'] ?? 1.0)).clamp(0.0, 1.0).toDouble(),
      bloomSize: (settings.fxSize['Cover Bloom'] ?? 1.0).clamp(0.35, 2.5).toDouble(),
      artistHeader: logo,
      artAnchorKey: _artKey,
      onTapCover: _openPlayer,
      trackTitle: _metadataText(_VybeTextRole.title, Alignment.center),
      albumPlaque: _metadataText(_VybeTextRole.album, Alignment.center),
      leftVisualizer: settings.visualizer
          ? _edgeBars(w * .08, leftEdge: true) : null,
      rightVisualizer: settings.visualizer
          ? _edgeBars(w * .08, leftEdge: false) : null,
      // Only album-emitted FX appear above the SIDE sleeves.
      // Image refraction, ambient distortion, and perspective effects
      // already ran on the fanart BELOW all sleeves in the root stack.
      depthFx: heavy
          ? <Widget>[
              ..._shaderFxLayers(coverflowMidOnly: true),
              ..._extraFx(coverflowDepthOnly: true),
              if (settings.bgEffects && settings.particles && !_gpuFxActive)
                _floatingParticleLayer(),
            ]
          : const <Widget>[],
      performanceMode: _fxTier <= 1,
      // Keep the approved Screen look on the phone, but use a simpler
      // visible alpha composite on a Wi-Fi Direct receiving head unit.
      headUnitReceiver: VybeLink.instance.enabled &&
          VybeLink.instance.role == 'receiver',

    );
  }

  /// Editorial: an angled, recognizable album sleeve over full-bleed
  /// artist photography. Both orientations have their own composition.
  /// Editorial: full-bleed fanart, a grayscale album-art backing and a
  /// separate rotated color sleeve. The two orientations are art-directed.
  Widget _editorialLayout(double w, double h) {
    final portrait = h > w * 1.1;
    final flipped = settings.layoutSwap && !portrait;
    // Recede the grayscale artwork boundary 20% of its former inset:
    // 20% of viewport width -> 16%, revealing more unobstructed fanart.
    // This is landscape-only; the portrait divider remains at 20% height.
    final landscapeDividerX = w * .16;
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
    // The sleeve uses full-resolution artwork, independent of the cached
    // backdrop decode.
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
            child: readable(_albumBackgroundImage(art)))),
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
    // Muzine artwork is unique; metadata always uses the shared typography
    // widget. No local artist, song, or album TextStyle belongs here.
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
        Positioned(left: 0, top: 0, bottom: 0, width: landscapeDividerX,
          child: ClipRect(child: backing)),
        Positioned(left: landscapeDividerX - w * .002,
            top: 0, bottom: 0,
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
              _artist(0, Alignment.center, false),
              SizedBox(height: h * .006),
              _metadataText(_VybeTextRole.title, Alignment.center),
              if (_showAlbumLabel) ...[
                SizedBox(height: h * .006),
                _metadataText(_VybeTextRole.album, Alignment.center),
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
            // Keep Muzine's right-hand metadata panel where it is, but
            // center EACH role on the same axis regardless of text length.
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (settings.useArtistClearLogo &&
                  _clearLogoBytes != null && model.active)
                SizedBox(width: w * .44, height: h * .19,
                  child: _scaledClearLogo(alignment: Alignment.center))
              else
                _artist(h * .085, Alignment.center, false),
              SizedBox(height: h * .009),
              _metadataText(_VybeTextRole.title, Alignment.center),
              if (_showAlbumLabel) ...[
                SizedBox(height: h * .008),
                _metadataText(_VybeTextRole.album, Alignment.center,
                  flushFrame: Alignment.center),
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
          Positioned(left: landscapeDividerX, right: w * .035,
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
        // Muzine's sleeve does not use _front; it needs its own FX anchor.
        child: GestureDetector(
          key: _artKey,
          behavior: HitTestBehavior.opaque,
          onTap: _openPlayer,
          child: readable(sleeve))),
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
          _metadataText(_VybeTextRole.album, textAlign),
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
                _artist(0, Alignment.center, false),
                SizedBox(height: h * .008),
                _title(h * _portraitFeatureTitleRatio, Alignment.center, false),
                if (_showAlbumLabel) ...[
                  SizedBox(height: h * .006),
                  _metadataText(_VybeTextRole.album, Alignment.center),
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


  /// All compatible image effects now run as individual, stackable
  /// full-screen Impeller backdrop passes. Each pass samples the pixels
  /// produced by the previous pass, instead of painting symbolic strokes.
  /// In Compatibility mode the existing Canvas effects remain available.
  bool get _gpuFxActive =>
      ui.ImageFilter.isShaderFilterSupported &&
      !settings.performance &&
      settings.fxPerformanceMode != 1 &&
      (settings.fxPerformanceMode == 2 || _fxTier > 0);

  /// Resolve the real visible album/sleeve after layout in viewport space.
  /// If there is no measured anchor, do not emit FX at screen center.
  /// Coverflow keeps its approved stage projection.
  Offset? _currentFxOrigin() {
    if (settings.theme == AppSettings.tCoverflow) {
      return const Offset(.50, .52);
    }
    final art = _artKey.currentContext?.findRenderObject();
    final viewport = _fxViewportKey.currentContext?.findRenderObject();
    if (art is RenderBox && art.attached && art.hasSize &&
        viewport is RenderBox && viewport.attached && viewport.hasSize &&
        viewport.size.width > 0 && viewport.size.height > 0) {
      final global = art.localToGlobal(art.size.center(Offset.zero));
      final local = viewport.globalToLocal(global);
      return Offset(
        (local.dx / viewport.size.width).clamp(-.15, 1.15).toDouble(),
        (local.dy / viewport.size.height).clamp(-.15, 1.15).toDouble(),
      );
    }
    // Typo deliberately replaces the cover with lyrics. Its full-screen
    // album background is the artwork, so its center is valid here.
    if (settings.theme == AppSettings.tTypo && _hasLyrics) {
      return const Offset(.5, .5);
    }
    return null;
  }

  // Exactly one layer for each Coverflow FX. Refraction and atmospheric
  // treatment belongs behind ALL albums; luminous/particle emitters,
  // rays and kick-driven pulses belong in front of the side albums
  // but behind the focused central cover. Never duplicate an effect.
  static const Set<String> _coverflowMidFxNames = <String>{
    'Bass Shockwave', 'Electric Arcs', 'Light Trails',
    'Particle Currents', 'Beat Ripples', 'Moving Bokeh',
    'Light Rays', 'Twinkling Stars', 'Floating Particles',
  };

  List<Widget> _shaderFxLayers({
    bool coverflowBackdropOnly = false,
    bool coverflowMidOnly = false,
  }) {
    assert(!(coverflowBackdropOnly && coverflowMidOnly));
    if (!_gpuFxActive) return const <Widget>[];
    const names = <String>[
      'Liquid Refraction', 'Vortex Tunnel', 'Prism Shards',
      'Holographic Interference', 'Bass Shockwave', 'Aurora Curtains',
      'Electric Arcs', 'Light Trails', 'Morphing Wireframe',
      'Particle Currents', 'Water Shimmer', 'Beat Ripples',
      'Moving Bokeh', 'Aurora Sweep', 'Light Rays', 'Nebula Haze',
      'Perspective Grid', 'Twinkling Stars', 'Floating Particles',
      'Cover Bloom', 'VHS',
    ];
    final enabled = <bool>[
      settings.extraFx['Liquid Refraction'] ?? false,
      settings.extraFx['Vortex Tunnel'] ?? false,
      settings.extraFx['Prism Shards'] ?? false,
      settings.extraFx['Holographic Interference'] ?? false,
      settings.extraFx['Bass Shockwave'] ?? false,
      settings.extraFx['Aurora Curtains'] ?? false,
      settings.extraFx['Electric Arcs'] ?? false,
      settings.extraFx['Light Trails'] ?? false,
      settings.extraFx['Morphing Wireframe'] ?? false,
      settings.extraFx['Particle Currents'] ?? false,
      settings.fxWater, settings.fxRipples, settings.fxGlow,
      settings.fxSweep, settings.fxRays, settings.fxNebula,
      settings.fxGrid, settings.fxStars,
      settings.bgEffects && settings.particles,
      settings.fxBloom, settings.fxVhs,
    ];
    final intensity = <double>[
      for (final n in names.take(10)) settings.extraStrength[n] ?? 0.8,
      settings.kWater, settings.kRipples, settings.kGlow,
      settings.kSweep, settings.kRays, settings.kNebula,
      settings.kGrid, settings.kStars,
      settings.kParticles, settings.kBloom, settings.vhsEffects,
    ];
    final tier = settings.fxPerformanceMode == 2 ? 2 : _fxTier;
    final limit = tier <= 1 ? 5 : names.length;
    final fx = <Widget>[];
    var budgeted = 0;
    for (var i = 0; i < names.length; i++) {
      if (!enabled[i] || intensity[i] <= 0) continue;
      // Coverflow's shockwave and bloom use dedicated central-art layers.
      if (settings.theme == AppSettings.tCoverflow && (i == 4 || i == 19)) {
        continue;
      }
      // Count every enabled FX before plane selection, so splitting into
      // two calls does NOT double the performance budget or selections.
      if (budgeted >= limit) break;
      budgeted++;
      final name = names[i];
      if (settings.theme == AppSettings.tCoverflow) {
        final mid = _coverflowMidFxNames.contains(name);
        if (coverflowBackdropOnly && mid) continue;
        if (coverflowMidOnly && !mid) continue;
      }
      final strength = (intensity[i] * (tier == 1 ? .70 : 1.0))
          .clamp(0.0, 1.0).toDouble();
      final blend = const <int>[
        0, 1, 1, 2, 3, 4, 3, 1, 2, 5, 5, 6, 6, 7, 7, 7, 7,
        0, 0, 0, 0, 0, 2, 0
      ][(settings.fxBlendMode[name] ?? 0).clamp(0, 23)];
      fx.add(IgnorePointer(child: AnimatedBuilder(
        animation: _tick,
        builder: (context, _) {
          final origin = _currentFxOrigin();
          if (origin == null) return const SizedBox.expand();
          return RefractionShaderLayer(
          key: ValueKey('gpu-fx-$name'),
          time: fxClock.t,
          bass: model.playing ? fxClock.bass : 0,
          // Recompute on each animation tick; do not capture a stale onset.
          pulseAge: ripples.starts.isEmpty ? 99.0 :
              (_time - ripples.starts.last).clamp(0.0, 99.0).toDouble(),
          mode: i,
          strength: strength,
          blendMode: blend,
          blendOpacity: settings.fxBlendOpacity[name] ?? 1.0,
          effectSize: settings.fxSize[name] ?? 1.0,
          rayPhase: fxClock.rayPhase,
          origin: origin,
          colorA: _palette.a,
          colorB: _palette.b,
          colorC: _palette.c,
          child: const SizedBox.expand(),
        );
        },
      )));
    }
    return fx;
  }

  /// Full-canvas particles share the same artwork-centered source and
  /// become part of Coverflow's special mid-depth stage when applicable.
  Widget _floatingParticleLayer() => IgnorePointer(
    child: Transform.scale(
      scale: settings.fxSize['Floating Particles'] ?? 1.0,
      child: RepaintBoundary(
        child: CustomPaint(
          key: _particlesLayerKey,
          painter: _FxBlendPainter(ParticlesPainter(
              field: particles, palette: _palette, k: settings.kParticles,
              artKey: _artKey, layerKey: _particlesLayerKey,
              repaint: _tick),
              settings.fxBlendMode['Floating Particles'] ?? 0,
              settings.fxBlendOpacity['Floating Particles'] ?? 1.0),
        ),
      ),
    ),
  );

  /// The optional effects, each switched on or off in settings.
  List<Widget> _extraFx({bool coverflowDepthOnly = false}) {
    final p = _palette;
    final coverflow = settings.theme == AppSettings.tCoverflow;
    // Root scene = background FX; Coverflow depthFx = emitted FX.
    // On all other themes these run in the normal shared FX stack.
    bool inPlane(String name) {
      if (!coverflow) return true;
      final middle = _coverflowMidFxNames.contains(name);
      return coverflowDepthOnly ? middle : !middle;
    }
    // The Coverflow sleeve's perspective center is at ~52% screen height.
    // Pin artwork-emitted effects there even on the initial frame before
    // its GlobalKey is laid out, rather than spawning at the left fallback.
    // For ordinary themes, painters resolve render boxes each paint.
    // Only Coverflow has an authored stage origin that must remain pinned.
    Offset? localOrigin(String name) {
      if (!coverflow) return null;
      const fxOrigin = Offset(.50, .52);
      final full = name == 'Aurora Sweep' ||
          name == 'Moving Bokeh' || name == 'Light Rays';
      final scale = full ? 1.0 : (1.18 *
          (settings.fxSize[name] ?? 1.0)).clamp(.4, 4.0).toDouble();
      return Offset(.5 + (fxOrigin.dx - .5) / scale,
          .5 + (fxOrigin.dy - .5) / scale);
    }
    Widget layer(String name, CustomPainter painter, {GlobalKey? layerKey}) {
      final blend = settings.fxBlendMode[name] ?? 0;
      final opacity = settings.fxBlendOpacity[name] ?? 1.0;
      final size = settings.fxSize[name] ?? 1.0;
      // Keep the FX canvas full-screen. Scaling the widget itself exposes
      // its rectangular bounds when Size drops below 100%.
      final fullCanvas = name == 'Aurora Sweep' ||
          name == 'Moving Bokeh' || name == 'Light Rays';
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
            inPlane(AppSettings.extraFxNames[i]) &&
            // GPU path renders all ten with real image processing.
            // Coverflow retains the depth-anchored shockwave painter.
            (!_gpuFxActive || (coverflow && i == 1 && coverflowDepthOnly)))
          layer(AppSettings.extraFxNames[i], ExpandedFxPainter(mode: i, clock: fxClock, palette: p,
            artKey: _artKey,
            layerKey: _expandedFxLayerKeys[i],
            pinnedOrigin: localOrigin(AppSettings.extraFxNames[i]),
            bassOnsets: i == 1 ? ripples : null,
            k: settings.extraStrength[AppSettings.extraFxNames[i]] ?? 0.8, repaint: _tick),
            layerKey: _expandedFxLayerKeys[i]),
      if (inPlane('Nebula Haze') && settings.fxNebula && !_gpuFxActive)
        layer('Nebula Haze', AtmospherePainter(mode: 0, clock: fxClock, palette: p,
            k: settings.kNebula, repaint: _tick)),
      if (inPlane('Perspective Grid') && settings.fxGrid && !_gpuFxActive)
        layer('Perspective Grid', AtmospherePainter(mode: 1, clock: fxClock, palette: p,
            k: settings.kGrid, repaint: _tick)),
      if (inPlane('Twinkling Stars') && settings.fxStars && !_gpuFxActive)
        layer('Twinkling Stars', AtmospherePainter(mode: 2, clock: fxClock, palette: p,
            k: settings.kStars, repaint: _tick)),
      if (inPlane('Moving Bokeh') && settings.fxGlow && !_gpuFxActive)
        layer('Moving Bokeh', GlowPainter(
            clock: fxClock, palette: p, k: settings.kGlow,
            effectSize: settings.fxSize['Moving Bokeh'] ?? 1.0,
            artKey: _artKey, layerKey: _bokehLayerKey, repaint: _tick),
            layerKey: _bokehLayerKey),
      if (inPlane('Aurora Sweep') && settings.fxSweep && !_gpuFxActive)
        layer('Aurora Sweep', SweepPainter(
            clock: fxClock, palette: p, k: settings.kSweep,
            effectSize: settings.fxSize['Aurora Sweep'] ?? 1.0, repaint: _tick)),
      if (inPlane('Light Rays') && settings.fxRays && !_gpuFxActive)
        layer('Light Rays', RaysPainter(
            clock: fxClock,
            artKey: _artKey,
            layerKey: _raysLayerKey,
            pinnedOrigin: localOrigin('Light Rays'),
            palette: p,
            k: settings.kRays,
            effectSize: settings.fxSize['Light Rays'] ?? 1.0,
            topOrigin: false, // artwork-origin even in Typo
            repaint: _tick), layerKey: _raysLayerKey),
      if (inPlane('Beat Ripples') && settings.fxRipples && !_gpuFxActive)
        layer('Beat Ripples', RipplesPainter(
            state: ripples,
            clock: fxClock,
            artKey: _artKey,
            layerKey: _ripplesLayerKey,
            pinnedOrigin: localOrigin('Beat Ripples'),
            palette: p,
            k: settings.kRipples,
            repaint: _tick), layerKey: _ripplesLayerKey),
      if (inPlane('Water Shimmer') && settings.fxWater && !_gpuFxActive)
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

    // Focused now uses the SAME song, artist, and album widgets as every
    // other theme. Never replace the idle copy with a local alternate string.
    final text = SizedBox(
      width: w * .90,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _metadataText(_VybeTextRole.title, Alignment.center),
        if (_showAlbumLabel) ...[
          SizedBox(height: h * .012),
          _metadataText(_VybeTextRole.album, Alignment.center),
        ],
        if (_lyricTheme && settings.lyrics) SizedBox(height: lyricGap),
        if (_lyricTheme && settings.lyrics)
          SizedBox(height: lyricSlot,
            child: _hasLyrics
                ? Center(child: _lyricLine(h * .03, Alignment.center))
                : null),
      ]),
    );
    final hasArtistLogo = model.active && settings.useArtistClearLogo &&
        _clearLogoBytes != null;
    final artistHeader = SizedBox(
      width: w * (portrait ? .94 : .88),
      height: h * (portrait ? .20 : .25),
      child: Center(child: _metadataText(_VybeTextRole.artist, Alignment.center)),
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
          top: h * (hasArtistLogo ? .045 : .050),
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
                            _metadataText(_VybeTextRole.album, textAlignment),
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
                      _metadataText(_VybeTextRole.album, Alignment.center),
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
      // Drive reserves a fixed artist band above the record. Its Riot
      // lettering fits within this band in at most two stationary lines;
      // the text is scaled, not scrolled, and never grows into artwork.
      // Preserve the original artwork allocation in Drive portrait.
      // Only the artist glyphs scale to fit 1 or 2 lines in this band.
      final brandingHeight = math.min(h * .105, w * .24).toDouble();
      final songFontSize = h * .031;
      final songHeight = h * .053;
      final albumHeight = _showAlbumLabel ? h * .055 : 0.0;
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
              // Clip the artist/logo to its own reserved band. Even a
              // three-word Riot artist must never appear underneath art.
              SizedBox(width: w * .86, height: brandingHeight,
                child: ClipRect(
                  child: hasLogo
                      ? _scaledClearLogo()
                      : _drivePortraitArtist(w * .86, brandingHeight),
                )),
              SizedBox(height: brandArtGap),
              _driveArtwork(artSide),
              SizedBox(height: artSongGap),
              SizedBox(width: w * .90, height: songHeight,
                child: Center(child: _title(
                    songFontSize, Alignment.center, false))),
              if (_showAlbumLabel) ...[
                SizedBox(height: songAlbumGap),
                SizedBox(width: w * .90, height: albumHeight,
                  child: Center(child: _metadataText(_VybeTextRole.album, Alignment.center))),
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
                  _shaded(_metadataText(_VybeTextRole.album, Alignment.center)),
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

  // Portrait Drive: show the FULL artist name, never scroll it and never
  // let lettering paint behind the record. Keep one line when it fits;
  // otherwise choose the best TWO-line word-boundary split and reduce
  // Riot's actual glyph size until both lines fit the reserved width/height.
  // This is deliberately Drive-only; all other themes keep their typography.
  Widget _drivePortraitArtist(double availableWidth, double availableHeight) {
    final name = _artistStr.toUpperCase().trim();
    if (name.isEmpty) return const SizedBox.shrink();

    final baseSize = _artistFontSize(0);
    final safeWidth = math.max(1.0, availableWidth * .92);
    // Riot glyph sizes include its 1.45x scale and enlarged word initials.
    // The pitch leaves a visible separation between the two brush rows.
    final lineBoxFactor = 1.45 * _riotWordInitialScale * 1.07;
    const linePitchRatio = .82;

    double fittingSize(List<String> lines) {
      final widthAtBase = lines.map((line) =>
          _artistRunWidth(line, baseSize)).reduce(math.max);
      final heightMultiplier =
          lines.length == 1 ? 1.0 : 1.0 + linePitchRatio;
      final heightSize = availableHeight /
          (lineBoxFactor * heightMultiplier);
      final widthSize = safeWidth * baseSize /
          math.max(1.0, widthAtBase);
      return math.max(1.0,
          math.min(baseSize, math.min(heightSize, widthSize)));
    }

    final words = name.split(RegExp(r'\s+'));
    var chosenLines = <String>[name];
    var chosenSize = fittingSize(chosenLines);
    if (words.length > 1) {
      for (var split = 1; split < words.length; split++) {
        final lines = <String>[
          words.take(split).join(' '),
          words.skip(split).join(' '),
        ];
        final candidate = fittingSize(lines);
        // Prefer one complete line if it already fits at its normal size.
        // Otherwise use whichever two-line split is the most legible.
        if (candidate > chosenSize + .01) {
          chosenLines = lines;
          chosenSize = candidate;
        }
      }
    }

    final boxHeight = chosenSize * lineBoxFactor;
    final pitch = boxHeight * linePitchRatio;
    final totalHeight = boxHeight +
        (chosenLines.length - 1) * pitch;
    final startY = (availableHeight - totalHeight) / 2;
    return SizedBox(
      width: availableWidth, height: availableHeight,
      child: ClipRect(
        child: Stack(clipBehavior: Clip.hardEdge, children: [
          for (var i = 0; i < chosenLines.length; i++)
            Positioned(
              top: startY + i * pitch,
              left: 0, right: 0,
              child: Center(
                child: _artistText(chosenSize,
                    letteringOverride: chosenLines[i]),
              ),
            ),
        ]),
      ),
    );
  }

  /// Drive art selection is shared by portrait and landscape.
  // Drive artwork is a direct music-player shortcut, independent of the
  // background control toggle. Avoid _front's pulse/bloom and crossfade layers.
  Widget _driveArtwork(double size) {
    return GestureDetector(
      key: _artKey,
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

  /// A two-pixel seamless accent, sampled from the current album colors.
  /// The illuminated edge stays flush against the art/visualizer seam.
  Widget _edgeAlbumAccent({required bool vertical, bool reversed = false}) {
    final colors = model.art?.palette ?? _lastArtPalette ?? _palette;
    return IgnorePointer(child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: vertical ? Alignment.topCenter : Alignment.centerLeft,
          end: vertical ? Alignment.bottomCenter : Alignment.centerRight,
          colors: [colors.a, colors.b, colors.c],
        ),
        boxShadow: [
          BoxShadow(
            color: colors.b.withOpacity(.34),
            blurRadius: 10,
            spreadRadius: 0.5,
            offset: vertical
                ? Offset(reversed ? -3 : 3, 0)
                : const Offset(0, 3),
          ),
        ],
      ),
    ));
  }

  /// Soft dark depth under the visualizer, directly away from the colorful
  /// album-art seam. A restrained album-color falloff adds continuity while
  /// keeping the animated bars clearly readable.
  Widget _edgeVisualizerShadow({
    required bool vertical,
    bool reversed = false,
  }) {
    final colors = model.art?.palette ?? _lastArtPalette ?? _palette;
    final start = vertical
        ? (reversed ? Alignment.centerRight : Alignment.centerLeft)
        : Alignment.topCenter;
    final end = vertical
        ? (reversed ? Alignment.centerLeft : Alignment.centerRight)
        : Alignment.bottomCenter;
    return IgnorePointer(child: Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: DecoratedBox(
          decoration: BoxDecoration(gradient: LinearGradient(
            begin: start, end: end,
            colors: [
              Colors.black.withOpacity(.85),
              Colors.black.withOpacity(.62),
              Colors.black.withOpacity(.22),
              Colors.transparent,
            ],
            stops: const [0.0, .16, .62, 1.0],
          )),
        )),
        Positioned.fill(child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) => LinearGradient(
            begin: start, end: end,
            colors: const [
              Colors.white, Color(0x77FFFFFF), Colors.transparent,
            ],
            stops: const [0.0, .30, 1.0],
          ).createShader(bounds),
          child: DecoratedBox(decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: vertical ? Alignment.topCenter : Alignment.centerLeft,
              end: vertical
                  ? Alignment.bottomCenter : Alignment.centerRight,
              colors: [
                colors.a.withOpacity(.19),
                colors.b.withOpacity(.15),
                colors.c.withOpacity(.19),
              ],
            ),
          )),
        )),
      ],
    ));
  }

  /// Cover on the left half of the screen, edge to edge. A vertical
  /// visualizer runs along the cover's edge, and the song info and lyrics
  /// are right-aligned in the space to the right of it.
  Widget _edgeLayout(double w, double h) {
    final swapped = settings.layoutSwap;
    final artPanel = SizedBox(
      width: w * 0.5,
      height: h,
      child: Stack(fit: StackFit.expand, clipBehavior: Clip.none, children: [
        _edgeArt(w * 0.5, h),
        Positioned(
          left: swapped ? 0 : null,
          right: swapped ? null : 0,
          top: 0, bottom: 0, width: 2.0,
          child: _edgeAlbumAccent(vertical: true, reversed: swapped),
        ),
      ]),
    );
    // Shade starts precisely at the album edge, underneath the visualizer,
    // and mirrors when the two panels are swapped.
    final barsPanel = SizedBox(
      width: w * 0.09,
      height: h,
      child: Stack(fit: StackFit.expand, children: [
        _edgeVisualizerShadow(vertical: true, reversed: swapped),
        _edgeBars(w * 0.09, leftEdge: !swapped),
      ]),
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
              _shaded(_metadataText(_VybeTextRole.album, textAlign)),
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
        SizedBox(
          width: w, height: h * 0.5,
          child: Stack(fit: StackFit.expand, clipBehavior: Clip.none, children: [
            _edgeArt(w, h * 0.5),
            Positioned(left: 0, right: 0, bottom: 0, height: 2.0,
              child: _edgeAlbumAccent(vertical: false)),
          ]),
        ),
        // Portrait mirrors the landscape seam: a full-width colored line
        // and a dark shadow travelling down beneath the spectrum bars.
        if (settings.visualizer)
          SizedBox(
            width: w,
            height: h * 0.08,
            child: Stack(fit: StackFit.expand, children: [
              _edgeVisualizerShadow(vertical: false),
              RepaintBoundary(child: CustomPaint(
                painter: DownBarsPainter(
                  sim: sim,
                  palette: _palette,
                  style: settings.diagonalWaveStyle,
                  count: settings.barCount,
                  gain: settings.sensitivity,
                  repaint: _tick,
                ),
              )),
            ]),
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
                        _metadataText(_VybeTextRole.album, Alignment.center),
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
    // Twenty-five percent darker than the previous grayscale panel.
    // The full-color sleeve, fanart, and white diagonal edge stay intact.
    .0574, .1931, .0195, 0, 0,
    .0574, .1931, .0195, 0, 0,
    .0574, .1931, .0195, 0, 0,
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
  Widget _focusedEdgeShadows(double edge) {
    // Overscan beyond the physical screen bounds on BOTH edges.
    // No safe-area/padding inset or visible gutter may interrupt the
    // full-height fade behind Focused's edge-to-edge visualizer.
    final bleed = math.max(20.0, edge * .34).toDouble();
    return Positioned.fill(child: IgnorePointer(
      child: Stack(clipBehavior: Clip.none, fit: StackFit.expand, children: [
        Positioned(left: -bleed, top: -bleed, bottom: -bleed,
          width: edge * 3.2 + bleed,
          child: const DecoratedBox(decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft, end: Alignment.centerRight,
              colors: [Color(0xFF000000), Color(0xE6000000),
                  Color(0x99000000), Color(0x00000000)],
              stops: [0.0, .22, .53, 1.0])))),
        Positioned(right: -bleed, top: -bleed, bottom: -bleed,
          width: edge * 3.2 + bleed,
          child: const DecoratedBox(decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerRight, end: Alignment.centerLeft,
              colors: [Color(0xFF000000), Color(0xE6000000),
                  Color(0x99000000), Color(0x00000000)],
              stops: [0.0, .22, .53, 1.0])))),
      ]),
    ));
  }

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
          // Reduce the remaining grayscale inset luminance by ~25%:
          // (1 - 0xBC/255) / (1 - 0xA6/255) = 0.75.
          const ColoredBox(color: Color(0xBC000000)),
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
                        _metadataText(_VybeTextRole.album, Alignment.center),
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
                _shaded(_metadataText(_VybeTextRole.album, Alignment.center)),
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
                        _metadataText(_VybeTextRole.album, Alignment.center),
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
                _shaded(_metadataText(_VybeTextRole.album, Alignment.center)),
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
            child: _albumBackgroundImage(art));
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
      // Separate the artist/logo header from the title and album. Anchor
      // both groups to the ACTUAL cover extents so the layout adapts to
      // different portrait aspect ratios without overlapping the artwork.
      final coverTop = mid.dy - s / 2;
      final coverBottom = mid.dy + s / 2;
      final artistTop = h * .025;
      final artistHeight = math.max(h * .08,
          coverTop - artistTop - h * .025).toDouble();
      final titleTop = math.max(coverBottom + h * .015, h * .605)
          .clamp(0.0, h * .72).toDouble();
      return Stack(
        fit: StackFit.expand,
        children: [
          gray,
          Positioned(left: 0, right: 0, bottom: 0, height: h * 0.18,
            child: _diagonalBottomFade()),
          bars,
          line,
          // Artist name or clearlogo belongs ABOVE the cover, not in the
          // lower song-information group.
          Positioned(
            left: w * .035, right: w * .035,
            top: artistTop, height: artistHeight,
            child: Center(child: SizedBox(
              width: w * .93,
              child: _metadataText(_VybeTextRole.artist, Alignment.center),
            )),
          ),
          Positioned(
            left: mid.dx - s / 2, top: coverTop,
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.diagonal3Values(
                  counterFlipText ? -1 : 1, 1, 1),
              child: _front(s, false),
            ),
          ),
          // Pull title and album UP immediately beneath the artwork.
          // Song title uses the full width before starting its fade-scroll.
          Positioned(
            left: w * .045, right: w * .045,
            top: titleTop, bottom: h * .04,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _metadataText(_VybeTextRole.title, Alignment.center),
                if (_showAlbumLabel) ...[
                  SizedBox(height: h * .012),
                  _metadataText(_VybeTextRole.album, Alignment.center),
                ],
                if (_hasLyrics) ...[
                  SizedBox(height: _lyricGap(h)),
                  _lyricBlock(h * .75, Alignment.center, vhs: false),
                ],
              ],
            ),
          ),
        ],
      );
    }

    final s = math.min(w * 0.37, h * 0.8).toDouble();
    // The label/title panel should fill the available open side.
    // The former fixed visualizer clearance shoved the whole information
    // column toward the right edge, leaving a large unused gap.
    // Bound the upper-edge clearance but use the wider lower-area space
    // for centered song information, without covering the front sleeve.
    final infoTop = h * 0.36;
    final root = math.max(0.0, infoTop - normal.dy * barMax).toDouble();
    final lineX = a.dx + (b.dx - a.dx) * (root - a.dy) / (b.dy - a.dy);
    final upperClearance = lineX +
        (settings.visualizer ? normal.dx * barMax : 0.0) + w * 0.012;
    final infoLeft = math.max(w * 0.44,
        math.min(upperClearance, w * 0.49)).toDouble();
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
          right: w * 0.025,
          top: infoTop,
          bottom: h * 0.07,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(counterFlipText ? -1 : 1, 1, 1),
            child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            // Force title/artist/album to inherit the entire available
            // width. The marquee only pans after genuinely filling it.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _artist(h * 0.090, Alignment.center, false),
              SizedBox(height: h * 0.012),
              _title(h * 0.085, Alignment.center, false),
              if (_showAlbumLabel) ...[
                SizedBox(height: h * 0.012),
                _shaded(_metadataText(_VybeTextRole.album, Alignment.center)),
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
      if (settings.backgroundSource != 1 && settings.backgroundSource != 6)
        _orbitGhost(w, h, narrow),
      // Portrait Orbit's black floor gradually rises behind the rings.
      // Draw BEFORE the orbit group, keeping the record and lighting sharp.
      if (narrow)
        Positioned(left: 0, right: 0, bottom: 0, height: h * .62,
          child: const IgnorePointer(child: DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Color(0xE6000000),
                Color(0xA6000000),
                Color(0x58000000),
                Color(0x00000000),
              ],
              stops: [0.0, .32, .68, 1.0],
            )),
          )),
        ),
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
                      _metadataText(_VybeTextRole.album, Alignment.center),
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
                _shaded(_metadataText(_VybeTextRole.album, Alignment.center)),
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
        _metadataText(_VybeTextRole.title,
            center ? Alignment.center : Alignment.centerRight),
        SizedBox(height: h * 0.008),
        if (_showAlbumLabel) ...[
          SizedBox(height: h * 0.005),
          _metadataText(_VybeTextRole.album,
              center ? Alignment.center : Alignment.centerRight),
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
        '♪',
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
      _lyricTheme && (model.lyrics?.isNotEmpty ?? false);

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
    final block = _shaded(SizedBox(
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
    // Typo deliberately hides cover art: tapping its lyric panel is the
    // source music-player shortcut, matching the artwork tap elsewhere.
    return _lyricTheme
        ? GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openPlayer,
            child: block,
          )
        : block;
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
    // The aggressive letter-to-letter overlap must NOT apply to digits
    // or punctuation, otherwise a dot/comma can end up under adjacent ink.
    // Letter pairs retain the exact saved factory kerning.
    final original = _riotIsLetter(previous) && _riotIsLetter(character)
        ? _riotDefaultPairOverlap(previous, character, fontSize, glyphWidth)
        : 0.0;
    final pair = previous + character;
    // Original hand-tuned pairs + approved new corrections + any later
    // residual editor adjustment. Shared by both width and rendered positions.
    return original - ((riotFixedPairOffsets[pair] ?? 0.0)
        + (riotApprovedPairOffsets[pair] ?? 0.0)
        + RiotSpacingStore.instance.deltaFor(pair)) * fontSize;
  }

  double _riotDefaultPairOverlap(String previous, String character,
      double fontSize, double glyphWidth) {
    final pair = previous + character;
    // Keep the I readable. Its glyph advance is only ~0.273 em, so the
    // previous I->C/N/S corrections could shift the following letter over
    // nearly the entire I. Both layout and width measurement call here.
    // Q/V and U/V are diagonally projected brush forms. Their ink
    // extends past the font's advance boxes (verified from the Riot TTF).
    // Any generic negative tracking lets V bury Q or U, particularly
    // when V is the enlarged first letter. At zero extra overlap the
    // visible contours already meet, without one glyph covering another.
    if (pair == 'QV' || pair == 'VQ' ||
        pair == 'UV' || pair == 'VU') {
      return 0.0;
    }
    if (pair == 'IV') {
      return math.min(fontSize * .018, glyphWidth * .05);
    }
    // VI had a false word gap; close it gently without obscuring I.
    if (pair == 'VI') {
      return math.min(fontSize * .115, glyphWidth * .45);
    }
    // INTERVALS: V's long diagonal enters R's brushwork. These glyph
    // contours nearly touch without any negative tracking; avoid hiding R.
    if (pair == 'RV') {
      return math.min(fontSize * .012, glyphWidth * .04);
    }
    // The angled entry on S creates another visible gap after narrow I.
    if (pair == 'IS') {
      return math.min(fontSize * .145, glyphWidth * .36);
    }
    // Keep the already-connected approaches into I. It is the following
    // glyph, not the preceding glyph, that gets painted on top of the I.
    // Narrow-letter protection therefore only applies when I comes FIRST.
    if (pair == 'LI') {
      // ELI: the narrow I is still too close to L's lower brush stroke.
      return math.min(fontSize * .12, glyphWidth * .46);
    }
    if (pair == 'FI') {
      return math.min(fontSize * .45, glyphWidth * .78);
    }
    if (pair == 'TI') {
      return math.min(fontSize * .235, glyphWidth * .57);
    }
    if (pair == 'IA') {
      // CASSIAN: A's rising brush can meet I without burying it.
      // Other I-following pairs retain the stronger narrow-I protection.
      return math.min(fontSize * .225, glyphWidth * .50);
    }
    if (pair == 'ID') {
      // SIDE: D's angled lead-in leaves an optical gap after narrow I.
      // Bring the strokes nearer, but never use the aggressive I-A overlap.
      return math.min(fontSize * .155, glyphWidth * .37);
    }
    if (previous == 'I') {
      return math.min(fontSize * .085, glyphWidth * .35);
    }
    // In the actual normalized Riot font, T and O first reach optical
    // contact near .32 em. The former .105 em produced a false word break.
    if (pair == 'TO') {
      return math.min(fontSize * .32, glyphWidth * .92);
    }
    // Keep connected double-S and N-S while showing their individual strokes.
    if (pair == 'SS' || pair == 'NS') {
      return math.min(fontSize * .26, glyphWidth * .60);
    }
    // Additional optical pairs observed across independent themes:
    // CASSIAN (A-S), WESTEND (W-E and E-S).
    // The normalized glyph outlines still have visible gaps at the generic
    // spacing, even though surrounding letters already connect.
    if (pair == 'AS') {
      return math.min(fontSize * .25, glyphWidth * .58);
    }
    if (pair == 'WE') {
      return math.min(fontSize * .23, glyphWidth * .48);
    }
    if (pair == 'ES') {
      // S begins with a slanted top stroke. This pair has much more
      // empty space than other E-following letters at the same advance.
      return math.min(fontSize * .43, glyphWidth * .89);
    }
    // Riot is a connected brush alphabet: maintain contact without
    // obscuring a recognizable counter or terminal.
    if (pair == 'QU') {
      // SUNSQUABI: U follows Q and obscures Q's lower brushwork.
      // Reduce overlap while retaining visual contact.
      return math.min(fontSize * .095, glyphWidth * .27);
    }
    if (pair == 'UQ') {
      // Keep the reverse pairing connected without hiding the O-shaped bowl.
      return math.min(fontSize * .105, glyphWidth * .28);
    }
    if (pair == 'LE') {
      // The L's lower arm must remain visible underneath E's brush tip.
      return math.min(fontSize * .115, glyphWidth * .26);
    }
    if (pair == 'JO') {
      // JORIS VOORN: J's far-right brush does not reach O at the default
      // spacing. Pull O closer while keeping its open center readable.
      return math.min(fontSize * .30, glyphWidth * .72);
    }
    if (character == 'O' && previous != 'W') {
      // Protect O's recognizable open center against diagonal intrusions.
      return math.min(fontSize * .105, glyphWidth * .28);
    }
    if (previous == 'O' && character != 'V' && character != 'S') {
      return math.min(fontSize * .105, glyphWidth * .28);
    }
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
    // J→E's unusually large empty advance separates JERU visually.
    // This optical pair correction applies to every theme via _artistText
    // and its matching _artistRunWidth measurement.
    if (pair == 'JE') {
      // ARJEN: the larger overlap that closed JERU buries J's
      // downward stroke. Leave both letterforms identifiable.
      return math.min(fontSize * .13, glyphWidth * .30);
    }
    if (pair == 'OS') {
      return math.min(fontSize * .145, glyphWidth * .32);
    }
    // Riot's S has an angled left side. Following C, U, G or T, its
    // measured advance leaves a visible false word break. Apply one
    // character-shape rule rather than artist-name-specific exceptions.
    if (character == 'S' && 'CUGT'.contains(previous)) {
      final amount = (previous == 'C' || previous == 'G') ? .37 : .33;
      return math.min(fontSize * amount, glyphWidth * .62);
    }
    // The Y's fork and the Z's upper brush stroke should read as one word.
    if (pair == 'YZ') {
      // Y's long descending brush already overlaps Z's upper branch.
      // The old .34em tracking buried the start of Z.
      return math.min(fontSize * .065, glyphWidth * .16);
    }
    // Riot's W has visible space inside its measured advance. Tighten only
    // the W→O (WORLD) and W→N (RENOWN) transitions seen in testing.
    if (pair == 'WO' || pair == 'WN') {
      return math.min(fontSize * .20, glyphWidth * .48);
    }
    // HOWSAM: W has a wide invisible exit bearing, while S begins
    // with an angled brush. Close the false word break without
    // overlapping the readable body of S.
    if (pair == 'WS') {
      return math.min(fontSize * .36, glyphWidth * .68);
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
    // E has a large slashing terminal, but pulling the next letter over
    // 0.30 em can obscure it. Reduce only its trailing overlap.
    if (previous == 'E') {
      return math.min(fontSize * .215, glyphWidth * .48);
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

  // Only alphabetic initials receive Riot's 1.27x first-letter treatment.
  // The old digit-only exception enlarged &, @, # and other symbols at
  // word starts, creating giant ampersands in artist names.
  bool _riotIsLetter(String character) {
    if (character.runes.length != 1) return false;
    final cp = character.runes.first;
    return (cp >= 65 && cp <= 90) ||
        (cp >= 0x00C0 && cp <= 0x00D6) ||
        (cp >= 0x00D8 && cp <= 0x00DE) ||
        (cp >= 0x0100 && cp <= 0x017F);
  }

  // Y's slanted exit and S's angled entry exaggerate the normal word gap.
  // Tighten this shape combination only; distinct words remain readable.
  double _riotWordGap(String previous, String next, double fontSize) =>
      fontSize * (previous == 'Y' && next == 'S' ? .11 : .22);

  bool get _headUnitControls => widget.driveHost ? settings.headUnitDevice :
      VybeLink.instance.deviceType == 'head_unit';

  Widget _artistText(double size, {Color? color, String? letteringOverride,
      bool logoTreatment = true}) {
    final lettering = (letteringOverride ?? _artistStr).toUpperCase();
    final fontSize = size * 1.45;
    // The original alpha mask accidentally contained Riot's pre-existing
    // multicolor Flutter drop shadows. Those shadows blurred the silhouette,
    // making six shader treatments look like nearly identical white glows.
    // The GPU now receives ONLY sharp, fully opaque Riot glyphs.
    final gpuLogo = logoTreatment && settings.artistLogoFx != 0 && model.active;
    final style = TextStyle(
      fontFamily: 'VYBERiot',
      fontFamilyFallback: const ['Roboto'],
      fontSize: fontSize,
      height: 1.0,
      letterSpacing: 0,
      wordSpacing: 0,
      color: gpuLogo ? Colors.white : (color ?? Colors.white),
      shadows: gpuLogo ? const <Shadow>[] : _artistNeonShadows,
    );
    // Measure glyphs first, then center every glyph within the tallest line
    // box. This centers the enlarged initial both above and below its word.
    final glyphCharacters = <String>[];
    final glyphStyles = <TextStyle>[];
    final glyphPositions = <double>[];
    final glyphHeights = <double>[];
    final glyphVertical = <double>[];
    final overrides = RiotSpacingStore.instance;
    var minX = 0.0, maxX = 0.0;
    var minY = 0.0, maxY = 0.0;
    var x = 0.0;
    var previous = '';
    var pendingWordGap = false;
    var maxHeight = fontSize;
    for (final rune in lettering.runes) {
      final character = String.fromCharCode(rune);
      // Delay the space until the next glyph so optical word-gap pairs can
      // be measured and painted exactly the same way.
      if (character == ' ') {
        if (previous.isNotEmpty) pendingWordGap = true;
        continue;
      }
      final isWordInitial = previous.isEmpty || pendingWordGap;
      final glyphStyle = isWordInitial && _riotIsLetter(character)
          ? style.copyWith(fontSize: fontSize * _riotWordInitialScale)
          : style;
      final painter = TextPainter(
        text: TextSpan(text: character, style: glyphStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final glyphWidth = painter.width;
      maxHeight = math.max(maxHeight, painter.height);
      if (pendingWordGap) {
        x += _riotWordGap(previous, character, fontSize);
      } else if (previous.isNotEmpty) {
        x -= _riotPairOverlap(previous, character, fontSize, glyphWidth);
      }
      final dx = overrides.xFor(character) * fontSize;
      final dy = overrides.yFor(character) * fontSize;
      final glyphX = x + dx;
      glyphCharacters.add(character);
      glyphStyles.add(glyphStyle);
      glyphPositions.add(glyphX);
      glyphHeights.add(painter.height);
      glyphVertical.add(dy);
      minX = math.min(minX, glyphX);
      maxX = math.max(maxX, glyphX + glyphWidth);
      minY = math.min(minY, dy);
      maxY = math.max(maxY, dy);
      x += glyphWidth + overrides.afterFor(character) * fontSize;
      previous = character;
      pendingWordGap = false;
    }
    final leftInset = -minX;
    final totalWidth = math.max(x, maxX) - minX;
    Widget buildWordmark({bool fallback = false}) => Transform(
      alignment: Alignment.center,
      transform: Matrix4.skewX(-.16),
      child: SizedBox(
        width: math.max(1, totalWidth),
        height: maxHeight + (maxY - minY),
        child: Stack(clipBehavior: Clip.none, children: [
          for (var i = 0; i < glyphCharacters.length; i++)
            Positioned(
              left: glyphPositions[i] + leftInset,
              top: (maxHeight - glyphHeights[i]) / 2 +
                  glyphVertical[i] - minY,
              child: Text(glyphCharacters[i], maxLines: 1,
                  softWrap: false, style: fallback
                      ? artistLogoFallbackStyle(glyphStyles[i],
                          treatment: settings.artistLogoFx,
                          position: glyphCharacters.length <= 1 ? .5 : i / (glyphCharacters.length - 1),
                          depth: settings.artistLogoDepth, edge: settings.artistLogoEdge,
                          accent: _artistNeonPalette.a, secondary: _artistNeonPalette.b,
                          tertiary: _artistNeonPalette.c, colorStrength: settings.artistLogoColor)
                      : glyphStyles[i]),
            ),
        ]),
      ),
    );
    if (!gpuLogo) {
      return buildWordmark();
    }
    // The GPU reads this entire composited wordmark as one alpha mask,
    // not separately illuminated characters. Padding preserves room for
    // silhouette contour lighting, emboss shadow and outer neon spill.
    return ArtistLogoShaderLayer(
      repaint: _tick,
      clock: () => _artistLogoPhase,
      bass: () => settings.artistLogoBeat && model.realActive
          ? ripples.pulseAt(_time) : 0.0,
      treatment: settings.artistLogoFx,
      depth: settings.artistLogoDepth,
      edge: settings.artistLogoEdge,
      accent: _artistNeonPalette.a,
      secondary: _artistNeonPalette.b,
      tertiary: _artistNeonPalette.c,
      colorStrength: settings.artistLogoColor,
      compatibilityMode: _headUnitControls && (VybeLink.instance.directAndroidSdk == 0 || VybeLink.instance.directAndroidSdk <= 28),
      fallback: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: buildWordmark(fallback: true),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: buildWordmark(),
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
    var minX = 0.0, maxX = 0.0;
    final overrides = RiotSpacingStore.instance;
    var prev = '';
    var pendingWordGap = false;
    for (final rune in lettering.runes) {
      final c = String.fromCharCode(rune);
      // Identical glyph sizing and spacing to _artistText; otherwise
      // line breaks will disagree with the rendered Riot wordmark.
      if (c == ' ') {
        if (prev.isNotEmpty) pendingWordGap = true;
        continue;
      }
      final isWordInitial = prev.isEmpty || pendingWordGap;
      final glyphStyle = isWordInitial && _riotIsLetter(c)
          ? style.copyWith(fontSize: fontSize * _riotWordInitialScale)
          : style;
      final p = TextPainter(text: TextSpan(text: c, style: glyphStyle),
          textDirection: TextDirection.ltr, maxLines: 1)..layout();
      final width = p.width;
      if (pendingWordGap) {
        x += _riotWordGap(prev, c, fontSize);
      } else if (prev.isNotEmpty) {
        x -= _riotPairOverlap(prev, c, fontSize, width);
      }
      final glyphX = x + overrides.xFor(c) * fontSize;
      minX = math.min(minX, glyphX);
      maxX = math.max(maxX, glyphX + width);
      x += width + overrides.afterFor(c) * fontSize;
      prev = c;
      pendingWordGap = false;
    }
    final measured = math.max(x, maxX) - minX;
    if (_artistWidthCache.length > 256) _artistWidthCache.clear();
    // Match the 16px per-side alpha-mask margin so the artist wrap/marquee
    // calculations include the stronger three-stage shader glow.
    final visualWidth = measured +
        (settings.artistLogoFx > 0 && model.active ? 32.0 : 0.0);
    _artistWidthCache[key] = visualWidth;
    return visualWidth;
  }

  // One line-break rule for ALL themes. Match the precise Riot glyph width
  // and leave only a small optical buffer for skewed brush strokes.
  // Artist names never shrink: multiword names wrap; one long word scrolls.
  List<String> _artistLines(String text, double size, double width) {
    if (text.isEmpty) return const [''];
    final safety = math.min(size * .12, width * .015);
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
  Widget _drawAlbum({required Alignment alignment, Alignment? flushFrame}) {
    final labelSize = _albumFontSize(0);
    final albumStyle = _albumLabelTextStyle(labelSize);
    return LayoutBuilder(builder: (context, bounds) {
      final screen = MediaQuery.sizeOf(context);
      final available = bounds.maxWidth.isFinite
          ? math.max(1.0, bounds.maxWidth)
          : math.max(1.0, screen.width * .86);
      // Frame is content-driven, but never collapses into a tiny badge.
      // Reserve the diagonal wings AND a clear inset on both sides BEFORE
      // deciding whether the album title needs to scroll. Short and medium
      // names must be fully visible at the original font size.
      final painter = TextPainter(
        text: TextSpan(text: _albumDisplayName, style: albumStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final letteringWidth = painter.width + labelSize * .45;
      final painterHeight = painter.height;
      painter.dispose();
      // The outer frame alignment comes from the theme's desired edge.
      // "flushFrame" is not merely decorative: it must align the OUTER
      // frame too, while the inner text clearance stays independent.
      final frameAlignment = flushFrame ?? alignment;
      final flushLeft = frameAlignment == Alignment.centerLeft;
      final flushRight = frameAlignment == Alignment.centerRight;
      // Mirror the real frame's angled geometry. A visual inset belongs
      // INSIDE the shape; it must never move its screen-side outer edge.
      // SongTitleMarquee has painter.height + 8 (minimum 24) before our
      // vertical padding. Use that same height for the diagonal cut.
      final frameHeight = math.max(painterHeight + 8.0, 24.0) +
          labelSize * .48;
      final safeGap = math.max(labelSize * .75, frameHeight * .25);
      final cut = frameHeight * .64;
      final offset = frameHeight * .26;
      final edgeMargin = math.max(1.5, frameHeight * .05);
      final maximalWing = frameHeight * 1.05;
      final naturalLeftInset =
          (flushLeft ? offset + edgeMargin : maximalWing) + cut + safeGap;
      final naturalRightInset =
          (flushRight ? offset + edgeMargin : maximalWing) + cut + safeGap;
      final desiredWidth = letteringWidth +
          naturalLeftInset + naturalRightInset;
      // Music Video portrait: the framed album label must line up with the
      // enlarged 94%-screen-width album cover with a little side padding.
      // The metadata slot is 90% wide, leaving ~2% on each side of the
      // actual cover. Keep this width FIXED, even for a very short album.
      // All landscape and non-Music-Video themes retain their old sizing.
      final fullPortraitVideoBadge =
          settings.theme == AppSettings.tMusicVideo && _textPortrait;
      final minimumFraction =
          settings.theme == AppSettings.tCoverflow && _textPortrait
              ? .92 : .78;
      final badgeWidth = fullPortraitVideoBadge
          ? available
          : math.max(1.0, math.min(available,
              math.max(available * minimumFraction, desiredWidth))).toDouble();
      final shape = _VybeAlbumFrameGeometry(
          Size(badgeWidth, frameHeight),
          flushLeft: flushLeft, flushRight: flushRight);
      // Always place BOTH ends of the marquee beyond the diagonal strokes
      // plus a visible gap, even when the album name has to pan.
      final leftInset = shape.left + shape.cut + safeGap;
      final rightInset = badgeWidth - (shape.right - shape.cut) + safeGap;
      return Align(
        alignment: frameAlignment,
        child: SizedBox(
          width: badgeWidth,
          child: CustomPaint(
            painter: _VybeAlbumLabelFrame(_palette.a,
                flushRight: flushRight, flushLeft: flushLeft),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  leftInset, labelSize * .24,
                  rightInset, labelSize * .24),
              child: ClipRect(
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
        ),
      );
    });
  }

  // Compatibility wrappers: old layout calls now all converge on the same
  // role-aware metadata widget. Their former size arguments do not affect type.
  Widget _fixedTitle(double unusedSize, Alignment align) =>
      _metadataText(_VybeTextRole.title, align);

  Widget _title(double unusedSize, Alignment a, bool vhs) =>
      _metadataText(_VybeTextRole.title, a, vhs: vhs);

  Widget _drawTitle(Alignment a, bool vhs) {
    final standard = _titleText(_songFontSize(0)).style!;
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

  Widget _artist(double unusedSize, Alignment a, bool vhs,
      {Color? textColor}) =>
      _metadataText(_VybeTextRole.artist, a,
          vhs: vhs, textColor: textColor);

  Widget _drawArtist(Alignment a, bool vhs, {Color? textColor}) {
    final fontSize = _artistFontSize(0);
    if (model.isSpotifyAdvertisement) {
      // Spotify publishes "Advertisement 2 of 3" as an artist string.
      // Riot is a hand-drawn LETTER font: its fallback digits create giant,
      // colliding glyphs when drawn with musician wordmark typography.
      return Align(
        alignment: a,
        child: Text(
          model.artist.trim(),
          textAlign: a.x < -.5
              ? TextAlign.left
              : (a.x > .5 ? TextAlign.right : TextAlign.center),
          maxLines: 2,
          softWrap: true,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'Roboto',
            fontSize: math.min(24.0, math.max(17.0, fontSize * .52)),
            fontWeight: FontWeight.w500,
            letterSpacing: .25,
            height: 1.15,
            color: textColor ?? _readableText(1),
            shadows: _cleanTextShadows,
          ),
        ),
      );
    }
    if (settings.useArtistClearLogo && _clearLogoBytes != null && model.active) {
      return _shaded(LayoutBuilder(builder: (context, box) {
        final screen = MediaQuery.sizeOf(context);
        final maxWidth = box.maxWidth.isFinite
            ? math.min(box.maxWidth, screen.width * .94)
            : screen.width * .90;
        final naturalHeight = math.min(screen.height * .25,
            math.max(screen.height * .14, fontSize * 3.0));
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
    Widget lineWidget(String line) =>
      (vhs || _vhsOn) && settings.artistLogoFx == 0
        ? _split((c) => _artistText(fontSize, color: c, letteringOverride: line),
            main: textColor ?? Colors.white70,
            leftGhost: _artistNeonPalette.a.withOpacity(.60),
            rightGhost: _artistNeonPalette.b.withOpacity(.60))
        : _artistText(fontSize, color: textColor, letteringOverride: line);
    return LayoutBuilder(builder: (context, box) {
      final screen = MediaQuery.sizeOf(context);
      final available = box.maxWidth.isFinite
          ? math.max(1.0, box.maxWidth) : math.max(1.0, screen.width * .88);
      final name = _artistStr.toUpperCase().trim();
      var lines = _artistLines(name, fontSize, available);
      // Portrait artist headers used to grow to 5-8 rows for compilation
      // credits and overflow directly on top of the covers. Preserve the
      // full name and full Riot glyph size: restrict to at most TWO rows,
      // and marquee horizontally within either row when necessary.
      if (_textPortrait && lines.length > 2) {
        final words = name.split(RegExp(r'\s+'));
        var bestSplit = 1;
        var bestScore = double.infinity;
        for (var i = 1; i < words.length; i++) {
          final first = words.take(i).join(' ');
          final second = words.skip(i).join(' ');
          final aWidth = _artistRunWidth(first, fontSize);
          final bWidth = _artistRunWidth(second, fontSize);
          final score = math.max(aWidth, bWidth) +
              .12 * (aWidth - bWidth).abs();
          if (score < bestScore) {
            bestScore = score;
            bestSplit = i;
          }
        }
        if (words.length > 1) {
          lines = [
            words.take(bestSplit).join(' '),
            words.skip(bestSplit).join(' '),
          ];
        } else {
          lines = [name];
        }
      }
      // Finite artist slots (Coverflow/Focused) must NOT paint into album
      // artwork. If two full-size rows exceed the available height, show
      // the whole name as one horizontally scrolling row instead.
      final rowHeight = fontSize * 1.45 * _riotWordInitialScale;
      final twoRowsHeight = rowHeight * 1.47 +
          (settings.artistLogoFx > 0 && model.active ? 26.0 : 0.0);
      if (_textPortrait && lines.length > 1 &&
          box.maxHeight.isFinite &&
          twoRowsHeight > box.maxHeight - 2.0) {
        lines = [name];
      }
      // Long single words/lines scroll with fading edges, never shrink.
      Widget renderedLine(String line) =>
          _artistRunWidth(line, fontSize) > available
              ? _overflowRiotWord(line, fontSize, available, lineWidget)
              : lineWidget(line);
      final artistBlock = lines.length > 1
          ? _compactRiotLines(lines, fontSize, a, renderedLine)
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [Align(alignment: a, child: renderedLine(lines.first))],
            );
      return _shaded(artistBlock);
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

  /// A vertically flipped copy of the cover, clipped to its top 28%.
  /// The reflection's alpha fades from the ART CONTACT at y=0 to
  /// transparent at the bottom. Keep the independent contact shadow below
  /// unchanged: it is part of the original artwork design, not the fade.
  Widget _reflection(double s) {
    final h = s * 0.28;
    return SizedBox(
      width: s,
      height: h,
      child: Stack(
        children: [
          Positioned.fill(
            // Clip the output window FIRST. A full-size flipped image must
            // not influence the reflection's visible fade coordinates.
            child: ClipRect(
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x66FFFFFF), Color(0x00FFFFFF)],
                ).createShader(rect),
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minWidth: s,
                  maxWidth: s,
                  minHeight: s,
                  maxHeight: s,
                  // The outgoing art crossfade in an overflowing square can
                  // draw outside the intended reflected slice. Flip only
                  // the current artwork; the main cover still transitions.
                  child: Transform(
                    key: ValueKey<Object>(model.art ?? 'placeholder'),
                    alignment: Alignment.center,
                    transform: Matrix4.diagonal3Values(1.0, -1.0, 1.0),
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
          // ORIGINAL CONTACT SHADOW: preserve its black fade, position,
          // strength and rounded lower corners exactly as before.
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
      child: IgnorePointer(
        // Keep the header mounted even when hidden. Conditional insertion
        // prevented an entrance animation, since there was no prior position.
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          offset: _showControls ? Offset.zero : const Offset(0, -1.15),
          child: Stack(children: [
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
          ]),
        ),
      ),
    );
  }


  /// Special-purpose utility popup for Music Video. No source MediaSession
  /// playback buttons or progress bar: the embedded video owns those.
  Widget _musicVideoUtilityPopup() {
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 680;
    final head = _headUnitControls;
    final margin = head ? 24.0 : (compact ? 8.0 : size.width * .27);

    Widget action(IconData icon, String label, VoidCallback callback) {
      final button = Tooltip(
        message: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            _hideTimer?.cancel();
            if (mounted) setState(() => _showControls = false);
            callback();
          },
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: head ? 13 : 8, horizontal: head ? 12 : 3),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: Colors.white, size: head ? 31 : (compact ? 20 : 25)),
              const SizedBox(height: 4),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white,
                    fontSize: head ? 14.0 : (compact ? 10.0 : 12.0))),
            ]),
          ),
        ),
      );
      return head ? ConstrainedBox(constraints: const BoxConstraints(minWidth: 64, minHeight: 64), child: button) : Expanded(child: button);
    }

    final actions = [action(Icons.grid_view_rounded, 'Themes', _pickTheme),
      action(Icons.tune_rounded, 'Customize', _openQuickCustomize),
      action(Icons.settings_outlined, 'Settings', _openSettings),
      action(Icons.navigation_rounded, 'Drive', _startDrive)];
    return Positioned(
      top: head ? 24 : 0, left: margin, right: margin,
      child: IgnorePointer(
        ignoring: !_showControls,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
          offset: _showControls ? Offset.zero : const Offset(0, -1.35),
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xF0101219),
              borderRadius: BorderRadius.vertical(
                bottom: Radius.circular(14)),
              boxShadow: [BoxShadow(color: Color(0xB0000000),
                blurRadius: 26, offset: Offset(0, 7))],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(height: 3, decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [
                  Color(0xFFFF27A8), Color(0xFF995CFF),
                  Color(0xFF05E2F3)]))),
              SafeArea(
                top: true, bottom: false,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: head ? 14 : 7, vertical: head ? 8 : 0),
                  child: head ? Wrap(alignment: WrapAlignment.center, spacing: 14, runSpacing: 10, children: actions) : Row(children: actions),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /// Full-width bottom controls. No bubble or pill background: a thin
  /// VYBE-magenta/purple/cyan rule and rising shadow separate it from the art.
  /// The persistent AnimatedSlide can animate both entrance AND exit.
  Widget _controls() {
    final screen = MediaQuery.sizeOf(context);
    final compact = screen.width < 610;
    final head = _headUnitControls;
    final iconSize = head ? 34.0 : (compact ? 23.0 : 29.0);
    final playSize = head ? 44.0 : (compact ? 34.0 : 45.0);

    Widget btn(IconData icon, String tooltip, VoidCallback onTap,
        {double? size}) => Tooltip(
      message: tooltip,
      child: IconButton(
        iconSize: size ?? iconSize,
        constraints: BoxConstraints(
          minWidth: head ? 64 : (compact ? 41 : 48),
          minHeight: head ? 64 : (compact ? 41 : 48)),
        visualDensity: head ? VisualDensity.standard : VisualDensity.compact,
        padding: EdgeInsets.symmetric(horizontal: head ? 5 : 3, vertical: head ? 5 : 3),
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
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          offset: _showControls ? Offset.zero : const Offset(0, 1.15),
          // No quick opacity crossfade: the full panel visibly slides up.
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
                      // Lift buttons off the ATOTO bezel while keeping the
                      // panel full-width and anchored at the bottom.
                      // SafeArea also respects Android navigation insets.
                      padding: EdgeInsets.fromLTRB(
                        head ? 26 : (compact ? 8 : 22), head ? 12 : 7,
                        head ? 26 : (compact ? 8 : 22),
                        head ? 26 : math.max(20.0, math.min(30.0, screen.height * .045))),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _seekBar(width: double.infinity),
                          SizedBox(height: head ? 8 : 2),
                          if (head) ...[
                            Wrap(alignment: WrapAlignment.center, spacing: 14, runSpacing: 8, children: [
                              btn(Icons.grid_view_rounded, 'Themes', _pickTheme),
                              btn(Icons.tune_rounded, 'Customize', _openQuickCustomize),
                              btn(Icons.settings_outlined, 'Settings', _openSettings),
                              if (screen.width > screen.height && const [1,3,5,6,7,8,9,10,11].contains(settings.theme))
                                btn(Icons.swap_horiz_rounded, 'Flip layout', () => settings.update(() => settings.layoutSwap = !settings.layoutSwap)),
                              if (widget.driveHost) ...[
                                btn(Icons.map_outlined, 'Show map', _hideDrive),
                                btn(Icons.close_rounded, 'Close Drive', _exitDrive),
                              ] else btn(Icons.navigation_rounded, 'Drive', _startDrive),
                              btn(Icons.skip_previous_rounded, 'Previous', model.previous, size: playSize),
                              btn(model.playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
                                  model.playing ? 'Pause' : 'Play', model.playPause, size: playSize + 8),
                              btn(Icons.skip_next_rounded, 'Next', model.next, size: playSize),
                            ]),
                          ] else Row(children: [
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
    if (size.isEmpty || depth <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
    final shadowDepth = math.min(depth, radius * .28);
    final inner = ((radius - shadowDepth) / radius).clamp(0.0, 1.0)
        .toDouble();

    // A smooth continuous radial gradient avoids the stacked drawArc
    // stroke caps that previously left a visible vertical hard edge.
    // Mask it with an angularly feathered sweep, so the localized inner
    // shadow melts away before reaching the end of the record cutout.
    final bounds = Offset.zero & size;
    canvas.saveLayer(bounds, Paint());
    canvas.drawCircle(center, radius,
      Paint()..shader = ui.Gradient.radial(center, radius, [
        Colors.transparent,
        Colors.transparent,
        const Color(0x3A000000),
        const Color(0x9E000000),
        const Color(0xB0000000),
        Colors.transparent,
      ], [
        0.0,
        math.max(0.0, inner - .04),
        (inner + (1 - inner) * .26),
        (inner + (1 - inner) * .65),
        .97,
        1.0,
      ]),
    );
    final arcSpan = math.min(span, math.pi * .98);
    final featherFraction = (0.14 / (2 * arcSpan)).clamp(.05, .22)
        .toDouble();
    // Sweep mask fades completely to zero at both arc endpoints, avoiding
    // the vertical edge even when the ellipse is cropped by the screen.
    canvas.drawRect(bounds, Paint()
      ..shader = SweepGradient(
        startAngle: centerAngle - arcSpan,
        endAngle: centerAngle + arcSpan,
        tileMode: TileMode.clamp,
        colors: const [
          Colors.transparent, Colors.white,
          Colors.white, Colors.transparent,
        ],
        stops: [
          0.0, featherFraction,
          1.0 - featherFraction, 1.0,
        ],
      ).createShader(bounds)
      ..blendMode = BlendMode.dstIn);
    canvas.restore();
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



/// Single source of truth for the angled album-label frame geometry.
/// Shared by its painter and the padded text viewport, so a change to the
/// diagonal shape cannot silently cause lettering to touch the frame.
class _VybeAlbumFrameGeometry {
  final double left;
  final double right;
  final double cut;
  final double offset;

  _VybeAlbumFrameGeometry(Size size,
      {required bool flushLeft, required bool flushRight})
      : cut = size.height * .64,
        offset = size.height * .26,
        left = flushLeft
            ? size.height * .26 + math.max(1.5, size.height * .05)
            : math.min(size.height * 1.05, size.width * .13),
        right = flushRight
            ? size.width - size.height * .26 -
                math.max(1.5, size.height * .05)
            : size.width -
                math.min(size.height * 1.05, size.width * .13);
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
    final geometry = _VybeAlbumFrameGeometry(size,
        flushLeft: flushLeft, flushRight: flushRight);
    final cut = geometry.cut;
    final offset = geometry.offset;
    final left = geometry.left;
    final right = geometry.right;
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
