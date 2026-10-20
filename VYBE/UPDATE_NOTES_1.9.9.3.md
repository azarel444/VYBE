# VYBE 1.9.9.3 — Pre-beta daily-use candidate

Based on 1.9.9.2. Changes:

- Onboarding now ends with a scrollable illustrated guide showing both **Standard** and **Drive Theme Activated** expanded control bars, with numbered icon explanations. The guide uses the real toolbar icon identifiers and their order, including Drive's Map and Close buttons. The final action is **Launch VYBE**.
- The same control guide is available again under Settings > General > Welcome > Floating toolbar guide.
- Branded Flutter splash is shown only when setup has not been completed. Returning users skip the 1.8-second splash and onboarding and open directly into Now Playing. A short black frame may appear while persistent settings are read; Android system splash behavior remains OS-controlled.
- Existing persistent theme and effect preferences are restored at startup. The dedicated Drive overlay remains a separate Android activity and uses the Drive theme only for that overlay without saving a replacement for the user's normal selected theme.
- MainActivity uses Android `singleTask` launch mode; auto-launch and boot intents use CLEAR_TOP + SINGLE_TOP, in addition to the existing visibility check and 3-second media launch debounce, to reduce duplicate activity instances.

**Testing requested:** Manual launcher + auto music launch + boot resume, repeated Bluetooth reconnects, Android 9 Drive overlay and map handoff, reopening settings guide, theme persistence across force-stop/reboot, portrait/landscape scrolling.

**Build validation:** Source archive integrity checked. Flutter/Dart SDK unavailable in this environment, so Android/Flutter compilation and device behavior must be verified in GitHub Actions and on devices.
