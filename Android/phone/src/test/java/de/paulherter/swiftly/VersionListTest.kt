package de.paulherter.swiftly

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The page reads the core's version list as it is: the order, the labels and the `standard` mark (`VersionOption::list`). */
class VersionListTest {
    private fun title(versions: String) =
        titleRead("""{"id":"m1","name":"Sommerregen","typ":"Movie","planDa":true,"fassungen":$versions}""")

    @Test fun readsTheCoreListWithItsDefaultMark() {
        val t = title("""[{"id":"a","label":"Test klein · 720p","standard":false},
            |{"id":"b","label":"Test · 1080p","standard":true},{"id":"c","label":"Test gross","standard":false}]""".trimMargin())
        assertEquals(listOf("a", "b", "c"), t.versions.map { it.id })
        assertEquals("b", t.versions.firstOrNull { it.isDefault }?.id)
        assertEquals(1, t.versions.count { it.isDefault })
    }

    @Test fun aTitleWithoutAChoiceHasNoList() {
        assertTrue(title("[]").versions.isEmpty())
        assertNull(title("[]").versions.firstOrNull { it.isDefault })
    }

    @Test fun aLongPressOffersTheListOnlyWhenThereIsAChoice() {
        val two = title("""[{"id":"a","label":"A","standard":true},{"id":"b","label":"B","standard":false}]""")
        val one = title("""[{"id":"a","label":"A","standard":true}]""")
        assertEquals(listOf("a", "b"), versionsOffered(two, onDevice = false).map { it.id })
        assertTrue(versionsOffered(one, onDevice = false).isEmpty())
        assertTrue(versionsOffered(two, onDevice = true).isEmpty())
        // A series carries no versions itself: the TV and phone series pages ask the state episode instead.
        assertTrue(versionsOffered(null, onDevice = false).isEmpty())
    }
}
