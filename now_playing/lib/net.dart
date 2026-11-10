import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'settings.dart';

/// All online lookups are optional. Missing metadata must not break playback
/// or replace valid media-session/local artwork with a guess.
///
/// MusicBrainz identifies releases; Cover Art Archive and Fanart.tv provide
/// their cover images. This module does not use Apple services.
Future<void> _musicBrainzGate = Future<void>.value();
DateTime _nextMusicBrainzRequest = DateTime.fromMillisecondsSinceEpoch(0);

/// Serialize this module's MusicBrainz requests at just below 1 request/s.
/// Artist fanart has its own client and may also share the public IP.
Future<void> _waitForMusicBrainz() {
  final previous = _musicBrainzGate;
  final ready = Completer<void>();
  _musicBrainzGate = ready.future;
  return () async {
    try {
      await previous;
      final delay = _nextMusicBrainzRequest.difference(DateTime.now());
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      _nextMusicBrainzRequest =
          DateTime.now().add(const Duration(milliseconds: 1150));
    } finally {
      ready.complete();
    }
  }();
}

Future<Uint8List?> httpGetBytes(Uri uri) async {
  if (uri.scheme != 'https') return null;
  if (uri.host == 'musicbrainz.org') await _waitForMusicBrainz();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final req = await client.getUrl(uri);
    req.headers.set('User-Agent',
        'VYBE/1.9.9 (https://github.com/azarel444/VYBE; Android music metadata lookup)');
    final res = await req.close().timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      await res.drain<void>();
      return null;
    }
    final builder = BytesBuilder();
    await for (final chunk in res.timeout(const Duration(seconds: 15))) {
      builder.add(chunk);
      if (builder.length > 6 * 1024 * 1024) return null;
    }
    return builder.takeBytes();
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<String?> httpGetString(Uri uri) async {
  final bytes = await httpGetBytes(uri);
  if (bytes == null) return null;
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return null;
  }
}

String _norm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

bool _hasAlbumTag(String album) {
  final normalized = _norm(album);
  return normalized.isNotEmpty && !const <String>{
    'unknown', 'unknownalbum', 'albumunknown', 'notavailable',
    'na', 'none', 'null',
  }.contains(normalized);
}

String _cleanTitle(String s) => s.replaceAll(
  RegExp(
    r'\s*[\(\[][^\)\]]*(?:official(?:\s+music)?\s+video|lyric\s+video|visualizer|remaster(?:ed)?|extended|radio edit|version)[^\)\]]*[\)\]]',
    caseSensitive: false,
  ),
  '',
).trim();

String _quoted(String value) =>
    '"${value.replaceAll('"', '').trim()}"';

bool _looksLikeImage(Uint8List b) => b.length > 12 && (
  (b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) ||
  (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47) ||
  (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
   b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50)
);

Future<Map<String, dynamic>?> _musicBrainzJson(Uri uri) async {
  final body = await httpGetString(uri);
  if (body == null) return null;
  try {
    final result = jsonDecode(body);
    if (result is Map<String, dynamic>) return result;
  } catch (_) {}
  return null;
}

class _ReleaseGroup {
  final String id;
  final String title;
  const _ReleaseGroup(this.id, this.title);
}

/// Require a true exact credited-artist match, not a substring match.
bool _artistCreditMatches(dynamic credit, String requestedArtist) {
  if (credit is! List) return false;
  final expected = _norm(requestedArtist);
  if (expected.isEmpty) return false;
  for (final entry in credit) {
    if (entry is! Map) continue;
    if (_norm(entry['name']?.toString() ?? '') == expected) return true;
    final artist = entry['artist'];
    if (artist is Map &&
        (_norm(artist['name']?.toString() ?? '') == expected ||
         _norm(artist['sort-name']?.toString() ?? '') == expected)) {
      return true;
    }
  }
  return false;
}

List<_ReleaseGroup> _groupsFromReleases(dynamic releases) {
  if (releases is! List) return const [];
  final result = <_ReleaseGroup>[];
  final seen = <String>{};
  for (final release in releases) {
    if (release is! Map) continue;
    final group = release['release-group'];
    if (group is! Map) continue;
    final id = group['id']?.toString() ?? '';
    final title = group['title']?.toString().trim() ?? '';
    if (id.isEmpty || title.isEmpty || !seen.add(id)) continue;
    final secondary = group['secondary-types'];
    if (secondary is List && secondary.any((x) =>
        const ['Compilation', 'Soundtrack', 'DJ-mix']
            .contains(x?.toString()))) {
      continue;
    }
    result.add(_ReleaseGroup(id, title));
  }
  return result;
}

