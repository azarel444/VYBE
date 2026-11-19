import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Music Video: user-initiated official YouTube embed with the source player's
/// audio paused during video playback. When no verified video is available,
/// the normal source audio and VYBE fanart/album art remain the fallback.
/// Only YouTube IDs and overlay preferences are cached, never video streams.
class MusicVideoTheme extends StatefulWidget {
  final String title;
  final String artist;
  final String album;
  final String sourcePackage;
  final Uint8List? artwork;
  final Uint8List? fanart;
  final Uint8List? clearLogo;
  final Color accent;
  final int sourcePositionMs;
  final int sourceDurationMs;
  final bool sourcePlaying;
  final Future<void> Function(int) onSeekSource;
  final Future<void> Function() onSourcePlayPause;
  final VoidCallback onOpenThemes;
  final VoidCallback onOpenCustomize;
  final VoidCallback onOpenSettings;

  const MusicVideoTheme({
    super.key,
    required this.title,
    required this.artist,
    required this.album,
    required this.sourcePackage,
    required this.accent,
    required this.sourcePositionMs,
    required this.sourceDurationMs,
    required this.sourcePlaying,
    required this.onSeekSource,
    required this.onSourcePlayPause,
    required this.onOpenThemes,
    required this.onOpenCustomize,
    required this.onOpenSettings,
    this.artwork,
    this.fanart,
    this.clearLogo,
  });

  @override
  State<MusicVideoTheme> createState() => _MusicVideoThemeState();
}

class _MusicVideoThemeState extends State<MusicVideoTheme> {
  static const _channel = MethodChannel('nowplaying/control');
  static const _origin = 'https://com.conjure.now_playing';
  static const _ytMusic = 'com.google.android.apps.youtube.music';

