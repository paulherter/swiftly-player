package de.paulherter.swiftly

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** Response of `Kern.person`; landscape images and titles are already settled there. */
data class PeopleState(val description: String?, val born: String?, val place: String?, val image: String?,
                         val banner: List<String>, val title: List<GridTile>, val tmdb: Int? = null,
                         /** The server did not answer the title list; not "no titles". */
                         val disrupted: Boolean = false)

internal fun personRead(json: String): PeopleState = JSONObject(json).let { o ->
    PeopleState(o.fieldText("beschreibung"), o.fieldText("geboren"), o.fieldText("ort"), o.fieldText("bild"),
                  o.fieldTexts("banner"), o.fieldList("titel") { gridTileRead(it) },
                  if (o.isNull("tmdb")) null else o.getInt("tmdb"),
                  o.optBoolean("gestoert", false))
}

/** "24. Juni 1962" in the device language: `Text(datum, format: .date(.long))`. */
private fun longDate(iso: String): String? =
    runCatching { LocalDate.parse(iso).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG)) }.getOrNull()

/**
 * Mirrors `PersonView` in `Sources/Shared/PersonView.swift`, narrow version.
 *
 * **Nothing jumps in later.** Image, name and role are there with the tap; birthday, place,
 * biography and titles fade in together once the server has answered. The two lines under the name
 * keep their place from the start; if they came later they pushed the name up. "Can be requested"
 * sits below once Seerr is connected, never above, or it would shift.
 */
