# VYBE 1.9.9.28 — Link LAN connectivity beta

- Adds VYBE Link settings tab: enable, Sender/Receiver, auto-connect, receiver IPv4 address, status, manual reconnect.
- Receiver hosts TCP port 38927 on local IPv4 interfaces. Sender connects by manually entered IP and sends newline-delimited JSON with title, artist, album, playback status, position, duration and base64 artwork (maximum 750 KB raw).
- Receiver displays Link metadata/artwork in the existing Now Playing model while connected; local media session resumes when disconnected.
- Existing audio stays on Bluetooth; no audio is transmitted.
- First build deliberately does NOT implement Wi-Fi Direct group formation, Android Auto transport, automatic discovery, encryption, pairing authorization, or background service persistence. Only use on a trusted local network.
- Same APK is used on both devices. Wi-Fi connectivity must exist before linking.
- NOT compiled or device-tested in this environment; requires GitHub Actions build and real-device validation.
