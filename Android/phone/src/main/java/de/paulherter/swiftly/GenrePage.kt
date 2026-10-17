package de.paulherter.swiftly

import androidx.compose.runtime.getValue
import androidx.compose.runtime.derivedStateOf
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext
import org.json.JSONArray

/**
 * Mirrors `genreChips` in `HomeView.swift`: a row of genres above the rows when "As chips" is
 * chosen. Corners like a button, not round: round is for images. Names come from the server and
 * are not translated.
 */
@Composable
fun GenreChips(genres: List<String>, select: (String) -> Unit) {
    val form = RoundedCornerShape(Theme.corner)
    LazyRow(contentPadding = PaddingValues(horizontal = Theme.edgeSpacing), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items(genres) { g ->
            // No border: the surface already says "tappable". And 14 is on no size ladder; a chip uses 13
            // medium, like the value pill and choice chip.
            Box(Modifier.tapOn { select(g) }.heightIn(min = 34.dp).clip(form).background(Theme.area)
                    .padding(horizontal = 14.dp),
                contentAlignment = Alignment.Center) {
                Text(g, style = Theme.tile, color = Theme.font)
            }
        }
    }
}

/**
 * Mirrors `GenreView` in Shared: the titles of a genre, newest first
 * (`JellyfinClient.title(genre:)`: whoever taps a genre usually looks for what is new).
 */
@Composable
fun GenrePage(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit, back: () -> Unit) {
    var title by remember(target.id) { mutableStateOf<List<GridTile>?>(null) }
    // `disrupted` means failed, empty means empty. `catch { emptyList() }` turned every network error
    // into "nothing in this genre". The same bug existed as `?? []` in iOS `GenreView` and is fixed there.
    var disrupted by remember(target.id) { mutableStateOf(false) }
    var attempt by remember(target.id) { mutableIntStateOf(0) }
    WatchStateChange(app) { attempt++ }
    LaunchedEffect(target.id, attempt) {
        disrupted = false
        try {
            title = JSONArray(withContext(Dispatchers.IO) { app.kern.genre(target.id).await() })
                .let { a -> (0 until a.length()).map { gridTileRead(a.getJSONObject(it)) } }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
            // What is already shown stays; the failure does not replace an existing list.
            if (title.isNullOrEmpty()) { disrupted = true; title = emptyList() }
        }
    }
    val grid = rememberLazyGridState()
    val density = LocalDensity.current
    val offset by remember {
        derivedStateOf { if (grid.firstVisibleItemIndex > 0) 100f else grid.firstVisibleItemScrollOffset / density.density }
    }
    // The header sits in the `BlurHeader`, not fixed above the grid, otherwise posters run past
    // a hard edge. On the right the count badge, since "am I through here?" applies here too.
    HeaderAndContent(header = {
        RootHeader({ offset }, margin = false) {
            SubpageHeader(target.name, back, bottom = 0.dp, top = false) {
                title?.takeIf { it.isNotEmpty() }?.let { CountMark(it.size) }
            }
        }
    }) { headerDp ->
        BoxWithConstraints(Modifier.fillMaxSize().background(Theme.reason)) {
            val count = Theme.columns((maxWidth - Theme.edgeSpacing * 2).value)
            LazyVerticalGrid(GridCells.Fixed(count), state = grid,
                contentPadding = PaddingValues(start = Theme.edgeSpacing, end = Theme.edgeSpacing, top = headerDp + 8.dp, bottom = 40.dp),
                horizontalArrangement = Arrangement.spacedBy(Theme.tileSpacing),
                verticalArrangement = Arrangement.spacedBy(20.dp),
                modifier = Modifier.fillMaxSize().navigationBarsPadding()) {
                val list = title
                if (list == null) items(count * 3, key = { "platzhalter$it" }) { TilePlaceholder() }
                else items(list, key = { it.id }) { k -> GridTileView(k) { open(Destination(k.id, k.title, k.type)) } }
            }
            if (disrupted) {
                EmptyState(Glyph.ServerRoute, translated("Server ist abgetaucht"),
                    translated("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", app.serverAddress()),
                    primaryButton = translated("Erneut versuchen") to { attempt++ })
            } else if (title?.isEmpty() == true) {
                EmptyState(Glyph.Tag, translated("Nichts in diesem Genre"),
                            translated("In diesem Genre gibt es auf deinem Server gerade keine Filme und Serien."))
            }
        }
    }
}
