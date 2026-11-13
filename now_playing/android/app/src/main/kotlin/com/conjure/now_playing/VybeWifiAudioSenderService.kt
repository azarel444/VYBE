package com.conjure.now_playing

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.net.Socket

/**
 * EXPERIMENTAL, opt-in raw PCM sender over an existing trusted VYBE Connect
 * network. Captures only apps which Android explicitly allows to be captured.
 * No recording is saved. This is plaintext, local-network test code, NOT an
 * encrypted production transport. A separate TCP stream leaves VYBE Connect's
 * metadata/artwork protocol entirely untouched.
 */
class VybeWifiAudioSenderService : Service() {
    companion object {
        const val ACTION_STOP = "com.conjure.now_playing.WIFI_AUDIO_STOP_SENDER"
        const val PORT = 38928
        const val RATE = 44100
        const val PREFS = "vybe_wifi_audio_sender"
    }
    @Volatile private var running = false
    private var audio: AudioRecord? = null
    private var projection: MediaProjection? = null
    private var socket: Socket? = null
    private var targetIp = ""
    private var bytesSent = 0L
    private var peakSample = 0
    private var chunksSent = 0L
    private var lastMetricsAt = 0L
    private var reconnectAttempts = 0
    private var lastNetworkFailure = ""


    override fun onBind(intent: Intent?): IBinder? = null

