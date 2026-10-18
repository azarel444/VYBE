# v1.9.9.27 — Aura Sweep scaling and Moving Bokeh

- Aura Sweep keeps a full-screen render surface at every Size setting; only its gradient pattern scales, eliminating the rectangular boundary below 100%.
- Replaced Breathing Glow with Moving Bokeh: 22 smoothly drifting, soft-focus lights in the current artwork palette, with subtle audio-reactive brightness.
- Moving Bokeh also scales its lights internally without shrinking the full-screen rendering surface.
- Existing fxGlow enable/intensity preferences remain compatible; the effect is renamed in the FX library and profile labels.

Source patch; requires Flutter/Android build and on-device visual testing.
