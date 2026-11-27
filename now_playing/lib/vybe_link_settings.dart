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
              subtitle: Text(headUnit ? 'Off: select your phone manually.' : 'Off: start the phone network manually.'),
              value: link.autoConnect,
              onChanged: (value) => link.configure(automatic: value),
            ),
            const Divider(),
            const SizedBox(height: 8),
            const Text('Wi-Fi connection',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
            Text(headUnit ? 'Find and join the Wi-Fi Direct network created by your VYBE phone.' : 'Your phone creates the Wi-Fi Direct network. Start it here, then select this phone on the head unit.'),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: link.directResetInProgress ? null : () => link.directStart(receiver: headUnit),
              icon: const Icon(Icons.wifi),
              label: Text(headUnit
                  ? 'Find VYBE phones'
                  : 'Start phone Wi-Fi Direct'),
            ),
            const SizedBox(height: 6),
            Text('Wi-Fi Direct: ${link.directStatus}',
                style: const TextStyle(color: Colors.white70)),
            if (!headUnit && link.localDeviceId.length >= 6)
              Text('Advertised as: VYBE Phone · '
                  '${link.localDeviceId.substring(link.localDeviceId.length - 6).toUpperCase()}',
                  style: const TextStyle(color: Colors.white70)),
            if (headUnit) ...[
              if (link.directPeers.isEmpty)
                const Text('No VYBE phones found. Start phone Wi-Fi Direct on your phone, then search here.'),
              for (final peer in link.directPeers)
                ListTile(
                  title: Text(peer['name'] ?? 'VYBE Phone'),
                  subtitle: Text(peer['id'] == link.savedDirectPhoneId
                      ? 'Saved VYBE phone' : 'Tap to join this phone'),
                  trailing: link.directPairingInProgress
                      ? const Icon(Icons.hourglass_top) : const Icon(Icons.link),
                  onTap: link.directPairingInProgress ? null : () =>
                    link.directConnectPeer(peer['address'] ?? '', manuallySelected: true),
                ),
            ],
            if (!headUnit) ...[
              if (link.hasSavedDirectReceiver)
                Text('Paired head unit: ${link.savedDirectReceiverLabel}'),
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
            const Text('Wi-Fi Direct frequency',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const Text('The phone owns the group. Automatic band selection is used in this test build.'),
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
            if (link.directPairingDiagnostic.isNotEmpty)
              SelectableText('Last Android pairing diagnostic: '
                  '${link.directPairingDiagnostic}',
                  style: const TextStyle(color: Colors.white70)),
            OutlinedButton.icon(
              onPressed: link.directResetInProgress
                  ? null : () => link.reconnectAutomatically(),
              icon: const Icon(Icons.refresh),
              label: const Text('Reconnect'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: link.directResetInProgress
                  ? null : () => link.resetDirectSession(),
              icon: const Icon(Icons.restart_alt),
              label: Text(link.directResetInProgress
                  ? 'Clearing Android Wi-Fi Direct...'
                  : (headUnit
                      ? 'Reset head-unit Wi-Fi Direct'
                      : 'Reset phone Wi-Fi Direct')),
            ),
            ...[
              const SizedBox(height: 7),
              OutlinedButton.icon(
                onPressed: link.directResetInProgress ? null : () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: Text(headUnit ? 'Forget saved phone?' : 'Forget saved head unit?'),
                      content: const Text(
                        'Remove VYBE\'s saved receiver identity and IP, '
                        'cancel any stalled pairing, and release the old '
                        'Wi-Fi Direct group. This does NOT delete artwork, '
                        'music, or VYBE settings. Re-pair from the device list.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('Cancel')),
                        FilledButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text('Forget and reset')),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await link.resetDirectSession(forgetSaved: true);
                  }
                },
                icon: const Icon(Icons.link_off),
                label: Text(headUnit ? 'Forget saved phone & reset link' : 'Forget saved head unit & reset link'),
              ),
            ],
            const Text(
              'Use Reset if pairing gets stuck or Android retains a dead '
              'group. Forget clears the saved device so you can select '
              'a different device without reinstalling VYBE.',
              style: TextStyle(color: Colors.white60, fontSize: 12),
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
