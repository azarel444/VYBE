import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'palette.dart';

/// All user-adjustable options, saved on the device.
class AppSettings extends ChangeNotifier {
  static const themeNames = [
    'Focused',
    'Side by Side',
    'VHS',
    'Edge to Edge',
    'Drive',
    'Fan',
    'Diagonal',
    'Record Cut',
    'Typo',
    'Orbit',
  ];

  /// Theme numbers, so the screen does not rely on bare digits.
  static const int tFan = 5;
  static const int tDiagonal = 6;
  static const int tRecord = 7;
  static const int tTypo = 8;
  static const int tOrbit = 9;

  /// Number 2 was the VHS theme. It is now an effect, so it is no longer
  /// offered as a theme; the other numbers stay as they were.
  static const int tRemovedVhs = 2;

  /// The themes that can be picked, in order.
  static const List<int> pickable = [0, 1, 3, 4, 5, 6, 7, 8, 9];
  static const accentNames = [
    'Auto (from art)',
    'Vaporwave',
    'Sunset',
    'Ocean',
    'Forest',
    'White',
    'Cosmic',
    'Ember',
    'Aurora',
    'Rose Gold',
    'Electric Lime',
    'Midnight',
    'Ice',
    'Ruby',
    'Golden Hour',
    'Ultraviolet',
    'Monochrome',
  ];

  /// Index 0 (Auto) is null: the colors come from the album art.
  static const List<ArtPalette?> accents = [
    null,
    ArtPalette(Color(0xFF01CDFE), Color(0xFFFF71CE), Color(0xFFB967FF)),
    ArtPalette(Color(0xFFFF9A5A), Color(0xFFFF5C8A), Color(0xFFD65CFF)),
    ArtPalette(Color(0xFF00E5FF), Color(0xFF3D8BFF), Color(0xFF7C5CFF)),
    ArtPalette(Color(0xFF7CFF8A), Color(0xFF00E5B0), Color(0xFFE5FF5C)),
    ArtPalette(Color(0xFFFFFFFF), Color(0xFFD0D8E8), Color(0xFF9AA8C0)),
    ArtPalette(Color(0xFF9B5CFF), Color(0xFFFF4CD8), Color(0xFF417DFF)), // Cosmic
    ArtPalette(Color(0xFFFF552E), Color(0xFFFFA332), Color(0xFFFFD16B)), // Ember
    ArtPalette(Color(0xFF39FFB1), Color(0xFF23C9FF), Color(0xFF9B79FF)), // Aurora
    ArtPalette(Color(0xFFFFC7A8), Color(0xFFE890A8), Color(0xFFB97885)), // Rose Gold
    ArtPalette(Color(0xFFB8FF24), Color(0xFF49FF68), Color(0xFF00DDBB)), // Electric Lime
    ArtPalette(Color(0xFF3450A3), Color(0xFF617AC9), Color(0xFF93B0ED)), // Midnight
    ArtPalette(Color(0xFFB9F5FF), Color(0xFF6DDCFF), Color(0xFF8EABFF)), // Ice
    ArtPalette(Color(0xFFFF365C), Color(0xFFCE164B), Color(0xFFFF8699)), // Ruby
    ArtPalette(Color(0xFFFFD05C), Color(0xFFFF9A39), Color(0xFFFF6250)), // Golden Hour
    ArtPalette(Color(0xFFC46BFF), Color(0xFF8153F5), Color(0xFFEA76E9)), // Ultraviolet
    ArtPalette(Color(0xFFF0F0F0), Color(0xFFB6B6B6), Color(0xFF737373)), // Monochrome
  ];

  /// Used by the VHS effect when the accent is left on Auto.
  static const vaporwave =
      ArtPalette(Color(0xFF01CDFE), Color(0xFFFF71CE), Color(0xFFB967FF));

  static const barCounts = [32, 48, 64, 96];

