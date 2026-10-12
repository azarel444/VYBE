import 'package:flutter/material.dart';
import 'now_playing_model.dart';
import 'palette.dart';
import 'settings.dart';

/// Screenshot-based theme library. Thumbnails show captures of the actual
/// layouts, never approximate/recreate their appearance with separate painters.
/// The live Now Playing theme implementations are not modified by this dialog.
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
  int? _preview;

  static const Map<int, String> _assetNames = {
    0: 'focused',
    1: 'side_by_side',
    3: 'edge_to_edge',
    4: 'drive',
    5: 'fan',
    6: 'diagonal',
    7: 'record_cut',
    8: 'typo',
    9: 'orbit',
  };

  String _imagePath(int id, bool portrait) =>
      'assets/theme_previews/${_assetNames[id]}_${portrait ? 'portrait' : 'landscape'}.jpg';

  void _apply(int id) {
    widget.settings.update(() => widget.settings.theme = id);
    Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final portrait = size.height > size.width;
    final accent = widget.palette.a;
    final ids = AppSettings.pickable;
    final maxWidth = portrait ? 640.0 : 1100.0;

    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      backgroundColor: const Color(0xFF101019),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: 900),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 8, 8),
            child: Row(children: [
              Icon(Icons.grid_view_rounded, color: accent),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('THEME LIBRARY',
                    style: TextStyle(fontSize: 19, letterSpacing: 2,
                        fontWeight: FontWeight.w600)),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close theme library',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ]),
          ),
          Expanded(
            child: _preview == null
                ? GridView.builder(
                    key: const ValueKey('theme-grid'),
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 18),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: portrait ? 2 : 3,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      // Landscape screenshots should be shown in landscape
                      // cards, and portrait screenshots in portrait cards.
                      childAspectRatio: portrait ? 0.78 : 1.48,
                    ),
                    itemCount: ids.length,
                    itemBuilder: (context, index) {
                      final id = ids[index];
                      final active = widget.settings.theme == id;
                      return Material(
                        color: const Color(0xFF1B1B29),
                        borderRadius: BorderRadius.circular(14),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => setState(() => _preview = id),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: active ? accent : Colors.white24,
                                width: active ? 2 : 1,
                              ),
                            ),
                            child: Column(children: [
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.all(3),
                                  child: Image.asset(
                                    _imagePath(id, portrait),
                                    fit: BoxFit.contain,
                                    width: double.infinity,
                                    height: double.infinity,
                                    filterQuality: FilterQuality.medium,
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                                child: Row(children: [
                                  Expanded(
                                    child: Text(
                                      AppSettings.themeNames[id],
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                  Icon(
                                    active ? Icons.check_circle : Icons.zoom_out_map,
                                    size: 17,
                                    color: active ? accent : Colors.white54,
                                  ),
                                ]),
                              ),
                            ]),
                          ),
                        ),
                      );
                    },
                  )
                : Column(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Row(children: [
                        IconButton(
                          onPressed: () => setState(() => _preview = null),
                          icon: const Icon(Icons.arrow_back),
                          tooltip: 'Back to all themes',
                        ),
                        Expanded(
                          child: Text(
                            AppSettings.themeNames[_preview!],
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ]),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: Image.asset(
                          _imagePath(_preview!, portrait),
                          fit: BoxFit.contain,
                          width: double.infinity,
                          height: double.infinity,
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                    ),
                  ]),
          ),
          if (_preview != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Colors.white24)),
              ),
              child: Row(children: [
                const Expanded(
                  child: Text('Actual theme screenshot',
                      style: TextStyle(fontSize: 12, color: Colors.white60)),
                ),
                TextButton(
                  onPressed: () => setState(() => _preview = null),
                  child: const Text('Back'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () => _apply(_preview!),
                  child: const Text('Apply theme'),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}
