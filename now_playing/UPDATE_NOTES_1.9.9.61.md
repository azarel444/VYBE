# VYBE v1.9.9.61 — Native preference source and album fallback

- Android-native SharedPreferences (`vybe_content_choices`) now stores the four onboarding/launch choices independently of Flutter engine caches.
- Onboarding and in-app toggles write the same native keys. On startup the UI reads the same keys; existing Flutter preference values are used for migration if native keys do not yet exist.
- Preserved working Drive overlay, native auto-launch service, lyrics renderer, fanart, and diagnostics.
- Album artwork lookup first tries an exact artist+album match against iTunes **album** results, without incorrectly requiring an album search result's track title to match the current song. MusicBrainz/Cover Art Archive remains the fallback.
- Artist fanart lookup now probes at most two exact-name MusicBrainz IDs with shorter per-request timeouts to reduce long waits. This is a latency tradeoff; some uncommon artists with relevant IDs later in the list may need future tuning.

## Verification limitations
- Static checks and ZIP integrity are performed. Flutter SDK and Android toolchain are not available in this environment; compilation and device behavior are unverified.
- For first-run onboarding regression, clear app data or reinstall only if appropriate (clearing data removes settings and cached artwork).