  int theme = 0; // index into themeNames
  bool visualizer = true;
  double sensitivity = 1.0; // 0.5 .. 1.5
  int vizStyle = 0; // Focused theme: 0 ring, 1 bars
  int barCount = 96;
  int accent = 0;
  double vhsEffects = 0.7; // VHS look strength 0 .. 1
  bool bgEffects = true; // slow drift + beat pulse
  bool particles = false;
  bool fxNebula = false;
  bool fxGrid = false;
  bool fxStars = false;
  double kNebula = 0.65;
  double kGrid = 0.5;
  double kStars = 0.6;
  bool showClock = true;
  bool clock24h = false;
  // Strength of each effect, 0 .. 1. Every effect has its own slider.
  double kGlow = 0.7;
  double kSweep = 0.7;
  double kRays = 0.7;
  double kRipples = 0.7;
  double kWater = 0.7;
  double kBloom = 0.7;
  double kParticles = 1.0;
  double kMotion = 1.0; // slow drift and beat pulse
  bool performance = false;
  int night = 1; // 0 off, 1 auto (8pm-6am), 2 always
  int fxPerformanceMode = 0; // 0 auto, 1 performance, 2 maximum visuals
  bool autoFxQuality = true; // live frame-time based shader quality governor
  bool burnIn = true;
  bool artLookup = true; // search online when a player sends no cover
  bool lyrics = false; // synced lyrics from LRCLIB
  bool bootStart = false;
  bool musicStart = false;
  bool vhsVaporwave = false; // VHS: pink/cyan instead of album colors
  bool fxGlow = false;
  bool fxSweep = false;
  bool fxRays = false;
  bool fxRipples = false;
  bool fxWater = false;
  bool fxBloom = false;
  static const extraFxNames = [
    'Liquid Refraction', 'Bass Shockwave', 'Aurora Curtains', 'Vortex Tunnel',
    'Electric Arcs', 'Prism Shards', 'Light Trails', 'Morphing Wireframe',
    'Particle Currents', 'Holographic Interference',
  ];
  final Map<String, bool> extraFx = {for (final n in extraFxNames) n: false};
  final Map<String, double> extraStrength = {for (final n in extraFxNames) n: 0.8};
  bool fxVhs = false; // VHS look over any theme (strength: vhsEffects)

  bool onboarded = false; // the first-launch tour has been shown
  String navPkg = ''; // navigation app (empty = find one automatically)
  String navLabel = '';
  bool driveAlbumCover = false; // Drive: square cover instead of spinning vinyl
  bool driveSwap = false; // Drive theme: navigation card on the left
  double driveCardWidth = 0.5; // Drive: share of the screen left open for the map, 0.35 .. 0.65
  int graceSec = 0; // a pause shorter than this does not reopen VYBE (0 = any pause reopens)
  bool driveControls = true; // Drive overlay: show prev/play/next
  bool driveAutoClose = true; // Drive overlay: close when guidance ends
  bool allowVideo = false; // let video apps open VYBE
  bool allowNavAudio = false; // let navigation audio open VYBE
  bool avoidNav = true; // never open VYBE while navigation is active
  bool driveBubble = true; // floating "return to VYBE" button while VYBE is hidden
  double driveBarsH = 0.14; // Drive: visualizer height along the bottom, share of screen height
  double bgOverlay = 1.0; // 0 clear, 1 original shading, 2 darker
  final Map<String, int> fxBlendMode = {for (final n in extraFxNames) n: 0};
  final Map<String, double> fxBlendOpacity = {for (final n in extraFxNames) n: 0.45};
  double bgContrast = 1.4; // blurred background contrast, 1.0 (normal) .. 2.0

