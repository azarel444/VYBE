package com.conjure.now_playing

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Protects the VYBE Connect process and the active Wi-Fi Direct connection
 * while another activity (Bluetooth Audio, Maps, home screen) is in front.
 *
 * This does NOT launch audio capture, play audio, pair devices, or create a
 * second Flutter engine. The existing VYBE Connect socket/discovery logic
 * remains in the main app. Foreground importance avoids normal background
 * process reclaim and the Wi-Fi lock prevents Wi-Fi sleep on supported radios.
 *
 * The service is started ONLY while the user has enabled VYBE Connect.
 * It stops immediately when Connect is switched off.
 */
class VybeLinkKeepAliveService : Service() {
    companion object {
        const val ACTION_START = "com.conjure.now_playing.LINK_KEEPALIVE_START"
        const val ACTION_STOP = "com.conjure.now_playing.LINK_KEEPALIVE_STOP"
        private const val CHANNEL_ID = "vybe_connect_background"
        private const val NOTIFICATION_ID = 7241

        @Volatile
        var isActive = false
            private set
    }

    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(NotificationChannel(
            CHANNEL_ID, "VYBE Connect background connection",
            NotificationManager.IMPORTANCE_LOW).apply {
            description = "Keeps the VYBE music-display connection running when switching apps"
            setShowBadge(false)
        })
    }

    private fun notification(): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_IMMUTABLE else 0)
        val pending = PendingIntent.getActivity(this, 0, openIntent, flags)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CHANNEL_ID)
        else Notification.Builder(this)
        return builder
            .setContentTitle("VYBE Connect active")
            .setContentText("Keeping music display connected while other apps are open")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pending)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            startForeground(NOTIFICATION_ID, notification())
            isActive = true
            if (wifiLock?.isHeld != true) {
                val manager = applicationContext.getSystemService(Context.WIFI_SERVICE)
                    as? WifiManager
                val lock = manager?.createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF, "vybe:link:background")
                lock?.setReferenceCounted(false)
                lock?.acquire()
                wifiLock = lock
            }
        } catch (error: Exception) {
            Log.w("VYBE", "Could not maintain background Wi-Fi Direct link", error)
            isActive = false
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isActive = false
        try { if (wifiLock?.isHeld == true) wifiLock?.release() }
        catch (error: Exception) { Log.w("VYBE", "Wi-Fi lock release failed", error) }
        wifiLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
