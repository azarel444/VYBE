# Drive / Google Maps PiP regression — architecture and ATOTO test plan

Status: **open; not fixed**. Tracking issue: https://github.com/azarel444/VYBE/issues/1.

## Verified behavior and cause

* Drive currently displays a translucent Flutter `DriveActivity` over Maps, with an opening in the Flutter UI where Maps is visible. `DriveActivity` has a separate Android task affinity.
* Tapping the map area calls the `hideDrive` native method in `MainActivity.kt`, which calls `moveTaskToBack(true)` and displays a `ReturnBubble` overlay. Maps becomes foreground.
* Tapping the Return bubble calls `startActivity(DriveActivity)`. This is an **activity foreground transition**. Maps can enter PiP when it loses foreground, regardless of whether the new activity is transparent or which intent flags are used. Changing `REORDER_TO_FRONT`, `CLEAR_TOP`, etc. does not prevent another app from entering PiP.
* Earlier attempts to change the return flags did not resolve PiP on the ATOTO. The latest commit on this branch restores the `/drive` route on a cold activity restore but **does not fix PiP**.

## Existing, non-destructive proof of concept

There is already a native `DriveOverlay.kt` that creates `WindowManager` windows with `TYPE_APPLICATION_OVERLAY` and `FLAG_NOT_FOCUSABLE`. The Return bubble supports **long press (650 ms)** to toggle `MediaListenerService.startDrive(mapSafePreview = true)` without calling `startActivity`. This is a *native overlay preview*, not the user's full Flutter Drive theme. It can help confirm that keeping Maps foreground avoids the PiP transition.

ATOTO validation: start Drive, tap Maps to show fullscreen Maps, **long-press** Return to VYBE. Verify Maps stays fullscreen behind the native overlay (no PiP), and that music keeps playing. Long-press again to hide the preview. This test does **not** constitute a final fix.

## Target implementation (do not silently substitute the native preview)

1. Move the **actual Flutter Drive UI** to a service-managed `FlutterView` in a `TYPE_APPLICATION_OVERLAY` window, not a foreground `DriveActivity`. Keep Maps the resumed foreground activity when showing/hiding Drive.
2. Use a dedicated Flutter engine (or a carefully managed shared engine), launched with route `/drive`, and transparent rendering. Follow Flutter's documented `FlutterView.attachToFlutterEngine` / lifecycle protocol; the overlay must not accidentally pause its animation loop when `MainActivity` stops. Transparent rendering on low-end ATOTO hardware requires profiling.
3. Extract native MethodChannel registration from the Activity into a service-safe host before enabling the new engine. Existing channels in `MainActivity.configureFlutterEngine` rely on Activity methods, permissions, local-art folder chooser, window brightness, navigation, and media controls. Preserve Connect, local artwork, fanart shuffle, theme-specific settings, and playback. Do not copy only part of the channels and ship a half-functional Drive screen.
4. The Flutter map opening is visually transparent, but a **full-screen touchable overlay still intercepts touches**. Preserve the current tap-map-area-to-hide behavior; do not assume transparent pixels pass taps to Maps. The Return bubble should show the same Flutter overlay without foregrounding an activity.
5. Keep the current `DriveActivity` path as a rollback/fallback during an opt-in ATOTO experiment. Do not make the experimental overlay default until it survives app/process recreation, navigation restarts, rotations, and playback changes.

## Acceptance tests

* Maps fullscreen -> Return -> **full Flutter Drive theme** over Maps, no Maps PiP.
* Tap map opening -> fullscreen Maps; repeat at least 10 times with active turn-by-turn directions.
* Artist artwork, album artwork, fanart cycling, visualizers, clock, controls, lyrics, and Drive theme profile remain correct.
* VYBE Connect remains stable; local artwork still wins when present; no extra network artwork lookups.
* Head-unit process/background lifecycle, screen off/on, navigation app restart, and orientation changes do not leave black/blank Flutter surfaces.
* No regression in normal Now Playing or auto-launch; Android 9 ATOTO and Samsung S23+ both tested.

Flutter references:
* https://docs.flutter.dev/add-to-app/android/add-flutter-view
* https://docs.flutter.dev/add-to-app/android/add-flutter-fragment
* https://api.flutter.dev/javadoc/io/flutter/embedding/android/FlutterView.html

**Do not mark issue #1 fixed based solely on a green APK build. Real ATOTO PiP testing is required.**
