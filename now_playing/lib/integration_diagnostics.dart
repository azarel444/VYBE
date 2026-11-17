import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Read-only, user-triggered YouTube Music metadata comparison.
/// Switching Song / Video is performed by the user inside YouTube Music;
/// neither capture sends playback commands or attempts to extract a stream.
class IntegrationDiagnostics extends StatefulWidget {
  const IntegrationDiagnostics({super.key});

  @override
  State<IntegrationDiagnostics> createState() => _IntegrationDiagnosticsState();
}

class _IntegrationDiagnosticsState extends State<IntegrationDiagnostics> {
  static const _channel = MethodChannel('nowplaying/control');
  static const _fields = <String>[
    'metadata.title',
    'metadata.artist',
    'metadata.album',
    'metadata.mediaId',
    'metadata.durationMs',
    'metadata.keys',
    'videoProbe.activeMediaId',
    'videoProbe.activeMediaUri',
    'videoProbe.activeQueueArtworkUri',
    'videoProbe.activeQueueVideoId',
    'videoProbe.queueVideoIdCount',
    'videoProbe.queueVideoIds',
    'videoProbe.descriptionTitle',
    'videoProbe.descriptionSubtitle',
    'videoProbe.descriptionExtrasKeys',
    'videoProbe.possibleVideoMetadataKeys',
    'videoProbe.possibleVideoMetadataValues',
    'videoProbe.playbackExtrasKeys',
    'videoProbe.sessionExtrasKeys',
    'playbackState',
    'playbackActionsMask',
    'playbackExtrasKeys',
    'sessionExtrasKeys',
    'queuePublished',
    'queueLength',
    'activeQueueItemId',
  ];

  final Map<String, Map<String, dynamic>> _snapshots = {};
  String? _busy;
  String? _error;

  Future<void> _capture(String mode) async {
    setState(() {
      _busy = mode;
      _error = null;
    });
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'integrationDiagnostics', {'service': 'youtube_music'},
      );
      if (!mounted) return;
      final report = Map<String, dynamic>.from(raw ?? <String, dynamic>{});
      report['capturedAs'] = mode;
      setState(() => _snapshots[mode] = report);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  dynamic _field(Map<String, dynamic> report, String path) {
    dynamic current = report;
    for (final part in path.split('.')) {
      if (current is! Map || !current.containsKey(part)) return null;
      current = current[part];
    }
    return current;
  }

  String _display(dynamic value) {
    if (value == null) return '(not supplied)';
    if (value is Map || value is List) return jsonEncode(value);
    return value.toString();
  }

  List<Map<String, String>> _differences() {
    final song = _snapshots['song'];
    final video = _snapshots['video'];
    if (song == null || video == null) return [];
    final changed = <Map<String, String>>[];
    for (final path in _fields) {
      final a = _field(song, path);
      final b = _field(video, path);
      if (jsonEncode(a) == jsonEncode(b)) continue;
      changed.add({
        'field': path,
        'song': _display(a),
        'video': _display(b),
      });
    }
    return changed;
  }

  String _fullReport() {
    return const JsonEncoder.withIndent('  ').convert({
      'purpose': 'YouTube Music Song versus Video MediaSession diagnostic',
      'note': 'Media IDs and URIs do not prove direct video stream access.',
      'song': _snapshots['song'],
      'video': _snapshots['video'],
      'differences': _differences(),
    });
  }

