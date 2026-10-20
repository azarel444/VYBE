# v1.9.9.57 — Drive map transparency and onboarding hotfix

- Preserves v1.9.9.56 onboarding Launch VYBE transition fix.
- Drive now uses a non-opaque Flutter route rather than the default opaque MaterialPageRoute, which could hide Google Maps even though the Drive cutout is clipped.
- Drive Flutter activity explicitly uses transparent rendering and transparent Android window background, with dimming disabled.
- Preserves v1.9.9.55 diagnostics, settings and fanart darkness changes.

Not compiled or tested on a device in this environment. Verify map is visible through the Drive opening on the ATOTO head unit.
