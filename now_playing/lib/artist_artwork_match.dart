/// Artist artwork is indexed by artist, not by a track's complete
/// collaboration credit. Keep the original name for display, and only
/// try the lead artist as a fallback after an exact full-name lookup fails.
///
/// The caller must confirm that a compound name was NOT found as an
/// independent MusicBrainz artist before using a conjunction fallback.
/// For example, `Eli & Fur` is a real group and must not become `Eli`.

final RegExp _explicitFeature = RegExp(
  r'\s+(?:feat\.?|featuring|ft\.?|with)\s+',
  caseSensitive: false,
);
final RegExp _collaboration = RegExp(
  r'\s+(?:&|\+|and|x|vs\.?)\s+',
  caseSensitive: false,
);

/// `feat.` and `featuring` unambiguously denote a guest credit.
bool hasExplicitFeaturedArtist(String artist) =>
    _explicitFeature.hasMatch(artist.trim());

/// Prioritize the main artist while retaining the full credited display
/// name. An ampersand can also be part of an established group name, so
/// require a confirmed exact-name miss before using this alternative.
String? leadArtistArtworkFallback(String credit) {
  final artist = credit.trim();
  if (artist.isEmpty) return null;
  final separator = _explicitFeature.firstMatch(artist) ??
      _collaboration.firstMatch(artist);
  if (separator == null) return null;
  final lead = artist.substring(0, separator.start).trim();
  if (lead.isEmpty || lead.toLowerCase() == artist.toLowerCase()) {
    return null;
  }
  return lead;
}
