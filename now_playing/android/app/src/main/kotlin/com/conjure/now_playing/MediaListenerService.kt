package com.conjure.now_playing

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Android only lets an app read other apps' media sessions if it owns an
 * enabled notification listener, so this service gives MainActivity that
 * permission.
 *
 * It also stays alive while notification access is on, even with the app
 * screen closed. That lets it open VYBE, and it hosts the Drive overlay.
 *
 * When VYBE opens by itself:
 *  - The person starts music, or picks or skips to another track. These all
 *    open VYBE.
 *  - A track that simply ends and rolls into the next one never does.
 *  - A short pause followed by play (a navigation voice prompt, say) never
 *    does. How short is a setting.
 *  - Only music players, unless video or navigation audio is switched on.
 *  - Never while navigation is guiding, during a call, or when VYBE is
 *    already on screen.
 */
class MediaListenerService : NotificationListenerService() {

    private class Watch(val c: MediaController, val cb: MediaController.Callback)

    /** What we last knew about a player's current track. */
    private class Snap(
        var key: String,
        var durationMs: Long,
        var posMs: Long,
        var stamp: Long,
        var speed: Float,
        var isPlaying: Boolean,
        var endedNaturally: Boolean = false,
    ) {
        /** Where the track is now, worked out from the last report. */
        fun estimate(now: Long): Long {
            var p = posMs
            if (isPlaying) p += ((now - stamp) * speed).toLong()
            if (durationMs > 0 && p > durationMs) p = durationMs
            return if (p < 0) 0 else p
        }
    }

    private var manager: MediaSessionManager? = null
    private var watches = ArrayList<Watch>()

    /** Packages that are playing right now, and when each last stopped. */
    private val playing = HashSet<String>()
    private val pausedAt = HashMap<String, Long>()
    private val snaps = HashMap<String, Snap>()
    private val userChangeAt = HashMap<String, Long>()
    private val endedAt = HashMap<String, Long>()
    private var lastLaunch = 0L

    private val main = Handler(Looper.getMainLooper())
    private var drive: DriveOverlay? = null
    private var navSeen = false
    private var lastArtKey = ""
    private var lastArt: android.graphics.Bitmap? = null

    private val autoClose = Runnable {
        if (drive?.running == true && !navigationNotificationActive()) stopDrive()
    }

