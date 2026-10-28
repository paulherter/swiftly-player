package de.paulherter.swiftly

import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.IntrinsicSize
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import android.content.Intent
import android.net.Uri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.window.PopupProperties
import androidx.compose.ui.window.Popup
import androidx.compose.animation.core.MutableTransitionState
import coil3.compose.AsyncImage
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

data class Season(val id: String, val name: String)
data class EpisodesState(val id: String, val resume: Boolean, val remainingTime: String?, val progress: Double?,
                       val season: Int?, val episode: Int?, val since: Double? = null)
data class Episode(val id: String, val title: String, val subline: String?, val image: String?,
                 val progress: Double?, val watched: Boolean, val since: Double? = null,
                 /** Raw, for TV; `TvSeries` builds the catalog format "F2 · Title" from it. */
                 val name: String = "", val number: Int? = null,
                 val runtimeMin: Int? = null, val remainingTime: String? = null)

/** Reply from `Kern.series`; button text, season preselection and cast are already fixed there. */
data class Series(
    val id: String, val name: String, val year: String?, val seasonRow: String?, val seasonCount: Int?,
    val genres: String?, val headerImage: String?, val rating: Double?, val sharing: String?,
    val description: String?, val remembered: Boolean, val watched: Boolean, val trailer: String?,
    val planPresent: Boolean, val lossless: Boolean, val method: String?,
    val state: EpisodesState?, val buttonText: String, val seasons: List<Season>, val selected: String?,
    val actors: List<WithAct>,
    /** TV only, see `Tile.backdrop`. */
    val backdrop: String? = null,
    /** Title logo if the server has one, see `TitleMark`. */
    val logo: String? = null,
) {
    /**
     * Year · seasons · genres. **A single season is shown by its name**, not as "1 season"; next
     * to "Play S2 · E1" that read like a contradiction.
     */
    val secondaryLine: String
        get() = listOfNotNull(year, seasonRow ?: seasonCount?.let { translated("%lld Staffeln", it) }, genres)
            .joinToString(" · ")
}

internal fun seriesRead(json: String): Series = JSONObject(json).let { o ->
    Series(o.getString("id"), o.getString("name"), o.fieldText("jahr"), o.fieldText("staffelzeile"),
          if (o.isNull("staffelzahl")) null else o.getInt("staffelzahl"),
          o.fieldText("gattungen"), o.fieldText("kopfbild"), o.fieldNumber("bewertung"), o.fieldText("freigabe"),
          o.fieldText("beschreibung"), o.optBoolean("gemerkt"), o.optBoolean("gesehen"), o.fieldText("trailer"),
          o.optBoolean("planDa"), o.optBoolean("lossless"), o.fieldText("methode"),
          o.optJSONObject("stand")?.let { s ->
              EpisodesState(s.getString("id"), s.optBoolean("fortsetzen"), s.fieldText("restzeit"), s.fieldNumber("fortschritt"),
                          if (s.isNull("staffel")) null else s.getInt("staffel"), if (s.isNull("folge")) null else s.getInt("folge"), s.fieldNumber("ab"))
          },
          o.optString("knopftext"),
          o.fieldList("staffeln") { Season(it.getString("id"), it.getString("name")) },
          o.fieldText("gewaehlt"),
          o.fieldList("darsteller") { WithAct(it.getString("id"), it.getString("name"), it.fieldText("rolle"), it.fieldText("bild")) },
          if (o.has("kulisse")) o.fieldText("kulisse") else null, o.fieldText("logo"))
}

internal fun episodesRead(json: String): List<Episode> = JSONArray(json).let { a ->
    (0 until a.length()).map { i ->
        a.getJSONObject(i).let { f ->
            Episode(f.getString("id"), f.getString("titel"), f.fieldText("unterzeile"), f.fieldText("bild"), f.fieldNumber("fortschritt"), f.optBoolean("gesehen"), f.fieldNumber("ab"),
                  f.optString("name"), if (f.isNull("nummer")) null else f.getInt("nummer"),
                  if (f.isNull("laufzeitMin")) null else f.getInt("laufzeitMin"), f.fieldText("restzeit"))
        }
    }
}

