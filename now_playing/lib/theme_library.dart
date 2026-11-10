import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'now_playing_model.dart';
import 'palette.dart';
import 'settings.dart';

/// Premium VYBE theme gallery. All previews remain screenshots captured from
/// the real themes; this changes ONLY theme selection, not theme rendering.
class ThemeLibrary extends StatefulWidget {
  final NowPlayingModel model;
  final AppSettings settings;
  final ArtPalette palette;

  const ThemeLibrary({
    super.key,
    required this.model,
    required this.settings,
    required this.palette,
  });

  @override
  State<ThemeLibrary> createState() => _ThemeLibraryState();
}

class _ThemeLibraryState extends State<ThemeLibrary> {
  static const _pink = Color(0xFFFF005E);
  static const _purple = Color(0xFF9C54FF);
  static const _cyan = Color(0xFF05E2F3);
  static const _surface = Color(0xFF171621);

  static const _brandGradient = LinearGradient(
    colors: [_pink, _purple, _cyan],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  int? _preview;
  bool? _previewPortrait;
  int? _focusedStyleChoice;
  bool _applying = false;

  String _imagePath(int id, bool portrait) =>
      'assets/theme_previews/${AppSettings.themePreviewAssets[id]}_${portrait ? 'portrait' : 'landscape'}.jpg';

  void _openPreview(int id) {
    final size = MediaQuery.sizeOf(context);
    final portrait = size.height > size.width * 1.1;
    setState(() {
      _preview = id;
      _previewPortrait = portrait;
      // Preserve the current orientation-specific Focused style choice.
      _focusedStyleChoice = widget.settings.focusedStyleFor(portrait);
    });
  }

  Future<void> _apply(int id) async {
    if (_applying) return;
    setState(() => _applying = true);
    // Do not change the working theme-selection and Drive save sequence.
    widget.settings.update(() {
      widget.settings.theme = id;
      if (id == 0) {
        final choice = _focusedStyleChoice ?? 0;
        widget.settings.vizStyle = choice;
        widget.settings.focusedPortraitStyle = choice;
        widget.settings.focusedLandscapeStyle = choice;
        widget.settings.visualizer = true;
      }
    }, persist: false);
    try {
      await widget.settings.saveTheme();
      if (id == 0) await widget.settings.saveFocusedStyle();
      if (mounted) Navigator.of(context).pop(id);
    } catch (error) {
      debugPrint('VYBE theme/profile save failed: $error');
      if (!mounted) return;
      setState(() => _applying = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not save this theme. Please try again.'),
      ));
    }
  }

