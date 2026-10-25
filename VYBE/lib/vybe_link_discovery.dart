import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// VYBE receiver discovery on an existing local network (Wi-Fi, hotspot,
/// Wi-Fi Direct group or USB tethering if Android exposes an IP interface).
/// Discovery does not create the underlying network.
class LinkReceiver {
  final String id;
  final String address;
  final String name;
  const LinkReceiver({required this.id, required this.address, required this.name});
}

class LinkDiscovery {
  static const int port = 38928;
  static final List<int> _probe = utf8.encode(
    jsonEncode(<String, dynamic>{'kind': 'vybe_discover', 'v': 1}),
  );

  static Future<List<LinkReceiver>> scan({
    Duration timeout = const Duration(milliseconds: 1400),
  }) async {
    final found = <String, LinkReceiver>{};
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? subscription;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final listening = socket;
      subscription = listening.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? packet;
        while ((packet = listening.receive()) != null) {
          try {
            final message = jsonDecode(utf8.decode(packet!.data));
            if (message is! Map || message['kind'] != 'vybe_receiver' ||
                message['v'] != 1) continue;
            final id = (message['id'] as String?) ?? '';
            if (id.length < 16 || id.length > 128) continue;
            found[id] = LinkReceiver(
              id: id,
              address: packet.address.address,
              name: (message['name'] as String?) ?? 'VYBE receiver',
            );
          } catch (_) {}
        }
      });

      final targets = <String>{'255.255.255.255'};
      try {
        for (final network in await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        )) {
          for (final address in network.addresses) {
            final octets = address.address.split('.');
            if (octets.length == 4) {
              // Common car head-unit, hotspot, and USB tethering networks
              // use /24. All-subnets broadcast is attempted as well.
              targets.add('${octets[0]}.${octets[1]}.${octets[2]}.255');
            }
          }
        }
      } catch (_) {}
      for (final target in targets) {
        try { listening.send(_probe, InternetAddress(target), port); } catch (_) {}
      }
      // Repeat once for networks that are still coming up.
      await Future<void>.delayed(timeout ~/ 2);
      for (final target in targets) {
        try { listening.send(_probe, InternetAddress(target), port); } catch (_) {}
      }
      await Future<void>.delayed(timeout ~/ 2);
    } catch (_) {
      // Broadcast can be blocked by some Android/OEM networks.
    } finally {
      await subscription?.cancel();
      socket?.close();
    }
    return found.values.toList();
  }
}

class LinkDiscoveryResponder {
  final RawDatagramSocket _socket;
  late final StreamSubscription<RawSocketEvent> _subscription;
  LinkDiscoveryResponder._(this._socket);

  static Future<LinkDiscoveryResponder> start(String receiverId) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4, LinkDiscovery.port,
    );
    final responder = LinkDiscoveryResponder._(socket);
    final reply = utf8.encode(jsonEncode(<String, dynamic>{
      'kind': 'vybe_receiver',
      'v': 1,
      'id': receiverId,
      'name': 'VYBE head unit',
    }));
    responder._subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = socket.receive()) != null) {
        if (packet!.data.length > 256) continue;
        try {
          final message = jsonDecode(utf8.decode(packet.data));
          if (message is Map && message['kind'] == 'vybe_discover' &&
              message['v'] == 1) {
            socket.send(reply, packet.address, packet.port);
          }
        } catch (_) {}
      }
    });
    return responder;
  }

  Future<void> close() async {
    await _subscription.cancel();
    _socket.close();
  }
}
