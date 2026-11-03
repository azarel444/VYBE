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

    private var artworkFolderResult: MethodChannel.Result? = null
    private val artworkRequestCode = 8943

    @Deprecated("Legacy activity result used for Android 9 compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != artworkRequestCode) return
        val pending = artworkFolderResult ?: return
        artworkFolderResult = null
        val uri = data?.data
        if (resultCode != android.app.Activity.RESULT_OK || uri == null) {
            pending.success(false)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION)
            getSharedPreferences("vybe_local_art", Context.MODE_PRIVATE).edit()
                .putString("tree", uri.toString()).apply()
            pending.success(true)
        } catch (e: Exception) { pending.error("folder", e.message, null) }
    }

    private fun scanArtworkTree(): List<Map<String, String>> {
        val tree = getSharedPreferences("vybe_local_art", Context.MODE_PRIVATE)
            .getString("tree", null) ?: return emptyList()
        val uri = Uri.parse(tree)
        val authority = android.provider.DocumentsContract.getTreeDocumentId(uri)
        val root = android.provider.DocumentsContract.buildDocumentUriUsingTree(uri, authority)
        val entries = mutableListOf<Map<String, String>>()
        val queue = java.util.ArrayDeque<Pair<Uri, String>>()
        queue.add(root to "")
        while (!queue.isEmpty() && entries.size < 25000) {
            val (folder, parent) = queue.removeFirst()
            val id = android.provider.DocumentsContract.getDocumentId(folder)
            val children = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(uri, id)
            val columns = arrayOf(
                android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE)
            contentResolver.query(children, columns, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val childId = cursor.getString(0)
                    val name = cursor.getString(1) ?: continue
                    val mime = cursor.getString(2) ?: ""
                    val child = android.provider.DocumentsContract.buildDocumentUriUsingTree(uri, childId)
                    if (mime == android.provider.DocumentsContract.Document.MIME_TYPE_DIR) {
                        if (parent.count { it == '/' } < 12) queue.add(child to "$parent/$name")
                    } else if (name.lowercase().matches(Regex(".*\\.(jpg|jpeg|png|webp)$"))) {
                        entries.add(mapOf("uri" to child.toString(), "name" to name,
                            "folder" to parent))
                    }
                }
            }
        }
        return entries
    }

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

        MethodChannel(messenger, "vybe/local_art").setMethodCallHandler { call, result ->
            when (call.method) {
                "chooseFolder" -> {
                    if (artworkFolderResult != null) result.error("busy", "Folder chooser active", null)
                    else {
                        artworkFolderResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        }
                        startActivityForResult(intent, artworkRequestCode)
                    }
                }
                "scan" -> Thread {
                    try {
                        val found = scanArtworkTree()
                        runOnUiThread { result.success(found) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("scan", e.message, null) }
                    }
                }.start()
                "read" -> Thread {
                    try {
                        val uri = Uri.parse(call.argument<String>("uri"))
                        val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                        runOnUiThread { result.success(bytes) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("read", e.message, null) }
                    }
                }.start()
                else -> result.notImplemented()
            }
        }
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
        MethodChannel(messenger, "vybe/preferences").setMethodCallHandler { call, result ->
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val key = call.argument<String>("key")
            when (call.method) {
                "getAll" -> {
                    val values = mutableMapOf<String, Any>()
                    for ((rawKey, rawValue) in prefs.all) {
                        if (!rawKey.startsWith("flutter.")) continue
                        val name = rawKey.removePrefix("flutter.")
                        when (rawValue) {
                            is Boolean, is Int, is Long, is Float -> values[name] = rawValue
                            is String -> {
                                val doublePrefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGRvdWJsZS4="
                                if (rawValue.startsWith(doublePrefix)) {
                                    rawValue.removePrefix(doublePrefix).toDoubleOrNull()?.let { values[name] = it }
                                } else values[name] = rawValue
                            }
                        }
                    }
                    result.success(values)
                }
                "set" -> {
                    val value = call.argument<Any>("value")
                    if (key == null || value == null) {
                        result.error("INVALID_PREF", "Missing key or value", null)
                    } else {
                        val editor = prefs.edit()
                        when (value) {
                            is Boolean -> editor.putBoolean("flutter.$key", value)
                            is Int -> editor.putInt("flutter.$key", value)
                            is Long -> editor.putLong("flutter.$key", value)
                            is Double -> editor.putString("flutter.$key", "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGRvdWJsZS4=" + value.toString())
                            is String -> editor.putString("flutter.$key", value)
                            else -> {
                                result.error("INVALID_PREF", "Unsupported type", null)
                                return@setMethodCallHandler
                            }
                        }
                        result.success(editor.commit())
                    }
                }
                else -> result.notImplemented()
            }
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
                "integrationDiagnostics" -> result.success(integrationDiagnostics(call.argument<String>("service") ?: ""))
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
                    val choices = getSharedPreferences("vybe_content_choices", Context.MODE_PRIVATE)
                    getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE).edit()
                        .putBoolean("openOnBoot", if (choices.contains("bootStart")) choices.getBoolean("bootStart", false) else (call.argument<Boolean>("boot") ?: false))
                        .putBoolean("openOnMusic", if (choices.contains("musicStart")) choices.getBoolean("musicStart", false) else (call.argument<Boolean>("music") ?: false))
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
                "launchDiagnostics" -> result.success(
                    getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE)
                        .getString("launch_diagnostics", "No launch events yet."))
                "clearLaunchDiagnostics" -> {
                    getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE)
                        .edit().remove("launch_diagnostics").apply()
                    result.success(null)
                }
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


    // Read-only inspection of the Android media-session contract. A published
    // queue is NOT proof of playlist browsing or arbitrary track playback.
    private fun integrationDiagnostics(service: String): Map<String, Any?> {
        val target = when (service) {
            "youtube_music" -> "com.google.android.apps.youtube.music"
            else -> return mapOf("error" to "Unknown integration")
        }
        if (!hasAccess()) return mapOf(
            "service" to service, "access" to false,
            "assessment" to "Enable Notification Access for VYBE, then retry.")
        return try {
            val mgr = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
            val cn = ComponentName(this, MediaListenerService::class.java)
            val sessions = mgr.getActiveSessions(cn)
            val matches = sessions.filter { it.packageName == target }
            val c = matches.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
                ?: matches.firstOrNull()
            if (c == null) return mapOf(
                "service" to service, "access" to true, "sessionFound" to false,
                "activePackages" to sessions.map { it.packageName },
                "assessment" to "No active media session for this app. Start playlist playback in the app and scan again.")
            val md = c.metadata
            val st = c.playbackState
            val queue = try { c.queue } catch (_: Exception) { null }
            val actions = st?.actions ?: 0L
            val skipToQueue = actions and PlaybackState.ACTION_SKIP_TO_QUEUE_ITEM != 0L
            val next = actions and PlaybackState.ACTION_SKIP_TO_NEXT != 0L
            val seek = actions and PlaybackState.ACTION_SEEK_TO != 0L
            val playFromId = actions and PlaybackState.ACTION_PLAY_FROM_MEDIA_ID != 0L
            val playFromSearch = actions and PlaybackState.ACTION_PLAY_FROM_SEARCH != 0L
            val tracks = queue?.take(100)?.mapIndexed { index, item ->
                mapOf(
                    "index" to index, "queueId" to item.queueId,
                    "title" to item.description.title?.toString(),
                    "subtitle" to item.description.subtitle?.toString(),
                    "mediaId" to item.description.mediaId,
                    "artworkUri" to item.description.iconUri?.toString(),
                    "mediaUri" to item.description.mediaUri?.toString(),
                    "extrasKeys" to (item.description.extras?.keySet()?.toList() ?: emptyList<String>())
                )
            } ?: emptyList()
            val flags = c.flags
            mapOf(
                "service" to service, "package" to target, "access" to true,
                "sessionFound" to true, "sessionCount" to matches.size,
                "playbackState" to (st?.state ?: -1),
                "scanTimeMs" to System.currentTimeMillis(),
                "activeQueueItemId" to (st?.activeQueueItemId ?: -1L),
                "playbackPositionMs" to (st?.position ?: -1L),
                "playbackActionsMask" to actions,
                "playbackExtrasKeys" to (st?.extras?.keySet()?.toList() ?: emptyList<String>()),
                "metadata" to mapOf(
                    "title" to md?.getString(MediaMetadata.METADATA_KEY_TITLE),
                    "artist" to md?.getString(MediaMetadata.METADATA_KEY_ARTIST),
                    "album" to md?.getString(MediaMetadata.METADATA_KEY_ALBUM),
                    "albumArtist" to md?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST),
                    "mediaId" to md?.getString(MediaMetadata.METADATA_KEY_MEDIA_ID),
                    "artUri" to md?.getString(MediaMetadata.METADATA_KEY_ART_URI),
                    "albumArtUri" to md?.getString(MediaMetadata.METADATA_KEY_ALBUM_ART_URI),
                    "displayIconUri" to md?.getString(MediaMetadata.METADATA_KEY_DISPLAY_ICON_URI),
                    "durationMs" to md?.getLong(MediaMetadata.METADATA_KEY_DURATION),
                    "hasEmbeddedArt" to (md?.getBitmap(MediaMetadata.METADATA_KEY_ART) != null),
                    "hasEmbeddedAlbumArt" to (md?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) != null),
                    "keys" to (md?.keySet()?.toList() ?: emptyList<String>())
                ),
                "queueTitle" to c.queueTitle?.toString(),
                "queueIds" to (queue?.map { it.queueId } ?: emptyList<Long>()),
                "queueArtworkUrlCount" to (queue?.count { it.description.iconUri != null } ?: 0),
                "queueMediaIdCount" to (queue?.count { it.description.mediaId != null } ?: 0),
                "queuePublished" to (queue != null),
                "queueLength" to (queue?.size ?: 0),
                "queueTruncated" to ((queue?.size ?: 0) > 100),
                "queue" to tracks,
                "sessionFlags" to flags,
                "actions" to mapOf(
                    "skipNext" to next, "skipPrevious" to
                        (actions and PlaybackState.ACTION_SKIP_TO_PREVIOUS != 0L),
                    "skipToQueueItem" to skipToQueue, "seek" to seek,
                    "playFromMediaId" to playFromId, "playFromSearch" to playFromSearch,
                    "play" to (actions and PlaybackState.ACTION_PLAY != 0L),
                    "pause" to (actions and PlaybackState.ACTION_PAUSE != 0L)
                ),
                "customActions" to (st?.customActions?.map { it.action } ?: emptyList<String>()),
                "sessionExtrasKeys" to (c.extras?.keySet()?.toList() ?: emptyList<String>()),
                "assessment" to when {
                    queue == null -> "Queue not published. Cannot confirm Up Next or playlist browsing from this session."
                    queue.isEmpty() -> "Queue is published but empty. No upcoming track data available."
                    else -> "Queue entries available for inspection. Up Next may be possible. Track jumping requires skipToQueueItem support and a real playback test; full playlist browsing is not established."
                },
                "upNextCandidate" to (queue != null && queue.size > 1),
                "activeItemInQueue" to (queue?.any { it.queueId == st?.activeQueueItemId } ?: false),
                "queueJumpCandidate" to (queue != null && queue.isNotEmpty() && skipToQueue),
                "fullPlaylistBrowsingVerified" to false,
                "prefetchCandidate" to (queue != null && queue.size > 1),
                "limitations" to "Android session queues may be partial, shuffled or different from playlists. No streaming API access is tested here."
            )
        } catch (e: Exception) {
            mapOf("service" to service, "access" to true,
                "error" to (e.javaClass.simpleName + ": " + (e.message ?: "unknown")))
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

    // Auto-launch must check whether VYBE owns foreground focus, not
    // whether its activity is merely started behind another music player.
    override fun onResume() {
        super.onResume()
        resumedActivities++
        visible = true
        MediaListenerService.instance?.hideBubble()
        MediaListenerService.instance?.vybeVisible(true)
    }

    override fun onPause() {
        resumedActivities = maxOf(0, resumedActivities - 1)
        visible = resumedActivities > 0
        MediaListenerService.instance?.vybeVisible(visible)
        super.onPause()
    }

    override fun onStop() {
        stopVisualizer()
        super.onStop()
    }

    companion object {
        @Volatile
        var visible = false
        private var resumedActivities = 0

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
