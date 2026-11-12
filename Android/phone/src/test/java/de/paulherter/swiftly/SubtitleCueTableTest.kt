package de.paulherter.swiftly

import androidx.media3.common.text.Cue
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.text.CuesWithTiming
import org.junit.Assert.assertEquals
import org.junit.Test

/** Contract line 14: embedded tracks are parsed one sample at a time, so the table has to collect them. */
@UnstableApi
class SubtitleCueTableTest {
    private fun cue(text: String, startS: Double, endS: Double) =
        CuesWithTiming(listOf(Cue.Builder().setText(text).build()), (startS * 1_000_000).toLong(), ((endS - startS) * 1_000_000).toLong())

    @Test fun samplesOfOneTrackAddUp() {
        val t = SubtitleCueTable()
        t.publish("5", listOf(cue("one", 1.0, 3.0)))
        t.publish("5", listOf(cue("two", 4.0, 6.0)))
        assertEquals("one", t.activeAt("5", 2_000_000).single().text.toString())
        assertEquals("two", t.activeAt("5", 5_000_000).single().text.toString())
    }

    @Test fun readingASampleAgainDoesNotDoubleTheText() {
        val t = SubtitleCueTable()
        t.publish("5", listOf(cue("one", 1.0, 3.0)))
        t.publish("5", listOf(cue("one", 1.0, 3.0)))
        assertEquals(1, t.activeAt("5", 2_000_000).size)
    }

    @Test fun theSelectedTrackIdWithAContainerPrefixFindsTheParsedOne() {
        val t = SubtitleCueTable()
        t.publish("datei:2", listOf(cue("one", 1.0, 3.0)))
        assertEquals(1, t.activeAt("1:datei:2", 2_000_000).size)
    }
}
