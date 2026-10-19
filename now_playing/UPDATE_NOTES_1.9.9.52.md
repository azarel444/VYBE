# VYBE 1.9.9.52 — Zero-entry Fanart.tv beta configuration

- Bundled the previously verified Fanart.tv project key for TEST BUILDS only.
- New installs default to Auto (fanart then album); existing user selection is respected.
- Removed personal/project API-key entry fields from Visuals settings.
- On startup the app uses the bundled project key, ignoring stale saved credentials.
- All artwork caching and UI changes from v1.9.9.51 are retained.

SECURITY: The project key is embedded in the source and resulting APK and can be extracted. Do not publish this beta build or repository. Before public release, rotate this key and replace direct client calls with a secure developer-managed proxy. The FANART_PROJECT_KEY dart-define overrides the beta default for private builds, but does not secure the key inside an APK.

No Flutter SDK available here; compile/device test not performed.
