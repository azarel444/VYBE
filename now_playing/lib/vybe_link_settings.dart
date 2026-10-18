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
        const Text('Bluetooth continues carrying audio. VYBE Link sends metadata and album artwork over a local Wi-Fi network.'),
        SwitchListTile(title: const Text('Enable VYBE Link'), value: link.enabled,
          onChanged: (v) => link.configure(isEnabled: v)),
        const SizedBox(height: 12),
        const Text('Device role', style: TextStyle(fontSize: 18)),
        RadioListTile<String>(title: const Text('Sender — phone'), value: 'sender',
          groupValue: link.role, onChanged: (v) { if (v != null) link.configure(deviceRole: v); }),
        RadioListTile<String>(title: const Text('Receiver — head unit'), value: 'receiver',
          groupValue: link.role, onChanged: (v) { if (v != null) link.configure(deviceRole: v); }),
        SwitchListTile(title: const Text('Auto-connect'),
          subtitle: const Text('Retry the saved receiver address when disconnected'),
          value: link.autoConnect, onChanged: (v) => link.configure(automatic: v)),
        if (link.role == 'sender') ...[
          TextField(controller: address,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Receiver IP address',
              hintText: '192.168.1.100', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          ElevatedButton(onPressed: () => link.configure(address: address.text),
            child: const Text('Save IP and Connect')),
        ] else ...[
          SelectableText('Head-unit IP: ${link.localAddresses.isEmpty ? "Not detected" : link.localAddresses}',
            style: const TextStyle(fontSize: 17)),
          const Text('TCP port: 38927'),
        ],
        const SizedBox(height: 20),
        const Text('Connect without a router', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
        const Text('Head unit: create a Wi-Fi Direct group. Phone: find the head unit and tap it. Bluetooth audio remains separate.'),
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
        const Text('Direct mode is experimental: both devices must support Wi-Fi Direct, grant Nearby devices / Location permission, and enable Location services for discovery. LAN IP mode remains available as a fallback.',
          style: TextStyle(color: Colors.white60)),
      ],
    ),
  );
}
