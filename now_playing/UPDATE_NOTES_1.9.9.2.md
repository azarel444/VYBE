# VYBE v1.9.9.2

- FX detail modal now scrolls within 88% of available screen height, making all controls reachable in landscape.
- Beat Ripples and Light Rays now convert the album-art center from global screen coordinates into each overscanned FX painter's local coordinates; avoids displaced origins when canvases are scaled.
- Typo landscape clock moved to the upper-left to avoid the conditional artwork region.

Source-only patch based on v1.9.9.1. ZIP integrity checked; Flutter SDK unavailable locally, so compilation and Android runtime remain unverified.
