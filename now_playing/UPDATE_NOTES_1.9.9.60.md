# VYBE v1.9.9.60 — onboarding handoff and artwork retry guard

- Preserve onboarding selections in process memory until the player finishes its initial settings load; apply and persist them to the actual player settings instance.
- Serialize individual toggle writes with whole-settings writes.
- Remove the app-resume full reload that could replace just-changed toggle state.
- Enforce the artwork retry budget at lookup entry; prevent counts beyond 4/4.
- Keep the existing working Drive/Maps, fanart and diagnostics.

Not compiled or device tested: Flutter SDK is unavailable.
