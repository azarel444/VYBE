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
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.net.InetSocketAddress
import java.io.DataInputStream
import java.io.EOFException
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

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
    private var expectedPeerIp: String = ""
    private var observedPeerIp: String = ""
    private var bytesReceived = 0L
    private var bytesPlayed = 0L
    private var loudestSample = 0
    private var audioRoute = "Unknown"
    private var connectedClients = 0
    private var rejectedClients = 0
    private var lastMetricsAt = 0L
    private var bufferUnderruns = 0
    private var droppedPackets = 0
    private var androidUnderruns = 0
    private var bufferedMs = 0
    private var lastFailure = ""


    override fun onBind(intent: Intent?): IBinder? = null

    private fun status(state: String, detail: String) {
        val mixer = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("state", state)
            .putString("detail", detail)
            .putLong("updated", System.currentTimeMillis())
            .putString("expectedIp", expectedPeerIp)
            .putString("observedIp", observedPeerIp)
            .putLong("bytesReceived", bytesReceived)
            .putLong("bytesPlayed", bytesPlayed)
            .putInt("peakSample", loudestSample)
            .putInt("connections", connectedClients)
            .putInt("rejected", rejectedClients)
            .putString("route", audioRoute)
            .putInt("bufferUnderruns", bufferUnderruns)
            .putInt("droppedPackets", droppedPackets)
            .putInt("androidUnderruns", androidUnderruns)
            .putInt("bufferedMs", bufferedMs)
            .putString("lastFailure", lastFailure)
            .putInt("streamVolume", mixer.getStreamVolume(AudioManager.STREAM_MUSIC))
            .putInt("streamMaxVolume", mixer.getStreamMaxVolume(AudioManager.STREAM_MUSIC))
            .putBoolean("musicActive", mixer.isMusicActive)
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
            expectedPeerIp = allowedIp
            observedPeerIp = ""
            bytesReceived = 0L
            bytesPlayed = 0L
            loudestSample = 0
            connectedClients = 0
            rejectedClients = 0
            audioRoute = "Not yet opened"
            bufferUnderruns = 0
            droppedPackets = 0
            androidUnderruns = 0
            bufferedMs = 0
            lastFailure = ""
            lastMetricsAt = 0L
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

    /**
     * Network reads and audio output MUST use different threads.
     *
     * Previously each blocking AudioTrack.write() delayed Socket.read().
     * On a weak Wi-Fi radio that causes avoidable backpressure and glitches.
     * A 12-second socket read timeout also used to terminate otherwise valid
     * sessions during a radio stall. Only the initial header has a timeout.
     *
     * 44.1 kHz / 2 channels / 16-bit: each 8192-byte packet is ~46 ms.
     * Pre-buffer ~0.55 seconds and retain at most ~3 seconds of packets.
     * Drop oldest packets when a slow device falls behind live music.
     */
    private fun receive(allowedIp: String) {
        try {
            val server = ServerSocket()
            server.reuseAddress = true
            server.bind(InetSocketAddress(PORT))
            listener = server
            while (running) {
                val client: Socket = try { server.accept() }
                    catch (error: SocketException) {
                        if (!running) break else throw error
                    }
                peer = client
                var writer: Thread? = null
                val readerEnded = AtomicBoolean(false)
                val writerError = AtomicReference<String?>(null)
                try {
                    observedPeerIp = client.inetAddress.hostAddress ?: "unknown"
                    connectedClients++
                    if (observedPeerIp != allowedIp) {
                        rejectedClients++
                        lastFailure = "Unpaired audio IP: $observedPeerIp"
                        status("rejected", "Audio IP mismatch: $observedPeerIp")
                        continue
                    }
                    status("connected", "Audio TCP accepted from $observedPeerIp")
                    client.tcpNoDelay = true
                    client.keepAlive = true
                    client.receiveBufferSize = 262144
                    client.soTimeout = 10000 // Handshake only.
                    val input = DataInputStream(client.getInputStream())
                    val expected = "VYBEPCM1\n".toByteArray(Charsets.US_ASCII)
                    val header = ByteArray(expected.size)
                    input.readFully(header)
                    if (!header.contentEquals(expected)) {
                        lastFailure = "Invalid audio stream header"
                        status("rejected", lastFailure)
                        continue
                    }
                    // A temporary Wi-Fi stall is NOT an audio session failure.
                    client.soTimeout = 0

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
                        .setBufferSizeInBytes(maxOf(minimum * 4, 65536))
                        .setTransferMode(AudioTrack.MODE_STREAM)
                        .build()
                    track = player
                    if (player.state != AudioTrack.STATE_INITIALIZED)
                        throw IllegalStateException("Android cannot initialize stereo PCM output")
                    // The queue holds complete stereo PCM frames: no partial
                    // TCP reads can split a sample across an AudioTrack write.
                    val packetBytes = 8192
                    val prebufferPackets = 12  // 557 ms, tolerates short dips.
                    val queue = ArrayBlockingQueue<ByteArray>(64)
                    status("buffering", "Connected; buffering music before playback")

                    writer = Thread({
                        try {
                            var started = false
                            while (running && !Thread.currentThread().isInterrupted) {
                                if (!started) {
                                    if (queue.size < prebufferPackets && !readerEnded.get()) {
                                        Thread.sleep(20)
                                        continue
                                    }
                                    if (queue.isEmpty() && readerEnded.get()) break
                                    player.play()
                                    started = true
                                }
                                val packet = queue.poll(200, TimeUnit.MILLISECONDS)
                                if (packet == null) {
                                    if (readerEnded.get()) break
                                    bufferUnderruns++
                                    // Pause during an actual drop instead of
                                    // accumulating long playback delay.
                                    player.pause()
                                    player.flush()
                                    started = false
                                    status("buffering", "Radio/audio data stalled; refilling 550 ms buffer")
                                    continue
                                }
                                var offset = 0
                                while (offset < packet.size && running) {
                                    val written = player.write(packet, offset,
                                        packet.size - offset, AudioTrack.WRITE_BLOCKING)
                                    if (written <= 0) {
                                        throw IllegalStateException("Android audio output write failed ($written)")
                                    }
                                    offset += written
                                    bytesPlayed += written
                                }
                                bufferedMs = (queue.size * packetBytes * 1000) / (RATE * 4)
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                                    androidUnderruns = player.underrunCount
                                }
                                val now = android.os.SystemClock.elapsedRealtime()
                                if (now - lastMetricsAt > 1000) {
                                    lastMetricsAt = now
                                    audioRoute = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                                        player.routedDevice?.productName?.toString()
                                            ?: "Android default output"
                                    else "Android default output"
                                    status("playing", if (loudestSample > 256)
                                        "PCM playing with ~${bufferedMs} ms buffered"
                                    else "PCM received but no audible signal detected")
                                }
                            }
                        } catch (error: Exception) {
                            if (running && !readerEnded.get()) {
                                writerError.set(error.message ?: error.javaClass.simpleName)
                                try { client.close() } catch (_: Exception) {}
                            }
                        }
                    }, "VYBE-WiFiAudioOutput")
                    writer.start()

                    try {
                        while (running) {
                            val packet = ByteArray(packetBytes)
                            // readFully reassembles packets from any number of
                            // TCP reads, including partial frames.
                            input.readFully(packet)
                            bytesReceived += packet.size
                            for (index in packet.indices step 2) {
                                val sample = (packet[index].toInt() and 255) or
                                    (packet[index + 1].toInt() shl 8)
                                val amplitude = kotlin.math.abs(sample.toShort().toInt())
                                if (amplitude > loudestSample) loudestSample = amplitude
                            }
                            if (!queue.offer(packet)) {
                                // A slower-than-realtime head unit should
                                // skip stale music rather than build latency.
                                queue.poll()
                                droppedPackets++
                                queue.offer(packet)
                            }
                            bufferedMs = (queue.size * packetBytes * 1000) / (RATE * 4)
                        }
                    } catch (error: EOFException) {
                        if (running) lastFailure = "Phone ended PCM connection"
                    } catch (error: Exception) {
                        if (running) lastFailure =
                            writerError.get() ?: "PCM network read: ${error.message}"
                    } finally {
                        readerEnded.set(true)
                    }
                    writer.join(2500)
                    if (writer.isAlive) writer.interrupt()
                    val failed = writerError.get()
                    if (failed != null && running) {
                        lastFailure = "Audio output: $failed"
                        status("interrupted", lastFailure)
                    } else if (lastFailure.isNotEmpty() && running) {
                        status("interrupted", lastFailure)
                    }
                } catch (error: Exception) {
                    if (running) {
                        lastFailure = "Audio receiver: ${error.message}"
                        status("interrupted", lastFailure)
                    }
                } finally {
                    readerEnded.set(true)
                    try { client.close() } catch (_: Exception) {}
                    if (writer?.isAlive == true) {
                        writer.interrupt()
                        try { writer.join(800) } catch (_: Exception) {}
                    }
                    try { track?.pause() } catch (_: Exception) {}
                    try { track?.flush() } catch (_: Exception) {}
                    try { track?.release() } catch (_: Exception) {}
                    track = null
                    peer = null
                    if (running) status("listening", "Waiting for phone audio. Last failure: ${if (lastFailure.isEmpty()) "none" else lastFailure}")
                }
            }
        } catch (error: Exception) {
            if (running) {
                lastFailure = "Receiver socket: ${error.message}"
                status("error", lastFailure)
            }
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
