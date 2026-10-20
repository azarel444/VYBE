# VYBE 1.9.9.38 — Visual experiment (source beta)

Based on 1.9.9.37; preserves native onboarding persistence and leaves Link connection implementation unchanged.

- Diagonal visualizer: Bars, Smooth Wave, Dot Wave selector under Settings > Visualizer. Uses the same spectrum values; wave is a connected spectrum trace, not raw PCM waveform.
- Diagonal bars and dots: symmetric 12% endpoint opacity fade.
- Night mode: replaces full-screen dark overlay with Android window-brightness override at 75% of current system setting. Restores default on off/dispose. Window override behavior needs device testing.
- Clock: increases default portrait and landscape font sizes.
- Orbit portrait: shifts artwork/rings down together.
- Theme picker: closes immediately on Apply Theme, saves afterward.
- Drive square/vinyl setting already existed in base and is retained.

Not yet included: comprehensive layout-flip expansion across remaining themes, fade for all other endpoint-based visualizers, a separate Drive-specific toggle in theme picker, full responsive Orbit collision audit.

No Flutter/Android SDK in this environment. ZIP integrity and source-level checks only. Compile and test via GitHub Actions; do not assume APK build success.
