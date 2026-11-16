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
import java.net.DatagramSocket
import java.net.DatagramPacket
import java.net.InetAddress
import java.io.IOException
import java.security.SecureRandom
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * EXPERIMENTAL, opt-in AAC-LC 128 kbps over private RTP-style UDP packets
 * on the existing VYBE Wi-Fi Direct link. AAC is required for this test.
 * Captures only apps which Android explicitly allows to be captured.
 * No recording is saved. This is plaintext, local-network test code, NOT an
 * encrypted production transport. TCP metadata/artwork remains unchanged.
 * Each RTP-like datagram is independently playable; late data isn't resent.
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
    private var socket: DatagramSocket? = null
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
    private var udpDatagrams = 0L
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
            .putLong("udpDatagrams", udpDatagrams)
            .putString("transport", "RTP-style UDP / Wi-Fi Direct")
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
            udpDatagrams = 0L
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
            status("connecting", "Starting RTP-style UDP audio to $host:$PORT")
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
            // across brief UDP send failures. A new capture prompt is unnecessary
            // unless Android ends projection or the user stops the service.
            while (running) {
                var udp: DatagramSocket? = null
                var encoder: VybeAacEncoder? = null
                var networkWriter: Thread? = null
                try {
                    status(if (reconnectAttempts == 0) "connecting" else "reconnecting",
                        "Opening RTP-style UDP audio to $host:$PORT")
                    val destination = InetAddress.getByName(host)
                    val datagram = DatagramSocket()
                    udp = datagram
                    socket = datagram
                    datagram.connect(destination, PORT)
                    datagram.sendBufferSize = 65536
                    encoder = try { VybeAacEncoder() } catch (error: Exception) {
                        throw IllegalStateException(
                            "AAC encoder required for UDP test: ${error.message}", error)
                    }
                    val codec = encoder ?: throw IllegalStateException(
                        "AAC encoder unavailable")
                    activeAudioCodec = "AAC-LC 128 kbps stereo / UDP"
                    val outgoing = ArrayBlockingQueue<ByteArray>(48)
                    val writeFailure = AtomicReference<String?>(null)
                    val streamId = SecureRandom().nextInt()
                    var sequence = 0
                    var audioTime = 0L
                    lastSentAtMs = android.os.SystemClock.elapsedRealtime()
                    txQueueMs = 0
                    networkWriter = Thread({
                        try {
                            while (running && !Thread.currentThread().isInterrupted) {
                                val payload = outgoing.poll(350, TimeUnit.MILLISECONDS) ?: continue
                                datagram.send(DatagramPacket(payload, payload.size,
                                    destination, PORT))
                                bytesSent += payload.size
                                udpDatagrams++
                                lastSentAtMs = android.os.SystemClock.elapsedRealtime()
                                txQueueMs = outgoing.size * 1024 * 1000 / RATE
                            }
                        } catch (error: Exception) {
                            if (running) writeFailure.set(
                                error.message ?: error.javaClass.simpleName)
                            try { datagram.close() } catch (_: Exception) {}
                        }
                    }, "VYBE-RTP-UDP-AudioSend")
                    networkWriter.start()
                    reconnectAttempts = 0
                    status("streaming", "Sending RTP-style UDP AAC to head unit")

                    while (running) {
                        writeFailure.get()?.let { throw IOException("UDP audio: $it") }
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
                            codec.encode(chunk, read) { frame ->
                                val payload = VybeRtpAudio.encode(
                                    frame, sequence, audioTime, streamId)
                                sequence = (sequence + 1) and 0xffff
                                audioTime += 1024L
                                if (!outgoing.offer(payload)) {
                                    // Never accumulate old audio behind a
                                    // delayed radio transmission.
                                    outgoing.poll()
                                    txFramesDropped++
                                    outgoing.offer(payload)
                                }
                                framesEncoded++
                                lastEncodedAtMs = android.os.SystemClock.elapsedRealtime()
                            }
                            chunksSent++
                            txQueueMs = outgoing.size * 1024 * 1000 / RATE
                            val now = android.os.SystemClock.elapsedRealtime()
                            if (now - lastMetricsAt >= 750L) {
                                lastMetricsAt = now
                                val idle = now - lastSentAtMs
                                status("streaming", if (idle > 1500L)
                                    "UDP packets stalled for ${idle} ms; queue ${txQueueMs} ms"
                                    else if (peakSample > 256)
                                    "RTP-style UDP AAC streaming; queue ${txQueueMs} ms"
                                    else "UDP audio capture is silent")
                            }
                        }
                    }
                } catch (error: Exception) {
                    if (!running) break
                    reconnectAttempts++
                    totalSocketDrops++
                    lastNetworkFailure = error.message ?: error.javaClass.simpleName
                    status("reconnecting",
                        "UDP sender error ($lastNetworkFailure); retrying")
                    try { udp?.close() } catch (_: Exception) {}
                    try { Thread.sleep(minOf(3000L, reconnectAttempts * 700L)) }
                    catch (_: InterruptedException) { break }
                } finally {
                    try { udp?.close() } catch (_: Exception) {}
                    try { networkWriter?.join(900L) } catch (_: InterruptedException) {}
                    try { encoder?.close() } catch (_: Exception) {}
                    if (socket === udp) socket = null
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
