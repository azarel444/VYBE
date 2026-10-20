# VYBE 1.9.9.45 — Artwork recovery test
- Recheck the active Android media session when album art is missing, with bounded retries at 1, 2, 3, 5, 8 and 12 seconds. Does not restart playback.
- Stop retrying when art arrives or the track changes.
- Do not permanently cache failed Fanart.tv results. Allow a new request for the same artist after a 25-second cooldown when the UI requests fanart again.
- Preserve existing fanart, visualizer and layout rendering.

Source-only package. Flutter/Android compilation and device tests have NOT been performed in this environment.
