import 'package:flutter/material.dart';
import 'vybe_link.dart';

class VybeLinkSettings extends StatefulWidget {
  const VybeLinkSettings({super.key});
  @override
  State<VybeLinkSettings> createState() => _VybeLinkSettingsState();
}
class _VybeLinkSettingsState extends State<VybeLinkSettings> {
  late final TextEditingController address;
  final link = VybeLink.instance;
  @override
  void initState() {
    super.initState();
    address = TextEditingController(text: link.receiverAddress);
  }
  @override
  void dispose() { address.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: link,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(20), children: [
        const Text('VYBE Link — Direct Connection Beta', style: TextStyle(fontSize: 23)),
        const SizedBox(height: 10),
        const Text('Bluetooth can carry audio while VYBE Link transfers song data and artwork over a reachable local IP network (Wi-Fi or supported USB tethering).'),
        SwitchListTile(title: const Text('Enable VYBE Link'), value: link.enabled,
          onChanged: (v) => link.configure(isEnabled: v)),
        const SizedBox(height: 12),
        const Text('Device role', style: TextStyle(fontSize: 18)),
        RadioListTile<String>(title: const Text('Sender — phone'), value: 'sender',
          groupValue: link.role, onChanged: (v) { if (v != null) link.configure(deviceRole: v); }),
        RadioListTile<String>(title: const Text('Receiver — head unit'), value: 'receiver',
          groupValue: link.role, onChanged: (v) { if (v != null) link.configure(deviceRole: v); }),
        SwitchListTile(title: const Text('Reconnect automatically'),
          subtitle: const Text('Remember this head unit and reconnect when the network is available'),
          value: link.autoConnect, onChanged: (v) => link.configure(automatic: v)),
        if (link.role == 'sender') ...[
          Text(link.pairedReceiverId.isNotEmpty
              ? 'Head unit paired. Automatic reconnection works when both devices share a reachable network.'
              : 'First connection: enable your phone hotspot and join it on the head unit, or connect both to the same Wi-Fi. Then find the receiver below.'),
          const SizedBox(height: 10),
          ElevatedButton.icon(
            onPressed: link.searchingReceivers ? null : () => link.findReceivers(),
            icon: const Icon(Icons.search),
            label: Text(link.searchingReceivers ? 'Searching...' : 'Find head unit on Wi-Fi / hotspot'),
          ),
          for (final receiver in link.receivers)
            ListTile(
              leading: const Icon(Icons.directions_car),
              title: Text(receiver.name),
              subtitle: Text(receiver.id == link.pairedReceiverId
                  ? 'Paired • ${receiver.address}'
                  : receiver.address),
              trailing: receiver.id == link.pairedReceiverId
                  ? const Icon(Icons.check_circle) : const Icon(Icons.link),
              onTap: () => link.pairReceiver(receiver),
            ),
          const SizedBox(height: 8),
          ExpansionTile(
            title: const Text('Advanced: manual IP fallback'),
            children: [
              TextField(controller: address,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Receiver IP address',
                  hintText: '192.168.1.100',
                  border: OutlineInputBorder(),
                )),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => link.configure(
                  isEnabled: true, deviceRole: 'sender',
                  address: address.text, automatic: true,
                ),
                child: const Text('Pair using this IP'),
              ),
            ],
          ),
        ] else ...[
          SelectableText('Head-unit IP: ${link.localAddresses.isEmpty ? "Not detected" : link.localAddresses}',
            style: const TextStyle(fontSize: 17)),
          const Text('TCP port: 38927'),
        ],
        const SizedBox(height: 20),
        const Text('Experimental Wi-Fi Direct', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
        const Text('This is separate from Wi-Fi / hotspot discovery above. First create a group on the head unit, then scan and join it from the phone. Some Android head units cannot start a group. Bluetooth audio remains separate.'),
        Text('Direct support: ${link.directAvailable ? "Detected" : "Not detected"}'),
        Text('Direct status: ${link.directStatus}'),
        ElevatedButton(onPressed: () => link.directStart(receiver: link.role == 'receiver'),
          child: Text(link.role == 'receiver' ? 'Create Direct Connection (head unit)' : 'Find Head Unit (phone)')),
        if (link.role == 'sender') ...[
          for (final peer in link.directPeers)
            ListTile(title: Text(peer['name'] ?? 'Device'), subtitle: Text(peer['address'] ?? ''),
              trailing: const Icon(Icons.link), onTap: () => link.directConnectPeer(peer['address'] ?? '')),
        ],
        const Divider(),
        const SizedBox(height: 18),
        Text('Status: ${link.status}', style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 10),
        ElevatedButton(onPressed: link.enabled ? () => link.connect() : null,
          child: const Text('Reconnect / Refresh Network')),
        const SizedBox(height: 16),
        const Text('Link diagnostics', style: TextStyle(fontSize: 18)),
        Text('Last track: ${link.lastReceivedTrack}'),
        Text('Artwork: ${link.artworkStatus}'),
        Text('Metadata packets: ${link.metadataReceived}  •  Covers: ${link.artworkReceived}  •  Errors: ${link.artworkErrors}'),
        const SizedBox(height: 20),
        const Text('Automatic reconnection needs the same underlying network to be available and VYBE to be running. Wi-Fi Direct and USB networking depend on device support. Android may suspend background apps; uninterrupted hands-free operation is not yet guaranteed.',
          style: TextStyle(color: Colors.white60)),
      ],
    ),
  );
}
