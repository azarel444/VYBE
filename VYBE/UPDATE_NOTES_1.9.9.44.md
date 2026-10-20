# v1.9.9.44 source patch
- Separate Fanart.tv project and personal key fields; send `api_key` and optional `client_key`. No keys embedded.
- Correct Orbit atmospheric fade direction in flipped landscape; flip ghost-image gradient.
- Move clock toward information panel in flipped layouts.
- Clip Record backdrop circle and its darkening layer together.
- Preserve existing visualizer expansion and onboarding code.

Note: Fanart requires a valid project key; a personal key alone does not work. Flutter compile/device testing not available.
