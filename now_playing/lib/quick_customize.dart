import 'package:flutter/material.dart';

import 'settings.dart';

/// Opens only from the floating Customize button. The host bottom-sheet route
/// supplies the upward entrance/exit animation; no persistent pull handle.
class QuickCustomizeSheet extends StatefulWidget {
  final AppSettings settings;
  final Color accent;
  final VoidCallback onOpenFx;

  const QuickCustomizeSheet({
    super.key,
    required this.settings,
    required this.accent,
    required this.onOpenFx,
  });

  @override
  State<QuickCustomizeSheet> createState() => _QuickCustomizeSheetState();
}

class _QuickCustomizeSheetState extends State<QuickCustomizeSheet> {
  AppSettings get s => widget.settings;
  // Some album palettes are almost black; keep slider tracks and selected
  // chips visible without abandoning the artwork-derived accent.
  Color get _controlAccent =>
      Color.lerp(widget.accent, Colors.white, .52)!;

  bool get _fanartTheme =>
      s.theme == AppSettings.tCinematic || s.theme == AppSettings.tEditorial;

  int get _backgroundChoice {
    if (_fanartTheme) {
      if (!s.fanartOverride) return 0; // Artist photos first
      return s.fanartFallbackSource == 1 ? 2 : 1;
    }
    return s.backgroundSource == 6 ? 0
        : s.backgroundSource == 0 ? 1 : 2;
  }

  bool get _usingFanart => _backgroundChoice == 0;

  @override
  void initState() {
    super.initState();
    s.addListener(_refresh);
  }

