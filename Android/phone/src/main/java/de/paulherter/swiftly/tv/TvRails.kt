package de.paulherter.swiftly.tv

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.Extra
import de.paulherter.swiftly.Episode
import de.paulherter.swiftly.WithAct
import de.paulherter.swiftly.GridTile
import de.paulherter.swiftly.Destination
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated

/**
 * Mirrors `TitleRails.swift` (`railsSection`+`strip`, `CastStrip`, `TitleStrip`,
 * `EpisodesStrip`): the home page, the title page and the series page share these rows.
 * **Public, not copied:** the same row rebuilt separately in three places once drifted apart on
 * iOS/tvOS (`loadMore()`).
 *
 * **Unlike tvOS, the title is inside each strip**, not in a separate `railsSection`. The Kotlin
 * building blocks (`TvStrip` in `TvPages.kt`, the home rows) already do it that way; a second,
 * decoupled pattern just for this file would gain nothing. The one exception is
 * `TvEpisodesStrip`: the series page needs its own header with the season pill, as on tvOS, so it
 * has no title of its own.
 */

/** Header and horizontal strip of a row. */
@Composable
fun TvRailsStrip(title: String, modifier: Modifier = Modifier, content: LazyListScope.() -> Unit) {
    Column(modifier.padding(top = TvTheme.railsSpacing - TvTheme.railsPadding)) {
        TvRailsTitle(title)
        LazyRow(contentPadding = PaddingValues(horizontal = TvTheme.edgePage, vertical = TvTheme.railsPadding),
                horizontalArrangement = Arrangement.spacedBy(TvTheme.tileSpacing), content = content)
    }
}

/**
 * Mirrors `CastStrip`: the cast, with a target on the person page. **Every tile leads
 * somewhere**, even where it would be a dead end here: otherwise tvOS would have a `focusSection`
 * with no target, which focus falls into and gets stuck.
 */
@Composable
fun TvCastStrip(folks: List<WithAct>, origin: String? = null,
                         title: String = translated("Besetzung"), open: (Destination) -> Unit) {
    if (folks.isEmpty()) return
    TvRailsStrip(title) {
        items(folks, key = { it.id }) { p ->
            Column(Modifier.width(TvTheme.posterWidth), horizontalAlignment = Alignment.CenterHorizontally) {
                FocusArea(perform = { open(Destination(p.id, p.name, "Person", p.role, origin)) }) {
                    Box(Modifier.size(TvTheme.posterWidth).clip(CircleShape).background(Theme.area),
                        contentAlignment = Alignment.Center) {
                        Symbol(Glyph.PersonFilled, 30.dp, color = Theme.fontVeryQuiet)
                        AsyncImage(model = p.image, contentDescription = p.name, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                    }
                }
                Text(p.name, style = TvTheme.tile, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis,
                     modifier = Modifier.padding(top = 7.dp))
                p.role?.let { Text(it, style = TvTheme.small, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            }
        }
    }
}

/** Mirrors `TitleStrip` (without `start`): titles to jump to, portrait as everywhere. */
@Composable
fun TvTitleStrip(title: String, items: List<GridTile>, open: (Destination) -> Unit) {
    if (items.isEmpty()) return
    TvRailsStrip(title) {
        items(items, key = { it.id }) { k ->
            TvTile(k.poster, k.title, k.subline) { open(Destination(k.id, k.title, k.type)) }
        }
    }
}

/**
 * Mirrors `TitleStrip` with `start`: extras play at once, without an intermediate page, so
 * landscape like an episode and with no target of their own.
 */
@Composable
fun TvExtraStrip(title: String = translated("Extras"), extras: List<Extra>, start: (Extra) -> Unit) {
    if (extras.isEmpty()) return
    TvRailsStrip(title) {
        items(extras, key = { it.id }) { x -> TvTile(x.image, x.name, x.runtime, landscape = true) { start(x) } }
    }
}

/**
 * Mirrors `EpisodesStrip`: a season's episodes as landscape tiles, prescrolled to the one where
 * playback continues. **No title of its own**, unlike the three strips above: the series page sets
 * the header itself, with the season pill beside it, and a title here would duplicate it.
 */
@Composable
fun TvEpisodesStrip(episodes: List<Episode>, nextWith: String?, start: (Episode) -> Unit, modifier: Modifier = Modifier) {
    if (episodes.isEmpty()) return
    val condition = rememberLazyListState()
    LaunchedEffect(episodes, nextWith) {
        val i = episodes.indexOfFirst { it.id == nextWith }
        if (i > 0) condition.scrollToItem(i)
    }
    LazyRow(modifier, state = condition,
            contentPadding = PaddingValues(horizontal = TvTheme.edgePage, vertical = TvTheme.railsPadding),
            horizontalArrangement = Arrangement.spacedBy(TvTheme.tileSpacing)) {
        items(episodes, key = { it.id }) { f ->
            TvTile(f.image, f.title, f.subline, landscape = true, progress = f.progress) { start(f) }
        }
    }
}
