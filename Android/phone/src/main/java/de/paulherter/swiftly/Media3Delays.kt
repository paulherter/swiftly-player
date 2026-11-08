package de.paulherter.swiftly

import android.content.Context
import android.media.AudioFormat
import android.os.Looper
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ForwardingRenderer
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.audio.AudioCapabilities
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.text.TextOutput
import java.nio.ByteBuffer

/**
 * **Audio delay for Media3** (VLC had `audioDelay`). A positive delay plays the sound later: silence is inserted
 * once when the value grows, and the first samples are dropped when it shrinks. Works on decoded sound only;
 * a passthrough track (the receiver decodes) cannot be delayed, the delay then stays without effect.
 */
@UnstableApi
class DelayAudioProcessor : BaseAudioProcessor() {
    /** Wanted delay in milliseconds, read on the audio thread. */
    @Volatile var wantedMs: Int = 0
    private var appliedFrames = 0L
    private var bytesPerFrame = 0
    private var rate = 0

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        bytesPerFrame = inputAudioFormat.bytesPerFrame
        rate = inputAudioFormat.sampleRate
        appliedFrames = 0
        return inputAudioFormat
    }

    override fun isActive(): Boolean = super.isActive()

    override fun onFlush() { appliedFrames = 0 }

    override fun queueInput(inputBuffer: ByteBuffer) {
        // Media3 also calls with an empty buffer (start and end of the stream). `replaceOutputBuffer(0)` then hands
        // back the very same shared empty buffer, and `put(inputBuffer)` into itself throws: every title failed
        // before its first picture. Nothing to move, nothing to count.
        if (!inputBuffer.hasRemaining()) return
        val target = wantedMs.toLong() * rate / 1000
        val diff = target - appliedFrames
        appliedFrames = target
        if (diff > 0) {
            val silence = replaceOutputBuffer((diff * bytesPerFrame + inputBuffer.remaining()).toInt())
            silence.put(ByteArray((diff * bytesPerFrame).toInt()))
            silence.put(inputBuffer)
            silence.flip()
        } else {
            if (diff < 0) inputBuffer.position(minOf(inputBuffer.limit().toLong(), inputBuffer.position() - diff * bytesPerFrame).toInt())
            val out = replaceOutputBuffer(inputBuffer.remaining())
            out.put(inputBuffer)
            out.flip()
        }
    }
}

/** Renderer that sees the clock `delayUs` late: text and picture subtitles appear that much later (negative: earlier). */
@UnstableApi
class ShiftedRenderer(delegate: Renderer, private val delayUs: () -> Long) : ForwardingRenderer(delegate) {
    override fun render(positionUs: Long, elapsedRealtimeUs: Long) {
        super.render(positionUs - delayUs(), elapsedRealtimeUs)
    }
}

/** Media3's standard renderers with our audio delay in the sink and the subtitle delay in the text renderer. */
@UnstableApi
class SwiftlyRenderersFactory(context: Context, val audioDelay: DelayAudioProcessor, private val passthrough: String)
    : DefaultRenderersFactory(context) {
    @Volatile var subtitleDelayMs: Int = 0

    /**
     * Sound output. `auto`: what the output reports (Media3's default). `off`: PCM only (the FFmpeg decoders or the
     * device decode, nothing goes to the receiver as a bitstream). `ac3`: AC-3 and E-AC-3 only. `all`: AC-3, E-AC-3,
     * DTS, DTS-HD and TrueHD are offered whether the probe finds them or not (the manual switch of the wiki list).
     */
    private fun capabilities(): AudioCapabilities? {
        val pcm = AudioFormat.ENCODING_PCM_16BIT
        return when (passthrough) {
            "off" -> AudioCapabilities(intArrayOf(pcm), 8)
            "ac3" -> AudioCapabilities(intArrayOf(pcm, AudioFormat.ENCODING_AC3, AudioFormat.ENCODING_E_AC3), 8)
            "all" -> AudioCapabilities(intArrayOf(pcm, AudioFormat.ENCODING_AC3, AudioFormat.ENCODING_E_AC3, AudioFormat.ENCODING_E_AC3_JOC,
                AudioFormat.ENCODING_DTS, AudioFormat.ENCODING_DTS_HD, AudioFormat.ENCODING_DOLBY_TRUEHD), 8)
            else -> null
        }
    }

    override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioOutputPlaybackParams: Boolean): AudioSink =
        DefaultAudioSink.Builder(context)
            .setEnableFloatOutput(enableFloatOutput)
            .setEnableAudioTrackPlaybackParams(enableAudioOutputPlaybackParams)
            .setAudioProcessors(arrayOf(audioDelay))
            .also { b -> capabilities()?.let { b.setAudioCapabilities(it) } }
            .build()

    override fun buildTextRenderers(context: Context, output: TextOutput, outputLooper: Looper, extensionRendererMode: Int,
                                    out: ArrayList<Renderer>) {
        val own = ArrayList<Renderer>()
        super.buildTextRenderers(context, output, outputLooper, extensionRendererMode, own)
        own.mapTo(out) { ShiftedRenderer(it) { subtitleDelayMs * 1000L } }
    }
}
