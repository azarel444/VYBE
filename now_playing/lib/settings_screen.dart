import 'package:flutter/material.dart';

import 'native.dart';
import 'now_playing_model.dart';
import 'onboarding.dart';
import 'settings.dart';
import 'fx_library.dart';
import 'media_cache.dart';

const _cyan = Color(0xFF00E5FF);

/// Full-screen settings page with large touch targets for head units.
/// Split into tabs so each page stays short.
class SettingsScreen extends StatelessWidget {
  final AppSettings settings;
  final NowPlayingModel model;

  const SettingsScreen({super.key, required this.settings, required this.model});

  static const _tabNames = [
    'General',
    'Visuals',
    'Launch',
    'Navigation',
    'Permissions',
  ];

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _tabNames.length,
      child: Scaffold(
        backgroundColor: const Color(0xFF05070D),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Image.asset(
                            'assets/vybe_logo.png',
                            height: 34,
                            errorBuilder: (context, error, stack) =>
                                const SizedBox.shrink(),
                          ),
                          const SizedBox(width: 18),
                          const Flexible(
                            child: Text('Settings',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 28, fontWeight: FontWeight.w300)),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      iconSize: 38,
                      padding: const EdgeInsets.all(12),
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              TabBar(
                isScrollable: true,
                indicatorColor: _cyan,
                labelColor: _cyan,
                unselectedLabelColor: Colors.white60,
                labelStyle: const TextStyle(fontSize: 19),
                tabs: [for (final t in _tabNames) Tab(text: t)],
              ),
              Expanded(
                child: AnimatedBuilder(
                  animation: Listenable.merge([settings, model]),
                  builder: (context, _) => TabBarView(
                    children: [
                      _page(_general(context)),
                      _page(_visuals(context)),
                      _page(_launch(context)),
                      _page(_navigation(context)),
                      _page(_permissions(context)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _page(List<Widget> children) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
            children: children,
          ),
        ),
      );

  // ------------------------------------------------------------------ pages

  List<Widget> _general(BuildContext context) {
    final s = settings;
    return [
      _section('Online (needs an internet connection)'),
      _switch('Find missing album art',
          'Searches online when a player does not send a cover',
          s.artLookup, (v) => s.update(() => s.artLookup = v)),
      _switch('Synced lyrics',
          'Shows the current line as it is sung, when the song has lyrics',
          s.lyrics, (v) => s.update(() => s.lyrics = v)),
      _section('Offline media cache'),
      _action('Clear cached artwork and lyrics',
          'Delete downloaded artwork and synced lyrics stored on this device',
          'Clear Cache', () async { await MediaCache.clear(); }),
      _section('Screen care'),
      _choices(
        'Night mode',
        const ['Off', 'Auto (8pm to 6am)', 'Always on'],
        s.night,
        (i) => s.update(() => s.night = i),
      ),
      _switch('Burn-in protection',
          'Moves the layout a few pixels over time',
          s.burnIn, (v) => s.update(() => s.burnIn = v)),
      _section('Welcome'),
      _action(
        'Welcome tour',
        'Replay the explanation of each permission',
        'Replay',
        () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (ctx) => OnboardingScreen(
            settings: settings,
            onDone: () => Navigator.of(ctx).pop(),
          ),
        )),
      ),
    ];
  }

  List<Widget> _visuals(BuildContext context) {
    final s = settings;
    return [
      _section('Theme and color'),
      _choices(
        'Theme',
        AppSettings.pickable.map((i) => AppSettings.themeNames[i]).toList(),
        AppSettings.pickable.indexOf(s.theme).clamp(0, AppSettings.pickable.length - 1).toInt(),
        (i) => s.update(() => s.theme = AppSettings.pickable[i]),
      ),
      _choices(
        'Accent colors',
        AppSettings.accentNames,
        s.accent,
        (i) => s.update(() => s.accent = i),
      ),
      _switch('VHS effect uses vaporwave colors',
          'Pink and cyan instead of colors from the album art',
          s.vhsVaporwave, (v) => s.update(() => s.vhsVaporwave = v)),
      _section('Visualizer'),
      _switch('Show visualizer', 'Turn the bars and ring off completely',
          s.visualizer, (v) => s.update(() => s.visualizer = v)),
      _slider(
        'Sensitivity',
        '${(s.sensitivity * 100).round()}%',
        s.sensitivity,
        0.5,
        1.5,
        (v) => s.update(() => s.sensitivity = v, persist: false),
        s.save,
      ),
      _choices(
        'Style in the Focused theme',
        const ['Ring', 'Bars'],
        s.vizStyle,
        (i) => s.update(() => s.vizStyle = i),
      ),
      _slider(
        'Background contrast',
        '${(s.bgContrast * 100).round()}%',
        s.bgContrast,
        1.0,
        2.0,
        (v) => s.update(() => s.bgContrast = v, persist: false),
        s.save,
      ),
      _choices(
        'Number of bars',
        AppSettings.barCounts.map((e) => '$e').toList(),
        AppSettings.barCounts.indexOf(s.barCount),
        (i) => s.update(() => s.barCount = AppSettings.barCounts[i]),
      ),
      _section('Clock'),
      _switch('Show clock', 'Small clock placed separately for each theme and orientation',
          s.showClock, (v) => s.update(() => s.showClock = v)),
      _switch('24-hour time', 'Off uses 12-hour time with AM/PM',
          s.clock24h, (v) => s.update(() => s.clock24h = v)),
      _section('Background effects'),
      _slider('Background darkness', '${(s.bgOverlay * 100).round()}%', s.bgOverlay, 0.0, 2.0,
          (v) => s.update(() => s.bgOverlay = v, persist: false), () => s.save()),
      _action(
        'Background FX Library',
        'Visual previews, individual effects, intensity and quick presets',
        'Open library',
        () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => FxLibraryScreen(settings: settings),
        )),
      ),
      _switch('Performance mode',
          'For slower units: turns off the effects above, plus grain, glitch bands, drift and the animated idle background',
          s.performance, (v) => s.update(() => s.performance = v)),
    ];
  }

  List<Widget> _launch(BuildContext context) {
    final s = settings;
    return [
      _section('When VYBE opens by itself'),
      _switch('Open when the unit starts',
          'Some units have their own auto-start manager that must also allow this app',
          s.bootStart, (v) => s.update(() => s.bootStart = v)),
      _switch('Open when music starts',
          'Opens VYBE whenever you start or change a song. It does not open when a song simply ends and the next one plays on its own',
          s.musicStart, (v) => s.update(() => s.musicStart = v)),
      _choices(
        'After music has been paused, play opens VYBE again after',
        const ['Any pause', '15 seconds', '30 seconds', '1 minute'],
        const [0, 15, 30, 60].indexOf(s.graceSec).clamp(0, 3).toInt(),
        (i) => s.update(() => s.graceSec = const [0, 15, 30, 60][i]),
      ),
      _switch("Don't open while navigation is guiding",
          'Looks for the navigation notification, so VYBE never covers your map. Tapping a song yourself still counts, but the map wins while guiding',
          s.avoidNav, (v) => s.update(() => s.avoidNav = v)),
      _section('Which apps may open VYBE'),
      _switch('Also open for video apps',
          'Off by default: only music players open VYBE',
          s.allowVideo, (v) => s.update(() => s.allowVideo = v)),
      _switch('Also open for navigation audio',
          'Off by default: voice prompts from a map never open VYBE',
          s.allowNavAudio, (v) => s.update(() => s.allowNavAudio = v)),
      _action(
        'Players that may open VYBE',
        'Every player VYBE has seen, with a switch for each',
        'Manage',
        () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => const PlayersScreen(),
        )),
      ),
    ];
  }

  List<Widget> _navigation(BuildContext context) {
    final s = settings;
    return [
      _section('Drive: VYBE over your map'),
      const Padding(
        padding: EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: Text(
          'Choosing the Drive theme opens your navigation app and puts the '
          'fully themed VYBE screen in front of it, with a window in the '
          'middle where the live map shows. Tap the screen for controls: the '
          'map button hides VYBE so you can use the map, and the X goes back '
          'to normal VYBE.',
          style: TextStyle(fontSize: 15, color: Colors.white60, height: 1.4),
        ),
      ),
      _action(
        'Navigation app',
        s.navLabel.isEmpty
            ? 'Automatic: the first known navigation app found'
            : s.navLabel,
        'Choose',
        () => _pickNavApp(context),
      ),
      _switch('Swap sides',
          'Song info on the left and album art on the right',
          s.driveSwap, (v) => s.update(() => s.driveSwap = v)),
      _slider(
        'Map area width',
        '${(s.driveCardWidth * 100).round()}%',
        s.driveCardWidth,
        0.35,
        0.65,
        (v) => s.update(() => s.driveCardWidth = v, persist: false),
        s.save,
      ),
      _slider(
        'Visualizer height',
        '${(s.driveBarsH * 100).round()}%',
        s.driveBarsH,
        0.08,
        0.26,
        (v) => s.update(() => s.driveBarsH = v, persist: false),
        s.save,
      ),
      _switch('Return to VYBE button',
          'A labeled Return to VYBE edge tab over the map while VYBE is hidden. Tap to return; drag to move. Requires display-over-other-apps permission',
          s.driveBubble, (v) => s.update(() => s.driveBubble = v)),
      _switch('Show prev, play and next',
          'Buttons under the album art in the overlay',
          s.driveControls, (v) => s.update(() => s.driveControls = v)),
      _switch('Close Drive when guidance ends',
          'Removes the overlay shortly after your navigation app stops guiding',
          s.driveAutoClose, (v) => s.update(() => s.driveAutoClose = v)),
      _action(
        'Stop Drive',
        'Removes the overlay now. You can also tap the X on it',
        'Stop',
        () => Native.stopDrive(),
      ),
    ];
  }

  List<Widget> _permissions(BuildContext context) => [
        _section('Permissions and privacy'),
        const _PermissionsPanel(),
      ];

  /// A toggle with its own strength slider underneath while it is on.
  Widget _fx(String title, String sub, bool on, void Function(bool) setOn,
      double k, void Function(double) setK) {
    final s = settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _switch(title, sub, on, (v) => s.update(() => setOn(v))),
        if (on)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 8, 6),
            child: Row(
              children: [
                const Text('Intensity',
                    style: TextStyle(fontSize: 16, color: Colors.white60)),
                Expanded(
                  child: Slider(
                    value: k.clamp(0.0, 1.0).toDouble(),
                    activeColor: _cyan,
                    onChanged: (v) => s.update(() => setK(v), persist: false),
                    onChangeEnd: (_) => s.save(),
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text('${(k * 100).round()}%',
                      textAlign: TextAlign.end,
                      style:
                          const TextStyle(fontSize: 16, color: Colors.white70)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _action(
          String title, String sub, String button, VoidCallback onPressed) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 20)),
                  const SizedBox(height: 2),
                  Text(sub,
                      style: const TextStyle(
                          fontSize: 15, color: Colors.white60)),
                ],
              ),
            ),
            ElevatedButton(
              onPressed: onPressed,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                child: Text(button, style: const TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      );

  Future<void> _pickNavApp(BuildContext context) async {
    final apps = await Native.getInstalledApps();
    if (!context.mounted) return;
    final choice = await showDialog<AppInfo>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Navigation app'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, const AppInfo('', '')),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Automatic', style: TextStyle(fontSize: 20)),
            ),
          ),
          for (final a in apps)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, a),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(a.label, style: const TextStyle(fontSize: 20)),
              ),
            ),
        ],
      ),
    );
    if (choice == null) return;
    settings.update(() {
      settings.navPkg = choice.pkg;
      settings.navLabel = choice.label;
    });
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 28, 8, 6),
        child: Text(
          t.toUpperCase(),
          style: const TextStyle(fontSize: 14, letterSpacing: 2, color: _cyan),
        ),
      );

  Widget _switch(String title, String sub, bool value, ValueChanged<bool> on) =>
      SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        title: Text(title, style: const TextStyle(fontSize: 20)),
        subtitle: Text(sub,
            style: const TextStyle(fontSize: 15, color: Colors.white60)),
        value: value,
        onChanged: on,
      );

  Widget _slider(String title, String label, double value, double min,
          double max, ValueChanged<double> onChanged, VoidCallback onEnd) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(title, style: const TextStyle(fontSize: 20)),
                Text(label,
                    style:
                        const TextStyle(fontSize: 18, color: Colors.white70)),
              ],
            ),
            Slider(
              value: value.clamp(min, max).toDouble(),
              min: min,
              max: max,
              activeColor: _cyan,
              onChanged: onChanged,
              onChangeEnd: (_) => onEnd(),
            ),
          ],
        ),
      );

  Widget _choices(String title, List<String> labels, int selected,
          ValueChanged<int> onSelect) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 20)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: List<Widget>.generate(
                labels.length,
                (i) => ChoiceChip(
                  label: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Text(labels[i], style: const TextStyle(fontSize: 18)),
                  ),
                  selected: i == selected,
                  onSelected: (_) => onSelect(i),
                ),
              ),
            ),
          ],
        ),
      );
}

