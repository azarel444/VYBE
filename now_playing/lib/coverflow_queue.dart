import 'dart:typed_data';

/// A real track published by an Android MediaSession queue or a cover
/// previously seen playing. Never invent unknown future tracks.
class CoverflowCover {
  final String id;
  final int slot; // 0 current; negative previously played, positive upcoming.
  final String title;
  final String artist;
  final String artUri;
  final Uint8List? thumb;

  const CoverflowCover({
    required this.id,
    required this.slot,
    required this.title,
    required this.artist,
    this.artUri = '',
    this.thumb,
  });

  CoverflowCover withThumbnail(Uint8List bytes) => CoverflowCover(
    id: id, slot: slot, title: title, artist: artist,
    artUri: artUri, thumb: bytes,
  );

  CoverflowCover atSlot(int value) => CoverflowCover(
    id: id, slot: value, title: title, artist: artist,
    artUri: artUri, thumb: thumb,
  );
}
