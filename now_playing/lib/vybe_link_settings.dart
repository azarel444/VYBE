import 'package:flutter/material.dart';
import 'vybe_link.dart';

/// VYBE Connect pairs by discovered device identity, never a user-entered IP.
/// Android provides the group-owner address for Wi-Fi Direct, while LAN
/// discovery learns it from the receiver's response.
class VybeLinkSettings extends StatelessWidget {
  const VybeLinkSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final link = VybeLink.instance;
    return AnimatedBuilder(
      animation: link,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('VYBE Connect',
              style: TextStyle(fontSize: 23)),
          const SizedBox(height: 10),
          const Text('Pair your phone and head unit once. VYBE discovers the '
              'receiver address automatically over Wi-Fi Direct or a shared '
              'network, then reconnects when the network returns.'),
          SwitchListTile(
            title: const Text('Enable VYBE Connect'),
            value: link.enabled,
            onChanged: (v) => link.configure(isEnabled: v),
          ),
          const SizedBox(height: 12),
          const Text('Device type', style: TextStyle(fontSize: 18)),
          ListTile(
            leading: Icon(link.deviceType == 'head_unit'
                ? Icons.directions_car : Icons.smartphone),
            title: Text(link.deviceType == 'head_unit' ? 'Head unit' : 'Phone'),
            subtitle: Text(link.role == 'receiver'
                ? 'Receives music and artwork from your phone'
                : 'Sends music and artwork to your head unit'),
            trailing: const Icon(Icons.check_circle_outline),
          ),
          const Text('Selected during Quick Setup. To change it, replay Setup '
              'in VYBE Settings.', style: TextStyle(color: Colors.white70)),
          SwitchListTile(
            title: const Text('Reconnect automatically'),
            subtitle: const Text('Restore Wi-Fi Direct and music transfer '
                'when a connection drops'),
            value: link.autoConnect,
            onChanged: (v) => link.configure(automatic: v),
          ),
          const SizedBox(height: 14),
          const Text('USB cable connection',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
          const Text('Uses the existing Connect music and artwork transfer '
              'over USB tethering instead of wireless. Plug the phone into '
              'a data-capable USB port on the head unit and enable USB '
              'tethering on the phone. A charging-only cable does not work.'),
          if (link.role == 'sender')
            SwitchListTile(
              title: const Text('Prefer USB when connected'),
              subtitle: const Text('Automatically switch to the paired head '
                  'unit on a working USB network; Wi-Fi remains the fallback'),
              value: link.preferWired,
              onChanged: (v) => link.setPreferWired(v),
            ),
          Text('USB link: ${link.wiredStatus}'),
          Text('Active transport: ${link.activeTransport}'),
          if (link.role == 'sender')
            ElevatedButton.icon(
              onPressed: () => link.openUsbTetheringSettings(),
              icon: const Icon(Icons.usb),
              label: const Text('Open phone USB tethering settings'),
            ),
          ElevatedButton.icon(
            onPressed: () => link.requestWiredConnection(),
            icon: const Icon(Icons.refresh),
            label: const Text('Detect / connect USB now'),
          ),
          const Text('Android controls USB tethering: VYBE cannot turn it '
              'on automatically. Some head units do not support USB '
              'networking; in that case Wi-Fi Direct continues working.',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 20),
          const Text('VYBE Wi-Fi Direct',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
          const Text('For initial pairing, set up the connection on the '
              'head unit and discover it from the phone. Once paired, VYBE '
              'remembers the device and attempts to restore the group '
              'automatically.'),
          Text('Direct support: ${link.directAvailable ? "Detected" : "Not detected"}'),
          Text('Direct status: ${link.directStatus}'),
          Text('Local discovery: ${link.discoveryStatus}'),
          ElevatedButton(
            onPressed: () => link.directStart(receiver: link.role == 'receiver'),
            child: Text(link.role == 'receiver'
                ? 'Set up head-unit connection'
                : 'Find head unit for pairing'),
          ),
          if (link.role == 'sender') ...[
            for (final peer in link.directPeers)
              ListTile(
                title: Text(peer['name'] ?? 'Device'),
                subtitle: const Text('Wi-Fi Direct device'),
                trailing: const Icon(Icons.link),
                onTap: () => link.directConnectPeer(
                    peer['address'] ?? '', manuallySelected: true),
              ),
            const SizedBox(height: 16),
            const Text('Shared Wi-Fi / hotspot',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
            const Text('VYBE can also find the receiver on the same '
                'Wi-Fi or hotspot network without needing an IP address.'),
            ElevatedButton.icon(
              onPressed: link.searchingReceivers
                  ? null : () => link.findReceivers(),
              icon: const Icon(Icons.search),
              label: Text(link.searchingReceivers
                  ? 'Searching...' : 'Discover head unit automatically'),
            ),
            for (final receiver in link.receivers)
              ListTile(
                leading: const Icon(Icons.directions_car),
                title: Text(receiver.name),
                subtitle: Text(receiver.id == link.pairedReceiverId
                    ? 'Paired head unit' : 'Available VYBE head unit'),
                trailing: receiver.id == link.pairedReceiverId
                    ? const Icon(Icons.check_circle)
                    : const Icon(Icons.link),
                onTap: () => link.pairReceiver(receiver),
              ),
          ] else ...[
            const Text('Listening for the paired phone on the available '
                'network. VYBE determines its own network address.'),
          ],
          if (link.role == 'receiver') ...[
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 14),
            const Text('Android Bluetooth audio source',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
            const Text('VYBE can request PLAY from a receiver that exposes '
                'an Android media session. This does not require Android Auto '
                'or a manufacturer-specific integration. Some head units '
                'hide their Bluetooth audio routing from regular apps.'),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: () => link.scanBluetoothSources(),
              icon: const Icon(Icons.search),
              label: const Text('Find Android media sources'),
            ),
            if (link.bluetoothSources.isEmpty)
              const Text('No sources listed yet. Start Bluetooth audio '
                  'once, then scan to identify the receiver session.'),
            for (final source in link.bluetoothSources)
              ListTile(
                leading: Icon(source['package'] == link.bluetoothSourcePackage
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                title: Text(source['name']?.toString() ?? 'Android media source'),
                subtitle: Text(
                    '${source['package'] ?? ''} — '
                    '${source['playing'] == true ? 'Playing' : 'Not playing'}'
                    '${source['canPlay'] == true ? ' • PLAY control' : ''}'),
                onTap: () => link.selectBluetoothSource(
                    source['package']?.toString() ?? ''),
              ),
            SwitchListTile(
              title: const Text('Activate audio on phone playback'),
              subtitle: const Text('When VYBE Connect reports that music '
                  'started, request PLAY from your selected Android receiver '
                  'session. Off until you choose a source.'),
              value: link.bluetoothAutoResume,
              onChanged: (v) => link.setBluetoothAutoResume(v),
            ),
            ElevatedButton.icon(
              onPressed: link.bluetoothSourcePackage.isEmpty
                  ? null : () => link.requestBluetoothSourcePlay(),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Try activating selected source'),
            ),
            OutlinedButton.icon(
              onPressed: () => link.requestSystemMediaPlay(),
              icon: const Icon(Icons.settings_remote),
              label: const Text('Test Android system PLAY key'),
            ),
            const Text('The system PLAY key is manual-only: Android may '
                'send it to an unrelated media app. Automatic activation '
                'only targets the source you selected.',
                style: TextStyle(color: Colors.white70)),
            Text('Source: ${link.bluetoothSourcePackage.isEmpty ? "Not selected" : link.bluetoothSourcePackage}'),
            Text('Status: ${link.bluetoothSourceStatus}'),
            Text('Diagnostics: ${link.bluetoothDeviceDiagnostics}'),
            const Text('PLAY requests cannot guarantee audio routing. '
                'If the receiver does not expose an Android media session '
                'until its factory app opens, VYBE cannot start that private '
                'service through standard Android APIs.',
                style: TextStyle(color: Colors.white60)),
          ],
          const Divider(),
          const SizedBox(height: 14),
          Text('Connection: ${link.status}',
              style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 10),
          ElevatedButton(
            onPressed: () => link.reconnectAutomatically(),
            child: const Text('Reconnect automatically now'),
          ),
          const SizedBox(height: 16),
          const Text('Connection diagnostics',
              style: TextStyle(fontSize: 18)),
          Text('Last track: ${link.lastReceivedTrack}'),
          Text('Artwork: ${link.artworkStatus}'),
          Text('Metadata packets: ${link.metadataReceived}  •  '
              'Covers: ${link.artworkReceived}  •  Errors: ${link.artworkErrors}'),
          const SizedBox(height: 20),
          const Text('No manual IP entry is required. Android may still '
              'request a one-time Wi-Fi Direct pairing approval, and a '
              'compatible network must be available. Some Android head '
              'units restrict background connection recovery.',
              style: TextStyle(color: Colors.white60)),
        ],
      ),
    );
  }
}
