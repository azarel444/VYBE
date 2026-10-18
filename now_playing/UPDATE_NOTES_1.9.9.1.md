# VYBE v1.9.9.1 — Drive Clock and Portrait Text Padding

- Drive portrait: remove the second screen-level clock, place the only clock above the album artwork inside the responsive music column, and adapt artwork size to available space.
- Drive landscape: remove the screen-level corner clock and place the clock centered above song information and the vinyl in the music panel.
- Drive transparent host: remove its additional screen-level clock so it does not duplicate the music-panel clock.
- Portrait: constrain metadata text to screen width minus 48 logical pixels (24 dp on each side), while leaving artwork, backgrounds and visualizers full bleed.
- 'Start music in any player app': reduce letter spacing for the placeholder to improve fit on narrow screens.

Source archive created and ZIP tested. Flutter SDK is not installed here; APK compilation and on-device layout remain unverified.
