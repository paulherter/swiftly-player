package de.paulherter.swiftly

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The strip's jump goes to the position the strip gives, not to a search over the loaded tiles. */
class AlphabetJumpTargetTest {
    private fun tile(i: Int, letter: String?) = GridTile("id$i", "t$i", "Movie", null, null, null, null, 0, letter)

    private val strip = listOf(LetterEntry("A", 0), LetterEntry("B", 2), LetterEntry("T", 5))

    @Test fun aLetterNoTileCarriesStillJumpsToItsOwnStart() = runBlocking {
        // The tiles were made without sort names: every one reads "T".
        val items = List(10) { tile(it, "T") }
        assertEquals(2, alphabetJumpTarget("B", strip, { items }, { false }, { false }) {})
        assertEquals(0, alphabetJumpTarget("A", strip, { items }, { false }, { false }) {})
        assertEquals(5, alphabetJumpTarget("T", strip, { items }, { false }, { false }) {})
    }

    @Test fun aLetterNotInTheStripHasNoTarget() = runBlocking {
        assertNull(alphabetJumpTarget("Z", strip, { List(10) { tile(it, null) } }, { false }, { false }) {})
    }

    @Test fun aTitleNotLoadedYetIsLoadedFirst() = runBlocking {
        var items = List(3) { tile(it, "A") }
        val asked = mutableListOf<Long>()
        val target = alphabetJumpTarget("T", strip, { items }, { items.size < 20 }, { false }) { n ->
            asked += n
            items = items + List(n.toInt()) { tile(items.size + it, "A") }
        }
        assertEquals(5, target)
        assertEquals(1, asked.size)
    }

    @Test fun aListThatEndsBeforeTheStartGivesTheLastTitle() = runBlocking {
        val items = List(3) { tile(it, "A") }
        assertEquals(2, alphabetJumpTarget("T", strip, { items }, { false }, { false }) {})
    }
}
