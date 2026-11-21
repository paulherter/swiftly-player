package de.paulherter.swiftly.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.Choice
import de.paulherter.swiftly.SeerrEpisodeSeasons
import de.paulherter.swiftly.SheetRequest
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.rustcore.SeerrEpisodeInfo
import de.paulherter.swiftly.seerrEpisodeTitle
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.smoothRoundedShape
import de.paulherter.swiftly.shared.translated

/**
 * Mirrors `SeerrEpisodes` on tvOS: "Folgen" with the series page's season button (`TvCapsule`, its menu is the same
 * `SheetRequest` "Staffel") next to it; the rows below are in the caller (one focus section each, so the page scrolls per row).
 */
@Composable
fun TvSeerrEpisodesHeading(app: SwiftlyApplication, episodes: SeerrEpisodeSeasons, pick: (Long) -> Unit, modifier: Modifier = Modifier) {
    Row(modifier.padding(start = TvTheme.edgePage), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(translated("Folgen"), style = TvTheme.rail, color = Theme.font)
        if (episodes.seasons.size > 1) TvCapsule(episodes.current.title) {
            app.sheet.value = SheetRequest(translated("Staffel"), episodes.seasons.map { Choice(it.number.toString(), it.title) },
                                           episodes.current.number.toString()) { w -> w.toLongOrNull()?.let(pick) }
        }
    }
}

/** One episode: focusable so the remote can walk down the list (it has no action), the still in final size. */
@Composable
fun TvSeerrEpisodeRow(e: SeerrEpisodeInfo, modifier: Modifier = Modifier) {
    FocusArea(modifier.padding(start = TvTheme.edgePage - 16.dp, end = TvTheme.edgePage).widthIn(max = 760.dp).fillMaxWidth(), magnifier = 1f, perform = {}) { focus ->
        Row(Modifier.fillMaxWidth().clip(smoothRoundedShape(TvTheme.corner)).background(if (focus) TvTheme.focusArea else Color.Transparent).padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Box(Modifier.size(180.dp, 101.dp).clip(smoothRoundedShape(TvTheme.cornerTile)).background(Theme.area)) {
                e.still?.let { AsyncImage(model = it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(seerrEpisodeTitle(e), style = TvTheme.body, color = Theme.font, maxLines = 2, overflow = TextOverflow.Ellipsis)
                if (e.meta.isNotEmpty()) Text(e.meta, style = TvTheme.small, color = Theme.fontVeryQuiet, maxLines = 1)
                e.overview?.let { Text(it, style = TvTheme.small, color = Theme.fontQuiet, maxLines = 3, overflow = TextOverflow.Ellipsis) }
            }
        }
    }
}