    private fun status(state: String, detail: String) {
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("state", state)
            .putString("detail", detail)
            .putLong("updated", System.currentTimeMillis())
            .putString("targetIp", targetIp)
            .putLong("bytesSent", bytesSent)
            .putInt("peakSample", peakSample)
            .putLong("chunksSent", chunksSent)
            .putInt("reconnectAttempts", reconnectAttempts)
            .putString("lastFailure", lastNetworkFailure)
            .apply()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            running = false
            try { socket?.close() } catch (_: Exception) {}
            try { audio?.stop() } catch (_: Exception) {}
            try { projection?.stop() } catch (_: Exception) {}
            status("stopped", "Wi-Fi audio transmission stopped")
            stopSelf()
            return START_NOT_STICKY
        }
        if (running) return START_NOT_STICKY
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            status("unsupported", "Android 10 or newer is needed to capture another player's audio")
            stopSelf()
            return START_NOT_STICKY
        }
        val host = intent?.getStringExtra("host").orEmpty()
        if (host.isBlank()) {
            status("error", "No connected VYBE receiver address")
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            targetIp = host
            bytesSent = 0L
            peakSample = 0
            chunksSent = 0L
            reconnectAttempts = 0
            lastNetworkFailure = ""
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = "vybe_wifi_audio_sender"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(NotificationChannel(channel,
                    "VYBE Wi-Fi audio", NotificationManager.IMPORTANCE_LOW))
            }
            val notification = Notification.Builder(this, channel)
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentTitle("VYBE Wi-Fi audio")
                .setContentText("Streaming permitted music audio to your head unit")
                .setOngoing(true).build()
            startForeground(77232, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            @Suppress("DEPRECATION")
            val token = if (Build.VERSION.SDK_INT >= 33) {
                intent?.getParcelableExtra("projectionToken", Intent::class.java)
            } else intent?.getParcelableExtra<Intent>("projectionToken")
            val resultCode = intent?.getIntExtra("projectionResultCode", 0) ?: 0
            if (token == null || resultCode != Activity.RESULT_OK) {
                status("error", "MediaProjection consent missing")
                stopSelf()
                return START_NOT_STICKY
            }
            running = true
            status("connecting", "Connecting to VYBE audio receiver at $host")
            Thread({
                transmit(host, token, resultCode)
                stopSelf(startId)
            }, "VYBE-WiFiAudioSend").start()
        } catch (error: Exception) {
            running = false
            status("error", "Wi-Fi audio sender startup failed: ${error.message}")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun transmit(host: String, token: Intent, resultCode: Int) {
        var lastStatus = "stopped"
        var details = "Wi-Fi audio stream ended"
        try {
            val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                as MediaProjectionManager
            val p = manager.getMediaProjection(resultCode, token)
                ?: throw IllegalStateException("Android denied playback projection")
            projection = p
            p.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    running = false
                    try { socket?.close() } catch (_: Exception) {}
                }
            }, Handler(Looper.getMainLooper()))
            val captureConfig = AudioPlaybackCaptureConfiguration.Builder(p)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                .build()
            val minimum = AudioRecord.getMinBufferSize(
                RATE, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT)
            if (minimum <= 0) throw IllegalStateException("AudioRecord unsupported")
            val record = AudioRecord.Builder()
                .setAudioFormat(format)
                .setAudioPlaybackCaptureConfig(captureConfig)
                .setBufferSizeInBytes(maxOf(minimum * 2, 32768))
                .build()
            audio = record
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                throw IllegalStateException("Audio capture recorder initialization failed")
            }
            record.startRecording()
            val chunk = ByteArray(8192)
            // Retain the SAME user-approved MediaProjection and AudioRecord
            // across brief TCP failures. A new capture prompt is unnecessary
            // unless Android ends projection or the user stops the service.
            while (running) {
                var client: Socket? = null
                try {
                    status(if (reconnectAttempts == 0) "connecting" else "reconnecting",
                        "Opening Wi-Fi audio socket at $host:$PORT")
                    val connected = Socket()
                    client = connected
                    socket = connected
                    connected.tcpNoDelay = true
                    connected.keepAlive = true
                    connected.sendBufferSize = 131072
                    connected.connect(java.net.InetSocketAddress(host, PORT), 5000)
                    val stream = connected.getOutputStream()
                    stream.write("VYBEPCM1\n".toByteArray(Charsets.US_ASCII))
                    stream.flush()
                    reconnectAttempts = 0
                    lastNetworkFailure = ""
                    status("streaming", "Sending permitted audio over Wi-Fi")
                    while (running) {
                        val read = record.read(chunk, 0, chunk.size, AudioRecord.READ_BLOCKING)
                        if (read < 0) throw IllegalStateException("AudioRecord error $read")
                        if (read > 0) {
                            for (index in 0 until read - 1 step 2) {
                                val sample = (chunk[index].toInt() and 255) or
                                    (chunk[index + 1].toInt() shl 8)
                                val amplitude = kotlin.math.abs(sample.toShort().toInt())
                                if (amplitude > peakSample) peakSample = amplitude
                            }
                            stream.write(chunk, 0, read)
                            bytesSent += read
                            chunksSent++
                            val now = android.os.SystemClock.elapsedRealtime()
                            if (now - lastMetricsAt >= 1000) {
                                lastMetricsAt = now
                                status("streaming", if (peakSample > 256)
                                    "Sending audible PCM over Wi-Fi"
                                    else "Sending silent PCM; check source playback")
                            }
                        }
                    }
                } catch (error: Exception) {
                    if (!running) break
                    reconnectAttempts++
                    lastNetworkFailure = error.message ?: error.javaClass.simpleName
                    status("reconnecting",
                        "Audio socket dropped ($lastNetworkFailure); trying to reconnect")
                    // Back off, but allow unlimited retries while the user
                    // explicitly has Wi-Fi audio enabled. The receiver remains
                    // listening and does not require fresh permission.
                    try {
                        Thread.sleep(minOf(3000L, reconnectAttempts * 700L))
                    } catch (_: InterruptedException) {
                        break
                    }
                } finally {
                    try { client?.close() } catch (_: Exception) {}
                    if (socket === client) socket = null
                }
            }
            lastStatus = "stopped"
        } catch (error: Exception) {
            if (running) {
                lastStatus = "error"
                details = "Audio capture ended: ${error.message}"
            }
        } finally {
            running = false
            try { audio?.stop() } catch (_: Exception) {}
            try { audio?.release() } catch (_: Exception) {}
            audio = null
            try { socket?.close() } catch (_: Exception) {}
            socket = null
            try { projection?.stop() } catch (_: Exception) {}
            projection = null
            status(lastStatus, details)
        }
    }

    override fun onDestroy() {
        running = false
        try { socket?.close() } catch (_: Exception) {}
        try { audio?.stop() } catch (_: Exception) {}
        try { projection?.stop() } catch (_: Exception) {}
        super.onDestroy()
    }
}
