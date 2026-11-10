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
  final List<String> releaseIds;
  _ReleaseGroup(this.id, this.title, [List<String>? releaseIds])
      : releaseIds = releaseIds ?? <String>[];
}

/// MusicBrainz keeps artist-credit as separate artists and join phrases,
/// while media players often supply the whole collaboration as one string.
final RegExp _artistJoin = RegExp(
  r'\s+(?:feat(?:uring)?\.?|ft\.?|with|&|and|\+|x|vs\.?)\s+',
  caseSensitive: false,
);

List<String> _creditParts(String value) => value
    .split(_artistJoin)
    .map(_norm)
    .where((name) => name.isNotEmpty)
    .toList();

String _catalogSearchArtist(String artist) {
  final first = artist.trim().split(_artistJoin).first.trim();
  return first.isEmpty ? artist.trim() : first;
}

bool _artistCreditMatches(dynamic credit, String requestedArtist) {
  if (credit is! List) return false;
  final wanted = _norm(requestedArtist);
  if (wanted.isEmpty) return false;
  final credited = <String>{};
  for (final entry in credit) {
    if (entry is! Map) continue;
    final creditedName = entry['name']?.toString() ?? '';
    final artist = entry['artist'];
    final standardName = artist is Map ? artist['name']?.toString() ?? '' : '';
    final sortName = artist is Map ? artist['sort-name']?.toString() ?? '' : '';
    if ([creditedName, standardName, sortName]
        .any((name) => _norm(name) == wanted)) return true;
    // Prefer credited performance names over legal-name changes.
    credited.addAll(_creditParts(
        creditedName.isNotEmpty ? creditedName : standardName));
  }
  final requestedParts = _creditParts(requestedArtist);
  if (requestedParts.isEmpty) return false;
  if (requestedParts.every(credited.contains)) return true;
  // A catalog can credit just the primary artist when the player says
  // "feat. Guest". Only accept lead-only credit if no other guest is
  // credited; the caller must separately verify the full remix title.
  final hasFeature = RegExp(r'\s+(?:feat(?:uring)?\.?|ft\.?)\s+',
      caseSensitive: false).hasMatch(requestedArtist);
  return hasFeature && requestedParts.length > 1 &&
      credited.length == 1 && credited.contains(requestedParts.first);
}

