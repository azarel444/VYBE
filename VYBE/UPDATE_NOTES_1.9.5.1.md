# VYBE v1.9.5.1 — Orbit default rays correction

- Removed OrbitRaysPainter from the always-on Orbit theme layer. Rays now render only through the existing optional FX pipeline when Light Rays is enabled.
- Preserved Orbit's defining rings, moving highlights, album art and circular spectrum; these remain intrinsic theme visuals rather than user-selectable background FX.
- Existing v1.9.5 adaptive shader governor remains unchanged. It does not yet benchmark or disable individual FX, and it does not yet maintain per-theme performance budgets.
- Source-only correction. Flutter build and runtime behavior have not been verified here.