/**
 * Mirrors iOS `SeriesDetailView` (narrow variant) and `SeasonTarget`: when an episode comes in,
 * the facade looks up its series and preselects its season.
 * **The core of the page is the single button**: Jellyfin's NextUp answers "episode in progress"
 * and "next unwatched" in one go. From the cache the page appears immediately.
 */
@Composable
fun SeriesPage(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit, back: () -> Unit) {
    var series by remember(target.id) { mutableStateOf(app.seriesCache[target.id]) }
    var season by remember(target.id) { mutableStateOf(series?.selected) }
    var episodes by remember(target.id) { mutableStateOf(season?.let { app.episodesCache[it] }.orEmpty()) }
    /** Chosen by hand; a reload no longer corrects the season. */
    var selfSelected by remember(target.id) { mutableStateOf(false) }
    var similar by remember(target.id) { mutableStateOf<List<GridTile>?>(null) }
    var similarDisturbed by remember(target.id) { mutableStateOf(false) }
    var extras by remember(target.id) { mutableStateOf<List<Extra>>(emptyList()) }
    // Without remembered episodes the placeholders show from the first frame, not only after the fetch.
    var episodesLoads by remember(target.id) { mutableStateOf(episodes.isEmpty()) }
    var episodesDisturbed by remember(target.id) { mutableStateOf(false) }
    var remembered by remember(target.id) { mutableStateOf(series?.remembered ?: false) }
    var watched by remember(target.id) { mutableStateOf(series?.watched ?: false) }
    var tab by rememberSaveable(target.id) { mutableIntStateOf(0) }
    var listOpen by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    /** The schedule arrives after the page; until then the badge row keeps its place. */
    var planLoaded by remember(target.id) { mutableStateOf(series?.planPresent == true) }
    /** The series itself did not arrive: it used to show "Loading…" forever without "Try again". */
    var seriesDisturbed by remember(target.id) { mutableStateOf(false) }
    val section = rememberCoroutineScope()
    val context = LocalContext.current
    val jerk = rememberJerk()

    suspend fun episodesLoad(seriesIdentifier: String, seasonIdentifier: String) {
        episodesLoads = true
        try {
            val new = episodesRead(withContext(Dispatchers.IO) { app.kern.episodes(seriesIdentifier, seasonIdentifier).await() })
            app.episodesCache[seasonIdentifier] = new
            if (season == seasonIdentifier) episodes = new
            episodesDisturbed = false
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
            if (season == seasonIdentifier) episodesDisturbed = true
        } finally { episodesLoads = false }
    }

    suspend fun planLoad(episodeIdentifier: String) {
        try {
            val o = JSONObject(withContext(Dispatchers.IO) { app.kern.plan(episodeIdentifier).await() })
            val new = series?.copy(planPresent = o.has("methode"), lossless = o.optBoolean("lossless"), method = o.fieldText("methode"))
            if (new != null) { series = new; app.seriesCache[target.id] = new }
            planLoaded = true
        } catch (e: CancellationException) { throw e } catch (_: Exception) { planLoaded = true }
    }

    /** **One load for everything**, also after "Mark season watched"; a separate refresh once forgot the schedule on iOS. */
    suspend fun load() {
        try {
            // Similar titles arrive in the same step as the series (iOS `SeriesDetailView.load`); loading
            // them only after series and episodes made the bottom shift.
            // `null`: the fetch failed.
            val (hasRead, surroundings) = coroutineScope {
                val a = async(Dispatchers.IO) { app.kern.series(target.id).await() }
                val b = async(Dispatchers.IO) {
                    try {
                        val o = JSONObject(app.kern.titleField(target.id).await())
                        o.fieldList("aehnliche") { gridTileRead(it) } to
                            o.fieldList("extras") { Extra(it.getString("id"), it.getString("name"), it.fieldText("bild"), it.fieldText("laufzeit")) }
                    }
                    catch (e: CancellationException) { throw e } catch (_: Exception) { null }
                }
                seriesRead(a.await()) to b.await()
            }
            // Keep the already known schedule until the new one arrives, or the badge row flickers.
            val alt = series
            val new = if (alt != null && alt.state?.id == hasRead.state?.id)
                hasRead.copy(planPresent = alt.planPresent, lossless = alt.lossless, method = alt.method) else hasRead
            val choice = if (!selfSelected || season == null) new.selected else season
            // **One fade-in, not two.** If no episode is there yet, series and episodes arrive in the same
            // frame; before, the series showed first with placeholders and the list then shrank to the
            // episodes. If the prefetch fails, `episodesLoad` loads afterwards as before.
            val preOff = if (episodes.isEmpty() && choice != null && app.episodesCache[choice] == null) try {
                episodesRead(withContext(Dispatchers.IO) { app.kern.episodes(new.id, choice).await() })
            } catch (e: CancellationException) { throw e } catch (_: Exception) { null } else null
            series = new
            app.seriesCache[target.id] = new
            // Fetch the schedule only now: `planLoad` writes into `series`. Started earlier, `series` was still
            // empty on first open (the episode fetch runs before), the result was lost and the badge missing.
            new.state?.let { st -> section.launch { planLoad(st.id) } } ?: run { planLoaded = true }
            similarDisturbed = surroundings == null
            surroundings?.let { similar = it.first; extras = it.second; if (it.second.isEmpty() && tab == 3) tab = 0 }
            remembered = new.remembered
            watched = new.watched
            if (!selfSelected || season == null) season = choice
            if (preOff != null && choice != null && season == choice) {
                app.episodesCache[choice] = preOff
                episodes = preOff
                episodesDisturbed = false
                episodesLoads = false
            } else season?.let { s -> if (episodes.isEmpty()) app.episodesCache[s]?.let { episodes = it }; episodesLoad(new.id, s) }
            seriesDisturbed = false
        } catch (e: CancellationException) { throw e } catch (_: Exception) { seriesDisturbed = series == null }
    }

    /** Switch first, then ask; if the server says no, revert and report. Then reload: the button shows a different episode. */
    fun episodeToggle(f: Episode) {
        val an = !f.watched
        jerk(Jerk.Lightweight)
        episodes = episodes.map { if (it.id == f.id) it.copy(watched = an, progress = if (an) null else it.progress) else it }
        section.launch {
            val reason = withContext(Dispatchers.IO) { app.kern.watched(f.id, an).await() }
            if (reason.isNotEmpty()) {
                message = errorString(reason)
                episodes = episodes.map { if (it.id == f.id) f else it }
            } else load()
        }
    }

    // Reload after watching: the button now shows a different episode.
    val playsNow = app.play.value != null
    var hasPlay by remember { mutableStateOf(false) }
    LaunchedEffect(playsNow) { if (playsNow) hasPlay = true else if (hasPlay) { hasPlay = false; load() } }
    // And again once the end report is through; only then does the server know the position.
    // Also after a watch-state change (tile menu), like `pagesRefresh` on iOS.
    val ended = app.playbackEnded.intValue + app.watchStateChanged.intValue
    val endedInitial = remember { ended }
    LaunchedEffect(ended) { if (ended != endedInitial) load() }

    LaunchedEffect(target.id) { load() }

    val scroll = rememberScrollState()
    // Scrolling closes the season list; a tap on the pill itself does not.
    LaunchedEffect(scroll) { snapshotFlow { scroll.isScrollInProgress }.collect { if (it) listOpen = false } }
    val density = LocalDensity.current.density
    val s = series
    val name = s?.name ?: target.name

    fun toggle(an: Boolean, setDown: (Boolean) -> Unit, question: suspend (String, Boolean) -> String) {
        val id = s?.id ?: return
        jerk(Jerk.Lightweight)
        setDown(an)
        section.launch {
            val reason = withContext(Dispatchers.IO) { question(id, an) }
            if (reason.isNotEmpty()) { setDown(!an); message = errorString(reason) }
            else app.seriesCache.remove(target.id)
        }
    }

    fun trailerStart() {
        val address = s?.trailer
        val went = address != null && runCatching {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(address)))
        }.isSuccess
        if (!went) message = translated("Für diesen Titel liegt kein Trailer vor.")
    }

    // **The header image's colour under the page**, as on the film page (`MoodReason`).
    val mood = rememberImageAudio(s?.headerImage)
    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        CompositionLocalProvider(LocalImageColor provides true, LocalImageAudio provides mood.tones) {
        Column(Modifier.fillMaxSize().verticalScroll(scroll).moodReason(mood, Theme.heroHeightValue)) {
            Hero(s?.headerImage, name, s?.secondaryLine.orEmpty(), mood,
                 logo = if (app.settings.titleAsLogo) s?.logo else null)

            Column(Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 14.dp),
                   verticalArrangement = Arrangement.spacedBy(14.dp)) {
                ProofRow(s != null && planLoaded, s?.planPresent == true, s?.lossless == true, s?.method, s?.rating, s?.sharing)

                // Always exactly one button. While loading it looks ready and says "Loading…"; disabled only
                // once it is certain there is no episode. The player follows.
                // Button and action row form one block: 8 between them, 14 to everything else.
                Column(Modifier.padding(bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
                    val menu = LocalTileMenu.current
                    PlayButton(Glyph.Play, s?.buttonText ?: translated("Lädt…"),
                               an = s == null || s.state != null, main = true,
                               // Long press: the series' tile menu, as on its tile.
                               lengthy = menu?.let { m -> {
                                   m(TileMenuRequest(target.id, name, "Series", s?.headerImage, landscape = true,
                                                        s?.secondaryLine, afterwards = { section.launch { load() } }))
                               } }) {
                        s?.state?.let { st -> jerk(Jerk.Medium); app.play.value = PlayRequest(st.id, st.since) }
                    }
                    s?.state?.remainingTime?.let { Text(it, style = Theme.small, color = Theme.fontQuiet) }
                    s?.state?.progress?.takeIf { it > 0 }?.let { ProgressBar(it, Modifier.clip(RoundedCornerShape(2.dp))) }
                    if (seriesDisturbed && s == null) DisturbHint(app.serverAddress(), spacingTop = 12.dp,
                        retry = { seriesDisturbed = false; section.launch { load() } })
                }

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (app.settings.watchlist) {
                        ActionButton(if (remembered) Glyph.BookmarkFilled else Glyph.Bookmark, translated("Merkliste"), remembered) {
                            toggle(!remembered, { remembered = it }) { id, an -> app.kern.remember(id, an).await() }
                        }
                    }
                    // **Download sits in the row, not in a hidden chip**, between Save and Watched, and always via
                    // the load selection, also for a season: single episodes must always be selectable. The trailer
                    // moves to the More sheet for it. With downloads off, it keeps its place.
                    if (app.settings.downloadButtonShow) {
                        ActionButton(Glyph.ArrowDown, translated("Laden"), false) {
                            s?.let { loadSelectionShow(app, it.id, it.name, it.seasons) }
                        }
                    } else {
                        ActionButton(Glyph.Film, translated("Trailer"), false) { trailerStart() }
                    }
                    ActionButton(if (watched) Glyph.CheckmarkCircleFilled else Glyph.CheckmarkCircle, translated("Gesehen"), watched) {
                        toggle(!watched, { watched = it }) { id, an -> app.kern.watched(id, an).await() }
                    }
                    // "Senden an", only while a TV running Swiftly is in reach (`PlayOn.kt`).
                    if (app.playTargets.value.isNotEmpty()) {
                        ActionButton(Glyph.Tv, translated("Senden an …"), false) { app.sendToShow(target.id, "Series", name) }
                    }
                    ActionButton(Glyph.More, translated("Mehr"), false) {
                        val selectedSeason = s?.seasons?.firstOrNull { it.id == season }
                        // `TitleActions.forSeries`.
                        val entries = buildList {
                            // The trailer, when Download has its place in the row; not twice.
                            if (app.settings.downloadButtonShow) add(Choice("trailer", translated("Trailer")))
                            s?.state?.let {
                                add(Choice("vonvorn", translated("Folge von vorn abspielen")))
                                // **"Next episode" yields to "Watch together"**: the sheet should not get longer, and the next
                                // episode is reachable via the list.
                                if (app.gemeinsam.value.mayCreate) add(Choice("gemeinsam", translated("Gemeinsam schauen")))
                                else add(Choice("naechste", translated("Nächste Folge abspielen")))
                            }
                            add(Choice("zufaellig", translated("Zufällig abspielen")))
                            selectedSeason?.let { add(Choice("staffel", translated("%@ als gesehen", it.name))) }
                            add(Choice("metadaten", translated("Metadaten neu einlesen")))
                        }
                        // Translated: German "F" for Folge, English "E" for episode. This was hard-coded as "E",
                        // also in German.
                        val abbreviation = s?.state?.let { st -> if (st.season != null && st.episode != null) " · " + translated("S%d F%d", st.season, st.episode) else "" }.orEmpty()
                        app.sheet.value = SheetRequest(name + abbreviation, entries, null,
                            mapOf("trailer" to Glyph.Film, "vonvorn" to Glyph.Rewind, "naechste" to Glyph.Skip, "zufaellig" to Glyph.Shuffle, "staffel" to Glyph.CheckmarkCircle,
                                  "gemeinsam" to Glyph.Cluster, "metadaten" to Glyph.Reload)) { choice ->
                            if (choice == "gemeinsam") {
                                s?.state?.let { st -> section.launch { kotlinx.coroutines.delay(SheetSwitch)
                                    sharedCreateOpen(app, st.id, if (st.season != null && st.episode != null) sharedTitleRow("", s.name, st.season, st.episode) else s.name) } }
                                return@SheetRequest
                            }
                            section.launch {
                                when (choice) {
                                    "trailer" -> trailerStart()
                                    "vonvorn" -> s?.state?.let { st -> app.play.value = PlayRequest(st.id, null) }
                                    // Without a next episode, report it rather than silently doing nothing.
                                    "naechste" -> s?.state?.let { st ->
                                        val afterThat = withContext(Dispatchers.IO) { app.kern.episodeAfter(st.id, s.id).await() }
                                        if (afterThat.isNotEmpty()) app.play.value = PlayRequest(afterThat, null)
                                        else message = translated("Danach kommt nichts mehr.")
                                    }
                                    // Mixes all episodes once (`ShuffleRun` in the package); "Next episode" in the player follows it.
                                    "zufaellig" -> {
                                        val first = withContext(Dispatchers.IO) { app.kern.shuffleStart(s?.id ?: return@withContext "").await() }
                                        if (first.isNotEmpty()) app.play.value = PlayRequest(first, 0.0)
                                        else message = translated("Die Folge konnte nicht geladen werden.")
                                    }
                                    "staffel" -> selectedSeason?.let { st ->
                                        val reason = withContext(Dispatchers.IO) { app.kern.watched(st.id, true).await() }
                                        if (reason.isNotEmpty()) message = errorString(reason)
                                        else { message = translated("%@ ist als gesehen vermerkt.", st.name); load() }
                                    }
                                    "metadaten" -> {
                                        val id = s?.id ?: return@launch
                                        val reason = withContext(Dispatchers.IO) { app.kern.metadataRefresh(id).await() }
                                        message = if (reason.isEmpty()) translated("Der Server liest die Metadaten neu ein.") else errorString(reason)
                                    }
                                }
                            }
                        }
                    }
                }
                }
                s?.description?.let { CollapsibleText(it) }
            }

            Spacer(Modifier.height(22.dp))
            PageTab(listOfNotNull(translated("Folgen"), translated("Besetzung"), translated("Ähnliches"), if (extras.isNotEmpty()) translated("Extras") else null), tab) { tab = it }

            Crossfade(tab, animationSpec = tween(160), label = "reiter") { r ->
                when (r) {
                    0 -> Column {
                        // **No placeholders** (as on iOS): while the series loads, the season button is invisible and
                        // keeps its height; it fades in at its place.
                        val headerPresent = s?.seasons?.isNotEmpty() == true
                        val headerVisibility by animateFloatAsState(if (headerPresent) 1f else 0f, Motion.reveal(), label = "staffelkopf")
                        if (headerPresent || s == null) Box(Modifier.alpha(headerVisibility)) {
                            SeasonHeader(s?.seasons.orEmpty(), season, listOpen, { listOpen = it }) { new ->
                                selfSelected = true
                                if (new != season) {
                                    season = new
                                    episodes = app.episodesCache[new].orEmpty()
                                    s?.id?.let { id -> section.launch { episodesLoad(id, new) } }
                                }
                            }
                        }
                        // No lines between episodes: the image carries the row, 12 above and below.
                        // While loading the area stays empty: never "No episodes", never placeholders.
                        if (episodesDisturbed) DisturbHint(app.serverAddress(), retry = { s?.id?.let { id -> season?.let { st -> section.launch { episodesLoad(id, st) } } } })
                        else if (episodes.isEmpty() && !episodesLoads && s != null && s.seasons.isNotEmpty()) EmptyHint(translated("Keine Folgen in dieser Staffel"))
                        val episodesVisibility by animateFloatAsState(if (episodes.isNotEmpty()) 1f else 0f, Motion.reveal(), label = "folgen")
                        Column(Modifier.alpha(episodesVisibility)) { episodes.forEachIndexed { i, f ->
                            // Swipe toggles watched; `SwipeRow` with tick or back arrow.
                            key(f.id) {
                                SwipeRow(if (f.watched) Glyph.Undo else Glyph.Checkmark,
                                           translated(if (f.watched) "Ungesehen" else "Gesehen"), perform = { episodeToggle(f) }) {
                                    // **Long press: the tile menu**, as on every other episode (`TileMenu`): play,
                                    // watched/unwatched, download, watch together.
                                    val menu = LocalTileMenu.current
                                    val lengthy: (() -> Unit)? = menu?.let { m -> {
                                        m(TileMenuRequest(f.id, f.title, "Episode", f.image, landscape = true, f.subline,
                                                             afterwards = { section.launch { load() } }))
                                    } }
                                    EpisodesRow(f, lengthy = lengthy) { app.play.value = PlayRequest(f.id, f.since) }
                                }
                            }
                        } }
                    }
                    1 -> {
                        val folks = s?.actors.orEmpty()
                        if (s != null && folks.isEmpty()) EmptyHint(translated("Keine Besetzung hinterlegt."))
                        else Grid(folks, columns = { width -> maxOf(1, ((width + 14f) / (84f + 14f)).toInt()) }, spacing = 14) { p ->
                            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                                CastTile(p) { open(Destination(p.id, p.name, "Person", p.role, name)) }
                            }
                        }
                    }
                    3 -> Grid(extras, columns = { width -> maxOf(1, ((width + 12f) / (210f + 12f)).toInt()) }, spacing = 12) { x ->
                        ExtraTile(x) { jerk(Jerk.Medium); app.play.value = PlayRequest(x.id, null) }
                    }
                    else -> {
                        val list = similar
                        if (similarDisturbed && list.isNullOrEmpty()) DisturbHint(app.serverAddress())
                        else if (list != null && list.isEmpty()) EmptyHint(translated("Nichts Ähnliches gefunden."))
                        else Grid(list.orEmpty(), columns = { Theme.columns(it) }, spacing = 12) { k ->
                            GridTileView(k) { open(Destination(k.id, k.title, k.type)) }
                        }
                    }
                }
            }
            Spacer(Modifier.navigationBarsPadding().height(24.dp))
        }
        }

        DetailHeader(name, { ((scroll.value / density - 150f) / 70f).coerceIn(0f, 1f) }, back)
        HintStrip(message, Modifier.align(Alignment.BottomCenter)) { message = null }
    }
}

