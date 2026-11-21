package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.rustcore.SeerrEpisodeInfo
import de.paulherter.swiftly.rustcore.SeerrSeasonRowInfo
import de.paulherter.swiftly.rustcore.SeerrTitleInfo
import de.paulherter.swiftly.rustcore.SeerrTitleScreen
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.smoothRoundedShape
import de.paulherter.swiftly.shared.translated

/**
 * The episodes of a title the server does not have ("Folgen"): the one state both Android UIs draw (iPhone `SeerrEpisodes`,
 * `SeerrTitleFlow.episodeSeasons`). The seasons that list episodes, and the one that shows: **the core's rule**
 * (`SeerrTitleScreen.episodeSeason`, the picked one if it has episodes, else the first that has any); only the pick stays
 * with the page.
 */
class SeerrEpisodeSeasons(val seasons: List<SeerrSeasonRowInfo>, val current: SeerrSeasonRowInfo)

fun seerrEpisodeSeasons(screen: SeerrTitleScreen?, info: SeerrTitleInfo, picked: Long?): SeerrEpisodeSeasons? {
    val seasons = info.seasons.filter { it.episodeList.isNotEmpty() }
    val number = screen?.episodeSeason(picked) ?: return null
    val current = seasons.firstOrNull { it.number == number } ?: return null
    return SeerrEpisodeSeasons(seasons, current)
}

/** "N. Name" as every host writes the row's title. */
fun seerrEpisodeTitle(e: SeerrEpisodeInfo) = "${e.number}. ${e.title}"

/** Phone: "Folgen", the season chips (only when there is more than one season), then a row per episode. */
@Composable
fun SeerrEpisodesBlock(episodes: SeerrEpisodeSeasons, pick: (Long) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(top = Theme.railsSpacing)) {
        Text(translated("Folgen"), style = Theme.section, color = Theme.font, modifier = Modifier.padding(horizontal = Theme.edgeSpacing))
        if (episodes.seasons.size > 1) Row(Modifier.padding(top = 10.dp).horizontalScroll(rememberScrollState()).padding(horizontal = Theme.edgeSpacing),
                                           horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            episodes.seasons.forEach { s ->
                val on = s.number == episodes.current.number
                Text(s.title, style = Theme.small.copy(fontSize = 14.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal),
                     color = if (on) Theme.font else Theme.fontQuiet, maxLines = 1,
                     modifier = Modifier.clip(CircleShape).background(Theme.font.copy(alpha = if (on) 0.14f else 0.06f))
                         .tapOn { pick(s.number) }.heightIn(min = 34.dp).padding(horizontal = 14.dp).wrapContentHeight(Alignment.CenterVertically))
            }
        }
        Spacer(Modifier.height(6.dp))
        episodes.current.episodeList.forEach { e -> SeerrEpisodeRow(e) }
    }
}

@Composable
private fun SeerrEpisodeRow(e: SeerrEpisodeInfo) {
    Row(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        // The still keeps its final size: a quiet field while it loads or when TMDB has none.
        Box(Modifier.size(128.dp, 72.dp).clip(smoothRoundedShape(Theme.cornerTile)).background(Theme.area)) {
            e.still?.let { AsyncImage(model = it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(seerrEpisodeTitle(e), style = Theme.listTitle, color = Theme.font, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (e.meta.isNotEmpty()) Text(e.meta, style = Theme.small, color = Theme.fontVeryQuiet, maxLines = 1)
            e.overview?.let { Text(it, style = Theme.small, color = Theme.fontQuiet, maxLines = 2, overflow = TextOverflow.Ellipsis) }
        }
    }
}
