import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'now_playing_model.dart';

/// Local-network beta: receiver hosts a TCP socket; sender connects by IP.
/// Does not claim to create Wi-Fi Direct groups or share Android Auto's network.
class VybeLink extends ChangeNotifier {
  VybeLink._();
  static final VybeLink instance = VybeLink._();
  static const port = 38927;
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
        await _direct.invokeMethod('host');
        directStatus = 'Creating head-unit Wi-Fi Direct group';
      } else {
        if (role != 'sender' || !enabled) await configure(isEnabled: true, deviceRole: 'sender');
        await _direct.invokeMethod('discover');
        directStatus = 'Searching for head unit';
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
    _model = model;
    final p = await SharedPreferences.getInstance();
    enabled = p.getBool('link_enabled') ?? false;
    role = p.getString('link_role') ?? 'sender';
    autoConnect = p.getBool('link_auto') ?? true;
    receiverAddress = p.getString('link_address') ?? '';
    model.addListener(_onModel);
    await directInitialize();
    await _updateAddresses();
    if (enabled && autoConnect) await connect();
    notifyListeners();
  }

  // Apply UI changes synchronously. Network and disk operations must never
  // delay the visual state of a switch or device-role control.
  Future<void> configure({bool? isEnabled, String? deviceRole, bool? automatic, String? address}) async {
    if (isEnabled != null) enabled = isEnabled;
    if (deviceRole != null && (deviceRole == 'sender' || deviceRole == 'receiver')) role = deviceRole;
    if (automatic != null) autoConnect = automatic;
    if (address != null) receiverAddress = address.trim();
    status = enabled ? 'Applying connection settings...' : 'Disabled';
    notifyListeners();
    // Start reconfiguration immediately, but do not hold UI updates hostage
    // to the socket teardown or an unreachable receiver.
    final connection = connect();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('link_enabled', enabled);
      await p.setString('link_role', role);
      await p.setBool('link_auto', autoConnect);
      await p.setString('link_address', receiverAddress);
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

  Future<void> connect() async {
    _generation++;
    final generation = _generation;
    _retry?.cancel(); _sendTimer?.cancel();
    await _socketSub?.cancel(); _socketSub = null;
    _socket?.destroy(); _socket = null;
    await _server?.close(); _server = null;
    _lastPayload = ''; _lastTrack = ''; _lastArtHash = 0; _artGeneration++; _rxGeneration++;
    _model?.setLinkReceiverActive(false);
    await _updateAddresses();
    if (generation != _generation) return;
    if (!enabled) { status = 'Disabled'; notifyListeners(); return; }
    if (role == 'receiver') {
      try {
        _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        if (generation != _generation) { await _server?.close(); return; }
        status = 'Listening on $localAddresses:$port'; notifyListeners();
        _server!.listen((client) {
          _socket?.destroy(); _socket = client;
          status = 'Connected to ${client.remoteAddress.address}';
          _model?.setLinkReceiverActive(true);
          notifyListeners();
          final lines = client.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());
          _socketSub = lines.listen(_receive, onError: (_) => _receiverDisconnected(client),
              onDone: () => _receiverDisconnected(client));
        });
      } catch (e) { status = 'Cannot listen: $e'; notifyListeners(); }
    } else {
      if (receiverAddress.isEmpty) {
        status = 'Enter the receiver IP address'; notifyListeners(); return;
      }
      try {
        final socket = await Socket.connect(receiverAddress, port, timeout: const Duration(seconds: 4));
        if (generation != _generation) { socket.destroy(); return; }
        _socket = socket;
        status = 'Connected to $receiverAddress'; notifyListeners();
        socket.listen((_) {}, onDone: () => _senderDisconnected(socket),
            onError: (_) => _senderDisconnected(socket), cancelOnError: true);
        _sendTimer = Timer.periodic(const Duration(seconds: 8), (_) => _send());
        _send();
      } catch (e) {
        status = 'Connection failed: $e'; notifyListeners(); _scheduleRetry(generation);
      }
    }
  }

  void _receiverDisconnected(Socket client) {
    if (!identical(client, _socket)) return;
    _socket = null; _model?.setLinkReceiverActive(false);
    status = 'Waiting for sender'; notifyListeners();
  }
  void _senderDisconnected(Socket client) {
    if (!identical(client, _socket)) return;
    _socket = null; _sendTimer?.cancel();
    status = 'Disconnected'; notifyListeners(); _scheduleRetry(_generation);
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
    final payload = jsonEncode({
      'v': 2, 'kind': 'meta', 'track': track,
      'title': model.title, 'artist': model.artist, 'album': model.album,
      'playing': model.playing, 'active': model.active,
      'duration': model.durationMs, 'position': model.positionMs,
    });
    if (payload != _lastPayload) {
      _lastPayload = payload;
      try { socket.write('$payload\n'); } catch (_) { _senderDisconnected(socket); return; }
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
    _retry?.cancel(); _sendTimer?.cancel();
    _model?.removeListener(_onModel);
    _socketSub?.cancel(); _socket?.destroy(); _server?.close();
    super.dispose();
  }
}
