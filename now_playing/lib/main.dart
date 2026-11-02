import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'native_preferences.dart';

import 'now_playing_screen.dart';
import 'onboarding.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final initialRoute = ui.PlatformDispatcher.instance.defaultRouteName;
  // This isolated route is an opt-in FlutterView/WindowManager experiment.
  // It must not change the Maps activity's system UI or load the real Drive UI.
  if (initialRoute == '/drive-overlay-probe') {
    runApp(const _DriveOverlayProbeApp());
    return;
  }
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  // The see-through Drive window starts the same app on the '/drive' route.
  final driveHost = initialRoute == '/drive';
  runApp(NowPlayingApp(driveHost: driveHost));
}

/// Opt-in, activity-independent FlutterView overlay experiment. The native
/// service supplies a small media-session snapshot and transport controls;
/// the full Drive UI and its other channels remain untouched.
class _DriveOverlayProbeApp extends StatefulWidget {
  const _DriveOverlayProbeApp();

  @override
  State<_DriveOverlayProbeApp> createState() => _DriveOverlayProbeAppState();
}

class _DriveOverlayProbeAppState extends State<_DriveOverlayProbeApp> {
  static const _channel = MethodChannel('vybe/drive_overlay_probe');
  Timer? _timer;
  String _title = 'Checking music…';
  String _artist = '';
  bool _playing = false;
  bool _fetching = false;
  String _artKey = '';
  Uint8List? _artwork;

  @override
  void initState() {
    super.initState();
    _refreshTrack();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refreshTrack());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refreshTrack() async {
    if (_fetching) return;
    _fetching = true;
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>('track');
      if (!mounted || data == null) return;
      final nextArtKey = (data['artKey'] as String?) ?? '';
      final artworkChanged = nextArtKey != _artKey;
      setState(() {
        _title = (data['title'] as String?) ?? 'Nothing playing';
        _artist = (data['artist'] as String?) ?? '';
        _playing = data['playing'] == true;
        if (artworkChanged) {
          _artKey = nextArtKey;
          _artwork = null;
        }
      });
      if (artworkChanged && nextArtKey.isNotEmpty) {
        _loadArtwork(nextArtKey);
      }
    } on PlatformException catch (e) {
      debugPrint('VYBE overlay probe media bridge: $e');
    } finally {
      _fetching = false;
    }
  }

  // Request art only when the media session changes its track/art key.
  // This deliberately uses session art, not VYBE's production local-art or
  // network fanart resolver, so the probe cannot regress those features.
  Future<void> _loadArtwork(String key) async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('artwork');
      if (!mounted || _artKey != key) return;
      setState(() => _artwork = bytes);
    } on PlatformException catch (e) {
      debugPrint('VYBE overlay probe artwork bridge: $e');
    }
  }

  Future<void> _send(String command) async {
    try {
      await _channel.invokeMethod<bool>('transport', {'command': command});
      await _refreshTrack();
    } on PlatformException catch (e) {
      debugPrint('VYBE overlay probe transport: $e');
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(),
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: Container(
            color: const Color(0xDD10131C),
            padding: const EdgeInsets.all(12),
            child: SafeArea(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.layers_outlined,
                      size: 36, color: Color(0xFF05D9FF)),
                  const SizedBox(height: 12),
                  const Text('VYBE Flutter overlay test',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                  if (_artwork != null) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: 92,
                      height: 92,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(_artwork!, fit: BoxFit.cover,
                            gaplessPlayback: true),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(_title, textAlign: TextAlign.center,
                      maxLines: 3, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  if (_artist.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(_artist, textAlign: TextAlign.center,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Previous track',
                        onPressed: () => _send('previous'),
                        icon: const Icon(Icons.skip_previous),
                      ),
                      IconButton(
                        tooltip: _playing ? 'Pause' : 'Play',
                        onPressed: () => _send('toggle'),
                        icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                      ),
                      IconButton(
                        tooltip: 'Next track',
                        onPressed: () => _send('next'),
                        icon: const Icon(Icons.skip_next),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Maps should stay fullscreen and touchable on the right. '
                    'Test artwork, track updates and controls without switching apps.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => _channel.invokeMethod<void>('close'),
                    child: const Text('Close test'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

class NowPlayingApp extends StatelessWidget {
  final bool driveHost;

  const NowPlayingApp({super.key, this.driveHost = false});

  @override
  Widget build(BuildContext context) {
    // Drive is a translucent Android activity. A default MaterialPageRoute is
    // opaque even when the child Scaffold is transparent, hiding Google Maps.
    // Use a non-opaque route and transparent app canvas for the Drive engine.
    if (driveHost) {
      return MaterialApp(
        title: 'VYBE Drive',
        debugShowCheckedModeBanner: false,
        color: Colors.transparent,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Colors.transparent,
          canvasColor: Colors.transparent,
          useMaterial3: false,
        ),
        onGenerateRoute: (_) => PageRouteBuilder<void>(
          opaque: false,
          barrierColor: null,
          pageBuilder: (context, animation, secondaryAnimation) =>
              const NowPlayingScreen(driveHost: true),
        ),
      );
    }
    return MaterialApp(
      title: 'VYBE',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        useMaterial3: false,
      ),
      initialRoute: '/',
      home: driveHost ? const NowPlayingScreen(driveHost: true) : const _Root(),
    );
  }
}

/// Splash first, then the first-launch tour (once), then the player.
class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  bool? _onboarded; // null while checking persistent setup state
  bool _firstLaunchSplash = false;
  static const _setupChannel = MethodChannel("vybe/setup_state");

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    var done = false;
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      done = (p.getBool('vybe_setup_completed_v2') ?? false) || (p.getBool('onboarded') ?? false);
    } catch (e) {
      debugPrint('VYBE: Flutter setup read failed: $e');
    }
    // Native Android storage is independent of Flutter SharedPreferences caches
    // and survives app process restarts. Either valid completion record wins.
    try {
      final nativeDone = await _setupChannel.invokeMethod<bool>('isComplete') ?? false;
      done = done || nativeDone;
      if (done && !nativeDone) {
        await _setupChannel.invokeMethod<bool>('complete');
      }
    } catch (e) {
      debugPrint('VYBE: native setup read failed: $e');
    }
    if (!mounted) return;
    if (done) {
      // Returning users go straight to their saved Now Playing theme.
      setState(() => _onboarded = true);
      return;
    }
    setState(() => _firstLaunchSplash = true);
    await Future<void>.delayed(const Duration(milliseconds: 1800));
    if (!mounted) return;
    setState(() { _firstLaunchSplash = false; _onboarded = false; });
  }

  bool _finishing = false;

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    // Enter the player immediately. A slow Android channel or preferences
    // operation must never leave Launch VYBE stuck on the last tour page.
    if (mounted) setState(() => _onboarded = true);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('vybe_setup_completed_v2', true);
      await p.setBool('onboarded', true);
    } catch (e) {
      debugPrint('VYBE: onboarding save failed: $e');
    }
    try {
      final saved = await _setupChannel.invokeMethod<bool>('complete')
          .timeout(const Duration(seconds: 3));
      if (saved != true) debugPrint('VYBE: native setup commit returned $saved');
    } catch (e) {
      debugPrint('VYBE: native setup commit failed: $e');
    } finally {
      _finishing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = _onboarded;
    if (o == null) {
      return _firstLaunchSplash
          ? const SplashScreen()
          : const Scaffold(backgroundColor: Colors.black);
    }
    if (!o) return OnboardingScreen(onDone: _finish);
    return const NowPlayingScreen();
  }
}
