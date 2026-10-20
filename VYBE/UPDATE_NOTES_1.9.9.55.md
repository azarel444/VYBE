# v1.9.9.55 — Onboarding, artwork diagnostics, and unified darkness

- Remove unconditional 32% dimming over fanart. Both fanart and album-art backgrounds now use one black overlay driven by the Background darkness slider (0% truly clear).
- Add Settings > General > Artwork diagnostics, with Copy Diagnostics. Reports media-session byte presence, artwork source, lookup progress, errors and cover display state. Online source currently reports iTunes or Cover Art Archive collectively; it cannot identify which provider without deeper net.dart instrumentation.
- Serialize onboarding preference writes and await pending saves before finishing the tour.
- Drive layout fix from v1.9.9.54 retained.

Source patch only: Flutter SDK/device testing unavailable in this environment.
