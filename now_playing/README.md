# VYBE 1.8.9 — expanded palette and reactive no-art background
# VYBE: build steps

1. Install Flutter and the Android SDK (or skip this and use Codemagic, see below).
2. Create the base project so Flutter generates the Gradle files and icons:

       flutter create --org com.conjure --project-name now_playing now_playing

3. Copy everything from this zip into that new `now_playing` folder, overwriting:
   - `pubspec.yaml`
   - `assets/` (the VYBE icon and logo)
   - `lib/` (replace the whole folder)
   - `android/app/src/main/AndroidManifest.xml`
   - `android/app/src/main/kotlin/com/conjure/now_playing/` (MainActivity.kt, MediaListenerService.kt, PlayerFilter.kt, BootReceiver.kt)
   - `android/app/src/main/res/mipmap-*` (the app icon)
   - `android/app/src/main/res/values/vybe_drive.xml` (the see-through Drive window theme)

4. If the build complains about minSdk, open `android/app/build.gradle`
   (or `build.gradle.kts`) and set `minSdk` to 21.

5. Build:

       flutter pub get
       flutter build apk --release

   Many older head units are 32-bit ARM. If the APK won't install or crashes
   on launch, rebuild with:

       flutter build apk --release --target-platform android-arm

   The APK is at `build/app/outputs/flutter-apk/app-release.apk`.

6. Sideload it onto the head unit, open it, tap "Open settings", and turn on
   notification access for VYBE. Start music in any player.

## Using it
- Tap the screen: controls appear for 5 seconds (theme switch, settings, previous, play/pause, next). A small label shows "live audio" or "simulated" so you can tell which visualizer is running.
- Themes (the first button cycles them): Focused, Side by Side, VHS, Edge to Edge, Drive, Fan, Diagonal, Record Cut, Typo. The grid button next to it opens a list of all themes.
- Drive: choosing the Drive theme opens your map app and then puts VYBE's fully themed screen in front of it, with a rounded see-through window against the right side (left with the swap setting) where the live map shows, so the car and route are centered. The visualizer comes off the window's left edge, and a large cover with the song info under it sits on the left. You can look at the map there but not touch it; tap the screen for controls, use the map button to hide VYBE and use the map, and the X to go back to normal VYBE. Picking any other theme in the Drive screen also goes back. Needs "Display over other apps". Turn-by-turn text is the map app's own, shown in the window.
- Fan has drop shadows and more blur on each cover further back. Visualizers that come off screen edges have a black shadow that fades inward. Record Cut has a large blurred black and white disc behind the record, with the visualizer on its left half.
- With no album art (or only a flat placeholder picture from the player), VYBE shows an animated night-sky backdrop (still in performance mode). Settings > Visuals has an All effects switch, the opposite of Performance mode.
- Settings is split into General, Visuals, Launch, Navigation and Permissions. Each effect has its own intensity slider.
- Auto-open: VYBE opens when you start or change a song, but not when a song ends and the next one plays on its own.
- Record Cut: a record that turns at 33 1/3 rpm (speeds up when playback starts, slows when it pauses, keeps its angle across tracks), with the visualizer running around its edge. Typo: song info on the left, large lyrics on the right, bars down both edges.
- After you leave VYBE for another app it will not open by itself for 10 minutes (Settings: Launch), even if a new song starts.
- First launch shows a splash and a tour that explains each permission before Android asks for it. It can be replayed from Settings under Permissions and privacy.
- Auto-open only fires when a music player starts (a session), never on track changes, short pauses, video, navigation voice or calls, and never while navigation is guiding. Settings has a per-player list.
- Optional effects (settings, all off by default): breathing glow, aurora sweep, light rays, beat ripples, water shimmer, cover bloom. Performance mode turns them all off.
- Settings (gear button): visualizer on/off, sensitivity, ring or bars, bar count, accent colors, VHS strength, background drift and beat pulse, particles, performance mode, night mode, burn-in protection.
- Seek: drag the progress bar in the controls. Tap the album cover to open the player app.
- Online features (settings, need internet): missing album art lookup (iTunes Search) and synced lyrics (LRCLIB). Both fail quietly when offline.
- Launch options (settings): open at boot, open when music starts. Newer Android may also need "Display over other apps" allowed; some head units have their own auto-start manager that must allow the app.
- Swipe left/right: next / previous track.
- The theme you pick is remembered.

## Codemagic (no local install)
Push the finished project folder to GitHub, connect the repo in Codemagic,
choose Flutter App, Android, and build the release APK.