/** Mirrors `Reiter` in `Style.swift`: spacing 26, 15 pt, active semibold with 2 pt accent below, hairline at the bottom. */
@Composable
private fun PageTab(title: List<String>, selected: Int, select: (Int) -> Unit) {
    Box(Modifier.fillMaxWidth().drawBehind {
        drawRect(Theme.line, topLeft = Offset(0f, size.height - 1.dp.toPx()), size = Size(size.width, 1.dp.toPx()))
    }) {
        Row(Modifier.padding(horizontal = Theme.edgeSpacing), horizontalArrangement = Arrangement.spacedBy(26.dp)) {
            title.forEachIndexed { i, t ->
                val an = i == selected
                // **Selected means white, no weight change:** semibold is wider than regular, and in a
                // **horizontal** row every neighbour to the right would shift. The accent line below stays;
                // it carries state.
                Text(t, style = Theme.listTitle,
                     color = if (an) Theme.font else Theme.fontQuiet,
                     modifier = Modifier.tapOn { select(i) }
                         .semantics { this.selected = an; role = Role.Tab }
                         .drawBehind {
                             // White, not accent: selected is ranking, not state.
                             if (an) drawRect(Theme.font, topLeft = Offset(0f, size.height - 2.dp.toPx()), size = Size(size.width, 2.dp.toPx()))
                         }
                         .padding(bottom = 11.dp))
            }
        }
    }
}

