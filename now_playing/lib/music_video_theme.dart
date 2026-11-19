import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

  const MusicVideoTheme({
    super.key,
    required this.title,
    required this.artist,
    required this.album,
    required this.sourcePackage,
    required this.accent,
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
function onYouTubeIframeAPIReady() {
 try {
  vybePlayer=new YT.Player('player',{
   width:'100%',height:'100%',videoId:'$id',
   playerVars:{autoplay:0,controls:1,playsinline:1,rel:0,enablejsapi:1,origin:'$_origin'},
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
          _position = double.tryParse(parts[0]) ?? _position;
          _duration = double.tryParse(parts[1]) ?? _duration;
          if (mounted) setState(() {});
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

  Future<void> _togglePlay() async {
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

  Widget _vinyl(double size) {
    final art = widget.artwork;
    return SizedBox(width: size * 1.32, height: size * 1.25,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(left: -size * .13, bottom: -size * .40,
          width: size, height: size,
          child: DecoratedBox(
            decoration: BoxDecoration(shape: BoxShape.circle,
              gradient: const RadialGradient(stops: [0,.16,.18,.27,.29,.43,.45,.67,.7,1],
                colors: [
                  Color(0xFF4E4A56), Color(0xFF0F0E12),
                  Color(0xFF5A5261), Color(0xFF111117),
                  Color(0xFF302F35), Color(0xFF09090D),
                  Color(0xFF3A3940), Color(0xFF0D0D10),
                  Color(0xFF29272E), Color(0xFF040407)]),
              boxShadow: [BoxShadow(color: widget.accent.withOpacity(.35),
                  blurRadius: 26, spreadRadius: 1)]))),
        Positioned(left: size * .35, bottom: 0, width: size * .79,
          height: size * .79,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: widget.accent.withOpacity(.8), width: 1.2),
              borderRadius: BorderRadius.circular(5),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(.7),
                  blurRadius: 15)]),
            child: ClipRRect(borderRadius: BorderRadius.circular(4),
              child: art == null
                ? const ColoredBox(color: Color(0xFF12111A),
                    child: Center(child: Icon(Icons.album, color: Colors.white38)))
                : Image.memory(art, fit: BoxFit.cover, gaplessPlayback: true)),
          )),
      ]));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, bounds) {
      final w = bounds.maxWidth, h = bounds.maxHeight;
      final portrait = h > w * 1.1;
      final headerHeight = portrait ? h * .16 : h * .145;
      final footerHeight = portrait ? 82.0 : 66.0;
      final recordSize = portrait ? w * .34 : h * .245;
      return ClipRect(child: Stack(fit: StackFit.expand, children: [
        _videoBackdrop(),
        if (_embedded)
          Positioned(left: portrait ? 0 : w * .10,
            right: portrait ? 0 : w * .10,
            top: headerHeight, bottom: footerHeight,
            child: Center(child: AspectRatio(aspectRatio: 16 / 9,
              child: ColoredBox(color: Colors.black,
                child: WebViewWidget(controller: _web))))),
        if (!_embedded)
          Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.play_circle_outline_rounded,
                size: portrait ? 66 : 80,
                color: widget.accent.withOpacity(.93)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _beginVideo,
              icon: _busy ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow_rounded),
              label: Text(_busy ? 'FINDING VIDEO' : 'PLAY MUSIC VIDEO'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xD9211B29),
                foregroundColor: Colors.white),
            ),
          ])),
        if (_showVinyl)
          Positioned(left: portrait ? -w * .055 : -h * .055,
            bottom: footerHeight + (portrait ? 8 : 2),
            child: IgnorePointer(child: _vinyl(recordSize))),
        // All VYBE decoration is outside the iframe controls/attribution.
        Positioned(left: 0, right: 0, top: 0, height: headerHeight,
          child: Padding(padding: EdgeInsets.symmetric(
              horizontal: portrait ? 13 : 28, vertical: 5),
            child: Row(children: [
              if (_showLogo)
                Expanded(flex: 4, child: Align(alignment: Alignment.centerLeft,
                  child: widget.clearLogo != null
                    ? Image.memory(widget.clearLogo!,
                        fit: BoxFit.contain, height: headerHeight * .72)
                    : Text(_artist.toUpperCase(), maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white,
                          fontSize: portrait ? 20 : 28,
                          fontWeight: FontWeight.w800, fontStyle: FontStyle.italic,
                          shadows: const [Shadow(color: Colors.black,
                            blurRadius: 12)]))))
              else
                const Spacer(flex: 1),
              const SizedBox(width: 12),
              if (_showInfo)
                Expanded(flex: 5, child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(_title, textAlign: TextAlign.right, maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: portrait ? 15 : 23)),
                  if (_album.isNotEmpty)
                    Text(_album, textAlign: TextAlign.right, maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white70,
                        fontSize: portrait ? 11 : 14)),
                ]))
              else
                const Spacer(flex: 1),
            ]))),
        Positioned(left: 0, right: 0, bottom: 0, height: footerHeight,
          child: Container(
            color: const Color(0xDD090A0F),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              SizedBox(height: 5,
                child: LinearProgressIndicator(
                  value: _duration > 0 ? (_position / _duration).clamp(0.0, 1.0).toDouble() : 0.0,
                  color: widget.accent, backgroundColor: Colors.white12)),
              Expanded(child: Row(children: [
                Text(_clock(_position), style: const TextStyle(
                    color: Colors.white54, fontSize: 11)),
                const Spacer(),
                IconButton(tooltip: 'Previous song',
                  onPressed: _advancing ? null : () => _advance(previous: true),
                  icon: const Icon(Icons.skip_previous_rounded),
                  color: Colors.white),
                IconButton(tooltip: _videoPlaying ? 'Pause video' : 'Play video',
                  onPressed: _busy || _advancing ? null : _togglePlay,
                  icon: Icon(_videoPlaying ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_fill_rounded),
                  iconSize: 32, color: Colors.white),
                IconButton(tooltip: 'Next song',
                  onPressed: _advancing ? null : _advance,
                  icon: const Icon(Icons.skip_next_rounded),
                  color: Colors.white),
                const Spacer(),
                Text(_duration > 0 ? _clock(_duration) : '—:—',
                  style: const TextStyle(color: Colors.white54, fontSize: 11)),
                IconButton(tooltip: 'Link a video for this track',
                  icon: const Icon(Icons.link_rounded), color: Colors.white70,
                  onPressed: _linkVideo),
                PopupMenuButton<String>(
                  tooltip: 'Video overlays', icon: const Icon(
                      Icons.layers_outlined, color: Colors.white70),
                  onSelected: _toggleOverlay,
                  itemBuilder: (context) => [
                    CheckedPopupMenuItem(value: 'logo', checked: _showLogo,
                        child: const Text('Artist / clearlogo')),
                    CheckedPopupMenuItem(value: 'info', checked: _showInfo,
                        child: const Text('Song / album')),
                    CheckedPopupMenuItem(value: 'vinyl', checked: _showVinyl,
                        child: const Text('Album art + vinyl')),
                  ]),
              ])),
            ]))),
        if (_status.isNotEmpty && (_busy || _advancing || !_embedded))
          Positioned(left: portrait ? 12 : w * .24,
            right: portrait ? 12 : w * .24,
            bottom: footerHeight + 8,
            child: IgnorePointer(child: Text(_status,
              textAlign: TextAlign.center, maxLines: 2,
              style: const TextStyle(color: Colors.white70, fontSize: 12,
                shadows: [Shadow(color: Colors.black, blurRadius: 7)])))),
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

