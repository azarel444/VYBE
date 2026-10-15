# VYBE 1.9.9.12 — Animated Color Template Backgrounds (first implementation)

- Visuals → Background: choose Blurred album art (default) or Animated color template.
- Procedural background uses the existing 16 color palettes (and auto palette), with palette-specific color combinations and eight geometric/motion families.
- Motion slider 0–100%, saved across restarts; performance mode freezes animation.
- Existing foreground album artwork, Now Playing themes, and FX remain separate.
- Uses existing low-frequency animation notifier; no new ticker, video assets, or blur filter.
- No Drive lifecycle changes.

Note: This is a first functional implementation for device testing. Background motion is not yet audio reactive, and some templates share geometric families with palette-specific colors. Flutter compilation and device performance require testing via GitHub Actions.
