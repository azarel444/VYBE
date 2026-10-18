# VYBE 1.9.9.10 — Drive square artwork follow-up

- Drive square cover now renders directly rather than through the shared AnimatedSwitcher, avoiding an image transition restart when tapping the background to toggle controls.
- Square artwork has a dark fallback for missing/flat art and an image decode error fallback.
- Keeps the vinyl path unchanged.

Needs Flutter compilation and real-device verification. This does not accelerate upstream media-session artwork retrieval; delayed art from the source app can still arrive later.
