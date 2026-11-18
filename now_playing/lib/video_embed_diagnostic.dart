import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Isolated, user-initiated proof of concept: play a YouTube ID inside VYBE
/// through YouTube's official IFrame Player API. No stream extraction or
/// video downloads. This route is not a production Music Video theme.
class VideoEmbedDiagnosticPage extends StatefulWidget {
  final String videoId;

  const VideoEmbedDiagnosticPage({super.key, required this.videoId});

  @override
  State<VideoEmbedDiagnosticPage> createState() =>
      _VideoEmbedDiagnosticPageState();
}

class _VideoEmbedDiagnosticPageState extends State<VideoEmbedDiagnosticPage> {
  static const _control = MethodChannel('nowplaying/control');
  static const _appOrigin = 'https://com.conjure.now_playing';

  late final WebViewController _web;
  final List<String> _events = [];
  bool _ready = false;
  bool _playOnReady = false;
  bool _busy = false;
  bool _pausingSource = false;
  bool _sourcePauseConfirmed = false;
  bool _showYoutubeControls = false;
  bool _automaticNext = true;
  bool _advancing = false;
  bool _waitingAfterCall = false;
  bool _inCall = false;
  bool _callPollBusy = false;
  bool _callPermissionNeeded = false;
  bool _resumeVideoAfterCall = false;
  bool _resumeSourceAfterCall = false;
  bool _sourceAudioFallback = false;
  bool _disposed = false;
  int _sequenceToken = 0;
  Timer? _callTimer;
  String _videoId = '';
  String _sourceTitle = '';
  String _sourceArtist = '';
  String _queueStatus = 'Waiting for source playlist';
  String _callStatus = 'Monitoring call audio mode';
  String _transitionStatus = 'Ready to test automatic Next';
  String _state = 'Initializing embedded YouTube player';
  String _sourcePause = 'YouTube Music has not been paused by this test';
  String _lastError = '';

  @override
  void initState() {
    super.initState();
    _videoId = widget.videoId;
    _callTimer = Timer.periodic(const Duration(milliseconds: 900),
        (_) => unawaited(_pollCallState()));
    unawaited(_pollCallState());
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      ..addJavaScriptChannel('VybeVideo',
          onMessageReceived: (message) => _onPlayerEvent(message.message))
      ..setNavigationDelegate(NavigationDelegate(
        onWebResourceError: (error) {
          if (error.isForMainFrame == true) {
            _record('WebView error: ${error.description}');
            if (mounted) setState(() => _lastError = error.description);
          }
        },
      ));
    if (_web.platform is AndroidWebViewController) {
      // Playback is still initiated by the user's Play button below.
      // This permits the official iframe API to respond to that gesture.
      unawaited((_web.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false));
    }
    unawaited(_load());
    unawaited(_readSourceStatus());
  }

  void _record(String description) {
    _events.add('${DateTime.now().toIso8601String()} — $description');
    if (_events.length > 40) _events.removeAt(0);
  }

  String _errorDescription(String code) {
    switch (code) {
      case '2': return 'Invalid YouTube ID or request (2)';
      case '5': return 'HTML5 player error (5)';
      case '100': return 'Video is unavailable, private or removed (100)';
      case '101': return 'Owner disallows embedding (101)';
      case '150': return 'Owner disallows embedding (150)';
      case '153': return 'Embedded player identity / Referer unavailable (153)';
      default: return 'YouTube player reported error $code';
    }
  }

