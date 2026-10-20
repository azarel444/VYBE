# VYBE v1.9.9.58 — preference persistence hotfix

- Serialized full-settings writes so rapid toggles cannot race each other.
- Onboarding writes individual choices directly instead of saving stale full settings.
- Onboarding finalization commits the selected booleans before navigating (3-second bounded wait).
- Drive Maps and artwork diagnostics remain unchanged from v1.9.9.57.

Source archive validated; Flutter compilation and real-device tests not available here.
