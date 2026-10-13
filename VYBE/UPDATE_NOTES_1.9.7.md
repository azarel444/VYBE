# VYBE 1.9.7 — Landscape FX library, Drive clock and edge effects

Based on v1.9.6.1.

- FX Library now uses a single CustomScrollView: settings and performance controls scroll away together with the FX grid, making all cards accessible in landscape.
- Drive portrait clock is anchored inside the metadata column immediately above the song title, not in a separate overlay; its position follows the art/metadata section when the map changes height.
- Canvas background FX receive 18% overscan to avoid obvious rectangular effect boundaries at the viewport edges. This does not modify core theme artwork or visualizers.
- Prism Shards GPU shader now samples the background with faceted triangular displacement and stronger RGB edge separation instead of a nearly imperceptible sinusoidal offset.

NOTE: Flutter SDK is not installed in this build environment. The archive is checked for integrity, but Flutter compilation and on-device rendering have NOT been verified. Shader refraction remains dependent on Flutter/Impeller support.
