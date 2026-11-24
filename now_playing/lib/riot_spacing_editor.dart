import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'riot_spacing_store.dart';

/// Edits the *actual* VYBE optical pair renderer, not TTF glyph bearings.
/// The host provides its real _artistText renderer so previews and themes
/// share all measured advances, enlarged initials, slant and baseline.
class RiotSpacingEditor extends StatefulWidget {
  final Widget Function(String text, double baseSize) previewBuilder;
  final String initialText;

  const RiotSpacingEditor({
    super.key,
    required this.previewBuilder,
    required this.initialText,
  });

  @override
  State<RiotSpacingEditor> createState() => _RiotSpacingEditorState();
}

class _RiotSpacingEditorState extends State<RiotSpacingEditor> {
  final RiotSpacingStore store = RiotSpacingStore.instance;
  late final TextEditingController _text;
  String _selectedPair = '';
  String _selectedGlyph = '.';
  late final TextEditingController _pairText;
  late final TextEditingController _glyphText;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialText.trim().isEmpty
        ? 'MORRISSEY' : widget.initialText.trim();
    _text = TextEditingController(text: initial.toUpperCase());
    store.addListener(_refresh);
    _selectedPair = _visiblePairs.isNotEmpty ? _visiblePairs.first : '';
    _pairText = TextEditingController(text: _selectedPair);
    _glyphText = TextEditingController(text: _selectedGlyph);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    store.removeListener(_refresh);
    _text.dispose();
    _pairText.dispose();
    _glyphText.dispose();
    unawaited(store.saveNow());
    super.dispose();
  }


  // Includes letters, digits, punctuation, symbols, accented characters
  // and any other printable Unicode glyph; spaces break adjacent pairs.
  List<String> get _visiblePairs {
    final found = <String>{};
    var previous = '';
    for (final rune in _text.text.toUpperCase().runes) {
      final current = String.fromCharCode(rune);
      if (!RiotSpacingStore.isGlyph(current)) {
        previous = '';
        continue;
      }
      if (previous.isNotEmpty) found.add(previous + current);
      previous = current;
    }
    return found.toList();
  }

  List<String> get _visibleGlyphs {
    final found = <String>{};
    for (final rune in _text.text.toUpperCase().runes) {
      final glyph = String.fromCharCode(rune);
      if (RiotSpacingStore.isGlyph(glyph)) found.add(glyph);
    }
    return found.toList();
  }

  void _selectPair(String pair) {
    if (!RiotSpacingStore.isPair(pair)) return;
    setState(() => _selectedPair = pair.toUpperCase());
    _pairText.text = pair.toUpperCase();
  }

  void _selectGlyph(String glyph) {
    if (!RiotSpacingStore.isGlyph(glyph)) return;
    setState(() => _selectedGlyph = glyph.toUpperCase());
    _glyphText.text = glyph.toUpperCase();
  }

  void _updateText(String value) {
    final pairs = _visiblePairs;
    if (!pairs.contains(_selectedPair) && pairs.isNotEmpty) {
      _selectPair(pairs.first);
    } else {
      setState(() {});
    }
  }

  void _example(String value) {
    _text.text = value;
    _text.selection = TextSelection.collapsed(offset: value.length);
    _updateText(value);
  }

  Widget _adjust(String label, double value, ValueChanged<double> change,
      String directions) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 15))),
        Text(value.abs() < .005 ? 'Original' :
          (value > 0 ? '+' : '') + value.toStringAsFixed(2) + ' em',
          style: const TextStyle(color: Colors.white70)),
      ]),
      Slider(value: value.clamp(-.60, .60).toDouble(),
        min: -.60, max: .60, divisions: 120,
        label: value.toStringAsFixed(2) + ' em',
        onChanged: change,
        onChangeEnd: (_) => unawaited(store.saveNow())),
      Text(directions, style: const TextStyle(
        color: Colors.white54, fontSize: 12)),
      const SizedBox(height: 11),
    ],
  );

  void _announce(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message),
          duration: const Duration(seconds: 3)));
  }

  Future<void> _copyAdjustments() async {
    await Clipboard.setData(ClipboardData(text: store.exportJson()));
    _announce('Riot spacing JSON copied. Save it before uninstalling VYBE.');
  }

  Future<void> _restoreAdjustments() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboard?.text;
    if (text == null || text.trim().isEmpty) {
      _announce('Clipboard is empty. Copy exported Riot spacing JSON first.');
      return;
    }
    try {
      store.importJson(text);
      _announce('Imported saved Riot spacing adjustments.');
    } catch (e) {
      _announce('Cannot import spacing settings: ' + e.toString());
    }
  }

  Future<void> _resetAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset all Riot spacing corrections?'),
        content: const Text('All custom pair and individual glyph adjustments will be removed. '
            'The original VYBE kerning stays unchanged. Export JSON '
            'first if you want to keep a backup.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset all')),
        ],
      ),
    );
    if (confirm == true) store.resetAll();
  }

  @override
  Widget build(BuildContext context) {
    final pairs = _visiblePairs;
    final pair = RiotSpacingStore.isPair(_selectedPair)
        ? _selectedPair : (pairs.isNotEmpty ? pairs.first : '');

    return Scaffold(
      backgroundColor: const Color(0xFF11121A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF191923),
        title: const Text('Riot Spacing Editor'),
        actions: [
          IconButton(tooltip: 'Export adjustments',
              onPressed: _copyAdjustments,
              icon: const Icon(Icons.file_upload_outlined)),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('Edit any Riot letter, number, punctuation mark or symbol. '
                    'Choose adjacent pairs or shift an individual character. '
                    'This uses the live VYBE renderer in every theme and saves '
                    'automatically without modifying the original font file.',
                  style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 12),
                TextField(
                  controller: _text,
                  maxLines: 1,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: _updateText,
                  decoration: const InputDecoration(
                    labelText: 'Artist name to preview',
                    hintText: 'DAFT PUNK 2.0, VOL. 3',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.edit),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  height: 164,
                  width: double.infinity,
                  clipBehavior: Clip.hardEdge,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF05050B), Color(0xFF261322)],
                    ),
                    border: Border.all(color: Colors.white24),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Center(
                      child: widget.previewBuilder(
                        _text.text.toUpperCase(), 35.0,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const Text('Preview uses the same custom VYBE positioning, '
                    'word initials and slant. Scroll horizontally for '
                    'long artist names.',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 17),

                Wrap(spacing: 8, runSpacing: 3, children: [
                  ActionChip(label: const Text('Numbers 0123456789'),
                    onPressed: () => _example('MUSIC 2026 123.45')),
                  ActionChip(label: const Text('Punctuation'),
                    onPressed: () => _example("A.B, C!D? 9:30; 12/24")),
                  ActionChip(label: const Text('Symbols'),
                    onPressed: () => _example('AC/DC + A&B @# \$% * (2) - _')),
                ]),
                const Divider(height: 30),
                const Text('1. Adjust adjacent character pairs',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                const Text('Pairs include letters, numbers, and punctuation. '
                  'Choose a pair from the preview or type ANY two adjacent '
                  'characters below. Spaces do not use pair kerning.',
                  style: TextStyle(color: Colors.white60, fontSize: 12)),
                const SizedBox(height: 8),
                if (pairs.isNotEmpty)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      for (final current in pairs)
                        Padding(padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(label: Text(current),
                            selected: current == pair,
                            onSelected: (_) => _selectPair(current))),
                    ]),
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: _pairText,
                  maxLines: 1,
                  decoration: const InputDecoration(
                    labelText: 'Edit any exact pair (e.g. A. or .B or 23)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) {
                    if (RiotSpacingStore.isPair(v.toUpperCase())) {
                      setState(() => _selectedPair = v.toUpperCase());
                    }
                  },
                ),
                const SizedBox(height: 12),
                if (pair.isNotEmpty) ...[
                  _adjust('Pair ' + pair + ' spacing',
                    store.deltaFor(pair), (v) => store.setPair(pair, v),
                    'Left = closer / more overlap   •   Right = farther apart'),
                  OutlinedButton.icon(
                    onPressed: () => store.resetPair(pair),
                    icon: const Icon(Icons.restore),
                    label: const Text('Reset selected pair'),
                  ),
                ],
                const Divider(height: 30),
                const Text('2. Adjust individual character placement',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                const Text('Move punctuation out from under other letters, '
                  'raise or lower its baseline, and correct the spacing '
                  'following a digit or symbol.',
                  style: TextStyle(color: Colors.white60, fontSize: 12)),
                const SizedBox(height: 8),
                SingleChildScrollView(scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final glyph in <String>{
                      ..._visibleGlyphs,
                      ...'0123456789.,:;!?@#\$%&*()-+/_'.runes
                        .map(String.fromCharCode),
                    })
                      Padding(padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(label: Text(glyph),
                          selected: glyph == _selectedGlyph,
                          onSelected: (_) => _selectGlyph(glyph))),
                  ]),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _glyphText,
                  maxLines: 1,
                  decoration: const InputDecoration(
                    labelText: 'Edit any single character or Unicode symbol',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) {
                    if (RiotSpacingStore.isGlyph(v.toUpperCase())) {
                      setState(() => _selectedGlyph = v.toUpperCase());
                    }
                  },
                ),
                const SizedBox(height: 12),
                if (RiotSpacingStore.isGlyph(_selectedGlyph)) ...[
                  _adjust('Horizontal position: ' + _selectedGlyph,
                    store.xFor(_selectedGlyph),
                    (v) => store.setHorizontal(_selectedGlyph, v),
                    'Left = move glyph left   •   Right = move glyph right'),
                  _adjust('Vertical position: ' + _selectedGlyph,
                    store.yFor(_selectedGlyph),
                    (v) => store.setVertical(_selectedGlyph, v),
                    'Left = raise glyph   •   Right = lower glyph'),
                  _adjust('Spacing AFTER: ' + _selectedGlyph,
                    store.afterFor(_selectedGlyph),
                    (v) => store.setAfter(_selectedGlyph, v),
                    'Left = next glyph closer   •   Right = next glyph farther'),
                  OutlinedButton.icon(
                    onPressed: () => store.resetGlyph(_selectedGlyph),
                    icon: const Icon(Icons.restore),
                    label: const Text('Reset selected character'),
                  ),
                ],
                const Divider(height: 30),
                Wrap(spacing: 12, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    onPressed: _copyAdjustments,
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy all adjustments'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _restoreAdjustments,
                    icon: const Icon(Icons.paste),
                    label: const Text('Import from clipboard'),
                  ),
                  TextButton.icon(
                    onPressed: _resetAll,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Reset all'),
                  ),
                ]),
                Text((store.pairs.length + store.horizontal.length +
                      store.vertical.length + store.after.length) == 0
                    ? 'No custom corrections saved yet.'
                    : '${store.pairs.length} pair corrections, '
                      '${store.horizontal.length + store.vertical.length + store.after.length} '
                      'character adjustments saved on this device.',
                  style: const TextStyle(color: Colors.white60,
                      fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
