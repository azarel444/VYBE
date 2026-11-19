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

  @override
  void initState() {
    super.initState();
    final initial = widget.initialText.trim().isEmpty
        ? 'MORRISSEY' : widget.initialText.trim();
    _text = TextEditingController(text: initial.toUpperCase());
    store.addListener(_refresh);
    _selectedPair = _visiblePairs.isNotEmpty ? _visiblePairs.first : '';
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    store.removeListener(_refresh);
    _text.dispose();
    super.dispose();
  }

  List<String> get _visiblePairs {
    final letters = _text.text.toUpperCase().runes.map(
        (rune) => String.fromCharCode(rune));
    final found = <String>{};
    var previous = '';
    for (final c in letters) {
      if (!RegExp(r'^[A-Z]$').hasMatch(c)) {
        previous = '';
        continue;
      }
      if (previous.isNotEmpty) found.add(previous + c);
      previous = c;
    }
    return found.toList(growable: false);
  }

  void _updateText(String value) {
    final pairs = _visiblePairs;
    setState(() {
      if (!pairs.contains(_selectedPair)) {
        _selectedPair = pairs.isNotEmpty ? pairs.first : '';
      }
    });
  }

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
        title: const Text('Reset every Riot spacing correction?'),
        content: const Text('All custom pair adjustments will be removed. '
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
    final pair = pairs.contains(_selectedPair)
        ? _selectedPair : (pairs.isNotEmpty ? pairs.first : '');
    final value = pair.isNotEmpty ? store.deltaFor(pair) : 0.0;

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
                const Text('Adjust how letters touch in the real Riot font '
                    'renderer. The same pair correction updates every '
                    'theme and artist name. Changes save automatically.',
                  style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 12),
                TextField(
                  controller: _text,
                  maxLines: 1,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: _updateText,
                  decoration: const InputDecoration(
                    labelText: 'Artist name to preview',
                    hintText: 'MORRISSEY',
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
                const Text('Tap the letter pair to correct',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 9),
                if (pairs.isEmpty)
                  const Text('Enter at least two adjacent letters.',
                    style: TextStyle(color: Colors.white60))
                else
                  Wrap(spacing: 7, runSpacing: 3, children: [
                    for (final current in pairs)
                      ChoiceChip(
                        label: Text(current),
                        selected: current == pair,
                        onSelected: (_) =>
                            setState(() => _selectedPair = current),
                      ),
                  ]),
                const SizedBox(height: 17),
                if (pair.isNotEmpty) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Spacing: ' + pair,
                          style: const TextStyle(fontSize: 16,
                              fontWeight: FontWeight.bold)),
                      Text(value.abs() < .005 ? 'Original' :
                          value < 0
                              ? 'Closer by ' + value.abs().toStringAsFixed(2) + ' em'
                              : 'Farther by ' + value.toStringAsFixed(2) + ' em',
                        style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                  Slider(
                    value: value.clamp(-.40, .40).toDouble(),
                    min: -.40,
                    max: .40,
                    divisions: 80,
                    label: value.toStringAsFixed(2) + ' em',
                    onChanged: (v) => store.setPair(pair, v),
                  ),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Closer / more overlap',
                        style: TextStyle(color: Colors.white60,
                            fontSize: 12)),
                      Text('Farther / more gap',
                        style: TextStyle(color: Colors.white60,
                            fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () => store.setPair(pair, 0),
                      icon: const Icon(Icons.restore),
                      label: const Text('Reset this pair'),
                    ),
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
                Text(store.pairs.isEmpty
                    ? 'No custom corrections saved yet.'
                    : store.pairs.length.toString() +
                      ' custom pair corrections saved on this device.',
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
