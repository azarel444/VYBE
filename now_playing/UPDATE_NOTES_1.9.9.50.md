# VYBE 1.9.9.50 — Artwork catalog fallback

- Keep Android media-session artwork as first priority.
- Keep Apple iTunes track search as first online catalog.
- Add MusicBrainz release-group lookup + Cover Art Archive front image fallback when Apple search fails.
- Require exact normalized album and credited artist to reduce mismatched covers.
- Keep existing retry/caching and fanart rendering unchanged.

Limitations: Some releases have no Cover Art Archive image, and Spotify may not expose album artwork in a media session. This source patch was not Flutter compiled or tested on Android.