List<_ReleaseGroup> _groupsFromReleases(dynamic releases) {
  if (releases is! List) return const [];
  final result = <String, _ReleaseGroup>{};
  for (final release in releases) {
    if (release is! Map) continue;
    final group = release['release-group'];
    if (group is! Map) continue;
    final id = group['id']?.toString() ?? '';
    final title = group['title']?.toString().trim() ?? '';
    if (id.isEmpty || title.isEmpty) continue;
    final entry = result.putIfAbsent(id, () => _ReleaseGroup(id, title));
    final releaseId = release['id']?.toString() ?? '';
    if (releaseId.isNotEmpty && !entry.releaseIds.contains(releaseId)) {
      entry.releaseIds.add(releaseId);
    }
  }
  return result.values.toList();
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

/// Album lookup diagnostics are kept separate from fanart diagnostics.
String latestArtworkCatalogDiagnostic = 'Not searched';

String _baseTrackTitle(String title) {
  final clean = _cleanTitle(title);
  final base = clean.replaceFirst(
    RegExp(r'\s*[\(\[][^\)\]]*[\)\]]\s*$'),
    '',
  ).trim();
  return base.isEmpty ? clean : base;
}

/// Match the recorded song, including its remixer. The old catalog's
/// searches were flexible, but this final check must not confuse different
/// remixes with the original recording.
String _trackMatchKey(String title) => _norm(
  _cleanTitle(title).replaceAll(
    RegExp(r'\bremix\b', caseSensitive: false), 'mix',
  ),
);

/// Find a trailing remix credit, retaining the exact remixers for validation.
String? _remixCredit(String title) {
  final match = RegExp(r'[\(\[]([^\)\]]+)[\)\]]\s*

/// Like the original working catalog lookup: try complete artist+song,
/// then a broader song title and a plain-text search. Verify each hit by
/// credited artist and full recording title before using artwork.
Future<List<_ReleaseGroup>> _recordingGroups(
    String title, String artist) {
  if (_norm(title).isEmpty || _norm(artist).isEmpty) {
    return Future.value(const <_ReleaseGroup>[]);
  }
  final key = '${_norm(artist)}|${_trackMatchKey(title)}';
  final existing = _recordingInFlight[key];
  if (existing != null) return existing;
  final task = _loadRecordingGroups(title, artist);
  _recordingInFlight[key] = task;
  task.then((groups) {
    // A failed search must be retryable, including after network timeouts.
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
  final fullTitle = _cleanTitle(title);
  final baseTitle = _baseTrackTitle(title);
  // MusicBrainz indexes featured performers separately, but names like
  // "Eli & Fur" are also legitimate single artist entities. Preserve
  // exact full-credit discovery before trying a lead-artist fallback.
  // Validate ALL credits and the full track/remix title on every hit.
  final searchArtist = _catalogSearchArtist(artist);
  final requestedRemix = _remixCredit(fullTitle);
  final remixers = requestedRemix == null
      ? <String>[] : _remixerNames(requestedRemix);
  // Recover the common catalog suffix "(Main Artist & Remixer remix)"
  // when the music file gives just "(Remixer remix)".
  final expandedRemixTitle = requestedRemix != null &&
          remixers.length == 1 &&
          !remixers.contains(_norm(searchArtist))
      ? '$baseTitle ($searchArtist & $requestedRemix remix)'
      : null;
  final queries = <String>{
    // Full names like "Eli & Fur" are real artist entities.
    'recording:${_quoted(fullTitle)} AND artist:${_quoted(artist)}',
    if (_norm(baseTitle) != _norm(fullTitle))
      'recording:${_quoted(baseTitle)} AND artist:${_quoted(artist)}',
    // Use lead-artist fallback only when a combined credit exists.
    // Always verify structured credits AND the exact remix title.
    if (expandedRemixTitle != null)
      'recording:${_quoted(expandedRemixTitle)} AND artist:${_quoted(searchArtist)}',
    if (_norm(searchArtist) != _norm(artist))
      'recording:${_quoted(fullTitle)} AND artist:${_quoted(searchArtist)}',
    if (_norm(searchArtist) != _norm(artist) &&
        _norm(baseTitle) != _norm(fullTitle))
      'recording:${_quoted(baseTitle)} AND artist:${_quoted(searchArtist)}',
    '${_quoted(searchArtist)} ${_quoted(fullTitle)}',
    'recording:${_quoted(fullTitle)}',
  };

  final groups = <_ReleaseGroup>[];
  final seenGroups = <String>{};
  final seenRecordings = <String>{};
  var browseCount = 0;
  var networkResponses = 0;
  void addGroups(List<_ReleaseGroup> items) {
    for (final group in items) {
      if (seenGroups.add(group.id)) {
        groups.add(group);
      } else {
        final existing = groups.firstWhere((g) => g.id == group.id);
        for (final releaseId in group.releaseIds) {
          if (!existing.releaseIds.contains(releaseId)) {
            existing.releaseIds.add(releaseId);
          }
        }
      }
    }
  }

  for (final term in queries) {
    final json = await _musicBrainzJson(
      Uri.https('musicbrainz.org', '/ws/2/recording/', {
        'query': term, 'fmt': 'json', 'limit': '100',
      }),
    );
    if (json == null) continue;
    networkResponses++;
    final recordings = json['recordings'];
    if (recordings is! List) continue;

    for (final entry in recordings) {
      if (entry is! Map) continue;
      if (!_trackMatches(entry['title']?.toString() ?? '', title, artist) ||
          !_artistCreditMatches(entry['artist-credit'], artist)) {
        continue;
      }
      final id = entry['id']?.toString() ?? '';
      if (id.isEmpty || !seenRecordings.add(id)) continue;

      // Some MusicBrainz search results omit release groups from nested
      // releases. Browse verified recordings to get their actual groups.
      // Don't drop compilation releases: the old provider could return
      // their covers when the official single has none.
      addGroups(_groupsFromReleases(entry['releases']));
      if (browseCount++ < 4) {
        final details = await _musicBrainzJson(
          Uri.https('musicbrainz.org', '/ws/2/release/', {
            'recording': id, 'inc': 'release-groups',
            'fmt': 'json', 'limit': '100',
          }),
        );
        addGroups(_groupsFromReleases(details?['releases']));
      }
    }
    if (groups.isNotEmpty) break;
  }

  latestArtworkCatalogDiagnostic = seenRecordings.isEmpty
      ? (networkResponses == 0
          ? 'MusicBrainz request failed or timed out'
          : 'No verified MusicBrainz artist + full song match')
      : (groups.isEmpty
          ? 'Matched ${seenRecordings.length} recording(s); no releases returned'
          : 'Matched ${seenRecordings.length} recording(s), ${groups.length} release group(s)');
  return groups;
}

List<_ReleaseGroup> _rankSongGroups(
    List<_ReleaseGroup> groups, String songTitle) {
  final base = _norm(_baseTrackTitle(songTitle));
  final ranked = List<_ReleaseGroup>.of(groups);
  int score(_ReleaseGroup group) {
    final name = _norm(group.title);
    if (name == base) return 3;
    if (name.startsWith(base) && base.isNotEmpty) return 2;
    if (name.contains(base) && base.isNotEmpty) return 1;
    return 0;
  }
  // Preserve catalog ordering on ties, as the previous song catalog did.
  ranked.sort((a, b) => score(b).compareTo(score(a)));
  return ranked;
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
  // Prefer the release group, then its verified recording's exact release.
  // A release may have front art even when its group has no selected front.
  for (final group in groups.take(10)) {
    final cover = await _coverArtArchiveImage(group.id);
    if (cover != null) return cover;
    for (final releaseId in group.releaseIds.take(3)) {
      for (final path in <String>[
        '/release/$releaseId/front-500',
        '/release/$releaseId/front',
      ]) {
        final bytes = await httpGetBytes(Uri.https('coverartarchive.org', path));
        if (bytes != null && _looksLikeImage(bytes)) return bytes;
      }
    }
    final fanart = await _fanartAlbumImage(group.id);
    if (fanart != null) return fanart;
  }
  return null;
}

/// Recreate the previous working search order with MusicBrainz instead
/// of Apple: artist + album first, then verified artist + recording with
/// full and simplified title search queries. Preserve player album labels.
Future<Uint8List?> fetchArtwork(
    String title, String artist, {String album = ''}) async {
  if (_norm(artist).isEmpty || _norm(title).isEmpty) return null;
  latestArtworkCatalogDiagnostic = 'Searching artist + album, then artist + song';

  if (_hasAlbumTag(album)) {
    final albumGroups = await _albumReleaseGroups(artist, album);
    final matchingAlbumCover = await _coverForGroups(albumGroups);
    if (matchingAlbumCover != null) {
      latestArtworkCatalogDiagnostic = 'Verified artist + album cover found';
      return matchingAlbumCover;
    }
  }

  final recordingGroups = await _recordingGroups(title, artist);
  if (recordingGroups.isEmpty) return null;
  final matchDetail = latestArtworkCatalogDiagnostic;
  final artwork = await _coverForGroups(
    _rankSongGroups(recordingGroups, title),
  );
  latestArtworkCatalogDiagnostic = artwork != null
      ? 'Verified artist + song; cover recovered from linked release'
      : '${matchDetail}; no downloadable cover in first 10 checked releases';
  return artwork;
}

/// Exact song lookup via MusicBrainz -> Cover Art Archive / Fanart.tv.
Future<Uint8List?> fetchSongSpecificArtwork(
    String title, String artist) async {
  if (_norm(artist).isEmpty || _norm(title).isEmpty) return null;
  final groups = await _recordingGroups(title, artist);
  if (groups.isEmpty) return null;
  return _coverForGroups(_rankSongGroups(groups, title));
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
)
      .firstMatch(_cleanTitle(title));
  if (match == null) return null;
  final suffix = match.group(1)?.trim() ?? '';
  if (!RegExp(r'\bremix

/// Like the original working catalog lookup: try complete artist+song,
/// then a broader song title and a plain-text search. Verify each hit by
/// credited artist and full recording title before using artwork.
Future<List<_ReleaseGroup>> _recordingGroups(
    String title, String artist) {
  if (_norm(title).isEmpty || _norm(artist).isEmpty) {
    return Future.value(const <_ReleaseGroup>[]);
  }
  final key = '${_norm(artist)}|${_trackMatchKey(title)}';
  final existing = _recordingInFlight[key];
  if (existing != null) return existing;
  final task = _loadRecordingGroups(title, artist);
  _recordingInFlight[key] = task;
  task.then((groups) {
    // A failed search must be retryable, including after network timeouts.
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
  final fullTitle = _cleanTitle(title);
  final baseTitle = _baseTrackTitle(title);
  // MusicBrainz indexes featured performers separately, but names like
  // "Eli & Fur" are also legitimate single artist entities. Preserve
  // exact full-credit discovery before trying a lead-artist fallback.
  // Validate ALL credits and the full track/remix title on every hit.
  final searchArtist = _catalogSearchArtist(artist);
  final queries = <String>{
    // Full names like "Eli & Fur" are real artist entities.
    'recording:${_quoted(fullTitle)} AND artist:${_quoted(artist)}',
    if (_norm(baseTitle) != _norm(fullTitle))
      'recording:${_quoted(baseTitle)} AND artist:${_quoted(artist)}',
    // Use lead-artist fallback only when a combined credit exists.
    // Always verify structured credits AND the exact remix title.
    if (_norm(searchArtist) != _norm(artist))
      'recording:${_quoted(fullTitle)} AND artist:${_quoted(searchArtist)}',
    if (_norm(searchArtist) != _norm(artist) &&
        _norm(baseTitle) != _norm(fullTitle))
      'recording:${_quoted(baseTitle)} AND artist:${_quoted(searchArtist)}',
    '${_quoted(searchArtist)} ${_quoted(fullTitle)}',
    'recording:${_quoted(fullTitle)}',
  };

  final groups = <_ReleaseGroup>[];
  final seenGroups = <String>{};
  final seenRecordings = <String>{};
  var browseCount = 0;
  var networkResponses = 0;
  void addGroups(List<_ReleaseGroup> items) {
    for (final group in items) {
      if (seenGroups.add(group.id)) {
        groups.add(group);
      } else {
        final existing = groups.firstWhere((g) => g.id == group.id);
        for (final releaseId in group.releaseIds) {
          if (!existing.releaseIds.contains(releaseId)) {
            existing.releaseIds.add(releaseId);
          }
        }
      }
    }
  }

  for (final term in queries) {
    final json = await _musicBrainzJson(
      Uri.https('musicbrainz.org', '/ws/2/recording/', {
        'query': term, 'fmt': 'json', 'limit': '100',
      }),
    );
    if (json == null) continue;
    networkResponses++;
    final recordings = json['recordings'];
    if (recordings is! List) continue;

    for (final entry in recordings) {
      if (entry is! Map) continue;
      if (!_trackMatches(entry['title']?.toString() ?? '', title) ||
          !_artistCreditMatches(entry['artist-credit'], artist)) {
        continue;
      }
      final id = entry['id']?.toString() ?? '';
      if (id.isEmpty || !seenRecordings.add(id)) continue;

      // Some MusicBrainz search results omit release groups from nested
      // releases. Browse verified recordings to get their actual groups.
      // Don't drop compilation releases: the old provider could return
      // their covers when the official single has none.
      addGroups(_groupsFromReleases(entry['releases']));
      if (browseCount++ < 4) {
        final details = await _musicBrainzJson(
          Uri.https('musicbrainz.org', '/ws/2/release/', {
            'recording': id, 'inc': 'release-groups',
            'fmt': 'json', 'limit': '100',
          }),
        );
        addGroups(_groupsFromReleases(details?['releases']));
      }
    }
    if (groups.isNotEmpty) break;
  }

  latestArtworkCatalogDiagnostic = seenRecordings.isEmpty
      ? (networkResponses == 0
          ? 'MusicBrainz request failed or timed out'
          : 'No verified MusicBrainz artist + full song match')
      : (groups.isEmpty
          ? 'Matched ${seenRecordings.length} recording(s); no releases returned'
          : 'Matched ${seenRecordings.length} recording(s), ${groups.length} release group(s)');
  return groups;
}

List<_ReleaseGroup> _rankSongGroups(
    List<_ReleaseGroup> groups, String songTitle) {
  final base = _norm(_baseTrackTitle(songTitle));
  final ranked = List<_ReleaseGroup>.of(groups);
  int score(_ReleaseGroup group) {
    final name = _norm(group.title);
    if (name == base) return 3;
    if (name.startsWith(base) && base.isNotEmpty) return 2;
    if (name.contains(base) && base.isNotEmpty) return 1;
    return 0;
  }
  // Preserve catalog ordering on ties, as the previous song catalog did.
  ranked.sort((a, b) => score(b).compareTo(score(a)));
  return ranked;
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
  // Prefer the release group, then its verified recording's exact release.
  // A release may have front art even when its group has no selected front.
  for (final group in groups.take(10)) {
    final cover = await _coverArtArchiveImage(group.id);
    if (cover != null) return cover;
    for (final releaseId in group.releaseIds.take(3)) {
      for (final path in <String>[
        '/release/$releaseId/front-500',
        '/release/$releaseId/front',
      ]) {
        final bytes = await httpGetBytes(Uri.https('coverartarchive.org', path));
        if (bytes != null && _looksLikeImage(bytes)) return bytes;
      }
    }
    final fanart = await _fanartAlbumImage(group.id);
    if (fanart != null) return fanart;
  }
  return null;
}

/// Recreate the previous working search order with MusicBrainz instead
/// of Apple: artist + album first, then verified artist + recording with
/// full and simplified title search queries. Preserve player album labels.
Future<Uint8List?> fetchArtwork(
    String title, String artist, {String album = ''}) async {
  if (_norm(artist).isEmpty || _norm(title).isEmpty) return null;
  latestArtworkCatalogDiagnostic = 'Searching artist + album, then artist + song';

  if (_hasAlbumTag(album)) {
    final albumGroups = await _albumReleaseGroups(artist, album);
    final matchingAlbumCover = await _coverForGroups(albumGroups);
    if (matchingAlbumCover != null) {
      latestArtworkCatalogDiagnostic = 'Verified artist + album cover found';
      return matchingAlbumCover;
    }
  }

  final recordingGroups = await _recordingGroups(title, artist);
  if (recordingGroups.isEmpty) return null;
  final matchDetail = latestArtworkCatalogDiagnostic;
  final artwork = await _coverForGroups(
    _rankSongGroups(recordingGroups, title),
  );
  latestArtworkCatalogDiagnostic = artwork != null
      ? 'Verified artist + song; cover recovered from linked release'
      : '${matchDetail}; no downloadable cover in first 10 checked releases';
  return artwork;
}

/// Exact song lookup via MusicBrainz -> Cover Art Archive / Fanart.tv.
Future<Uint8List?> fetchSongSpecificArtwork(
    String title, String artist) async {
  if (_norm(artist).isEmpty || _norm(title).isEmpty) return null;
  final groups = await _recordingGroups(title, artist);
  if (groups.isEmpty) return null;
  return _coverForGroups(_rankSongGroups(groups, title));
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
, caseSensitive: false).hasMatch(suffix)) {
    return null;
  }
  final credit = suffix.replaceFirst(
      RegExp(r'\s+remix

/// Like the original working catalog lookup: try complete artist+song,
/// then a broader song title and a plain-text search. Verify each hit by
/// credited artist and full recording title before using artwork.
Future<List<_ReleaseGroup>> _recordingGroups(
    String title, String artist) {
  if (_norm(title).isEmpty || _norm(artist).isEmpty) {
    return Future.value(const <_ReleaseGroup>[]);
  }
  final key = '${_norm(artist)}|${_trackMatchKey(title)}';
  final existing = _recordingInFlight[key];
  if (existing != null) return existing;
  final task = _loadRecordingGroups(title, artist);
  _recordingInFlight[key] = task;
  task.then((groups) {
    // A failed search must be retryable, including after network timeouts.
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
  final fullTitle = _cleanTitle(title);
  final baseTitle = _baseTrackTitle(title);
  // MusicBrainz indexes featured performers separately, but names like
  // "Eli & Fur" are also legitimate single artist entities. Preserve
  // exact full-credit discovery before trying a lead-artist fallback.
  // Validate ALL credits and the full track/remix title on every hit.
  final searchArtist = _catalogSearchArtist(artist);
  final queries = <String>{
    // Full names like "Eli & Fur" are real artist entities.
    'recording:${_quoted(fullTitle)} AND artist:${_quoted(artist)}',
    if (_norm(baseTitle) != _norm(fullTitle))
      'recording:${_quoted(baseTitle)} AND artist:${_quoted(artist)}',
    // Use lead-artist fallback only when a combined credit exists.
    // Always verify structured credits AND the exact remix title.
    if (_norm(searchArtist) != _norm(artist))
      'recording:${_quoted(fullTitle)} AND artist:${_quoted(searchArtist)}',
    if (_norm(searchArtist) != _norm(artist) &&
        _norm(baseTitle) != _norm(fullTitle))
      'recording:${_quoted(baseTitle)} AND artist:${_quoted(searchArtist)}',
    '${_quoted(searchArtist)} ${_quoted(fullTitle)}',
    'recording:${_quoted(fullTitle)}',
  };

  final groups = <_ReleaseGroup>[];
  final seenGroups = <String>{};
  final seenRecordings = <String>{};
  var browseCount = 0;
  var networkResponses = 0;
  void addGroups(List<_ReleaseGroup> items) {
    for (final group in items) {
      if (seenGroups.add(group.id)) {
        groups.add(group);
      } else {
        final existing = groups.firstWhere((g) => g.id == group.id);
        for (final releaseId in group.releaseIds) {
          if (!existing.releaseIds.contains(releaseId)) {
            existing.releaseIds.add(releaseId);
          }
        }
      }
    }
  }

  for (final term in queries) {
    final json = await _musicBrainzJson(
      Uri.https('musicbrainz.org', '/ws/2/recording/', {
        'query': term, 'fmt': 'json', 'limit': '100',
      }),
    );
    if (json == null) continue;
    networkResponses++;
    final recordings = json['recordings'];
    if (recordings is! List) continue;

    for (final entry in recordings) {
      if (entry is! Map) continue;
      if (!_trackMatches(entry['title']?.toString() ?? '', title) ||
          !_artistCreditMatches(entry['artist-credit'], artist)) {
        continue;
      }
      final id = entry['id']?.toString() ?? '';
      if (id.isEmpty || !seenRecordings.add(id)) continue;

      // Some MusicBrainz search results omit release groups from nested
      // releases. Browse verified recordings to get their actual groups.
      // Don't drop compilation releases: the old provider could return
      // their covers when the official single has none.
      addGroups(_groupsFromReleases(entry['releases']));
      if (browseCount++ < 4) {
        final details = await _musicBrainzJson(
          Uri.https('musicbrainz.org', '/ws/2/release/', {
            'recording': id, 'inc': 'release-groups',
            'fmt': 'json', 'limit': '100',
          }),
        );
        addGroups(_groupsFromReleases(details?['releases']));
      }
    }
    if (groups.isNotEmpty) break;
  }

  latestArtworkCatalogDiagnostic = seenRecordings.isEmpty
      ? (networkResponses == 0
          ? 'MusicBrainz request failed or timed out'
          : 'No verified MusicBrainz artist + full song match')
      : (groups.isEmpty
          ? 'Matched ${seenRecordings.length} recording(s); no releases returned'
          : 'Matched ${seenRecordings.length} recording(s), ${groups.length} release group(s)');
  return groups;
}

List<_ReleaseGroup> _rankSongGroups(
    List<_ReleaseGroup> groups, String songTitle) {
  final base = _norm(_baseTrackTitle(songTitle));
  final ranked = List<_ReleaseGroup>.of(groups);
  int score(_ReleaseGroup group) {
    final name = _norm(group.title);
    if (name == base) return 3;
    if (name.startsWith(base) && base.isNotEmpty) return 2;
    if (name.contains(base) && base.isNotEmpty) return 1;
    return 0;
  }
  // Preserve catalog ordering on ties, as the previous song catalog did.
  ranked.sort((a, b) => score(b).compareTo(score(a)));
  return ranked;
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
  // Prefer the release group, then its verified recording's exact release.
  // A release may have front art even when its group has no selected front.
  for (final group in groups.take(10)) {
    final cover = await _coverArtArchiveImage(group.id);
    if (cover != null) return cover;
    for (final releaseId in group.releaseIds.take(3)) {
      for (final path in <String>[
        '/release/$releaseId/front-500',
        '/release/$releaseId/front',
      ]) {
        final bytes = await httpGetBytes(Uri.https('coverartarchive.org', path));
        if (bytes != null && _looksLikeImage(bytes)) return bytes;
      }
    }
    final fanart = await _fanartAlbumImage(group.id);
    if (fanart != null) return fanart;
  }
  return null;
}

/// Recreate the previous working search order with MusicBrainz instead
/// of Apple: artist + album first, then verified artist + recording with
/// full and simplified title search queries. Preserve player album labels.
Future<Uint8List?> fetchArtwork(
    String title, String artist, {String album = ''}) async {
  if (_norm(artist).isEmpty || _norm(title).isEmpty) return null;
  latestArtworkCatalogDiagnostic = 'Searching artist + album, then artist + song';

  if (_hasAlbumTag(album)) {
    final albumGroups = await _albumReleaseGroups(artist, album);
    final matchingAlbumCover = await _coverForGroups(albumGroups);
    if (matchingAlbumCover != null) {
      latestArtworkCatalogDiagnostic = 'Verified artist + album cover found';
      return matchingAlbumCover;
    }
  }

  final recordingGroups = await _recordingGroups(title, artist);
  if (recordingGroups.isEmpty) return null;
  final matchDetail = latestArtworkCatalogDiagnostic;
  final artwork = await _coverForGroups(
    _rankSongGroups(recordingGroups, title),
  );
  latestArtworkCatalogDiagnostic = artwork != null
      ? 'Verified artist + song; cover recovered from linked release'
      : '${matchDetail}; no downloadable cover in first 10 checked releases';
  return artwork;
}

/// Exact song lookup via MusicBrainz -> Cover Art Archive / Fanart.tv.
Future<Uint8List?> fetchSongSpecificArtwork(
    String title, String artist) async {
  if (_norm(artist).isEmpty || _norm(title).isEmpty) return null;
  final groups = await _recordingGroups(title, artist);
  if (groups.isEmpty) return null;
  return _coverForGroups(_rankSongGroups(groups, title));
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
, caseSensitive: false), '').trim();
  return credit.isEmpty ? null : credit;
}

List<String> _remixerNames(String credit) => credit
    .split(RegExp(r'\s+(?:&|and|\+|x|with|vs\.?)\s+',
        caseSensitive: false))
    .map(_norm)
    .where((name) => name.isNotEmpty)
    .toList();

bool _trackMatches(String candidate, String requested, String creditedArtist) {
  // Retain the exact-title behavior that already works for other tracks.
  if (_trackMatchKey(candidate).isNotEmpty &&
      _trackMatchKey(candidate) == _trackMatchKey(requested)) return true;

  // "(R3hab remix)" can match "(Calvin Harris & R3hab remix)" only
  // when the omitted name is independently verified as a credited
  // main artist. Never substitute a different remixer or song.
  if (_norm(_baseTrackTitle(candidate)) !=
      _norm(_baseTrackTitle(requested))) return false;
  final requestedCredit = _remixCredit(requested);
  final foundCredit = _remixCredit(candidate);
  if (requestedCredit == null || foundCredit == null) return false;
  final wanted = _remixerNames(requestedCredit).toSet();
  if (wanted.isEmpty) return false;
  final mainArtists = _creditParts(creditedArtist).toSet();
  final recorded = _remixerNames(foundCredit)
      .where((name) => !mainArtists.contains(name) || wanted.contains(name))
      .toSet();
  return recorded.length == wanted.length &&
      wanted.every(recorded.contains);
}

/// Like the original working catalog lookup: try complete artist+song,
/// then a broader song title and a plain-text search. Verify each hit by
/// credited artist and full recording title before using artwork.
Future<List<_ReleaseGroup>> _recordingGroups(
    String title, String artist) {
  if (_norm(title).isEmpty || _norm(artist).isEmpty) {
    return Future.value(const <_ReleaseGroup>[]);
  }
  final key = '${_norm(artist)}|${_trackMatchKey(title)}';
  final existing = _recordingInFlight[key];
  if (existing != null) return existing;
  final task = _loadRecordingGroups(title, artist);
  _recordingInFlight[key] = task;
  task.then((groups) {
    // A failed search must be retryable, including after network timeouts.
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
  final fullTitle = _cleanTitle(title);
  final baseTitle = _baseTrackTitle(title);
  // MusicBrainz indexes featured performers separately, but names like
  // "Eli & Fur" are also legitimate single artist entities. Preserve
  // exact full-credit discovery before trying a lead-artist fallback.
  // Validate ALL credits and the full track/remix title on every hit.
  final searchArtist = _catalogSearchArtist(artist);
  final queries = <String>{
    // Full names like "Eli & Fur" are real artist entities.
    'recording:${_quoted(fullTitle)} AND artist:${_quoted(artist)}',
    if (_norm(baseTitle) != _norm(fullTitle))
      'recording:${_quoted(baseTitle)} AND artist:${_quoted(artist)}',
    // Use lead-artist fallback only when a combined credit exists.
    // Always verify structured credits AND the exact remix title.
    if (_norm(searchArtist) != _norm(artist))
      'recording:${_quoted(fullTitle)} AND artist:${_quoted(searchArtist)}',
    if (_norm(searchArtist) != _norm(artist) &&
        _norm(baseTitle) != _norm(fullTitle))
      'recording:${_quoted(baseTitle)} AND artist:${_quoted(searchArtist)}',
    '${_quoted(searchArtist)} ${_quoted(fullTitle)}',
    'recording:${_quoted(fullTitle)}',
  };

  final groups = <_ReleaseGroup>[];
  final seenGroups = <String>{};
  final seenRecordings = <String>{};
  var browseCount = 0;
  var networkResponses = 0;
  void addGroups(List<_ReleaseGroup> items) {
    for (final group in items) {
      if (seenGroups.add(group.id)) {
        groups.add(group);
      } else {
        final existing = groups.firstWhere((g) => g.id == group.id);
        for (final releaseId in group.releaseIds) {
          if (!existing.releaseIds.contains(releaseId)) {
            existing.releaseIds.add(releaseId);
          }
        }
      }
    }
  }

  for (final term in queries) {
    final json = await _musicBrainzJson(
      Uri.https('musicbrainz.org', '/ws/2/recording/', {
        'query': term, 'fmt': 'json', 'limit': '100',
      }),
    );
    if (json == null) continue;
    networkResponses++;
    final recordings = json['recordings'];
    if (recordings is! List) continue;

    for (final entry in recordings) {
      if (entry is! Map) continue;
      if (!_trackMatches(entry['title']?.toString() ?? '', title) ||
          !_artistCreditMatches(entry['artist-credit'], artist)) {
        continue;
      }
      final id = entry['id']?.toString() ?? '';
      if (id.isEmpty || !seenRecordings.add(id)) continue;

      // Some MusicBrainz search results omit release groups from nested
      // releases. Browse verified recordings to get their actual groups.
      // Don't drop compilation releases: the old provider could return
      // their covers when the official single has none.
      addGroups(_groupsFromReleases(entry['releases']));
      if (browseCount++ < 4) {
        final details = await _musicBrainzJson(
          Uri.https('musicbrainz.org', '/ws/2/release/', {
            'recording': id, 'inc': 'release-groups',
            'fmt': 'json', 'limit': '100',
          }),
        );
        addGroups(_groupsFromReleases(details?['releases']));
      }
    }
    if (groups.isNotEmpty) break;
  }

  latestArtworkCatalogDiagnostic = seenRecordings.isEmpty
      ? (networkResponses == 0
          ? 'MusicBrainz request failed or timed out'
          : 'No verified MusicBrainz artist + full song match')
      : (groups.isEmpty
          ? 'Matched ${seenRecordings.length} recording(s); no releases returned'
          : 'Matched ${seenRecordings.length} recording(s), ${groups.length} release group(s)');
  return groups;
}

List<_ReleaseGroup> _rankSongGroups(
    List<_ReleaseGroup> groups, String songTitle) {
  final base = _norm(_baseTrackTitle(songTitle));
  final ranked = List<_ReleaseGroup>.of(groups);
  int score(_ReleaseGroup group) {
    final name = _norm(group.title);
    if (name == base) return 3;
    if (name.startsWith(base) && base.isNotEmpty) return 2;
    if (name.contains(base) && base.isNotEmpty) return 1;
    return 0;
  }
  // Preserve catalog ordering on ties, as the previous song catalog did.
  ranked.sort((a, b) => score(b).compareTo(score(a)));
  return ranked;
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
  // Prefer the release group, then its verified recording's exact release.
  // A release may have front art even when its group has no selected front.
  for (final group in groups.take(10)) {
    final cover = await _coverArtArchiveImage(group.id);
    if (cover != null) return cover;
    for (final releaseId in group.releaseIds.take(3)) {
      for (final path in <String>[
        '/release/$releaseId/front-500',
        '/release/$releaseId/front',
      ]) {
        final bytes = await httpGetBytes(Uri.https('coverartarchive.org', path));
        if (bytes != null && _looksLikeImage(bytes)) return bytes;
      }
    }
    final fanart = await _fanartAlbumImage(group.id);
    if (fanart != null) return fanart;
  }
  return null;
}

/// Recreate the previous working search order with MusicBrainz instead
/// of Apple: artist + album first, then verified artist + recording with
/// full and simplified title search queries. Preserve player album labels.
Future<Uint8List?> fetchArtwork(
    String title, String artist, {String album = ''}) async {
  if (_norm(artist).isEmpty || _norm(title).isEmpty) return null;
  latestArtworkCatalogDiagnostic = 'Searching artist + album, then artist + song';

  if (_hasAlbumTag(album)) {
    final albumGroups = await _albumReleaseGroups(artist, album);
    final matchingAlbumCover = await _coverForGroups(albumGroups);
    if (matchingAlbumCover != null) {
      latestArtworkCatalogDiagnostic = 'Verified artist + album cover found';
      return matchingAlbumCover;
    }
  }

  final recordingGroups = await _recordingGroups(title, artist);
  if (recordingGroups.isEmpty) return null;
  final matchDetail = latestArtworkCatalogDiagnostic;
  final artwork = await _coverForGroups(
    _rankSongGroups(recordingGroups, title),
  );
  latestArtworkCatalogDiagnostic = artwork != null
      ? 'Verified artist + song; cover recovered from linked release'
      : '${matchDetail}; no downloadable cover in first 10 checked releases';
  return artwork;
}

/// Exact song lookup via MusicBrainz -> Cover Art Archive / Fanart.tv.
Future<Uint8List?> fetchSongSpecificArtwork(
    String title, String artist) async {
  if (_norm(artist).isEmpty || _norm(title).isEmpty) return null;
  final groups = await _recordingGroups(title, artist);
  if (groups.isEmpty) return null;
  return _coverForGroups(_rankSongGroups(groups, title));
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
