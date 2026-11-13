import 'dart:async';
import 'package:flutter/material.dart';
import 'vybe_link.dart';

/// One clear Connect screen for either phone or Android head unit.
/// USB tether controls were removed: Wi-Fi Direct, automatic reconnection
/// and direct Wi-Fi audio are now the supported connection paths.
class VybeLinkSettings extends StatefulWidget {
  const VybeLinkSettings({super.key});

  @override
  State<VybeLinkSettings> createState() => _VybeLinkSettingsState();
}

class _VybeLinkSettingsState extends State<VybeLinkSettings> {
  Timer? _audioPoll;

  @override
  void initState() {
    super.initState();
    // Poll native sender/receiver statistics only while the settings page
    // exists. Device role and actual PCM output are visible on the head unit.
    _audioPoll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted && VybeLink.instance.enabled) {
        unawaited(VybeLink.instance.refreshWifiAudioStreamStatus());
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(VybeLink.instance.refreshWifiAudioStreamStatus());
      }
    });
  }

  @override
  void dispose() {
    _audioPoll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final link = VybeLink.instance;
    return AnimatedBuilder(
      animation: link,
      builder: (context, _) {
        final headUnit = link.role == 'receiver';
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('VYBE Connect', style: TextStyle(fontSize: 23)),
            const SizedBox(height: 6),
            const Text('Connect the phone to the head unit over Wi-Fi Direct '
                'or a shared Wi-Fi network. No Android Auto or USB required.'),
            SwitchListTile(
              title: const Text('Enable VYBE Connect'),
              value: link.enabled,
              onChanged: (value) => link.configure(isEnabled: value),
            ),
            const SizedBox(height: 10),
            const Text('This device', style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: () => link.setDeviceType('phone'),
                icon: Icon(!headUnit ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                label: const Text('Phone'),
              )),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(
                onPressed: () => link.setDeviceType('head_unit'),
                icon: Icon(headUnit ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                label: const Text('Head unit'),
              )),
            ]),
            Text(headUnit
                ? 'Receiving artwork, playback information and optional audio.'
                : 'Sending artwork, playback information and optional audio.',
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            Text('Connection: ${link.status}'),
            Text('Network: ${link.activeTransport}'),
            SwitchListTile(
              title: const Text('Reconnect automatically'),
              value: link.autoConnect,
              onChanged: (value) => link.configure(automatic: value),
            ),
            const Divider(),
            const SizedBox(height: 8),
            const Text('Wi-Fi connection',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
            const Text('Only head units advertising the VYBE receiver '
                'service appear during pairing. Nearby printers and generic '
                'Android devices are hidden.'),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () => link.directStart(receiver: headUnit),
              icon: const Icon(Icons.wifi),
              label: Text(headUnit
                  ? 'Set up head-unit Wi-Fi Direct'
                  : 'Find VYBE head units'),
            ),
            if (!headUnit) ...[
              if (link.directPeers.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No VYBE head units discovered yet. Enable '
                      'VYBE Connect and set up Wi-Fi Direct on the head '
                      'unit first, then search here. You can also use '
                      'shared Wi-Fi pairing below.',
                      style: TextStyle(color: Colors.white70)),
                ),
              for (final peer in link.directPeers)
                ListTile(
                  title: Text(peer['name'] ?? 'VYBE Head Unit'),
                  subtitle: Text(peer['id'] == link.pairedReceiverId
                      ? 'Paired VYBE receiver'
                      : 'VYBE receiver service detected'),
                  trailing: const Icon(Icons.link),
                  onTap: () => link.directConnectPeer(
                      peer['address'] ?? '', manuallySelected: true),
                ),
              OutlinedButton.icon(
                onPressed: link.searchingReceivers
                    ? null : () => link.findReceivers(),
                icon: const Icon(Icons.search),
                label: Text(link.searchingReceivers
                    ? 'Searching...' : 'Find head unit on shared Wi-Fi'),
              ),
              for (final receiver in link.receivers)
                ListTile(
                  title: Text(receiver.name),
                  subtitle: Text(receiver.id == link.pairedReceiverId
                      ? 'Paired head unit' : 'Tap to pair'),
                  trailing: receiver.id == link.pairedReceiverId
                      ? const Icon(Icons.check_circle_outline)
                      : const Icon(Icons.link),
                  onTap: () => link.pairReceiver(receiver),
                ),
            ],
            Text('Wi-Fi Direct: ${link.directStatus}',
                style: const TextStyle(color: Colors.white70)),
            OutlinedButton.icon(
              onPressed: () => link.reconnectAutomatically(),
              icon: const Icon(Icons.refresh),
              label: const Text('Reconnect'),
            ),
            const Divider(),
            const SizedBox(height: 8),
            const Text('Wi-Fi music audio',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
            const Text('Experimental direct audio over VYBE Connect. '
                'Bluetooth Music and Android Auto are not needed for this '
                'audio test. Both devices must have VYBE Connect active.'),
            const SizedBox(height: 8),
            if (headUnit) ...[
              ElevatedButton.icon(
                onPressed: link.wifiAudioPeerConnected
                    ? () => link.startWifiAudioReceiver() : null,
                icon: const Icon(Icons.speaker),
                label: const Text('Start receiving Wi-Fi audio'),
              ),
              OutlinedButton.icon(
                onPressed: () => link.stopWifiAudioReceiver(),
                icon: const Icon(Icons.stop),
                label: const Text('Stop receiving audio'),
              ),
              const SizedBox(height: 10),
              Text('Receiver status: ${link.wifiStreamReceiverStatus}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(link.wifiStreamReceiverDetail),
              Text('Audio bytes received: ${link.wifiStreamReceivedBytes}'),
              Text('Audio bytes written: ${link.wifiStreamPlayedBytes}'),
              Text('Signal peak: ${link.wifiStreamReceiverPeak} / 32767'),
              Text('Jitter buffer: ${link.wifiStreamReceiverBufferedMs} ms'),
              Text('Buffer underruns: ${link.wifiStreamReceiverUnderruns}'),
              Text('Android audio underruns: ${link.wifiStreamTrackUnderruns}'),
              Text('Late packets dropped: ${link.wifiStreamDroppedPackets}'),
              if (link.wifiStreamReceiverLastFailure.isNotEmpty)
                Text('Last audio interruption: ${link.wifiStreamReceiverLastFailure}'),
              Text('Output: ${link.wifiStreamOutputRoute}'),
              Text('Media volume: ${link.wifiStreamMusicVolume} / '
                  '${link.wifiStreamMusicMaxVolume}'),
              Text('Expected phone IP: ${link.wifiStreamExpectedPhoneIp.isEmpty ? "Not connected" : link.wifiStreamExpectedPhoneIp}'),
              Text('Actual audio connection: ${link.wifiStreamObservedPhoneIp.isEmpty ? "None yet" : link.wifiStreamObservedPhoneIp}'),
              if (link.wifiStreamRejected > 0)
                Text('Rejected audio connections: ${link.wifiStreamRejected}'),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => link.testHeadUnitAudioOutput(),
                icon: const Icon(Icons.volume_up),
                label: const Text('Test head-unit speaker output'),
              ),
              Text('Speaker test: ${link.wifiStreamToneStatus}'),
              const Text('Start the receiver here, then start Wi-Fi audio '
                  'on the phone. The receiver counters above show whether '
                  'audio actually arrives and reaches Android audio output.',
                  style: TextStyle(color: Colors.white70)),
            ] else ...[
              ElevatedButton.icon(
                onPressed: link.wifiAudioPeerConnected
                    ? () => link.startWifiAudioStream() : null,
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('Start streaming audio to head unit'),
              ),
              OutlinedButton.icon(
                onPressed: () => link.stopWifiAudioStream(),
                icon: const Icon(Icons.stop),
                label: const Text('Stop streaming audio'),
              ),
              const SizedBox(height: 8),
              Text('Sender status: ${link.wifiStreamSenderStatus}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(link.wifiStreamSenderDetail),
              Text('Audio bytes sent: ${link.wifiStreamSentBytes}'),
              Text('Captured signal peak: ${link.wifiStreamSenderPeak} / 32767'),
              Text('Reconnect attempts: ${link.wifiStreamSenderReconnects}'),
              if (link.wifiStreamSenderLastFailure.isNotEmpty)
                Text('Last audio socket failure: ${link.wifiStreamSenderLastFailure}'),
              Text('Head unit IP: ${link.wifiStreamSenderIp.isEmpty ? "Not connected" : link.wifiStreamSenderIp}'),
              const Text('Start Wi-Fi audio reception on the head unit first. '
                  'Android will then ask permission to capture the playing '
                  'music. Phone speaker playback may continue during testing.',
                  style: TextStyle(color: Colors.white70)),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => link.refreshWifiAudioStreamStatus(),
              icon: const Icon(Icons.analytics_outlined),
              label: const Text('Refresh audio diagnostics'),
            ),
            const Text('For this beta, audio is unencrypted PCM. '
                'Use a trusted Wi-Fi Direct or private network.',
                style: TextStyle(color: Colors.white60)),
            const Divider(),
            ExpansionTile(
              title: const Text('Advanced diagnostics'),
              children: [
                Text('Local discovery: ${link.discoveryStatus}'),
                Text('Metadata packets: ${link.metadataReceived}'),
                Text('Album art received: ${link.artworkReceived}'),
                Text('Network / artwork errors: ${link.artworkErrors}'),
                Text('Last track: ${link.lastReceivedTrack}'),
                Text('Artwork: ${link.artworkStatus}'),
                if (!headUnit) ...[
                  const SizedBox(height: 12),
                  const Text('Phone playback-capture compatibility test'),
                  ElevatedButton(
                    onPressed: () => link.startWifiAudioCaptureTest(),
                    child: const Text('Run 25-second capture test'),
                  ),
                  OutlinedButton(
                    onPressed: () => link.refreshWifiAudioCaptureTest(),
                    child: const Text('Read capture results'),
                  ),
                  Text('Capture: ${link.wifiAudioProbeStatus}'),
                  Text(link.wifiAudioProbeDetails),
                  if (link.wifiAudioProbeSamples > 0)
                    Text('Peak: ${link.wifiAudioProbePeak}; samples: '
                        '${link.wifiAudioProbeSamples}'),
                ] else ...[
                  const SizedBox(height: 12),
                  const Text('Android Bluetooth source control'),
                  ElevatedButton(
                    onPressed: () => link.scanBluetoothSources(),
                    child: const Text('Find Android media sources'),
                  ),
                  for (final source in link.bluetoothSources)
                    ListTile(
                      title: Text(source['name']?.toString() ?? 'Media source'),
                      subtitle: Text(source['package']?.toString() ?? ''),
                      trailing: source['package'] == link.bluetoothSourcePackage
                          ? const Icon(Icons.check_circle_outline)
                          : const Icon(Icons.radio_button_unchecked),
                      onTap: () => link.selectBluetoothSource(
                          source['package']?.toString() ?? ''),
                    ),
                  SwitchListTile(
                    title: const Text('Request Bluetooth PLAY on phone playback'),
                    value: link.bluetoothAutoResume,
                    onChanged: (value) => link.setBluetoothAutoResume(value),
                  ),
                  OutlinedButton(
                    onPressed: link.bluetoothSourcePackage.isEmpty
                        ? null : () => link.requestBluetoothSourcePlay(),
                    child: const Text('Test selected Bluetooth source'),
                  ),
                  Text('Bluetooth status: ${link.bluetoothSourceStatus}'),
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}