/**
 * Mirrors `ExpandList`: season name in row type, arrow only from two seasons. The list grows
 * from top left, 200 wide, 44 below the pill, and sits above the episodes.
 */
@Composable
internal fun SeasonHeader(seasons: List<Season>, selected: String?, opened: Boolean, setOpen: (Boolean) -> Unit,
                         compact: Boolean = false, select: (String) -> Unit) {
    val multiple = seasons.size > 1
    val rotation by animateFloatAsState(if (opened) 180f else 0f, Motion.leap(), label = "pfeil")
    // **A tap on the pill only closes the open list.** It arrived twice: the popup first closed it
    // as a tap outside, then the pill reopened it in the same step (fixed on iOS).
    val closedAround = remember { longArrayOf(0L) }
    // **Compact** in the player's episode layer (mirrors `ExpandList(font: meta + 1, height: 28)`):
    // in place of the meta line, without its own margin; the layer header provides that.
    // `ExpandList(asField:)`: on the series page a field, 34 high, `area`, corner 8, 11 inside,
    // 15 semibold; in the player no surface, 28 high, in meta type.
    val height = if (compact) 28.dp else 34.dp
    Box(if (compact) Modifier.zIndex(10f) else Modifier.fillMaxWidth().zIndex(10f).padding(start = Theme.edgeSpacing, top = 14.dp, bottom = 14.dp)) {
        Row(Modifier.tapOn { if (multiple && android.os.SystemClock.uptimeMillis() - closedAround[0] > 300) setOpen(!opened) }
                .heightIn(min = height)
                .then(if (compact) Modifier else Modifier.clip(RoundedCornerShape(Theme.cornerSmall)).background(buttonArea(LocalImageColor.current)).padding(horizontal = 11.dp)),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            Text(seasons.firstOrNull { it.id == selected }?.name ?: translated("Staffel"),
                 style = if (compact) Theme.small.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold) else Theme.listTitle,
                 color = Theme.font)
            if (multiple) Symbol(Glyph.AngleDown, 11.dp, Modifier.graphicsLayer { rotationZ = rotation },
                                color = Theme.fontVeryQuiet, strength = Strength.Semibold, description = translated("Öffnet die Auswahl"))
        }
        // **Above the episodes, not between them.** A popup has no height in the page and stays
        // tappable; a drawing outside the header row would get no taps.
        val condition = remember { MutableTransitionState(false) }
        condition.targetState = opened
        if (condition.currentState || condition.targetState) {
            val density = LocalDensity.current
            // 16 margin in the popup for the motion; the list sits 6 below the field.
            val margin = with(density) { 16.dp.roundToPx() }
            val bottom = with(density) { (height + 6.dp).roundToPx() }
            Popup(offset = IntOffset(-margin, bottom - margin), onDismissRequest = { closedAround[0] = android.os.SystemClock.uptimeMillis(); setOpen(false) },
                  properties = PopupProperties(focusable = false)) {
                AnimatedVisibility(condition, Modifier.padding(16.dp),
                    enter = fadeIn(Motion.leap()) + scaleIn(Motion.leap(), initialScale = 0.94f, transformOrigin = TransformOrigin(0f, 0f)),
                    exit = fadeOut(Motion.leap()) + scaleOut(Motion.leap(), targetScale = 0.94f, transformOrigin = TransformOrigin(0f, 0f))) {
                // **As wide as the longest name, at least 180**; a fixed 200 left a gap on the right.
                // Corner 10, no shadows.
                // **Over an image colour, in the page's colour:** opaque because episodes sit below, but in the
                // page's tone at this spot, with the white of the other surfaces on top. A fixed grey looked
                // foreign.
                val tones = LocalImageAudio.current
                val reason = if (LocalImageColor.current && tones.isNotEmpty()) remember(tones) { imageColor(tones, 0.2, 0.55) } else null
                Column(Modifier.width(IntrinsicSize.Max).widthIn(min = 180.dp).clip(RoundedCornerShape(Theme.corner))
                        .background(Theme.area).then(if (reason != null) Modifier.background(reason).background(surfaceTranslucent) else Modifier)) {
                    seasons.forEach { st ->
                        val an = st.id == selected
                        // Tick on the left, always reserved; selected white, otherwise quiet: 15 semibold, 14/9 inside.
                        Row(Modifier.fillMaxWidth().pressRow { setOpen(false); select(st.id) }.padding(horizontal = 14.dp, vertical = 9.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Box(Modifier.width(18.dp), contentAlignment = Alignment.Center) {
                                if (an) Symbol(Glyph.Checkmark, 15.dp, color = Theme.font, strength = Strength.Semibold)
                            }
                            Text(st.name, style = Theme.listTitle, color = if (an) Theme.font else Theme.fontQuiet, maxLines = 1)
                        }
                    }
                }
                }
            }
        }
    }
}

