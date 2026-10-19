package de.paulherter.swiftly.support

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The status rules of the Play build on top of Play's purchase list (`PlayPurchases`). */
class PlayPurchasesTest {
    private val tips = setOf("de.paulherter.swiftly.tip.coffee", "de.paulherter.swiftly.tip.cake", "de.paulherter.swiftly.tip.movie")

    @Test fun nothingBoughtMeansNoStatus() {
        val s = PlayPurchases.summarize(tips, emptyList())
        assertTrue(s.owned.isEmpty())
        assertTrue(s.statusGone)
    }

    @Test fun oneTipOwnsItAndKeepsTheStatus() {
        val s = PlayPurchases.summarize(tips, listOf(PlayPurchases.Seen(listOf("de.paulherter.swiftly.tip.cake"), purchased = true)))
        assertEquals(setOf("de.paulherter.swiftly.tip.cake"), s.owned)
        assertEquals(setOf(0), s.relevant)
        assertFalse(s.statusGone)
    }

    @Test fun pendingOwnsNothingYet() {
        val s = PlayPurchases.summarize(tips, listOf(PlayPurchases.Seen(listOf("de.paulherter.swiftly.tip.movie"), purchased = false)))
        assertTrue(s.owned.isEmpty())
        // Still handed on (it is logged as pending), but no status.
        assertEquals(setOf(0), s.relevant)
        assertTrue(s.statusGone)
    }

    @Test fun foreignProductsDoNotCount() {
        val s = PlayPurchases.summarize(tips, listOf(
            PlayPurchases.Seen(listOf("something.else"), purchased = true),
            PlayPurchases.Seen(listOf("de.paulherter.swiftly.tip.coffee"), purchased = true)))
        assertEquals(setOf("de.paulherter.swiftly.tip.coffee"), s.owned)
        assertEquals(setOf(1), s.relevant)
        assertFalse(s.statusGone)
    }

    @Test fun allThreeOwned() {
        val s = PlayPurchases.summarize(tips, tips.map { PlayPurchases.Seen(listOf(it), purchased = true) })
        assertEquals(tips, s.owned)
    }
}
