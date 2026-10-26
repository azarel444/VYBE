import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'now_playing_model.dart';
import 'vybe_link_discovery.dart';

/// Local-network beta. Pair a receiver once, then rediscover its IP across
/// sessions. A reachable IP network is still required (LAN, Wi-Fi Direct or
/// USB tethering); this code does not establish that underlying network.
class VybeLink extends ChangeNotifier {
  VybeLink._();
  static final VybeLink instance = VybeLink._();
  static const port = 38927;
  String localDeviceId = '';
  String pairedReceiverId = '';
  List<LinkReceiver> receivers = [];
  bool searchingReceivers = false;
  LinkDiscoveryResponder? _responder;
  Timer? _helloTimer;
  int _lastMetadataSentAt = 0;
  String _lastMetadataState = '';
  bool enabled = false;
  String role = 'sender';
  bool autoConnect = true;
  String receiverAddress = '';
  String status = 'Disabled';
  String localAddresses = '';
  ServerSocket? _server;
  Socket? _socket;
  StreamSubscription? _socketSub;
  Timer? _retry;
  Timer? _connectionWatchdog;
  bool _connecting = false;
  bool _initialized = false;
  Timer? _sendTimer;
  NowPlayingModel? _model;
  String _lastPayload = '';
  String _lastTrack = '';
  int _lastArtHash = 0;
  int _artGeneration = 0;
  int _rxGeneration = 0;
  String lastReceivedTrack = 'None';
  String artworkStatus = 'No artwork received';
  int metadataReceived = 0;
  int artworkReceived = 0;
  int artworkErrors = 0;
  Uint8List? receivedFanart;
  String receivedFanartArtist = '';
  String _sentFanartArtist = '';
  String _currentSenderArtist = '';
  int _sentFanartHash = 0;
  int _fanartGeneration = 0;

  static const MethodChannel _direct = MethodChannel('vybe/direct');
  bool directAvailable = false;
  bool directActive = false;
  String directStatus = 'Not started';
  List<Map<String, String>> directPeers = [];
  bool _directRegistered = false;

  Future<void> directInitialize() async {
    if (!_directRegistered) {
      _directRegistered = true;
      _direct.setMethodCallHandler((call) async {
        if (call.method != 'event') return;
        final data = Map<String, dynamic>.from(call.arguments as Map);
        switch (data['type']) {
          case 'peers':
            directPeers = (data['items'] as List).map((e) => Map<String, String>.from(e as Map)).toList();
            directStatus = 'Found ${directPeers.length} nearby Wi-Fi Direct devices';
            break;
          case 'connected':
            final host = data['host']?.toString() ?? '';
            directStatus = 'Wi-Fi Direct group connected ($host)';
            // Refresh the newly created P2P interface address on the head unit.
            await _updateAddresses();
            if (role == 'sender' && host.isNotEmpty) {
              receiverAddress = host;
              // Reuse the existing TCP artwork transport over the new direct network.
              await connect();
            }
            break;
          case 'disconnected':
            directStatus = 'Wi-Fi Direct disconnected';
            break;
          case 'error':
            directStatus = data['message']?.toString() ?? 'Wi-Fi Direct error';
            break;
          case 'status':
            directStatus = data['message']?.toString() ?? 'Wi-Fi Direct in progress';
            break;
          case 'state':
            directStatus = data['enabled'] == true ? 'Wi-Fi Direct available' : 'Wi-Fi Direct disabled';
            break;
          case 'action':
            directStatus = '${data['name']} request ${data['ok'] == true ? 'accepted' : 'failed'}';
            break;
        }
        notifyListeners();
      });
    }
    try { directAvailable = await _direct.invokeMethod<bool>('available') ?? false; }
    catch (e) { directStatus = 'Wi-Fi Direct unavailable: $e'; }
    notifyListeners();
  }

