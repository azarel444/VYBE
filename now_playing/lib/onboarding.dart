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
  static const _lastStep = 2;

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
    final s = widget.settings;
    if (s != null) {
      s.update(() {
        switch (key) {
          case 'artLookup':
            s.artLookup = v;
            break;
          case 'lyrics':
            s.lyrics = v;
            break;
          case 'bootStart':
            s.bootStart = v;
            break;
          case 'musicStart':
            s.musicStart = v;
            break;
        }
      });
      return;
    }
    final p = await SharedPreferences.getInstance();
    await p.setBool(key, v);
  }

  bool _granted(String k) => _perm[k] == true;

  Future<void> _next() async {
    if (_step >= _lastStep) {
      // Do not gate entry into VYBE on a potentially stalled preference write.
      // The selected values are captured from UI state and committed by the
      // root before its main screen is shown.
      widget.onDone();
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

  Widget _permissionRow(String title, String detail, String key,
      String action, VoidCallback request) {
    final granted = _granted(key);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(granted ? Icons.check_circle : Icons.radio_button_unchecked,
              color: granted ? Colors.greenAccent : Colors.white54, size: 22),
          const SizedBox(width: 10),
          Expanded(child: Text(title,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 4),
        Text(detail, style: const TextStyle(fontSize: 15, color: Colors.white70)),
        if (!granted)
          Align(alignment: Alignment.centerRight,
            child: TextButton(onPressed: request, child: Text(action))),
      ]),
    );
  }

  Widget _content() {
    switch (_step) {
      case 0:
        return _page(
          icon: Icons.security_outlined,
          title: 'Permissions',
          body: 'Allow the features you want. You can change these later in Settings.',
          extra: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _permissionRow('Music notifications', 'Detect songs, artwork and playback controls. Also checks navigation notifications for Drive features.', 'notification',
                'Enable', Native.openAccessSettings),
            _permissionRow('Audio access · Optional', 'Live visualizer. VYBE does not record microphone audio; without access, a simulated visualizer is used.', 'audio',
                'Enable', () async { await Native.requestAudio(); _refresh(); }),
            _permissionRow('Display over apps · Optional', 'Auto-open VYBE with music and show Drive overlays.', 'overlay',
                'Enable', Native.openOverlaySettings),
          ]),
        );
      case 1:
        return _page(
          icon: Icons.tune,
          title: 'Quick setup',
          body: 'Choose what VYBE does. Change any option later in Settings. Online artwork and lyrics searches send song title and artist to their providers.',
          extra: Column(children: [
            _switchRow('Find missing album art', _art, (v) {
              setState(() => _art = v);
              _put('artLookup', v);
            }),
            _switchRow('Show synced lyrics', _lyrics, (v) {
              setState(() => _lyrics = v);
              _put('lyrics', v);
            }),
            _switchRow('Open when music starts', _music, (v) {
              setState(() => _music = v);
              _put('musicStart', v);
            }),
            _switchRow('Open when device starts', _boot, (v) {
              setState(() => _boot = v);
              _put('bootStart', v);
            }),
          ]),
        );
      default:
        return _page(
          icon: Icons.touch_app_outlined,
          title: 'Your VYBE controls',
          body: 'Tap the player to show the toolbar. Here are the controls for both modes.',
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
    return Row(children: [
      if (_step > 0)
        TextButton(onPressed: _back,
            child: const Text('Back', style: TextStyle(fontSize: 18))),
      const Spacer(),
      Flexible(child: ElevatedButton(
        onPressed: _next,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Text(_step == _lastStep ? 'Launch VYBE' : 'Continue',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 19)),
        ),
      )),
    ]);
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