/// Live status of each permission, with a button to change it.
class _PermissionsPanel extends StatefulWidget {
  const _PermissionsPanel();

  @override
  State<_PermissionsPanel> createState() => _PermissionsPanelState();
}

class _PermissionsPanelState extends State<_PermissionsPanel>
    with WidgetsBindingObserver {
  Map<String, bool> _p = const {
    'notification': false,
    'audio': false,
    'overlay': false,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final r = await Native.permissionStatus();
    if (mounted) setState(() => _p = r);
  }

  Widget _row(String title, String why, bool on, String button,
      Future<void> Function() act) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(on ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: on ? Colors.greenAccent : Colors.white38),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title, style: const TextStyle(fontSize: 20)),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(36, 4, 0, 0),
            child: Text(why,
                style: const TextStyle(fontSize: 15, color: Colors.white60)),
          ),
          if (!on)
            Padding(
              padding: const EdgeInsets.fromLTRB(36, 8, 0, 0),
              child: ElevatedButton(
                onPressed: () async {
                  await act();
                  _refresh();
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  child: Text(button, style: const TextStyle(fontSize: 16)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _row(
          'Notification access',
          'Reads the title, artist, album and cover of what is playing. In '
              'Drive mode it also reads the text of your navigation '
              'notification to show turn-by-turn directions. Required.',
          _p['notification'] == true,
          'Open settings',
          Native.openAccessSettings,
        ),
        _row(
          'Audio access',
          'Only for the live visualizer. VYBE does not use the microphone or '
              'record anything.',
          _p['audio'] == true,
          'Allow',
          () async {
            await Native.requestAudio();
          },
        ),
        _row(
          'Display over other apps',
          'Lets VYBE open itself when you start music, and draw the Drive '
              'panels and the small "return to VYBE" button over your map. '
              'Nothing is drawn over other apps unless you start Drive.',
          _p['overlay'] == true,
          'Open settings',
          Native.openOverlaySettings,
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Text(
            'The internet is used only if album art search or lyrics are on, '
            'and sends just the song title and artist. Everything else stays '
            'on this device.',
            style: TextStyle(fontSize: 15, color: Colors.white54, height: 1.4),
          ),
        ),
      ],
    );
  }
}