  Widget _brandDivider() => const SizedBox(
    height: 3,
    width: double.infinity,
    child: DecoratedBox(decoration: BoxDecoration(gradient: _brandGradient)),
  );

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 11, 10, 10),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: const Color(0xFF281524),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: _pink.withOpacity(.45)),
          ),
          child: SvgPicture.asset('assets/vybe_edgy_icon.svg'),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('THEME COLLECTION',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w800,
                  letterSpacing: 1.8, color: Colors.white)),
              SizedBox(height: 3),
              Text('MAKE THE MUSIC YOURS',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w600,
                  color: Color(0xFFB7A9C9), letterSpacing: 1.9)),
            ],
          ),
        ),
        IconButton(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: const Icon(Icons.close_rounded, size: 26),
          color: Colors.white70,
          tooltip: 'Close theme collection',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ]),
    );
  }

  Widget _themeTile(int id, bool portrait) {
    final selected = widget.settings.theme == id;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openPreview(id),
        splashColor: _pink.withOpacity(.19),
        highlightColor: _purple.withOpacity(.12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? _pink : const Color(0xFF3A3548),
              width: selected ? 2.0 : 1.0,
            ),
            boxShadow: selected ? [
              BoxShadow(
                color: _pink.withOpacity(.28),
                blurRadius: 18, spreadRadius: 1,
              ),
            ] : null,
          ),
          child: Column(children: [
            Expanded(
              child: Stack(fit: StackFit.expand, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 6, 6, 3),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: ColoredBox(
                      color: const Color(0xFF0C0B12),
                      child: Image.asset(
                        _imagePath(id, portrait),
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                        width: double.infinity,
                        height: double.infinity,
                      ),
                    ),
                  ),
                ),
                if (selected)
                  Positioned(
                    right: 11, top: 11,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xF20D0916),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: _pink.withOpacity(.7)),
                      ),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.check_rounded, color: _cyan, size: 12),
                        SizedBox(width: 4),
                        Text('ACTIVE', style: TextStyle(
                            fontSize: 9, letterSpacing: 1.1,
                            fontWeight: FontWeight.w800, color: Colors.white)),
                      ]),
                    ),
                  ),
              ]),
            ),
            Container(
              height: 3,
              decoration: BoxDecoration(
                gradient: selected ? _brandGradient : const LinearGradient(
                  colors: [Color(0xFF373044), Color(0xFF282432)],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
              child: Row(children: [
                Expanded(
                  child: Text(
                    AppSettings.themeNames[id].toUpperCase(),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12, letterSpacing: .65,
                      fontWeight: FontWeight.w800,
                      color: selected ? Colors.white : const Color(0xFFE4DFEC),
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Icon(
                  selected ? Icons.check_circle_rounded : Icons.open_in_full_rounded,
                  size: 17, color: selected ? _cyan : Colors.white54,
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _gallery(bool portrait) {
    return LayoutBuilder(builder: (context, constraints) {
      // Large enough for ATOTO touch targets, and still two-up on a phone.
      final columns = constraints.maxWidth < 720 ? 2 : 3;
      return GridView.builder(
        key: const ValueKey('vybe-theme-gallery'),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 15,
          crossAxisSpacing: 15,
          childAspectRatio: portrait ? .77 : 1.48,
        ),
        itemCount: AppSettings.pickable.length,
        itemBuilder: (context, index) =>
          _themeTile(AppSettings.pickable[index], portrait),
      );
    });
  }

  Widget _optionRow(String label, Widget choice) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 1, 16, 9),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 5,
        children: [
          Text(label, style: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600,
            color: Color(0xFFE9E0F1))),
          choice,
        ],
      ),
    );
  }

  Widget _selectedPreview(bool portrait) {
    final id = _preview!;
    final screenshotPortrait = _previewPortrait ?? portrait;
    final active = widget.settings.theme == id;
    final screenshot = _imagePath(id, screenshotPortrait);

    return Column(
      key: ValueKey('vybe-preview-$id'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 16, 8),
          child: Row(children: [
            IconButton(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: () => setState(() => _preview = null),
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: 'Back to theme gallery',
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(AppSettings.themeNames[id].toUpperCase(),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18, letterSpacing: 1.2,
                        fontWeight: FontWeight.w800)),
                  Text(active ? 'CURRENT THEME' : 'THEME PREVIEW',
                    style: const TextStyle(
                      color: _cyan, fontSize: 10, letterSpacing: 1.3,
                      fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ]),
        ),
        _optionRow('Preview orientation',
          SegmentedButton<bool>(
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              foregroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.selected) ? Colors.white : Colors.white70),
              backgroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.selected)
                      ? const Color(0xFF822654)
                      : const Color(0xFF252232)),
            ),
            segments: const [
              ButtonSegment<bool>(value: true, icon: Icon(Icons.smartphone, size: 16),
                  label: Text('Portrait')),
              ButtonSegment<bool>(value: false, icon: Icon(Icons.desktop_windows_rounded, size: 16),
                  label: Text('Landscape')),
            ],
            selected: {screenshotPortrait},
            onSelectionChanged: (values) => setState(
              () => _previewPortrait = values.first),
          ),
        ),
        if (id == 4)
          _optionRow('Drive artwork style',
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment<bool>(value: true, label: Text('Square')),
                ButtonSegment<bool>(value: false, label: Text('Record')),
              ],
              selected: {widget.settings.driveAlbumCover},
              onSelectionChanged: (choice) {
                widget.settings.update(
                  () => widget.settings.driveAlbumCover = choice.first);
                setState(() {});
              },
            ),
          ),
        if (id == 0)
          _optionRow('Visualizer style',
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment<int>(value: 0, label: Text('Circle')),
                ButtonSegment<int>(value: 1, label: Text('Bars')),
              ],
              selected: {_focusedStyleChoice ??
                  widget.settings.focusedStyleFor(portrait)},
              onSelectionChanged: (choice) => setState(
                () => _focusedStyleChoice = choice.first),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 1, 16, 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF0B0A12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF4A354F)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(9),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: Image.asset(
                      screenshot,
                      key: ValueKey(screenshot),
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                      width: double.infinity, height: double.infinity,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _previewFooter() {
    final id = _preview!;
    final active = widget.settings.theme == id;
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF191320),
        border: Border(top: BorderSide(color: Color(0xFF483249))),
      ),
      padding: const EdgeInsets.fromLTRB(17, 10, 17, 12),
      child: Row(children: [
        Expanded(
          child: Text(
            active ? 'CURRENTLY SELECTED' : 'READY TO APPLY',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, letterSpacing: 1.1,
                fontWeight: FontWeight.w700, color: Color(0xFFC7AFD1)),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: _applying ? null : () => _apply(id),
          style: FilledButton.styleFrom(
            minimumSize: const Size(148, 50),
            backgroundColor: _pink,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(11)),
            textStyle: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w800),
          ),
          icon: Icon(_applying
              ? Icons.hourglass_top_rounded : Icons.check_rounded, size: 20),
          label: Text(_applying ? 'Applying...' : 'Apply theme'),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final portrait = viewport.height > viewport.width;
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: portrait ? 10 : 18, vertical: 12),
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: SizedBox(
        width: portrait ? 680 : 1100,
        height: math.min(viewport.height * .92, 860),
        child: Material(
          color: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          borderRadius: BorderRadius.circular(21),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [Color(0xFF101018), Color(0xFF1F1425)]),
              borderRadius: BorderRadius.circular(21),
              border: Border.all(color: const Color(0xFF4C2C4D)),
              boxShadow: const [
                BoxShadow(color: Color(0xD9000000), blurRadius: 30,
                    spreadRadius: 8),
              ],
            ),
            child: Column(children: [
              _brandDivider(),
              _header(),
              const Divider(height: 1, color: Color(0xFF38283D)),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 290),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(.035, 0), end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: _preview == null
                      ? KeyedSubtree(
                          key: const ValueKey('gallery'),
                          child: _gallery(portrait),
                        )
                      : _selectedPreview(portrait),
                ),
              ),
              if (_preview != null) _previewFooter(),
            ]),
          ),
        ),
      ),
    );
  }
}
