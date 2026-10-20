# v1.9.9.37 — Persistent onboarding state

- Root now reads an independent native Android completion flag, plus legacy Flutter SharedPreferences completion flags.
- Native flag is stored in `vybe_setup_state` with synchronous `commit()`; completed legacy installations are migrated.
- The Launch VYBE action writes the native flag before entering the player, then writes legacy flags for compatibility.
- Existing VYBE Link and other functionality unchanged.

## Verification status
Source-level assertions and ZIP integrity only. Flutter/Gradle build and real device reopen testing are required. If app data is cleared, onboarding is expected to reappear.
