package de.paulherter.swiftly

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SwitchAnswerTest {
    @Test fun switchedCarriesThePlanAndAPendingStop() {
        val a = SwitchAnswer.read("""{"ergebnis":"gewechselt","spielplan":"{\"url\":\"u\"}","nachmeldung":"p"}""")
        assertEquals(SwitchAnswer.Switched("""{"url":"u"}""", "p"), a)
    }

    @Test fun switchedWithoutAPlanIsStillSwitched() =
        assertEquals(SwitchAnswer.Switched(null, null), SwitchAnswer.read("""{"ergebnis":"gewechselt"}"""))

    @Test fun everyOtherCoreWordHasItsOwnCase() {
        assertEquals(SwitchAnswer.Locked(null), SwitchAnswer.read("""{"ergebnis":"gesperrt"}"""))
        assertEquals(SwitchAnswer.Cancelled(null), SwitchAnswer.read("""{"ergebnis":"abgebrochen"}"""))
        assertEquals(SwitchAnswer.Failed("Nicht verfügbar", null), SwitchAnswer.read("""{"ergebnis":"gescheitert","fehler":"Nicht verfügbar"}"""))
        assertNull((SwitchAnswer.read("""{"ergebnis":"gescheitert"}""") as SwitchAnswer.Failed).error)
    }

    @Test fun unknownWordsAndBrokenAnswersAreNeverSilent() {
        // English words (an older core), a missing key, an empty or broken answer: each is an Unknown that the player shows.
        assertEquals(SwitchAnswer.Unknown("switched", null), SwitchAnswer.read("""{"ergebnis":"switched"}"""))
        assertEquals(SwitchAnswer.Unknown("ohne Ergebnis", null), SwitchAnswer.read("""{"result":"switched"}"""))
        assertTrue(SwitchAnswer.read("") is SwitchAnswer.Unknown)
        assertTrue(SwitchAnswer.read("kein json") is SwitchAnswer.Unknown)
    }
}
