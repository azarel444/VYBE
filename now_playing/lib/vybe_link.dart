import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
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
  int _generation = 0;

  Future<void> initialize(NowPlayingModel model) async {
    _model = model;
    final p = await SharedPreferences.getInstance();
    enabled = p.getBool('link_enabled') ?? false;
    role = p.getString('link_role') ?? 'sender';
    autoConnect = p.getBool('link_auto') ?? true;
    receiverAddress = p.getString('link_address') ?? '';
    model.addListener(_onModel);
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
    _lastPayload = '';
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
        _sendTimer = Timer.periodic(const Duration(seconds: 2), (_) => _send());
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
  void _send() {
    final socket = _socket, model = _model;
    if (socket == null || model == null || !enabled || role != 'sender') return;
    final art = model.art?.bytes;
    // 1 MB encoded limit to avoid flooding low-memory Android head units.
    final encoded = art != null && art.length <= 750000 ? base64Encode(art) : null;
    final payload = jsonEncode({
      'v': 1, 'title': model.title, 'artist': model.artist, 'album': model.album,
      'playing': model.playing, 'active': model.active,
      'duration': model.durationMs, 'position': model.positionMs,
      'art': encoded,
    });
    if (payload == _lastPayload) return;
    _lastPayload = payload;
    try { socket.write('$payload\n'); } catch (_) { _senderDisconnected(socket); }
  }
  void _receive(String line) {
    if (!enabled || role != 'receiver' || line.length > 1500000) return;
    try {
      final data = jsonDecode(line);
      if (data is! Map || data['v'] != 1) return;
      Uint8List? art;
      if (data['art'] is String) art = base64Decode(data['art'] as String);
      _model?.applyLinkMetadata(
        titleValue: data['title'] is String ? data['title'] : '',
        artistValue: data['artist'] is String ? data['artist'] : '',
        albumValue: data['album'] is String ? data['album'] : '',
        isPlaying: data['playing'] == true,
        isActive: data['active'] == true,
        duration: (data['duration'] as num?)?.toInt() ?? 0,
        position: (data['position'] as num?)?.toInt() ?? 0,
        artwork: art,
      );
    } catch (_) {}
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
