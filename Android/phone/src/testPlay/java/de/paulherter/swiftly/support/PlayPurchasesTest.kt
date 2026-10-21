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

    @Test fun oneTipOwnsItButGivesNoStatus() {
        val s = PlayPurchases.summarize(tips, listOf(PlayPurchases.Seen(listOf("de.paulherter.swiftly.tip.cake"), purchased = true)))
        assertEquals(setOf("de.paulherter.swiftly.tip.cake"), s.owned)
        assertEquals(setOf(0), s.relevant)
        assertTrue(s.statusGone)
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
        assertTrue(s.statusGone)
    }

    @Test fun allThreeOwned() {
        val s = PlayPurchases.summarize(tips, tips.map { PlayPurchases.Seen(listOf(it), purchased = true) })
        assertEquals(tips, s.owned)
        assertTrue(s.statusGone)
    }

    @Test fun subscriptionAndLifetimeCountWithTips() {
        val ids = tips + "supporter" + "supporter_lifetime"
        val s = PlayPurchases.summarize(ids, listOf(PlayPurchases.Seen(listOf("supporter"), purchased = true)))
        assertEquals(setOf("supporter"), s.owned)
        assertFalse(s.statusGone)
    }

    @Test fun aTipBesideAPlanKeepsTheStatusOnlyForThePlan() {
        val ids = tips + "supporter" + "supporter_lifetime"
        val both = listOf(PlayPurchases.Seen(listOf("de.paulherter.swiftly.tip.cake"), purchased = true),
                          PlayPurchases.Seen(listOf("supporter"), purchased = true))
        assertFalse(PlayPurchases.summarize(ids, both).statusGone)
        val lapsed = listOf(PlayPurchases.Seen(listOf("de.paulherter.swiftly.tip.cake"), purchased = true),
                            PlayPurchases.Seen(listOf("supporter"), purchased = false))
        assertTrue(PlayPurchases.summarize(ids, lapsed).statusGone)
    }

    @Test fun lapsedSubscriptionWithoutAnythingElseWithdrawsTheStatus() {
        val ids = tips + "supporter" + "supporter_lifetime"
        val s = PlayPurchases.summarize(ids, emptyList())
        assertTrue(s.statusGone)
    }
}

class PlayPlanPriorityTest {
    @Test fun lifetimeBeatsSubscriptionBeatsTip() {
        val tip = listOf("de.paulherter.swiftly.tip.cake")
        val sub = listOf("supporter")
        val life = listOf("supporter_lifetime")
        assertEquals("lifetime", PlayPurchases.bestPlan(listOf(sub, life, tip)))
        assertEquals("lifetime", PlayPurchases.bestPlan(listOf(life, sub)))
        assertEquals("monthly", PlayPurchases.bestPlan(listOf(tip, sub)))
        assertEquals("", PlayPurchases.bestPlan(listOf(tip)))
        assertEquals("monthly", PlayPurchases.bestPlan(listOf(tip, sub, tip)))
    }

    @Test fun rankOrdersWeakestFirst() {
        val order = listOf(listOf("supporter_lifetime"), listOf("x.tip"), listOf("supporter")).sortedBy { PlayPurchases.rank(it) }
        assertEquals(listOf("x.tip"), order[0]); assertEquals(listOf("supporter_lifetime"), order[2])
    }
}
