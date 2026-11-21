package de.paulherter.swiftly.tv

import de.paulherter.swiftly.Rail

/** A row's identity across reloads: its id in the core's Home order, for genre rows the raw key or the title. Never its position. */
internal fun Rail.identity(): String = id.ifEmpty { key ?: title }

/**
 * The rule in one list (a grid, or one row): the same id if it is still there, else the one that took its position, the last when
 * the list got shorter, null when nothing is left. `focusAfterReload` applies it per row; the library grid applies it to all tiles.
 */
internal fun idAfterReload(id: String?, old: List<String>, new: List<String>): String? {
    if (id == null || new.isEmpty()) return null
    if (id in new) return id
    return new[minOf(old.indexOf(id).coerceAtLeast(0), new.size - 1)]
}

/**
 * Where focus goes when the rows are replaced by a reload while a tile in them holds focus (`mark` is "row|id" as in
 * `lastAtTitle`, the row counted in `old`). Quiet reloads must not move the user: the same tile if it is still there,
 * else the tile at the same place in the same row (the one that took its position), else a tile of the row above, else
 * the first row below that has any. Rows are matched by identity, so a row appearing or vanishing above does not
 * shift the answer. Returns the new mark, or null when nothing is left to focus.
 */
internal fun focusAfterReload(mark: String?, old: List<Rail>?, new: List<Rail>): String? {
    val parts = mark?.split('|', limit = 2) ?: return null
    val oldIndex = parts[0].toIntOrNull() ?: return null
    val oldRail = old?.getOrNull(oldIndex)
    val id = parts.getOrNull(1)
    val position = oldRail?.tiles?.indexOfFirst { it.id == id }?.takeIf { it >= 0 } ?: 0
    val row = oldRail?.let { r -> new.indexOfFirst { it.identity() == r.identity() } }?.takeIf { it >= 0 }
    fun at(i: Int): String? = new.getOrNull(i)?.tiles?.takeIf { it.isNotEmpty() }?.let { "$i|${it[minOf(position, it.size - 1)].id}" }
    if (row != null) {
        idAfterReload(id, oldRail?.tiles.orEmpty().map { it.id }, new[row].tiles.map { it.id })?.let { return "$row|$it" }
    }
    val from = (row ?: minOf(oldIndex, new.size)) - 1
    for (i in from downTo 0) at(i)?.let { return it }
    for (i in (from + 1) until new.size) at(i)?.let { return it }
    return null
}
