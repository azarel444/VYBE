# VYBE v1.9.9.53 — Artwork retrieval test

- Artist fanart: search up to 15 MusicBrainz results, try up to 5 exact-name artist IDs, and up to 3 image URLs per ID. Record a useful failure reason rather than equating network errors with missing art.
- Album covers: Cover Art Archive lookup now tries original and remaster/edition-stripped album titles, up to 12 release-group candidates each. Existing iTunes lookup and album reuse remain.
- Track artwork status in NowPlayingModel for subsequent diagnostics.
- Preserve the automatic Fanart.tv beta credential behavior from v1.9.9.52.

This is a source-only test build. Flutter compilation and on-device behavior have not been verified.
