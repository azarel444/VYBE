# VYBE v1.9.9.19 — club over album art + expanded FX controls

- Added fourth background option, Album Art + Club Light Show. It renders the blurred artwork behind transparent club lighting; standalone club mode retains its dark stage.
- Club blend selection is available in both club background modes.
- All FX Library detail sheets now show transfer/blend mode, blend opacity, intensity and size controls, with per-effect persistence.
- Expanded blend selection to 24 Flutter compositing options for CustomPainter effects. Each painted effect composites in its own layer; normal/full-opacity bypasses extra layers.
- Size controls scale painter FX and Floating Particles. Shader-based effects retain shader-specific blend approximations; some UI-driven effects (VHS, Background Motion, Cover Bloom) are not yet fully integrated with the universal painter compositing system.
- Preserved Orbit artwork blur when artwork is used as the background, including the new combined background option.

## Validation
ZIP integrity verified. Flutter SDK unavailable in this environment; GitHub Actions compilation and device validation required. On Android 9, avoid stacking many non-Normal blend modes because offscreen compositing increases GPU workload.
