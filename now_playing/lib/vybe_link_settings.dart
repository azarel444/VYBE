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
        const Text('VYBE Link — LAN Test', style: TextStyle(fontSize: 23)),
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
        const SizedBox(height: 18),
        Text('Status: ${link.status}', style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 10),
        ElevatedButton(onPressed: link.enabled ? () => link.connect() : null,
          child: const Text('Reconnect / Refresh Network')),
        const SizedBox(height: 20),
        const Text('Beta limitation: both devices must already be on a mutually reachable Wi-Fi network. This version does not create Wi-Fi Direct groups or automatically discover peers. If the head unit and phone cannot share a local network, the connection test will not work yet.',
          style: TextStyle(color: Colors.white60)),
      ],
    ),
  );
}
