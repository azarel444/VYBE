# v1.9.9.23 Artwork recovery

- Invalidate pending artwork lookups on track change to prevent stale results.
- Retry unsuccessful online lookups up to four times with delays; no negative-result cache.
- Search up to 25 iTunes results with strict artist AND song matching, alternate queries, and album preference.
- Download fallback images with alternate candidates on failed download.
- Add Refresh Artwork button to playback controls when online artwork lookup is enabled.
- Preserve lyrics and other settings.

Build and device tests have not been run.