    private val sessionsListener =
        MediaSessionManager.OnActiveSessionsChangedListener { list -> attach(list) }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        drive = DriveOverlay(this).also {
            it.controllerProvider = { pickController() }
            it.onClose = { stopDrive() }
        }
        try {
            val m = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
            val cn = ComponentName(this, MediaListenerService::class.java)
            manager = m
            m.addOnActiveSessionsChangedListener(sessionsListener, cn)
            attach(m.getActiveSessions(cn))
        } catch (_: Exception) {
        }
    }

    override fun onListenerDisconnected() {
        instance = null
        main.removeCallbacks(autoClose)
        bubble?.hide()
        bubble = null
        drive?.stop()
        drive = null
        for (w in watches) {
            try {
                w.c.unregisterCallback(w.cb)
            } catch (_: Exception) {
            }
        }
        watches = ArrayList()
        playing.clear()
        try {
            manager?.removeOnActiveSessionsChangedListener(sessionsListener)
        } catch (_: Exception) {
        }
        super.onListenerDisconnected()
    }

    // ------------------------------------------------------------ sessions

    /**
     * Called whenever the set of active sessions changes. A session that is
     * new to us is checked right away: a player that appears already playing
     * produces no state change, which used to make auto-open miss.
     */
    private fun attach(list: List<MediaController>?) {
        val now = SystemClock.elapsedRealtime()
        val keep = ArrayList<Watch>()
        val fresh = ArrayList<Watch>()
        for (c in list ?: emptyList()) {
            val existing = watches.firstOrNull { it.c.sessionToken == c.sessionToken }
            if (existing != null) {
                keep.add(existing)
                continue
            }
            val cb = object : MediaController.Callback() {
                override fun onPlaybackStateChanged(state: PlaybackState?) {
                    trackState(c, state)
                    handleState(c, state, true)
                    if (drive?.running == true) pushOverlay()
                }

                override fun onMetadataChanged(metadata: MediaMetadata?) {
                    handleMetadata(c, metadata)
                    if (drive?.running == true) pushOverlay()
                }
            }
            val w = Watch(c, cb)
            try {
                c.registerCallback(cb)
            } catch (_: Exception) {
                continue
            }
            keep.add(w)
            fresh.add(w)
        }
        for (old in watches) {
            if (keep.none { it.c.sessionToken == old.c.sessionToken }) {
                try {
                    old.c.unregisterCallback(old.cb)
                } catch (_: Exception) {
                }
                // The session went away: treat it as a stop.
                val pkg = old.c.packageName
                if (playing.remove(pkg)) pausedAt[pkg] = now
            }
        }
        watches = keep
        for (w in fresh) {
            remember(w.c)
            if (!snaps.containsKey(w.c.packageName)) {
                snaps[w.c.packageName] = newSnap(w.c, w.c.metadata)
            }
            handleState(w.c, w.c.playbackState, false)
            // Some players publish their PLAYING state after the session
            // appears, without delivering a callback to a newly registered
            // listener. Re-read the state briefly during session startup.
            val token = w.c.sessionToken
            for (delay in listOf(350L, 1000L, 2200L)) {
                main.postDelayed({
                    if (watches.any { it.c.sessionToken == token }) {
                        handleState(w.c, w.c.playbackState, false)
                    }
                }, delay)
            }
        }
        if (drive?.running == true) pushOverlay()
    }

    private fun remember(c: MediaController) {
        try {
            val prefs = getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE)
            val kind = PlayerFilter.classify(this, c.packageName, c.metadata)
            PlayerFilter.remember(this, prefs, c.packageName, kind)
        } catch (_: Exception) {
        }
    }

    private fun keyOf(md: MediaMetadata?): String {
        if (md == null) return ""
        val t = md.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""
        val a = md.getString(MediaMetadata.METADATA_KEY_ARTIST)
            ?: md.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: ""
        val al = md.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: ""
        return if (t.isEmpty() && a.isEmpty() && al.isEmpty()) "" else "$t|$a|$al"
    }

    private fun newSnap(c: MediaController, md: MediaMetadata?): Snap {
        val st = c.playbackState
        val now = SystemClock.elapsedRealtime()
        val lu = st?.lastPositionUpdateTime ?: 0L
        return Snap(
            key = keyOf(md),
            durationMs = md?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L,
            posMs = maxOf(0L, st?.position ?: 0L),
            stamp = if (lu > 0L) lu else now,
            speed = st?.playbackSpeed ?: 1f,
            isPlaying = st?.state == PlaybackState.STATE_PLAYING,
        )
    }

    /**
     * Keeps the snapshot current, and notices when the position jumps back
     * from the very end of a track: that is a track finishing on its own.
     */
    private fun trackState(c: MediaController, st: PlaybackState?) {
        val s = snaps[c.packageName] ?: return
        if (st == null) return
        val now = SystemClock.elapsedRealtime()
        val newPos = st.position
        if (s.durationMs > 0) {
            val est = s.estimate(now)
            if (est >= s.durationMs - END_WINDOW_MS && newPos in 0L until (est - 5000L)) {
                s.endedNaturally = true
                endedAt[c.packageName] = now
            }
        }
        s.posMs = if (newPos < 0) 0L else newPos
        s.stamp = if (st.lastPositionUpdateTime > 0L) st.lastPositionUpdateTime else now
        s.speed = st.playbackSpeed
        s.isPlaying = st.state == PlaybackState.STATE_PLAYING
    }

    /**
     * A different track is now loaded. If the old one had just run out, this
     * is the player rolling on by itself and VYBE stays put. Otherwise the
     * person picked or skipped to it, and VYBE opens.
     */
    private fun handleMetadata(c: MediaController, md: MediaMetadata?) {
        val pkg = c.packageName
        val now = SystemClock.elapsedRealtime()
        val key = keyOf(md)
        val dur = md?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L
        val prev = snaps[pkg]
        if (prev == null) {
            snaps[pkg] = newSnap(c, md)
            return
        }
        if (key.isEmpty()) return // metadata is being cleared
        if (key == prev.key) {
            if (dur > 0) prev.durationMs = dur // the length often arrives late
            return
        }
        val ended = prev.endedNaturally ||
            (prev.durationMs > 0 && prev.estimate(now) >= prev.durationMs - END_WINDOW_MS)
        prev.key = key
        prev.durationMs = dur
        prev.posMs = 0L
        prev.stamp = now
        prev.endedNaturally = false
        if (ended) {
            endedAt[pkg] = now
            return
        }
        // Metadata changes alone cannot distinguish automatic playlist
        // progression from a deliberate skip. Never foreground VYBE here.
        // A genuine playback start is handled separately in onStart.
    }

    /**
     * [live] is true for a state change reported by the player, and false
     * for the first look at a session we just discovered.
     */
    private fun handleState(c: MediaController, st: PlaybackState?, live: Boolean) {
        val pkg = c.packageName
        val now = SystemClock.elapsedRealtime()
        when (st?.state ?: PlaybackState.STATE_NONE) {
            PlaybackState.STATE_PLAYING -> {
                if (playing.add(pkg)) {
                    // A just-found session only counts as a fresh start if
                    // its state was set a moment ago. Otherwise the music has
                    // been going for a while (service restarted, say).
                    // Some players retain an older position timestamp when
                    // they start playing. For newly observed playback, use
                    // position near the beginning as additional evidence.
                    // Do not treat an already-running session as a new start.
                    val position = st?.position ?: -1L
                    val timestampRecent = st != null &&
                        now - st.lastPositionUpdateTime in 0L..5000L
                    val nearStart = position in 0L..4000L &&
                        (st?.playbackSpeed ?: 0f) > 0f
                    val recent = live || timestampRecent || nearStart
                    onStart(c, recent)
                }
            }
            PlaybackState.STATE_PAUSED,
            PlaybackState.STATE_STOPPED,
            PlaybackState.STATE_NONE,
            PlaybackState.STATE_ERROR -> {
                if (playing.remove(pkg)) {
                    pausedAt[pkg] = now
                    val s = snaps[pkg]
                    if (s != null && s.durationMs > 0 &&
                        (s.endedNaturally || s.estimate(now) >= s.durationMs - END_WINDOW_MS)
                    ) {
                        endedAt[pkg] = now
                    }
                }
            }
            else -> {
                // Buffering, connecting, skipping and so on: not a change.
            }
        }
    }

    private fun onStart(c: MediaController, recent: Boolean) {
        if (!recent) return
        val prefs = getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE)
        val pkg = c.packageName
        val now = SystemClock.elapsedRealtime()

        // The player rolling from one track to the next by itself.
            val e = endedAt[pkg]
            if (e != null && now - e < 8000L) return
            // A short pause followed by play, such as after a voice prompt.
            val graceMs = prefs.getInt("graceSec", 0) * 1000L
            val last = pausedAt[pkg]
            if (last != null && now - last < graceMs) return
        launchVybe(c)
    }

    private fun launchVybe(c: MediaController) {
        val prefs = getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE)
        val pkg = c.packageName
        val now = SystemClock.elapsedRealtime()
        if (!prefs.getBoolean("openOnMusic", false)) return
        val kind = PlayerFilter.classify(this, pkg, c.metadata)
        if (!PlayerFilter.allowed(prefs, pkg, kind)) return
        if (MainActivity.visible) return
        if (prefs.getBoolean("avoidNav", true) && navigationActive(prefs)) return
        if (inCall()) return
        if (now - lastLaunch < 3000L) return
        lastLaunch = now
        userChangeAt.remove(pkg)
        try {
            val i = Intent(this, MainActivity::class.java)
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            startActivity(i)
        } catch (_: Exception) {
        }
    }

    // ----------------------------------------------------------- navigation

    private fun isNavNotification(sbn: StatusBarNotification, navPkg: String): Boolean {
        val n = sbn.notification
        val ongoing = (n.flags and Notification.FLAG_ONGOING_EVENT) != 0
        if (!ongoing) return false
        return n.category == "navigation" ||
            (navPkg.isNotEmpty() && sbn.packageName == navPkg) ||
            sbn.packageName in PlayerFilter.navApps
    }

    /**
     * Navigation apps show an ongoing notification while guiding. This looks
     * for one in the "navigation" category, or an ongoing one from the
     * navigation app the user picked in settings.
     */
    private fun navigationActive(prefs: android.content.SharedPreferences): Boolean {
        return try {
            val navPkg = prefs.getString("navPkg", "") ?: ""
            val list = activeNotifications ?: return false
            list.any { sbn -> isNavNotification(sbn, navPkg) }
        } catch (_: Exception) {
            false
        }
    }

    /** True while the navigation app shows its guidance notification. */
    fun navActiveNow(): Boolean = navigationNotificationActive()

    private var bubble: ReturnBubble? = null

    /** Shows the small "return to VYBE" button, if the Drive window exists. */
    fun showBubble() {
        main.post {
            if (!DriveActivity.alive) return@post
            if (bubble == null) bubble = ReturnBubble(this)
            bubble?.show()
        }
    }

    fun hideBubble() {
        main.post { bubble?.hide() }
    }

    private fun navigationNotificationActive(): Boolean {
        val prefs = getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE)
        return navigationActive(prefs)
    }

    private fun inCall(): Boolean {
        return try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.mode == AudioManager.MODE_IN_CALL ||
                am.mode == AudioManager.MODE_IN_COMMUNICATION ||
                am.mode == AudioManager.MODE_RINGTONE
        } catch (_: Exception) {
            false
        }
    }

    // -------------------------------------------------------- Drive overlay

    fun driveRunning(): Boolean = drive?.running == true

    fun startDrive() {
        val d = drive ?: return
        val prefs = getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE)
        navSeen = false
        main.removeCallbacks(autoClose)
        d.start(
            prefs.getBoolean("driveSwap", false),
            prefs.getFloat("driveCenter", 0.5f),
            prefs.getBoolean("driveControls", true),
        )
        d.setSuppressed(MainActivity.visible)
        pushOverlay()
        scanNavigation()
    }

    fun stopDrive() {
        main.removeCallbacks(autoClose)
        drive?.stop()
    }

    /** VYBE itself came on or off screen. The overlay steps aside for it. */
    fun vybeVisible(visible: Boolean) {
        drive?.setSuppressed(visible)
    }

    private fun pickController(): MediaController? {
        val prefs = getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE)
        fun isMusic(c: MediaController) =
            PlayerFilter.classify(this, c.packageName, c.metadata) == PlayerFilter.Kind.MUSIC ||
                PlayerFilter.modeOf(prefs, c.packageName) == "allow"
        fun isPlaying(c: MediaController) = c.playbackState?.state == PlaybackState.STATE_PLAYING
        val list = watches.map { it.c }
        return list.firstOrNull { isMusic(it) && isPlaying(it) }
            ?: list.firstOrNull { isMusic(it) }
            ?: list.firstOrNull { isPlaying(it) }
            ?: list.firstOrNull()
    }

    private fun pushOverlay() {
        val d = drive ?: return
        val c = pickController()
        if (c == null) {
            d.update("Nothing playing", "", null, false)
            return
        }
        val md = c.metadata
        val title = md?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""
        val artist = md?.getString(MediaMetadata.METADATA_KEY_ARTIST)
            ?: md?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: ""
        val key = keyOf(md)
        if (key != lastArtKey) {
            lastArtKey = key
            lastArt = MediaArt.bitmap(this, md)
        }
        d.update(
            if (title.isEmpty()) "Nothing playing" else title,
            artist,
            lastArt,
            c.playbackState?.state == PlaybackState.STATE_PLAYING,
        )
    }

    /** Reads the guidance notification that is already showing, if any. */
    private fun scanNavigation() {
        try {
            val prefs = getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE)
            val navPkg = prefs.getString("navPkg", "") ?: ""
            val list = activeNotifications ?: return
            val sbn = list.firstOrNull { isNavNotification(it, navPkg) }
            if (sbn != null) showDirections(sbn) else drive?.setDirections(null, null)
        } catch (_: Exception) {
        }
    }

    /**
     * The next turn comes from the text of the navigation app's own
     * notification. What it says depends on the app, so it is shown as is.
     */
    private fun showDirections(sbn: StatusBarNotification) {
        navSeen = true
        main.removeCallbacks(autoClose)
        val ex = sbn.notification.extras
        val title = ex?.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        val text = listOfNotNull(
            ex?.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
            ex?.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString(),
        ).filter { it.isNotBlank() }.joinToString("  ·  ")
        drive?.setDirections(title, text)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null || drive?.running != true) return
        val prefs = getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE)
        if (isNavNotification(sbn, prefs.getString("navPkg", "") ?: "")) showDirections(sbn)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        if (sbn == null || drive?.running != true) return
        val prefs = getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE)
        if (!isNavNotification(sbn, prefs.getString("navPkg", "") ?: "")) return
        if (navigationNotificationActive()) return
        drive?.setDirections(null, null)
        // Guidance ended. Close the overlay after a short wait, if asked to.
        if (navSeen && prefs.getBoolean("driveAutoClose", true)) {
            main.removeCallbacks(autoClose)
            main.postDelayed(autoClose, 20000L)
        }
    }

    companion object {
        /** The track counts as finished when this close to its end. */
        private const val END_WINDOW_MS = 4500L

        @Volatile
        var instance: MediaListenerService? = null
    }
}
