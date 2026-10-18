# VYBE 1.9.9.33 — Wi-Fi Direct connection path (experimental)

- Added Android native Wi-Fi Direct group hosting on receiver, peer discovery and selection on sender.
- On group connection, phone uses group owner IP for existing TCP transfer on port 38927.
- Added Wi-Fi Direct permissions and runtime permission request.
- Added Direct connection controls and peer list to Link settings. Existing LAN IP connection remains available.
- Bluetooth continues to handle audio and metadata; this change is focused on connectivity.

## Important test limitations
- Not compiled against Android SDK/Flutter in this environment; GitHub Actions and physical device tests are required.
- Wi-Fi Direct availability and Wi-Fi Direct/TCP routing on ATOTO A5L have not been verified.
- Discovery requires Android Location services and permission, and nearby-devices permission on Android 13+.
- Initial pairing is manual; reconnecting after reboot may require repeating group creation/discovery.
- Current image transport still includes a small metadata packet for artwork association; artwork-only refactor is not part of this connection-path release.
- Source tree is a partial Android overlay; the build workflow must generate a Flutter Android project and copy the supplied android/app/src/main files as before.
