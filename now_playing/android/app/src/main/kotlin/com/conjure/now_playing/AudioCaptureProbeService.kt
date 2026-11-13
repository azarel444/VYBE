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
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import kotlin.math.sqrt

/**
 * A phone-side, short-lived compatibility experiment. It deliberately neither
 * stores nor sends audio, and never captures microphone input. Only aggregate
 * PCM amplitude statistics are written into private app preferences.
 *
 * A successful non-silent sample proves Android delivered capturable playback
 * audio. Silence does NOT prove the music app always forbids capture: it may
 * be paused, muted, playing in another user profile, or using another route.
 */
class AudioCaptureProbeService : Service() {
    private val channelId = "vybe_audio_capture_probe"
    private val prefName = "vybe_audio_capture_probe"
    private val notificationId = 77231
    private val sampleRate = 44100
    private val durationMs = 25000L
    @Volatile private var running = false
    private var projection: MediaProjection? = null
    private var recorder: AudioRecord? = null

    override fun onBind(intent: Intent?): IBinder? = null

    private fun publish(state: String, details: String,
                        peak: Int = 0, rms: Float = 0f,
                        fraction: Float = 0f, samples: Long = 0L) {
        getSharedPreferences(prefName, Context.MODE_PRIVATE).edit()
            .putString("state", state)
            .putString("details", details)
            .putInt("peak", peak)
            .putFloat("rms", rms)
            .putFloat("signalFraction", fraction)
            .putLong("samples", samples)
            .putLong("updatedAt", System.currentTimeMillis())
            .apply()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (running) return START_NOT_STICKY
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || intent == null) {
            publish("unavailable", "Android 10 or newer is required for audio playback capture.")
            stopSelf(startId)
            return START_NOT_STICKY
        }
        try {
            val notificationManager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                notificationManager.createNotificationChannel(
                    NotificationChannel(channelId, "VYBE audio compatibility test",
                        NotificationManager.IMPORTANCE_LOW))
            }
            val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, channelId)
            } else Notification.Builder(this)
            val notificationBuilt = notification
                .setContentTitle("VYBE testing music capture")
                .setContentText("Measuring playback audio for 25 seconds; no audio saved")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setOngoing(true)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(notificationId, notificationBuilt,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            } else startForeground(notificationId, notificationBuilt)
            @Suppress("DEPRECATION")
            val token = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra("projectionToken", Intent::class.java)
            } else intent.getParcelableExtra<Intent>("projectionToken")
            val resultCode = intent.getIntExtra("projectionResultCode", 0)
            if (token == null || resultCode != android.app.Activity.RESULT_OK) {
                publish("error", "Android did not provide a playback-capture authorization.")
                stopSelf(startId)
                return START_NOT_STICKY
            }
            running = true
            publish("capturing", "Music capture test active. Play music in your selected app.")
            Thread({
                executeCapture(resultCode, token)
                stopSelf(startId)
            }, "VYBE-AudioProbe").start()
        } catch (error: Exception) {
            running = false
            publish("error", "Audio capture service failed: ${error.message}")
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    private fun executeCapture(resultCode: Int, token: Intent) {
        try {
            val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                as MediaProjectionManager
            val mediaProjection = manager.getMediaProjection(resultCode, token)
                ?: throw IllegalStateException("Android denied playback projection")
            projection = mediaProjection
            mediaProjection.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() { running = false }
            }, Handler(Looper.getMainLooper()))

            val config = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(sampleRate)
                .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                .build()
            val minimum = AudioRecord.getMinBufferSize(
                sampleRate, AudioFormat.CHANNEL_IN_STEREO,
                AudioFormat.ENCODING_PCM_16BIT)
            val bytes = if (minimum > 0) maxOf(minimum * 2, 16384) else 32768
            val audioRecord = AudioRecord.Builder()
                .setAudioFormat(format)
                .setBufferSizeInBytes(bytes)
                .setAudioPlaybackCaptureConfig(config)
                .build()
            recorder = audioRecord
            if (audioRecord.state != AudioRecord.STATE_INITIALIZED) {
                throw IllegalStateException("Android could not initialize the playback-capture recorder")
            }
            audioRecord.startRecording()
            val data = ShortArray(4096)
            var total = 0L
            var aboveThreshold = 0L
            var peak = 0
            var sumSquares = 0.0
            val endAt = SystemClock.elapsedRealtime() + durationMs
            while (running && SystemClock.elapsedRealtime() < endAt) {
                val count = audioRecord.read(data, 0, data.size, AudioRecord.READ_BLOCKING)
                if (count < 0) throw IllegalStateException(
                    "AudioRecord returned error $count")
                for (index in 0 until count) {
                    val absolute = kotlin.math.abs(data[index].toInt())
                    if (absolute > peak) peak = absolute
                    if (absolute > 128) aboveThreshold++
                    sumSquares += absolute.toDouble() * absolute
                }
                total += count
            }
            val rms = if (total > 0) sqrt(sumSquares / total).toFloat() else 0f
            val fraction = if (total > 0) (aboveThreshold.toDouble() / total).toFloat() else 0f
            val signal = total > 4096 && peak > 256 && aboveThreshold > 2048
            val state = if (signal) "captured" else "silent"
            val message = if (signal)
                "Captured a real audio signal. Wi-Fi transfer is technically possible for this playback session."
            else "No meaningful signal captured. The player may block capture, or playback may have been silent, paused or routed differently."
            publish(state, message, peak, rms, fraction, total)
        } catch (error: Exception) {
            publish("error", "Playback capture failed: ${error.message}")
        } finally {
            running = false
            try { recorder?.stop() } catch (_: Exception) {}
            try { recorder?.release() } catch (_: Exception) {}
            recorder = null
            try { projection?.stop() } catch (_: Exception) {}
            projection = null
        }
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }
}
