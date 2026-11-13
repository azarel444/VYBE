package com.conjure.now_playing

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import android.os.IBinder
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException

/**
 * EXPERIMENTAL, manually started head-unit PCM receiver. Uses a separate TCP
 * port; the existing VYBE Connect metadata socket is not changed.
 *
 * Only accepts the sender IP of the currently connected VYBE Connect peer.
 * The audio is unencrypted, so do not enable on an untrusted shared network.
 * It plays standard AudioTrack media and requires no manufacturer app.
 */
class VybeWifiAudioReceiverService : Service() {
    companion object {
        const val ACTION_STOP = "com.conjure.now_playing.WIFI_AUDIO_STOP_RECEIVER"
        const val PREFS = "vybe_wifi_audio_receiver"
        const val PORT = 38928
        const val RATE = 44100
    }

    @Volatile private var running = false
    private var listener: ServerSocket? = null
    private var peer: Socket? = null
    private var track: AudioTrack? = null

    override fun onBind(intent: Intent?): IBinder? = null

    private fun status(state: String, detail: String) {
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("state", state)
            .putString("detail", detail)
            .putLong("updated", System.currentTimeMillis())
            .apply()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            shutdown()
            status("stopped", "Head-unit Wi-Fi audio receiver stopped")
            stopSelf()
            return START_NOT_STICKY
        }
        if (running) return START_NOT_STICKY
        val allowedIp = intent?.getStringExtra("allowedIp").orEmpty()
        if (allowedIp.isBlank()) {
            status("error", "No connected phone in VYBE Connect")
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            val channel = "vybe_wifi_audio_receiver"
            val notifications =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                notifications.createNotificationChannel(NotificationChannel(
                    channel, "VYBE Wi-Fi audio receiver", NotificationManager.IMPORTANCE_LOW))
            }
            @Suppress("DEPRECATION")
            val n = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                Notification.Builder(this, channel) else Notification.Builder(this)
            val notification = n.setSmallIcon(android.R.drawable.ic_media_play)
                .setContentTitle("VYBE Wi-Fi audio receiver")
                .setContentText("Waiting for audio from your connected phone")
                .setOngoing(true).build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(77233, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else startForeground(77233, notification)
            running = true
            status("listening", "Waiting for VYBE phone audio on TCP $PORT")
            Thread({
                receive(allowedIp)
                stopSelf(startId)
            }, "VYBE-WiFiAudioReceive").start()
        } catch (error: Exception) {
            status("error", "Could not start audio receiver: ${error.message}")
            shutdown()
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun receive(allowedIp: String) {
        try {
            val server = ServerSocket(PORT)
            listener = server
            // Keep listening after a sender disconnect. Never allow another
            // LAN device's audio to override the paired phone.
            while (running) {
                val client: Socket = try { server.accept() }
                    catch (error: SocketException) {
                        if (!running) break else throw error
                    }
                peer = client
                try {
                    if (client.inetAddress.hostAddress != allowedIp) {
                        status("rejected", "Audio attempt from an unpaired network device")
                        continue
                    }
                    client.tcpNoDelay = true
                    client.receiveBufferSize = 131072
                    client.soTimeout = 12000
                    val input = client.getInputStream()
                    val expected = "VYBEPCM1\n".toByteArray(Charsets.US_ASCII)
                    var valid = true
                    for (byte in expected) {
                        if (input.read() != byte.toInt()) { valid = false; break }
                    }
                    if (!valid) {
                        status("rejected", "Unrecognized VYBE audio stream")
                        continue
                    }
                    val minimum = AudioTrack.getMinBufferSize(RATE,
                        AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
                    if (minimum <= 0) throw IllegalStateException("PCM output unsupported")
                    val player = AudioTrack.Builder()
                        .setAudioAttributes(AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                        .setAudioFormat(AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(RATE)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
                        .setBufferSizeInBytes(maxOf(minimum * 2, 32768))
                        .setTransferMode(AudioTrack.MODE_STREAM)
                        .build()
                    track = player
                    if (player.state != AudioTrack.STATE_INITIALIZED)
                        throw IllegalStateException("Head unit cannot initialize PCM output")
                    player.play()
                    status("playing", "Playing Wi-Fi audio from the paired phone (44.1 kHz stereo PCM)")
                    val chunk = ByteArray(8192)
                    while (running) {
                        val count = input.read(chunk)
                        if (count < 0) break
                        var offset = 0
                        while (offset < count && running) {
                            val written = player.write(chunk, offset, count - offset)
                            if (written < 0) throw IllegalStateException("AudioTrack error $written")
                            if (written == 0) break
                            offset += written
                        }
                    }
                } catch (error: Exception) {
                    if (running) status("interrupted", "Audio interrupted: ${error.message}")
                } finally {
                    try { track?.pause() } catch (_: Exception) {}
                    try { track?.flush() } catch (_: Exception) {}
                    try { track?.release() } catch (_: Exception) {}
                    track = null
                    try { client.close() } catch (_: Exception) {}
                    peer = null
                    if (running) status("listening", "Waiting for phone to reconnect audio")
                }
            }
        } catch (error: Exception) {
            if (running) status("error", "Wi-Fi audio receiver failed: ${error.message}")
        } finally {
            shutdown()
        }
    }

    private fun shutdown() {
        running = false
        try { listener?.close() } catch (_: Exception) {}
        listener = null
        try { peer?.close() } catch (_: Exception) {}
        peer = null
        try { track?.stop() } catch (_: Exception) {}
        try { track?.release() } catch (_: Exception) {}
        track = null
    }

    override fun onDestroy() {
        shutdown()
        super.onDestroy()
    }
}
