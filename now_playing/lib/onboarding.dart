import 'local_artwork.dart';
import 'portable_media_cache.dart';
import 'local_artwork_scan.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'native.dart';
import 'settings.dart';
import 'vybe_link.dart';

const _cyan = Color(0xFFFF005E);

/// The VYBE logo on black for a moment while the app starts.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final landscape = constraints.maxWidth > constraints.maxHeight;
          return SizedBox.expand(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOut,
              builder: (context, value, child) =>
                  Opacity(opacity: value, child: child),
              child: Image.asset(
                landscape
                    ? 'assets/vybe_splash_landscape.png'
                    : 'assets/vybe_splash_portrait.png',
                fit: BoxFit.cover,
                alignment: Alignment.center,
                gaplessPlayback: true,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// First-launch tour. Every permission is explained before Android is asked
/// for it. Optional ones can be skipped; the tour can be replayed from
/// Settings.
class OnboardingScreen extends StatefulWidget {
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
  String _deviceType = 'phone';
  bool _deviceChoiceTouched = false;
  Future<void> _pendingDeviceTypeWrite = Future<void>.value();
  String _localArtStatus = 'Optional — you can set this up later.';
  bool _choosingArtwork = false;
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
      if (!_deviceChoiceTouched) {
        _deviceType = p.getString('vybe_device_type') ??
            ((p.getString('link_role') ?? 'sender') == 'receiver'
                ? 'head_unit' : 'phone');
      }
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

  void _chooseDeviceType(String choice) {
    if (choice != 'phone' && choice != 'head_unit') return;
    setState(() {
      _deviceType = choice;
      _deviceChoiceTouched = true;
    });
    // Persist during Quick Setup, well before the final Launch button.
    // A replay of onboarding also switches an already active Connect role.
    _pendingDeviceTypeWrite = _pendingDeviceTypeWrite
        .catchError((Object _) {})
        .then((_) => VybeLink.instance.setDeviceType(choice));
  }

  Future<void> _next() async {
    if (_step >= _lastStep) {
      // Finish the device role choice before the receiver/sender starts.
      await _pendingDeviceTypeWrite.catchError((Object error) {
        debugPrint('VYBE: device setup save failed: $error');
      });
      // Do not gate entry into VYBE on a potentially stalled preference write.
      // The selected values are captured from UI state and committed by the
      // root before its main screen is shown.
      OnboardingScreen.launchSelections = {
        'artLookup': _art,
        'lyrics': _lyrics,
        'bootStart': _boot,
        'musicStart': _music,
      };
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
      backgroundColor: const Color(0xFF0B0B0F),
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
            const Divider(height: 28),
            const Text('Google Maps Drive setup · Optional',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('Google Maps picture-in-picture can cover VYBE when returning to Drive. Turn off Allow picture-in-picture for Maps to avoid the popup.'),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: Native.openMapsPipSettings,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open Picture-in-Picture Settings'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF005E),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18, vertical: 15),
                  textStyle: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ]),
        );
      case 1:
        return _page(
          icon: Icons.tune,
          title: 'Quick setup',
          body: 'Choose what VYBE does. Change any option later in Settings. Online artwork and lyrics searches send song title and artist to their providers.',
          extra: Column(children: [
            const SizedBox(height: 8),
            const Text('Where is VYBE installed?',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment<String>(
                    value: 'phone', label: Text('Phone'),
                    icon: Icon(Icons.smartphone)),
                ButtonSegment<String>(
                    value: 'head_unit', label: Text('Head unit'),
                    icon: Icon(Icons.directions_car)),
              ],
              selected: {_deviceType},
              onSelectionChanged: (choices) => _chooseDeviceType(choices.first),
            ),
            const SizedBox(height: 6),
            Text(_deviceType == 'head_unit'
                ? 'VYBE Connect will receive music information and artwork from your phone.'
                : 'VYBE Connect will send music information and artwork to your head unit.',
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 18),
            const Text('Local music & artwork',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('Select your music folder to index local artwork. Choose a separate Saved Artwork location below to preserve those images and future downloads, even if the music USB drive is lost. You can also choose the same folder for both.'),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF005E),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                  textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              onPressed: _choosingArtwork ? null : () async {
                setState(() => _choosingArtwork = true);
                try {
                  final selected = await LocalArtwork.instance.chooseFolder();
                  if (!mounted) return;
                  if (selected) {
                    await showLocalArtworkScan(context);
                    if (mounted) setState(() => _localArtStatus = LocalArtwork.instance.status);
                  }
                } catch (e) {
                  if (mounted) setState(() => _localArtStatus = 'Folder selection failed: $e');
                } finally {
                  if (mounted) setState(() => _choosingArtwork = false);
                }
              },
              icon: const Icon(Icons.folder_open),
              label: const Text('SELECT LOCAL MUSIC FOLDER'),
              ),
            ),
            Text(_localArtStatus, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            const Text('Saved Artwork Library',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
            const Text('Choose Documents/internal storage, the music folder, or another accessible directory. VYBE makes permanent copies of imported album art, backgrounds, logos and downloaded artwork into its VYBE Cache subfolder.'),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _choosingArtwork ? null : () async {
                  setState(() => _choosingArtwork = true);
                  try {
                    final selected = await PortableMediaCache.chooseLocation();
                    if (!mounted) return;
                    if (selected) {
                      await PortableMediaCache.backupExisting();
                      await LocalArtwork.instance.reconnectSavedArtwork();
                      final copies = await LocalArtwork.instance.mirrorIndexedArtwork();
                      if (mounted) setState(() =>
                          _localArtStatus = '$copies local images preserved in Saved Artwork Library.');
                    }
                  } catch (error) {
                    if (mounted) setState(() =>
                        _localArtStatus = 'Saved artwork folder error: $error');
                  } finally {
                    if (mounted) setState(() => _choosingArtwork = false);
                  }
                },
                icon: const Icon(Icons.save_alt),
                label: const Text('SELECT SAVED ARTWORK FOLDER'),
              ),
            ),
            const SizedBox(height: 14),
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
          body: 'Tap Now Playing to slide up the full-width playback controls. Customize opens a separate floating panel for this theme.',
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
              child: SvgPicture.asset('assets/vybe_edgy_logo.svg', width: 340),
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
      ElevatedButton(
        onPressed: _next,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Text(_step == _lastStep ? 'Launch VYBE' : 'Continue',
              softWrap: false,
              style: const TextStyle(fontSize: 17)),
        ),
      ),
    ]);
  }

}

