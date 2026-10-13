package com.conjure.now_playing

import android.content.Context
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import android.media.MediaMetadata
import android.os.Build

/**
 * Decides which apps count as music players. Only music players may open
 * VYBE by themselves; navigation and video apps need to be switched on.
 */
object PlayerFilter {

    enum class Kind { MUSIC, VIDEO, NAV, OTHER }

    const val PREFS = "np_prefs"

    val navApps = setOf(
        "com.google.android.apps.maps", "com.waze", "com.sygic.aura",
        "com.here.app.maps", "net.osmand", "net.osmand.plus",
        "com.tomtom.gplay.navapp", "com.mapfactor.navigator",
        "cz.seznam.mapy", "com.navigon.navigator_checkout",
        "app.organicmaps", "com.mapswithme.maps.pro", "ru.yandex.yandexnavi",
        "ru.yandex.yandexmaps", "com.garmin.android.apps.carnavigation",
        "com.telenav.app.android.scout_us", "com.mapbox.navigation"
    )

    private val videoApps = setOf(
        "com.google.android.youtube", "com.google.android.youtube.tv",
        "com.netflix.mediaclient", "com.amazon.avod.thirdpartyclient",
        "com.disney.disneyplus", "com.hulu.plus", "tv.twitch.android.app",
        "com.google.android.apps.youtube.kids", "com.google.android.videos",
        "com.plexapp.android", "com.vimeo.android.videoapp",
        "com.android.chrome", "org.mozilla.firefox", "com.brave.browser",
        "com.microsoft.emmx", "com.opera.browser"
    )

    fun classify(ctx: Context, pkg: String, md: MediaMetadata?): Kind {
        if (pkg in navApps) return Kind.NAV
        if (pkg in videoApps) return Kind.VIDEO
        if (Build.VERSION.SDK_INT >= 26) {
            try {
                when (ctx.packageManager.getApplicationInfo(pkg, 0).category) {
                    ApplicationInfo.CATEGORY_AUDIO -> return Kind.MUSIC
                    ApplicationInfo.CATEGORY_VIDEO -> return Kind.VIDEO
                    ApplicationInfo.CATEGORY_MAPS -> return Kind.NAV
                    else -> {}
                }
            } catch (_: Exception) {
            }
        }
        // The app does not say what it is. Music players almost always send
        // an artist or an album; videos and voice prompts do not.
        val hasMusicInfo = md != null && (
            !md.getString(MediaMetadata.METADATA_KEY_ARTIST).isNullOrEmpty() ||
                !md.getString(MediaMetadata.METADATA_KEY_ALBUM).isNullOrEmpty())
        return if (hasMusicInfo) Kind.MUSIC else Kind.OTHER
    }

    fun modeOf(prefs: SharedPreferences, pkg: String): String {
        if (prefs.getStringSet("block_pkgs", emptySet())?.contains(pkg) == true) return "block"
        if (prefs.getStringSet("allow_pkgs", emptySet())?.contains(pkg) == true) return "allow"
        return "auto"
    }

    fun allowed(prefs: SharedPreferences, pkg: String, kind: Kind): Boolean {
        when (modeOf(prefs, pkg)) {
            "block" -> return false
            "allow" -> return true
        }
        return when (kind) {
            Kind.MUSIC -> true
            Kind.VIDEO -> prefs.getBoolean("allowVideo", false)
            Kind.NAV -> prefs.getBoolean("allowNav", false)
            Kind.OTHER -> false
        }
    }

    fun setOverride(prefs: SharedPreferences, pkg: String, mode: String) {
        val allow = HashSet(prefs.getStringSet("allow_pkgs", emptySet()) ?: emptySet())
        val block = HashSet(prefs.getStringSet("block_pkgs", emptySet()) ?: emptySet())
        allow.remove(pkg)
        block.remove(pkg)
        if (mode == "allow") allow.add(pkg)
        if (mode == "block") block.add(pkg)
        prefs.edit().putStringSet("allow_pkgs", allow).putStringSet("block_pkgs", block).apply()
    }

    /** Remembers a player so the settings page can list it. */
    fun remember(ctx: Context, prefs: SharedPreferences, pkg: String, kind: Kind) {
        val label = try {
            val pm = ctx.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
        } catch (_: Exception) {
            pkg
        }
        val set = HashSet(prefs.getStringSet("seen_players", emptySet()) ?: emptySet())
        set.removeAll { it.startsWith("$pkg|") }
        set.add("$pkg|${kind.name}|$label")
        prefs.edit().putStringSet("seen_players", set).apply()
    }
}
