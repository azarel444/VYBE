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
import java.io.DataOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * EXPERIMENTAL, opt-in AAC-LC 128 kbps sender over an existing trusted
 * VYBE Connect network, with a legacy PCM fallback when AAC is unavailable.
 * Captures only apps which Android explicitly allows to be captured.
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
    @Volatile private var bytesSent = 0L
    private var peakSample = 0
    private var chunksSent = 0L
    private var lastMetricsAt = 0L
    private var reconnectAttempts = 0
    private var totalSocketDrops = 0
    private var lastNetworkFailure = ""
    @Volatile private var stopReason = ""
    private var activeAudioCodec = "Not started"
    private var framesEncoded = 0L
    @Volatile private var txQueueMs = 0
    @Volatile private var txFramesDropped = 0L
    @Volatile private var lastCaptureAtMs = 0L
    @Volatile private var lastEncodedAtMs = 0L
    @Volatile private var lastSentAtMs = 0L


    override fun onBind(intent: Intent?): IBinder? = null

    private fun status(state: String, detail: String) {
        val now = android.os.SystemClock.elapsedRealtime()
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("state", state)
            .putString("detail", detail)
            .putLong("updated", System.currentTimeMillis())
            .putString("targetIp", targetIp)
            .putLong("bytesSent", bytesSent)
            .putInt("peakSample", peakSample)
            .putLong("chunksSent", chunksSent)
            .putInt("reconnectAttempts", totalSocketDrops)
            .putString("lastFailure", lastNetworkFailure)
            .putString("codec", activeAudioCodec)
            .putLong("framesEncoded", framesEncoded)
            .putInt("sendQueueMs", txQueueMs)
            .putLong("sendFramesDropped", txFramesDropped)
            .putLong("captureIdleMs", if (lastCaptureAtMs == 0L) 0L else now - lastCaptureAtMs)
            .putLong("encoderIdleMs", if (lastEncodedAtMs == 0L) 0L else now - lastEncodedAtMs)
            .putLong("networkIdleMs", if (lastSentAtMs == 0L) 0L else now - lastSentAtMs)
            .apply()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopReason = "Wi-Fi audio stopped by VYBE"
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
            totalSocketDrops = 0
            lastNetworkFailure = ""
            stopReason = ""
            activeAudioCodec = "Not started"
            framesEncoded = 0L
            txQueueMs = 0
            txFramesDropped = 0L
            lastCaptureAtMs = 0L
            lastEncodedAtMs = 0L
            lastSentAtMs = 0L
            lastMetricsAt = 0L
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
                    if (running) {
                        stopReason = "Android ended playback capture permission"
                    }
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
                var encoder: VybeAacEncoder? = null
                var networkWriter: Thread? = null
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
                    val stream = DataOutputStream(
                        java.io.BufferedOutputStream(connected.getOutputStream(), 16384))
                    encoder = try { VybeAacEncoder() } catch (_: Exception) { null }
                    activeAudioCodec = if (encoder != null)
                        "AAC-LC 128 kbps stereo" else "PCM stereo (AAC unavailable)"
                    stream.write(if (encoder != null) VybeAacFormat.HEADER
                        else "VYBEPCM1\n".toByteArray(Charsets.US_ASCII))
                    stream.flush()

                    // Capture/encoding must never wait for a slow Wi-Fi Direct
                    // write. The dedicated writer handles network backpressure
                    // while this thread keeps reading live phone audio.
                    // 128 AAC frames represent ~3 seconds; once full, discard
                    // stale frames so the stream catches up with live music.
                    val outgoing = ArrayBlockingQueue<ByteArray>(128)
                    val writeFailure = AtomicReference<String?>(null)
                    val frameMs = if (encoder != null) 1024 * 1000 / RATE else 46
                    lastSentAtMs = android.os.SystemClock.elapsedRealtime()
                    txQueueMs = 0
                    networkWriter = Thread({
                        try {
                            while (running && !Thread.currentThread().isInterrupted) {
                                val packet = outgoing.poll(350, TimeUnit.MILLISECONDS) ?: continue
                                stream.write(packet)
                                var writtenBytes = packet.size
                                // Flush a batch together to minimize small
                                // TCP writes without delaying the first packet.
                                while (true) {
                                    val next = outgoing.poll() ?: break
                                    stream.write(next)
                                    writtenBytes += next.size
                                }
                                stream.flush()
                                bytesSent += writtenBytes
                                lastSentAtMs = android.os.SystemClock.elapsedRealtime()
                                txQueueMs = outgoing.size * frameMs
                            }
                        } catch (error: Exception) {
                            if (running) writeFailure.set(
                                error.message ?: error.javaClass.simpleName)
                            try { connected.close() } catch (_: Exception) {}
                        }
                    }, "VYBE-AAC-NetworkWriter")
                    networkWriter.start()
                    reconnectAttempts = 0
                    status("streaming", "Sending $activeAudioCodec to head unit")

                    while (running) {
                        writeFailure.get()?.let { throw IOException("Audio network write: $it") }
                        val read = record.read(chunk, 0, chunk.size, AudioRecord.READ_BLOCKING)
                        if (read < 0) throw IllegalStateException("AudioRecord error $read")
                        if (read > 0) {
                            lastCaptureAtMs = android.os.SystemClock.elapsedRealtime()
                            for (index in 0 until read - 1 step 2) {
                                val sample = (chunk[index].toInt() and 255) or
                                    (chunk[index + 1].toInt() shl 8)
                                val amplitude = kotlin.math.abs(sample.toShort().toInt())
                                if (amplitude > peakSample) peakSample = amplitude
                            }
                            val codec = encoder
                            if (codec != null) {
                                codec.encode(chunk, read) { frame ->
                                    if (frame.size > 65536)
                                        throw IllegalStateException("Oversized AAC access unit")
                                    val packet = ByteBuffer.allocate(frame.size + 4)
                                        .putInt(frame.size).put(frame).array()
                                    if (!outgoing.offer(packet)) {
                                        // Network writes can temporarily block
                                        // without freezing MediaProjection.
                                        // Discard only stale queued audio.
                                        outgoing.poll()
                                        txFramesDropped++
                                        outgoing.offer(packet)
                                    }
                                    framesEncoded++
                                    lastEncodedAtMs = android.os.SystemClock.elapsedRealtime()
                                }
                            } else {
                                val packet = chunk.copyOf(read)
                                if (!outgoing.offer(packet)) {
                                    outgoing.poll()
                                    txFramesDropped++
                                    outgoing.offer(packet)
                                }
                                lastEncodedAtMs = android.os.SystemClock.elapsedRealtime()
                            }
                            chunksSent++
                            txQueueMs = outgoing.size * frameMs
                            val now = android.os.SystemClock.elapsedRealtime()
                            if (now - lastMetricsAt >= 750L) {
                                lastMetricsAt = now
                                val networkIdle = now - lastSentAtMs
                                status("streaming", if (networkIdle > 1500L)
                                    "Audio capture active; network stalled for ${networkIdle} ms (queued ~${txQueueMs} ms)"
                                    else if (peakSample > 256)
                                    "Streaming $activeAudioCodec; queued ~${txQueueMs} ms"
                                    else "Streaming $activeAudioCodec; capture is silent")
                            }
                        }
                    }
                    writeFailure.get()?.let { throw IOException("Audio network write: $it") }
                } catch (error: Exception) {
                    if (!running) break
                    reconnectAttempts++
                    totalSocketDrops++
                    lastNetworkFailure = error.message ?: error.javaClass.simpleName
                    status("reconnecting",
                        "Audio socket dropped ($lastNetworkFailure); trying to reconnect")
                    // Release the stale TCP writer before backoff, not after
                    // sleeping; otherwise its output can remain blocked and
                    // delay a healthy new stream.
                    try { client?.close() } catch (_: Exception) {}
                    try {
                        Thread.sleep(minOf(3000L, reconnectAttempts * 700L))
                    } catch (_: InterruptedException) {
                        break
                    }
                } finally {
                    try { client?.close() } catch (_: Exception) {}
                    try { networkWriter?.join(900L) } catch (_: InterruptedException) {}
                    try { encoder?.close() } catch (_: Exception) {}
                    if (socket === client) socket = null
                    txQueueMs = 0
                }
            }
            lastStatus = if (stopReason.startsWith("Android"))
                "capture-ended" else "stopped"
            details = if (stopReason.isNotEmpty())
                stopReason else "Wi-Fi audio stream ended"
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
