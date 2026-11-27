package com.conjure.now_playing

import android.app.ActivityOptions
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Rect
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.media.AudioManager
import android.telephony.TelephonyManager
import android.view.KeyEvent
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
    private var cacheFolderResult: MethodChannel.Result? = null
    private val artworkRequestCode = 8943
    private val cacheRequestCode = 8944
    @Deprecated("Legacy activity result used for Android 9 compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != artworkRequestCode && requestCode != cacheRequestCode) return
        val cachePicker = requestCode == cacheRequestCode
        val pending = if (cachePicker) cacheFolderResult else artworkFolderResult
        if (cachePicker) cacheFolderResult = null else artworkFolderResult = null
        if (pending == null) return
        val uri = data?.data
        if (resultCode != android.app.Activity.RESULT_OK || uri == null) {
            pending.success(false)
            return
        }
        try {
            val granted = ((data?.flags ?: 0) and (
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION))
            contentResolver.takePersistableUriPermission(uri, granted)
            val prefs = getSharedPreferences("vybe_local_art", Context.MODE_PRIVATE)
            if (cachePicker) {
                val oldCache = portableCacheTree()
                prefs.edit().putString("cache_tree", uri.toString()).apply()
                clearPortableCacheIndex()
                // The existing source directory can be on an unplugged USB
                // drive. Failed migration must not erase the destination.
                Thread {
                    try { migrateOldPortableCache(oldCache, uri) } catch (_: Exception) {}
                }.start()
            } else {
                prefs.edit().putString("tree", uri.toString()).apply()
                clearPortableCacheIndex()
            }
            pending.success(true)
        } catch (e: Exception) {
            pending.error("folder", e.message, null)
        }
    }

    // Keep large artwork indexes out of FlutterSharedPreferences. On older
    // installs, migrate only this one key; preserve the SAF tree permission,
    // Connect pairing and all other preferences.
    private fun artworkIndexFile() = android.util.AtomicFile(
        java.io.File(filesDir, "vybe_local_art_index.json"))

    private fun writeArtworkIndex(json: String) {
        val file = artworkIndexFile()
        val output = file.startWrite()
        try {
            output.write(json.toByteArray(Charsets.UTF_8))
            file.finishWrite(output)
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        }
    }

    private fun readArtworkIndex(): String? {
        val file = artworkIndexFile()
        if (file.baseFile.exists()) {
            return file.openRead().bufferedReader(Charsets.UTF_8).use { it.readText() }
        }
        val legacy = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val old = legacy.getString("flutter.localArtworkIndex", null) ?: return null
        writeArtworkIndex(old)
        legacy.edit().remove("flutter.localArtworkIndex").apply()
        return old
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

    // New installations can select Documents/internal storage for persistent
    // artwork, independently of where music resides. Older installations
    // continue to read their historical Music/VYBE Cache folder until users
    // select another destination.
    private fun portableCacheTree(): Uri? {
        val prefs = getSharedPreferences("vybe_local_art", Context.MODE_PRIVATE)
        val raw = prefs.getString("cache_tree", null)
            ?: prefs.getString("tree", null) ?: return null
        return Uri.parse(raw)
    }

    private fun storageLocations(): Map<String, Any> {
        val prefs = getSharedPreferences("vybe_local_art", Context.MODE_PRIVATE)
        return mapOf(
            "music" to (prefs.getString("tree", null) ?: ""),
            "cache" to (prefs.getString("cache_tree", null) ?: ""),
            "independent" to (prefs.getString("cache_tree", null) != null),
            "effectiveCache" to (portableCacheTree()?.toString() ?: "")
        )
    }

    private fun portableCacheChild(tree: Uri, dir: Uri, filename: String): Pair<Uri, String>? {
        val id = android.provider.DocumentsContract.getDocumentId(dir)
        val children = android.provider.DocumentsContract
            .buildChildDocumentsUriUsingTree(tree, id)
        val columns = arrayOf(
            android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE)
        contentResolver.query(children, columns, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                if (cursor.getString(1) != filename) continue
                val docId = cursor.getString(0)
                val mime = cursor.getString(2) ?: ""
                return android.provider.DocumentsContract
                    .buildDocumentUriUsingTree(tree, docId) to mime
            }
        }
        return null
    }

    private fun portableCacheDirectory(create: Boolean,
        explicitTree: Uri? = null): Pair<Uri, Uri>? {
        val tree = explicitTree ?: portableCacheTree() ?: return null
        val root = android.provider.DocumentsContract.buildDocumentUriUsingTree(
            tree, android.provider.DocumentsContract.getTreeDocumentId(tree))
        val directoryMime = android.provider.DocumentsContract.Document.MIME_TYPE_DIR
        val existing = portableCacheChild(tree, root, "VYBE Cache")
        if (existing != null) {
            if (existing.second != directoryMime) return null
            return tree to existing.first
        }
        if (!create) return null
        val writable = contentResolver.persistedUriPermissions.any {
            it.uri == tree && it.isWritePermission
        }
        if (!writable) return null
        val folder = android.provider.DocumentsContract.createDocument(
            contentResolver, root, directoryMime, "VYBE Cache") ?: return null
        return tree to folder
    }

    // The VYBE Cache can contain hundreds of files. Re-querying the entire
    // SAF directory for every cacheRead was O(n) per song after reinstall.
    // Build one in-memory filename -> document URI index per chosen folder.
    private val portableCacheIndexLock = Any()
    private var portableCacheIndexFolder: String? = null
    private var portableCacheIndexTime = 0L
    private var portableCacheIndex = mutableMapOf<String, Uri>()

    private fun clearPortableCacheIndex() = synchronized(portableCacheIndexLock) {
        portableCacheIndexFolder = null
        portableCacheIndex.clear()
        portableCacheIndexTime = 0L
    }

    private fun portableCacheFile(tree: Uri, dir: Uri, filename: String): Uri? =
        synchronized(portableCacheIndexLock) {
            val folderId = tree.toString() + "|" + dir.toString()
            val now = android.os.SystemClock.elapsedRealtime()
            // Refresh periodically so another VYBE engine can add cache files.
            if (portableCacheIndexFolder != folderId ||
                (now - portableCacheIndexTime > 120000L)) {
                val next = mutableMapOf<String, Uri>()
                val dirId = android.provider.DocumentsContract.getDocumentId(dir)
                val children = android.provider.DocumentsContract
                    .buildChildDocumentsUriUsingTree(tree, dirId)
                val columns = arrayOf(
                    android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE)
                contentResolver.query(children, columns, null, null, null)?.use { cursor ->
                    while (cursor.moveToNext()) {
                        val name = cursor.getString(1) ?: continue
                        if (cursor.getString(2) ==
                            android.provider.DocumentsContract.Document.MIME_TYPE_DIR) continue
                        val id = cursor.getString(0)
                        next[name] = android.provider.DocumentsContract
                            .buildDocumentUriUsingTree(tree, id)
                    }
                }
                portableCacheIndex = next
                portableCacheIndexFolder = folderId
                portableCacheIndexTime = now
            }
            portableCacheIndex[filename]
        }

    private fun rememberPortableCacheFile(tree: Uri, dir: Uri,
        filename: String, file: Uri) = synchronized(portableCacheIndexLock) {
        if (portableCacheIndexFolder == tree.toString() + "|" + dir.toString()) {
            portableCacheIndex[filename] = file
        }
    }

    private fun validPortableCacheName(filename: String): Boolean =
        Regex("[A-Za-z0-9_]{1,40}_[a-f0-9]{16}\\.bin").matches(filename)

    private fun portableCacheRead(filename: String): ByteArray? {
        if (!validPortableCacheName(filename)) return null
        val (tree, dir) = portableCacheDirectory(false) ?: return null
        val file = portableCacheFile(tree, dir, filename) ?: return null
        val bytes = contentResolver.openInputStream(file)?.use { it.readBytes() }
            ?: return null
        return bytes.takeIf { it.isNotEmpty() && it.size <= 12 * 1024 * 1024 }
    }

    private fun portableCacheWrite(filename: String, bytes: ByteArray): Boolean {
        if (!validPortableCacheName(filename) ||
            bytes.isEmpty() || bytes.size > 12 * 1024 * 1024) return false
        val (tree, dir) = portableCacheDirectory(true) ?: return false
        val file = portableCacheFile(tree, dir, filename) ?:
            android.provider.DocumentsContract.createDocument(
                contentResolver, dir, "application/octet-stream", filename)
                ?: return false
        rememberPortableCacheFile(tree, dir, filename, file)
        val stream = contentResolver.openOutputStream(file, "wt") ?: return false
        stream.use { it.write(bytes) }
        return true
    }

    // Copy the OLD persistent cache when moving to a different folder. Never
    // remove source files or overwrite backed-up files in the new destination.
    private fun migrateOldPortableCache(source: Uri?, destination: Uri) {
        if (source == null || source == destination) return
        val old = portableCacheDirectory(false, source) ?: return
        val oldId = android.provider.DocumentsContract.getDocumentId(old.second)
        val children = android.provider.DocumentsContract
            .buildChildDocumentsUriUsingTree(source, oldId)
        val columns = arrayOf(
            android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        contentResolver.query(children, columns, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val name = cursor.getString(1) ?: continue
                if (!validPortableCacheName(name)) continue
                try {
                    val doc = android.provider.DocumentsContract
                        .buildDocumentUriUsingTree(source, cursor.getString(0))
                    val newDir = portableCacheDirectory(true, destination) ?: return
                    if (portableCacheFile(newDir.first, newDir.second, name) != null) continue
                    val data = contentResolver.openInputStream(doc)?.use { it.readBytes() }
                        ?: continue
                    if (data.isNotEmpty() && data.size <= 12 * 1024 * 1024) {
                        portableCacheWrite(name, data)
                    }
                } catch (_: Exception) { /* Keep copying remaining files. */ }
            }
        }
    }

    // Import all indexed artwork into the independently chosen cache. The
    // source files remain untouched. Dart keeps the backed-up image index so
    // VYBE can rediscover those images after a USB drive goes missing.
    private fun mirrorLocalArtwork(
        entries: List<*>): List<String> {
        val saved = mutableListOf<String>()
        for (raw in entries) {
            val entry = raw as? Map<*, *> ?: continue
            val name = entry["cacheName"] as? String ?: continue
            val uriText = entry["uri"] as? String ?: continue
            if (!validPortableCacheName(name) || !uriText.startsWith("content://")) {
                continue
            }
            try {
                val target = portableCacheDirectory(true) ?: break
                if (portableCacheFile(target.first, target.second, name) != null) {
                    saved.add(name)
                    continue
                }
                val bytes = contentResolver.openInputStream(Uri.parse(uriText))
                    ?.use { it.readBytes() } ?: continue
                if (bytes.isNotEmpty() && bytes.size <= 12 * 1024 * 1024 &&
                    portableCacheWrite(name, bytes)) {
                    saved.add(name)
                }
            } catch (_: Exception) { /* Continue with remaining artwork. */ }
        }
        return saved
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
                    if (artworkFolderResult != null || cacheFolderResult != null) result.error("busy", "Folder chooser active", null)
                    else {
                        artworkFolderResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        }
                        startActivityForResult(intent, artworkRequestCode)
                    }
                }
                "chooseCacheFolder" -> {
                    if (artworkFolderResult != null || cacheFolderResult != null) {
                        result.error("busy", "Folder chooser active", null)
                    } else {
                        cacheFolderResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        }
                        startActivityForResult(intent, cacheRequestCode)
                    }
                }
                "getStorageLocations" -> result.success(storageLocations())
                "mirrorLocalArtwork" -> Thread {
                    try {
                        val entries = call.argument<List<*>>("entries") ?: emptyList<Any>()
                        val saved = mirrorLocalArtwork(entries)
                        runOnUiThread { result.success(saved) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("mirror_artwork", e.message, null) }
                    }
                }.start()
                "readIndex" -> Thread {
                    try {
                        val json = readArtworkIndex()
                        runOnUiThread { result.success(json) }
                    } catch (error: Exception) {
                        runOnUiThread { result.error("read_index", error.message, null) }
                    }
                }.start()
                "writeIndex" -> {
                    val json = call.argument<String>("json")
                    if (json == null) {
                        result.error("write_index", "Missing artwork index data", null)
                    } else Thread {
                        try {
                            writeArtworkIndex(json)
                            runOnUiThread { result.success(true) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error("write_index", error.message, null) }
                        }
                    }.start()
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
                "cacheRead" -> Thread {
                    try {
                        val filename = call.argument<String>("name") ?: ""
                        val bytes = portableCacheRead(filename)
                        runOnUiThread { result.success(bytes) }
                    } catch (_: Exception) {
                        runOnUiThread { result.success(null) }
                    }
                }.start()
                "cacheWrite" -> Thread {
                    try {
                        val filename = call.argument<String>("name") ?: ""
                        val bytes = call.argument<ByteArray>("bytes")
                        val saved = bytes != null && portableCacheWrite(filename, bytes)
                        runOnUiThread { result.success(saved) }
                    } catch (_: Exception) {
                        runOnUiThread { result.success(false) }
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
        // Android-wide media source control. This does not use vendor
        // packages, hidden Bluetooth A2DP Sink APIs, root or special grants.
        // A public MediaController may be able to request playback, but
        // activating a proprietary Bluetooth audio route is not guaranteed.
        MethodChannel(messenger, "vybe/bluetooth_audio").setMethodCallHandler { call, result ->
            when (call.method) {
                "scan" -> result.success(bluetoothAudioSnapshot())
                "requestPlay" -> result.success(requestExternalMediaPlay(
                    call.argument<String>("package") ?: ""))
                "systemPlay" -> result.success(requestSystemMediaPlay())
                else -> result.notImplemented()
            }
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

        // Album thumbnails for the real player-published Coverflow queue.
        // Retrieve only on demand, off the UI thread. Never decode a queue
        // bitmap on every 2-second now-playing metadata heartbeat.
        MethodChannel(messenger, "nowplaying/queue_art")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "thumbnail" -> {
                        val id = call.argument<Number>("queueId")?.toLong()
                        val side = call.argument<Number>("targetSide")?.toInt() ?: 768
                        if (id == null) {
                            result.success(null)
                        } else {
                            Thread {
                                val bytes = queueArtThumbnail(id, side)
                                mainHandler.post { result.success(bytes) }
                            }.start()
                        }
                    }
                    "encode" -> {
                        val input = call.argument<ByteArray>("bytes")
                        val side = call.argument<Number>("targetSide")?.toInt() ?: 768
                        if (input == null) {
                            result.success(null)
                        } else {
                            Thread {
                                val bytes = encodeQueueArtBytes(input, side)
                                mainHandler.post { result.success(bytes) }
                            }.start()
                        }
                    }
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

        // Opening USB tether settings is user-controlled; normal apps cannot
        // enable tethering silently. VYBE detects the resulting IP link.
        MethodChannel(messenger, "vybe/wired").setMethodCallHandler { call, result ->
            when (call.method) {
                "openTetherSettings" -> {
                    try {
                        startActivity(Intent("android.settings.TETHER_SETTINGS"))
                        result.success(true)
                    } catch (_: Exception) {
                        try {
                            startActivity(Intent(Settings.ACTION_WIRELESS_SETTINGS))
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("USB_TETHER_SETTINGS", error.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Keep the user-enabled VYBE Connect process alive when switching to
        // Bluetooth Audio, Maps or the launcher. This only maintains the
        // existing TCP and P2P session; it never starts audio capture.
        MethodChannel(messenger, "vybe/link_background")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        try {
                            val intent = Intent(this,
                                VybeLinkKeepAliveService::class.java).apply {
                                action = if (enabled)
                                    VybeLinkKeepAliveService.ACTION_START
                                    else VybeLinkKeepAliveService.ACTION_STOP
                            }
                            if (enabled) {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                                    startForegroundService(intent)
                                else startService(intent)
                            } else {
                                stopService(intent)
                            }
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("LINK_BACKGROUND_SERVICE",
                                "Cannot maintain VYBE Connect in background: ${error.message}", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        val directChannel = MethodChannel(messenger, "vybe/direct")
        vybeDirect = VybeDirect(this, directChannel)
        directChannel.setMethodCallHandler { call, result ->
            val direct = vybeDirect!!
            when (call.method) {
                "available" -> result.success(direct.available())
                "bandCapabilities" -> result.success(direct.bandCapabilities())
                "refreshBandInfo" -> result.success(direct.refreshBandInfo())
                "permission" -> result.success(direct.permission())
                "requestPermission" -> {
                    val permission = direct.permission()
                    if (android.os.Build.VERSION.SDK_INT >= 23 && checkSelfPermission(permission) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(permission), 8392)
                    }
                    result.success(true)
                }
                "start" -> result.success(direct.start())
                "host" -> result.success(direct.host(
                    call.argument<String>("receiverId") ?: "",
                    call.argument<Boolean>("refreshAdvertisement") ?: false))
                "publishHost" -> result.success(direct.publishHost(call.argument<String>("receiverId") ?: ""))
                "discoverRaw" -> result.success(direct.discoverRaw())
                "discover" -> result.success(direct.discover(
                    call.argument<Boolean>("force") ?: false))
                "connect" -> result.success(direct.connect(
                    call.argument<String>("address") ?: "",
                    call.argument<String>("bandMode") ?: "auto",
                    call.argument<Boolean>("rawSelected") ?: false))
                "cancelAuto" -> result.success(direct.cancelAutomaticPairing())
                "resetGroup" -> result.success(direct.resetStaleGroup())
                "resetSession" -> result.success(direct.resetSession())
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
                "pauseYoutubeMusicForVideoTest" -> result.success(pauseYoutubeMusicForVideoTest())
                "advanceYoutubeMusicForVideoTest" -> result.success(advanceYoutubeMusicForVideoTest())
                "resumeYoutubeMusicForVideoTest" -> result.success(resumeYoutubeMusicForVideoTest())
                // Production Music Video theme uses the precise original media
                // app, not the possibly changed global MediaSession controller.
                "musicVideoSourceSnapshot" -> result.success(musicVideoSourceSnapshot(
                    call.argument<String>("package") ?: ""))
                "captureYoutubeSongArtwork" -> result.success(captureYoutubeSongArtwork())
                "musicVideoOpenSource" -> result.success(
                    musicVideoOpenSource(call.argument<String>("package") ?: ""))
                "musicVideoSourceControl" -> result.success(musicVideoSourceControl(
                    call.argument<String>("package") ?: "",
                    call.argument<String>("action") ?: "",
                    call.argument<String>("expectedTitle") ?: ""))
                "musicVideoCallState" -> result.success(musicVideoCallState())
                "requestMusicVideoCallPermission" -> requestMusicVideoCallPermission(result)
                "startVisualizer" -> result.success(startVisualizer())
                "stopVisualizer" -> { stopVisualizer(); result.success(null) }
                "openAccessSettings" -> { openAccessSettings(); result.success(null) }
                "seekTo" -> {
                    val ms = (call.arguments as? Number)?.toLong() ?: 0L
                    controller?.transportControls?.seekTo(ms)
                    result.success(null)
                }
                "openPlayer" -> result.success(openPlayer())
                "openMapsPipSettings" -> {
                    try {
                        startActivity(Intent("android.settings.PICTURE_IN_PICTURE_SETTINGS",
                            Uri.parse("package:com.google.android.apps.maps")))
                        result.success(null)
                    } catch (e: Exception) {
                        try {
                            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:com.google.android.apps.maps")))
                            result.success(null)
                        } catch (fallback: Exception) {
                            result.error("MAPS_SETTINGS", fallback.message, null)
                        }
                    }
                }
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


    /** Enumerate public Android media sessions without assuming an OEM
     * Bluetooth receiver package or a particular head-unit architecture.
     * "musicActive" and available audio devices are diagnostics only: they do
     * NOT prove that incoming Bluetooth A2DP is routed to the amplifier.
     */
    private fun bluetoothAudioSnapshot(): Map<String, Any?> {
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val routes: List<Map<String, Any?>> =
            if (Build.VERSION.SDK_INT >= 23) {
                try {
                    audio.getDevices(AudioManager.GET_DEVICES_INPUTS or
                        AudioManager.GET_DEVICES_OUTPUTS).map { device ->
                        mapOf(
                            "type" to device.type,
                            "role" to if (device.isSource) "input" else "output",
                            "name" to device.productName.toString()
                        )
                    }
                } catch (_: Exception) { emptyList() }
            } else emptyList()
        if (!hasAccess()) return mapOf(
            "access" to false,
            "musicActive" to audio.isMusicActive,
            "devices" to routes,
            "sessions" to emptyList<Map<String, Any?>>(),
            "message" to "Grant VYBE Notification Access to inspect active Android media sessions.")
        return try {
            val service = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
            val component = ComponentName(this, MediaListenerService::class.java)
            val sources = service.getActiveSessions(component).map { controller ->
                val pkg = controller.packageName
                val name = try {
                    packageManager.getApplicationLabel(
                        packageManager.getApplicationInfo(pkg, 0)).toString()
                } catch (_: Exception) { pkg }
                val playback = controller.playbackState
                val actions = playback?.actions ?: 0L
                val metadata = controller.metadata
                mapOf<String, Any?>(
                    "package" to pkg,
                    "name" to name,
                    "state" to (playback?.state ?: PlaybackState.STATE_NONE),
                    "playing" to (playback?.state == PlaybackState.STATE_PLAYING),
                    "canPlay" to (actions and PlaybackState.ACTION_PLAY != 0L ||
                        actions and PlaybackState.ACTION_PLAY_PAUSE != 0L),
                    "title" to (metadata?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""),
                    "playbackType" to (controller.playbackInfo?.playbackType ?: 0)
                )
            }
            mapOf("access" to true, "musicActive" to audio.isMusicActive,
                "devices" to routes, "sessions" to sources,
                "message" to if (sources.isEmpty())
                    "No active media sessions. A receiver that exposes no session cannot be started through MediaController."
                else "Select the Android media session belonging to the Bluetooth receiver.")
        } catch (error: Exception) {
            mapOf("access" to false, "musicActive" to audio.isMusicActive,
                "devices" to routes, "sessions" to emptyList<Map<String, Any?>>(),
                "message" to "Media session inspection unavailable: ${error.message}")
        }
    }

    /** Send PLAY only to a session explicitly selected by the user. Never
     * auto-start an unrelated music app or assume the command routed audio.
     */
    private fun requestExternalMediaPlay(pkg: String): Map<String, Any?> {
        if (pkg.isBlank()) return mapOf(
            "requested" to false, "message" to "Choose a receiver media session first.")
        if (!hasAccess()) return mapOf(
            "requested" to false, "message" to "Notification Access is required.")
        return try {
            val service = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
            val component = ComponentName(this, MediaListenerService::class.java)
            val matches = service.getActiveSessions(component)
                .filter { it.packageName == pkg }
            val target = matches.firstOrNull {
                it.playbackState?.state == PlaybackState.STATE_PLAYING
            } ?: matches.firstOrNull()
            if (target == null) {
                mapOf("requested" to false,
                    "message" to "Selected receiver has no active media session. Android cannot activate its private audio source through a public media session.")
            } else {
                val state = target.playbackState
                val playing = state?.state == PlaybackState.STATE_PLAYING
                if (!playing) target.transportControls.play()
                mapOf("requested" to true,
                    "alreadyPlaying" to playing,
                    "message" to if (playing)
                        "Selected Android media session is already playing. Bluetooth audio routing is not verified."
                    else "PLAY requested on the selected Android media session. Audio routing is not verified.")
            }
        } catch (error: Exception) {
            mapOf("requested" to false, "message" to
                "Android refused media session control: ${error.message}")
        }
    }

    /** Explicit manual diagnostic only. Dispatching a global play key may
     * start an unrelated local player; never run this automatically.
     */
    private fun requestSystemMediaPlay(): Map<String, Any?> = try {
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PLAY))
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MEDIA_PLAY))
        mapOf("requested" to true, "message" to
            "System PLAY key sent to Android's current media-key consumer; Bluetooth source activation is not confirmed.")
    } catch (error: Exception) {
        mapOf("requested" to false,
            "message" to "Could not dispatch system media key: ${error.message}")
    }

    // Called ONLY after the tester presses Play in the embedded-player test.
    // Pause exactly YouTube Music, never the currently selected VYBE output.
    // The user resumes YouTube Music manually after the test.
    private fun pauseYoutubeMusicForVideoTest(): Map<String, Any?> {
        if (!hasAccess()) return mapOf("paused" to false,
            "reason" to "Notification access unavailable; pause YouTube Music manually")
        return try {
            val mgr = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
            val cn = ComponentName(this, MediaListenerService::class.java)
            val c = mgr.getActiveSessions(cn).firstOrNull {
                it.packageName == "com.google.android.apps.youtube.music"
            }
            when {
                c == null -> mapOf("paused" to false,
                    "reason" to "No YouTube Music session; make sure other source audio is paused")
                c.playbackState?.state == PlaybackState.STATE_PAUSED ->
                    mapOf("paused" to false, "alreadyPaused" to true,
                        "reason" to "YouTube Music already paused")
                c.playbackState?.state != PlaybackState.STATE_PLAYING ->
                    mapOf("paused" to false,
                        "reason" to "YouTube Music is not playing")
                else -> {
                    c.transportControls.pause()
                    mapOf("paused" to true, "reason" to "Paused YouTube Music for embedded-video test")
                }
            }
        } catch (e: Exception) {
            mapOf("paused" to false,
                "reason" to "Could not pause YouTube Music: ${e.message}")
        }
    }

    // Music Video sequence diagnostic: target YouTube Music explicitly.
    // Never skip whatever happened to be selected by VYBE's general
    // media-session controller (which could belong to another app).
    private fun youtubeMusicSession(): MediaController? {
        if (!hasAccess()) return null
        return try {
            val mgr = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
            val component = ComponentName(this, MediaListenerService::class.java)
            mgr.getActiveSessions(component).firstOrNull {
                it.packageName == "com.google.android.apps.youtube.music"
            }
        } catch (_: Exception) { null }
    }

    private fun advanceYoutubeMusicForVideoTest(): Map<String, Any?> {
        val c = youtubeMusicSession() ?: return mapOf(
            "sent" to false, "reason" to "YouTube Music session unavailable")
        val state = c.playbackState
        if ((state?.actions ?: 0L) and PlaybackState.ACTION_SKIP_TO_NEXT == 0L) {
            return mapOf("sent" to false,
                "reason" to "YouTube Music does not expose Skip Next")
        }
        return try {
            val fromQueueId = state?.activeQueueItemId ?: -1L
            val fromTitle = c.metadata?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""
            c.transportControls.skipToNext()
            mapOf("sent" to true, "fromQueueId" to fromQueueId,
                "fromTitle" to fromTitle,
                "reason" to "Sent Skip Next to YouTube Music; awaiting new metadata")
        } catch (e: Exception) {
            mapOf("sent" to false, "reason" to "Skip Next failed: ${e.message}")
        }
    }

    private fun resumeYoutubeMusicForVideoTest(): Map<String, Any?> {
        val c = youtubeMusicSession() ?: return mapOf(
            "resumed" to false, "reason" to "YouTube Music session unavailable")
        return try {
            if (c.playbackState?.state == PlaybackState.STATE_PLAYING) {
                mapOf("resumed" to false, "alreadyPlaying" to true,
                    "reason" to "Source audio already playing")
            } else {
                c.transportControls.play()
                mapOf("resumed" to true,
                    "reason" to "Requested YouTube Music playback")
            }
        } catch (e: Exception) {
            mapOf("resumed" to false, "reason" to "Resume failed: ${e.message}")
        }
    }

    /** The theme must control the ORIGINAL source app after the WebView
     * starts producing audio. Never dispatch global media keys: they can
     * pause the iframe or an entirely unrelated music player.
     */
    private fun musicVideoSession(target: String): MediaController? {
        if (target.isBlank() || target == packageName || !hasAccess()) return null
        return try {
            val service = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
            val component = ComponentName(this, MediaListenerService::class.java)
            val matches = service.getActiveSessions(component).filter {
                it.packageName == target
            }
            matches.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
                ?: matches.firstOrNull()
        } catch (_: Exception) { null }
    }

    /** Open the source application's actual playback screen, regardless
     * of which MediaSession Android has selected for VYBE's global controls.
     * Never open the current VYBE WebView in place of the source app.
     */
    private fun musicVideoOpenSource(target: String): String {
        if (target.isBlank() || target == packageName)
            return "No source music player selected"

        // A MediaSession's sessionActivity PendingIntent may send without
        // bringing the source app forward. Start its real launcher FIRST.
        // Keep its existing task/video at the foreground if available.
        try {
            val launch = packageManager.getLaunchIntentForPackage(target)
            if (launch != null) {
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                startActivity(launch)
                return "ok"
            }
        } catch (error: Exception) {
            android.util.Log.w("VYBE", "Source launcher failed: $target", error)
        }

        // Some apps hide their launch intent from package visibility checks.
        // Their MediaSession sessionActivity remains a useful fallback.
        try {
            val session = musicVideoSession(target)
            val activity = session?.sessionActivity
            if (activity != null) {
                activity.send()
                return "ok"
            }
        } catch (error: Exception) {
            android.util.Log.w("VYBE", "Source session activity failed: $target", error)
        }
        return "Cannot open the source app: $target"
    }

    private fun musicVideoSourceSnapshot(target: String): Map<String, Any?> {
        val source = musicVideoSession(target) ?: return mapOf(
            "found" to false, "package" to target,
            "reason" to "Original source session unavailable")
        val metadata = source.metadata
        val state = source.playbackState
        return mapOf(
            "found" to true,
            "package" to source.packageName,
            "title" to (metadata?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""),
            "artist" to (metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: ""),
            "album" to (metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: ""),
            "playing" to (state?.state == PlaybackState.STATE_PLAYING),
            "paused" to (state?.state == PlaybackState.STATE_PAUSED),
            "canSkipNext" to ((state?.actions ?: 0L) and PlaybackState.ACTION_SKIP_TO_NEXT != 0L)
        )
    }

    private fun musicVideoSourceControl(
        target: String, action: String, expectedTitle: String): Map<String, Any?> {
        val source = musicVideoSession(target) ?: return mapOf(
            "sent" to false, "reason" to "Original music player not found")
        val currentTitle =
            source.metadata?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""
        // A playback-state event may publish the new song before Flutter's
        // title updates. User-initiated Next/Previous must not be rejected
        // for that title lag. Only asynchronous pause/resume commands need
        // the stale-song title guard. Source package is still exact.
        if (action != "next" && action != "previous" &&
            (expectedTitle.isBlank() ||
            !currentTitle.trim().equals(expectedTitle.trim(), ignoreCase = true))) {
            return mapOf("sent" to false,
                "reason" to "Source song changed; refusing stale video command")
        }
        val state = source.playbackState
        val actions = state?.actions ?: 0L
        return try {
            when (action) {
                "pause" -> when (state?.state) {
                    PlaybackState.STATE_PAUSED -> mapOf("alreadyPaused" to true,
                        "reason" to "Original music player already paused")
                    PlaybackState.STATE_PLAYING -> {
                        source.transportControls.pause()
                        mapOf("paused" to true, "reason" to "Paused original music source")
                    }
                    else -> mapOf("paused" to false,
                        "reason" to "Source is not playing or paused")
                }
                "resume" -> {
                    if (state?.state == PlaybackState.STATE_PLAYING) {
                        mapOf("alreadyPlaying" to true,
                            "reason" to "Original music source already playing")
                    } else {
                        source.transportControls.play()
                        mapOf("resumed" to true, "reason" to "Resumed source audio")
                    }
                }
                "next", "previous" -> {
                    val requiredAction = if (action == "next")
                        PlaybackState.ACTION_SKIP_TO_NEXT else PlaybackState.ACTION_SKIP_TO_PREVIOUS
                    // Some YouTube Music sessions implement skipToNext but
                    // don't advertise the corresponding supported-actions
                    // bit. Send the exact package controller's transport
                    // command and let the source's next metadata confirm it.
                    if (action == "next") source.transportControls.skipToNext()
                    else source.transportControls.skipToPrevious()
                    mapOf("sent" to true, "reportedSupported" to
                        (actions and requiredAction != 0L),
                        "reason" to "Track skip sent to original source")
                }
                else -> mapOf("sent" to false,
                    "reason" to "Unsupported music-video command")
            }
        } catch (error: Exception) {
            mapOf("sent" to false,
                "reason" to "Source control failed: " + (error.message ?: "unknown"))
        }
    }

    // Standalone Android head units can signal HFP calls through audio mode,
    // even when they have no telephony radio. Phone-side ringing detection
    // additionally uses the optional READ_PHONE_STATE runtime permission.
    private fun musicVideoCallState(): Map<String, Any?> {
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val mode = audio.mode
        val audioCall = mode == AudioManager.MODE_RINGTONE ||
            mode == AudioManager.MODE_IN_CALL ||
            mode == AudioManager.MODE_IN_COMMUNICATION
        val telephony = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        val hasPhone = telephony != null &&
            telephony.phoneType != TelephonyManager.PHONE_TYPE_NONE
        val permitted = Build.VERSION.SDK_INT < 23 ||
            checkSelfPermission(Manifest.permission.READ_PHONE_STATE) ==
                PackageManager.PERMISSION_GRANTED
        var cellularCall = false
        if (hasPhone && permitted) {
            try {
                cellularCall = telephony!!.callState != TelephonyManager.CALL_STATE_IDLE
            } catch (_: SecurityException) {}
        }
        return mapOf(
            "inCall" to (audioCall || cellularCall),
            "audioMode" to mode,
            "cellularCall" to cellularCall,
            "hasPhone" to hasPhone,
            "permissionGranted" to permitted,
            "permissionNeeded" to (hasPhone && !permitted),
            "detection" to if (cellularCall) "phone call state"
                else if (audioCall) "Android audio call mode" else "idle"
        )
    }

    private var pendingMusicVideoCallPermission: MethodChannel.Result? = null
    private val requestMusicVideoCallCode = 4785

    private fun requestMusicVideoCallPermission(result: MethodChannel.Result) {
        val telephony = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        if (telephony == null || telephony.phoneType == TelephonyManager.PHONE_TYPE_NONE ||
            Build.VERSION.SDK_INT < 23 ||
            checkSelfPermission(Manifest.permission.READ_PHONE_STATE) ==
                PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        pendingMusicVideoCallPermission?.success(false)
        pendingMusicVideoCallPermission = result
        requestPermissions(arrayOf(Manifest.permission.READ_PHONE_STATE),
            requestMusicVideoCallCode)
    }

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
            // Standard YouTube thumbnails include a video ID in /vi/VIDEO_ID/.
            // This is an *identifier*, not a media stream or embedability proof.
            fun youtubeThumbnailId(raw: String?): String? {
                if (raw.isNullOrBlank()) return null
                return try {
                    val uri = Uri.parse(raw)
                    if (uri.host?.lowercase() !in listOf("i.ytimg.com", "img.youtube.com")) {
                        null
                    } else {
                        val parts = uri.pathSegments
                        if (parts.size >= 2 &&
                            (parts[0] == "vi" || parts[0] == "vi_webp") &&
                            Regex("[A-Za-z0-9_-]{11}").matches(parts[1])) {
                            parts[1]
                        } else null
                    }
                } catch (_: Exception) { null }
            }
            val activeQueueEntry = queue?.firstOrNull {
                it.queueId == st?.activeQueueItemId
            }
            val activeQueueArtworkUri = activeQueueEntry?.description?.iconUri?.toString()
            val activeQueueVideoId = youtubeThumbnailId(activeQueueArtworkUri)
            val videoIdEntries = queue?.mapNotNull { item ->
                val id = youtubeThumbnailId(item.description.iconUri?.toString())
                    ?: return@mapNotNull null
                mapOf("queueId" to item.queueId, "videoId" to id,
                    "title" to (item.description.title?.toString() ?: ""))
            } ?: emptyList()
            val tracks = queue?.take(100)?.mapIndexed { index, item ->
                mapOf(
                    "index" to index, "queueId" to item.queueId,
                    "title" to item.description.title?.toString(),
                    "subtitle" to item.description.subtitle?.toString(),
                    "mediaId" to item.description.mediaId,
                    "artworkUri" to item.description.iconUri?.toString(),
                    "youtubeThumbnailVideoId" to youtubeThumbnailId(
                        item.description.iconUri?.toString()),
                    "mediaUri" to item.description.mediaUri?.toString(),
                    "extrasKeys" to (item.description.extras?.keySet()?.toList() ?: emptyList<String>())
                )
            } ?: emptyList()
            // Snapshot media-description and possible video-mode hints as exposed
            // by the Android MediaSession. This does NOT access or extract video.
            val description = md?.description
            val possibleVideoKeys = md?.keySet()?.filter { key ->
                val lower = key.lowercase()
                lower.contains("video") || lower.contains("mime") ||
                    lower.contains("content_type") || lower.contains("stream_type")
            }?.sorted() ?: emptyList<String>()
            val possibleVideoValues = possibleVideoKeys.associateWith { key ->
                try {
                    if (key.endsWith("_PX")) md?.getLong(key)?.toString()
                    else md?.getString(key)?.take(300)
                } catch (_: Exception) { null }
            }
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
                // A mediaId or mediaUri is only an identifier/reference, not
                // evidence of a directly readable audiovisual stream.
                "videoProbe" to mapOf(
                    "activeMediaId" to description?.mediaId,
                    "activeMediaUri" to description?.mediaUri?.toString(),
                    "activeQueueArtworkUri" to activeQueueArtworkUri,
                    "activeQueueVideoId" to activeQueueVideoId,
                    "queueVideoIdCount" to videoIdEntries.size,
                    "queueVideoIds" to videoIdEntries,
                    "descriptionTitle" to description?.title?.toString(),
                    "descriptionSubtitle" to description?.subtitle?.toString(),
                    "descriptionExtrasKeys" to (description?.extras?.keySet()?.sorted() ?: emptyList<String>()),
                    "possibleVideoMetadataKeys" to possibleVideoKeys,
                    "possibleVideoMetadataValues" to possibleVideoValues,
                    "playbackExtrasKeys" to (st?.extras?.keySet()?.sorted() ?: emptyList<String>()),
                    "sessionExtrasKeys" to (c.extras?.keySet()?.sorted() ?: emptyList<String>()),
                    "directVideoStreamVerified" to false,
                    "assessment" to "Thumbnail /vi/ IDs identify candidate YouTube videos only. Stream access and embed permissions remain unverified."
                ),
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

    // Artwork kind is a clue, NOT a reason to hide the source image.
    // Inspect the URI associated with the bitmap extractArt actually picks.
    private fun youtubeArtworkKind(md: MediaMetadata?): String {
        if (md == null) return "unknown"
        val albumUri = md.getString(MediaMetadata.METADATA_KEY_ALBUM_ART_URI)
        val artUri = md.getString(MediaMetadata.METADATA_KEY_ART_URI)
        val selectedUri = when {
            md.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) != null -> albumUri
            md.getBitmap(MediaMetadata.METADATA_KEY_ART) != null -> artUri
            else -> albumUri ?: artUri
        } ?: return "unknown"
        return try {
            val uri = Uri.parse(selectedUri)
            val host = uri.host?.lowercase() ?: ""
            when {
                (host == "ytimg.com" || host.endsWith(".ytimg.com") ||
                    host == "img.youtube.com") &&
                    uri.pathSegments.firstOrNull() in listOf("vi", "vi_webp", "an_webp") ->
                    "thumbnail"
                host == "lh3.googleusercontent.com" ||
                    host == "lh5.googleusercontent.com" -> "releaseCandidate"
                else -> "unknown"
            }
        } catch (_: Exception) { "unknown" }
    }

    // Read the source directly BEFORE VYBE pauses it to start its own video.
    // No transport command or mode switch is sent. Capture the exact bytes
    // and tags from one native snapshot, not a later metadata callback.
    private fun captureYoutubeSongArtwork(): Map<String, Any?> {
        val source = musicVideoSession("com.google.android.apps.youtube.music")
            ?: return emptyMap()
        val md = source.metadata ?: return emptyMap()
        val kind = youtubeArtworkKind(md)
        val title = md.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""
        val artist = md.getString(MediaMetadata.METADATA_KEY_ARTIST)
            ?: md.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: ""
        val album = md.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: ""
        return mapOf(
            "title" to title, "artist" to artist, "album" to album,
            "duration" to md.getLong(MediaMetadata.METADATA_KEY_DURATION),
            "sourceMediaId" to (md.getString(MediaMetadata.METADATA_KEY_MEDIA_ID) ?: ""),
            "youtubeArtworkKind" to kind,
            "art" to if (kind == "thumbnail") null else extractArt(md),
            "customActions" to (source.playbackState?.customActions?.map {
                mapOf("id" to it.action, "name" to it.name.toString())
            } ?: emptyList<Map<String, String>>())
        )
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
            // Identify the emitting player. Upload metadata may be corrected
            // only for YouTube Music; other music sessions remain untouched.
            "sourcePackage" to c.packageName,
            "duration" to duration,
            "position" to pos,
            "speed" to speed.toDouble(),
        )

        val youtube = c.packageName == "com.google.android.apps.youtube.music"
        val kind = if (youtube) youtubeArtworkKind(md) else "unknown"
        val mediaId = md?.getString(MediaMetadata.METADATA_KEY_MEDIA_ID) ?: ""
        if (youtube) {
            map["youtubeArtworkKind"] = kind
            map["sourceMediaId"] = mediaId
        }
        // Song/Video changes can retain the same display title.
        val key = "$title|$artist|$album|$duration" +
            (if (youtube) "|$mediaId|$kind" else "")
        if (withMeta || key != lastTrackKey) {
            map["queueItems"] = currentCoverflowQueue(c, st, title, artist)
        }
        if (md != null && (withMeta || key != lastTrackKey)) {
            extractArt(md)?.let { map["art"] = it }
        }
        lastTrackKey = key
        s.success(map)
    }

    /** Return only *actual* entries from the active Android media queue.
     * An empty queue never implies a fictional next song. The active item ID
     * is authoritative; title matching is used only when unambiguous.
     */
    private fun currentCoverflowQueue(
        c: MediaController, st: PlaybackState?, title: String, artist: String
    ): List<Map<String, Any?>> {
        val queue = try { c.queue } catch (_: Exception) { null }
        if (queue.isNullOrEmpty()) return emptyList()
        var activeIndex = queue.indexOfFirst { it.queueId == st?.activeQueueItemId }
        if (activeIndex < 0) {
            val match = queue.withIndex().filter { (_, item) ->
                item.description.title?.toString()?.trim()?.equals(
                    title.trim(), ignoreCase = true) == true &&
                    (artist.isBlank() ||
                        item.description.subtitle?.toString()?.trim()?.equals(
                            artist.trim(), ignoreCase = true) == true)
            }
            if (match.size != 1) return emptyList()
            activeIndex = match.first().index
        }
        val from = maxOf(0, activeIndex - 3)
        val to = minOf(queue.size - 1, activeIndex + 3)
        return (from..to).mapNotNull { index ->
            val entry = queue[index]
            val description = entry.description
            val name = description.title?.toString()?.trim() ?: ""
            if (name.isBlank()) null else mapOf(
                "id" to entry.queueId,
                "slot" to (index - activeIndex),
                "title" to name,
                "artist" to (description.subtitle?.toString() ?: ""),
                "artUri" to (description.iconUri?.toString() ?: ""),
                "hasBitmap" to (description.iconBitmap != null)
            )
        }
    }

    /**
     * Real MediaSession queue artwork rendered at adequate resolution for
     * Coverflow side sleeves (which occupy almost as much screen as the
     * selected album). Prefer the higher-resolution content URI to the
     * often 128/256px session iconBitmap. No enlargement of low-res sources.
     */
    private fun queueArtThumbnail(queueId: Long, requestedSide: Int): ByteArray? {
        val item = try { controller?.queue?.firstOrNull {
            it.queueId == queueId } } catch (_: Exception) { null } ?: return null
        val description = item.description
        val maxSide = requestedSide.coerceIn(384, 896)
        var image: Bitmap? = null
        val uri = description.iconUri
        if (uri != null && (uri.scheme == "content" || uri.scheme == "file" ||
                uri.scheme == "android.resource")) {
            image = try {
                val bounds = BitmapFactory.Options().apply {
                    inJustDecodeBounds = true
                }
                contentResolver.openInputStream(uri)?.use {
                    BitmapFactory.decodeStream(it, null, bounds)
                }
                var sample = 1
                while (maxOf(bounds.outWidth, bounds.outHeight) / sample >
                        maxSide * 2) sample *= 2
                val options = BitmapFactory.Options().apply {
                    inSampleSize = sample
                    inPreferredConfig = Bitmap.Config.RGB_565
                }
                contentResolver.openInputStream(uri)?.use {
                    BitmapFactory.decodeStream(it, null, options)
                }
            } catch (_: Exception) { null }
        }
        // Many players publish only a small icon. Use it if there is no
        // better asset, but do NOT upscale and claim detail is recovered.
        val bitmap = image ?: description.iconBitmap ?: return null
        return encodeQueueCoverBitmap(bitmap, maxSide)
    }

    private fun encodeQueueArtBytes(input: ByteArray, requestedSide: Int): ByteArray? {
        if (input.isEmpty() || input.size > 8 * 1024 * 1024) return null
        return try {
            val bounds = BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            BitmapFactory.decodeByteArray(input, 0, input.size, bounds)
            val maxSide = requestedSide.coerceIn(384, 896)
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / sample >
                    maxSide * 2) sample *= 2
            val options = BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.RGB_565
            }
            val bmp = BitmapFactory.decodeByteArray(
                input, 0, input.size, options) ?: return null
            try { encodeQueueCoverBitmap(bmp, maxSide) }
            finally { bmp.recycle() }
        } catch (_: Exception) { null }
    }

    private fun encodeQueueCoverBitmap(bitmap: Bitmap, maxSide: Int): ByteArray? {
        return try {
            val longest = maxOf(bitmap.width, bitmap.height)
            if (longest <= 0) return null
            val scaled = if (longest > maxSide) {
                val ratio = maxSide.toDouble() / longest
                Bitmap.createScaledBitmap(bitmap,
                    maxOf(1, (bitmap.width * ratio).toInt()),
                    maxOf(1, (bitmap.height * ratio).toInt()), true)
            } else bitmap
            try {
                // Keep actual pixel detail, while bounding transfers so
                // VYBE Connect can send up to six JPEG side sleeves.
                val output = ByteArrayOutputStream()
                var data = ByteArray(0)
                for (quality in intArrayOf(90, 83, 76, 68)) {
                    output.reset()
                    if (!scaled.compress(Bitmap.CompressFormat.JPEG,
                            quality, output)) return null
                    data = output.toByteArray()
                    if (data.size <= 240 * 1024) break
                }
                data.takeIf { it.size <= 280 * 1024 }
            } finally {
                if (scaled !== bitmap) scaled.recycle()
            }
        } catch (_: Exception) { null }
    }

    // ----------------------------------------------------------------- art

    private fun extractArt(md: MediaMetadata): ByteArray? {
        // Android DISPLAY_ICON is a player's generic play/music icon, not
        // verified album artwork. Use VYBE's own placeholder when ART and
        // ALBUM_ART (including their URIs) are absent.
        var bmp: Bitmap? = md.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: md.getBitmap(MediaMetadata.METADATA_KEY_ART)

        if (bmp == null) {
            // Some players only provide a content:// or file:// URI.
            val uri = md.getString(MediaMetadata.METADATA_KEY_ALBUM_ART_URI)
                ?: md.getString(MediaMetadata.METADATA_KEY_ART_URI)
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
        if (requestCode == requestMusicVideoCallCode) {
            pendingMusicVideoCallPermission?.success(
                grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pendingMusicVideoCallPermission = null
            return
        }
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
        // A hidden Drive activity may be reclaimed while navigation stays in
        // the foreground. Keep its return tab available unless Drive was
        // explicitly finished; ReturnBubble can recreate the /drive route.
        if (isFinishing) MediaListenerService.instance?.hideBubble()
        super.onDestroy()
    }

    companion object {
        /** True while the Drive window exists (shown or hidden behind the map). */
        @Volatile
        var alive = false
    }
}
