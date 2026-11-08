package de.paulherter.swiftly

import android.media.AudioFormat
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer

@UnstableApi
class DelayAudioProcessorTest {

    private fun processor(delayMs: Int): DelayAudioProcessor {
        val p = DelayAudioProcessor()
        p.wantedMs = delayMs
        p.configure(AudioProcessor.AudioFormat(48_000, 2, AudioFormat.ENCODING_PCM_16BIT))
        p.flush()
        return p
    }

    @Test fun emptyInputIsIgnoredInsteadOfCopyingABufferIntoItself() {
        val p = processor(0)
        p.queueInput(AudioProcessor.EMPTY_BUFFER)
        assertEquals(0, p.getOutput().remaining())
    }

    @Test fun soundPassesThroughUnchangedWithoutDelay() {
        val p = processor(0)
        val input = ByteBuffer.allocateDirect(8).also { b -> repeat(8) { b.put(it.toByte()) }; b.flip() }
        p.queueInput(input)
        val out = p.getOutput()
        assertEquals(8, out.remaining())
        assertEquals(3, out.get(3).toInt())
    }

    @Test fun delayAddsSilenceInFront() {
        val p = processor(10)
        val input = ByteBuffer.allocateDirect(4).also { b -> repeat(4) { b.put(1) }; b.flip() }
        p.queueInput(input)
        val out = p.getOutput()
        assertEquals(480 * 4 + 4, out.remaining())
        assertEquals(0, out.get(0).toInt())
        assertEquals(1, out.get(out.limit() - 1).toInt())
    }
}