/**
 * Mirrors `EpisodesRow`: image 116 × 65, title "3. Name" on two lines, remaining or total time below.
 * **Watched steps back** instead of disappearing: image and title dimmed, tick on the image.
 * Bar and tick together would be the same information twice.
 */
@Composable
internal fun EpisodesRow(f: Episode, end: (@Composable () -> Unit)? = null, lengthy: (() -> Unit)? = null, perform: () -> Unit) {
    EpisodesRowsLayout(if (lengthy != null) Modifier.pressRowLong(lengthy, perform) else Modifier.pressRow(perform), f.title, f.subline, if (f.watched) Theme.fontQuiet else Theme.font, end = end) {
        // **Watched only gets darker, not transparent** (`Gesehenhaken`, `colorMultiply`): with opacity
        // the background shone through, and on a page in image colour every watched still took on its tint.
        Box(Modifier.size(116.dp, 65.dp).clip(RoundedCornerShape(Theme.cornerTile)).background(Theme.area)) {
            AsyncImage(model = f.image, contentDescription = null, contentScale = ContentScale.Crop,
                       colorFilter = if (f.watched) WATCHED_DIM else null, modifier = Modifier.fillMaxSize())
            // Bar and tick together would be the same information twice.
            if (!f.watched) f.progress?.takeIf { it > 0 }?.let { ProgressBar(it, Modifier.align(Alignment.BottomStart)) }
            if (f.watched) WatchedCheckmark()
        }
    }
}

