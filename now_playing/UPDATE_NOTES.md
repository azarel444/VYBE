# VYBE 1.8.9 — expanded color palette test build

- No-album-art animated background now uses the active VYBE color palette instead of a hardcoded fallback palette. This includes flat/placeholder art.
- Added 11 selectable accent palettes: Cosmic, Ember, Aurora, Rose Gold, Electric Lime, Midnight, Ice, Ruby, Golden Hour, Ultraviolet, Monochrome.
- Existing palettes, settings persistence, visual effects, Drive transition fix, theme library, clock, and map return tab retained.
- In Auto (from art), missing album art still uses the default fallback colors; choose a named color palette to set fallback animation colors.
- Requires Android/Flutter build and device testing; not compiled in this environment.


## v1.9.0 FX Library
- Visual FX grid accessed from Settings > Visuals > Background FX Library.
- Toggle each effect with a checkbox; tap card for intensity and larger preview.
- All On / All Off are temporary selection overrides; Restore My FX restores the last custom checkbox combination, persisted across launches.
- Illustrative static effect previews; live FX still render in Now Playing.
- Existing theme, Drive, clock, palette and FX engine code preserved.
