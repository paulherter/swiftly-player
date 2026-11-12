package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/** Old against new for the pure player helpers: the Swift answers (Android/golden, files `pl-*.json`) against the core's. */
class LegacyPlayerRulesParityTest {
    private val golden = System.getenv("SWIFTLY_GOLDEN_DIR")
    private val en = "en"

    private fun old(name: String): String {
        assumeTrue("no SWIFTLY_GOLDEN_DIR", golden != null)
        return File(golden!!, "$name.json").readText().trim()
    }

    private fun json(name: String, new: String) = assertNull(name, JsonParity.diff(old(name), new))
    private fun text(name: String, new: String) = assertEquals(name, old(name), new)
    private fun number(name: String, new: Double) = assertEquals(name, old(name).toDouble(), new, 1e-9)

    @Test fun delayState() {
        json("pl-delay-state-en", legacyDelayState(1500, "en-US", "en"))
        json("pl-delay-state-de-minus", legacyDelayState(-250, "de-DE", "de"))
        json("pl-delay-state-null", legacyDelayState(0, "en-US", "en"))
        json("pl-delay-state-end", legacyDelayState(12000, "en-US", "en"))
        json("pl-delay-state-start", legacyDelayState(-10000, "de-DE", "de"))
        json("pl-delay-state-round", legacyDelayState(74, "en-US", "en"))
    }

    @Test fun delayNumbers() {
        text("pl-delay-shifted", legacyDelayShifted(200, 1, 5).toString())
        text("pl-delay-shifted-cap", legacyDelayShifted(9950, 1, 5).toString())
        text("pl-delay-shifted-down", legacyDelayShifted(0, -1, 3).toString())
        text("pl-delay-new-same-title", legacyDelayForNewTitle(300, "a", "", "a", "").toString())
        text("pl-delay-new-same-series", legacyDelayForNewTitle(300, "a", "s", "b", "s").toString())
        text("pl-delay-new-other", legacyDelayForNewTitle(300, "a", "s", "b", "t").toString())
        text("pl-delay-new-none", legacyDelayForNewTitle(300, "a", "", "b", "").toString())
        text("pl-delay-micro", legacyDelayMicroseconds(350).toString())
        text("pl-delay-soft-no", legacyDelaySoftFrom(200, 200_400).toString())
        text("pl-delay-soft-yes", legacyDelaySoftFrom(200, 0).toString())
    }

    @Test fun firstFrame() {
        text("pl-ff-rat-wait", legacyFirstFrameRat(true, false, 0, 2.0, 0))
        text("pl-ff-rat-output", legacyFirstFrameRat(true, false, 0, 5.0, 0))
        text("pl-ff-rat-software", legacyFirstFrameRat(true, false, 0, 5.0, 1))
        text("pl-ff-rat-giveup", legacyFirstFrameRat(true, false, 0, 5.0, 2))
        text("pl-ff-rat-done", legacyFirstFrameRat(true, false, 0, 5.0, 3))
        text("pl-ff-rat-picture", legacyFirstFrameRat(true, false, 4, 9.0, 0))
        text("pl-ff-rat-novideo", legacyFirstFrameRat(false, false, 0, 9.0, 0))
        text("pl-ff-rat-excluded", legacyFirstFrameRat(true, true, 0, 9.0, 0))
        for (rat in listOf("ausgabeNeu", "softwareDekoder", "aufgeben", "warten", "nichts")) {
            text("pl-ff-next-$rat", legacyFirstFrameNext(rat, 1).toString())
        }
        number("pl-ff-growth", legacyFirstFrameGrowth(10.0, 10.5))
        number("pl-ff-growth-seek", legacyFirstFrameGrowth(10.0, 90.0))
        number("pl-ff-growth-none", legacyFirstFrameGrowth(-1.0, 10.0))
        for (rung in 0..3) text("pl-ff-hint-$rung", legacyFirstFrameHint(rung.toLong(), en))
        text("pl-ff-option", legacyFirstFrameSoftwareOption())
    }

