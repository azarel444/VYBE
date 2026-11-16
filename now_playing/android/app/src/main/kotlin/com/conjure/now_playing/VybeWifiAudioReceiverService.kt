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
import java.net.DatagramSocket
import java.net.DatagramPacket
import java.net.SocketException
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.util.TreeMap
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit


/**
 * EXPERIMENTAL, opt-in RTP-style AAC receiver over UDP on the existing
 * Wi-Fi Direct network. Artwork/metadata continue on the original TCP link.
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
    private var listener: DatagramSocket? = null
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
    private var audioCodec = "Not connected"
    @Volatile private var lastAacPacketAtMs = 0L
    private var rtpMissingPackets = 0
    private var rtpLatePackets = 0
    private var rtpReorderedPackets = 0
    private var rtpStreamRestarts = 0
    private var latestRtpTimestamp = 0L


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
            .putString("codec", audioCodec)
            .putLong("lastAacPacketAtMs", lastAacPacketAtMs)
            .putInt("rtpMissingPackets", rtpMissingPackets)
            .putInt("rtpLatePackets", rtpLatePackets)
            .putInt("rtpReorderedPackets", rtpReorderedPackets)
            .putInt("rtpStreamRestarts", rtpStreamRestarts)
            .putLong("rtpTimestamp", latestRtpTimestamp)
            .putString("transport", "RTP-style UDP / Wi-Fi Direct")
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
            audioCodec = "Not connected"
            lastAacPacketAtMs = 0L
            rtpMissingPackets = 0
            rtpLatePackets = 0
            rtpReorderedPackets = 0
            rtpStreamRestarts = 0
            latestRtpTimestamp = 0L
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
            status("listening", "Waiting for VYBE RTP-style UDP audio on port $PORT")
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
     * Experimental low-latency UDP/RTP-style AAC playback.
     *
     * Network reception is independent of AudioTrack writes. Packets carry
     * an RTP-v2 sequence number, 44.1-kHz capture timestamp and stream ID.
     * We reorder a few packets briefly, then skip permanently late frames.
     * No TCP retransmission or large buffered backlog is involved.
     */
    private fun receive(allowedIp: String) {
        val udp = DatagramSocket(null)
        val incoming = ArrayBlockingQueue<VybeRtpAudio.Packet>(96)
        val readerFinished = java.util.concurrent.atomic.AtomicBoolean(false)
        val decoderFailure = java.util.concurrent.atomic.AtomicReference<String?>(null)
        var decoderThread: Thread? = null
        try {
            udp.reuseAddress = true
            udp.bind(InetSocketAddress(PORT))
            udp.soTimeout = 1000 // Poll stop flag; never use as an audio disconnect.
            udp.receiveBufferSize = 131072
            listener = udp
            status("listening", "UDP receiver ready on $PORT; waiting for AAC packets")
            decoderThread = Thread({
                var decoder: VybeAacDecoder? = null
                var player: AudioTrack? = null
                var started = false
                var primedBytes = 0
                var streamId: Int? = null
                var expected: Int? = null
                var firstBufferedAt = 0L
                var gapAt = 0L
                var underrunNotedAt = 0L
                val reorder = TreeMap<Int, VybeRtpAudio.Packet>()
                try {
                    val minBuffer = AudioTrack.getMinBufferSize(RATE,
                        AudioFormat.CHANNEL_OUT_STEREO,
                        AudioFormat.ENCODING_PCM_16BIT)
                    if (minBuffer <= 0) throw IllegalStateException(
                        "AAC PCM output unsupported")
                    val output = AudioTrack.Builder()
                        .setAudioAttributes(AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build())
                        .setAudioFormat(AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(RATE)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                            .build())
                        .setBufferSizeInBytes(maxOf(minBuffer * 4, 131072))
                        .setTransferMode(AudioTrack.MODE_STREAM)
                        .build()
                    if (output.state != AudioTrack.STATE_INITIALIZED)
                        throw IllegalStateException("Cannot initialize AAC speaker output")
                    player = output
                    track = output
                    decoder = VybeAacDecoder()
                    // Keep the proven #676 decoder+speaker output path.
                    // Do not add the extra decoded-PCM worker that regressed #677.
                    while (running && !Thread.currentThread().isInterrupted) {
                        val next = incoming.poll(12L, TimeUnit.MILLISECONDS)
                        val now = android.os.SystemClock.elapsedRealtime()
                        if (next != null) {
                            if (streamId != next.streamId) {
                                if (streamId != null) {
                                    rtpStreamRestarts++
                                    try { decoder?.close() } catch (_: Exception) {}
                                    decoder = VybeAacDecoder()
                                    if (started) {
                                        try { output.pause(); output.flush() }
                                        catch (_: Exception) {}
                                    }
                                    started = false
                                    primedBytes = 0
                                }
                                streamId = next.streamId
                                expected = null
                                firstBufferedAt = now
                                gapAt = 0L
                                reorder.clear()
                                audioCodec = "AAC-LC 128 kbps / RTP-style UDP"
                                status("buffering", "New RTP audio stream; syncing timestamps")
                            }
                            val seq = if (expected == null) next.sequence
                                else VybeRtpAudio.unwrap(next.sequence, expected!!)
                            if (expected != null && seq < expected!!) {
                                rtpLatePackets++
                            } else if (!reorder.containsKey(seq)) {
                                if (reorder.isNotEmpty() && seq < reorder.lastKey())
                                    rtpReorderedPackets++
                                reorder[seq] = next
                            }
                            // Prevent stale audio backlog on weak hardware.
                            while (reorder.size > 64) {
                                val removed = reorder.pollFirstEntry()
                                if (removed != null) {
                                    droppedPackets++
                                    if (expected != null && removed.key >= expected!!)
                                        expected = removed.key + 1
                                }
                            }
                        }
                        if (expected == null) {
                            if (reorder.isEmpty()) continue
                            // ~280ms of startup jitter tolerance. If Wi-Fi
                            // is very sparse, begin after a bounded delay.
                            if (reorder.size < 12 && now - firstBufferedAt < 600L)
                                continue
                            expected = reorder.firstKey()
                        }
                        val wanted = expected!!
                        val frame = reorder.remove(wanted)
                        if (frame == null) {
                            if (reorder.isNotEmpty() && reorder.firstKey() > wanted) {
                                if (gapAt == 0L) gapAt = now
                                if (now - gapAt >= 65L) {
                                    val first = reorder.firstKey()
                                    rtpMissingPackets += (first - wanted)
                                    expected = first
                                    gapAt = 0L
                                }
                            } else if (reorder.isEmpty() && started &&
                                now - lastAacPacketAtMs > 350L &&
                                (underrunNotedAt == 0L || now - underrunNotedAt > 700L)) {
                                underrunNotedAt = now
                                bufferUnderruns++
                                status("buffering",
                                    "UDP radio/capture gap; keeping speaker open")
                            }
                            continue
                        }
                        expected = wanted + 1
                        gapAt = 0L
                        latestRtpTimestamp = frame.timestamp
                        val activeDecoder = decoder ?:
                            throw IllegalStateException("AAC decoder not initialized")
                        activeDecoder.decode(frame.aac) { pcm ->
                            for (index in 0 until pcm.size - 1 step 2) {
                                val sample = (pcm[index].toInt() and 255) or
                                    (pcm[index + 1].toInt() shl 8)
                                val amplitude = kotlin.math.abs(sample.toShort().toInt())
                                if (amplitude > loudestSample) loudestSample = amplitude
                            }
                            var offset = 0
                            while (offset < pcm.size && running) {
                                val mode = if (started)
                                    AudioTrack.WRITE_BLOCKING
                                    else AudioTrack.WRITE_NON_BLOCKING
                                val written = output.write(pcm, offset,
                                    pcm.size - offset, mode)
                                if (written < 0)
                                    throw IllegalStateException(
                                        "AAC speaker write failed ($written)")
                                if (written == 0) {
                                    if (!started) {
                                        output.play()
                                        started = true
                                    } else Thread.sleep(2L)
                                    continue
                                }
                                offset += written
                                bytesPlayed += written
                                if (!started) primedBytes += written
                            }
                        }
                        bufferedMs = (reorder.size + incoming.size) * 1024 * 1000 / RATE
                        if (!started && primedBytes >= RATE * 4 / 4) {
                            output.play()
                            started = true
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N)
                            androidUnderruns = output.underrunCount
                        val updateAt = android.os.SystemClock.elapsedRealtime()
                        if (updateAt - lastMetricsAt >= 1000L) {
                            lastMetricsAt = updateAt
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                                audioRoute = output.routedDevice?.productName?.toString()
                                    ?: "Android default output"
                            status(if (started) "playing" else "buffering",
                                "RTP-style UDP AAC; jitter ~${bufferedMs} ms, lost ${rtpMissingPackets}")
                        }
                    }
                } catch (error: Exception) {
                    if (running) {
                        decoderFailure.set(error.message ?: error.javaClass.simpleName)
                        try { udp.close() } catch (_: Exception) {}
                    }
                } finally {
                    try { decoder?.close() } catch (_: Exception) {}
                    try { player?.pause(); player?.flush(); player?.release() }
                    catch (_: Exception) {}
                    if (track === player) track = null
                }
            }, "VYBE-RTP-AAC-DecodeAndPlay")
            decoderThread.start()
            val buffer = ByteArray(VybeRtpAudio.MAX_DATAGRAM)
            while (running) {
                try {
                    val packet = DatagramPacket(buffer, buffer.size)
                    udp.receive(packet)
                    val senderIp = packet.address.hostAddress ?: ""
                    observedPeerIp = senderIp
                    if (senderIp != allowedIp) {
                        rejectedClients++
                        continue
                    }
                    val frame = VybeRtpAudio.decode(packet.data, packet.length)
                    if (frame == null) {
                        rejectedClients++
                        continue
                    }
                    if (connectedClients == 0) {
                        connectedClients = 1
                        lastFailure = ""
                        status("connected", "UDP AAC stream accepted from $senderIp")
                    }
                    bytesReceived += packet.length
                    lastAacPacketAtMs = android.os.SystemClock.elapsedRealtime()
                    if (!incoming.offer(frame)) {
                        incoming.poll()
                        droppedPackets++
                        incoming.offer(frame)
                    }
                } catch (_: SocketTimeoutException) {
                    // No forced reconnect on short Wi-Fi Direct stalls.
                } catch (error: SocketException) {
                    if (!running) break else throw error
                }
            }
        } catch (error: Exception) {
            if (running) {
                lastFailure = decoderFailure.get() ?: "UDP receiver: " +
                    (error.message ?: error.javaClass.simpleName)
                status("interrupted", lastFailure)
            }
        } finally {
            readerFinished.set(true)
            try { udp.close() } catch (_: Exception) {}
            try { decoderThread?.join(1800L) } catch (_: InterruptedException) {}
            if (decoderThread?.isAlive == true) decoderThread?.interrupt()
            if (listener === udp) listener = null
            if (running && decoderFailure.get() != null) {
                lastFailure = "AAC playback: " + decoderFailure.get()
                status("interrupted", lastFailure)
            }
            shutdown()
        }
    }

    private fun shutdown() {
        running = false
        try { listener?.close() } catch (_: Exception) {}
        listener = null
        try { track?.stop() } catch (_: Exception) {}
        try { track?.release() } catch (_: Exception) {}
        track = null
    }

    override fun onDestroy() {
        shutdown()
        super.onDestroy()
    }
}