  late final WebViewController _web;
  Timer? _callTimer;
  bool _busy = false;
  bool _embedded = false;
  bool _ready = false;
  bool _playWhenReady = false;
  bool _videoPlaying = false;
  bool _advancing = false;
  bool _pausedSource = false;
  bool _inCall = false;
  bool _resumeAfterCall = false;
  bool _disposed = false;
  bool _showLogo = true;
  bool _showInfo = true;
  bool _showVinyl = true;
  int _generation = 0;
  String _sourcePackage = '';
  String _title = '';
  String _artist = '';
  String _album = '';
  String _videoId = '';
  String _status = 'Press Play to find a matching music video';
  double _position = 0;
  double _duration = 0;
  bool _scrubbing = false;
  double _seekPreview = 0;
  DateTime _ignoreOldProgressUntil = DateTime.fromMillisecondsSinceEpoch(0);
  double? _fallbackSeekPosition;
  DateTime _fallbackSeekUntil = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _sourcePackage = widget.sourcePackage;
    _title = widget.title;
    _artist = widget.artist;
    _album = widget.album;
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel('VybeVideo',
          onMessageReceived: (message) => _handleVideoEvent(message.message))
      ..setNavigationDelegate(NavigationDelegate(
        onWebResourceError: (error) {
          if (error.isForMainFrame == true && mounted && _embedded) {
            unawaited(_fallback('Video player unavailable: ' + error.description));
          }
        },
      ));
    if (_web.platform is AndroidWebViewController) {
      unawaited((_web.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false));
    }
    unawaited(_loadOverlayChoices());
    _callTimer = Timer.periodic(const Duration(milliseconds: 1100),
        (_) => unawaited(_checkCall()));
  }

  @override
  void didUpdateWidget(covariant MusicVideoTheme oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sourcePackage.isNotEmpty && _sourcePackage.isEmpty) {
      _sourcePackage = widget.sourcePackage;
    }
    if (oldWidget.title != widget.title || oldWidget.artist != widget.artist) {
      // New track published from outside this theme; never leave the old
      // video running underneath a different MediaSession song.
      if (!_advancing && (_title != widget.title || _artist != widget.artist)) {
        final hadVideo = _embedded;
        _generation++;
        _embedded = false;
        _ready = false;
        _playWhenReady = false;
        _videoPlaying = false;
        _videoId = '';
        _position = 0;
        _duration = 0;
        _fallbackSeekPosition = null;
        if (hadVideo) {
          unawaited(_send('window.vybeStop && window.vybeStop();'));
          unawaited(_resumeSource());
        }
        _status = 'New track — press Play to load its video';
      }
      _title = widget.title;
      _artist = widget.artist;
      _album = widget.album;
    }
  }

  String get _songKey =>
      'vybe_music_video_id|' + _artist.trim().toLowerCase() + '|' +
      _title.trim().toLowerCase();

  Future<void> _loadOverlayChoices() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _showLogo = prefs.getBool('musicVideoShowLogo') ?? true;
      _showInfo = prefs.getBool('musicVideoShowInfo') ?? true;
      _showVinyl = prefs.getBool('musicVideoShowVinyl') ?? true;
    });
  }

  Future<void> _toggleOverlay(String name) async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      if (name == 'logo') _showLogo = !_showLogo;
      if (name == 'info') _showInfo = !_showInfo;
      if (name == 'vinyl') _showVinyl = !_showVinyl;
    });
    await prefs.setBool('musicVideoShowLogo', _showLogo);
    await prefs.setBool('musicVideoShowInfo', _showInfo);
    await prefs.setBool('musicVideoShowVinyl', _showVinyl);
  }

  static String _normalize(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  static String _validId(Object? candidate) {
    final value = candidate?.toString().trim() ?? '';
    return RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(value) ? value : '';
  }

  static String _idFromUri(Object? raw) {
    final uri = Uri.tryParse(raw?.toString() ?? '');
    if (uri == null) return '';
    final host = uri.host.toLowerCase();
    final path = uri.pathSegments;
    if ((host == 'i.ytimg.com' || host == 'img.youtube.com') &&
        path.length >= 2 && (path[0] == 'vi' || path[0] == 'vi_webp')) {
      return _validId(path[1]);
    }
    if (host == 'youtu.be' && path.isNotEmpty) {
      return _validId(path.first);
    }
    if (host == 'youtube.com' || host == 'www.youtube.com' ||
        host == 'music.youtube.com' || host == 'm.youtube.com') {
      if (path.length >= 2 && path.first == 'embed') {
        return _validId(path[1]);
      }
      if (path.length >= 2 && path.first == 'shorts') {
        return _validId(path[1]);
      }
      return _validId(uri.queryParameters['v']);
    }
    return '';
  }

  String _verifiedYoutubeMusicId(Map<dynamic, dynamic> snapshot) {
    final meta = snapshot['metadata'];
    if (meta is! Map ||
        _normalize(meta['title']?.toString() ?? '') != _normalize(_title)) {
      return '';
    }
    final queue = snapshot['queue'];
    if (queue is List) {
      final exact = <String>{};
      for (final item in queue) {
        if (item is! Map ||
            _normalize(item['title']?.toString() ?? '') != _normalize(_title)) {
          continue;
        }
        final id = _validId(item['youtubeThumbnailVideoId']);
        final fromUri = _idFromUri(item['artworkUri']);
        if (id.isNotEmpty) exact.add(id);
        if (fromUri.isNotEmpty) exact.add(fromUri);
      }
      if (exact.length == 1) return exact.single;
      if (exact.length > 1) return '';
    }
    for (final value in [
      meta['mediaId'],
      _idFromUri(meta['artUri']),
      _idFromUri(meta['albumArtUri']),
      _idFromUri(meta['displayIconUri']),
    ]) {
      final id = _validId(value);
      if (id.isNotEmpty) return id;
    }
    final probe = snapshot['videoProbe'];
    if (probe is Map &&
        _normalize(probe['descriptionTitle']?.toString() ?? '') ==
            _normalize(_title)) {
      for (final value in [
        probe['activeMediaId'],
        _idFromUri(probe['activeMediaUri']),
        probe['activeQueueVideoId'],
      ]) {
        final id = _validId(value);
        if (id.isNotEmpty) return id;
      }
    }
    return '';
  }

  Future<String> _findVideo() async {
    if (_title.isEmpty || _artist.isEmpty) return '';
    final prefs = await SharedPreferences.getInstance();
    // The proven automatic identity route is YouTube Music's actual current
    // MediaSession metadata and title-matched queue artwork. Never guess an
    // unrelated video from a search-result title.
    if (_sourcePackage == _ytMusic) {
      try {
        final snapshot = await _channel.invokeMapMethod<String, dynamic>(
            'integrationDiagnostics', {'service': 'youtube_music'});
        if (snapshot != null && snapshot['sessionFound'] == true) {
          final id = _verifiedYoutubeMusicId(snapshot);
          if (id.isNotEmpty) {
            await prefs.setString(_songKey, id);
            return id;
          }
        }
      } catch (_) {}
    }
    // A previously confirmed/manual link is portable across local music,
    // Spotify and other media players with the same artist/song identity.
    final saved = _validId(prefs.getString(_songKey));
    if (saved.isNotEmpty) return saved;
    final related = await _musicBrainzVideoId();
    if (related.isNotEmpty) await prefs.setString(_songKey, related);
    return related;
  }

  /// Optional exact recording-to-video relationship fallback for Spotify
  /// and local players; no automated YouTube search-result guessing.
  Future<String> _musicBrainzVideoId() async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      Future<Map<String, dynamic>?> fetch(Uri uri) async {
        final req = await client!.getUrl(uri).timeout(const Duration(seconds: 7));
        req.headers.set(HttpHeaders.userAgentHeader, 'VYBE/1.9 (Music Video metadata)');
        final response = await req.close().timeout(const Duration(seconds: 7));
        if (response.statusCode != 200) return null;
        final decoded = jsonDecode(await utf8.decoder.bind(response)
            .join().timeout(const Duration(seconds: 7)));
        return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
      }
      final title = _title.replaceAll('"', '').trim();
      final artist = _artist.replaceAll('"', '').trim();
      if (title.isEmpty || artist.isEmpty) return '';
      final search = await fetch(Uri.https('musicbrainz.org',
          '/ws/2/recording/', {'query': 'recording:"' + title +
          '" AND artist:"' + artist + '"', 'fmt': 'json', 'limit': '5'}));
      final recs = search?['recordings'];
      if (recs is! List) return '';
      final ids = <String>[];
      for (final entry in recs) {
        if (entry is! Map ||
            _normalize(entry['title']?.toString() ?? '') != _normalize(title)) continue;
        final credits = entry['artist-credit'];
        if (credits is! List || !credits.whereType<Map>().any((credit) =>
            credit['artist'] is Map &&
            _normalize(credit['artist']['name']?.toString() ?? '') ==
                _normalize(artist))) continue;
        final id = entry['id']?.toString() ?? '';
        if (RegExp(r'^[0-9a-f-]{36}$').hasMatch(id)) ids.add(id);
        if (ids.length >= 2) break;
      }
      final results = <String>{};
      for (final id in ids) {
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        final recording = await fetch(Uri.https('musicbrainz.org',
            '/ws/2/recording/' + id, {'inc': 'url-rels', 'fmt': 'json'}));
        final links = recording?['relations'];
        if (links is! List) continue;
        for (final relation in links) {
          if (relation is! Map ||
              (relation['type'] != 'free streaming' &&
               relation['type'] != 'streaming')) continue;
          final attributes = relation['attributes'], url = relation['url'];
          if (attributes is! List || !attributes.contains('video') || url is! Map) continue;
          final id = _idFromUri(url['resource']);
          if (id.isNotEmpty) results.add(id);
        }
      }
      return results.length == 1 ? results.single : '';
    } catch (_) { return ''; }
    finally { client?.close(force: true); }
  }

  Future<Map<dynamic, dynamic>?> _sourceSnapshot() async {
    if (_sourcePackage.isEmpty) return null;
    try {
      return await _channel.invokeMapMethod<dynamic, dynamic>(
          'musicVideoSourceSnapshot', {'package': _sourcePackage});
    } catch (_) {
      return null;
    }
  }

  Future<Map<dynamic, dynamic>?> _sourceCommand(
      String action, String expectedTitle) async {
    if (_sourcePackage.isEmpty) return null;
    try {
      return await _channel.invokeMapMethod<dynamic, dynamic>(
          'musicVideoSourceControl', {
        'package': _sourcePackage,
        'action': action,
        'expectedTitle': expectedTitle,
      });
    } catch (_) {
      return null;
    }
  }

  Future<bool> _pauseSource() async {
    final result = await _sourceCommand('pause', _title);
    final confirmed = result?['paused'] == true || result?['alreadyPaused'] == true;
    if (result?['paused'] == true) _pausedSource = true;
    if (!confirmed && mounted) {
      setState(() => _status = result?['reason']?.toString() ??
          'Could not pause the source player safely');
    }
    return confirmed;
  }

  Future<void> _resumeSource() async {
    if (!_pausedSource) return;
    _pausedSource = false;
    await _sourceCommand('resume', _title);
  }

  Future<void> _send(String script) async {
    try {
      await _web.runJavaScript(script);
    } catch (_) {}
  }

  String _iframe(String id) => '''
<!doctype html><html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<meta name="referrer" content="strict-origin-when-cross-origin">
<style>html,body,#player{padding:0;margin:0;width:100%;height:100%;overflow:hidden;background:#000}</style>
</head><body><div id="player"></div><script>
var vybePlayer=null;
function vybeEvent(event,detail) {
 try { window.VybeVideo.postMessage(JSON.stringify({event:event,detail:String(detail)})); } catch(e){}
}
window.vybePlay=function(){if(vybePlayer)vybePlayer.playVideo();};
window.vybePause=function(){if(vybePlayer)vybePlayer.pauseVideo();};
window.vybeStop=function(){if(vybePlayer)vybePlayer.stopVideo();};
window.vybeSeek=function(seconds){
 if(vybePlayer && typeof vybePlayer.seekTo==='function'){
   vybePlayer.seekTo(Math.max(0,seconds),true);
 }
};
function onYouTubeIframeAPIReady() {
 try {
  vybePlayer=new YT.Player('player',{
   width:'100%',height:'100%',videoId:'$id',
   playerVars:{autoplay:0,controls:0,playsinline:1,rel:0,enablejsapi:1,origin:'$_origin'},
   events:{
    onReady:function(){vybeEvent('ready','ok');},
    onStateChange:function(e){
     var s={'-1':'Unstarted','0':'Ended','1':'Playing','2':'Paused','3':'Buffering','5':'Cued'};
     vybeEvent('state',s[e.data]||'Unknown');
    },
    onError:function(e){vybeEvent('error',e.data);},
    onAutoplayBlocked:function(){vybeEvent('error','Autoplay blocked');}
   }
  });
 }catch(e){vybeEvent('error',e.message);}
}
setInterval(function(){
 if(!vybePlayer||!vybePlayer.getCurrentTime)return;
 try {vybeEvent('progress',vybePlayer.getCurrentTime()+','+vybePlayer.getDuration());}catch(e){}
},850);
var tag=document.createElement('script');tag.src='https://www.youtube.com/iframe_api';
tag.onerror=function(){vybeEvent('error','Player API unavailable');};
document.head.appendChild(tag);
</script></body></html>
''';

  Future<void> _loadVideo(String id) async {
    if (!mounted) return;
    setState(() {
      _videoId = id;
      _embedded = true;
      _ready = false;
      _playWhenReady = true;
      _videoPlaying = false;
      _position = 0;
      _duration = 0;
      _scrubbing = false;
      _seekPreview = 0;
      _status = 'Loading verified music video…';
    });
    try {
      await _web.loadHtmlString(_iframe(id), baseUrl: '$_origin/');
    } catch (error) {
      await _fallback('Could not open embedded video: ' + error.toString());
    }
  }

  Future<void> _beginVideo() async {
    if (_busy || _advancing || _inCall || _title.isEmpty || _artist.isEmpty) return;
    if (_embedded && _ready) {
      if (await _pauseSource()) {
        await _send('window.vybePlay && window.vybePlay();');
      }
      return;
    }
    final token = ++_generation;
    setState(() {
      _busy = true;
      _status = 'Finding a verified music video for this song…';
    });
    final id = await _findVideo();
    if (!mounted || token != _generation) return;
    if (id.isEmpty) {
      setState(() {
        _busy = false;
        _status = 'No verified video yet — music continues with VYBE artwork';
      });
      // After video-driven Skip Next, the source may still be muted.
      // Fallback must always restore the original music app's audio.
      await _resumeSource();
      return;
    }
    if (!await _pauseSource()) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted || token != _generation) return;
    setState(() => _busy = false);
    await _loadVideo(id);
  }

  Future<void> _fallback(String reason) async {
    if (!mounted) return;
    _generation++;
    _playWhenReady = false;
    _videoPlaying = false;
    await _send('window.vybeStop && window.vybeStop();');
    if (!mounted) return;
    setState(() {
      _embedded = false;
      _ready = false;
      _status = reason;
    });
    await _resumeSource();
  }

  void _handleVideoEvent(String raw) {
    if (!mounted || !_embedded) return;
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return;
      final type = value['event']?.toString() ?? '';
      final detail = value['detail']?.toString() ?? '';
      if (type == 'ready') {
        _ready = true;
        if (_playWhenReady && !_inCall) {
          _playWhenReady = false;
          unawaited(_send('window.vybePlay && window.vybePlay();'));
        }
      } else if (type == 'state') {
        if (detail == 'Playing') {
          if (_inCall) {
            unawaited(_send('window.vybePause && window.vybePause();'));
          } else {
            _videoPlaying = true;
            unawaited(_pauseSource());
          }
        } else {
          _videoPlaying = false;
          if (detail == 'Ended' && !_advancing) unawaited(_advance());
        }
        setState(() => _status = detail == 'Playing'
            ? 'Music video playing' : 'Video: ' + detail);
      } else if (type == 'progress') {
        final parts = detail.split(',');
        if (parts.length == 2) {
          final current = double.tryParse(parts[0]);
          final total = double.tryParse(parts[1]);
          setState(() {
            if (total != null && total.isFinite && total > 0) _duration = total;
            // Do not let late WebView progress overwrite the user's drag.
            if (!_scrubbing &&
                DateTime.now().isAfter(_ignoreOldProgressUntil) &&
                current != null && current.isFinite) {
              _position = current;
            }
          });
        }
      } else if (type == 'error') {
        final message = detail == '101' || detail == '150'
            ? 'This video does not allow embedding — using VYBE artwork'
            : 'YouTube video unavailable (' + detail + ')';
        unawaited(_fallback(message));
      }
    } catch (_) {}
  }

  Future<void> _advance({bool previous = false}) async {
    if (_busy || _advancing || _inCall || _sourcePackage.isEmpty) return;
    final previousTitle = _title;
    final token = ++_generation;
    setState(() {
      _advancing = true;
      _status = previous ? 'Previous track…' : 'Finding the next video…';
    });
    await _send('window.vybeStop && window.vybeStop();');
    final command = await _sourceCommand(previous ? 'previous' : 'next',
        previousTitle);
    if (!mounted || token != _generation) return;
    if (command?['sent'] != true) {
      setState(() {
        _advancing = false;
        _status = command?['reason']?.toString() ?? 'Unable to change source track';
      });
      return;
    }
    // Retain source-audio ownership until a video or art fallback finishes.
    String nextTitle = '';
    String nextArtist = '';
    String nextAlbum = '';
    for (var i = 0; i < 17; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 750));
      if (!mounted || token != _generation) return;
      if (_inCall) break;
      final snapshot = await _sourceSnapshot();
      final title = snapshot?['title']?.toString() ?? '';
      if (title.isEmpty || _normalize(title) == _normalize(previousTitle)) {
        continue;
      }
      nextTitle = title;
      nextArtist = snapshot?['artist']?.toString() ?? '';
      nextAlbum = snapshot?['album']?.toString() ?? '';
      break;
    }
    if (!mounted || token != _generation) return;
    setState(() {
      _advancing = false;
      _embedded = false;
      _ready = false;
      _videoPlaying = false;
      if (nextTitle.isNotEmpty) {
        _title = nextTitle;
        _artist = nextArtist;
        _album = nextAlbum;
        _videoId = '';
      }
      _status = nextTitle.isEmpty
          ? 'Waiting for source playlist to update'
          : 'Looking up the next track video…';
    });
    if (nextTitle.isEmpty) {
      await _resumeSource();
      return;
    }
    // The official iframe is re-created for every independently verified
    // next track. An absent ID simply leaves source audio and art available.
    await _beginVideo();
  }

  Future<void> _checkCall() async {
    try {
      final state = await _channel.invokeMapMethod<String, dynamic>(
          'musicVideoCallState');
      if (!mounted || state == null) return;
      final active = state['inCall'] == true;
      if (active == _inCall) return;
      _inCall = active;
      if (active) {
        _resumeAfterCall = _videoPlaying || _playWhenReady;
        _playWhenReady = false;
        await _send('window.vybePause && window.vybePause();');
      } else if (_resumeAfterCall && _embedded) {
        _resumeAfterCall = false;
        if (await _pauseSource()) {
          await _send('window.vybePlay && window.vybePlay();');
        }
      }
    } catch (_) {}
  }

  /// Seek the video that is actually playing in VYBE's YouTube iframe.
  /// The original YouTube Music MediaSession remains paused while embedded
  /// playback owns the audio; seeking it would affect the wrong player.
  Future<void> _seekVideo(double seconds) async {
    if (!_embedded || !_ready || _duration <= 0 || _inCall) return;
    final target = seconds.clamp(0.0, _duration).toDouble();
    setState(() {
      _scrubbing = false;
      _position = target;
      _seekPreview = target;
      _ignoreOldProgressUntil =
          DateTime.now().add(const Duration(milliseconds: 1100));
    });
    await _send('window.vybeSeek && window.vybeSeek(' +
        target.toStringAsFixed(3) + ');');
  }

  /// The same mockup slider also seeks source audio when no verified video
  /// exists, instead of becoming a decorative, dead control.
  Future<void> _seekPlayback(double seconds) async {
    if (_embedded) {
      await _seekVideo(seconds);
      return;
    }
    if (widget.sourceDurationMs <= 0 || _inCall) return;
    final target = seconds.clamp(
        0.0, widget.sourceDurationMs / 1000.0).toDouble();
    setState(() {
      _scrubbing = false;
      _seekPreview = target;
      _fallbackSeekPosition = target;
      _fallbackSeekUntil = DateTime.now().add(
          const Duration(milliseconds: 1500));
    });
    await widget.onSeekSource((target * 1000).round());
  }

  Future<void> _togglePlay() async {
    if (!_embedded) {
      await widget.onSourcePlayPause();
      return;
    }
    if (_embedded && _videoPlaying) {
      await _send('window.vybePause && window.vybePause();');
      if (mounted) setState(() => _videoPlaying = false);
    } else {
      await _beginVideo();
    }
  }

  Future<void> _linkVideo() async {
    final input = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1822),
        title: const Text('Link a music video'),
        content: TextField(
          controller: input, autofocus: true, autocorrect: false,
          decoration: const InputDecoration(
            hintText: 'YouTube link or 11-character video ID',
            helperText: 'Saves the link for this artist and song',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, input.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    input.dispose();
    if (!mounted || raw == null) return;
    final id = _validId(raw).isNotEmpty ? _validId(raw) : _idFromUri(raw);
    if (id.isEmpty) {
      setState(() => _status = 'Invalid YouTube video link');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_songKey, id);
    if (mounted) {
      // A replacement link must replace the current iframe, not resume it.
      if (_embedded) {
        await _send('window.vybeStop && window.vybeStop();');
        if (mounted) setState(() {
          _embedded = false;
          _ready = false;
          _videoPlaying = false;
        });
      }
      if (!mounted) return;
      setState(() => _status = 'Video link saved for this song');
      await _beginVideo();
    }
  }

  static String _clock(double seconds) {
    final time = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
    return (time ~/ 60).toString() + ':' + (time % 60).toString().padLeft(2, '0');
  }

  Widget _videoBackdrop() {
    final bytes = widget.fanart ?? widget.artwork;
    return Stack(fit: StackFit.expand, children: [
      if (bytes != null)
        ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Transform.scale(scale: 1.14, child: Image.memory(bytes,
              fit: BoxFit.cover, gaplessPlayback: true)))
      else
        const DecoratedBox(decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFF171020), Color(0xFF100B19), Colors.black]))),
      const ColoredBox(color: Color(0x93000000)),
      const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        stops: [0, .25, .74, 1],
        colors: [Color(0xC0000000), Colors.transparent,
          Color(0x30000000), Color(0xE8000000)]))),
    ]);
  }

  /// Black vinyl with radial reflections and fine groove rings, viewed
  /// partly behind the sleeve rather than centered under a small thumbnail.
  Widget _referenceVinyl(double diameter) {
    return Container(
      width: diameter, height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          stops: [0, .07, .10, .16, .19, .28, .32, .50, .54, .73, .77, 1],
          colors: [
            Color(0xFF353941), Color(0xFF15151B), Color(0xFF44444B),
            Color(0xFF0B0D10), Color(0xFF3A3A41), Color(0xFF111216),
            Color(0xFF35353C), Color(0xFF0B0C10), Color(0xFF303138),
            Color(0xFF101115), Color(0xFF33343B), Color(0xFF07080B),
          ],
        ),
        boxShadow: [
          BoxShadow(color: widget.accent.withOpacity(.27),
              blurRadius: 42, spreadRadius: 4),
          const BoxShadow(color: Color(0xB5000000),
              blurRadius: 24, offset: Offset(10, 14)),
        ],
      ),
      child: CustomPaint(painter: _MusicVideoVinylGrooves()),
    );
  }

  Widget _ringTransport(IconData icon, VoidCallback? onTap,
      double diameter, String tooltip) {
    return Tooltip(message: tooltip, child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(width: diameter, height: diameter,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0x30050D10),
            border: Border.all(color: widget.accent.withOpacity(.92),
                width: 1.2),
          ),
          child: Center(child: Icon(icon, color: Colors.white,
              size: diameter * .58)),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, bounds) {
      final w = bounds.maxWidth, h = bounds.maxHeight;
      final portrait = h > w * 1.1;
      // Landscape anchors follow the supplied 1536x864 reference:
      // artwork x=1.3%, y=74.7%, width=28.5%; record peeks out behind it
      // to the right. Transport is x=44.8%..96.8%, y≈92%.
      final artSide = portrait ? w * .63 : w * .285;
      final artLeft = portrait ? w * .035 : w * .013;
      final artTop = portrait ? h * .69 : h * .747;
      final discSide = artSide * .72;
      final discLeft = artLeft + artSide * .80;
      final discTop = artTop + artSide * .075;
      final transportWidth = portrait ? w * .94 : w * .52;
      final transportRight = portrait ? w * .03 : w * .032;
      final transportBottom = portrait ? h * .035 : h * .038;
      final transportHeight = portrait ? 68.0 : (h * .084).clamp(62.0, 76.0).toDouble();
      final iconSize = portrait ? 39.0
          : (h * .061).clamp(40.0, 55.0).toDouble();
      final iconGap = portrait ? 7.0 : w * .015;
      final infoWidth = portrait ? w * .46 : w * .27;
      final duration = _embedded ? _duration
          : widget.sourceDurationMs / 1000.0;
      final position = _embedded ? _position
          : (_fallbackSeekPosition != null &&
             DateTime.now().isBefore(_fallbackSeekUntil)
              ? _fallbackSeekPosition!
              : widget.sourcePositionMs / 1000.0);
      final canSeek = !_inCall && (_embedded
          ? _ready && _duration > 0 : widget.sourceDurationMs > 0);
      final isPlaying = _embedded ? _videoPlaying : widget.sourcePlaying;

      return ClipRect(child: Stack(fit: StackFit.expand, children: [
        // Keep existing artist imagery as a safe fallback while a verified
        // video is not available. Never display an empty, black-only theme.
        _videoBackdrop(),
        if (_embedded)
          Positioned.fill(child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.center,
              minWidth: 0, minHeight: 0,
              maxWidth: double.infinity, maxHeight: double.infinity,
              child: SizedBox(
                // Enlarge to 16:9 and crop overflow; never letterbox the
                // full-screen reference inside a centered small rectangle.
                width: math.max(w, h * (16 / 9)),
                height: math.max(h, w * (9 / 16)),
                child: WebViewWidget(controller: _web),
              ),
            ),
          )),
        // Light vignette protects white logos over bright video frames.
        // No full-width black control panel or permanently visible clock.
        const Positioned.fill(child: IgnorePointer(child: DecoratedBox(
          decoration: BoxDecoration(gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            stops: [0, .21, .62, 1],
            colors: [Color(0x72000000), Color(0x12000000),
                     Color(0x00000000), Color(0x70000000)],
          )),
        ))),
        if (!_embedded)
          Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.play_circle_outline_rounded,
              color: widget.accent, size: portrait ? 52 : 76),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _beginVideo,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xCC11171C),
                foregroundColor: Colors.white),
              icon: _busy
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow_rounded),
              label: Text(_busy ? 'FINDING VIDEO' : 'PLAY MUSIC VIDEO'),
            ),
          ])),
        if (_showVinyl) ...[
          // A broad album-colored lamp-like bloom, not just a thin outline.
          Positioned(
            left: artLeft - artSide * .20,
            top: artTop - artSide * .21,
            width: artSide * 1.75, height: artSide * 1.30,
            child: IgnorePointer(child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-.13, -.12),
                  radius: .79,
                  colors: [
                    widget.accent.withOpacity(.48),
                    widget.accent.withOpacity(.24),
                    widget.accent.withOpacity(.08),
                    Colors.transparent,
                  ],
                  stops: const [0, .42, .73, 1],
                ),
              ),
            )),
          ),
          Positioned(left: discLeft, top: discTop,
            width: discSide, height: discSide,
            child: IgnorePointer(child: _referenceVinyl(discSide))),
          Positioned(
            left: artLeft, top: artTop,
            width: artSide, height: artSide,
            child: IgnorePointer(child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(color: widget.accent.withOpacity(.67),
                    blurRadius: 48, spreadRadius: 4),
                  const BoxShadow(color: Color(0xB0000000),
                    blurRadius: 24, offset: Offset(6, 14)),
                ],
                border: Border.all(color: widget.accent.withOpacity(.91),
                  width: 1.8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: widget.artwork == null
                    ? const ColoredBox(color: Color(0xFF0E1315),
                        child: Center(child: Icon(Icons.album,
                          color: Colors.white38, size: 55)))
                    : Image.memory(widget.artwork!, fit: BoxFit.cover,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.high),
              ),
            )),
          ),
        ],
        if (_showLogo)
          Positioned(
            left: portrait ? w * .025 : w * .024,
            top: portrait ? h * .025 : h * .045,
            width: portrait ? w * .43 : w * .185,
            height: portrait ? h * .155 : h * .29,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onOpenThemes,
              onLongPress: widget.onOpenCustomize,
              onDoubleTap: widget.onOpenSettings,
              child: Align(alignment: Alignment.topLeft,
                child: widget.clearLogo != null
                  ? Image.memory(widget.clearLogo!,
                      fit: BoxFit.contain,
                      alignment: Alignment.topLeft,
                      gaplessPlayback: true)
                  : Text(_artist.toUpperCase(),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white,
                        fontSize: portrait ? w * .060 : w * .030,
                        fontWeight: FontWeight.w800,
                        fontStyle: FontStyle.italic,
                        shadows: const [
                          Shadow(color: Colors.black, blurRadius: 12),
                        ])),
              ),
            ),
          ),
        if (_showInfo)
          Positioned(
            right: portrait ? w * .035 : w * .031,
            top: portrait ? h * .035 : h * .049,
            width: infoWidth,
            child: IgnorePointer(child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_title, textAlign: TextAlign.right,
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white,
                    fontSize: portrait ? w * .055 : (w * .020).clamp(18.0, 32.0).toDouble(),
                    fontWeight: FontWeight.w500,
                    letterSpacing: .05,
                    shadows: const [
                      Shadow(color: Color(0xDD000000), blurRadius: 10),
                    ])),
                if (_album.isNotEmpty &&
                    _normalize(_album) != _normalize(_title)) ...[
                  const SizedBox(height: 10),
                  Text(_album, textAlign: TextAlign.right,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white,
                      fontSize: portrait ? w * .038 : (w * .015).clamp(13.0, 24.0).toDouble(),
                      letterSpacing: .08,
                      shadows: const [
                        Shadow(color: Color(0xDD000000), blurRadius: 10),
                      ])),
                ],
              ],
            )),
          ),
        // EXACTLY ONE interaction row, aligned at lower right of the mockup.
        // In contrast to the previous noninteractive progress indicator,
        // this slider seeks the actual embedded YouTube video.
        Positioned(
          right: transportRight, bottom: transportBottom,
          width: transportWidth, height: transportHeight,
          child: Row(crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _ringTransport(Icons.arrow_left_rounded,
                  _advancing ? null
                      : () => unawaited(_advance(previous: true)),
                  iconSize, 'Previous song'),
              SizedBox(width: iconGap),
              _ringTransport(isPlaying ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
                  _busy || _advancing ? null
                      : () => unawaited(_togglePlay()),
                  iconSize, isPlaying ? 'Pause' : 'Play'),
              SizedBox(width: iconGap),
              Expanded(child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(height: transportHeight * .60,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: portrait ? 5.0 : 9.0,
                        activeTrackColor: widget.accent,
                        inactiveTrackColor: widget.accent.withOpacity(.73),
                        thumbColor: const Color(0xFF050C10),
                        disabledThumbColor: const Color(0xFF050C10),
                        overlayColor: widget.accent.withOpacity(.25),
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius: portrait ? 9 : 15,
                          disabledThumbRadius: portrait ? 8 : 13,
                          elevation: 0, pressedElevation: 0),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 17),
                      ),
                      child: Slider(
                        value: (_scrubbing ? _seekPreview : position)
                          .clamp(0.0, duration > 0 ? duration : 1.0)
                          .toDouble(),
                        min: 0.0,
                        max: duration > 0 ? duration : 1.0,
                        onChangeStart: canSeek
                          ? (value) => setState(() {
                              _scrubbing = true; _seekPreview = value;
                            }) : null,
                        onChanged: canSeek
                          ? (value) => setState(() => _seekPreview = value)
                          : null,
                        onChangeEnd: canSeek
                          ? (value) => unawaited(_seekPlayback(value))
                          : null,
                      ),
                    ),
                  ),
                  Text(
                    _clock(_scrubbing ? _seekPreview : position) +
                    ' - ' + (duration > 0 ? _clock(duration) : '0:00'),
                    maxLines: 1,
                    style: TextStyle(color: Colors.white,
                      fontSize: portrait ? 11.0 : (h * .020).clamp(12.0, 18.0).toDouble()),
                  ),
                ],
              )),
              SizedBox(width: iconGap),
              _ringTransport(Icons.arrow_right_rounded,
                  _advancing ? null : () => unawaited(_advance()),
                  iconSize, 'Next song'),
            ],
          ),
        ),
        if (_status.isNotEmpty && (_busy || _advancing || !_embedded))
          Positioned(left: portrait ? w * .12 : w * .33,
            right: portrait ? w * .12 : w * .33,
            bottom: transportBottom + transportHeight + 14,
            child: IgnorePointer(child: Text(_status,
              textAlign: TextAlign.center, maxLines: 2,
              style: const TextStyle(color: Colors.white70, fontSize: 12,
                shadows: [Shadow(color: Colors.black, blurRadius: 8)])))),
      ]));
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _callTimer?.cancel();
    unawaited(_send('window.vybeStop && window.vybeStop();'));
    if (!_inCall) unawaited(_resumeSource());
    super.dispose();
  }
}

