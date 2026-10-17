package de.paulherter.swiftly

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VlcHandoverTest {
    @Test fun viewsAreAttachedOnlyWhenMissingAndALayoutExists() {
        assertTrue(VlcHandover.attachNeeded(hasLayout = true, attached = false))
        assertFalse(VlcHandover.attachNeeded(hasLayout = true, attached = true))
        assertFalse(VlcHandover.attachNeeded(hasLayout = false, attached = false))
    }

    @Test fun chosenSpeedSurvivesTheFallback() {
        assertEquals(1.5f, VlcHandover.rateAfterOpen(1.5f))
        assertEquals(0.75f, VlcHandover.rateAfterOpen(0.75f))
        assertNull(VlcHandover.rateAfterOpen(1f))
        assertNull(VlcHandover.rateAfterOpen(0f))
    }
}
