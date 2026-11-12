package de.paulherter.swiftly

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PreRollTest {
    @Test fun farJumpOutsideTheBufferReadsFromEarlier() =
        assertEquals(115_000L, PreRoll.start(125_000, positionMs = 3_000, bufferedMs = 40_000, subtitleOn = true))

    @Test fun nearTheStartItReadsFromZero() =
        assertEquals(0L, PreRoll.start(6_000, positionMs = 90_000, bufferedMs = 100_000, subtitleOn = true))

    @Test fun noTrackNoPreRoll() = assertNull(PreRoll.start(125_000, 3_000, 40_000, subtitleOn = false))

    @Test fun insideTheBufferIsAPlainSeek() = assertNull(PreRoll.start(40_000, 3_000, 60_000, subtitleOn = true))

    @Test fun aShortSkipIsAPlainSeek() {
        assertNull(PreRoll.start(90_000, 100_000, 100_000, subtitleOn = true))
        assertNull(PreRoll.start(115_000, 100_000, 100_000, subtitleOn = true))
    }

    @Test fun farBackIsPreRolledToo() = assertEquals(50_000L, PreRoll.start(60_000, 200_000, 210_000, subtitleOn = true))

    @Test fun resumeAlwaysReadsFromEarlier() =
        assertEquals(115_000L, PreRoll.start(125_000, 125_000, 125_000, subtitleOn = true, force = true))

    @Test fun startOfFilmNeedsNone() = assertNull(PreRoll.start(0, 0, 0, subtitleOn = true, force = true))

    @Test fun landsWhenTheBufferIsPastTheTargetOrTimeIsUp() {
        val s = PreRoll.State.Reading(target = 125_000, from = 115_000, resume = false, deadlineMs = 10_000)
        assertFalse(PreRoll.readyToLand(s, bufferedMs = 124_000, ended = false, nowMs = 1_000))
        assertTrue(PreRoll.readyToLand(s, bufferedMs = 125_400, ended = false, nowMs = 1_000))
        assertTrue(PreRoll.readyToLand(s, bufferedMs = 116_000, ended = false, nowMs = 10_000))
        assertTrue(PreRoll.readyToLand(s, bufferedMs = 116_000, ended = true, nowMs = 1_000))
    }
}
