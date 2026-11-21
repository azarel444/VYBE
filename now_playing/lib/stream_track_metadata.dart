/// Conservative repair for YouTube Music uploads whose Android media session
/// reports the uploader's channel as artist, and a combined "Artist - Track"
/// string as both title and album. Does not modify regular catalog tracks.
class StreamTrackMetadata {
  final String title;
  final String artist;
  final String album;
  final String uploader;
  final bool corrected;

  const StreamTrackMetadata({
    required this.title,
    required this.artist,
    required this.album,
    required this.uploader,
    required this.corrected,
  });

  static String normalizedKey(String value) {
    var folded = value.toLowerCase();
    const groups = <String, String>{
      'a': 'àáâãäåāăą', 'c': 'çćč', 'd': 'ďđð',
      'e': 'èéêëēĕėęě', 'g': 'ğģ', 'i': 'ìíîïīįı',
      'l': 'łĺľ', 'n': 'ñńň', 'o': 'òóôõöøōő',
      'r': 'řŕ', 's': 'śšşș', 't': 'ťţț',
      'u': 'ùúûüūůű', 'y': 'ýÿŷ', 'z': 'źżž',
    };
    for (final entry in groups.entries) {
      folded = folded.replaceAll(RegExp('[${entry.value}]'), entry.key);
    }
    return folded.replaceAll('æ', 'ae').replaceAll('œ', 'oe')
        .replaceAll('ß', 'ss').replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  static String _normalized(String value) => normalizedKey(value);

  static bool _isMissingAlbum(String album) {
    final normalized = _normalized(album);
    return normalized.isEmpty ||
        normalized == 'unknownalbum' ||
        normalized == 'albumunknown' ||
        normalized == 'unknown' ||
        normalized == 'na';
  }

  static StreamTrackMetadata resolve({
    required String title,
    required String artist,
    required String album,
    required String sourcePackage,
  }) {
    StreamTrackMetadata unchanged() => StreamTrackMetadata(
          title: title,
          artist: artist,
          album: album,
          uploader: '',
          corrected: false,
        );

    // Only parse YouTube Music's upload-style sessions. A hyphen in a
    // properly tagged Musicolet/Samsung/BlackPlayer track is not evidence
    // that the player supplied a channel name.
    if (sourcePackage != 'com.google.android.apps.youtube.music') {
      return unchanged();
    }

    final rawTitle = title.trim();
    final rawArtist = artist.trim();
    final rawAlbum = album.trim();
    if (rawTitle.isEmpty || rawArtist.isEmpty) return unchanged();

    // Video-upload metadata sometimes duplicates "Artist - Song" in both
    // the title and album fields. A real distinct album tag takes priority.
    final repeatedTitle = _normalized(rawAlbum) == _normalized(rawTitle);
    if (!repeatedTitle && !_isMissingAlbum(rawAlbum)) return unchanged();

    // Require an explicit spaced separator; never split hyphenated words,
    // titles with unspaced punctuation, or artist names such as Run-DMC.
    final split = RegExp(r'\s+[-–—]\s+').firstMatch(rawTitle);
    if (split == null) return unchanged();
    final realArtist = rawTitle.substring(0, split.start).trim();
    final realSong = rawTitle.substring(split.end).trim();

    // Avoid taking uploader names as the title prefix or promoting empty,
    // suspiciously long, or generic prefix fragments into artist metadata.
    if (realArtist.length < 2 || realArtist.length > 80 ||
        realSong.length < 2 || realSong.length > 240 ||
        realArtist.split(RegExp(r'\s+')).length > 12 ||
        !RegExp(r'[A-Za-zÀ-ÿ]').hasMatch(realArtist) ||
        !RegExp(r'[A-Za-z0-9À-ÿ]').hasMatch(realSong) ||
        _normalized(realArtist) == _normalized(rawArtist)) {
      return unchanged();
    }

    // The uploaded video title is NOT verified release metadata. Clearing
    // the duplicated album string lets VYBE's existing release-title lookup
    // find a genuine album, falling back to the individual song if unknown.
    return StreamTrackMetadata(
      title: realSong,
      artist: realArtist,
      album: repeatedTitle || _isMissingAlbum(rawAlbum) ? '' : rawAlbum,
      uploader: rawArtist,
      corrected: true,
    );
  }
}
