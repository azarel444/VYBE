# VYBE v1.9.9 — optical blend controls and Drive map depth

Based on v1.9.8.1.

- New Background darkness slider in Settings > Background effects. 0% removes the black gradient, 100% matches the original gradient, 200% increases darkness. Persists per device.
- New per-effect blend mode and blend opacity controls for Liquid Refraction, Vortex Tunnel, Prism Shards, and Holographic Interference in FX Library detail sheets. Modes: Normal, Screen, Multiply, Overlay, Soft Light, Color Dodge, Difference, Hue Shift.
- Fragment shader implements blend transfer modes using sampled backdrop image and per-effect controls.
- Prism Shards: replaces repeating facet grid with 18 independently drifting, irregular refractive triangular regions at varied depths; no painted strokes.
- Drive: subtle dark inner shadow around the map window, clipped to the rounded cutout, preserving map visibility and tap behavior.

Note: Flutter/Android build and device GPU compatibility were not verified in this environment. GPU shader effects require compatible Flutter engine; Skia fallback is unchanged.