Future<List<_ReleaseGroup>> _albumReleaseGroups(
    String artist, String album) async {
  if (_norm(artist).isEmpty || _norm(album).isEmpty) return const [];
  final albumVariants = <String>{
    album.trim(),
    album.replaceAll(
      RegExp(
        r'\s*[\(\[][\s\S]*?(?:remaster|deluxe|anniversary|edition)[\s\S]*?[\)\]]',
        caseSensitive: false,
      ),
      '',
    ).trim(),
  }..removeWhere((s) => s.isEmpty);

  final groups = <_ReleaseGroup>[];
  final seen = <String>{};
  for (final albumVariant in albumVariants) {
    final query =
        'releasegroup:${_quoted(albumVariant)} AND artist:${_quoted(artist)}';
    final json = await _musicBrainzJson(
      Uri.https('musicbrainz.org', '/ws/2/release-group/', {
        'query': query, 'fmt': 'json', 'limit': '12',
      }),
    );
    final entries = json?['release-groups'];
    if (entries is! List) continue;
    for (final entry in entries) {
      if (entry is! Map) continue;
      final id = entry['id']?.toString() ?? '';
      final name = entry['title']?.toString() ?? '';
      if (id.isEmpty || _norm(name) != _norm(albumVariant) ||
          !_artistCreditMatches(entry['artist-credit'], artist) ||
          !seen.add(id)) {
        continue;
      }
      groups.add(_ReleaseGroup(id, name));
    }
    if (groups.isNotEmpty) break;
  }
  return groups;
}

final Map<String, Future<List<_ReleaseGroup>>> _recordingInFlight = {};

/// Verify the recording's actual credited artist and song, then collect its
/// release groups. Multiple releases are left for the caller to disambiguate.
Future<List<_ReleaseGroup>> _recordingGroups(
    String title, String artist) {
  if (_norm(title).isEmpty || _norm(artist).isEmpty) {
    return Future.value(const <_ReleaseGroup>[]);
  }
  final key = '${_norm(artist)}|${_norm(_cleanTitle(title))}';
  final existing = _recordingInFlight[key];
  if (existing != null) return existing;
  final task = _loadRecordingGroups(title, artist);
  _recordingInFlight[key] = task;
  task.then((groups) {
    // Do not cache misses: a transient network error remains retryable.
    if (groups.isEmpty && identical(_recordingInFlight[key], task)) {
      _recordingInFlight.remove(key);
    }
  }, onError: (Object _) {
    if (identical(_recordingInFlight[key], task)) {
      _recordingInFlight.remove(key);
    }
  });
  if (_recordingInFlight.length > 35) {
    _recordingInFlight.remove(_recordingInFlight.keys.first);
  }
  return task;
}

Future<List<_ReleaseGroup>> _loadRecordingGroups(
    String title, String artist) async {
  final term =
      'recording:${_quoted(_cleanTitle(title))} AND artist:${_quoted(artist)}';
  final json = await _musicBrainzJson(
    Uri.https('musicbrainz.org', '/ws/2/recording/', {
      'query': term, 'fmt': 'json', 'limit': '12',
    }),
  );
  final recordings = json?['recordings'];
  if (recordings is! List) return const [];
  final groups = <_ReleaseGroup>[];
  final seen = <String>{};
  var inspected = 0;
  for (final entry in recordings) {
    if (entry is! Map) continue;
    if (_norm(_cleanTitle(entry['title']?.toString() ?? '')) !=
            _norm(_cleanTitle(title)) ||
        !_artistCreditMatches(entry['artist-credit'], artist)) {
      continue;
    }
    var releases = _groupsFromReleases(entry['releases']);
    // MusicBrainz recording search and recording lookups don't always attach
    // release-group data to the nested releases. Browse the verified
    // recording's releases instead: release-group is supported on a release.
    if (releases.isEmpty && inspected++ < 2) {
      final id = entry['id']?.toString() ?? '';
      if (id.isNotEmpty) {
        final details = await _musicBrainzJson(Uri.https(
          'musicbrainz.org', '/ws/2/release/', {
            'recording': id, 'inc': 'release-groups', 'fmt': 'json',
            'limit': '100',
          },
        ));
        final total = details?['release-count'];
        // More than one page cannot prove an unambiguous match, so decline
        // rather than silently pick a potentially unrelated edition.
        if (total is int && total <= 100) {
          releases = _groupsFromReleases(details?['releases']);
        }
      }
    }
    for (final release in releases) {
      if (seen.add(release.id)) groups.add(release);
    }
  }
  return groups;
}

Future<Uint8List?> _coverArtArchiveImage(String releaseGroupId) async {
  for (final path in [
    '/release-group/$releaseGroupId/front-500',
    '/release-group/$releaseGroupId/front',
  ]) {
    final bytes = await httpGetBytes(Uri.https('coverartarchive.org', path));
    if (bytes != null && _looksLikeImage(bytes)) return bytes;
  }
  return null;
}