  ArtPalette? get accentPalette =>
      (accent > 0 && accent < accents.length) ? accents[accent] : null;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    // The Drive overlay uses a separate Flutter engine with its own cache.
    // Refresh from Android storage before reading changes made by that engine.
    await p.reload();
    theme = _int(p, 'theme', 0, 0, themeNames.length - 1);
    visualizer = p.getBool('visualizer') ?? true;
    sensitivity = (p.getDouble('sensitivity') ?? 1.0).clamp(0.5, 1.5).toDouble();
    vizStyle = _int(p, 'vizStyle', 0, 0, 1);
    final bc = p.getInt('barCount') ?? 96;
    barCount = barCounts.contains(bc) ? bc : 96;
    accent = _int(p, 'accent', 0, 0, accents.length - 1);
    final oldFx = p.getDouble('effects') ?? 0.7;
    // Older versions had one slider; start the VHS one at that value.
    vhsEffects =
        (p.getDouble('vhsEffects') ?? oldFx).clamp(0.0, 1.0).toDouble();
    double k(String key, double def) =>
        (p.getDouble(key) ?? def).clamp(0.0, 1.0).toDouble();
    kGlow = k('kGlow', oldFx);
    kSweep = k('kSweep', oldFx);
    kRays = k('kRays', oldFx);
    kRipples = k('kRipples', oldFx);
    kWater = k('kWater', oldFx);
    kBloom = k('kBloom', oldFx);
    kParticles = k('kParticles', 1.0);
    kMotion = k('kMotion', 1.0);
    bgEffects = p.getBool('bgEffects') ?? true;
    particles = p.getBool('particles') ?? false;
    fxNebula = p.getBool('fxNebula') ?? false;
    fxGrid = p.getBool('fxGrid') ?? false;
    fxStars = p.getBool('fxStars') ?? false;
    kNebula = k('kNebula', 0.65);
    kGrid = k('kGrid', 0.5);
    kStars = k('kStars', 0.6);
    showClock = p.getBool('showClock') ?? true;
    clock24h = p.getBool('clock24h') ?? false;
    performance = p.getBool('performance') ?? false;
    autoFxQuality = p.getBool('autoFxQuality') ?? true;
    fxPerformanceMode = _int(p, 'fxPerformanceMode', 0, 0, 2);
    night = _int(p, 'night', 1, 0, 2);
    burnIn = p.getBool('burnIn') ?? true;
    artLookup = p.getBool('artLookup') ?? true;
    lyrics = p.getBool('lyrics') ?? false;
    bootStart = p.getBool('bootStart') ?? false;
    musicStart = p.getBool('musicStart') ?? false;
    vhsVaporwave = p.getBool('vhsVaporwave') ?? false;
    fxGlow = p.getBool('fxGlow') ?? false;
    fxSweep = p.getBool('fxSweep') ?? false;
    fxRays = p.getBool('fxRays') ?? false;
    fxRipples = p.getBool('fxRipples') ?? false;
    fxWater = p.getBool('fxWater') ?? false;
    fxBloom = p.getBool('fxBloom') ?? false;
    fxVhs = p.getBool('fxVhs') ?? false;
    for (final n in extraFxNames) {
      extraFx[n] = p.getBool('extraFx:$n') ?? false;
      extraStrength[n] = k('extraStrength:$n', 0.8);
    }
    var migrated = false;
    if (theme == tRemovedVhs) {
      // VHS used to be a theme. Keep the look as an effect on Focused.
      theme = 0;
      fxVhs = true;
      migrated = true;
    }
    onboarded = p.getBool('onboarded') ?? false;
    navPkg = p.getString('navPkg') ?? '';
    navLabel = p.getString('navLabel') ?? '';
    driveAlbumCover = p.getBool('driveAlbumCover') ?? false;
    driveSwap = p.getBool('driveSwap') ?? false;
    driveCardWidth =
        (p.getDouble('driveCardWidth') ?? 0.5).clamp(0.35, 0.65).toDouble();
    final g = p.getInt('graceSec') ?? 0;
    graceSec = const [0, 15, 30, 60].contains(g) ? g : 0;
    driveControls = p.getBool('driveControls') ?? true;
    driveAutoClose = p.getBool('driveAutoClose') ?? true;
    allowVideo = p.getBool('allowVideo') ?? false;
    allowNavAudio = p.getBool('allowNavAudio') ?? false;
    avoidNav = p.getBool('avoidNav') ?? true;
    driveBubble = p.getBool('driveBubble') ?? true;
    driveBarsH = (p.getDouble('driveBarsH') ?? 0.14).clamp(0.08, 0.26).toDouble();
    bgOverlay = (p.getDouble('bgOverlay') ?? 1.0).clamp(0.0, 2.0).toDouble();
    for (final n in extraFxNames) {
      fxBlendMode[n] = (p.getInt('fxBlendMode:$n') ?? 0).clamp(0, 7);
      fxBlendOpacity[n] = (p.getDouble('fxBlendOpacity:$n') ?? 0.45).clamp(0.0, 1.0).toDouble();
    }
    bgContrast = (p.getDouble('bgContrast') ?? 1.4).clamp(1.0, 2.0).toDouble();
    notifyListeners();
    if (migrated) save();
  }

  int _int(SharedPreferences p, String key, int def, int lo, int hi) {
    final v = p.getInt(key) ?? def;
    return (v < lo || v > hi) ? def : v;
  }

  Future<void> saveTheme() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('theme', theme);
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('theme', theme);
    await p.setBool('visualizer', visualizer);
    await p.setDouble('sensitivity', sensitivity);
    await p.setInt('vizStyle', vizStyle);
    await p.setInt('barCount', barCount);
    await p.setInt('accent', accent);
    await p.setDouble('kGlow', kGlow);
    await p.setDouble('kSweep', kSweep);
    await p.setDouble('kRays', kRays);
    await p.setDouble('kRipples', kRipples);
    await p.setDouble('kWater', kWater);
    await p.setDouble('kBloom', kBloom);
    await p.setDouble('kParticles', kParticles);
    await p.setDouble('kMotion', kMotion);
    await p.setDouble('vhsEffects', vhsEffects);
    await p.setBool('bgEffects', bgEffects);
    await p.setBool('particles', particles);
    await p.setBool('fxNebula', fxNebula);
    await p.setBool('fxGrid', fxGrid);
    await p.setBool('fxStars', fxStars);
    await p.setDouble('kNebula', kNebula);
    await p.setDouble('kGrid', kGrid);
    await p.setDouble('kStars', kStars);
    await p.setBool('showClock', showClock);
    await p.setBool('clock24h', clock24h);
    await p.setBool('performance', performance);
    await p.setBool('autoFxQuality', autoFxQuality);
    await p.setInt('fxPerformanceMode', fxPerformanceMode);
    await p.setInt('night', night);
    await p.setBool('burnIn', burnIn);
    await p.setBool('artLookup', artLookup);
    await p.setBool('lyrics', lyrics);
    await p.setBool('bootStart', bootStart);
    await p.setBool('musicStart', musicStart);
    await p.setBool('vhsVaporwave', vhsVaporwave);
    await p.setBool('fxGlow', fxGlow);
    await p.setBool('fxSweep', fxSweep);
    await p.setBool('fxRays', fxRays);
    await p.setBool('fxRipples', fxRipples);
    await p.setBool('fxWater', fxWater);
    await p.setBool('fxBloom', fxBloom);
    await p.setBool('fxVhs', fxVhs);
    for (final n in extraFxNames) {
      await p.setBool('extraFx:$n', extraFx[n] ?? false);
      await p.setDouble('extraStrength:$n', extraStrength[n] ?? 0.8);
    }
    await p.setBool('onboarded', onboarded);
    await p.setString('navPkg', navPkg);
    await p.setString('navLabel', navLabel);
    await p.setBool('driveAlbumCover', driveAlbumCover);
    await p.setBool('driveSwap', driveSwap);
    await p.setDouble('driveCardWidth', driveCardWidth);
    await p.setInt('graceSec', graceSec);
    await p.setBool('driveControls', driveControls);
    await p.setBool('driveAutoClose', driveAutoClose);
    await p.setBool('allowVideo', allowVideo);
    await p.setBool('allowNavAudio', allowNavAudio);
    await p.setBool('avoidNav', avoidNav);
    await p.setBool('driveBubble', driveBubble);
    await p.setDouble('driveBarsH', driveBarsH);
    await p.setDouble('bgOverlay', bgOverlay);
    for (final n in extraFxNames) {
      await p.setInt('fxBlendMode:$n', fxBlendMode[n] ?? 0);
      await p.setDouble('fxBlendOpacity:$n', fxBlendOpacity[n] ?? 0.45);
    }
    await p.setDouble('bgContrast', bgContrast);
  }

  /// Apply a change, tell listeners, and (by default) save it.
  void update(VoidCallback change, {bool persist = true}) {
    change();
    notifyListeners();
    if (persist) save();
  }
}
