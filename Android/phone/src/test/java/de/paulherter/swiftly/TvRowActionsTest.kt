package de.paulherter.swiftly

import de.paulherter.swiftly.tv.TvRowActions
import org.junit.Assert.assertEquals
import org.junit.Test

class TvRowActionsTest {
    @Test fun movieNeverShuffles() {
        assertEquals(TvRowActions(shuffle = false, together = true), TvRowActions.forMovie(planPresent = true, mayCreate = true))
        assertEquals(false, TvRowActions.forMovie(planPresent = true, mayCreate = false).together)
        assertEquals(false, TvRowActions.forMovie(planPresent = false, mayCreate = true).together)
    }

    @Test fun seriesAlwaysShufflesAndTogetherNeedsAnEpisode() {
        assertEquals(true, TvRowActions.forSeries(hasEpisodeToContinue = false, mayCreate = true).shuffle)
        assertEquals(false, TvRowActions.forSeries(hasEpisodeToContinue = false, mayCreate = true).together)
        assertEquals(true, TvRowActions.forSeries(hasEpisodeToContinue = true, mayCreate = true).together)
        assertEquals(false, TvRowActions.forSeries(hasEpisodeToContinue = true, mayCreate = false).together)
    }
}