/// Which players may open VYBE: Auto follows the rules, or force it.
class PlayersScreen extends StatefulWidget {
  const PlayersScreen({super.key});

  @override
  State<PlayersScreen> createState() => _PlayersScreenState();
}

class _PlayersScreenState extends State<PlayersScreen> {
  List<PlayerInfo>? _players;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Native.getPlayers();
    if (mounted) setState(() => _players = r);
  }

  Future<void> _set(PlayerInfo p, String mode) async {
    await Native.setPlayerOverride(p.pkg, mode);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final list = _players;
    return Scaffold(
      backgroundColor: const Color(0xFF05070D),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 12, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Players that may open VYBE',
                        style:
                            TextStyle(fontSize: 26, fontWeight: FontWeight.w300)),
                  ),
                  IconButton(
                    iconSize: 38,
                    padding: const EdgeInsets.all(12),
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: list == null
                      ? const Center(child: CircularProgressIndicator())
                      : list.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.all(32),
                              child: Text(
                                'No players seen yet. Start music in a player '
                                'app and it will appear here.',
                                style: TextStyle(
                                    fontSize: 19, color: Colors.white70),
                              ),
                            )
                          : ListView(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                              children: [
                                const Padding(
                                  padding: EdgeInsets.fromLTRB(8, 4, 8, 8),
                                  child: Text(
                                    'Auto lets music players open VYBE and keeps '
                                    'video and navigation apps out. Allow or '
                                    'Block overrides that for one app.',
                                    style: TextStyle(
                                        fontSize: 15, color: Colors.white60),
                                  ),
                                ),
                                for (final p in list) _playerRow(p),
                              ],
                            ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _playerRow(PlayerInfo p) {
    const modes = ['auto', 'allow', 'block'];
    const names = ['Auto', 'Allow', 'Block'];
    final sel = modes.indexOf(p.override).clamp(0, 2).toInt();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(p.label, style: const TextStyle(fontSize: 20)),
          const SizedBox(height: 2),
          Text(
            p.kindLabel + (p.allowed ? ' · can open VYBE' : ' · will not open VYBE'),
            style: TextStyle(
                fontSize: 15,
                color: p.allowed ? Colors.greenAccent : Colors.white54),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            children: List<Widget>.generate(
              3,
              (i) => ChoiceChip(
                label: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Text(names[i], style: const TextStyle(fontSize: 17)),
                ),
                selected: i == sel,
                onSelected: (_) => _set(p, modes[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
