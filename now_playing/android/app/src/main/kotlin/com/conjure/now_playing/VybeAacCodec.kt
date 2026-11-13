package com.conjure.now_playing

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import java.io.Closeable
import java.nio.ByteBuffer

/**
 * Narrow, versioned, Android-native AAC-LC streaming codec.
 *
 * Both sides use 44.1 kHz / stereo / 16-bit PCM, AAC-LC at 128 kbps.
 * The wire framing is one 32-bit big-endian length and one raw AAC access
 * unit per packet. The receiver supplies MPEG-4 AudioSpecificConfig (0x1210)
 * so no encoder-specific configuration is silently lost during reconnection.
 *
 * The old PCM stream stays supported on the receiver for compatibility.
 */
internal object VybeAacFormat {
    const val RATE = 44100
    const val CHANNELS = 2
    const val BITRATE = 128000
    const val PCM_BYTES_PER_FRAME = 4
    const val PCM_FRAME_DURATION_MS = 23 // AAC-LC frame = 1024 samples
    val HEADER: ByteArray = "VYBEAAC1\n".toByteArray(Charsets.US_ASCII)
}

internal class VybeAacEncoder : Closeable {
    private val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
    private var pcmFramesQueued = 0L

    init {
        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC,
            VybeAacFormat.RATE, VybeAacFormat.CHANNELS).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE,
                MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, VybeAacFormat.BITRATE)
            setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
    }

    /** Input is only captured PCM; emit never stores a recording. */
    fun encode(pcm: ByteArray, size: Int, emit: (ByteArray) -> Unit) {
        var offset = 0
        val alignedSize = (size / VybeAacFormat.PCM_BYTES_PER_FRAME) *
            VybeAacFormat.PCM_BYTES_PER_FRAME
        var noInputTries = 0
        while (offset < alignedSize) {
            val index = codec.dequeueInputBuffer(10000L)
            if (index < 0) {
                drain(emit)
                if (++noInputTries > 100) {
                    throw IllegalStateException("AAC encoder input stalled")
                }
                continue
            }
            noInputTries = 0
            val buffer = codec.getInputBuffer(index)
                ?: throw IllegalStateException("AAC encoder input unavailable")
            buffer.clear()
            val alignedCapacity = (buffer.remaining() / 4) * 4
            val count = minOf(alignedCapacity, alignedSize - offset)
            if (count <= 0) throw IllegalStateException("AAC encoder PCM input too small")
            buffer.put(pcm, offset, count)
            val presentationUs = pcmFramesQueued * 1000000L / VybeAacFormat.RATE
            codec.queueInputBuffer(index, 0, count, presentationUs, 0)
            pcmFramesQueued += count / 4
            offset += count
            drain(emit)
        }
        drain(emit)
    }

    private fun drain(emit: (ByteArray) -> Unit) {
        val info = MediaCodec.BufferInfo()
        repeat(64) {
            val outputIndex = codec.dequeueOutputBuffer(info, 0L)
            if (outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER) return
            if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) return@repeat
            if (outputIndex < 0) return@repeat
            try {
                if (info.size > 0 &&
                    info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                    val output = codec.getOutputBuffer(outputIndex)
                        ?: throw IllegalStateException("AAC encoder output unavailable")
                    output.position(info.offset)
                    output.limit(info.offset + info.size)
                    val bytes = ByteArray(info.size)
                    output.get(bytes)
                    emit(bytes)
                }
            } finally {
                codec.releaseOutputBuffer(outputIndex, false)
            }
        }
    }

    override fun close() {
        try { codec.stop() } catch (_: Exception) {}
        try { codec.release() } catch (_: Exception) {}
    }
}

internal class VybeAacDecoder : Closeable {
    private val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
    private var encodedFramesQueued = 0L

    init {
        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC,
            VybeAacFormat.RATE, VybeAacFormat.CHANNELS).apply {
            // MPEG-4 AudioSpecificConfig: AAC-LC, 44100 Hz, stereo.
            setByteBuffer("csd-0", ByteBuffer.wrap(byteArrayOf(0x12, 0x10)))
            setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
        }
        codec.configure(format, null, null, 0)
        codec.start()
    }

    fun decode(frame: ByteArray, emit: (ByteArray) -> Unit) {
        var tries = 0
        var index = codec.dequeueInputBuffer(10000L)
        while (index < 0) {
            drain(emit)
            if (++tries > 100) throw IllegalStateException("AAC decoder input stalled")
            index = codec.dequeueInputBuffer(10000L)
        }
        val input = codec.getInputBuffer(index)
            ?: throw IllegalStateException("AAC decoder input unavailable")
        input.clear()
        if (frame.size > input.remaining()) {
            throw IllegalStateException("AAC frame exceeds decoder input capacity")
        }
        input.put(frame)
        val timestamp = encodedFramesQueued * 1024L * 1000000L / VybeAacFormat.RATE
        codec.queueInputBuffer(index, 0, frame.size, timestamp, 0)
        encodedFramesQueued++
        drain(emit)
    }

    private fun drain(emit: (ByteArray) -> Unit) {
        val info = MediaCodec.BufferInfo()
        repeat(64) {
            val index = codec.dequeueOutputBuffer(info, 0L)
            if (index == MediaCodec.INFO_TRY_AGAIN_LATER) return
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                // This stream is specified as 16-bit, 44.1 kHz, stereo PCM.
                val format = codec.outputFormat
                val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                val channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                if (sampleRate != VybeAacFormat.RATE ||
                    channels != VybeAacFormat.CHANNELS) {
                    throw IllegalStateException("Unexpected AAC output: $sampleRate Hz / $channels channels")
                }
                return@repeat
            }
            if (index < 0) return@repeat
            try {
                if (info.size > 0 &&
                    info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                    val output = codec.getOutputBuffer(index)
                        ?: throw IllegalStateException("AAC decoder output unavailable")
                    output.position(info.offset)
                    output.limit(info.offset + info.size)
                    val bytes = ByteArray(info.size)
                    output.get(bytes)
                    emit(bytes)
                }
            } finally {
                codec.releaseOutputBuffer(index, false)
            }
        }
    }

    override fun close() {
        try { codec.stop() } catch (_: Exception) {}
        try { codec.release() } catch (_: Exception) {}
    }
}
