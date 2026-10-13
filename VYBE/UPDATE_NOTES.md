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