  void _onPlayerEvent(String raw) {
    if (!mounted) return;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return;
      final name = json['event']?.toString() ?? 'unknown';
      final detail = json['detail']?.toString() ?? '';
      _record('$name: $detail');
      setState(() {
        switch (name) {
          case 'ready':
            _ready = true;
            _state = 'Player ready — press Play video';
            break;
          case 'state':
            _state = detail;
            break;
          case 'error':
            _lastError = _errorDescription(detail);
            _state = _lastError;
            _playOnReady = false;
            break;
          case 'blocked':
            _lastError = 'Playback blocked by WebView/YouTube. Try '
                'Show YouTube controls and tap the player directly.';
            _state = _lastError;
            _playOnReady = false;
            break;
          default:
            _state = '$name $detail';
        }
      });
      // A tap directly on the YouTube iframe bypasses VYBE's pink Play
      // button. Observe the iframe state so BOTH control paths pause the
      // original source and only one audio track continues.
      if (name == 'state' && detail == 'Playing') {
        if (_inCall) {
          // A late iframe autoplay event must never restart video mid-call.
          unawaited(_send('window.vybePause && window.vybePause();'));
        } else {
          _sourceAudioFallback = false;
          unawaited(_pauseMusicSource('Embedded video entered Playing'));
        }
      }
      if (name == 'state' && detail == 'Ended' && _automaticNext) {
        if (_inCall) {
          _waitingAfterCall = true;
          _record('Video ended during call; next track deferred');
        } else {
          unawaited(_advanceToNext('Embedded video ended'));
        }
      }
      if (name == 'ready' && _playOnReady) {
        _playOnReady = false;
        if (!_inCall) {
          unawaited(_send('window.vybePlay && window.vybePlay();'));
        } else {
          _resumeVideoAfterCall = true;
        }
      }
    } catch (error) {
      _record('Invalid player status message: $error');
    }
  }

  String _html() {
    final controls = _showYoutubeControls ? 1 : 0;
    // baseUrl supplies the embedding app identity as HTTP Referer, per
    // YouTube's documented Android WebView integration. No fake website or
    // proxy is involved. Keep YouTube's player and attribution unobscured.
    return '''
<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<meta name="referrer" content="strict-origin-when-cross-origin">
<style>
html,body{margin:0;padding:0;background:#000;width:100%;height:100%;overflow:hidden}
#player{width:100%;height:100%}
</style>
</head><body>
<div id="player"></div>
<script>
var ytPlayer = null;
function vybeEvent(event, detail) {
  try { window.VybeVideo.postMessage(JSON.stringify({event:event,detail:String(detail)})); }
  catch (e) {}
}
window.vybePlay = function() {
  if (ytPlayer && typeof ytPlayer.playVideo === 'function') ytPlayer.playVideo();
  else vybeEvent('state','Player is not ready');
};
window.vybePause = function() {
  if (ytPlayer && typeof ytPlayer.pauseVideo === 'function') ytPlayer.pauseVideo();
};
window.vybeStop = function() {
  if (ytPlayer && typeof ytPlayer.stopVideo === 'function') ytPlayer.stopVideo();
};
function onYouTubeIframeAPIReady() {
  try {
    ytPlayer = new YT.Player('player', {
      width: '100%', height: '100%',
      videoId: '$_videoId',
      playerVars: {
        autoplay: 0,
        controls: $controls,
        playsinline: 1,
        rel: 0,
        enablejsapi: 1,
        origin: '$_appOrigin'
      },
      events: {
        onReady: function() { vybeEvent('ready','YouTube iframe loaded'); },
        onStateChange: function(e) {
          var states = {
            '-1':'Unstarted','0':'Ended','1':'Playing',
            '2':'Paused','3':'Buffering','5':'Cued'
          };
          vybeEvent('state',states[e.data] || 'State '+e.data);
        },
        onError: function(e) { vybeEvent('error',e.data); },
        onAutoplayBlocked: function() { vybeEvent('blocked','Autoplay blocked'); }
      }
    });
  } catch(e) { vybeEvent('error', 'API: '+e.message); }
}
var tag = document.createElement('script');
tag.src = 'https://www.youtube.com/iframe_api';
tag.onerror = function(){vybeEvent('error','YouTube API script failed to load');};
document.head.appendChild(tag);
</script>
</body></html>
''';
  }

  Future<void> _load({bool playOnReady = false}) async {
    if (!mounted) return;
    _playOnReady = playOnReady;
    _sourcePauseConfirmed = false;
    setState(() {
      _ready = false;
      _state = 'Loading YouTube iframe…';
      _lastError = '';
    });
    _record('Loading video ID $_videoId; controls=${_showYoutubeControls ? 1 : 0}');
    try {
      await _web.loadHtmlString(_html(), baseUrl: '$_appOrigin/');
    } catch (e) {
      _record('Could not load WebView: $e');
      if (mounted) setState(() => _lastError = e.toString());
    }
  }

  Future<void> _send(String command) async {
    try {
      await _web.runJavaScript(command);
    } catch (error) {
      _record('JavaScript command failed: $error');
      if (mounted) setState(() => _lastError = error.toString());
    }
  }

  /// Coordinate audio even when YouTube's own on-video Play button is used.
  /// Do not interrupt the embedded player; pause only the music app's
  /// Android MediaSession. The native call is idempotent.
  Future<void> _pauseMusicSource(String trigger) async {
    if (!mounted || _pausingSource || _sourcePauseConfirmed) return;
    _pausingSource = true;
    _record('Source pause requested: $trigger');
    try {
      final result = await _control.invokeMapMethod<String, dynamic>(
          'pauseYoutubeMusicForVideoTest');
      if (!mounted) return;
      final reason = result?['reason']?.toString() ?? 'Pause status unknown';
      _sourcePauseConfirmed =
          result?['paused'] == true || result?['alreadyPaused'] == true;
      setState(() => _sourcePause = reason);
      _record('Source handoff: $reason');
    } catch (error) {
      if (!mounted) return;
      final reason = 'Could not pause YouTube Music: $error. '
          'Pause the source app manually.';
      setState(() => _sourcePause = reason);
      _record(reason);
    } finally {
      _pausingSource = false;
    }
  }

  Future<void> _play() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _state = 'Preparing playback and pausing YouTube Music…';
      _lastError = '';
    });
    try {
      await _pauseMusicSource('VYBE Play button');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (!_ready) {
      _playOnReady = true;
      setState(() => _state = 'Waiting for YouTube player to become ready…');
      return;
    }
    _record('Play requested by tester');
    await _send('window.vybePlay && window.vybePlay();');
  }

  Future<void> _pause() async {
    _playOnReady = false;
    _resumeVideoAfterCall = false;
    _record('Pause requested');
    await _send('window.vybePause && window.vybePause();');
  }

  Future<void> _stop() async {
    _playOnReady = false;
    _resumeVideoAfterCall = false;
    _record('Stop requested');
    await _send('window.vybeStop && window.vybeStop();');
  }

  Future<Map<String, dynamic>?> _sourceSnapshot() async {
    try {
      final raw = await _control.invokeMapMethod<String, dynamic>(
          'integrationDiagnostics', {'service': 'youtube_music'});
      if (raw == null) return null;
      return Map<String, dynamic>.from(raw);
    } catch (error) {
      _record('Could not read source MediaSession: $error');
      return null;
    }
  }

  String _activeVideoId(Map<String, dynamic> snapshot) {
    final probe = snapshot['videoProbe'];
    if (probe is! Map) return '';
    final candidate = probe['activeQueueVideoId']?.toString() ?? '';
    return RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(candidate)
        ? candidate : '';
  }

  String _activeTitle(Map<String, dynamic> snapshot) {
    final metadata = snapshot['metadata'];
    return metadata is Map ? metadata['title']?.toString() ?? '' : '';
  }

  String _activeArtist(Map<String, dynamic> snapshot) {
    final metadata = snapshot['metadata'];
    return metadata is Map ? metadata['artist']?.toString() ?? '' : '';
  }

  Future<void> _readSourceStatus() async {
    final snapshot = await _sourceSnapshot();
    if (!mounted || snapshot == null) return;
    final actions = snapshot['actions'];
    final skipAllowed = actions is Map && actions['skipNext'] == true;
    final id = _activeVideoId(snapshot);
    setState(() {
      _sourceTitle = _activeTitle(snapshot);
      _sourceArtist = _activeArtist(snapshot);
      _queueStatus = snapshot['sessionFound'] == true
          ? 'Source: $_sourceArtist — $_sourceTitle; '
              'active thumbnail ID: ${id.isEmpty ? "none" : id}; '
              'Skip Next: ${skipAllowed ? "available" : "unsupported"}'
          : 'YouTube Music session not found';
    });
    _record(_queueStatus);
  }

  /// Polling is intentionally limited to this open test page. On an actual
  /// phone, READ_PHONE_STATE detects RINGING as well as OFFHOOK; an Android
  /// stereo may instead report Bluetooth HFP calls through AudioManager
  /// MODE_RINGTONE / MODE_IN_CALL / MODE_IN_COMMUNICATION.
  Future<void> _pollCallState() async {
    if (_disposed || _callPollBusy) return;
    _callPollBusy = true;
    try {
      final state = await _control.invokeMapMethod<String, dynamic>(
          'musicVideoCallState');
      if (!mounted || state == null) return;
      final active = state['inCall'] == true;
      final permissionNeeded = state['permissionNeeded'] == true;
      final signal = state['detection']?.toString() ?? 'unknown';
      if (_callPermissionNeeded != permissionNeeded ||
          _inCall != active || (_inCall && _callStatus != 'Call detected: $signal')) {
        setState(() {
          _callPermissionNeeded = permissionNeeded;
          _callStatus = active ? 'Call detected: $signal'
              : permissionNeeded
                  ? 'Phone permission needed to detect incoming ringing'
                  : 'No call detected (monitoring enabled)';
        });
      }
      if (active == _inCall) return;
      _inCall = active;
      if (active) {
        _record('Phone/BT call started: $signal');
        _resumeVideoAfterCall = _state == 'Playing' ||
            _state == 'Buffering' || _playOnReady;
        _resumeSourceAfterCall = _sourceAudioFallback;
        _playOnReady = false;
        await _send('window.vybePause && window.vybePause();');
        if (_sourceAudioFallback) {
          _sourcePauseConfirmed = false;
          await _pauseMusicSource('Incoming call during source-audio fallback');
        }
      } else {
        _record('Call ended; restoring the audio path that was active');
        if (_waitingAfterCall) {
          // The video is complete; advance the playlist instead of
          // restarting an already-finished video after the call.
          _resumeVideoAfterCall = false;
        }
        if (_resumeVideoAfterCall && !_sourceAudioFallback) {
          // YouTube Music sometimes resumes on its own after a BT phone call.
          // Pause the source again BEFORE restarting embedded video audio.
          _sourcePauseConfirmed = false;
          await _pauseMusicSource('Call completed; returning to embedded video');
          await _send('window.vybePlay && window.vybePlay();');
        } else if (_resumeSourceAfterCall && _sourceAudioFallback) {
          await _resumeMusicSource();
        }
        _resumeVideoAfterCall = false;
        _resumeSourceAfterCall = false;
        if (_waitingAfterCall) {
          _waitingAfterCall = false;
          unawaited(_advanceToNext('Video ended during call'));
        }
      }
    } catch (error) {
      _record('Call-state check unavailable: $error');
    } finally {
      _callPollBusy = false;
    }
  }

  Future<void> _requestCallPermission() async {
    try {
      final granted = await _control.invokeMethod<bool>(
          'requestMusicVideoCallPermission');
      _record('Phone call detection permission: ${granted == true ? "enabled" : "not granted"}');
      await _pollCallState();
    } catch (error) {
      _record('Could not request call detection: $error');
    }
  }

  Future<void> _resumeMusicSource() async {
    try {
      final result = await _control.invokeMapMethod<String, dynamic>(
          'resumeYoutubeMusicForVideoTest');
      if (!mounted) return;
      final reason = result?['reason']?.toString() ?? 'Unknown source resume status';
      setState(() => _sourcePause = reason);
      _record('Source audio resume: $reason');
    } catch (error) {
      _record('Source audio could not resume: $error');
    }
  }

  /// One video completion must produce at most one source-player Skip Next.
  /// Do not silently skip an unrelated track when the iframe ID no longer
  /// matches YouTube Music's CURRENT queue item.
  Future<void> _advanceToNext(String trigger) async {
    if (!mounted || _disposed || _advancing) return;
    if (_inCall) {
      _waitingAfterCall = true;
      _record('Next-video transition deferred during phone call');
      return;
    }
    final token = ++_sequenceToken;
    setState(() {
      _advancing = true;
      _transitionStatus = 'Verifying source queue before Skip Next…';
    });
    _record('Automatic next triggered: $trigger');
    try {
      final before = await _sourceSnapshot();
      if (!mounted || token != _sequenceToken) return;
      if (before == null || before['sessionFound'] != true) {
        setState(() => _transitionStatus = 'No YouTube Music session to advance');
        _record(_transitionStatus);
        return;
      }
      final sourceId = _activeVideoId(before);
      if (sourceId.isEmpty || sourceId != _videoId) {
        setState(() => _transitionStatus =
            'Queue mismatch: YouTube Music video ID '
            '${sourceId.isEmpty ? "not published" : sourceId} '
            'does not match embedded $_videoId. No skip sent.');
        _record(_transitionStatus);
        return;
      }
      final actions = before['actions'];
      if (actions is! Map || actions['skipNext'] != true) {
        setState(() => _transitionStatus =
            'YouTube Music does not expose Skip Next; no skip sent');
        _record(_transitionStatus);
        return;
      }
      final beforeId = before['activeQueueItemId']?.toString() ?? '';
      final beforeTitle = _activeTitle(before);
      await _send('window.vybeStop && window.vybeStop();');
      final command = await _control.invokeMapMethod<String, dynamic>(
          'advanceYoutubeMusicForVideoTest');
      if (!mounted || token != _sequenceToken) return;
      if (command?['sent'] != true) {
        setState(() => _transitionStatus =
            command?['reason']?.toString() ?? 'Skip Next refused');
        _record(_transitionStatus);
        return;
      }
      _record('Skip Next sent from "$beforeTitle" (queue ID $beforeId)');
      setState(() => _transitionStatus =
          'Skip Next sent; waiting for new MediaSession metadata…');
      // Allow time for YouTube Music to publish the next real queue entry.
      for (var attempt = 0; attempt < 17; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (!mounted || token != _sequenceToken) return;
        if (_inCall) {
          _record('Call interrupted queue transition; check session after call');
          setState(() => _transitionStatus =
              'Call interrupted queue transition. Inspect report and retry manually.');
          return;
        }
        final after = await _sourceSnapshot();
        if (!mounted || token != _sequenceToken) return;
        if (after == null || after['sessionFound'] != true) continue;
        final nextQueueId = after['activeQueueItemId']?.toString() ?? '';
        final nextTitle = _activeTitle(after);
        final changedId = beforeId != '-1' && nextQueueId != '-1' &&
            nextQueueId != beforeId;
        final changedTitle = nextTitle.isNotEmpty &&
            nextTitle != beforeTitle;
        if (!changedId && !changedTitle) continue;
        final nextId = _activeVideoId(after);
        _sourceTitle = nextTitle;
        _sourceArtist = _activeArtist(after);
        _queueStatus = 'New source track: $_sourceArtist — $_sourceTitle; '
            'queue ID $nextQueueId; video ID ${nextId.isEmpty ? "not published" : nextId}';
        _record(_queueStatus);
        if (nextId.isEmpty) {
          // The full theme will do a verified video lookup here; this
          // diagnostic deliberately avoids guessing an unrelated video.
          _sourceAudioFallback = true;
          _playOnReady = false;
          setState(() => _transitionStatus =
              'Next song has no published video ID. Testing fallback: '
              'resume source-player audio; no guessed video.');
          await _resumeMusicSource();
          return;
        }
        _videoId = nextId;
        _sourceAudioFallback = false;
        _sourcePauseConfirmed = false;
        await _pauseMusicSource('Next track reported by YouTube Music');
        if (!mounted || token != _sequenceToken) return;
        setState(() => _transitionStatus =
            'Next video ID found: $nextId; starting YouTube iframe…');
        await _load(playOnReady: true);
        return;
      }
      setState(() => _transitionStatus =
          'Timed out: source did not publish a different queue item '
          'after Skip Next. No second skip was sent.');
      _record(_transitionStatus);
    } catch (error) {
      if (mounted) {
        setState(() => _transitionStatus =
            'Next-video diagnostic failed: $error');
        _record(_transitionStatus);
      }
    } finally {
      if (mounted) setState(() => _advancing = false);
    }
  }

  void _copyReport() {
    final content = const JsonEncoder.withIndent('  ').convert({
      'test': 'YouTube IFrame player inside VYBE Android WebView',
      'initialVideoId': widget.videoId,
      'currentVideoId': _videoId,
      'automaticNext': _automaticNext,
      'sourceTitle': _sourceTitle,
      'sourceArtist': _sourceArtist,
      'queueStatus': _queueStatus,
      'transitionStatus': _transitionStatus,
      'callStatus': _callStatus,
      'callPermissionNeeded': _callPermissionNeeded,
      'audioCallActive': _inCall,
      'usingSourceAudioFallback': _sourceAudioFallback,
      'controlsShown': _showYoutubeControls,
      'playerReady': _ready,
      'currentState': _state,
      'sourcePause': _sourcePause,
      'sourcePauseConfirmed': _sourcePauseConfirmed,
      'lastError': _lastError,
      'events': _events,
      'note': 'Successful identification does not guarantee that a video '
          'allows embedding or provides moving-picture music video content.',
    });
    Clipboard.setData(ClipboardData(text: content));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Embedded-player test report copied')),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _callTimer?.cancel();
    _sequenceToken++;
    _playOnReady = false;
    // Do not permit the iframe to keep playing after its test page closes.
    unawaited(_web.runJavaScript('window.vybeStop && window.vybeStop();')
        .catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF0B0B0F),
    appBar: AppBar(
      backgroundColor: const Color(0xFF0B0B0F),
      title: const Text('Embedded video test'),
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 36),
            children: [
              Text('YouTube ID: $_videoId',
                  style: const TextStyle(fontSize: 15, color: Colors.white70)),
              const SizedBox(height: 10),
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ColoredBox(
                  color: Colors.black,
                  child: WebViewWidget(controller: _web),
                ),
              ),
              const SizedBox(height: 10),
              Text('Status: $_state',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 5),
              Text(_transitionStatus,
                  style: const TextStyle(color: Colors.cyanAccent, fontSize: 12)),
              const SizedBox(height: 4),
              Text(_queueStatus,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              Text(_callStatus,
                  style: TextStyle(
                    color: _inCall ? Colors.orangeAccent : Colors.white70,
                    fontSize: 12,
                  )),
              if (_callPermissionNeeded) ...[
                const SizedBox(height: 6),
                FilledButton.icon(
                  onPressed: _requestCallPermission,
                  icon: const Icon(Icons.phone_in_talk),
                  label: const Text('Enable incoming call detection'),
                ),
              ],
              if (_lastError.isNotEmpty)
                Text(_lastError, style: const TextStyle(color: Colors.amber)),
              const SizedBox(height: 6),
              Text(_sourcePause,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _play,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play video'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _pause,
                    icon: const Icon(Icons.pause),
                    label: const Text('Pause'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _stop,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _advancing ? null
                        : () => _advanceToNext('Manual Next test button'),
                    icon: const Icon(Icons.skip_next),
                    label: const Text('Test next video'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _load(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reload'),
                  ),
                ],
              ),
              SwitchListTile(
                title: const Text('Automatically play next video'),
                subtitle: const Text('When the iframe reports Ended, '
                    'send one Skip Next to YouTube Music, wait for its '
                    'new track metadata, then load its next video ID. '
                    'Only advances when the current video ID matches '
                    'the active YouTube Music queue entry.'),
                value: _automaticNext,
                onChanged: (value) => setState(() => _automaticNext = value),
              ),
              OutlinedButton.icon(
                onPressed: _readSourceStatus,
                icon: const Icon(Icons.playlist_play),
                label: const Text('Read current YouTube Music queue'),
              ),
              SwitchListTile(
                title: const Text('Show YouTube player controls'),
                subtitle: const Text('Diagnostic fallback if hidden-control '
                    'playback is blocked. Recreates the video player.'),
                value: _showYoutubeControls,
                onChanged: (value) {
                  setState(() => _showYoutubeControls = value);
                  unawaited(_load());
                },
              ),
              const Text('Two-track playback diagnostic, not the finished '
                  'Music Video theme. Start with YouTube Music in Video mode '
                  'and a playlist with at least two tracks. The embedded '
                  'video ID must match its active queue video ID. Play a '
                  'video to test automatic handoff, or tap Test next video '
                  'without waiting for the video to finish. If the next '
                  'track has no published YouTube video ID, this test '
                  'resumes source audio rather than guessing a match. '
                  'Cellular ringing detection needs optional phone permission; '
                  'standalone head units use Android audio-call mode where '
                  'available. Embedded autoplay may still be blocked. '
                  'Close the page to stop the test video. ',

                  style: TextStyle(fontSize: 12, color: Colors.white70)),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _copyReport,
                icon: const Icon(Icons.copy),
                label: const Text('Copy playback test report'),
              ),
              ExpansionTile(
                title: const Text('Playback events'),
                children: [
                  SelectableText(_events.join('\n'),
                      style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 11,
                        color: Colors.white70,
                      )),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