    @Test fun streamWatch() {
        text("pl-sw-notyet", legacyStreamWatchRat(2.0, -1.0, false, 100.0, 100.0))
        text("pl-sw-jump", legacyStreamWatchRat(7.0, -1.0, true, 100.0, 100.0))
        text("pl-sw-jump-recent", legacyStreamWatchRat(7.0, -1.0, false, 5.0, 100.0))
        text("pl-sw-buffer", legacyStreamWatchRat(7.0, -1.0, false, 100.0, 1.0))
        text("pl-sw-new", legacyStreamWatchRat(7.0, -1.0, false, 100.0, 100.0))
        text("pl-sw-net-fresh", legacyStreamWatchRat(3.0, 10.0, false, 100.0, 100.0))
        text("pl-sw-net-old", legacyStreamWatchRat(3.0, 500.0, false, 100.0, 100.0))
        text("pl-sw-images-same", legacyStreamWatchImagesState(5, 5).toString())
        text("pl-sw-images-grown", legacyStreamWatchImagesState(5, 9).toString())
        text("pl-sw-images-none", legacyStreamWatchImagesState(-1, 9).toString())
        text("pl-sw-images-zero", legacyStreamWatchImagesState(0, 0).toString())
        number("pl-sw-deadline", legacyStreamWatchNetworkChangeDeadline())
    }

    @Test fun ratingAndCommunity() {
        text("pl-rating-counts-yes", legacyRatingCounts(2400.0, 2500.0).toString())
        text("pl-rating-counts-short", legacyRatingCounts(50.0, 55.0).toString())
        text("pl-rating-counts-early", legacyRatingCounts(1000.0, 2500.0).toString())
        text("pl-rating-due-yes", legacyRatingDue(3, "", "1.2").toString())
        text("pl-rating-due-same", legacyRatingDue(3, "1.2", "1.2").toString())
        text("pl-rating-due-few", legacyRatingDue(2, "", "1.2").toString())
        text("pl-community-rating", legacyCommunityTrigger(3, "", "1.2", false, true))
        text("pl-community-discord", legacyCommunityTrigger(5, "1.2", "1.2", false, true))
        text("pl-community-discord-norating", legacyCommunityTrigger(5, "", "1.2", false, false))
        text("pl-community-none", legacyCommunityTrigger(5, "1.2", "1.2", true, true))
        text("pl-community-few", legacyCommunityTrigger(1, "", "1.2", false, true))
        for (art in listOf("discord", "discordKurz", "play", "fehlerKurz")) text("pl-community-addr-$art", legacyCommunityAddress(art, "1.2", "Android"))
        text("pl-community-error", legacyCommunityAddress("fehler", "1.2.3 (45)", "Android 14 & more+"))
    }

    @Test fun nextEpisodeAndNotch() {
        text("pl-next-auto-none", legacyNextAutomaticApplies("", "").toString())
        text("pl-next-auto-account-off", legacyNextAutomaticApplies("", "0").toString())
        text("pl-next-auto-own-on", legacyNextAutomaticApplies("1", "0").toString())
        text("pl-next-auto-own-off", legacyNextAutomaticApplies("0", "1").toString())
        number("pl-notch-near", legacyNotch(150.0, 2700.0, listOf(90.0, 2500.0), 270.0))
        number("pl-notch-far", legacyNotch(1000.0, 2700.0, listOf(90.0, 2500.0), 270.0))
        number("pl-notch-twice", legacyNotch(100.0, 2700.0, listOf(60.0, 140.0), 270.0))
        number("pl-notch-edge", legacyNotch(10.0, 2700.0, listOf(0.0, 2700.0), 270.0))
    }

    @Test fun settingsLists() {
        json("pl-bitrate-levels", legacyBitrateLevels(en))
        json("pl-span", legacySpan())
        json("pl-languages-file", legacyLanguages("", en))
        json("pl-languages-off", legacyLanguages("Off", en))
        json("pl-buffer-levels", legacyBufferLevels(en))
    }
}
