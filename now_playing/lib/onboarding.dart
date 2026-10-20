import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'native.dart';
import 'settings.dart';

const _cyan = Color(0xFF00E5FF);

/// The VYBE logo on black for a moment while the app starts.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: 1),
          duration: const Duration(milliseconds: 900),
          curve: Curves.easeOut,
          builder: (context, v, child) => Opacity(
            opacity: v,
            child: Transform.scale(scale: 0.92 + 0.08 * v, child: child),
          ),
          child: Image.asset(
            'assets/vybe_logo.png',
            width: 460,
            errorBuilder: (context, error, stack) => const Text(
              'VYBE',
              style: TextStyle(fontSize: 64, fontWeight: FontWeight.w300),
            ),
          ),
        ),
      ),
    );
  }
}

/// First-launch tour. Every permission is explained before Android is asked
/// for it. Optional ones can be skipped; the tour can be replayed from
/// Settings.
class OnboardingScreen extends StatefulWidget {
  // One-time in-process handoff prevents stale preference reads at launch.
  static Map<String, bool>? launchSelections;

  final VoidCallback onDone;

  /// Given when replayed from Settings, so changes go through the same
  /// settings object the rest of the app is using.
  final AppSettings? settings;

  const OnboardingScreen({super.key, required this.onDone, this.settings});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  static const _lastStep = 7;

