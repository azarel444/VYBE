import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'now_playing_screen.dart';
import 'onboarding.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  // The see-through Drive window starts the same app on the '/drive' route.
  final driveHost = ui.PlatformDispatcher.instance.defaultRouteName == '/drive';
  runApp(NowPlayingApp(driveHost: driveHost));
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