/// Fanart.tv album API v3 returns albums keyed by release-group MBID;
/// v3.2 uses entries with release_group_id. Accept both layouts by ID.
Future<Uint8List?> _fanartAlbumImage(String releaseGroupId) async {
  final projectKey = AppSettings.bundledFanartProjectKey;
  if (projectKey.isEmpty) return null;
  final body = await httpGetString(Uri.https(
    'webservice.fanart.tv', '/v3/music/albums/$releaseGroupId',
    {'api_key': projectKey},
  ));
  if (body == null) return null;
  dynamic album;
  try {
    final data = jsonDecode(body);
    if (data is! Map) return null;
    final albums = data['albums'];
    if (albums is Map) {
      album = albums[releaseGroupId];
      if (album == null) {
        for (final entry in albums.entries) {
          if (entry.key.toString().toLowerCase() ==
              releaseGroupId.toLowerCase()) {
            album = entry.value;
            break;
          }
        }
      }
    } else if (albums is List) {
      for (final entry in albums) {
        if (entry is Map &&
            entry['release_group_id']?.toString().toLowerCase() ==
                releaseGroupId.toLowerCase()) {
          album = entry;
          break;
        }
      }
    }
  } catch (_) {
    return null;
  }
  if (album is! Map) return null;
  final covers = album['albumcover'];
  if (covers is! List) return null;
  for (final entry in covers.take(3)) {
    if (entry is! Map || entry['url'] is! String) continue;
    final uri = Uri.tryParse(entry['url'] as String);
    if (uri == null || uri.scheme != 'https' ||
        uri.host != 'assets.fanart.tv') {
      continue;
    }
    final bytes = await httpGetBytes(uri);
    if (bytes != null && _looksLikeImage(bytes)) return bytes;
  }
  return null;
}

Future<Uint8List?> _coverForGroups(List<_ReleaseGroup> groups) async {
  for (final group in groups.take(3)) {
    final cover = await _coverArtArchiveImage(group.id);
    if (cover != null) return cover;
    final fanart = await _fanartAlbumImage(group.id);
    if (fanart != null) return fanart;
  }
  return null;
}

/// Prefer exact artist + track identification. The incoming album tag can
/// be a user-defined folder/playlist name (e.g. "Bangers"), not the title of
/// any official release. Do not require that tag to match the verified song's
/// release group. Never guess between multiple different release groups.
Future<Uint8List?> fetchArtwork(
    String title, String artist, {String album = ''}) async {
  if (_norm(artist).isEmpty || _norm(title).isEmpty) return null;

  final recordingGroups = await _recordingGroups(title, artist);
  if (_hasAlbumTag(album)) {
    // If the track is cataloged on the supplied album, prefer that exact
    // release over other singles, remix collections or reissues.
    final exactAlbumGroups = recordingGroups
        .where((g) => _norm(g.title) == _norm(album)).toList();
    if (exactAlbumGroups.isNotEmpty) {
      final matchedCover = await _coverForGroups(exactAlbumGroups);
      if (matchedCover != null) return matchedCover;
    }
  }

  // A uniquely identified artist+recording can supply artwork even if its
  // official release differs from a custom album tag. Keep the album label
  // the player supplied; this only recovers the missing image.
  if (recordingGroups.length == 1) {
    final songCover = await _coverForGroups(recordingGroups);
    if (songCover != null) return songCover;
  }

  // No unambiguous song cover: keep the existing conservative artist + album
  // fallback for tracks with genuine album tags. Unknown/custom albums simply
  // return null instead of borrowing unrelated artwork.
  if (_hasAlbumTag(album)) {
    final albumGroups = await _albumReleaseGroups(artist, album);
    return _coverForGroups(albumGroups);
  }
  return null;
}

/// Exact song lookup via MusicBrainz -> Cover Art Archive / Fanart.tv.
Future<Uint8List?> fetchSongSpecificArtwork(
    String title, String artist) async {
  if (_norm(artist).isEmpty || _norm(title).isEmpty) return null;
  final groups = await _recordingGroups(title, artist);
  if (groups.length != 1) return null;
  return _coverForGroups(groups);
}

/// For songs without an album tag, only identify a uniquely matched release.
Future<String?> fetchSongReleaseTitle(
    String title, String artist) async {
  if (_norm(artist).isEmpty || _norm(title).isEmpty) return null;
  final groups = await _recordingGroups(title, artist);
  if (groups.length != 1) return null;
  final release = groups.single.title.trim();
  return release.isEmpty ? null : release;
}

/// Independent Cover Art Archive lookup for clients with album metadata.
Future<Uint8List?> fetchCoverArtArchive(
    String artist, String album) async {
  final groups = await _albumReleaseGroups(artist, album);
  for (final group in groups.take(3)) {
    final cover = await _coverArtArchiveImage(group.id);
    if (cover != null) return cover;
  }
  return null;
}
