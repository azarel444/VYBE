# VYBE 1.9.9.59 — settings toggle synchronization

- Isolated the four onboarding-controlled switches (art lookup, lyrics, boot launch, music launch) from whole-settings writes that can overwrite values using stale state, including Drive's second engine.
- Settings now writes each of those four toggles directly and notifies the UI immediately.
- Prevented a late onboarding preference read from resetting toggles after the user has interacted.
- Preserved working Drive Maps and artwork diagnostics.
- No Flutter SDK in this environment; compilation and on-device validation pending.
