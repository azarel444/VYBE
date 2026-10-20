# VYBE 1.9.9.54 — Drive theme isolation

- DriveActivity now renders `_driveLayout` unconditionally, regardless of the saved main-app theme.
- This prevents a second Flutter engine or asynchronous settings reload from showing Focused inside the Drive window.
- Prevents non-Drive positional shift and VHS OSD in the Drive host.
- All other 1.9.9.53 features are unchanged; onboarding and artwork diagnostics are reserved for a later build.

Static source patch only: Flutter SDK unavailable here, so APK compilation and runtime verification remain pending.
