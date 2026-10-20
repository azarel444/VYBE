# VYBE 1.9.9.20 — FX rendering integration

- Added isolated widget-layer transfer compositing for VHS overlays and backdrops and Cover Bloom, with size and opacity controls.
- Wired Background Motion size to its drift amplitude and zoom, and opacity/blend to its blurred-art layer.
- Wired shader effect size to shader spatial frequency and prism geometry; existing shader blend-mode approximations remain.
- Retained previous settings and existing Club Light Show album overlay.

## Known limitations
- The shader renderer currently approximates its available transfer modes rather than implementing all 24 enum modes exactly.
- Background Motion's blend applies to its moving album-art layer, not a separate transparent FX-only layer.
- On Android 9/Skia, GPU backdrop shaders may fall back to canvas visuals; behavior needs device validation.
- Layout-flip controls and Drive lifecycle changes are not part of this release.
- Flutter compilation unavailable in this environment. Test with GitHub Actions before deploying.