/// Subtle grooves catch the light near the exposed right side of the record.
class _MusicVideoVinylGrooves extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide / 2;
    for (var i = 0; i < 28; i++) {
      final radius = r * (.35 + i * .021);
      canvas.drawCircle(c, radius, Paint()
        ..color = Colors.white.withOpacity(i.isEven ? .043 : .023)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .65);
    }
    canvas.drawCircle(c, r * .095, Paint()
      ..color = const Color(0xFF141418));
    canvas.drawCircle(c, r * .021, Paint()
      ..color = const Color(0xFF767B85));
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Offline, nonplaying theme-library preview. Never starts video or YouTube
/// network activity merely because the user browses available themes.
class MusicVideoThemePreview extends StatelessWidget {
  final Uint8List? artwork;
  final Uint8List? fanart;
  final Uint8List? clearLogo;
  final String title;
  final String album;
  final String artist;
  final Color accent;

  const MusicVideoThemePreview({
    super.key,
    this.artwork,
    this.fanart,
    this.clearLogo,
    required this.title,
    required this.album,
    required this.artist,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final portrait = h > w * 1.1;
      final side = portrait ? w * .63 : w * .285;
      final left = portrait ? w * .035 : w * .013;
      final top = portrait ? h * .69 : h * .747;
      final discSide = side * .72;
      return ClipRect(child: Stack(fit: StackFit.expand, children: [
        // A static fanart approximation for the theme gallery. Never start
        // YouTube/WebView simply by browsing the theme preview.
        if (fanart != null || artwork != null)
          Image.memory(fanart ?? artwork!, fit: BoxFit.cover,
              gaplessPlayback: true)
        else
          const ColoredBox(color: Color(0xFF091319)),
        const Positioned.fill(child: ColoredBox(color: Color(0x32000000))),
        Positioned(
          left: left - side * .20, top: top - side * .21,
          width: side * 1.75, height: side * 1.30,
          child: DecoratedBox(decoration: BoxDecoration(
            gradient: RadialGradient(
              colors: [accent.withOpacity(.55),
                accent.withOpacity(.18), Colors.transparent],
            ),
          )),
        ),
        Positioned(left: left + side * .80, top: top + side * .075,
          width: discSide, height: discSide,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                colors: [Color(0xFF2F3138), Color(0xFF0C0D12),
                  Color(0xFF34343C), Colors.black],
                stops: [0, .33, .67, 1],
              ),
            ),
            child: CustomPaint(painter: _MusicVideoVinylGrooves()),
          ),
        ),
        Positioned(left: left, top: top, width: side, height: side,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: accent, width: 1.1),
              boxShadow: [BoxShadow(color: accent.withOpacity(.55),
                blurRadius: 11, spreadRadius: 2)],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: artwork != null
                ? Image.memory(artwork!, fit: BoxFit.cover)
                : const ColoredBox(color: Color(0xFF121518)),
            ),
          ),
        ),
        Positioned(left: w * .024, top: h * .045,
          width: portrait ? w * .43 : w * .185,
          height: portrait ? h * .155 : h * .29,
          child: Align(alignment: Alignment.topLeft,
            child: clearLogo != null
              ? Image.memory(clearLogo!, fit: BoxFit.contain,
                  alignment: Alignment.topLeft)
              : Text(artist.isEmpty ? 'VYBE' : artist.toUpperCase(),
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontStyle: FontStyle.italic,
                    fontSize: portrait ? w * .047 : w * .022)),
          ),
        ),
        Positioned(right: w * .032, top: h * .049,
          width: portrait ? w * .46 : w * .27,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(title.isEmpty ? 'MUSIC VIDEO' : title,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(color: Colors.white,
                    fontSize: portrait ? w * .048 : w * .020)),
              if (album.isNotEmpty &&
                  album.trim().toLowerCase() != title.trim().toLowerCase())
                Text(album, textAlign: TextAlign.right,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white70,
                    fontSize: portrait ? w * .030 : w * .014)),
            ],
          )),
        Positioned(right: w * .032, bottom: h * .038,
          width: portrait ? w * .94 : w * .52,
          height: h * .084,
          child: Row(children: [
            Icon(Icons.arrow_circle_left_outlined,
              color: accent, size: h * .054),
            SizedBox(width: w * .012),
            Icon(Icons.pause_circle_outline_rounded,
              color: accent, size: h * .054),
            SizedBox(width: w * .016),
            Expanded(child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(height: math.max(2.0, h * .009).toDouble(),
                  decoration: BoxDecoration(color: accent,
                    borderRadius: BorderRadius.circular(3))),
                SizedBox(height: h * .016),
                Text('1:22 - 4:45',
                  style: TextStyle(color: Colors.white,
                    fontSize: math.max(7.0, h * .017).toDouble())),
              ],
            )),
            SizedBox(width: w * .016),
            Icon(Icons.arrow_circle_right_outlined,
              color: accent, size: h * .054),
          ]),
        ),
      ]));
    },
  );
}
