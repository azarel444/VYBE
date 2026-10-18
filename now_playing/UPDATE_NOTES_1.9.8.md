# VYBE 1.9.8 — Optical FX cleanup and feathered rays

- Prism Shards, Liquid Refraction, Vortex Tunnel and Holographic Interference no longer draw their canvas-based decorative geometry when GPU backdrop shaders are supported. These effects are image distortions, not colored line overlays.
- Prism Shards GPU shader uses facet-based pixel displacement with RGB dispersion localized near boundaries; removed the broad decorative caustic tint from non-liquid modes.
- Light Rays now use multi-band angular feathering plus radial distance falloff to soften hard edges. Revertible by restoring the previous RaysPainter implementation.
- Retains all v1.9.7 changes.

Notes: On devices without shader backdrop support, legacy canvas FX are retained as fallback. No Flutter SDK compilation or GPU validation performed here.
