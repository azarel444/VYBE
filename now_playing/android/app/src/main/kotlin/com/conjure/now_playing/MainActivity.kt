package com.conjure.now_playing

import android.app.ActivityOptions
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Rect
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import android.Manifest
import android.content.pm.PackageManager
import android.media.audiofx.Visualizer
import android.os.Build
import android.os.Handler
import android.os.Looper
import kotlin.math.hypot
import kotlin.math.log10
import kotlin.math.pow

open class MainActivity : FlutterActivity() {

    private var vybeDirect: VybeDirect? = null
    private var sink: EventChannel.EventSink? = null
    private var manager: MediaSessionManager? = null
    private var listenerComponent: ComponentName? = null
    private var controller: MediaController? = null
    private var lastTrackKey: String? = null

    private var visualizer: Visualizer? = null
    private var fftSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private val sessionsListener =
        MediaSessionManager.OnActiveSessionsChangedListener { list -> pick(list) }

    private val callback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) = push(true)
        override fun onPlaybackStateChanged(state: PlaybackState?) = push(false)
        override fun onSessionDestroyed() = refresh()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Dedicated, synchronously committed onboarding state. Avoid relying
        // solely on SharedPreferences' per-engine Dart cache.
        MethodChannel(messenger, "vybe/window_brightness").setMethodCallHandler { call, result ->
            if (call.method == "setNight") {
                val night = call.arguments as? Boolean ?: false
                runOnUiThread {
                    val params = window.attributes
                    if (night) {
                        val systemLevel = try {
                            Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255f
                        } catch (_: Exception) { 0.75f }
                        params.screenBrightness = (systemLevel * 0.75f).coerceIn(0.02f, 1f)
                    } else {
                        params.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    }
                    window.attributes = params
                    result.success(null)
                }
            } else result.notImplemented()
        }
        MethodChannel(messenger, "vybe/setup_state").setMethodCallHandler { call, result ->
            val prefs = getSharedPreferences("vybe_setup_state", Context.MODE_PRIVATE)
            when (call.method) {
                "isComplete" -> result.success(prefs.getBoolean("complete", false))
                "complete" -> result.success(prefs.edit().putBoolean("complete", true).commit())
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "nowplaying/stream").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    refresh()
                }

                override fun onCancel(args: Any?) {
                    sink = null
                }
            })

        EventChannel(messenger, "nowplaying/fft").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    fftSink = events
                }

                override fun onCancel(args: Any?) {
                    fftSink = null
                }
            })

        val directChannel = MethodChannel(messenger, "vybe/direct")
        vybeDirect = VybeDirect(this, directChannel)
        directChannel.setMethodCallHandler { call, result ->
            val direct = vybeDirect!!
            when (call.method) {
                "available" -> result.success(direct.available())
                "permission" -> result.success(direct.permission())
                "requestPermission" -> {
                    val permission = direct.permission()
                    if (android.os.Build.VERSION.SDK_INT >= 23 && checkSelfPermission(permission) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(permission), 8392)
                    }
                    result.success(true)
                }
                "start" -> result.success(direct.start())
                "host" -> result.success(direct.host())
                "discover" -> result.success(direct.discover())
                "connect" -> result.success(direct.connect(call.argument<String>("address") ?: ""))
                "stop" -> { direct.stop(); result.success(true) }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "nowplaying/control").setMethodCallHandler { call, result ->
            when (call.method) {
                "playPause" -> {
                    val c = controller
                    if (c?.playbackState?.state == PlaybackState.STATE_PLAYING)
                        c.transportControls.pause() else c?.transportControls?.play()
                    result.success(null)
                }
                "next" -> { controller?.transportControls?.skipToNext(); result.success(null) }
                "previous" -> { controller?.transportControls?.skipToPrevious(); result.success(null) }
                "refresh" -> { refresh(); result.success(null) }
                "recheckArtwork" -> { push(true); result.success(null) }
                "startVisualizer" -> result.success(startVisualizer())
                "stopVisualizer" -> { stopVisualizer(); result.success(null) }
                "openAccessSettings" -> { openAccessSettings(); result.success(null) }
                "seekTo" -> {
                    val ms = (call.arguments as? Number)?.toLong() ?: 0L
                    controller?.transportControls?.seekTo(ms)
                    result.success(null)
                }
                "openPlayer" -> result.success(openPlayer())
                "openOverlaySettings" -> { openOverlaySettings(); result.success(null) }
                "getContentChoices" -> {
                    val prefs = getSharedPreferences("vybe_content_choices", Context.MODE_PRIVATE)
                    val keys = listOf("artLookup", "lyrics", "bootStart", "musicStart")
                    result.success(keys.filter { prefs.contains(it) }.associateWith { prefs.getBoolean(it, false) })
                }
                "setContentChoice" -> {
                    val key = call.argument<String>("key")
                    val value = call.argument<Boolean>("value")
                    if (key !in listOf("artLookup", "lyrics", "bootStart", "musicStart") || value == null) {
                        result.error("BAD_CHOICE", "Invalid content choice", null)
                    } else {
                        val ok = getSharedPreferences("vybe_content_choices", Context.MODE_PRIVATE)
                            .edit().putBoolean(key, value).commit()
                        // The service reads these values from PlayerFilter.PREFS.
                        // Commit the same choice there immediately, rather than
                        // depending on a later Flutter listener callback.
                        val launchOk = when (key) {
                            "bootStart" -> getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE)
                                .edit().putBoolean("openOnBoot", value).commit()
                            "musicStart" -> getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE)
                                .edit().putBoolean("openOnMusic", value).commit()
                            else -> true
                        }
                        result.success(ok && launchOk)
                    }
                }
                "setLaunchSettings" -> {
                    getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE).edit()
                        .putBoolean("openOnBoot", call.argument<Boolean>("boot") ?: false)
                        .putBoolean("openOnMusic", call.argument<Boolean>("music") ?: false)
                        .putInt("graceSec", call.argument<Int>("graceSec") ?: 0)
                        .putBoolean("allowVideo", call.argument<Boolean>("allowVideo") ?: false)
                        .putBoolean("allowNav", call.argument<Boolean>("allowNav") ?: false)
                        .putBoolean("avoidNav", call.argument<Boolean>("avoidNav") ?: true)
                        .putString("navPkg", call.argument<String>("navPkg") ?: "")
                        .apply()
                    result.success(null)
                }
                "startDrive" -> {
                    getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE).edit()
                        .putBoolean("driveSwap", call.argument<Boolean>("swap") ?: false)
                        .putFloat("driveCenter", (call.argument<Double>("center") ?: 0.5).toFloat())
                        .putBoolean("driveControls", call.argument<Boolean>("controls") ?: true)
                        .putBoolean("driveAutoClose", call.argument<Boolean>("autoClose") ?: true)
                        .putString("navPkg", call.argument<String>("navPkg") ?: "")
                        .apply()
                    val svc = MediaListenerService.instance
                    when {
                        !Settings.canDrawOverlays(this) -> result.success("permission")
                        svc == null -> result.success("nolistener")
                        else -> { svc.startDrive(); result.success("ok") }
                    }
                }
                "startDriveScreen" -> {
                    if (Build.VERSION.SDK_INT >= 23 && !Settings.canDrawOverlays(this)) {
                        result.success("permission")
                    } else {
                        val pkg = call.argument<String>("navPkg") ?: ""
                        getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE).edit()
                            .putString("navPkg", pkg).apply()
                        val nav = launchNavigation(pkg, null)
                        if (nav == "nopkg" || nav == "none") {
                            result.success(nav)
                        } else {
                            // Give the map app a moment to come up, then put the
                            // see-through Drive window in front of it.
                            val app = applicationContext
                            mainHandler.postDelayed({
                                try {
                                    val i = FlutterActivity
                                        .NewEngineIntentBuilder(DriveActivity::class.java)
                                        .initialRoute("/drive")
                                        .backgroundMode(
                                            FlutterActivityLaunchConfigs.BackgroundMode.transparent)
                                        .build(app)
                                    i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    app.startActivity(i)
                                } catch (_: Exception) {
                                }
                            }, 1200L)
                            result.success("ok")
                        }
                    }
                }
                "exitDrive" -> {
                    try {
                        startActivity(
                            Intent(this, MainActivity::class.java)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                        )
                    } catch (_: Exception) {}
                    if (this is DriveActivity) finish()
                    result.success(null)
                }
                "hideDrive" -> {
                    val bubble = call.argument<Boolean>("bubble") ?: false
                    moveTaskToBack(true)
                    if (bubble && this is DriveActivity) {
                        MediaListenerService.instance?.showBubble()
                    }
                    result.success(null)
                }
                "navActive" -> result.success(MediaListenerService.instance?.navActiveNow() == true)
                "stopDrive" -> { MediaListenerService.instance?.stopDrive(); result.success(null) }
                "driveRunning" -> result.success(MediaListenerService.instance?.driveRunning() == true)
                "getPlayers" -> result.success(getPlayers())
                "setPlayerOverride" -> {
                    val pkg = call.argument<String>("pkg")
                    val mode = call.argument<String>("mode") ?: "auto"
                    if (pkg != null) {
                        PlayerFilter.setOverride(
                            getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE), pkg, mode)
                    }
                    result.success(null)
                }
                "permissionStatus" -> result.success(permissionStatus())
                "requestAudio" -> requestAudioForOnboarding(result)
                "getInstalledApps" -> result.success(getInstalledApps())
                "launchNavigation" -> {
                    val pkg = call.argument<String>("pkg") ?: ""
                    val l = call.argument<Int>("left")
                    val t = call.argument<Int>("top")
                    val r = call.argument<Int>("right")
                    val b = call.argument<Int>("bottom")
                    val bounds = if (l != null && t != null && r != null && b != null && r > l && b > t)
                        Rect(l, t, r, b) else null
                    result.success(launchNavigation(pkg, bounds))
                }
                else -> result.notImplemented()
            }
        }
    }

    // ------------------------------------------------------------ sessions

    private fun hasAccess(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
        return flat?.contains(packageName) == true
    }

    private fun refresh() {
        detach()
        if (!hasAccess()) {
            sink?.success(mapOf("access" to false, "active" to false))
            return
        }
        try {
            val m = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
            val cn = ComponentName(this, MediaListenerService::class.java)
            manager = m
            listenerComponent = cn
            m.addOnActiveSessionsChangedListener(sessionsListener, cn)
            pick(m.getActiveSessions(cn))
        } catch (e: SecurityException) {
            sink?.success(mapOf("access" to false, "active" to false))
        }
    }

    private fun detach() {
        try { manager?.removeOnActiveSessionsChangedListener(sessionsListener) } catch (_: Exception) {}
        try { controller?.unregisterCallback(callback) } catch (_: Exception) {}
        controller = null
        lastTrackKey = null
    }

    private fun pick(list: List<MediaController>?) {
        try { controller?.unregisterCallback(callback) } catch (_: Exception) {}
        // Prefer a music player over navigation voice or video sessions, and
        // a playing session over an idle one.
        val prefs = getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE)
        fun isMusic(c: MediaController) =
            PlayerFilter.classify(this, c.packageName, c.metadata) == PlayerFilter.Kind.MUSIC ||
                PlayerFilter.modeOf(prefs, c.packageName) == "allow"
        fun isPlaying(c: MediaController) = c.playbackState?.state == PlaybackState.STATE_PLAYING
        val chosen = list?.firstOrNull { isMusic(it) && isPlaying(it) }
            ?: list?.firstOrNull { isMusic(it) }
            ?: list?.firstOrNull { isPlaying(it) }
            ?: list?.firstOrNull()
        controller = chosen
        lastTrackKey = null
        chosen?.registerCallback(callback)
        push(true)
    }

    private fun push(withMeta: Boolean) {
        val s = sink ?: return
        val c = controller
        if (c == null) {
            s.success(mapOf("access" to true, "active" to false))
            return
        }
        val md = c.metadata
        val st = c.playbackState
        val speed = st?.playbackSpeed ?: 1f
        var pos = st?.position ?: 0L
        if (pos < 0) pos = 0
        if (st != null && st.state == PlaybackState.STATE_PLAYING) {
            pos += ((SystemClock.elapsedRealtime() - st.lastPositionUpdateTime) * speed).toLong()
        }

        val title = md?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""
        val artist = md?.getString(MediaMetadata.METADATA_KEY_ARTIST)
            ?: md?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: ""
        val album = md?.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: ""
        val duration = md?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L

        val map = hashMapOf<String, Any>(
            "access" to true,
            "active" to true,
            "playing" to (st?.state == PlaybackState.STATE_PLAYING),
            "title" to title,
            "artist" to artist,
            "album" to album,
            "duration" to duration,
            "position" to pos,
            "speed" to speed.toDouble(),
        )

        val key = "$title|$artist|$album|$duration"
        if (md != null && (withMeta || key != lastTrackKey)) {
            extractArt(md)?.let { map["art"] = it }
        }
        lastTrackKey = key
        s.success(map)
    }

    // ----------------------------------------------------------------- art

    private fun extractArt(md: MediaMetadata): ByteArray? {
        var bmp: Bitmap? = md.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: md.getBitmap(MediaMetadata.METADATA_KEY_ART)
            ?: md.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)

        if (bmp == null) {
            // Some players only provide a content:// or file:// URI.
            val uri = md.getString(MediaMetadata.METADATA_KEY_ALBUM_ART_URI)
                ?: md.getString(MediaMetadata.METADATA_KEY_ART_URI)
                ?: md.getString(MediaMetadata.METADATA_KEY_DISPLAY_ICON_URI)
            if (uri != null && (uri.startsWith("content:") || uri.startsWith("file:"))) {
                try {
                    contentResolver.openInputStream(Uri.parse(uri))?.use {
                        bmp = BitmapFactory.decodeStream(it)
                    }
                } catch (_: Exception) {}
            }
        }

        val b = bmp ?: return null
        val max = 1024
        val scaled = if (b.width > max || b.height > max) {
            val r = max.toFloat() / maxOf(b.width, b.height)
            Bitmap.createScaledBitmap(b, (b.width * r).toInt(), (b.height * r).toInt(), true)
        } else b
        val out = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.JPEG, 92, out)
        return out.toByteArray()
    }

    /**
     * Opens the player app that owns the current media session.
     * Returns "ok" or a short message that the screen can show.
     */
    private fun openPlayer(): String {
        val c = controller ?: return "No player is active"
        val pkg = c.packageName
        try {
            val launch = packageManager.getLaunchIntentForPackage(pkg)
            if (launch != null) {
                startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return "ok"
            }
        } catch (_: Exception) {}
        val pi = c.sessionActivity
        if (pi != null) {
            try {
                pi.send()
                return "ok"
            } catch (_: Exception) {}
        }
        return "Could not open $pkg"
    }

    private fun getPlayers(): List<Map<String, Any>> {
        val prefs = getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE)
        val out = ArrayList<Map<String, Any>>()
        for (entry in prefs.getStringSet("seen_players", emptySet()) ?: emptySet()) {
            val a = entry.indexOf('|')
            val b = if (a >= 0) entry.indexOf('|', a + 1) else -1
            if (a < 0 || b < 0) continue
            val pkg = entry.substring(0, a)
            val kind = try {
                PlayerFilter.Kind.valueOf(entry.substring(a + 1, b))
            } catch (_: Exception) {
                PlayerFilter.Kind.OTHER
            }
            out.add(mapOf(
                "pkg" to pkg,
                "label" to entry.substring(b + 1),
                "kind" to kind.name,
                "override" to PlayerFilter.modeOf(prefs, pkg),
                "allowed" to PlayerFilter.allowed(prefs, pkg, kind),
            ))
        }
        out.sortBy { (it["label"] as String).lowercase() }
        return out
    }

    private fun permissionStatus(): Map<String, Boolean> {
        val audio = Build.VERSION.SDK_INT < 23 ||
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val overlay = Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(this)
        return mapOf("notification" to hasAccess(), "audio" to audio, "overlay" to overlay)
    }

    private var pendingAudioResult: MethodChannel.Result? = null

    /** Asks for the audio permission and answers once the person has decided. */
    private fun requestAudioForOnboarding(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 23 ||
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        pendingAudioResult?.success(false)
        pendingAudioResult = result
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQ_AUDIO_ONBOARD)
    }

    private fun getInstalledApps(): List<Map<String, String>> {
        return try {
            val pm = packageManager
            val i = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            val seen = HashSet<String>()
            val out = ArrayList<Map<String, String>>()
            for (ri in pm.queryIntentActivities(i, 0)) {
                val pkg = ri.activityInfo.packageName
                if (pkg == packageName || !seen.add(pkg)) continue
                out.add(mapOf("pkg" to pkg, "label" to ri.loadLabel(pm).toString()))
            }
            out.sortBy { it["label"]!!.lowercase() }
            out
        } catch (_: Exception) {
            emptyList()
        }
    }

    private val knownNavApps = listOf(
        "com.google.android.apps.maps", "com.waze", "com.sygic.aura",
        "com.here.app.maps", "net.osmand", "net.osmand.plus", "app.organicmaps",
        "com.mapfactor.navigator", "com.tomtom.gplay.navapp"
    )

    /**
     * Opens the navigation app, asking Android to put it in a window of the
     * given size (pixels) on top of VYBE. That only takes effect if the head
     * unit has freeform windows switched on and the nav app can be resized;
     * otherwise Android opens it full screen as usual.
     *
     * Returns "ok" (a window was requested), "full" (opened normally),
     * "nopkg" (no nav app chosen or found) or "none" (could not open it).
     */
    private fun launchNavigation(pkgIn: String, bounds: Rect?): String {
        var pkg = pkgIn
        if (pkg.isEmpty()) {
            pkg = knownNavApps.firstOrNull { packageManager.getLaunchIntentForPackage(it) != null } ?: ""
        }
        if (pkg.isEmpty()) return "nopkg"
        val launch = packageManager.getLaunchIntentForPackage(pkg) ?: return "none"
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (bounds != null && Build.VERSION.SDK_INT >= 24) {
            try {
                val opts = ActivityOptions.makeBasic().setLaunchBounds(bounds)
                try {
                    // 5 = freeform. Hidden API; ignored when not available.
                    val m = ActivityOptions::class.java
                        .getMethod("setLaunchWindowingMode", Int::class.javaPrimitiveType)
                    m.invoke(opts, 5)
                } catch (_: Throwable) {
                }
                startActivity(launch, opts.toBundle())
                return "ok"
            } catch (_: Exception) {
            }
        }
        return try {
            startActivity(launch)
            "full"
        } catch (_: Exception) {
            "none"
        }
    }

    /** "Display over other apps" lets the app open itself from the background. */
    private fun openOverlaySettings() {
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (_: Exception) {}
    }

    private fun openAccessSettings() {
        try {
            startActivity(Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    // ---------------------------------------------------------- visualizer

    /**
     * Taps the system audio output (session 0) and sends 96 frequency bands
     * to Flutter. On some Android versions this is blocked or returns
     * silence; the Flutter side then falls back to the simulated visualizer.
     */
    private fun startVisualizer(): String {
        if (visualizer != null) return "running"
        if (Build.VERSION.SDK_INT >= 23 &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQ_AUDIO)
            return "permission"
        }
        return try {
            val v = Visualizer(0)
            v.setEnabled(false)
            v.setCaptureSize(Visualizer.getCaptureSizeRange()[1])
            v.setDataCaptureListener(object : Visualizer.OnDataCaptureListener {
                override fun onWaveFormDataCapture(vis: Visualizer?, data: ByteArray?, rate: Int) {}
                override fun onFftDataCapture(vis: Visualizer?, fft: ByteArray?, rate: Int) {
                    if (fft != null) handleFft(fft)
                }
            }, Visualizer.getMaxCaptureRate(), false, true)
            v.setEnabled(true)
            visualizer = v
            "running"
        } catch (e: Exception) {
            "unavailable"
        }
    }

    private fun stopVisualizer() {
        try {
            visualizer?.setEnabled(false)
            visualizer?.release()
        } catch (_: Exception) {}
        visualizer = null
    }

    private fun handleFft(fft: ByteArray) {
        val half = fft.size / 2
        if (half < 8) return
        val mag = DoubleArray(half)
        for (k in 1 until half) {
            mag[k] = hypot(fft[2 * k].toDouble(), fft[2 * k + 1].toDouble())
        }
        val ratio = half * 0.73 // roughly up to 16 kHz
        val out = ByteArray(BANDS)
        for (i in 0 until BANDS) {
            val lo = ratio.pow(i.toDouble() / BANDS)
            val hi = ratio.pow((i + 1).toDouble() / BANDS)
            val v = if (hi - lo < 1.0) {
                val p = (lo + hi) / 2
                val a = p.toInt().coerceIn(0, half - 1)
                val f = p - a
                mag[a] * (1 - f) + mag[minOf(a + 1, half - 1)] * f
            } else {
                var m = 0.0
                for (k in lo.toInt()..minOf(hi.toInt(), half - 1)) m = maxOf(m, mag[k])
                m
            }
            val base = (20.0 * log10(v + 1.0) - 6.0) / 34.0
            val level = if (base <= 0.0) 0.0 else base * (1.0 + 0.5 * i / (BANDS - 1))
            out[i] = (level.coerceIn(0.0, 1.0) * 255).toInt().toByte()
        }
        mainHandler.post { fftSink?.success(out) }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_AUDIO_ONBOARD) {
            pendingAudioResult?.success(
                grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pendingAudioResult = null
            return
        }
        if (requestCode == REQ_AUDIO &&
            grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        ) {
            startVisualizer()
        }
    }

    // "On screen" means started, not resumed: in a split or freeform window
    // VYBE can be paused (another window has focus) but still visible.
    override fun onStart() {
        super.onStart()
        started++
        visible = true
        MediaListenerService.instance?.hideBubble()
        MediaListenerService.instance?.vybeVisible(true)
    }

    override fun onStop() {
        // Either VYBE screen counts: the normal one or the Drive window.
        started = maxOf(0, started - 1)
        visible = started > 0
        MediaListenerService.instance?.vybeVisible(visible)
        stopVisualizer()
        super.onStop()
    }

    companion object {
        @Volatile
        var visible = false
        private var started = 0

        private const val BANDS = 96
        private const val REQ_AUDIO = 4711
        private const val REQ_AUDIO_ONBOARD = 4712
    }

    override fun onDestroy() {
        stopVisualizer()
        detach()
        super.onDestroy()
    }
}

/** The see-through Drive window. It runs the same app on the '/drive' route. */
class DriveActivity : MainActivity() {
    // Explicitly request a transparent Flutter surface in the Drive engine.
    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setBackgroundDrawableResource(android.R.color.transparent)
        window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        alive = true
    }

    override fun onDestroy() {
        alive = false
        MediaListenerService.instance?.hideBubble()
        super.onDestroy()
    }

    companion object {
        /** True while the Drive window exists (shown or hidden behind the map). */
        @Volatile
        var alive = false
    }
}
