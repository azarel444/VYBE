## v1.9.4.2 — Record Cut overlap and camera-safe clocks

- Record Cut portrait: independently position the grayscale outer circle and vinyl so the lower curve of the outer circle crosses behind the vinyl at its vertical midpoint. Move the vinyl upward from the overly low previous position; keep metadata below the vinyl.
- Portrait clocks placed near the top: enforce Android `MediaQuery.viewPadding.top` plus clearance, with a 48 logical-pixel minimum for immersive devices where the camera cutout remains exposed despite hidden status bars. Bottom-centered clocks are unchanged.
- Based on v1.9.4.1 including its two `FxClock.mid` compilation fixes. No FX changes.
- Source archive checked; no Flutter SDK available to compile an APK here.

## v1.9.4.1 — Flutter compilation fix

- Replaced two invalid `FxClock.mid` references in `lib/effects.dart` (Aurora curtains and Light Trails) with the existing `FxClock.bass` audio-response value. No new fields or media pipeline changes.
- Preserves all v1.9.4 layout and FX work.
- Archive validated; Flutter SDK unavailable here, so APK compilation is not verified.

# VYBE 1.9.1 — expanded FX and offline cache (test build)

- Ten additional selectable visual FX, with animated painters rendered over existing album-art backgrounds and intensity sliders in the FX Library.
- Increased visibility for Nebula Haze, Twinkling Stars and Beat Ripples; stronger Background Motion and a more responsive adaptive ripple trigger.
- Persistent on-device caching of downloaded album artwork and synchronized lyrics; bounded storage and a Clear Cache action in General settings.
- Ignore flat placeholder art for the Now Playing background and do not persist it as downloaded cover art.
- Clock placement adjusted for Side by Side, Edge to Edge, Fan, Diagonal and Drive landscape.

## Known limitations

- Flutter/Android toolchains were unavailable in the build environment; this is a source ZIP, not a compiled/tested APK.
- New FX are Canvas-based approximations intended for visual testing. Liquid Refraction does not yet refract the underlying pixels; Bass Shockwave is continuously modulated by bass energy rather than triggering from discrete detected onsets. Further shader/audio refinement may be required.
- Full per-theme clock layout verification and generic-player placeholder recognition require device testing.
- Cache currently stores only downloaded artwork and downloaded synced lyrics, not every artwork image sent by a player.

## Visual polish — Fan, Diagonal and text
- Removed only the radial black backing panels behind text. Retained visualizer shading and other atmospheric shadows.
- Added a small glyph drop shadow to the common song title, artist, album and lyric text styles, and Typo's primary labels.
- Added a bottom-to-top black compositional fade behind the foreground artwork on Fan and Diagonal in portrait and landscape.
- Reduced the Fan's middle cover blur to 0.003 × cover size and rear cover blur to 0.008 × cover size; reduced their darkening and restored opacity so both remain recognizable.
- Based on VYBE 1.9.1 cache compile fix. Android compilation and visual device tests have not been run here.

## 1.9.3 — Missing-art and clock corrections
- Detect uniform neutral-dark player placeholder images with central logos, including Musicolett-style defaults, in addition to flat-color placeholders. Reject them before use as artwork or background.
- Reuse the animated, palette-reactive fallback whenever art is absent or rejected. Preserve existing idle VYBE logo presentation.
- Explicitly assign clock anchors for all nine selectable themes and both orientations, placing Side by Side on the opposite side from artwork and keeping Drive away from its map panel.
- Retain Fan/Diagonal fades, Fan rear-cover blur changes, FX library and caching from 1.9.2.
- This is a source-only patch; verify on actual devices. Dark, minimalist legitimate covers should be tested against the conservative placeholder heuristic.

## 1.9.4 — Portrait composition and FX refinement
- Applied the October portrait clock placements per theme: centered above/between visual groups or centered at the bottom for Side by Side and Edge to Edge.
- Drive portrait: reduced the live map window height and reserved a top panel for the centered clock, album art, title, and artist. The transparent map interaction window is retained.
- Record Cut portrait: lowered the vinyl so it overlaps the lower part of the outer circular boundary, with the clock centered above.
- Focused portrait: lowered the artwork/visualizer group to give the centered clock breathing room.
- Refined FX: bass shockwave scales to the shorter display dimension; aurora brightness and light trails respond to mid-frequency energy. Existing FX selections and blurred artwork layering preserved.
- These are source edits; Android compilation and visual verification are still required.
