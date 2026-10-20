# VYBE 1.9.9.40 — source-only experimental patch
- Added artist fanart background mode and local cache; Fanart.tv personal API key required, configured in Visuals settings. Artist ID resolved through MusicBrainz. Missing images fall back to album art.
- Added landscape flip control for Diagonal and counter-flipped song info.
- Corrected flipped Orbit text panel geometry.
- Darkened background disc behind vinyl record.
- Renamed diagonal waveform setting to indicate compatibility work.

**LIMITATIONS:** Smooth Wave and Dot Wave are still implemented only for Diagonal, not all themes. Fanart service has not been tested with a live key, API usage terms need confirmation. No Flutter SDK available for compile/device validation. This source ZIP is NOT a fully verified completed release.
