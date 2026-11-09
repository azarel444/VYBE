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
          const Text('VYBE Wi-Fi Direct',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
          const Text('For initial pairing, set up the connection on the '
              'head unit and discover it from the phone. Once paired, VYBE '
              'remembers the device and attempts to restore the group '
              'automatically.'),
          Text('Direct support: ${link.directAvailable ? "Detected" : "Not detected"}'),
          Text('Direct status: ${link.directStatus}'),
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