/// Offline, nonplaying theme-library preview. Never starts video or YouTube
/// network activity merely because the user browses available themes.
class MusicVideoThemePreview extends StatelessWidget {
  final Uint8List? artwork;
  final String title;
  final String artist;
  final Color accent;

  const MusicVideoThemePreview({super.key, this.artwork,
    required this.title, required this.artist, required this.accent});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final h = box.maxHeight;
      return ClipRect(child: Stack(fit: StackFit.expand, children: [
        if (artwork != null)
          ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Image.memory(artwork!, fit: BoxFit.cover))
        else
          const ColoredBox(color: Color(0xFF10101A)),
        const ColoredBox(color: Color(0x9F000000)),
        Positioned.fill(child: Center(child: Icon(
          Icons.play_circle_outline_rounded,
          color: accent, size: h * .31))),
        Positioned(left: 9, top: 8, width: box.maxWidth * .45,
          child: Text(artist.isEmpty ? 'VYBE' : artist.toUpperCase(),
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: h * .11, color: Colors.white,
              fontWeight: FontWeight.w900, fontStyle: FontStyle.italic))),
        Positioned(right: 9, top: 8, width: box.maxWidth * .42,
          child: Text(title.isEmpty ? 'MUSIC VIDEO' : title,
            textAlign: TextAlign.right, maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: h * .09, color: Colors.white))),
        Positioned(left: 0, right: 0, bottom: 0, height: h * .12,
          child: DecoratedBox(decoration: BoxDecoration(
            color: const Color(0xDD08080F),
            border: Border(top: BorderSide(
                color: accent.withOpacity(.7), width: 2))),
            child: const Center(child: Icon(Icons.play_arrow_rounded,
              color: Colors.white, size: 17)))),
      ]));
    },
  );
}