  @override
  void dispose() {
    s.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _chooseBackground(int choice) {
    s.update(() {
      if (_fanartTheme) {
        s.fanartOverride = choice != 0;
        if (choice != 0) s.fanartFallbackSource = choice == 2 ? 1 : 0;
      } else {
        s.backgroundSource = choice == 0 ? 6 : choice == 1 ? 0 : 1;
        s.fanartMode = choice == 0 ? 1 : 0;
      }
    });
  }

  Widget _compactSlider(String label, double value, double min, double max,
      String valueLabel, ValueChanged<double> change) {
    return SizedBox(
      height: 47,
      child: Row(children: [
        SizedBox(width: 78, child: Text(label, maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: Colors.white))),
        Expanded(child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
          ),
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            activeColor: _controlAccent,
            inactiveColor: Colors.white24,
            onChanged: (v) => s.update(() => change(v), persist: false),
            onChangeEnd: (_) => s.save(),
          ),
        )),
        SizedBox(width: 43, child: Text(valueLabel, textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12, color: Colors.white70))),
      ]),
    );
  }

  Widget _sourceChip(int index, String label) {
    final selected = _backgroundChoice == index;
    return ChoiceChip(
      label: Text(label, style: TextStyle(
          fontSize: 13, color: selected ? Colors.black : Colors.white)),
      selected: selected,
      showCheckmark: false,
      selectedColor: _controlAccent,
      backgroundColor: const Color(0xFF242833),
      side: const BorderSide(color: Colors.white24),
      visualDensity: VisualDensity.compact,
      onSelected: (_) => _chooseBackground(index),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fanartPhotoControls = _fanartTheme || _usingFanart;
    final blur = _fanartTheme ? s.cinematicBlur
        : _usingFanart ? (s.bgBlur - 6).clamp(0.0, 12.0).toDouble() : s.bgBlur;
    final blurMax = _usingFanart && !_fanartTheme ? 12.0 : 18.0;
    final contrast = _fanartTheme ? s.cinematicContrast : s.bgContrast;

    final sliders = <Widget>[
      _compactSlider('Darkness', s.bgOverlay, 0, 1,
        (s.bgOverlay * 100).round().toString() + '%',
        (v) => s.bgOverlay = v),
      _compactSlider('Blur', blur, 0, blurMax, blur.round().toString(),
        (v) {
          if (_fanartTheme) {
            s.cinematicBlur = v;
          } else if (_usingFanart) {
            s.bgBlur = v + 6;
          } else {
            s.bgBlur = v;
          }
        }),
      _compactSlider('Contrast', contrast, 1, 2,
        (contrast * 100).round().toString() + '%',
        (v) {
          if (_fanartTheme) {
            s.cinematicContrast = v;
          } else {
            s.bgContrast = v;
          }
        }),
      _compactSlider('Logo size', s.artistLogoScale, .5, 2,
        (s.artistLogoScale * 100).round().toString() + '%',
        (v) => s.artistLogoScale = v),
      if (fanartPhotoControls)
        _compactSlider('Fanart dim', s.cinematicDarkness, 0, 1,
          (s.cinematicDarkness * 100).round().toString() + '%',
          (v) => s.cinematicDarkness = v),
    ];

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xEB11141D),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: const Color(0x45FFFFFF), width: .7),
          boxShadow: const [
            BoxShadow(
              color: Color(0xB8000000),
              blurRadius: 26, spreadRadius: 2, offset: Offset(0, -9)),
            BoxShadow(
              color: Color(0x77000000),
              blurRadius: 20, offset: Offset(0, 12)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Same neon gradient as the controls bar, but floating
            // inside a softly rounded translucent card.
            Container(height: 3,
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [
                  Color(0xFFFF27A8), Color(0xFF995CFF),
                  Color(0xFF05E2F3)]))),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .72),
              child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Icon(Icons.tune_rounded, color: _controlAccent, size: 22),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('Quick Customize',
                      style: TextStyle(fontSize: 19,
                        fontWeight: FontWeight.w700))),
                    IconButton(
                      tooltip: 'Close customization',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ]),
                  Text('This theme: ' + AppSettings.themeNames[s.theme],
                    style: const TextStyle(
                      color: Colors.white60, fontSize: 12)),
                  const SizedBox(height: 8),
                  Row(children: [
                    const Text('Background', style: TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13)),
                    const SizedBox(width: 10),
                    Expanded(child: Wrap(alignment: WrapAlignment.end,
                      spacing: 6, runSpacing: 0, children: [
                        _sourceChip(0, 'Fanart'),
                        _sourceChip(1, 'Album'),
                        _sourceChip(2, 'Animated'),
                      ])),
                  ]),
                  const SizedBox(height: 5),
                  LayoutBuilder(builder: (context, bounds) {
                    final twoColumns = bounds.maxWidth >= 570;
                    final cellWidth = twoColumns
                        ? (bounds.maxWidth - 10) / 2
                        : bounds.maxWidth;
                    return Wrap(spacing: 10, runSpacing: 0,
                      children: [
                        for (final slider in sliders)
                          SizedBox(width: cellWidth, child: slider),
                      ],
                    );
                  }),
                  const Divider(height: 14, color: Colors.white24),
                  Wrap(spacing: 10, runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilterChip(
                        label: const Text('Clearlogo'),
                        selected: s.useArtistClearLogo,
                        onSelected: (v) =>
                            s.update(() => s.useArtistClearLogo = v),
                        visualDensity: VisualDensity.compact),
                      FilterChip(
                        label: const Text('VYBE palette'),
                        selected: s.useVybePalette,
                        onSelected: (v) =>
                            s.update(() => s.useVybePalette = v),
                        visualDensity: VisualDensity.compact),
                      FilterChip(
                        label: const Text('Motion'),
                        selected: s.bgEffects,
                        onSelected: (v) =>
                            s.update(() => s.bgEffects = v),
                        visualDensity: VisualDensity.compact),
                      OutlinedButton.icon(
                        onPressed: widget.onOpenFx,
                        icon: const Icon(Icons.auto_awesome, size: 17),
                        label: const Text('FX Gallery'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
          ],
        ),
      ),
    ),
  );
  }
}
