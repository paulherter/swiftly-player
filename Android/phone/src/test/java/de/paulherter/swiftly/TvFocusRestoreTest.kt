package de.paulherter.swiftly

import de.paulherter.swiftly.tv.focusAfterReload
import de.paulherter.swiftly.tv.idAfterReload
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A quiet reload keeps TV focus where it was: same tile, else the tile that took its place, else the row above. */
class TvFocusRestoreTest {
    private fun tile(id: String) = Tile(id, id, "Episode", null, null, null, null)
    private fun rail(id: String, vararg tiles: String) = Rail(id, id, true, tiles.map(::tile), id = id)

    private val old = listOf(rail("a", "a1", "a2"), rail("b", "b1", "b2", "b3"), rail("c", "c1"))

    @Test fun theSameTileKeepsFocus() {
        assertEquals("1|b2", focusAfterReload("1|b2", old, listOf(rail("a", "a1"), rail("b", "b1", "b2"), rail("c", "c1"))))
    }

    @Test fun aRemovedTileHandsFocusToTheOneAtItsPlace() {
        assertEquals("1|n2", focusAfterReload("1|b2", old, listOf(rail("a", "a1"), rail("b", "b1", "n2", "b3"), rail("c", "c1"))))
        // The row got shorter than the position: the last tile.
        assertEquals("1|b1", focusAfterReload("1|b3", old, listOf(rail("a", "a1"), rail("b", "b1"), rail("c", "c1"))))
    }

    @Test fun aRowAboveAppearingOrVanishingDoesNotShiftFocus() {
        assertEquals("2|b2", focusAfterReload("1|b2", old, listOf(rail("n", "n1"), rail("a", "a1"), rail("b", "b1", "b2"), rail("c", "c1"))))
        assertEquals("0|b2", focusAfterReload("1|b2", old, listOf(rail("b", "b1", "b2"), rail("c", "c1"))))
    }

    @Test fun aVanishedRowFallsBackToTheRowAbove() {
        assertEquals("0|a2", focusAfterReload("1|b2", old, listOf(rail("a", "a1", "a2"), rail("c", "c1"))))
        assertEquals("0|a1", focusAfterReload("1|b1", old, listOf(rail("a", "a1", "a2"), rail("b"), rail("c", "c1"))))
    }

    @Test fun withNothingAboveTheFirstRowBelowTakesIt() {
        assertEquals("0|c1", focusAfterReload("0|a1", old, listOf(rail("c", "c1"))))
        assertNull(focusAfterReload("0|a1", old, emptyList()))
        assertNull(focusAfterReload(null, old, old))
    }

    @Test fun aGridKeepsTheTileOrHandsFocusToTheOneAtItsPlace() {
        val grid = listOf("a", "b", "c", "d")
        assertEquals("b", idAfterReload("b", grid, listOf("a", "b", "n")))
        assertEquals("c", idAfterReload("b", grid, listOf("a", "c", "d")))
        assertEquals("c", idAfterReload("d", grid, listOf("a", "b", "c")))
        assertEquals("a", idAfterReload("b", grid, listOf("a")))
        assertNull(idAfterReload("b", grid, emptyList()))
        assertNull(idAfterReload(null, grid, grid))
    }
}
