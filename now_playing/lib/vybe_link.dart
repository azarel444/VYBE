import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'native_preferences.dart';
import 'now_playing_model.dart';
import 'vybe_link_discovery.dart';
import 'local_artwork.dart';
import 'vybe_link_artist_art_cache.dart';

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
  String discoveryStatus = 'Not checked';
  LinkDiscoveryResponder? _responder;
  bool _startingResponder = false;
  int _lastResponderAttemptMs = 0;
  Timer? _helloTimer;
  int _lastMetadataSentAt = 0;
  String _lastMetadataState = '';
  bool enabled = false;
  String role = 'sender';
  String deviceType = 'phone';
  bool autoConnect = true;
  String receiverAddress = '';
  String status = 'Disabled';
  String localAddresses = '';
  // USB tethering is an ordinary point-to-point IPv4 LAN. Prefer it for
  // stability when detected; Wi-Fi Direct and shared Wi-Fi remain fallback.
  static const MethodChannel _wired = MethodChannel('vybe/wired');
  // USB tether mode disabled while VYBE prioritizes Wi-Fi Direct.
  bool preferWired = false;
  bool wiredAvailable = false;
  String wiredStatus = 'No USB tethering network detected';
  String activeTransport = 'Disconnected';

  // Android-wide Bluetooth audio source integration. No OEM package names
  // are hardcoded. The user selects a media session discovered on the head
  // unit; Android decides whether that session can start Bluetooth playback.
  static const MethodChannel _bluetoothAudio =
      MethodChannel('vybe/bluetooth_audio');
  static const MethodChannel _audioProbe = MethodChannel('vybe/audio_probe');
  static const MethodChannel _wifiAudio = MethodChannel('vybe/wifi_audio');
  String wifiStreamSenderStatus = 'off';
  String wifiStreamReceiverStatus = 'off';
  String wifiStreamSenderDetail = '';
  String wifiStreamReceiverDetail = '';
  String wifiStreamSenderIp = '';
  String wifiStreamExpectedPhoneIp = '';
  String wifiStreamObservedPhoneIp = '';
  String wifiStreamOutputRoute = '';
  String wifiStreamToneStatus = 'Not tested';
  int wifiStreamSentBytes = 0;
  int wifiStreamSenderPeak = 0;
  int wifiStreamReceivedBytes = 0;
  int wifiStreamPlayedBytes = 0;
  int wifiStreamReceiverPeak = 0;
  int wifiStreamConnections = 0;
  int wifiStreamRejected = 0;
  int wifiStreamMusicVolume = 0;
  int wifiStreamMusicMaxVolume = 0;
  bool wifiStreamMusicActive = false;
  bool _wifiSenderRequested = false;
  bool _wifiReceiverRequested = false;

  bool get wifiAudioPeerConnected => enabled && _socket != null;
  bool get wifiAudioStreamingSupported => enabled && _socket != null &&
      (role == 'sender' || role == 'receiver');
  String wifiAudioProbeStatus = 'Not tested';
  String wifiAudioProbeDetails = 'Run a test while a music player is active.';
  int wifiAudioProbePeak = 0;
  double wifiAudioProbeRms = 0;
  double wifiAudioProbeSignalFraction = 0;
  int wifiAudioProbeSamples = 0;
  bool _wifiAudioProbeBusy = false;
  String bluetoothSourcePackage = '';
  bool bluetoothAutoResume = false;
  List<Map<String, dynamic>> bluetoothSources = <Map<String, dynamic>>[];
  String bluetoothSourceStatus = 'Not checked';
  String bluetoothDeviceDiagnostics = '';
  bool bluetoothSessionAccess = false;
  bool _bluetoothRequestBusy = false;
  bool _remoteWasPlaying = false;
  int _lastBluetoothAutoMs = 0;

  List<String> _wiredAddresses = <String>[];
  String _savedWiredReceiverIp = '';
  bool _tcpConnectedViaWired = false;
  bool _wiredRefreshing = false;
  bool _wiredUpgradeBusy = false;
  int _lastWiredUpgradeMs = 0;
  int _wiredWatchdogTicks = 0;
  ServerSocket? _server;
  Socket? _socket;
  StreamSubscription? _socketSub;
  Timer? _retry;
  Timer? _connectionWatchdog;
  Timer? _heartbeat;
  int _lastPeerResponse = 0;
  String _localCoverTrack = '';
  bool _localCoverAvailable = false;
  bool _connecting = false;
  bool _connectPending = false;
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
  Uint8List? receivedClearLogo;
  String receivedClearLogoArtist = '';
  String _sentClearLogoArtist = '';
  int _sentClearLogoHash = 0;
  int _clearLogoGeneration = 0;
  String _encodingClearLogoArtist = '';
  int _encodingClearLogoHash = 0;
  Timer? _clearLogoAckTimer;

  static const MethodChannel _direct = MethodChannel('vybe/direct');
  bool directAvailable = false;
  bool directActive = false;
  String directStatus = 'Not started';
  List<Map<String, String>> directPeers = [];
  bool _directRegistered = false;
  // Remember that Wi-Fi Direct was actually chosen, not just that TCP auto
  // reconnect is enabled. They are different network layers.
  bool _directPreferred = false;
  String _savedDirectPeerAddress = '';
  String _savedDirectPeerName = '';
  bool _directGroupConnected = false;
  String _directGroupOwnerIp = '';
  bool _tcpConnectedViaDirect = false;
  bool _directRecoveryBusy = false;
  int _lastDirectRecoveryMs = 0;
  int _lastDirectPeerAttemptMs = 0;
  Timer? _directRecoveryTimer;

  /// Restore the head-unit's Direct group or discover the previously paired
  /// Wi-Fi Direct MAC. Only called when TCP is disconnected; never tears down
  /// a working socket, hotspot or manually established LAN connection.
  Future<void> _recoverDirect({bool immediately = false}) async {
    if (!enabled || !autoConnect || !_directPreferred || !directAvailable ||
        _directRecoveryBusy || _directGroupConnected ||
        (activeTransport == 'USB tethering' && _socket != null) ||
        (role == 'sender' && _socket != null)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!immediately && now - _lastDirectRecoveryMs < 10000) return;
    _lastDirectRecoveryMs = now;
    _directRecoveryBusy = true;
    try {
      // Existing OS permission only. Never pop a permission dialog during
      // background recovery; manual setup remains available if needed.
      final started = await _direct.invokeMethod<bool>('start') ?? false;
      if (!started) {
        directStatus = 'Wi-Fi Direct permission or service unavailable';
        notifyListeners();
        return;
      }
      directActive = true;
      if (role == 'receiver') {
        directStatus = 'Restoring head-unit Wi-Fi Direct group...';
        await _direct.invokeMethod<bool>('host');
      } else if (role == 'sender') {
        directStatus = 'Searching for saved head unit over Wi-Fi Direct...';
        await _direct.invokeMethod<bool>('discover');
      }
      notifyListeners();
    } catch (error) {
      directStatus = 'Wi-Fi Direct recovery: $error';
      notifyListeners();
    } finally {
      _directRecoveryBusy = false;
    }
  }

  void _trySavedDirectPeer() {
    if (!enabled || !autoConnect || !_directPreferred ||
        role != 'sender' || _socket != null || _directGroupConnected ||
        _savedDirectPeerAddress.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastDirectPeerAttemptMs < 12000) return;
    // Android may rotate Wi-Fi Direct device addresses after a network reset.
    // Prefer the saved address, or the unique saved device name when the
    // address has rotated. Never guess among multiple matching devices.
    Map<String, String>? peer;
    for (final item in directPeers) {
      if (item['address'] == _savedDirectPeerAddress) {
        peer = item;
        break;
      }
    }
    if (peer == null && _savedDirectPeerName.isNotEmpty) {
      final candidates = directPeers.where((item) =>
          item['name'] == _savedDirectPeerName).toList();
      if (candidates.length == 1) peer = candidates.single;
    }
    final address = peer?['address'];
    if (address == null || address.isEmpty) return;
    _lastDirectPeerAttemptMs = now;
    unawaited(directConnectPeer(address, remember: true));
  }

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
            _trySavedDirectPeer();
            break;
          case 'connected':
            final host = data['host']?.toString() ?? '';
            _directGroupConnected = true;
            _directGroupOwnerIp = host;
            directActive = true;
            directStatus = 'Wi-Fi Direct connected; receiver address resolved automatically';
            // The Android Wi-Fi Direct API supplies groupOwnerAddress.
            // NEVER ask the user for an IP or hardcode one for all networks.
            await _updateAddresses();
            if (role == 'sender' && host.isNotEmpty && _socket == null) {
              // The Android group-owner IP is the preferred TCP target.
              // Never interrupt an already working LAN/hotspot socket just
              // because a duplicate Direct broadcast announces another IP.
              receiverAddress = host;
              unawaited(connect());
            }
            break;
          case 'disconnected':
            _directGroupConnected = false;
            _lastDirectPeerAttemptMs = 0;
            directStatus = 'Wi-Fi Direct disconnected; restoring automatically';
            // The underlying Direct link disappeared. A TCP Socket can stay
            // non-null for several seconds even though its route is dead.
            // Invalidate ONLY a socket actually using the Direct host; do
            // not disrupt a healthy shared-Wi-Fi or hotspot connection.
            if (role == 'sender' && _tcpConnectedViaDirect) {
              final disconnectedPeer = _socket;
              if (disconnectedPeer != null) {
                _senderDisconnected(disconnectedPeer);
                disconnectedPeer.destroy();
              }
            }
            // A TCP retry cannot recreate a lost P2P group. Recover the
            // underlying network separately, with a short settling delay.
            if (_directPreferred && enabled && autoConnect) {
              Future<void>.delayed(const Duration(seconds: 2), () {
                if (enabled && autoConnect && !_directGroupConnected) {
                  unawaited(_recoverDirect(immediately: true));
                }
              });
            }
            break;
          case 'error':
            directStatus = data['message']?.toString() ?? 'Wi-Fi Direct error';
            break;
          case 'status':
            directStatus = data['message']?.toString() ?? 'Wi-Fi Direct in progress';
            break;
          case 'state':
            if (data['enabled'] != true) _directGroupConnected = false;
            directStatus = data['enabled'] == true
                ? 'Wi-Fi Direct available' : 'Wi-Fi Direct disabled';
            if (data['enabled'] == true && _directPreferred && enabled && autoConnect) {
              unawaited(_recoverDirect(immediately: true));
            }
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
      _directPreferred = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('link_direct_preferred', true);
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

  Future<void> directConnectPeer(String address,
      {bool remember = true, bool manuallySelected = false}) async {
    if (address.isEmpty) return;
    try {
      final ok = await _direct.invokeMethod<bool>(
          'connect', {'address': address}) ?? false;
      directStatus = ok ? 'Connecting to head unit...' : 'Device no longer in nearby list';
      if (ok && remember) {
        // Save Wi-Fi Direct identity. The TCP IP is determined automatically
        // from Android's connection information every time a group forms.
        _savedDirectPeerAddress = address;
        final chosen = directPeers.where((item) =>
            item['address'] == address).toList();
        if (chosen.isNotEmpty) {
          _savedDirectPeerName = chosen.first['name'] ?? '';
        }
        _directPreferred = true;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('link_direct_peer', address);
        await prefs.setString('link_direct_peer_name', _savedDirectPeerName);
        await prefs.setBool('link_direct_preferred', true);
        if (manuallySelected) {
          // Explicit selection authorizes fresh pairing after the ATOTO was
          // reinstalled and generated a new VYBE receiver identity.
          // Automatic recovery must never discard the trusted receiver ID.
          pairedReceiverId = '';
          await prefs.setString('link_paired_receiver', '');
        }
      }
    } catch (e) { directStatus = 'Direct connection failed: $e'; }
    notifyListeners();
  }

  int _generation = 0;

  String? _wiredSourceFor(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return null;
    for (final local in _wiredAddresses) {
      final segment = local.split('.');
      if (segment.length == 4 &&
          segment[0] == parts[0] &&
          segment[1] == parts[1] &&
          segment[2] == parts[2] &&
          local != address) return local;
    }
    return null;
  }

  bool _isWiredDestination(String address) =>
      _wiredSourceFor(address) != null;

  List<LinkReceiver> _matchingReceivers(List<LinkReceiver> devices) {
    if (pairedReceiverId.isNotEmpty) {
      return devices.where((d) => d.id == pairedReceiverId).toList();
    }
    // Never guess which head unit should be paired when several answer.
    return devices.length == 1 ? devices : <LinkReceiver>[];
  }

  /// Refresh without interrupting a healthy connection. The OS exposes
  /// RNDIS/NCM/USB ethernet once tethering is active; a charging-only cable
  /// is not a valid network link.
  Future<void> refreshWired({bool reconnect = true}) async {
    if (_wiredRefreshing) return;
    _wiredRefreshing = true;
    try {
      final addresses = await LinkDiscovery.wiredAddresses();
      final changed = addresses.join('|') != _wiredAddresses.join('|');
      _wiredAddresses = addresses;
      wiredAvailable = addresses.isNotEmpty;
      if (!wiredAvailable) {
        wiredStatus = 'No USB tethering network detected';
      } else if (activeTransport == 'USB tethering' && _socket != null) {
        wiredStatus = 'Connected over USB';
      } else {
        wiredStatus = 'USB network detected: ${addresses.join(', ')}';
      }
      if (changed) notifyListeners();
      if (!changed || !reconnect || !enabled || !autoConnect ||
          role != 'sender') return;
      if (!wiredAvailable && _tcpConnectedViaWired) {
        // Network disappeared before TCP noticed: reconnect over Wi-Fi.
        final peer = _socket;
        if (peer != null) {
          _senderDisconnected(peer);
          peer.destroy();
        }
      } else if (wiredAvailable && preferWired) {
        if (_socket == null && !_connecting) {
          unawaited(connect());
        } else if (_socket != null && !_tcpConnectedViaWired) {
          // Verify the trusted receiver responds over USB before switching.
          unawaited(_upgradeToWired());
        }
      }
    } finally {
      _wiredRefreshing = false;
    }
  }

  Future<void> _upgradeToWired() async {
    if (_wiredUpgradeBusy || !enabled || !autoConnect || !preferWired ||
        !wiredAvailable || role != 'sender' || _tcpConnectedViaWired ||
        _socket == null || _connecting) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastWiredUpgradeMs < 15000) return;
    _lastWiredUpgradeMs = now;
    _wiredUpgradeBusy = true;
    try {
      for (final local in _wiredAddresses) {
        final devices = await LinkDiscovery.scan(
            sourceAddress: local,
            timeout: const Duration(milliseconds: 1100));
        final matching = _matchingReceivers(devices);
        if (matching.isEmpty || _socket == null || !wiredAvailable) continue;
        final candidate = matching.first.address;
        if (!_isWiredDestination(candidate)) continue;
        _savedWiredReceiverIp = candidate;
        wiredStatus = 'Paired head unit found over USB; switching';
        notifyListeners();
        // The exact receiver ID was confirmed by its UDP reply. Keep the
        // existing Wi-Fi session until this point, not at cable insertion.
        await connect();
        return;
      }
      wiredStatus = 'USB network found, but paired head unit not discovered';
      notifyListeners();
    } catch (error) {
      wiredStatus = 'USB discovery failed: $error';
      notifyListeners();
    } finally {
      _wiredUpgradeBusy = false;
    }
  }

  Future<void> setPreferWired(bool value) async {
    preferWired = value;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool('link_prefer_wired', value);
    if (value) await requestWiredConnection();
  }

  Future<void> requestWiredConnection() async {
    await refreshWired(reconnect: false);
    if (!enabled) {
      wiredStatus = 'Enable VYBE Connect to use USB';
      notifyListeners();
      return;
    }
    if (!wiredAvailable) {
      wiredStatus = 'Connect USB and enable USB tethering on the phone';
      notifyListeners();
      return;
    }
    if (role == 'receiver') {
      wiredStatus = activeTransport == 'USB tethering' && _socket != null
          ? 'Connected over USB'
          : (_server == null
              ? 'USB detected; starting receiver'
              : 'USB detected; listening for phone');
      notifyListeners();
      if (_server == null) await connect();
    } else if (_tcpConnectedViaWired && _socket != null) {
      wiredStatus = 'Connected over USB';
      notifyListeners();
    } else if (_socket != null) {
      // A manual Retry bypasses the normal automatic upgrade cooldown.
      _lastWiredUpgradeMs = 0;
      await _upgradeToWired();
    } else {
      await connect();
    }
  }

  Future<bool> openUsbTetheringSettings() async {
    try {
      return await _wired.invokeMethod<bool>('openTetherSettings') ?? false;
    } catch (error) {
      wiredStatus = 'Open Android Settings → Hotspot and tethering: $error';
      notifyListeners();
      return false;
    }
  }

  /// Initial raw-PCM prototype. A separate native TCP connection handles
  /// audio so artist metadata and artwork continue at their existing pace.
  /// This is opt-in and local-network plaintext until authenticated encrypted
  /// audio can be implemented; do not use on untrusted shared networks.
  Future<void> startWifiAudioStream() async {
    if (role != 'sender') return;
    final host = _socket?.remoteAddress.address;
    if (!enabled || host == null) {
      wifiStreamSenderStatus = 'error';
      wifiStreamSenderDetail = 'Connect VYBE to the head unit first';
      notifyListeners();
      return;
    }
    wifiStreamSenderStatus = 'requesting';
    wifiStreamSenderDetail = 'Android will ask permission to capture playback audio';
    notifyListeners();
    try {
      final result = await _wifiAudio.invokeMethod<dynamic>(
          'startSender', <String, dynamic>{'host': host});
      if (result is Map) {
        wifiStreamSenderStatus = result['state']?.toString() ?? 'unknown';
        wifiStreamSenderDetail = result['detail']?.toString() ?? '';
      }
      _wifiSenderRequested = wifiStreamSenderStatus == 'starting';
    } catch (error) {
      wifiStreamSenderStatus = 'error';
      wifiStreamSenderDetail = 'Could not start Wi-Fi audio: $error';
    }
    notifyListeners();
  }

  Future<void> startWifiAudioReceiver() async {
    if (role != 'receiver') return;
    final phoneIp = _socket?.remoteAddress.address;
    if (!enabled || phoneIp == null) {
      wifiStreamReceiverStatus = 'error';
      wifiStreamReceiverDetail = 'Connect the phone in VYBE Connect first';
      notifyListeners();
      return;
    }
    wifiStreamReceiverStatus = 'starting';
    wifiStreamReceiverDetail = 'Listening for audio from the connected VYBE phone';
    notifyListeners();
    try {
      final result = await _wifiAudio.invokeMethod<dynamic>(
          'startReceiver', <String, dynamic>{'allowedIp': phoneIp});
      if (result is Map) {
        wifiStreamReceiverStatus = result['state']?.toString() ?? 'unknown';
        wifiStreamReceiverDetail = result['detail']?.toString() ?? '';
      }
      _wifiReceiverRequested = wifiStreamReceiverStatus == 'starting';
    } catch (error) {
      wifiStreamReceiverStatus = 'error';
      wifiStreamReceiverDetail = 'Could not start Wi-Fi audio receiver: $error';
    }
    notifyListeners();
  }

  Future<void> stopWifiAudioStream() async {
    if (role != 'sender') return;
    _wifiSenderRequested = false;
    try { await _wifiAudio.invokeMethod<dynamic>('stopSender'); } catch (_) {}
    wifiStreamSenderStatus = 'stopped';
    wifiStreamSenderDetail = 'Wi-Fi audio stopped';
    notifyListeners();
  }

  Future<void> stopWifiAudioReceiver() async {
    if (role != 'receiver') return;
    _wifiReceiverRequested = false;
    try { await _wifiAudio.invokeMethod<dynamic>('stopReceiver'); } catch (_) {}
    wifiStreamReceiverStatus = 'stopped';
    wifiStreamReceiverDetail = 'Wi-Fi audio receiver stopped';
    notifyListeners();
  }

  Future<void> testHeadUnitAudioOutput() async {
    if (role != 'receiver') return;
    wifiStreamToneStatus = 'Starting Android output test...';
    notifyListeners();
    try {
      final response = await _wifiAudio.invokeMethod<dynamic>('testOutputTone');
      wifiStreamToneStatus = response is Map
          ? response['message']?.toString() ?? 'Started output test'
          : 'Started output test';
    } catch (error) {
      wifiStreamToneStatus = 'Android audio output test failed: $error';
    }
    notifyListeners();
  }

  Future<void> refreshWifiAudioStreamStatus() async {
    try {
      final result = await _wifiAudio.invokeMethod<dynamic>('status');
      if (result is! Map) throw StateError('No audio status returned');
      wifiStreamSenderStatus = result['sender']?.toString() ?? 'unknown';
      wifiStreamSenderDetail = result['senderDetail']?.toString() ?? '';
      wifiStreamReceiverStatus = result['receiver']?.toString() ?? 'unknown';
      wifiStreamReceiverDetail = result['receiverDetail']?.toString() ?? '';
      wifiStreamSenderIp = result['senderTargetIp']?.toString() ?? '';
      wifiStreamSentBytes = (result['senderBytes'] as num?)?.toInt() ?? 0;
      wifiStreamSenderPeak = (result['senderPeak'] as num?)?.toInt() ?? 0;
      wifiStreamExpectedPhoneIp = result['receiverExpectedIp']?.toString() ?? '';
      wifiStreamObservedPhoneIp = result['receiverPeerIp']?.toString() ?? '';
      wifiStreamReceivedBytes = (result['receiverBytes'] as num?)?.toInt() ?? 0;
      wifiStreamPlayedBytes = (result['receiverPlayedBytes'] as num?)?.toInt() ?? 0;
      wifiStreamReceiverPeak = (result['receiverPeak'] as num?)?.toInt() ?? 0;
      wifiStreamConnections = (result['receiverConnections'] as num?)?.toInt() ?? 0;
      wifiStreamRejected = (result['receiverRejected'] as num?)?.toInt() ?? 0;
      wifiStreamOutputRoute = result['receiverRoute']?.toString() ?? '';
      wifiStreamMusicVolume = (result['outputVolume'] as num?)?.toInt() ?? 0;
      wifiStreamMusicMaxVolume = (result['outputMaxVolume'] as num?)?.toInt() ?? 0;
      wifiStreamMusicActive = result['outputMusicActive'] == true;
      wifiStreamToneStatus = result['toneState']?.toString() ?? 'Not tested';
    } catch (error) {
      if (role == 'sender') {
        wifiStreamSenderStatus = 'error';
        wifiStreamSenderDetail = 'Audio diagnostic unavailable: $error';
      } else {
        wifiStreamReceiverStatus = 'error';
        wifiStreamReceiverDetail = 'Audio diagnostic unavailable: $error';
      }
    }
    notifyListeners();
  }

  /// Audio only: VYBE never stores or forwards PCM in this test. The Android
  /// projection permission request is explicit and applies to a single run.
  Future<void> startWifiAudioCaptureTest() async {
    if (role != 'sender' || _wifiAudioProbeBusy) return;
    _wifiAudioProbeBusy = true;
    wifiAudioProbeStatus = 'Requesting Android playback capture permission';
    notifyListeners();
    try {
      final result = await _audioProbe.invokeMethod<dynamic>('start');
      if (result is Map) {
        wifiAudioProbeStatus = result['state']?.toString() ?? 'unknown';
        wifiAudioProbeDetails = result['details']?.toString() ?? '';
      } else {
        wifiAudioProbeStatus = 'unknown';
        wifiAudioProbeDetails = 'Android did not return a test result';
      }
    } catch (error) {
      wifiAudioProbeStatus = 'error';
      wifiAudioProbeDetails = 'Cannot start playback capture: $error';
    } finally {
      _wifiAudioProbeBusy = false;
      notifyListeners();
    }
  }

  Future<void> refreshWifiAudioCaptureTest() async {
    if (role != 'sender') return;
    try {
      final result = await _audioProbe.invokeMethod<dynamic>('status');
      if (result is! Map) throw StateError('No capture report');
      wifiAudioProbeStatus = result['state']?.toString() ?? 'unknown';
      wifiAudioProbeDetails = result['details']?.toString() ?? '';
      wifiAudioProbePeak = (result['peak'] as num?)?.toInt() ?? 0;
      wifiAudioProbeRms = (result['rms'] as num?)?.toDouble() ?? 0;
      wifiAudioProbeSignalFraction =
          (result['signalFraction'] as num?)?.toDouble() ?? 0;
      wifiAudioProbeSamples = (result['samples'] as num?)?.toInt() ?? 0;
    } catch (error) {
      wifiAudioProbeStatus = 'error';
      wifiAudioProbeDetails = 'Cannot read playback capture report: $error';
    }
    notifyListeners();
  }

  /// The built-in Android media session API is device-agnostic. A visible
  /// session is necessary for the public PLAY command; a proprietary head
  /// unit may require privileges that an ordinary app does not possess.
  Future<void> scanBluetoothSources() async {
    if (role != 'receiver') return;
    bluetoothSourceStatus = 'Inspecting Android media sessions...';
    notifyListeners();
    try {
      final result = await _bluetoothAudio.invokeMethod<dynamic>('scan');
      if (result is! Map) throw StateError('No session information returned');
      final response = Map<String, dynamic>.from(result);
      bluetoothSessionAccess = response['access'] == true;
      final raw = response['sessions'];
      bluetoothSources = raw is List ? raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e)).toList()
          : <Map<String, dynamic>>[];
      bluetoothDeviceDiagnostics = 'Audio active: ${response['musicActive'] == true}; '
          'routes: ${(response['devices'] as List?)?.length ?? 0}';
      final details = response['message']?.toString() ?? 'No result';
      final selected = bluetoothSources.where(
          (s) => s['package'] == bluetoothSourcePackage);
      bluetoothSourceStatus = selected.isNotEmpty
          ? 'Selected source detected: ${selected.first['name']}'
          : details;
    } catch (error) {
      bluetoothSessionAccess = false;
      bluetoothSources = <Map<String, dynamic>>[];
      bluetoothSourceStatus = 'Android media session check failed: $error';
    }
    notifyListeners();
  }

  Future<void> selectBluetoothSource(String packageName) async {
    if (role != 'receiver') return;
    // A source can be selected only from the Android sessions that the user
    // inspected. Do not allow hardcoded/guessed OEM package identities.
    if (!bluetoothSources.any((s) => s['package'] == packageName)) return;
    bluetoothSourcePackage = packageName;
    bluetoothSourceStatus = 'Saved Android media source: $packageName';
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('link_bluetooth_source', packageName);
  }

  Future<void> setBluetoothAutoResume(bool selected) async {
    if (role != 'receiver') return;
    if (selected && bluetoothSourcePackage.isEmpty) {
      bluetoothSourceStatus = 'Select a detected Android media source first';
      notifyListeners();
      return;
    }
    bluetoothAutoResume = selected;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('link_bluetooth_auto_resume', selected);
  }

  /// A request is not proof that Bluetooth audio is routed to speakers.
  /// Never retry continuously, take audio focus, or launch an arbitrary app.
  Future<void> requestBluetoothSourcePlay({bool automatic = false}) async {
    if (role != 'receiver' || _bluetoothRequestBusy) return;
    if (bluetoothSourcePackage.isEmpty) {
      bluetoothSourceStatus = 'Select an Android media source first';
      notifyListeners();
      return;
    }
    if (automatic && (!bluetoothAutoResume || !enabled)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (automatic && now - _lastBluetoothAutoMs < 20000) return;
    if (automatic) _lastBluetoothAutoMs = now;
    _bluetoothRequestBusy = true;
    try {
      final response = await _bluetoothAudio.invokeMethod<dynamic>(
          'requestPlay', <String, dynamic>{
        'package': bluetoothSourcePackage,
      });
      if (response is Map) {
        bluetoothSourceStatus =
            response['message']?.toString() ?? 'No response to play request';
      } else {
        bluetoothSourceStatus = 'Android did not return a play-request result';
      }
    } catch (error) {
      bluetoothSourceStatus = 'Android cannot activate the selected source: $error';
    } finally {
      _bluetoothRequestBusy = false;
      notifyListeners();
    }
  }

  /// Manual-only diagnostic. Android sends the key to whichever system
  /// media consumer currently holds it, which may be an unrelated player.
  Future<void> requestSystemMediaPlay() async {
    if (role != 'receiver') return;
    try {
      final response = await _bluetoothAudio.invokeMethod<dynamic>('systemPlay');
      bluetoothSourceStatus = response is Map
          ? (response['message']?.toString() ?? 'Media key dispatched')
          : 'No response from system media key';
    } catch (error) {
      bluetoothSourceStatus = 'System media key unavailable: $error';
    }
    notifyListeners();
  }

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
    // New installs choose this during onboarding. For existing users,
    // preserve their previously configured sender/receiver role.
    final savedRole = p.getString('link_role') ?? 'sender';
    deviceType = p.getString('vybe_device_type') ??
        (savedRole == 'receiver' ? 'head_unit' : 'phone');
    role = deviceType == 'head_unit' ? 'receiver' : 'sender';
    autoConnect = p.getBool('link_auto') ?? true;
    bluetoothSourcePackage = p.getString('link_bluetooth_source') ?? '';
    bluetoothAutoResume = p.getBool('link_bluetooth_auto_resume') ?? false;
    // Earlier builds experimented with USB tethering, now disabled.
    preferWired = false;
    _savedWiredReceiverIp = (p.getString('link_wired_address') ?? '').trim();
    receiverAddress = (p.getString('link_address') ?? '').trim();
    pairedReceiverId = p.getString('link_paired_receiver') ?? '';
    _savedDirectPeerAddress = p.getString('link_direct_peer') ?? '';
    _savedDirectPeerName = p.getString('link_direct_peer_name') ?? '';
    _directPreferred = p.getBool('link_direct_preferred') ?? false;
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
    if (enabled && autoConnect) {
      // A P2P group may already exist when VYBE launches. Register for its
      // native state and reuse the automatically resolved group owner IP.
      if (_directPreferred && directAvailable) {
        try { await _direct.invokeMethod<bool>('start'); } catch (_) {}
      }
      unawaited(connect());
    }
    // Network auto-reconnect is not enough if Wi-Fi Direct itself vanished.
    // When the user has already chosen Direct, restore its group/peer without
    // asking for the IP again. A running LAN socket takes priority.
    if (enabled && autoConnect && _directPreferred) {
      unawaited(_recoverDirect(immediately: true));
    }
    _directRecoveryTimer?.cancel();
    _directRecoveryTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (enabled && autoConnect && _directPreferred &&
          !_directGroupConnected && (role == 'receiver' || _socket == null)) {
        unawaited(_recoverDirect());
      }
    });
    // Android/network transitions may not generate a socket close event.
    // Periodically recover a missing connection without user interaction.
    _connectionWatchdog?.cancel();
    _connectionWatchdog = Timer.periodic(const Duration(seconds: 3), (_) {
      // No USB tethering polling while this mode is disabled.
      final peer = _socket;
      if (peer != null) {
        if (DateTime.now().millisecondsSinceEpoch - _lastPeerResponse > 11000) {
          if (role == 'sender') _senderDisconnected(peer);
          else _receiverDisconnected(peer);
          peer.destroy();
          return;
        }
        try { peer.writeln(jsonEncode({'v': 2, 'kind': 'ping'})); }
        catch (_) { if (role == 'sender') _senderDisconnected(peer); else _receiverDisconnected(peer); }
      }
      if (!enabled || !autoConnect) return;
      // Keep UDP pairing discoverable even if it failed after TCP binding.
      if (role == 'receiver' && _server != null && _responder == null) {
        unawaited(_ensureResponder());
      }
      if (_connecting || _retry?.isActive == true) return;
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
    discoveryStatus = results.isEmpty
        ? 'No UDP response on this network (Direct or saved IP may still work)'
        : 'Found ' + results.length.toString() + ' receiver(s)';
    if (_socket == null && role == 'sender') {
      status = results.isEmpty
          ? 'Discovery did not respond; automatic reconnect is still active'
          : 'Found ' + results.length.toString() + ' VYBE receiver(s)';
    }
    notifyListeners();
  }

  Future<void> pairReceiver(LinkReceiver receiver) async {
    pairedReceiverId = receiver.id;
    receiverAddress = receiver.address;
    enabled = true;
    autoConnect = true;
    final p = await SharedPreferences.getInstance();
    await p.setString('link_paired_receiver', pairedReceiverId);
    await p.setString('link_address', receiverAddress);
    // Do not route pairing through configure(address:): it intentionally
    // clears the saved receiver identity for manual IP changes.
    await configure(isEnabled: true, deviceRole: 'sender', automatic: true);
  }

  /// Called when the UI returns from another app. Background reconnect is
  /// best-effort: Android can suspend this Flutter process.
  void onResumed() {
    if (!enabled || !autoConnect) return;
    if (_directPreferred) unawaited(_recoverDirect(immediately: true));
    if (_connecting) return;
    if (role == 'receiver' && _server == null) { connect(); return; }
    if (role == 'sender' && _socket == null) connect();
  }

  /// One recovery action covers BOTH the underlying Wi-Fi Direct network and
  /// TCP transport. It never requires a numeric IP address.
  Future<void> reconnectAutomatically() async {
    if (!enabled) await configure(isEnabled: true, automatic: true);
    if (_directPreferred) {
      await _recoverDirect(immediately: true);
    } else if (role == 'sender') {
      unawaited(findReceivers());
    }
    if (role == 'receiver' && _server != null) return;
    if (role == 'sender' && _socket != null) return;
    await connect();
  }


  /// Choose the installed device once, instead of asking the user to pick
  /// sender/receiver again in Connect settings.
  Future<void> setDeviceType(String type) async {
    if (type != 'phone' && type != 'head_unit') return;
    deviceType = type;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString('vybe_device_type', type);
    await configure(deviceRole: type == 'head_unit' ? 'receiver' : 'sender');
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
    if (!enabled) {
      _connectPending = false;
      _directGroupConnected = false;
      // The periodic timer checks enabled/autoConnect and should remain
      // installed so re-enabling VYBE Connect restores automatic recovery.
    }
    if (address != null) {
      final requested = address.trim();
      if (requested != receiverAddress) {
        pairedReceiverId = ''; // Manual new IP means explicitly pairing again.
      }
      receiverAddress = requested;
    }
    status = !enabled ? 'Disabled' :
        (!endpointChanged && _socket != null && role == 'sender')
            ? 'Connected to ${receiverAddress}' : 'Connecting...';
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

  /// The TCP server can be listening before the separate UDP discovery
  /// responder has bound. Retry discovery without restarting a working server.
  Future<void> _ensureResponder() async {
    if (_responder != null || _startingResponder || !enabled ||
        role != 'receiver' || _server == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastResponderAttemptMs < 5000) return;
    _lastResponderAttemptMs = now;
    _startingResponder = true;
    final generation = _generation;
    try {
      final started = await LinkDiscoveryResponder.start(localDeviceId);
      if (generation == _generation && enabled &&
          role == 'receiver' && _server != null) {
        _responder = started;
        discoveryStatus = 'UDP discovery responder ready';
      } else {
        await started.close();
      }
    } catch (error) {
      discoveryStatus = 'TCP ready but UDP discovery unavailable: $error';
      debugPrint('VYBE Connect discovery responder failed: $error');
    } finally {
      _startingResponder = false;
      notifyListeners();
    }
  }

  Future<void> _updateAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      localAddresses = interfaces.expand((i) => i.addresses)
          .where((a) => !a.isLoopback).map((a) => a.address).join(', ');
    } catch (_) { localAddresses = 'Unavailable'; }
  }

  /// Connection addresses are discovered from Android Wi-Fi Direct group
  /// information or from VYBE's UDP discovery. A user-entered IP is never
  /// required. Receiver identity is learned asynchronously without blocking
  /// the first metadata packet.
  Future<void> connect() async {
    // A Wi-Fi Direct "connected" event can arrive while an old-IP attempt
    // is in progress. Do not discard it: run one fresh connection attempt
    // using Android's new group-owner IP as soon as the old attempt ends.
    if (_connecting) {
      _connectPending = true;
      return;
    }
    _connecting = true;
    try {
      do {
        _connectPending = false;
        await _connectInternal();
      // Native Direct broadcasts often arrive while TCP is connecting.
      // A queued retry must NEVER tear down a socket that just succeeded.
      } while (_connectPending && enabled &&
          (role == 'receiver' ? _server == null : _socket == null));
    } finally {
      _connecting = false;
    }
  }

  Future<void> _connectInternal() async {
    final generation = ++_generation;
    _retry?.cancel(); _retry = null;
    _sendTimer?.cancel(); _sendTimer = null;
    _helloTimer?.cancel(); _helloTimer = null;
    _lastPeerResponse = 0;
    await _socketSub?.cancel(); _socketSub = null;
    await _responder?.close(); _responder = null;
    _socket?.destroy(); _socket = null;
    await _server?.close(); _server = null;
    _lastPayload = ''; _lastTrack = ''; _lastArtHash = 0;
    _artGeneration++; _rxGeneration++;
    _sentFanartArtist = ''; _currentSenderArtist = '';
    _sentFanartHash = 0; _fanartGeneration++;
    receivedFanart = null; receivedFanartArtist = '';
    receivedClearLogo = null; receivedClearLogoArtist = '';
    _sentClearLogoArtist = ''; _sentClearLogoHash = 0; ++_clearLogoGeneration;
    _encodingClearLogoArtist = ''; _encodingClearLogoHash = 0;
    _clearLogoAckTimer?.cancel(); _clearLogoAckTimer = null;
    _lastMetadataSentAt = 0; _lastMetadataState = '';
    _remoteWasPlaying = false;
    if (_wifiSenderRequested) unawaited(stopWifiAudioStream());
    if (_wifiReceiverRequested) unawaited(stopWifiAudioReceiver());

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
      activeTransport = 'Listening on available networks';
      try {
        final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        if (generation != _generation) { await server.close(); return; }
        _server = server;
        // Discovery must not interfere with accepting a manually entered IP.
        await _ensureResponder();
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
          _lastPeerResponse = DateTime.now().millisecondsSinceEpoch;
          final overUsb = _isWiredDestination(client.remoteAddress.address);
          activeTransport = overUsb ? 'USB tethering' : 'Wi-Fi / LAN';
          if (overUsb) wiredStatus = 'Connected over USB';
          status = 'Connected via $activeTransport to ${client.remoteAddress.address}';
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

    status = receiverAddress.isNotEmpty ? 'Connecting to saved head unit...' :
        'Searching for head unit...';
    notifyListeners();
    // Wired USB is the first choice, but never trust an arbitrary connected
    // device: discover its VYBE receiver ID before pairing. A saved wired
    // address is tried first only on the active USB subnet for fast startup.
    Socket? socket;
    String address = '';
    if (preferWired && _wiredAddresses.isNotEmpty) {
      status = 'Looking for head unit over USB tethering...';
      notifyListeners();
      if (_savedWiredReceiverIp.isNotEmpty &&
          _isWiredDestination(_savedWiredReceiverIp)) {
        try {
          socket = await Socket.connect(_savedWiredReceiverIp, port,
              sourceAddress: _wiredSourceFor(_savedWiredReceiverIp),
              timeout: const Duration(milliseconds: 1100));
          address = _savedWiredReceiverIp;
        } catch (_) {}
      }
      if (generation != _generation) { socket?.destroy(); return; }
      if (socket == null) {
        for (final source in _wiredAddresses) {
          try {
            final found = await LinkDiscovery.scan(
                sourceAddress: source,
                timeout: const Duration(milliseconds: 1100));
            if (generation != _generation) return;
            final matched = _matchingReceivers(found);
            if (matched.isEmpty ||
                !_isWiredDestination(matched.first.address)) continue;
            address = matched.first.address;
            try {
              socket = await Socket.connect(address, port,
                  sourceAddress: source,
                  timeout: const Duration(seconds: 2));
            } catch (_) {}
            if (socket != null) break;
          } catch (error) {
            wiredStatus = 'USB discovery: $error';
          }
        }
        if (generation != _generation) { socket?.destroy(); return; }
      }
    }

    // USB not ready or the receiver isn't reachable yet? Preserve the
    // previously working Wi-Fi Direct, hotspot and LAN fallback paths.
    if (socket == null) {
      address = _directGroupConnected && _directGroupOwnerIp.isNotEmpty
          ? _directGroupOwnerIp : receiverAddress;
      if (address.isNotEmpty) {
        try {
          socket = await Socket.connect(address, port,
              timeout: const Duration(seconds: 2));
        } catch (_) {}
      }
    }
    if (generation != _generation) { socket?.destroy(); return; }

    // A Direct connection can form during the saved-IP attempt. Try the
    // new owner IP immediately rather than waiting for the next retry timer.
    if (socket == null && _directGroupConnected &&
        _directGroupOwnerIp.isNotEmpty && address != _directGroupOwnerIp) {
      address = _directGroupOwnerIp;
      try {
        socket = await Socket.connect(
            address, port, timeout: const Duration(seconds: 2));
      } catch (_) {}
      if (generation != _generation) { socket?.destroy(); return; }
    }

    if (socket == null) {
      status = 'Discovering head unit automatically...';
      notifyListeners();
      try {
        final devices = await LinkDiscovery.scan();
        discoveryStatus = devices.isEmpty ? 'No UDP response yet'
            : 'Found ' + devices.length.toString() + ' receiver(s)';
        if (generation != _generation) return;
        // Reconnect ONLY to the paired receiver when its identity is known.
        // With one discovered receiver and no pairing, initial setup can
        // also connect without any IP entry.
        final matching = pairedReceiverId.isNotEmpty
            ? devices.where((d) => d.id == pairedReceiverId).toList()
            : (devices.length == 1 ? devices : <LinkReceiver>[]);
        if (matching.isNotEmpty) {
          address = matching.first.address;
          try {
            socket = await Socket.connect(
                address, port, timeout: const Duration(seconds: 3));
          } catch (_) {}
        }
      } catch (_) {}
    }
    if (generation != _generation) { socket?.destroy(); return; }
    if (socket == null) {
      status = 'Waiting for head unit; automatic discovery and reconnection active';
      notifyListeners();
      if (_directPreferred) unawaited(_recoverDirect());
      _scheduleRetry(generation);
      return;
    }

    _socket = socket;
    _tcpConnectedViaWired = _isWiredDestination(address);
    _tcpConnectedViaDirect = !_tcpConnectedViaWired &&
        _directGroupConnected &&
        _directGroupOwnerIp.isNotEmpty && address == _directGroupOwnerIp;
    activeTransport = _tcpConnectedViaWired ? 'USB tethering'
        : (_tcpConnectedViaDirect ? 'Wi-Fi Direct' : 'Wi-Fi / LAN');
    if (_tcpConnectedViaWired) {
      _savedWiredReceiverIp = address;
      wiredStatus = 'Connected over USB';
    }
    _lastPeerResponse = DateTime.now().millisecondsSinceEpoch;
    receiverAddress = address;
    // Persist automatically discovered network addresses for faster next
    // connection; still resolve them anew when the network changes.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('link_enabled', true);
      await prefs.setBool('link_auto', true);
      await prefs.setString('link_role', 'sender');
      await prefs.setString('link_address', address);
      if (_tcpConnectedViaWired) {
        await prefs.setString('link_wired_address', address);
      }
      autoConnect = true;
    } catch (e) {
      debugPrint('VYBE Link failed to persist working receiver IP: $e');
    }
    if (generation != _generation || !identical(socket, _socket)) return;
    status = 'Connected via $activeTransport to $address';
    // The original working method transmitted immediately upon TCP connect.
    // Do not wait for a hello packet, which could prevent all song data.
    final peer = socket;
    final lines = peer.cast<List<int>>()
        .transform(utf8.decoder).transform(const LineSplitter());
    _socketSub = lines.listen((line) {
      if (!identical(_socket, peer) || generation != _generation) return;
      try {
        final data = jsonDecode(line);
        if (data is! Map || data['v'] != 2) return;
        _lastPeerResponse = DateTime.now().millisecondsSinceEpoch;
        if (data['kind'] == 'ping') { peer.writeln(jsonEncode({'v': 2, 'kind': 'pong'})); return; }
        if (data['kind'] == 'clearlogo_ack') {
          if (data['artist'] == _sentClearLogoArtist &&
              data['hash'] == _sentClearLogoHash) {
            _clearLogoAckTimer?.cancel();
            _clearLogoAckTimer = null;
            artworkStatus = 'Clearlogo received by head unit';
            notifyListeners();
          }
          return;
        }
        if (data['kind'] != 'hello') return;
        final id = (data['id'] as String?) ?? '';
        if (id.length < 16 || id.length > 128) return;
        if (pairedReceiverId.isNotEmpty && pairedReceiverId != id) {
          // A previously saved IP may now belong to another device. Never
          // keep reconnecting to that stale address forever; rediscover the
          // paired receiver by its stable identity on the next attempt.
          status = 'Saved IP belongs to a different receiver; rediscovering';
          receiverAddress = '';
          if (_tcpConnectedViaWired) _savedWiredReceiverIp = '';
          notifyListeners();
          unawaited(SharedPreferences.getInstance().then((prefs) async {
            await prefs.setString('link_address', '');
            if (_tcpConnectedViaWired) {
              await prefs.setString('link_wired_address', '');
            }
          }).catchError((Object error) {
            debugPrint('VYBE Link could not clear stale IP: $error');
          }));
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
    // Send cached clearlogos only after the first metadata packet, so the
    // receiver already knows which artist a logo belongs to.
    notifyListeners();
  }

  void _receiverDisconnected(Socket client) {
    if (!identical(client, _socket)) return;
    _socket = null; _model?.setLinkReceiverActive(false);
    _remoteWasPlaying = false;
    if (_wifiReceiverRequested) unawaited(stopWifiAudioReceiver());
    activeTransport = 'Listening on available networks';
    status = 'Waiting for sender'; notifyListeners();
  }
  void _senderDisconnected(Socket client) {
    if (!identical(client, _socket)) return;
    _socket = null;
    if (_wifiSenderRequested) unawaited(stopWifiAudioStream());
    _tcpConnectedViaDirect = false;
    _tcpConnectedViaWired = false;
    activeTransport = 'Disconnected';
    _sendTimer?.cancel(); _sendTimer = null;
    _helloTimer?.cancel(); _helloTimer = null;
    _clearLogoAckTimer?.cancel(); _clearLogoAckTimer = null;
    status = 'Connection lost; reconnecting automatically...';
    notifyListeners();
    if (_directPreferred) unawaited(_recoverDirect());
    _scheduleRetry(_generation);
  }
  void _scheduleRetry(int generation) {
    if (!enabled || !autoConnect || role != 'sender') return;
    _retry?.cancel();
    // A head unit can finish booting its Wi-Fi and TCP server shortly after
    // the phone starts. Retry promptly without requiring the user to tap.
    _retry = Timer(const Duration(seconds: 4), () {
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
      // The small cover shown on screen and the full-screen album-art
      // backdrop both need the original image. Never downsample to 320 px
      // merely because the receiver is a head unit.
      final transfer = await _imageTransferBytes(bytes);
      if (token != _artGeneration || !identical(socket, _socket) ||
          track != _lastTrack) return;
      if (transfer == null) {
        artworkStatus = 'Album artwork too large for transfer';
        _lastArtHash = 0;
        notifyListeners();
        return;
      }
      socket.write('${jsonEncode({'v': 2, 'kind': 'art', 'track': track, 'art': base64Encode(transfer)})}\n');
      artworkStatus = identical(transfer, bytes)
          ? 'Original album artwork sent (${(transfer.length / 1024).round()} KB)'
          : 'Album artwork resized to fit transfer (${(transfer.length / 1024).round()} KB)';
      notifyListeners();
    } catch (error) {
      if (token == _artGeneration && identical(socket, _socket)) {
        _lastArtHash = 0;
        artworkStatus = 'Sender artwork error: $error';
        notifyListeners();
      }
    }
  }

  /// Invalidate older artist encodes even while the new image downloads.
  void setFanartArtist(String artist) {
    if (role != 'sender' || !enabled || _currentSenderArtist == artist) return;
    _currentSenderArtist = artist;
    _sentFanartArtist = '';
    _sentFanartHash = 0;
    ++_fanartGeneration;
  }

  // Original JPEG/PNG bytes are usually small enough to send unchanged.
  // Keep the same cap for album art and artist fanart; only unusually large
  // local source images need a bounded, screen-quality fallback.
  static const int _maxTransferImageBytes = 6 * 1024 * 1024;

  Future<Uint8List?> _imageTransferBytes(Uint8List original) async {
    if (original.length <= _maxTransferImageBytes) {
      // No decode, resize or PNG conversion: highest quality, fastest send.
      return original;
    }
    // Unusually large local backgrounds still need a bounded payload.
    // Attempt HD first and step down only if the encoded PNG is too large.
    // Never default to a tiny 480 px image just to make the transfer work.
    for (final width in <int>[1600, 1280, 960, 720, 480]) {
      final codec = await ui.instantiateImageCodec(original, targetWidth: width);
      try {
        final frame = await codec.getNextFrame();
        try {
          final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) continue;
          final reduced = data.buffer.asUint8List(
              data.offsetInBytes, data.lengthInBytes);
          if (reduced.length <= _maxTransferImageBytes) return reduced;
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    }
    return null;
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
        final transfer = await _imageTransferBytes(bytes);
        if (token != _fanartGeneration || !identical(socket, _socket) ||
            artist != _currentSenderArtist) return;
        if (transfer == null) {
          artworkStatus = 'Fanart too large to send at supported quality';
          _sentFanartArtist = '';
          _sentFanartHash = 0;
          notifyListeners();
          return;
        }
        // JPEG and PNG bytes are both decoded by image signature, not by the
        // .png extension of the shared app-private Drive cache file.
        socket.write('${jsonEncode({'v': 2, 'kind': 'fanart', 'artist': artist, 'art': base64Encode(transfer)})}\n');
        artworkStatus = identical(transfer, bytes)
            ? 'Original fanart sent (${(transfer.length / 1024).round()} KB)'
            : 'HD fanart resized for transfer (${(transfer.length / 1024).round()} KB)';
        notifyListeners();
      } catch (e) {
        if (token == _fanartGeneration && identical(socket, _socket)) {
          _sentFanartArtist = '';
          _sentFanartHash = 0;
          artworkStatus = 'Fanart transfer error: $e';
          notifyListeners();
        }
      }
    }();
  }

  /// Clearlogos use the SAME working TCP socket as covers and fanart.
  /// Keep PNG alpha, avoid unnecessary re-encoding of small cached PNGs,
  /// and only mark a logo as sent after bytes are written to the socket.
  void sendClearLogo(String artist, Uint8List? bytes) {
    final socket = _socket;
    if (socket == null || !enabled || role != 'sender' || artist.isEmpty ||
        bytes == null || bytes.isEmpty) return;
    final hash = Object.hash(bytes.length, bytes.first,
        bytes[bytes.length ~/ 2], bytes.last);
    if (_sentClearLogoArtist == artist && _sentClearLogoHash == hash) return;
    // Rapid model/link notifications must not invalidate an ongoing encode.
    if (_encodingClearLogoArtist == artist &&
        _encodingClearLogoHash == hash) return;
    _encodingClearLogoArtist = artist;
    _encodingClearLogoHash = hash;
    final token = ++_clearLogoGeneration;
    () async {
      try {
        Uint8List? compact;
        final png = bytes.length >= 8 &&
            bytes[0] == 137 && bytes[1] == 80 &&
            bytes[2] == 78 && bytes[3] == 71;
        // Original transparent PNGs generally need no processing.
        if (png && bytes.length <= 950000) {
          compact = bytes;
        } else {
          // If needed, reduce resolution without losing transparency.
          // The 640px-only path previously failed silently for large PNGs.
          for (final width in <int>[480, 320, 240]) {
            final codec = await ui.instantiateImageCodec(
                bytes, targetWidth: width);
            final frame = await codec.getNextFrame();
            final data = await frame.image.toByteData(
                format: ui.ImageByteFormat.png);
            frame.image.dispose();
            codec.dispose();
            if (data == null) continue;
            final encoded = data.buffer.asUint8List(
                data.offsetInBytes, data.lengthInBytes);
            if (encoded.length <= 950000) {
              compact = encoded;
              break;
            }
          }
        }
        if (token != _clearLogoGeneration ||
            !identical(socket, _socket) || artist != _model?.artist.trim()) return;
        if (compact == null) {
          artworkStatus = 'Clearlogo could not fit transfer limit';
          notifyListeners();
          return;
        }
        socket.write('${jsonEncode({'v': 2, 'kind': 'clearlogo',
          'artist': artist, 'hash': hash, 'art': base64Encode(compact)})}\n');
        // Mark as sent only after writing; receiver ACK confirms delivery.
        _sentClearLogoArtist = artist;
        _sentClearLogoHash = hash;
        _clearLogoAckTimer?.cancel();
        _clearLogoAckTimer = Timer(const Duration(seconds: 5), () {
          if (!identical(socket, _socket) ||
              _sentClearLogoArtist != artist || _sentClearLogoHash != hash) return;
          // No ACK: retry the same logo with the existing artwork socket.
          _sentClearLogoArtist = '';
          _sentClearLogoHash = 0;
          sendClearLogo(artist, bytes);
        });
      } catch (e) {
        artworkStatus = 'Clearlogo transfer error: $e';
        notifyListeners();
      } finally {
        if (token == _clearLogoGeneration) {
          _encodingClearLogoArtist = '';
          _encodingClearLogoHash = 0;
        }
      }
    }();
  }

  // Socket data is ordered, but asynchronous artwork decoding must not allow
  // an older cover to overwrite a newly selected track.
  void _receive(String line) {
    // 6 MB binary artwork becomes ~8 MB of base64. The previous 1.6M
    // character gate silently discarded higher-resolution covers/fanart.
    // Keep a bounded limit while accepting the full-quality transfer cap.
    if (!enabled || role != 'receiver' || line.length > 9 * 1024 * 1024) return;
    try {
      final data = jsonDecode(line);
      if (data is! Map || data['v'] != 2) return;
      _lastPeerResponse = DateTime.now().millisecondsSinceEpoch;
      if (data['kind'] == 'ping') { _socket?.writeln(jsonEncode({'v': 2, 'kind': 'pong'})); return; }
      if (data['kind'] == 'pong') return;
      final track = data['track'] is String ? data['track'] as String : '';
      if (data['kind'] == 'meta') {
        final changed = track != lastReceivedTrack;
        if (changed) {
          lastReceivedTrack = track;
          artworkStatus = 'Checking local artwork';
          _rxGeneration++;
          _localCoverTrack = track;
          _localCoverAvailable = false;
          final token = _rxGeneration;
          final artist = data['artist'] is String ? data['artist'] as String : '';
          final album = data['album'] is String ? data['album'] as String : '';
          LocalArtwork.instance.albumArt(artist, album).then((bytes) {
            if (token != _rxGeneration || track != lastReceivedTrack || bytes == null || bytes.isEmpty) return;
            _localCoverAvailable = true;
            _model?.applyLinkArtwork(bytes);
            artworkStatus = 'Local album artwork';
            notifyListeners();
          });
        }
        final incomingArtist = data['artist'] is String ? data['artist'] as String : '';
        if (incomingArtist != receivedFanartArtist) {
          receivedFanart = null; receivedFanartArtist = incomingArtist; notifyListeners();
        }
        if (incomingArtist != receivedClearLogoArtist) {
          receivedClearLogo = null; receivedClearLogoArtist = incomingArtist;
          notifyListeners();
        }
        metadataReceived++;
        // The phone's existing VYBE Connect playback state is an Android-
        // independent trigger. Only the first PLAYING transition requests
        // activation of the user-selected media session on the head unit.
        // Never dispatch global media keys automatically.
        final remotePlaying = data['playing'] == true && data['active'] == true;
        if (remotePlaying && !_remoteWasPlaying && bluetoothAutoResume &&
            bluetoothSourcePackage.isNotEmpty) {
          unawaited(requestBluetoothSourcePlay(automatic: true));
        }
        _remoteWasPlaying = remotePlaying;
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
          final incoming = base64Decode(data['art'] as String);
          receivedFanart = incoming;
          // The separate Drive Flutter engine can't see this singleton's
          // memory. Publish the same artist-matched image via app storage.
          unawaited(LinkArtistArtworkCache.save(
              receivedFanartArtist, 'fanart', incoming));
          notifyListeners();
        } catch (_) { artworkErrors++; }
      } else if (data['kind'] == 'clearlogo' && data['art'] is String &&
          data['artist'] == receivedClearLogoArtist) {
        try {
          final incoming = base64Decode(data['art'] as String);
          if (incoming.isEmpty) return;
          receivedClearLogo = incoming;
          unawaited(LinkArtistArtworkCache.save(
              receivedClearLogoArtist, 'clearlogo', incoming));
          notifyListeners();
          // Explicit confirmation prevents an unsuccessful send being
          // permanently suppressed after reconnect or dropped packets.
          try {
            _socket?.writeln(jsonEncode({'v': 2, 'kind': 'clearlogo_ack',
              'artist': receivedClearLogoArtist, 'hash': data['hash']}));
          } catch (_) {}
        } catch (_) { artworkErrors++; }
      } else if (data['kind'] == 'art' && track == lastReceivedTrack && data['art'] is String) {
        try {
          final bytes = base64Decode(data['art'] as String);
          if (track != lastReceivedTrack) return;
          if (!_localCoverAvailable) _model?.applyLinkArtwork(bytes);
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
    _retry?.cancel(); _connectionWatchdog?.cancel(); _heartbeat?.cancel();
    _sendTimer?.cancel(); _helloTimer?.cancel();
    _model?.removeListener(_onModel);
    _socketSub?.cancel(); _socket?.destroy(); _server?.close();
    _responder?.close();
    super.dispose();
  }
}
