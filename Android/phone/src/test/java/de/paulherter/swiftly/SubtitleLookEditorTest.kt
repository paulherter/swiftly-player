package de.paulherter.swiftly

import org.junit.Assert.assertEquals
import org.junit.Test

/** Four taps on the look page keep all four changes (the page used to build on a stale look). */
class SubtitleLookEditorTest {
    private var stored = "colour=white;outline=normal"
    private val editor = SubtitleLookEditor({ stored }, { stored = it }, { it }) { json, field, value ->
        json.split(';').filter { !it.startsWith("$field=") }.plus("$field=$value").sorted().joinToString(";")
    }

    @Test fun twoTapsInARowKeepBoth() {
        editor.set("colour", "yellow")
        editor.set("outline", "thin")
        assertEquals("colour=yellow;outline=thin", stored)
    }

    @Test fun fourTapsKeepAllFour() {
        editor.set("colour", "yellow"); editor.set("outline", "thin"); editor.set("size", "large"); editor.set("shadow", "true")
        assertEquals("colour=yellow;outline=thin;shadow=true;size=large", stored)
    }

    @Test fun resetReturnsTheLookBefore() {
        editor.set("colour", "yellow")
        assertEquals("colour=yellow;outline=normal", editor.reset("colour=white;outline=normal"))
        assertEquals("colour=white;outline=normal", stored)
    }
}
