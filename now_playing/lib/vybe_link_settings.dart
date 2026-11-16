import 'dart:async';
import 'package:flutter/material.dart';
import 'vybe_link.dart';

/// One clear Connect screen for either phone or Android head unit.
/// Wi-Fi Direct carries artwork, track information and controls.
/// Audio plays separately through the head unit's Bluetooth audio input.
class VybeLinkSettings extends StatefulWidget {
  const VybeLinkSettings({super.key});

  @override
  State<VybeLinkSettings> createState() => _VybeLinkSettingsState();
}

class _VybeLinkSettingsState extends State<VybeLinkSettings> {
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
            const Text('Wi-Fi Direct or shared Wi-Fi transfers artwork, '
                'track information and controls. Play music through the '
                'head unit Bluetooth audio input. Android Auto is not required.'),
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
              subtitle: const Text('Off: no background pairing or retries. '
                  'Use Find VYBE head units to connect manually.'),
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
            if (headUnit && link.localDeviceId.length >= 6)
              Text('Advertised as: VYBE Head Unit · '
                  '${link.localDeviceId.substring(link.localDeviceId.length - 6).toUpperCase()}',
                  style: const TextStyle(color: Colors.white70)),
            if (!headUnit) ...[
              // Saved identity is persistent even if the head unit's Wi-Fi
              // briefly vanishes or a new scan yields no advertisements.
              if (link.hasSavedDirectReceiver &&
                  !link.directPeers.any(
                      (peer) => peer['id'] == link.savedDirectReceiverId))
                ListTile(
                  title: Text(link.savedDirectReceiverLabel),
                  subtitle: const Text('Saved head unit · not responding yet. '
                      'Tap to scan again without losing the pairing.'),
                  trailing: const Icon(Icons.refresh),
                  onTap: () => link.directStart(receiver: false),
                ),
              if (link.directPeers.isEmpty && !link.hasSavedDirectReceiver)
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
                  subtitle: Text(peer['id'] == link.savedDirectReceiverId
                      ? 'Saved VYBE head unit'
                      : 'Verified VYBE receiver found'),
                  trailing: link.directPairingInProgress
                      ? const Icon(Icons.hourglass_top)
                      : const Icon(Icons.link),
                  onTap: link.directPairingInProgress
                      ? null : () => link.directConnectPeer(
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
            const SizedBox(height: 10),
            const Text('Wi-Fi Direct band test',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            Text(headUnit
                ? 'This head unit runs Android 9. Android does not provide '
                    'an app-controlled 2.4/5 GHz Wi-Fi Direct setting or '
                    'an actual-frequency reading on Android 9. '
                    'Check the measured band on the connected phone.'
                : 'Automatic is recommended. Strict 2.4/5 GHz modes '
                    'restrict which Wi-Fi Direct group your phone will JOIN. '
                    'They cannot force the Android 9 head unit to change bands.',
                style: const TextStyle(color: Colors.white70)),
            if (!headUnit) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: link.directBandMode,
                decoration: const InputDecoration(
                  labelText: 'Phone Wi-Fi Direct connection band'),
                items: const [
                  DropdownMenuItem(value: 'auto',
                      child: Text('Automatic (recommended)')),
                  DropdownMenuItem(value: '2ghz',
                      child: Text('2.4 GHz only — test')),
                  DropdownMenuItem(value: '5ghz',
                      child: Text('5 GHz only — test')),
                ],
                onChanged: link.directBandSelectable
                    ? (value) {
                        if (value != null) {
                          unawaited(link.setDirectBandMode(value));
                        }
                      }
                    : null,
              ),
              if (!link.directBandSelectable)
                const Text('This phone needs Android 10 or newer for band '
                    'selection; Automatic remains available.',
                    style: TextStyle(color: Colors.white70)),
              if (link.directBandMode != 'auto')
                const Text('Test mode applies when establishing a new '
                    'Wi-Fi Direct connection. The ATOTO must already host '
                    'on the chosen band. If pairing fails, choose Automatic '
                    'and reconnect; continuous automatic retries are '
                    'suppressed in test mode.',
                    style: TextStyle(color: Colors.white70)),
            ],
            const SizedBox(height: 6),
            Text('Actual Wi-Fi Direct band: ${link.directActualBand}'
                '${link.directFrequencyMHz > 0 ? " (${link.directFrequencyMHz} MHz)" : ""}'),
            Text(link.directBandVerified
                ? 'Measured from the active Wi-Fi Direct group'
                : 'Band not verified. An ordinary Wi-Fi network frequency '
                    'does not identify the Wi-Fi Direct channel.',
                style: const TextStyle(color: Colors.white70)),
            OutlinedButton.icon(
              onPressed: () => link.refreshDirectBandInfo(),
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh Wi-Fi Direct frequency'),
            ),
            Text('Wi-Fi Direct: ${link.directStatus}',
                style: const TextStyle(color: Colors.white70)),
            if (link.directPairingDiagnostic.isNotEmpty)
              SelectableText('Last Android pairing diagnostic: '
                  '${link.directPairingDiagnostic}',
                  style: const TextStyle(color: Colors.white70)),
            OutlinedButton.icon(
              onPressed: () => link.reconnectAutomatically(),
              icon: const Icon(Icons.refresh),
              label: const Text('Reconnect'),
            ),
            const Divider(),
            ExpansionTile(
              title: const Text('Advanced diagnostics'),
              children: [
                Text('Local discovery: ${link.discoveryStatus}'),
                Text('Metadata packets: ${link.metadataReceived}'),
                Text('Synchronized lyric sheets received: ${link.lyricsReceived}'),
                if (headUnit) Text('Lyrics: ${link.lyricsTransferStatus}'),
                Text('Album art received: ${link.artworkReceived}'),
                Text('Network / artwork errors: ${link.artworkErrors}'),
                Text('Last track: ${link.lastReceivedTrack}'),
                Text('Artwork: ${link.artworkStatus}'),
                if (headUnit) ...[
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
