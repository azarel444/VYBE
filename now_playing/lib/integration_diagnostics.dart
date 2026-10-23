import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Read-only diagnostics: does not sign in, browse a private playlist API,
/// or send playback commands. Results reflect only the current Android session.
class IntegrationDiagnostics extends StatefulWidget {
  const IntegrationDiagnostics({super.key});

  @override
  State<IntegrationDiagnostics> createState() => _IntegrationDiagnosticsState();
}

class _IntegrationDiagnosticsState extends State<IntegrationDiagnostics> {
  static const _channel = MethodChannel('nowplaying/control');
  final Map<String, Map<String, dynamic>> _reports = {};
  String? _busy;
  String? _error;

  Future<void> _scan(String service) async {
    setState(() { _busy = service; _error = null; });
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
          'integrationDiagnostics', {'service': service});
      if (!mounted) return;
      setState(() => _reports[service] = Map<String, dynamic>.from(raw ?? {}));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  String _format(String service) {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(_reports[service] ?? {});
  }

  Widget _service(String key, String name) {
    final report = _reports[key];
    final actions = report?['actions'];
    final capabilities = actions is Map ? actions : <String, dynamic>{};
    final found = report?['sessionFound'] == true;
    final published = report?['queuePublished'] == true;
    final length = report?['queueLength'] ?? 0;
    final jump = report?['queueJumpCandidate'] == true;
    final next = report?['upNextCandidate'] == true;
    return Card(
      color: const Color(0xFF121722),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(found ? 'Active session found' : report == null
              ? 'Not scanned' : 'No matching session',
              style: const TextStyle(color: Colors.white70)),
          if (report != null) ...[
            const SizedBox(height: 8),
            Text('Queue published: ${published ? "Yes" : "No"}  •  Entries: $length'),
            Text('Up Next candidate: ${next ? "Yes" : "Not established"}'),
            Text('Queue-item jumping candidate: ${jump ? "Yes" : "Not established"}'),
            Text('Skip next: ${capabilities['skipNext'] == true ? "Supported" : "Not reported"}'),
            Text('Full playlist browsing: Not verified by media-session scan'),
            const SizedBox(height: 8),
            Text('${report['assessment'] ?? report['error'] ?? ""}',
                style: const TextStyle(color: Colors.amberAccent)),
            const SizedBox(height: 12),
            SelectableText(_format(key),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace',
                    color: Colors.white70)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _format(key)));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Diagnostics copied')));
              },
              icon: const Icon(Icons.copy), label: const Text('Copy diagnostics')),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy == null ? () => _scan(key) : null,
            icon: _busy == key
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search),
            label: Text(_busy == key ? 'Scanning…' : 'Scan $name'),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          const Text('YouTube Music integration diagnostics',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w500)),
          const SizedBox(height: 10),
          const Text('Start a playlist in YouTube Music, then scan '
              'while it is playing. These diagnostics inspect what Android '
              'actually exposes to VYBE: track metadata, artwork references, '
              'queue entries and playback actions. They do not access the '
              'streaming service\'s private playlist library.'),
          const SizedBox(height: 12),
          _service('youtube_music', 'YouTube Music'),
          const SizedBox(height: 8),
          const Text('For later compatibility testing: scan once, skip to the next song and scan again. Repeat after shuffle or switching playlists. Compare activeQueueItemId, queueIds, queue artwork and track ordering. No playback commands are sent by this diagnostic.', style: TextStyle(color: Colors.white70)),
          if (_error != null) Text(_error!,
              style: const TextStyle(color: Colors.redAccent)),
          const SizedBox(height: 10),
          const Text('Important: A queue entry is not proof that an entire '
              'playlist can be browsed, or that selecting any track will '
              'work. Scan results are snapshots; repeat after shuffle, '
              'skip, and playlist changes. The report may contain song '
              'titles, artist names and media IDs. Review before sharing.',
              style: TextStyle(color: Colors.white60)),
        ],
      ),
    ),
  );
}
