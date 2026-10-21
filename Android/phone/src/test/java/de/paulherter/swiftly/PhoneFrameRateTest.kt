package de.paulherter.swiftly

import org.junit.Assert.assertEquals
import org.junit.Test

class PhoneFrameRateTest {
    private val panel = listOf(60f, 120f)

    @Test fun filmOnSixtyOneTwentyStaysAtSixty() = assertEquals(60f, PhoneFrameRate.target(23.976, panel))
    @Test fun twentyFiveOnSixtyOneTwentyIsSixty() = assertEquals(60f, PhoneFrameRate.target(25.0, panel))
    @Test fun thirtyAndSixtyAreSixty() {
        assertEquals(60f, PhoneFrameRate.target(29.97, panel))
        assertEquals(60f, PhoneFrameRate.target(59.94, panel))
    }
    @Test fun lowestEvenMultipleWins() {
        val many = listOf(24f, 30f, 48f, 50f, 60f, 90f, 120f)
        assertEquals(24f, PhoneFrameRate.target(23.976, many))
        assertEquals(50f, PhoneFrameRate.target(25.0, many))
        assertEquals(30f, PhoneFrameRate.target(30.0, many))
        assertEquals(50f, PhoneFrameRate.target(50.0, many))
    }
    @Test fun neverAboveSixty() {
        assertEquals(60f, PhoneFrameRate.target(120.0, panel))
        assertEquals(60f, PhoneFrameRate.target(23.976, listOf(90f, 120f)))
    }
}