/** Mirrors iOS `EpisodesRowsLayout`, the layout of an episode row; on iOS the season view's placeholder shares it. */
@Composable
private fun EpisodesRowsLayout(modifier: Modifier, title: String, subline: String?, titleColor: Color,
                               end: (@Composable () -> Unit)? = null, image: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().then(modifier).padding(horizontal = Theme.edgeSpacing, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        image()
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            // Row with image: title 15 semibold, subline 12.
            // **Single line**, or the rows of a season would end at different heights.
            Text(title, style = Theme.listTitle, color = titleColor, maxLines = 1, overflow = TextOverflow.Ellipsis)
            subline?.let { Text(it, style = Theme.small, color = Theme.fontVeryQuiet, maxLines = 1) }
        }
        end?.let { Box(Modifier.align(Alignment.CenterVertically)) { it() } }
    }
}

/** Grid in a scrolling page: no own scroll surface, columns from the width. */
@Composable
private fun <T> Grid(entries: List<T>, columns: (Float) -> Int, spacing: Int, cell: @Composable (T) -> Unit) {
    BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing).padding(top = 20.dp)) {
        val count = columns(maxWidth.value)
        Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
            entries.chunked(count).forEach { rail ->
                Row(horizontalArrangement = Arrangement.spacedBy(spacing.dp)) {
                    rail.forEach { Box(Modifier.weight(1f)) { cell(it) } }
                    repeat(count - rail.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

@Composable
private fun EmptyHint(text: String) {
    Text(text, style = Theme.body.copy(textAlign = TextAlign.Center), color = Theme.fontVeryQuiet,
         modifier = Modifier.fillMaxWidth().padding(top = 40.dp, start = Theme.edgeSpacing, end = Theme.edgeSpacing))
}