  Future<void> directStart({required bool receiver}) async {
    await directInitialize();
    if (!directAvailable) { directStatus = 'Wi-Fi Direct not supported on this device'; notifyListeners(); return; }
    try {
      var ready = await _direct.invokeMethod<bool>('start') ?? false;
      if (!ready) {
        await _direct.invokeMethod('requestPermission');
        directStatus = 'Allow Nearby devices / Location, then tap again';
        notifyListeners(); return;
      }
      directActive = true;
      if (receiver) {
        if (role != 'receiver' || !enabled) await configure(isEnabled: true, deviceRole: 'receiver');
        directStatus = 'Requesting head-unit Wi-Fi Direct group...';
        notifyListeners();
        final accepted = await _direct.invokeMethod<bool>('host') ?? false;
        if (!accepted) directStatus = 'Cannot start Wi-Fi Direct on head unit (permission or service unavailable)';
      } else {
        if (role != 'sender' || !enabled) await configure(isEnabled: true, deviceRole: 'sender');
        directStatus = 'Scanning for Wi-Fi Direct devices...';
        notifyListeners();
        final accepted = await _direct.invokeMethod<bool>('discover') ?? false;
        if (!accepted) directStatus = 'Cannot start Wi-Fi Direct discovery (permission or service unavailable)';
      }
    } catch (e) { directStatus = 'Wi-Fi Direct setup failed: $e'; }
    notifyListeners();
  }

  Future<void> directConnectPeer(String address) async {
    try {
      final ok = await _direct.invokeMethod<bool>('connect', {'address': address}) ?? false;
      directStatus = ok ? 'Connecting to head unit...' : 'Device no longer in nearby list';
    } catch (e) { directStatus = 'Direct connection failed: $e'; }
    notifyListeners();
  }

  int _generation = 0;

