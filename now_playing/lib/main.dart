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

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    var done = false;
    try {
      final p = await SharedPreferences.getInstance();
      done = p.getBool('onboarded') ?? false;
    } catch (_) {}
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

  Future<void> _finish() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('onboarded', true);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _onboarded = true);
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
