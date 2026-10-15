# VYBE 1.9.9.11 — Drive artwork shortcut restoration

- Restore tap-to-open-music-app for both square cover and vinyl Drive artwork.
- Keep the direct square image renderer and its dark fallback from 1.9.9.10.
- Artwork tap uses existing `_openPlayer` logic; background taps retain their controls toggle.

Source-only patch; Flutter compilation and device testing required.