  void _copyReport() {
    Clipboard.setData(ClipboardData(text: _fullReport()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Song/Video diagnostic copied')),
    );
  }

  Widget _snapshotCard(String mode, String label, IconData icon) {
    final report = _snapshots[mode];
    final found = report?['sessionFound'] == true;
    final metadata = report?['metadata'];
    final songInfo = metadata is Map ? metadata : const <String, dynamic>{};
    final videoInfo = report?['videoProbe'];
    final probe = videoInfo is Map ? videoInfo : const <String, dynamic>{};
    final title = songInfo['title']?.toString() ?? 'No track reported';
    final artist = songInfo['artist']?.toString() ?? '';
    final mediaUri = probe['activeMediaUri'];
    final candidateId = probe['activeQueueVideoId']?.toString();
    final queueVideoIdCount = probe['queueVideoIdCount'] ?? 0;
    final assessment = report?['assessment']?.toString() ??
        report?['error']?.toString() ?? '';
    return Card(
      color: const Color(0xFF121722),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(
              fontSize: 19, fontWeight: FontWeight.bold,
            )),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _busy == null ? () => _capture(mode) : null,
              icon: _busy == mode
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(icon),
              label: Text(_busy == mode
                  ? 'Capturing…' : 'Capture $label'),
            ),
            if (report == null) ...[
              const SizedBox(height: 8),
              const Text('Not captured yet.',
                  style: TextStyle(color: Colors.white60)),
            ] else ...[
              const SizedBox(height: 12),
              Text(found ? 'YouTube Music session found'
                         : 'No YouTube Music session found',
                  style: TextStyle(color: found
                      ? Colors.lightGreenAccent : Colors.orangeAccent)),
              if (found) ...[
                const SizedBox(height: 8),
                Text(title),
                if (artist.isNotEmpty) Text(artist,
                    style: const TextStyle(color: Colors.white70)),
                Text('Active media URI: ' +
                    (mediaUri == null ? 'Not supplied' : mediaUri.toString()),
                    style: const TextStyle(
                        fontSize: 12, color: Colors.white70)),
                Text('Queue entries: ' +
                    (report['queueLength'] ?? 0).toString(),
                    style: const TextStyle(
                        fontSize: 12, color: Colors.white70)),
                const SizedBox(height: 8),
                Text(
                  candidateId == null
                      ? 'Current track video ID: Not found in thumbnail'
                      : 'Current track video ID: $candidateId',
                  style: TextStyle(color: candidateId == null
                      ? Colors.white70 : Colors.lightGreenAccent),
                ),
                Text('Queue video thumbnail IDs: $queueVideoIdCount',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.white70)),
                if (candidateId != null) ...[
                  const SizedBox(height: 4),
                  OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text:
                          'https://www.youtube.com/watch?v=$candidateId'));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content:
                            Text('Candidate YouTube video URL copied')),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy candidate video link'),
                  ),
                ],
              ],
              if (assessment.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(assessment,
                    style: const TextStyle(color: Colors.amberAccent)),
              ],
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Full snapshot (technical details)'),
                children: [
                  SelectableText(const JsonEncoder.withIndent('  ')
                      .convert(report),
                      style: const TextStyle(
                        fontSize: 11, fontFamily: 'monospace',
                        color: Colors.white70,
                      )),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _comparison() {
    final ready = _snapshots.containsKey('song') &&
        _snapshots.containsKey('video');
    if (!ready) {
      return const Text('Capture both modes to compare their Android '
          'MediaSession data.', style: TextStyle(color: Colors.white70));
    }
    final changes = _differences();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Changed fields: ' + changes.length.toString(),
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        const Text('Differences indicate what YouTube Music published in '
            'each mode. They do not establish that VYBE can read or '
            'retransmit its video.', style: TextStyle(color: Colors.white70)),
        if (changes.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text('No changes in the selected fields. Video may still '
                'be playing; Android may simply expose identical metadata.'),
          ),
        for (final item in changes)
          Card(
            color: const Color(0xFF121722),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item['field'] ?? '',
                      style: const TextStyle(fontWeight: FontWeight.bold,
                          color: Colors.cyanAccent)),
                  const SizedBox(height: 6),
                  SelectableText('Song: ' + (item['song'] ?? '')),
                  const SizedBox(height: 4),
                  SelectableText('Video: ' + (item['video'] ?? '')),
                ],
              ),
            ),
          ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: _copyReport,
          icon: const Icon(Icons.copy),
          label: const Text('Copy complete comparison'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          const Text('YouTube Music video diagnostic',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w500)),
          const SizedBox(height: 10),
          const Text('Use the same song for both tests. In YouTube Music, '
              'select Song (headphones), return to VYBE and capture Song. '
              'Then switch YouTube Music to Video (play icon), return to '
              'VYBE and capture Video. Do not change songs between scans.'),
          const SizedBox(height: 12),
          _snapshotCard('song', 'Song mode', Icons.headphones),
          _snapshotCard('video', 'Video mode', Icons.ondemand_video),
          const SizedBox(height: 16),
          _comparison(),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 18),
          const Text('This diagnostic is read-only. It checks metadata, '
              'media identifiers, video IDs in official YouTube thumbnail '
              'URLs, and queue changes made available by Android. '
              'Thumbnail IDs are candidates, not verified playable embeds. '
              'It cannot retrieve YouTube Music video bytes or verify '
              'a playable audiovisual stream. '
              'Copied reports may contain track names and media IDs; '
              'review them before sharing.',
              style: TextStyle(color: Colors.white60, fontSize: 12)),
        ],
      ),
    ),
  );
}
