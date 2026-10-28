package de.paulherter.swiftly.tv

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.*
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Mirrors tvOS `SeriesView`. **No tabs**: episodes, cast and similar titles stack like the rows of
 * the home page. Episodes are a horizontal strip of landscape tiles like "Continue watching"; the
 * season changes via a row of chips between the row title and the strip (`TvSeasonChips`).
 * **The first focus belongs to the main button, not to an episode.** The header is the same as on
 * the film page (`TvDetailHeader` in `TvTitle.kt`), otherwise the two pages drift apart again.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TvSeries(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit) {
    var s by remember(target.id) { mutableStateOf(app.seriesCache[target.id]) }
    val playsNow = app.play.value != null
    val run = rememberCoroutineScope()
    var season by remember(target.id) { mutableStateOf(s?.selected) }
    /** Chosen by hand: then no reload corrects the season anymore (as in `SeriesPage`). */
    var selfSelected by remember(target.id) { mutableStateOf(false) }
    var episodes by remember(target.id) { mutableStateOf(season?.let { app.episodesCache[it] }.orEmpty()) }
    // Separate from empty: "No episodes in this season" applies only once the server has really
    // answered, otherwise the hint flashes before the first response (`SeriesView.loadsEpisodes` on
    // tvOS). With remembered episodes the space is there from the first frame.
    var loadsEpisodes by remember(target.id) { mutableStateOf(episodes.isEmpty()) }
    /** The series did not arrive on first load; before, "Loading…" never ended. */
    var disrupted by remember(target.id) { mutableStateOf(false) }
    var similar by remember(target.id) { mutableStateOf<List<GridTile>>(emptyList()) }
    var extras by remember(target.id) { mutableStateOf<List<Extra>>(emptyList()) }

    // **The plan arrives later, as on the phone** (`SeriesPage.planLoad`): `Kern.series` does not
    // deliver it, because `PlaybackInfo` takes seconds for a freshly probed file and the whole page
    // would wait. Without this follow-up the Direct Play badge in the header was always off on TV
    // (`planPresent` stayed `false`).
    fun planAccept(json: String?) {
        val o = json?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return
        s?.let { alt ->
            val new = alt.copy(planPresent = o.has("methode"), lossless = o.optBoolean("lossless"), method = o.fieldText("methode"))
            s = new; app.seriesCache[target.id] = new
        }
    }
    /** Only for a manual season change; the first load fetches the episodes in `load`. */
    suspend fun episodesLoad(sid: String, stf: String) {
        if (episodes.isEmpty()) loadsEpisodes = true
        try {
            val new = episodesRead(withContext(Dispatchers.IO) { app.kern.episodes(sid, stf).await() })
            app.episodesCache[stf] = new
            if (season == stf) episodes = new
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
        finally { loadsEpisodes = false }
    }
    /**
     * **One load, one fade-in** (mirrors iOS `SeriesDetailView.load` and phone `SeriesPage.load`).
     * Series with state and seasons, similar titles and the chosen season's episodes arrive together
     * and appear in the same frame. Before, the page set each response separately: first header and
     * cast, then the episodes, and finally "Similar" slid in below. The plan runs alongside and only
     * sets the badge in the header, whose space is already there. If one part fails, its old state
     * stays.
     */
    suspend fun load() {
        try {
            val (hasRead, surroundings) = coroutineScope {
                val a = async(Dispatchers.IO) { app.kern.series(target.id).await() }
                val b = async(Dispatchers.IO) {
                    try { app.kern.titleField(target.id).await() } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
                }
                seriesRead(a.await()) to b.await()
            }
            val alt = s
            // Keep the already known plan until the new one is there, otherwise the badge flickers.
            val new = if (alt != null && alt.state?.id == hasRead.state?.id)
                hasRead.copy(planPresent = alt.planPresent, lossless = alt.lossless, method = alt.method) else hasRead
            val plan = new.state?.let { st ->
                run.async(Dispatchers.IO) { try { app.kern.plan(st.id).await() } catch (e: CancellationException) { throw e } catch (_: Exception) { null } }
            }
            val choice = if (selfSelected && season != null) season else new.selected
            val fetched = choice?.let { w ->
                try { episodesRead(withContext(Dispatchers.IO) { app.kern.episodes(new.id, w).await() }) }
                catch (e: CancellationException) { throw e } catch (_: Exception) { null }
            }
            val newSimilar = surroundings?.let { runCatching { JSONObject(it).fieldList("aehnliche") { k -> gridTileRead(k) } }.getOrNull() }
            // From here without interruption: everything lands in the same frame.
            s = new
            app.seriesCache[target.id] = new
            newSimilar?.let { similar = it }
            surroundings?.let { u -> runCatching { JSONObject(u).fieldList("extras") { Extra(it.getString("id"), it.getString("name"), it.fieldText("bild"), it.fieldText("laufzeit")) } }.getOrNull() }?.let { extras = it }
            // If the user has chosen a season in the meantime, the list belongs to that choice.
            if (!selfSelected || season == null || season == choice) {
                season = choice
                if (fetched != null && choice != null) { app.episodesCache[choice] = fetched; episodes = fetched }
                loadsEpisodes = false
            }
            plan?.let { p -> run.launch { planAccept(p.await()) } }
            disrupted = false
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
            if (s != null) loadsEpisodes = false
            disrupted = s == null
        }
    }
    // Also after the end report: only then does the server know the position (`playbackEnded`).
    LaunchedEffect(target.id, playsNow, app.playbackEnded.intValue, app.watchStateChanged.intValue) {
        if (!playsNow) load()
    }
    val series = s
    // The running episode first: whoever keeps watching should not have to search for it.
    val strip = rememberLazyListState()
    LaunchedEffect(episodes, series?.state?.id) {
        val i = episodes.indexOfFirst { it.id == series?.state?.id }
        if (i > 0) strip.scrollToItem(i)
    }
    val main = firstFocus()
    // As `TvDetail`: until `Kern.series` answers, the header from the home page (`TvPreOff`).
    val preOff = remember(target.id) { TvHandoff.of(target.id) }
    val name = series?.name ?: preOff?.title ?: target.name
    // Backdrop and ground are drawn by `TvMain` (`TvBackdropsLayer`), same address as on home.
    TvBackdropReport(series?.let { it.backdrop ?: it.headerImage }, ready = series != null)

    // Mirrors `SeriesView.inFade` on tvOS, same approach as `TvDetail`: backdrop and header
    // info (title/details/description) show immediately, button row and rows fade in.
    // Why `rememberTvFadeIn` and not `animateFloatAsState`: see there (TvStyle.kt).
    val inFade = rememberTvFadeIn(target.id)
    val fadeInAlpha = { inFade.value }
    // Mirrors the `MainView.errorMessage` band, wired like on the phone (`SeriesPage.meldung`);
    // Android has no shared error source like `AppModel.errorMessage`, hence its own state.
    var message by remember { mutableStateOf<String?>(null) }

    Box(Modifier.fillMaxSize()) {
        TvSectionPage { a ->
                TvDetailHeader(name, if (series != null) series.year.orEmpty() else preOff?.details.orEmpty(),
                             if (series != null) series.rating else preOff?.rating,
                             if (series != null) series.sharing else preOff?.sharing,
                             if (series != null) series.description else preOff?.description,
                             directPlayFlag = series?.planPresent == true && series.lossless,
                             hint = if (series?.planPresent == true && !series.lossless) series.method else null,
                             buttonAlpha = fadeInAlpha, modifier = Modifier.tvSection(a, "kopf", TvSectionKind.Header),
                             logo = if (app.settings.titleAsLogo) series?.logo else null) {
                    // Never locked while loading: the button must stay a focus target.
                    // Mirrors `SeriesView.starte`: without a plan it reports instead of silently doing nothing.
                    val menu = de.paulherter.swiftly.LocalTileMenu.current
                    TvButton(series?.buttonText?.ifEmpty { null } ?: translated(if (disrupted) "Erneut versuchen" else "Lädt…"), Glyph.Play, Modifier.focusRequester(main),
                            // Long OK or the menu key: the series' tile menu, as on its tile.
                            lengthy = menu?.let { m -> {
                                m(de.paulherter.swiftly.TileMenuRequest(target.id, name, "Series", series?.let { it.backdrop ?: it.headerImage },
                                    true, series?.secondaryLine, afterwards = { run.launch { load() } }))
                            } }) {
                        if (series == null && disrupted) { disrupted = false; run.launch { load() }; return@TvButton }
                        val st = series?.state
                        if (st != null && series?.planPresent == true) app.play.value = PlayRequest(st.id, st.since)
                        else if (st != null) message = translated("Der Server hat keine Datei zu dieser Folge.")
                    }
                    series?.state?.takeIf { it.resume }?.let { st -> TvButton(null, Glyph.Rewind, description = translated("Von vorn abspielen")) {
                        if (series?.planPresent == true) app.play.value = PlayRequest(st.id, null)
                        else message = translated("Der Server hat keine Datei zu dieser Folge.")
                    } }
                    if (app.settings.watchlist) {
                        TvButton(null, if (series?.remembered == true) Glyph.BookmarkFilled else Glyph.Bookmark,
                                description = translated("Merkliste"), active = series?.remembered == true) {
                            val alt = series ?: return@TvButton
                            s = alt.copy(remembered = !alt.remembered)
                            // Like "Watched": roll back **and report**.
                            run.launch {
                                val reason = withContext(Dispatchers.IO) { app.kern.remember(alt.id, !alt.remembered).await() }
                                if (reason.isNotEmpty()) { s = alt; message = errorString(reason) }
                            }
                        }
                    }
                    // **`TvMoreButton` instead of `app.sheet`**: on tvOS the menu opens directly under the button,
                    // not as a panel at the right edge (see the doc comment in `TvTitle.kt`).
                    val alt = series
                    if (alt != null) {
                        val selectedSeason = alt.seasons.firstOrNull { it.id == season }
                        // `TitleActions.forSeries`: "Watched" first (from the button row, see `gesehenHandlung`),
                        // then episode/season actions, metadata last.
                        val entries = buildList {
                            add(Choice("gesehen", translated(if (alt.watched) "Als ungesehen merken" else "Als gesehen merken")))
                            alt.state?.let {
                                add(Choice("vonvorn", translated("Folge von vorn abspielen")))
                                // **"Next episode" gives way to "Watch together"**.
                                if (app.gemeinsam.value.mayCreate) add(Choice("gemeinsam", translated("Gemeinsam schauen")))
                                else add(Choice("naechste", translated("Nächste Folge abspielen")))
                            }
                            selectedSeason?.let { add(Choice("staffel", translated("%@ als gesehen", it.name))) }
                            add(Choice("metadaten", translated("Metadaten neu einlesen")))
                        }
                        TvMoreButton(entries,
                            mapOf("gesehen" to Glyph.CheckmarkCircleFilled, "vonvorn" to Glyph.Rewind,
                                  "naechste" to Glyph.Skip, "staffel" to Glyph.CheckmarkCircle,
                                  "gemeinsam" to Glyph.Cluster, "metadaten" to Glyph.Reload)) { choice ->
                            if (choice == "gemeinsam") {
                                alt.state?.let { st -> tvCreateOpen(app, st.id,
                                    if (st.season != null && st.episode != null) sharedTitleRow("", alt.name, st.season, st.episode) else alt.name) }
                                return@TvMoreButton
                            }
                            run.launch {
                                when (choice) {
                                    // Mirrors `gesehenHandlung`/`DetailView.swift:189-194`: toggle immediately, roll back on error
                                    // and report.
                                    "gesehen" -> {
                                        s = alt.copy(watched = !alt.watched)
                                        val reason = withContext(Dispatchers.IO) { app.kern.watched(alt.id, !alt.watched).await() }
                                        if (reason.isNotEmpty()) { s = alt.copy(watched = alt.watched); message = errorString(reason) }
                                    }
                                    "vonvorn" -> alt.state?.let { st ->
                                        if (series?.planPresent == true) app.play.value = PlayRequest(st.id, null)
                                        else message = translated("Der Server hat keine Datei zu dieser Folge.")
                                    }
                                    // Mirrors `TitleActions.forSeries`: without a next episode it reports.
                                    "naechste" -> alt.state?.let { st ->
                                        val afterThat = withContext(Dispatchers.IO) { app.kern.episodeAfter(st.id, alt.id).await() }
                                        if (afterThat.isNotEmpty()) app.play.value = PlayRequest(afterThat, null)
                                        else message = translated("Danach kommt nichts mehr.")
                                    }
                                    "staffel" -> selectedSeason?.let { st ->
                                        val reason = withContext(Dispatchers.IO) { app.kern.watched(st.id, true).await() }
                                        if (reason.isNotEmpty()) message = errorString(reason)
                                        else {
                                            message = translated("%@ ist als gesehen vermerkt.", st.name)
                                            load()
                                        }
                                    }
                                    "metadaten" -> {
                                        val reason = withContext(Dispatchers.IO) { app.kern.metadataRefresh(alt.id).await() }
                                        message = if (reason.isEmpty()) translated("Der Server liest die Metadaten neu ein.") else errorString(reason)
                                    }
                                }
                            }
                        }
                    } else {
                        TvButton(null, Glyph.More, description = translated("Mehr")) {}
                    }
                }

                Column(Modifier.tvSection(a, "folgen").padding(top = TvTheme.railsSpacing - TvTheme.railsPadding).tvInFade(fadeInAlpha)) {
                    Text(translated("Folgen"), style = TvTheme.rail, color = Theme.font, modifier = Modifier.padding(start = TvTheme.edgePage))
                    val list = series?.seasons.orEmpty()
                    if (list.size > 1) {
                        TvSeasonChips(list, season) { w ->
                            season = w; selfSelected = true
                            app.episodesCache[w]?.let { episodes = it }
                            series?.id?.let { sid -> run.launch { episodesLoad(sid, w) } }
                        }
                    }
                    // One stack as on tvOS: loading / empty / strip share the same height, so the cast below does
                    // not jump back and forth on a season change.
                    val spaceHeight = TvTheme.landscapeHeight + TvTheme.railsPadding * 2 + 40.dp
                    when {
                        disrupted && series == null -> TvDisruption(app)
                        loadsEpisodes -> Box(Modifier.padding(start = TvTheme.edgePage, top = TvTheme.titleSpacing).height(spaceHeight))
                        episodes.isEmpty() -> Text(translated("Keine Folgen in dieser Staffel"), style = TvTheme.body, color = Theme.fontQuiet,
                             modifier = Modifier.padding(start = TvTheme.edgePage, top = 16.dp).height(spaceHeight))
                        // Own horizontal bring-into-view (the page turns off the vertical one): `TvStaticRail`. A
                        // fully visible episode does not move the row, otherwise it would drift one episode further out
                        // of the header line with every Down.
                        else -> CompositionLocalProvider(LocalBringIntoViewSpec provides TvStaticRail) {
                            LazyRow(state = strip, contentPadding = PaddingValues(start = TvTheme.edgePage, end = TvTheme.edgePage, top = TvTheme.titleSpacing, bottom = TvTheme.railsPadding),
                                    horizontalArrangement = Arrangement.spacedBy(TvTheme.tileSpacing)) {
                                items(episodes, key = { it.id }) { f ->
                                    // Long OK or the menu key: the tile menu, as on every other episode.
                                    val menu = de.paulherter.swiftly.LocalTileMenu.current
                                    val lengthy: (() -> Unit)? = menu?.let { m -> {
                                        m(de.paulherter.swiftly.TileMenuRequest(f.id, f.name.ifEmpty { f.title }, "Episode",
                                            f.image, true, f.subline,
                                            afterwards = { series?.id?.let { sid -> season?.let { st -> run.launch { episodesLoad(sid, st) } } } }))
                                    } }
                                    TvEpisodesTile(f, lengthy = lengthy) { app.play.value = PlayRequest(f.id, f.since) }
                                }
                            }
                        }
                    }
                }
                val folks = series?.actors.orEmpty()
                if (folks.isNotEmpty()) TvStrip(translated("Besetzung"), Modifier.tvInFade(fadeInAlpha).tvSection(a, "besetzung")) {
                    items(folks, key = { it.id }) { p -> TvCast(p) { open(Destination(p.id, p.name, "Person", p.role, name)) } }
                }
                if (similar.isNotEmpty()) TvStrip(translated("Ähnliches"), Modifier.tvInFade(fadeInAlpha).tvSection(a, "aehnliche")) {
                    items(similar, key = { it.id }) { k -> TvTile(k.poster, k.title, k.subline) { open(Destination(k.id, k.title, k.type)) } }
                }
                if (extras.isNotEmpty()) TvStrip(translated("Extras"), Modifier.tvInFade(fadeInAlpha).tvSection(a, "extras")) {
                    items(extras, key = { it.id }) { x -> TvTile(x.image, x.name, x.runtime, landscape = true) { app.play.value = PlayRequest(x.id, null) } }
                }
                Spacer(Modifier.height(40.dp))
        }
        message?.let { text ->
            TvHintStrip(text, Modifier.align(Alignment.TopCenter).padding(top = 74.dp)) { message = null }
        }
    }
}

/**
 * **The seasons as a row of chips, not a sheet.** Mirrors `seasonRow` in tvOS `SeriesView`. A list of
 * ten seasons is taller than the screen; a row is as wide as it needs and scrolls, and left and right
 * is how the remote moves along a row anyway. `TvChip` because it is the chip that shows a selection:
 * the selected season carries the accent. Only from two seasons, as the pill before.
 *
 * **Entering the row lands on the selected season**, not on the chip geometrically closest
 * (`focusProperties.enter`, as the left column of `TvProfile`). Only while that chip is laid out: a
 * requester without a node would have nothing to focus, and the default search takes over.
 *
 * The selected season is scrolled into view when the row appears and when it changes, as the episode
 * strip does with the running episode.
 *
 * **Shared by the series page and the player's episode layer** (`TvEpisodesLayer`), so both pick a
 * season the same way. `onSelected` lets the caller put focus on the selected chip itself, as the
 * layer does when it has no episodes to focus; `modifier` carries its focus tracking.
 */
// `focusProperties.enter` is still experimental in Compose UI (as in `TvProfile`).
@OptIn(ExperimentalFoundationApi::class, androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
internal fun TvSeasonChips(seasons: List<Season>, selected: String?, modifier: Modifier = Modifier,
                           onSelected: FocusRequester = remember { FocusRequester() }, select: (String) -> Unit) {
    val chips = rememberLazyListState()
    val index = seasons.indexOfFirst { it.id == selected }
    LaunchedEffect(index) {
        if (index >= 0 && chips.layoutInfo.visibleItemsInfo.none { it.index == index }) chips.scrollToItem(index)
    }
    CompositionLocalProvider(LocalBringIntoViewSpec provides TvStaticRail) {
        LazyRow(modifier.focusProperties {
                    enter = { if (chips.layoutInfo.visibleItemsInfo.any { it.index == index }) onSelected else FocusRequester.Default }
                }.focusGroup(),
                state = chips,
                contentPadding = PaddingValues(start = TvTheme.edgePage, end = TvTheme.edgePage, top = TvTheme.railsPadding),
                horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            items(seasons, key = { it.id }) { st ->
                val an = st.id == selected
                TvChip(st.name, an, if (an) Modifier.focusRequester(onSelected) else Modifier) { select(st.id) }
            }
        }
    }
}

/**
 * An episode in the strip, shared by the series page and the player's episode layer (mirrors tvOS
 * `EpisodesStrip`). **Same catalog format as tvOS** (`headerLine`/`durationRow`): "the accent rule · Title",
 * below it the runtime and time left. **Watched shows as a checkmark in the picture, not as a
 * word**: picture dimmed, title quiet; a full bar plus a checkmark would be the same information
 * twice. `title`/`subline` stay unchanged for the phone; the raw parts come separately from
 * `Kern.episodes`.
 */
@Composable
fun TvEpisodesTile(f: Episode, modifier: Modifier = Modifier, lengthy: (() -> Unit)? = null, perform: () -> Unit) {
    // Translated: German "F" for Folge, English "E" for episode; this was hard-coded as "F",
    // also in English.
    val title = f.number?.let { "${translated("F%d", it)} · ${f.name}" } ?: f.name
    val subline = buildList {
        f.runtimeMin?.let { add(translated("%lld Min", it)) }
        f.remainingTime?.let { add(it) }
    }.joinToString(" · ").ifEmpty { null }
    TvTile(f.image, title, subline, landscape = true, progress = if (f.watched) null else f.progress,
             mark = if (f.watched) "gesehen" else null, modifier = modifier, lengthy = lengthy,
             dimmed = f.watched, titleQuiet = f.watched, perform = perform)
}