@Composable
fun PersonPage(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit, back: () -> Unit) {
    var state by remember(target.id) { mutableStateOf(app.peopleCache[target.id]) }
    var attempt by remember(target.id) { mutableIntStateOf(0) }
    // **Without an answer, not placeholders forever**: the error was swallowed, the page stayed empty
    // and offered no "Erneut versuchen".
    var failed by remember(target.id) { mutableStateOf(false) }
    WatchStateChange(app) { attempt++ }
    LaunchedEffect(target.id, attempt) {
        failed = false
        try {
            val new = personRead(withContext(Dispatchers.IO) { app.kern.person(target.id).await() })
            state = new
            app.peopleCache[target.id] = new
        } catch (e: CancellationException) { throw e } catch (_: Exception) { failed = true }
    }
    val s = state
    // Seerr's filmography arrives later, minus what is already on the server under another name.
    var requestable by remember(target.id) { mutableStateOf<List<SeerrTile>?>(null) }
    val tmdb = s?.tmdb
    val seerrPresent = app.seerrConnected.value
    LaunchedEffect(tmdb, seerrPresent) {
        if (tmdb == null || !seerrPresent) return@LaunchedEffect
        val ownOnes = s?.title.orEmpty().mapTo(HashSet()) { it.title.lowercase() }
        requestable = try {
            seerrTilesRead(withContext(Dispatchers.IO) { app.kern.seerrFilmography(tmdb.toLong()).await() })
                .filter { it.title.lowercase() !in ownOnes }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() }
    }
    val seerrReady = requestable != null || !seerrPresent || (s != null && tmdb == null)
    val on by animateFloatAsState(if (s != null) 1f else 0f, Motion.reveal(), label = "person")

    // **The images do not change by themselves.** A loop every six seconds was the only thing that
    // moved on its own ("nothing moves decoratively"), and it ignored "reduce motion". It stays on
    // the first image.
    val banner = s?.banner.orEmpty()
    var wholeBiography by remember { mutableStateOf(false) }

    val scroll = rememberScrollState()
    val density = LocalDensity.current.density

    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        Column(Modifier.fillMaxSize().verticalScroll(scroll)) {
            Box(Modifier.fillMaxWidth().height(Theme.heroHeightValue)) {
                AsyncImage(model = banner.firstOrNull(), contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                HeroRunOut(Modifier.align(Alignment.BottomStart))
                // **One layout, not two:** a round head like the cast tile.
                Row(Modifier.align(Alignment.BottomStart).padding(horizontal = Theme.edgeSpacing).padding(bottom = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.Bottom) {
                    AsyncImage(model = s?.image, contentDescription = null, contentScale = ContentScale.Crop,
                        modifier = Modifier.size(76.dp).clip(CircleShape).background(Theme.area))
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(target.name, style = Theme.title, color = Theme.font,
                             maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Column(Modifier.alpha(on), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                            // Birthday and place at 12; 13 Regular is not a step.
                            val row = Theme.small
                            Text(s?.born?.let(::longDate)?.let { translated("Geboren %@", it) } ?: " ",
                                 style = row, color = Theme.fontQuiet, maxLines = 1)
                            Text(s?.place ?: " ", style = row, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }

            // The role comes with the tap and waits for nothing.
            val role = target.role
            val origin = target.origin
            if (!role.isNullOrEmpty() && origin != null) {
                Text(translated("%@ in %@", role, origin),
                     style = Theme.tile, color = Theme.accent, maxLines = 2,
                     modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 14.dp))
            }

            // Four lines, then "Mehr", so the biography does not push the titles away before one wants it.
            s?.description?.let { text ->
                Column(Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 14.dp).alpha(on),
                       verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(text, style = Theme.body.copy(lineHeight = 21.sp), color = Theme.fontQuiet,
                         maxLines = if (wholeBiography) Int.MAX_VALUE else 4, overflow = TextOverflow.Ellipsis,
                         modifier = Modifier.animateContentSize(tween(200, easing = EaseInOut)))
                    // The same "Mehr" as in the expandable text, hence the same size: 13 Medium.
                    Text(translated(if (wholeBiography) "Weniger" else "Mehr"),
                         style = Theme.tile, color = Theme.font,
                         modifier = Modifier.tapOn { wholeBiography = !wholeBiography })
                }
            }

            // While nothing is there, three placeholders in the shape of the row.
            if (s == null && failed) {
                DisturbHint(app.serverAddress(), spacingTop = 26.dp, retry = { attempt++ })
            } else if (s == null) {
                Row(Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = Theme.railsSpacing),
                    horizontalArrangement = Arrangement.spacedBy(Theme.tileSpacing)) {
                    repeat(3) { LoadField(Modifier.size(Theme.tileWidth, Theme.tileHeight)) }
                }
            }
            if (s != null) {
                if (s.title.isNotEmpty()) {
                    Box(Modifier.alpha(on)) {
                        Segment(translated("Auf deinem Server"), Theme.tileSpacing) {
                            tilesWithKey(s.title, { it.id }) { k -> GridTileView(k, Modifier.width(Theme.tileWidth)) { open(Destination(k.id, k.title, k.type)) } }
                        }
                    }
                }
                // Under the own server, so nothing shifts above it.
                requestable?.takeIf { it.isNotEmpty() }?.let { list ->
                    Segment(translated("Kann angefragt werden"), Theme.tileSpacing) {
                        tilesWithKey(list, { it.key }) { t ->
                            SeerrTileView(t, Modifier.width(Theme.tileWidth)) {
                                app.seerrHit[t.key] = t
                                open(Destination(t.key, t.title, "Seerrtitel"))
                            }
                        }
                    }
                }
                // **Failed is not empty.** "Nothing else with ... on your server" is a statement about the
                // inventory; if the server did not answer, nobody checked it. The error notice replaces only this
                // section, since image, name and biography are there.
                if (s.disrupted && s.title.isEmpty()) {
                    DisturbHint(app.serverAddress(), Modifier.alpha(on), spacingTop = 26.dp, retry = { attempt++ })
                } else if (s.title.isEmpty() && requestable.isNullOrEmpty() && seerrReady) {
                    Text(translated("Auf deinem Server gibt es sonst nichts mit %@.", target.name),
                         style = Theme.body, color = Theme.fontQuiet,
                         modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 26.dp).alpha(on))
                }
            }
            Spacer(Modifier.navigationBarsPadding().height(30.dp))
        }

        DetailHeader(target.name, { ((scroll.value / density - 150f) / 70f).coerceIn(0f, 1f) }, back)
    }
}
