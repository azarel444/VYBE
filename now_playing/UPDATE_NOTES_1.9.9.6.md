# VYBE v1.9.9.6 — Foundation fixes, batch 1

- Typo landscape clock is top-center only while lyrics are actually displayed; otherwise upper-left to avoid album artwork. Top offset 22dp for lyric mode.
- Renamed existing persistent synced-lyrics switch to **Show lyrics**, with clearer explanation. Existing setting already suppresses lyrics and allows artwork in Typo; no new redundant switch added.
- Horizontal track skipping now requires at least 72 logical pixels of horizontal travel, at least 180 logical pixels/second of horizontal release velocity, and matching direction. The Flutter horizontal gesture recognizer already excludes predominantly vertical drags.

## Still pending
Expanded metadata treatment across non-Typo themes, further FX/theme fixes, Drive variants and navigation, performance and stress testing.

## Verification
Source archive validated. Flutter build was not run in this environment. Test Android 9 and Android 16 devices after GitHub Actions build.