/// Read-only guide using the same icons and ordering as the expanded player
/// toolbar. Both variants remain visible without needing to activate Drive.
class ToolbarGuide extends StatelessWidget {
  const ToolbarGuide({super.key});

  static const _normal = <_GuideControl>[
    _GuideControl(Icons.grid_view_rounded, 'Themes', 'Choose a Now Playing theme'),
    _GuideControl(Icons.tune_rounded, 'Customize', 'Background, darkness, blur, logo size, palette and FX for this theme'),
    _GuideControl(Icons.settings_outlined, 'Settings', 'Advanced options, permissions and VYBE Connect'),
    _GuideControl(Icons.swap_horiz_rounded, 'Flip layout', 'Swap sides in supported landscape themes'),
    _GuideControl(Icons.navigation_rounded, 'Drive', 'Open the Drive map experience'),
    _GuideControl(Icons.skip_previous_rounded, 'Previous', 'Go to the previous track'),
    _GuideControl(Icons.play_circle_filled, 'Play / Pause', 'Control music playback'),
    _GuideControl(Icons.skip_next_rounded, 'Next', 'Skip to the next track'),
  ];
  static const _drive = <_GuideControl>[
    _GuideControl(Icons.grid_view_rounded, 'Themes', 'Choose a Now Playing theme'),
    _GuideControl(Icons.tune_rounded, 'Customize', 'Background, darkness, blur, logo size, palette and FX for this theme'),
    _GuideControl(Icons.settings_outlined, 'Settings', 'Advanced options, permissions and VYBE Connect'),
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
          decoration: const BoxDecoration(
            color: Color(0xE5101219),
            boxShadow: [BoxShadow(color: Color(0x77000000),
              blurRadius: 18, offset: Offset(0, -6))],
          ),
          child: Column(children: [
            const Row(children: [
              Icon(Icons.linear_scale, color: Colors.white38, size: 18),
              SizedBox(width: 8),
              Expanded(child: Divider(color: Colors.white24, thickness: 3)),
              SizedBox(width: 8),
              Text('0:00 / 0:00', style: TextStyle(color: Colors.white54, fontSize: 11)),
            ]),
            Container(height: 3, decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [
                Color(0xFFFF27A8), Color(0xFF995CFF), Color(0xFF05E2F3)]))),
            const SizedBox(height: 10),
            Row(children: [
              for (var i = 0; i < controls.length; i++)
                Expanded(child: Column(children: [
                  Icon(controls[i].icon, size: 20, color: Colors.white),
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
      const Padding(padding: EdgeInsets.only(top: 6), child: Text('Flip layout appears in supported landscape themes only.', style: TextStyle(color: Colors.white70, fontSize: 14))),
      _section('Drive Theme Activated', _drive),
      const SizedBox(height: 16),
      const Text('Tap the screen to slide up the controls. The VYBE gradient sits above the seek bar. Customize opens a floating per-theme panel for backgrounds, logo size and FX Gallery. Settings has advanced options. Tap outside to return to full-screen artwork.',
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
