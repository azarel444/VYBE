# VYBE 1.9.9.9 — Drive square artwork hotfix

- Removed the nested tap-to-open-player handlers from Drive artwork in both orientations. A tap on the artwork no longer launches the music app, which could make the artwork disappear behind the player.
- Render Drive square artwork directly through the existing art card instead of the `_front` wrapper with its nested gesture and pulsing/bloom layers.
- Keep the selected artwork mode, map layout, and vinyl behavior unchanged.

Please verify both orientations and track changes. The white placeholder during artwork retrieval may originate upstream from the Android media session or artwork decoding; if it persists, collect logs from the head unit to identify the source. No Flutter SDK compilation was performed here.
