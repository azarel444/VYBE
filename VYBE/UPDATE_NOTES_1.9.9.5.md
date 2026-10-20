# VYBE v1.9.9.5 — Record Cut depth and swipe cleanup

- Record Cut portrait and landscape: darkened the large grayscale background disc by approximately 30%, leaving the rotating vinyl unaffected.
- Added a soft localized inward shadow from the curved vinyl-facing boundary only; no all-around perimeter shadow.
- Verified the main Now Playing gesture handler uses horizontal drag only (left next, right previous). No vertical swipe track-change handlers remain in the Flutter `lib/` source; Android system vertical navigation is not intercepted there.
- All prior v1.9.9.4 visual FX and adaptive text changes retained.

Flutter compilation not performed in this environment. Build and test via GitHub Actions and physical devices.
