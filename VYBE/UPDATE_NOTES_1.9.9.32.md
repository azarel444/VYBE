# VYBE 1.9.9.32 — consolidated Link beta

Changes:
- Retains 1.9.9.31 onboarding persistence correction.
- VYBE Link protocol v2: metadata is sent independently of artwork; 320-pixel PNG artwork is prepared on the sender and transferred separately.
- Track IDs prevent an older cover being assigned to the next song.
- Receiver disables its own artwork web searches while a Link session is active.
- Link settings show received metadata count, cover count, artwork errors, and last artwork status.
- Metadata keepalive interval increased to 8 seconds to reduce head-unit workload.
- Edge-to-edge landscape layout centers song text in its panel when visualizer is disabled.

Important: This is a beta source ZIP, not a compiled or device-validated APK. Both sender and receiver must use 1.9.9.32 (Link v2). Wi-Fi and Bluetooth coexistence / audio stutter cannot be guaranteed by this patch. Existing Performance Mode is unchanged; a separate new performance mode was not added. Other themes with visualizer/text shared areas may still need adjustment after on-device review.