  Future<void> initialize(NowPlayingModel model) async {
    if (_initialized) {
      if (!identical(_model, model)) {
        _model?.removeListener(_onModel);
        _model = model;
        model.addListener(_onModel);
      }
      onResumed();
      return;
    }
    _initialized = true;
    _model = model;
    final p = await SharedPreferences.getInstance();
    enabled = p.getBool('link_enabled') ?? false;
    role = p.getString('link_role') ?? 'sender';
    autoConnect = p.getBool('link_auto') ?? true;
    receiverAddress = (p.getString('link_address') ?? '').trim();
    pairedReceiverId = p.getString('link_paired_receiver') ?? '';
    localDeviceId = p.getString('link_device_id') ?? '';
    if (localDeviceId.isEmpty) {
      final random = Random.secure();
      localDeviceId = List<int>.generate(16, (_) => random.nextInt(256))
          .map((value) => value.toRadixString(16).padLeft(2, '0')).join();
      await p.setString('link_device_id', localDeviceId);
    }
    model.addListener(_onModel);
    await directInitialize();
    await _updateAddresses();
    if (enabled && autoConnect) await connect();
    // Android/network transitions may not generate a socket close event.
    // Periodically recover a missing connection without user interaction.
    _connectionWatchdog?.cancel();
    _connectionWatchdog = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!enabled || !autoConnect || _connecting || _retry?.isActive == true) return;
      if (role == 'sender' && _socket == null) connect();
      if (role == 'receiver' && _server == null) connect();
    });
    notifyListeners();
  }

  /// Run discovery only when pairing is requested or a trusted receiver's
  /// saved IP stops working. No IP entry is needed for first-time pairing.
  Future<void> findReceivers() async {
    if (searchingReceivers) return;
    searchingReceivers = true;
    status = 'Searching for nearby VYBE receivers...';
    notifyListeners();
    final results = await LinkDiscovery.scan();
    receivers = results;
    searchingReceivers = false;
    status = results.isEmpty ? 'No VYBE receiver found on this network'
        : 'Found ${results.length} VYBE receiver(s)';
    notifyListeners();
  }

  Future<void> pairReceiver(LinkReceiver receiver) async {
    pairedReceiverId = receiver.id;
    receiverAddress = receiver.address;
    enabled = true;
    autoConnect = true;
    final p = await SharedPreferences.getInstance();
    await p.setString('link_paired_receiver', pairedReceiverId);
    // Do not route pairing through configure(address:): it intentionally
    // clears the saved receiver identity for manual IP changes.
    await configure(isEnabled: true, deviceRole: 'sender', automatic: true);
  }

  /// Called when the UI returns from another app. Background reconnect is
  /// best-effort: Android can suspend this Flutter process.
  void onResumed() {
    if (!enabled || !autoConnect) return;
    if (_connecting) return;
    if (role == 'receiver' && _server == null) { connect(); return; }
    if (role == 'sender' && _socket == null) connect();
  }

  // Apply UI changes synchronously. Network and disk operations must never
  // delay the visual state of a switch or device-role control.
  Future<void> configure({bool? isEnabled, String? deviceRole, bool? automatic, String? address}) async {
    final endpointChanged = (isEnabled != null && isEnabled != enabled) ||
        (deviceRole != null && deviceRole != role) ||
        (address != null && address.trim() != receiverAddress);
    if (isEnabled != null) enabled = isEnabled;
    if (deviceRole != null && (deviceRole == 'sender' || deviceRole == 'receiver')) role = deviceRole;
    if (automatic != null) autoConnect = automatic;
    if (address != null) {
      final requested = address.trim();
      if (requested != receiverAddress) {
        pairedReceiverId = ''; // Manual new IP means explicitly pairing again.
      }
      receiverAddress = requested;
    }
    status = enabled ? 'Applying connection settings...' : 'Disabled';
    notifyListeners();
    // Start reconfiguration immediately, but do not hold UI updates hostage
    // to the socket teardown or an unreachable receiver.
    final connection = !endpointChanged && enabled &&
        ((role == 'sender' && _socket != null) ||
         (role == 'receiver' && _server != null))
        ? Future<void>.value() : connect();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('link_enabled', enabled);
      await p.setString('link_role', role);
      await p.setBool('link_auto', autoConnect);
      await p.setString('link_address', receiverAddress);
      await p.setString('link_paired_receiver', pairedReceiverId);
    } catch (e) {
      status = 'Could not save settings: $e';
      notifyListeners();
    }
    await connection;
  }

  Future<void> _updateAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      localAddresses = interfaces.expand((i) => i.addresses)
          .where((a) => !a.isLoopback).map((a) => a.address).join(', ');
    } catch (_) { localAddresses = 'Unavailable'; }
  }

  /// Restore the proven direct TCP path: manual IP connections send
  /// metadata immediately. Receiver identity is learned asynchronously,
  /// never used as a precondition for playing music.
  Future<void> connect() async {
    if (_connecting) return;
    _connecting = true;
    try {
    await _connectInternal();
    } finally {
      _connecting = false;
    }
  }

  Future<void> _connectInternal() async {
    final generation = ++_generation;
    _retry?.cancel(); _retry = null;
    _sendTimer?.cancel(); _sendTimer = null;
    _helloTimer?.cancel(); _helloTimer = null;
    await _socketSub?.cancel(); _socketSub = null;
    await _responder?.close(); _responder = null;
    _socket?.destroy(); _socket = null;
    await _server?.close(); _server = null;
    _lastPayload = ''; _lastTrack = ''; _lastArtHash = 0;
    _artGeneration++; _rxGeneration++;
    _sentFanartArtist = ''; _currentSenderArtist = '';
    _sentFanartHash = 0; _fanartGeneration++;
    receivedFanart = null; receivedFanartArtist = '';
    _lastMetadataSentAt = 0; _lastMetadataState = '';

    // The sender must never clear its own media playback. A receiver retains
    // the current song briefly while the TCP session is being recovered.
    if (role != 'receiver' || !enabled) {
      _model?.setLinkReceiverActive(false, immediate: true);
    } else {
      _model?.setLinkReceiverActive(false);
    }
    await _updateAddresses();
    if (generation != _generation) return;
    if (!enabled) { status = 'Disabled'; notifyListeners(); return; }

    if (role == 'receiver') {
      try {
        final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        if (generation != _generation) { await server.close(); return; }
        _server = server;
        // Discovery must not interfere with accepting a manually entered IP.
        try {
          _responder = await LinkDiscoveryResponder.start(localDeviceId);
        } catch (_) {
          _responder = null;
        }
        if (generation != _generation) {
          await _responder?.close(); _responder = null;
          await server.close();
          return;
        }
        status = 'Listening on ${localAddresses.isEmpty ? "no network IP detected" : localAddresses}:$port';
        notifyListeners();
        server.listen((client) {
          if (generation != _generation || role != 'receiver' || !enabled) {
            client.destroy(); return;
          }
          _socketSub?.cancel();
          _socket?.destroy();
          _socket = client;
          status = 'Connected to ${client.remoteAddress.address}';
          _model?.setLinkReceiverActive(true);
          notifyListeners();
          // Optional non-blocking identity message, useful for future
          // rediscovery but not required for metadata/artwork transfer.
          try {
            client.writeln(jsonEncode({'v': 2, 'kind': 'hello', 'id': localDeviceId}));
          } catch (_) {}
          final lines = client.cast<List<int>>()
              .transform(utf8.decoder).transform(const LineSplitter());
          _socketSub = lines.listen(
            _receive,
            onError: (_) => _receiverDisconnected(client),
            onDone: () => _receiverDisconnected(client),
            cancelOnError: true,
          );
        });
      } catch (e) {
        if (generation == _generation) {
          status = 'Cannot listen for connections: $e';
          notifyListeners();
          if (autoConnect) {
            _retry?.cancel();
            _retry = Timer(const Duration(seconds: 8), () {
              if (generation == _generation && _server == null) connect();
            });
          }
        }
      }
      return;
    }

    // Previously entered IP is always tried FIRST. Discovery is only a
    // fallback when that address stops working and a receiver was paired.
    Socket? socket;
    String address = receiverAddress;
    if (address.isNotEmpty) {
      try {
        socket = await Socket.connect(
          address, port, timeout: const Duration(seconds: 4));
      } catch (_) {}
    }
    if (generation != _generation) { socket?.destroy(); return; }

    if (socket == null && pairedReceiverId.isNotEmpty) {
      status = 'Retrying paired receiver discovery...';
      notifyListeners();
      try {
        final devices = await LinkDiscovery.scan();
        if (generation != _generation) return;
        for (final device in devices) {
          if (device.id != pairedReceiverId) continue;
          address = device.address;
          try {
            socket = await Socket.connect(
              address, port, timeout: const Duration(seconds: 4));
          } catch (_) {}
          break;
        }
      } catch (_) {}
    }
    if (generation != _generation) { socket?.destroy(); return; }
    if (socket == null) {
      status = receiverAddress.isEmpty && pairedReceiverId.isEmpty
          ? 'Enter the head-unit IP address to connect'
          : 'Unable to reach head unit at ${receiverAddress.isEmpty ? "saved network" : receiverAddress}:$port';
      notifyListeners();
      _scheduleRetry(generation);
      return;
    }

    _socket = socket;
    receiverAddress = address;
    // A working manual-IP connection is a valid pairing even when UDP
    // discovery or the optional receiver hello is blocked by the head unit.
    // Save it immediately instead of relying on the hello callback.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('link_enabled', true);
      await prefs.setBool('link_auto', true);
      await prefs.setString('link_role', 'sender');
      await prefs.setString('link_address', address);
      autoConnect = true;
    } catch (e) {
      debugPrint('VYBE Link failed to persist working receiver IP: $e');
    }
    if (generation != _generation || !identical(socket, _socket)) return;
    status = 'Connected to $address';
    notifyListeners();
    // The original working method transmitted immediately upon TCP connect.
    // Do not wait for a hello packet, which could prevent all song data.
    final peer = socket;
    final lines = peer.cast<List<int>>()
        .transform(utf8.decoder).transform(const LineSplitter());
    _socketSub = lines.listen((line) {
      if (!identical(_socket, peer) || generation != _generation) return;
      try {
        final data = jsonDecode(line);
        if (data is! Map || data['kind'] != 'hello' || data['v'] != 2) return;
        final id = (data['id'] as String?) ?? '';
        if (id.length < 16 || id.length > 128) return;
        if (pairedReceiverId.isNotEmpty && pairedReceiverId != id) {
          status = 'Connected IP belongs to a different receiver';
          notifyListeners();
          peer.destroy();
          _senderDisconnected(peer);
          return;
        }
        pairedReceiverId = id;
        SharedPreferences.getInstance().then((p) async {
          await p.setString('link_address', address);
          await p.setString('link_paired_receiver', id);
        }).catchError((Object e) {
          debugPrint('VYBE Link could not remember receiver: $e');
        });
      } catch (_) {}
    }, onDone: () => _senderDisconnected(peer),
        onError: (_) => _senderDisconnected(peer), cancelOnError: true);
    _sendTimer = Timer.periodic(const Duration(seconds: 2), (_) => _send());
    _send();
  }

  void _receiverDisconnected(Socket client) {
    if (!identical(client, _socket)) return;
    _socket = null; _model?.setLinkReceiverActive(false);
    status = 'Waiting for sender'; notifyListeners();
  }
  void _senderDisconnected(Socket client) {
    if (!identical(client, _socket)) return;
    _socket = null; _sendTimer?.cancel(); _sendTimer = null;
    _helloTimer?.cancel(); _helloTimer = null;
    status = 'Connection lost; retrying saved IP...';
    notifyListeners(); _scheduleRetry(_generation);
  }
  void _scheduleRetry(int generation) {
    if (!enabled || !autoConnect || role != 'sender') return;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 8), () {
      if (generation == _generation) connect();
    });
  }
  void _onModel() { if (enabled && role == 'sender') _send(); }

  // Metadata is never blocked by artwork encoding or a network artwork lookup.
  // Playback position is interpolated locally by NowPlayingModel, so don't
  // transmit position updates on every model notification.
  void _send() {
    final socket = _socket, model = _model;
    if (socket == null || model == null || !enabled || role != 'sender') return;
    final track = '${model.title}|${model.artist}|${model.album}';
    final changed = track != _lastTrack;
    if (changed) { _lastTrack = track; _lastArtHash = 0; _artGeneration++; }
    // Limit timestamp-only changes to one send every 2 seconds. Flutter
    // visualizer/album updates can notify many times per second and used to
    // generate a new JSON packet on every notification.
    final now = DateTime.now().millisecondsSinceEpoch;
    final state = '${model.active}|${model.playing}';
    if (changed || state != _lastMetadataState ||
        now - _lastMetadataSentAt >= 2000) {
      final payload = jsonEncode({
        'v': 2, 'kind': 'meta', 'track': track,
        'title': model.title, 'artist': model.artist, 'album': model.album,
        'playing': model.playing, 'active': model.active,
        'duration': model.durationMs, 'position': model.positionMs,
      });
      if (payload != _lastPayload) {
        try {
          socket.write('$payload\n');
          _lastPayload = payload;
          _lastMetadataSentAt = now;
          _lastMetadataState = state;
        } catch (_) { _senderDisconnected(socket); return; }
      }
    }
    final art = model.art?.bytes;
    if (art == null || art.isEmpty) return;
    final hash = Object.hash(art.length, art.length > 16 ? art[8] : 0,
        art.length > 64 ? art[64] : 0, art.last);
    if (hash == _lastArtHash) return;
    _lastArtHash = hash;
    final token = ++_artGeneration;
    _sendArtwork(socket, track, art, token);
  }

  Future<void> _sendArtwork(Socket socket, String track, Uint8List bytes, int token) async {
    try {
      // Decode and downscale on the sender, rather than asking the A5L to
      // decode a multi-megabyte original. PNG encoding is supported by Flutter.
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 320);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose(); codec.dispose();
      if (data == null || token != _artGeneration || !identical(socket, _socket) || track != _lastTrack) return;
      final compressed = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      // Cap line size to protect low-RAM receivers; report failures rather
      // than silently sending a missing-art payload.
      if (compressed.length > 950000) { artworkStatus = 'Artwork too large after resize'; notifyListeners(); return; }
      socket.write('${jsonEncode({'v': 2, 'kind': 'art', 'track': track, 'art': base64Encode(compressed)})}\n');
    } catch (e) { artworkStatus = 'Sender artwork error: $e'; notifyListeners(); }
  }

  /// Invalidate older artist encodes even while the new image downloads.
  void setFanartArtist(String artist) {
    if (role != 'sender' || !enabled || _currentSenderArtist == artist) return;
    _currentSenderArtist = artist;
    _sentFanartArtist = '';
    _sentFanartHash = 0;
    ++_fanartGeneration;
  }

  void sendFanart(String artist, Uint8List? bytes) {
    final socket = _socket;
    if (artist != _currentSenderArtist) return;
    if (socket == null || !enabled || role != 'sender' || artist.isEmpty) return;
    if (bytes == null || bytes.isEmpty) return;
    final hash = Object.hash(bytes.length, bytes[0], bytes[bytes.length ~/ 2], bytes.last);
    if (_sentFanartArtist == artist && _sentFanartHash == hash) return;
    _sentFanartArtist = artist; _sentFanartHash = hash;
    final token = ++_fanartGeneration;
    () async {
      try {
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: 480);
        final frame = await codec.getNextFrame();
        final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
        frame.image.dispose(); codec.dispose();
        if (data == null || token != _fanartGeneration || !identical(socket, _socket)) return;
        final compact = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        if (compact.length > 950000) return;
        socket.write('${jsonEncode({'v': 2, 'kind': 'fanart', 'artist': artist, 'art': base64Encode(compact)})}\n');
      } catch (e) { artworkStatus = 'Fanart transfer error: $e'; notifyListeners(); }
    }();
  }

  // Socket data is ordered, but asynchronous artwork decoding must not allow
  // an older cover to overwrite a newly selected track.
  void _receive(String line) {
    if (!enabled || role != 'receiver' || line.length > 1600000) return;
    try {
      final data = jsonDecode(line);
      if (data is! Map || data['v'] != 2) return;
      final track = data['track'] is String ? data['track'] as String : '';
      if (data['kind'] == 'meta') {
        final changed = track != lastReceivedTrack;
        if (changed) { lastReceivedTrack = track; artworkStatus = 'Waiting for sender artwork'; _rxGeneration++; }
        final incomingArtist = data['artist'] is String ? data['artist'] as String : '';
        if (incomingArtist != receivedFanartArtist) {
          receivedFanart = null; receivedFanartArtist = incomingArtist; notifyListeners();
        }
        metadataReceived++;
        _model?.applyLinkMetadata(
          titleValue: data['title'] is String ? data['title'] : '',
          artistValue: data['artist'] is String ? data['artist'] : '',
          albumValue: data['album'] is String ? data['album'] : '',
          isPlaying: data['playing'] == true,
          isActive: data['active'] == true,
          duration: (data['duration'] as num?)?.toInt() ?? 0,
          position: (data['position'] as num?)?.toInt() ?? 0,
        );
        if (changed) notifyListeners();
      } else if (data['kind'] == 'fanart' && data['art'] is String &&
          data['artist'] == receivedFanartArtist) {
        try {
          receivedFanart = base64Decode(data['art'] as String);
          notifyListeners();
        } catch (_) { artworkErrors++; }
      } else if (data['kind'] == 'art' && track == lastReceivedTrack && data['art'] is String) {
        try {
          final bytes = base64Decode(data['art'] as String);
          if (track != lastReceivedTrack) return;
          _model?.applyLinkArtwork(bytes);
          artworkReceived++;
          artworkStatus = 'Received (${(bytes.length / 1024).round()} KB)';
          notifyListeners();
        } catch (_) { artworkErrors++; artworkStatus = 'Artwork decode failed'; notifyListeners(); }
      }
    } catch (_) { artworkErrors++; notifyListeners(); }
  }
  Future<void> stop() async { await configure(isEnabled: false); }
  @override
  void dispose() {
    _retry?.cancel(); _connectionWatchdog?.cancel();
    _sendTimer?.cancel(); _helloTimer?.cancel();
    _model?.removeListener(_onModel);
    _socketSub?.cancel(); _socket?.destroy(); _server?.close();
    _responder?.close();
    super.dispose();
  }
}