  int _step = 0;
  Map<String, bool> _perm = const {
    'notification': false,
    'audio': false,
    'overlay': false,
  };
  bool _art = true;
  bool _lyrics = false;
  bool _boot = false;
  bool _music = false;
  Timer? _poll;
  Future<void> _pendingChoiceWrite = Future<void>.value();
  bool _choicesTouched = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadChoices();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _loadChoices() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    if (_choicesTouched) return;
    setState(() {
      _art = p.getBool('artLookup') ?? true;
      _lyrics = p.getBool('lyrics') ?? false;
      _boot = p.getBool('bootStart') ?? false;
      _music = p.getBool('musicStart') ?? false;
    });
  }

  Future<void> _refresh() async {
    final r = await Native.permissionStatus();
    if (!mounted) return;
    var same = r.length == _perm.length;
    if (same) {
      for (final k in r.keys) {
        if (r[k] != _perm[k]) same = false;
      }
    }
    if (!same) setState(() => _perm = r);
  }

  /// Saves a yes/no choice, through the app's settings when replaying.
  Future<void> _put(String key, bool v) async {
    // Serialize writes so finishing onboarding cannot race the final toggle.
    final previous = _pendingChoiceWrite;
    final next = previous.catchError((Object _) {}).then((_) => _saveChoice(key, v));
    _pendingChoiceWrite = next;
    await next;
  }

  Future<void> _saveChoice(String key, bool v) async {
    // Commit each onboarding selection directly to the same preferences store
    // read by AppSettings.load. Avoid a full-settings save from an instance
    // whose other fields may still contain defaults.
    await AppSettings.persistContentChoice(key, v);
    final settings = widget.settings;
    if (settings != null) {
      switch (key) {
        case 'artLookup': settings.artLookup = v; break;
        case 'lyrics': settings.lyrics = v; break;
        case 'bootStart': settings.bootStart = v; break;
        case 'musicStart': settings.musicStart = v; break;
      }
      settings.notifyListeners();
    }
  }

  bool _granted(String k) => _perm[k] == true;

  Future<void> _next() async {
    if (_step >= _lastStep) {
      OnboardingScreen.launchSelections = {
        'artLookup': _art, 'lyrics': _lyrics,
        'bootStart': _boot, 'musicStart': _music,
      };
      // Do not gate entry into VYBE on a potentially stalled preference write.
      // The selected values are captured from UI state and committed by the
      // root before its main screen is shown.
      try {
        await _pendingChoiceWrite.timeout(const Duration(seconds: 3));
        await Future.wait([
          AppSettings.persistContentChoice('artLookup', _art),
          AppSettings.persistContentChoice('lyrics', _lyrics),
          AppSettings.persistContentChoice('bootStart', _boot),
          AppSettings.persistContentChoice('musicStart', _music),
        ]).timeout(const Duration(seconds: 5));
      } catch (e) {
        debugPrint('VYBE onboarding preference commit: $e');
      }
      if (mounted) widget.onDone();
    } else {
      setState(() => _step++);
    }
  }

  void _back() {
    if (_step > 0) setState(() => _step--);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF05070D),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              children: [
                const SizedBox(height: 14),
                _dots(),
                Expanded(
                  child: SingleChildScrollView(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                    child: _content(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 4, 32, 18),
                  child: _buttons(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _dots() => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List<Widget>.generate(
          _lastStep + 1,
          (i) => Container(
            margin: const EdgeInsets.symmetric(horizontal: 5),
            width: i == _step ? 22 : 9,
            height: 9,
            decoration: BoxDecoration(
              color: i == _step
                  ? _cyan
                  : (i < _step ? Colors.white54 : Colors.white24),
              borderRadius: BorderRadius.circular(5),
            ),
          ),
        ),
      );

  Widget _content() {
    switch (_step) {
      case 0:
        return _page(
          icon: null,
          title: 'Welcome to VYBE',
          body: 'VYBE turns your head unit into a now playing screen with '
              'album art, a live visualizer and lyrics.\n\n'
              'Before it asks for anything, the next screens explain what each '
              'permission is for and what VYBE does with it. Everything stays '
              'on your device, except two optional online features that you '
              'choose below.',
          logo: true,
        );
      case 1:
        return _page(
          icon: Icons.notifications_active_outlined,
          title: 'Notification access',
          tag: 'Required',
          status: _granted('notification'),
          body: 'This is how Android lets an app see what is playing. VYBE '
              'reads only the title, artist, album and cover of the current '
              'song, and lets you pause and skip.\n\n'
              'It also checks whether a navigation app is guiding, so VYBE '
              'does not open over your map. In the optional Drive mode it '
              'reads the text of the navigation notification (the next turn) '
              'to show it on screen. Nothing else is read.\n\n'
              'VYBE does not read your messages, and nothing it sees leaves '
              'your device.',
        );
      case 2:
        return _page(
          icon: Icons.graphic_eq,
          title: 'Audio access',
          tag: 'Optional',
          status: _granted('audio'),
          body: 'The live visualizer analyzes the sound your player is '
              'outputting, and Android protects that behind its microphone '
              'permission. That is the only reason it is requested.\n\n'
              'VYBE does not use the microphone. It never records, stores or '
              'sends audio.\n\n'
              'If you skip this, the visualizer still works from a simulated '
              'pattern that moves with the music.',
        );
      case 3:
        return _page(
          icon: Icons.cloud_outlined,
          title: 'Online features',
          tag: 'Optional',
          body: 'Two features use the internet. Android grants the internet '
              'permission automatically, so these switches are the real '
              'choice.\n\n'
              'Album art search finds a cover when your player does not send '
              'one (iTunes Search). Synced lyrics come from LRCLIB. Both '
              'send only the song title and artist.\n\n'
              'Without them VYBE works fully offline.',
          extra: Column(
            children: [
              _switchRow(
                'Find missing album art',
                _art,
                (v) {
                  setState(() { _choicesTouched = true; _art = v; });
                  _put('artLookup', v);
                },
              ),
              _switchRow(
                'Show synced lyrics',
                _lyrics,
                (v) {
                  setState(() { _choicesTouched = true; _lyrics = v; });
                  _put('lyrics', v);
                },
              ),
            ],
          ),
        );
      case 4:
        return _page(
          icon: Icons.open_in_new,
          title: 'Display over other apps',
          tag: 'Optional',
          status: _granted('overlay'),
          body: 'Newer versions of Android do not let an app open itself '
              'while another app is on screen, unless this is allowed. '
              'It is what lets VYBE open when your music starts.\n\n'
              'It is also what lets the optional Drive mode draw album art and '
              'song info over your map app, and a small "return to VYBE" button '
              'while VYBE is hidden so you can get back to it (it can be '
              'turned off in settings). VYBE draws nothing over other apps '
              'unless you start Drive. If you skip this, VYBE can still be '
              'opened by hand, and auto-open may not work on your unit.',
        );
      case 5:
        return _page(
          icon: Icons.play_circle_outline,
          title: 'Opening by itself',
          tag: 'Optional',
          body: 'VYBE opens when you start or change a song in a music player. It '
              'does not open when a song just ends and the next one plays by '
              'itself. It stays out of the way for video, navigation voice and '
              'phone calls, and it does not open while navigation is guiding.\n\n'
              'Some head units have their own auto-start manager, which must '
              'also allow VYBE.',
          extra: Column(
            children: [
              _switchRow(
                'Open when the unit starts',
                _boot,
                (v) {
                  setState(() { _choicesTouched = true; _boot = v; });
                  _put('bootStart', v);
                },
              ),
              _switchRow(
                'Open when music starts',
                _music,
                (v) {
                  setState(() { _choicesTouched = true; _music = v; });
                  _put('musicStart', v);
                },
              ),
            ],
          ),
        );
      case 6:
        return _page(
          icon: Icons.check_circle_outline,
          title: 'You are set',
          body: 'You can review every permission and change any choice later '
              'in Settings, on the Permissions tab. You can also '
              'replay this tour from there.',
          extra: Column(
            children: [
              _summaryRow('Notification access', _granted('notification')),
              _summaryRow('Audio access (live visualizer)', _granted('audio')),
              _summaryRow('Display over other apps', _granted('overlay')),
              _summaryRow('Album art search', _art),
              _summaryRow('Synced lyrics', _lyrics),
              _summaryRow('Open when the unit starts', _boot),
              _summaryRow('Open when music starts', _music),
            ],
          ),
        );
      default:
        return _page(
          icon: Icons.touch_app_outlined,
          title: 'Your VYBE controls',
          body: 'The floating toolbar appears when you tap the player. '
              'These are the expanded controls in both modes. '
              'No guessing or tapping around required.',
          extra: const ToolbarGuide(),
        );
    }
  }

  Widget _page({
    required IconData? icon,
    required String title,
    required String body,
    String? tag,
    bool? status,
    Widget? extra,
    bool logo = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (logo)
          Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Image.asset(
                'assets/vybe_logo.png',
                width: 340,
                errorBuilder: (context, error, stack) =>
                    const SizedBox.shrink(),
              ),
            ),
          )
        else if (icon != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Icon(icon, size: 56, color: _cyan),
          ),
        Row(
          children: [
            Flexible(
              child: Text(
                title,
                style:
                    const TextStyle(fontSize: 32, fontWeight: FontWeight.w300),
              ),
            ),
            if (tag != null) ...[
              const SizedBox(width: 14),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: tag == 'Required' ? Colors.orangeAccent : Colors.white38),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  tag,
                  style: TextStyle(
                    fontSize: 14,
                    color:
                        tag == 'Required' ? Colors.orangeAccent : Colors.white60,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 14),
        Text(
          body,
          style: const TextStyle(
              fontSize: 19, height: 1.45, color: Color(0xDDFFFFFF)),
        ),
        if (status != null) ...[
          const SizedBox(height: 18),
          Row(
            children: [
              Icon(status ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: status ? Colors.greenAccent : Colors.white38),
              const SizedBox(width: 10),
              Text(
                status ? 'Allowed' : 'Not allowed yet',
                style: TextStyle(
                  fontSize: 18,
                  color: status ? Colors.greenAccent : Colors.white60,
                ),
              ),
            ],
          ),
        ],
        if (extra != null) ...[const SizedBox(height: 14), extra],
      ],
    );
  }

  Widget _switchRow(String label, bool value, ValueChanged<bool> onChanged) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: const TextStyle(fontSize: 20)),
        value: value,
        onChanged: onChanged,
      );

  Widget _summaryRow(String label, bool on) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(on ? Icons.check_circle : Icons.remove_circle_outline,
                size: 22, color: on ? Colors.greenAccent : Colors.white38),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 18, color: on ? Colors.white : Colors.white54)),
            ),
            Text(on ? 'On' : 'Off',
                style: TextStyle(
                    fontSize: 16, color: on ? Colors.greenAccent : Colors.white38)),
          ],
        ),
      );

  Widget _buttons() {
    final optional = _step == 2 || _step == 4;
    final isRequired = _step == 1;
    String label;
    VoidCallback onPressed;

    if (_step == 0) {
      label = 'Get started';
      onPressed = _next;
    } else if (_step == _lastStep) {
      label = 'Launch VYBE';
      onPressed = _next;
    } else if (isRequired && !_granted('notification')) {
      label = 'Open notification settings';
      onPressed = Native.openAccessSettings;
    } else if (_step == 2 && !_granted('audio')) {
      label = 'Allow audio access';
      onPressed = () async {
        await Native.requestAudio();
        _refresh();
      };
    } else if (_step == 4 && !_granted('overlay')) {
      label = 'Open settings';
      onPressed = Native.openOverlaySettings;
    } else {
      label = 'Continue';
      onPressed = _next;
    }

    final showSkip = (optional && !_granted(_step == 2 ? 'audio' : 'overlay')) ||
        (isRequired && !_granted('notification'));

    // A Wrap instead of a Row, so a long label drops to its own line
    // instead of running off the edge of the screen.
    return LayoutBuilder(builder: (context, box) {
      return Wrap(
        alignment: WrapAlignment.end,
        runAlignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          if (_step > 0)
            TextButton(
              onPressed: _back,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Text('Back', style: TextStyle(fontSize: 18)),
              ),
            ),
          if (showSkip)
            TextButton(
              onPressed: _next,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Text('Skip for now',
                    style: TextStyle(fontSize: 18, color: Colors.white60)),
              ),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: box.maxWidth),
            child: ElevatedButton(
              onPressed: onPressed,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 19),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}

/// Read-only guide using the same icons and ordering as the expanded player
/// toolbar. Both variants remain visible without needing to activate Drive.
class ToolbarGuide extends StatelessWidget {
  const ToolbarGuide({super.key});

  static const _normal = <_GuideControl>[
    _GuideControl(Icons.grid_view_rounded, 'Themes', 'Choose a Now Playing theme'),
    _GuideControl(Icons.settings, 'Settings', 'Adjust visuals, FX, permissions and launch options'),
    _GuideControl(Icons.navigation_rounded, 'Drive', 'Open the Drive map experience'),
    _GuideControl(Icons.skip_previous_rounded, 'Previous', 'Go to the previous track'),
    _GuideControl(Icons.play_circle_filled, 'Play / Pause', 'Control music playback'),
    _GuideControl(Icons.skip_next_rounded, 'Next', 'Skip to the next track'),
  ];
  static const _drive = <_GuideControl>[
    _GuideControl(Icons.grid_view_rounded, 'Themes', 'Choose a Now Playing theme'),
    _GuideControl(Icons.settings, 'Settings', 'Adjust visuals, FX, permissions and launch options'),
    _GuideControl(Icons.map_outlined, 'Show Map', 'Return to the map while Drive stays active'),
    _GuideControl(Icons.close_rounded, 'Close Drive', 'Exit the Drive overlay'),
    _GuideControl(Icons.skip_previous_rounded, 'Previous', 'Go to the previous track'),
    _GuideControl(Icons.play_circle_filled, 'Play / Pause', 'Control music playback'),
    _GuideControl(Icons.skip_next_rounded, 'Next', 'Skip to the next track'),
  ];

  Widget _section(String title, List<_GuideControl> controls) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _cyan)),
        const SizedBox(height: 10),
        // Full expanded toolbar preview, scaled to fit narrow portrait screens.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xDD151A25),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white24),
          ),
          child: Column(children: [
            const Row(children: [
              Icon(Icons.linear_scale, color: Colors.white38, size: 18),
              SizedBox(width: 8),
              Expanded(child: Divider(color: Colors.white24, thickness: 3)),
              SizedBox(width: 8),
              Text('0:00 / 0:00', style: TextStyle(color: Colors.white54, fontSize: 11)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              for (var i = 0; i < controls.length; i++)
                Expanded(child: Column(children: [
                  Icon(controls[i].icon, size: 25, color: Colors.white),
                  const SizedBox(height: 5),
                  Text('${i + 1}', style: const TextStyle(color: _cyan, fontSize: 12, fontWeight: FontWeight.bold)),
                ])),
            ]),
          ]),
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < controls.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 26, height: 26,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: Color(0x3322DDEE), shape: BoxShape.circle),
                child: Text('${i + 1}', style: const TextStyle(color: _cyan, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text('${controls[i].label} — ${controls[i].description}',
                style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.3))),
            ]),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _section('Standard', _normal),
      _section('Drive Theme Activated', _drive),
      const SizedBox(height: 16),
      const Text('Tap the screen to show the toolbar. The seek bar at the top '
          'lets you move through the track; playback time and audio status '
          'appear at the right. Tap outside the toolbar to return to the full view.',
          style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.4)),
    ],
  );
}

class _GuideControl {
  final IconData icon;
  final String label;
  final String description;
  const _GuideControl(this.icon, this.label, this.description);
}
