package de.paulherter.swiftly.tv

import de.paulherter.swiftly.shared.motionReduced
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import coil3.compose.AsyncImage
import de.paulherter.swiftly.*
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/**
 * Shared header for movie and series detail pages: facts block, then the button row. The backdrop
 * lives in each page itself as a fixed layer because it sits outside the scrolling column.
 * One function instead of two near-identical blocks, so the pages cannot drift apart.
 *
 * Uses the shared `HeaderInfo` from `TvStart.kt` instead of its own copy (an earlier duplicate
 * had a different description color and lacked rating/certification). Rating and certification
 * live in `HeaderInfo`; only the direct-play badge is passed in via `closing`.
 *
 * `buttonAlpha` fades in the button row while title, facts, description and backdrop are shown
 * immediately: only what is new compared to the home screen fades in (mirrors tvOS `DetailView`).
 */
@Composable
fun TvDetailHeader(title: String, yearRuntime: String, rating: Double?, sharing: String?, description: String?,
                 directPlayFlag: Boolean, hint: String?, buttonAlpha: () -> Float = { 1f }, modifier: Modifier = Modifier,
                 logo: String? = null, buttons: @Composable () -> Unit) {
    // 306.5 dp is the whole zone, padding included (halved `Theme.heroHeightDetail`). On tvOS the
    // padding sits inside the fixed height, so a `Box` carries the total height and the `Column`
    // inside carries the padding. Putting both on one `Column` would add them up (404.5 dp) and
    // leave a gap between the button row and "Episodes". tvOS always reserves three description
    // lines (`Theme.infoHeight`) so a short description does not crowd the button row.
    //
    // `secondLine = null`: detail pages never show it, because an episode has no page of its own
    // and every route to it leads to the series page. See `HeaderInfo`.
    Box(modifier.fillMaxWidth().height(306.5.dp)) {
        Column(Modifier.padding(start = TvTheme.edgePage, top = 98.dp)) {
            HeaderInfo(title, null, yearRuntime, rating, sharing, description, logo = logo) {
                TvProofRow(directPlayFlag, hint, rating = null, sharing = null)
            }
            Row(Modifier.padding(top = 18.dp).tvInFade(buttonAlpha), horizontalArrangement = Arrangement.spacedBy(12.dp), content = { buttons() })
        }
    }
}

/**
 * Mirrors tvOS `ProofRow`: rating, certification badge, and direct play (or the reason against
 * it) as a tinted badge. Sizes halved. The rating shares the direct-play shell. `eigen` replaces
 * the plan with a free-form badge, e.g. the request status on the Seerr page.
 * If everything is missing the row takes no space; the caller still adds it so the fixed
 * height of the header does not jump.
 */
@Composable
fun TvProofRow(directPlayFlag: Boolean, hint: String?, rating: Double?, sharing: String?,
                 own: Triple<Glyph, String, Color>? = null) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        if (own != null) TvMark(own.first, own.second, own.third, Strength.Semibold)
        rating?.let {
            TvMark(Glyph.StarFilled, String.format(Locale.ROOT, "%.1f", it).replace('.', ','), Theme.fontQuiet, Strength.Semibold)
        }
        sharing?.takeIf { it.isNotBlank() }?.let { TvBadge(it) }
        if (own == null && (directPlayFlag || hint != null)) {
            TvMark(if (directPlayFlag) Glyph.Checkmark else Glyph.Warning, if (directPlayFlag) "Direct Play" else hint.orEmpty(),
                    if (directPlayFlag) Theme.accent else Theme.warning, if (directPlayFlag) Strength.Semibold else Strength.Normal)
        }
    }
}

/**
 * The single shell for all badges: 15 % color fill, `cornerSmall` corners, icon and text in the
 * same color.
 */
@Composable
private fun TvMark(symbolText: Glyph, word: String, color: Color, strength: Strength) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = Modifier.clip(RoundedCornerShape(TvTheme.cornerSmall)).background(color.copy(alpha = 0.15f))
            .padding(start = 8.dp, end = 10.dp, top = 4.dp, bottom = 4.dp)) {
        Symbol(symbolText, 11.dp, color = color, strength = strength)
        Text(word, style = TvTheme.tile, color = color, maxLines = 1)
    }
}

/**
 * Mirrors tvOS `Badge.far`: fill instead of border. Fill = color at 15 %, text = full color;
 * certification and rating are neutral white at 7 %. Corners `cornerSmall`.
 */
@Composable
private fun TvBadge(text: String) {
    Text(text, style = TvTheme.badge.copy(letterSpacing = 0.sp), color = Theme.fontQuiet,
         modifier = Modifier.clip(RoundedCornerShape(TvTheme.cornerSmall)).background(Theme.line)
             .padding(horizontal = 6.dp, vertical = 2.dp))
}

/**
 * Mirrors tvOS `MoreButton`: the menu opens directly below the button, anchored left, without a
 * title row, icons on the left. Unlike `TvPanel` (right screen edge, with title row).
 *
 * Focus stays inside the menu (`focusGroup` with locked exit) until it closes; Back closes only
 * the menu, not the page.
 *
 * On close, focus returns to the "..." button via `FocusRemember`/`LocalWithinPanel` from
 * `TvTheme.kt`, as in `TvPanel`. `warOffen` records that the menu really was open: without it
 * the restore call would run on first composition (`opened` starts `false`) and could discard the
 * `FocusRemember` of an unrelated trigger on the page.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun TvMoreButton(entries: List<Choice>, icons: Map<String, Glyph> = emptyMap(), select: (String) -> Unit) {
    var opened by remember { mutableStateOf(false) }
    // Restore focus to the "..." button first, then close the menu. The other way round, removing
    // the focused row would drop focus onto the first focusable node briefly and a later restore
    // would show as a jump. The button owns its `FocusRequester`; `sharing` opens the locked exit
    // (`exit = Cancel` also blocks programmatic `requestFocus`).
    val button = remember { FocusRequester() }
    val sharing = remember { booleanArrayOf(false) }
    fun close() {
        sharing[0] = true
        runCatching { button.requestFocus() }
        opened = false
    }
    Box {
        TvButton(null, Glyph.More, modifier = Modifier.focusRequester(button), description = translated("Mehr")) {
            if (opened) close() else { sharing[0] = false; opened = true }
        }
        if (opened) {
            BackHandler(onBack = { close() })
            val first = remember { FocusRequester() }
            LaunchedEffect(Unit) { delay(TvTheme.focusDeadline); runCatching { first.requestFocus() } }
            // 44 dp below the button, same as the season list on the phone (`SeasonHeader` in
            // `SeriesPage.kt`). `focusable = true` as in `TvCapsuleWithPanel`, otherwise keys bypass the menu.
            Popup(offset = IntOffset(0, with(LocalDensity.current) { 44.dp.roundToPx() }),
                  onDismissRequest = { close() }, properties = PopupProperties(focusable = true)) {
                // Inside the panel: a clicked row must not register itself as the trigger in `FocusRemember`,
                // or the next close would restore focus to that row instead of the "..." button.
                CompositionLocalProvider(LocalWithinPanel provides true) {
                    Column(Modifier.width(340.dp).clip(RoundedCornerShape(TvTheme.cornerArea)).background(Theme.area)
                            .padding(vertical = 6.dp)
                            .focusProperties { exit = { if (sharing[0]) FocusRequester.Default else FocusRequester.Cancel } }.focusGroup()) {
                        entries.forEachIndexed { i, e ->
                            TvRow(e.text, icons[e.value], modifier = if (i == 0) Modifier.focusRequester(first) else Modifier) {
                                close()
                                select(e.value)
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * A titled row, mirrors `railsSection`/`strip` from `TitleRails.swift`.
 *
 * `TvRailsBringIntoView` is set again explicitly (see `TvNoVerticalRightsBringIntoView` in
 * `TvStart.kt`): the pages embedding this row disable vertical bring-into-view on their column
 * and scroll by section themselves (`TvSectionPage`). Without this line the `LazyRow` would
 * inherit the disabled spec and stop scrolling to the next tile.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TvStrip(title: String, modifier: Modifier = Modifier, content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    Column(modifier.padding(top = TvTheme.railsSpacing - TvTheme.railsPadding)) {
        TvRailsTitle(title)
        CompositionLocalProvider(LocalBringIntoViewSpec provides TvRailsBringIntoView) {
            LazyRow(contentPadding = PaddingValues(horizontal = TvTheme.edgePage, vertical = TvTheme.railsPadding),
                    horizontalArrangement = Arrangement.spacedBy(TvTheme.tileSpacing), content = content)
        }
    }
}

/** Mirrors `CastTile`: round, 104 dp, name and role below. */
@Composable
fun TvCast(p: WithAct, perform: () -> Unit) {
    Column(Modifier.width(TvTheme.posterWidth), horizontalAlignment = Alignment.CenterHorizontally) {
        FocusArea(perform = perform) {
            Box(Modifier.size(TvTheme.posterWidth).clip(CircleShape).background(Theme.area), contentAlignment = Alignment.Center) {
                Symbol(Glyph.PersonFilled, 30.dp, color = Theme.fontVeryQuiet)
                AsyncImage(model = p.image, contentDescription = p.name, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            }
        }
        Text(p.name, style = TvTheme.tile, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 7.dp))
        p.role?.let { Text(it, style = TvTheme.small, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis) }
    }
}

/**
 * Mirrors tvOS `DetailView`: 510 high, not 1080. Backdrop right, text left, rows below start at
 * the same height as on the home screen. No back arrow (the remote handles Back). One main button
 * with text, then three square ones (restart, watchlist, more); "Watched" is in the panel. Initial
 * focus is on the main button.
 *
 * The trailer is first in the extras, not a sixth pill: five labelled buttons were too many for
 * one row. `Kern.localTrailer` returns it separately from `titleField` because not every
 * title has one.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TvDetail(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit) {
    var t by remember(target.id) { mutableStateOf(app.titleCache[target.id]) }
    var similar by remember(target.id) { mutableStateOf<List<GridTile>>(emptyList()) }
    var extras by remember(target.id) { mutableStateOf<List<Extra>>(emptyList()) }
    var collections by remember(target.id) { mutableStateOf<List<CollectionRailsData>>(emptyList()) }
    /** Everything below the header has been answered, see `load`. */
    var bottomPresent by remember(target.id) { mutableStateOf(false) }
    /** The title did not load the first time; without this the page stayed empty. */
    var disrupted by remember(target.id) { mutableStateOf(false) }
    val run = rememberCoroutineScope()
    val playsNow = app.play.value != null

    suspend fun newLoad() {
        try { t = titleRead(withContext(Dispatchers.IO) { app.kern.title(target.id).await() }).also { app.titleCache[target.id] = it } }
        catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }
    /**
     * Everything below the header arrives at once (mirrors iOS `ItemDetailView.bottomPresent`, like
     * `TitlePage.load` on the phone). Collection, similar, extras and cast used to arrive one by
     * one and push into the page, so focus could sit on a row that then moved down. Now the page
     * waits for all requests and fades the rows in together. If one fails, only its row is missing.
     */
    suspend fun load() {
        coroutineScope {
            val a = async { try { titleRead(withContext(Dispatchers.IO) { app.kern.title(target.id).await() }) }
                            catch (e: CancellationException) { throw e } catch (_: Exception) { null } }
            val b = async { try { JSONObject(withContext(Dispatchers.IO) { app.kern.titleField(target.id).await() }) }
                            catch (e: CancellationException) { throw e } catch (_: Exception) { null } }
            // The trailer lives in the extras, not as a sixth pill; see the doc comment above.
            val c = async { try { JSONObject(withContext(Dispatchers.IO) { app.kern.localTrailer(target.id).await() }) }
                            catch (e: CancellationException) { throw e } catch (_: Exception) { null } }
            val d = async { collectionRailsLoad(app.kern, target.id) }
            val new = a.await(); val surroundings = b.await(); val tr = c.await(); val rails = d.await()
            val preview = tr?.takeIf { it.has("id") }?.let { Extra(it.getString("id"), it.getString("name"), it.fieldText("bild"), it.fieldText("laufzeit")) }
            // No suspension point from here on: everything lands in the same frame.
            new?.let { t = it; app.titleCache[target.id] = it }
            disrupted = new == null && t == null
            surroundings?.let { o ->
                similar = o.fieldList("aehnliche") { gridTileRead(it) }
                extras = listOfNotNull(preview) + o.fieldList("extras") { Extra(it.getString("id"), it.getString("name"), it.fieldText("bild"), it.fieldText("laufzeit")) }
            }
            collections = rails
            bottomPresent = true
        }
    }
    LaunchedEffect(target.id) { load() }
    // After watching and after the end report (only then does the server know the position), reload
    // only the title.
    var hasPlay by remember(target.id) { mutableStateOf(false) }
    LaunchedEffect(target.id, playsNow, app.playbackEnded.intValue, app.watchStateChanged.intValue) {
        if (playsNow) hasPlay = true else if (hasPlay) newLoad()
    }
    val main = firstFocus()
    val title = t
    // Until `Kern.title` answers, the header shows what the home screen already showed (`TvPreOff`),
    // so nothing jumps when the data arrives. Only direct play, buttons and rows come later.
    val preOff = remember(target.id) { TvHandoff.of(target.id) }
    val name = title?.name ?: preOff?.title ?: target.name
    // `TvMain` draws backdrop and background (`TvBackdropsLayer`), same URL as on Start.
    TvBackdropReport(title?.let { it.backdrop ?: it.headerImage }, ready = title != null)

    // Mirrors tvOS `DetailView.inFade`: fades in on appearing, not on loading, every time,
    // whether the cache already has the data or not. Backdrop, title, facts line and description
    // show immediately (`TvDetailHeader`/`HeaderInfo` ignore `inFade`); only the button row and
    // the rows below are new compared to the home screen. Otherwise everything would pop in at once.
    //
    // `rememberTvFadeIn` instead of a plain `animateFloatAsState`; see there for why the old
    // version did not visibly fade on the emulator.
    val inFade = rememberTvFadeIn(target.id)
    val fadeInAlpha = { inFade.value }
    // The rows below fade in only after `load` is done, together, not one by one.
    val bottom = rememberTvFadeIn(target.id, ready = bottomPresent)
    val bottomAlpha = { inFade.value * bottom.value }
    // Mirrors the `MainView.errorMessage` banner, wired like on the phone (`TitlePage.meldung`).
    // Android has no shared error source like `AppModel.errorMessage`, hence its own state.
    var message by remember { mutableStateOf<String?>(null) }

    Box(Modifier.fillMaxSize()) {
        TvSectionPage { a ->
                TvDetailHeader(name, if (title != null) title.yearRuntime else preOff?.details.orEmpty(),
                             if (title != null) title.rating else preOff?.rating,
                             if (title != null) title.sharing else preOff?.sharing,
                             if (title != null) title.description else preOff?.description,
                             directPlayFlag = title?.planPresent == true && title.lossless,
                             hint = if (title?.planPresent == true && !title.lossless) title.method else null,
                             buttonAlpha = fadeInAlpha, modifier = Modifier.tvSection(a, "kopf", TvSectionKind.Header),
                             logo = if (app.settings.titleAsLogo) title?.logo else null) {
                    // Mirrors `DetailView.starte`: without a plan it reports instead of silently doing nothing.
                    val menu = de.paulherter.swiftly.LocalTileMenu.current
                    TvButton(translated(if (title?.resumeFrom != null) "Fortsetzen" else "Abspielen"), Glyph.Play, Modifier.focusRequester(main),
                            // Long OK or the menu key: the title's tile menu, as on its tile.
                            lengthy = menu?.let { m -> {
                                m(de.paulherter.swiftly.TileMenuRequest(target.id, name, title?.type?.ifEmpty { null } ?: "Movie",
                                    title?.let { it.backdrop ?: it.headerImage }, true, title?.secondaryLine,
                                    afterwards = { run.launch { newLoad() } }))
                            } }) {
                        if (title?.planPresent == true) de.paulherter.swiftly.playOrChoose(app, title, target.id, title.resumeFrom)
                        // Without a title nobody knows whether a file exists; ask again first.
                        else if (title == null && disrupted) { disrupted = false; run.launch { load() } }
                        else message = translated("Der Server hat keine Datei zu diesem Titel.")
                    }
                    if (title?.resumeFrom != null) TvButton(null, Glyph.Rewind, description = translated("Von vorn abspielen")) {
                        if (title.planPresent) app.play.value = PlayRequest(target.id, null)
                        else message = translated("Der Server hat keine Datei zu diesem Titel.")
                    }
                    if (app.settings.watchlist) {
                        TvButton(null, if (title?.remembered == true) Glyph.BookmarkFilled else Glyph.Bookmark,
                                description = translated("Merkliste"), active = title?.remembered == true) {
                            val an = !(title?.remembered ?: false)
                            title?.let { t = it.copy(remembered = an) }
                            // Like "Watched": revert and report. Before, the mark silently jumped back.
                            run.launch {
                                val reason = withContext(Dispatchers.IO) { app.kern.remember(target.id, an).await() }
                                if (reason.isNotEmpty()) { title?.let { t = it }; message = errorString(reason) }
                            }
                        }
                    }
                    // `TvMoreButton` instead of `app.sheet`: on tvOS the menu opens directly below the button, not as
                    // a panel on the right edge. See its doc comment.
                    val tt = title
                    if (tt != null) {
                        val watchedNow = tt.watched
                        // `TitleActions.forMovie`: "Watched" first (reachable from the button row, see
                        // `gesehenHandlung`), "Restart"/"Reset" only with progress.
                        val entries = buildList {
                            add(Choice("gesehen", translated(if (watchedNow) "Als ungesehen merken" else "Als gesehen merken")))
                            if (tt.planPresent && tt.resumeFrom != null) {
                                add(Choice("vonvorn", translated("Von vorn abspielen")))
                                add(Choice("zuruecksetzen", translated("Fortschritt zurücksetzen")))
                            }
                            // Only with a file and permission (`TitleActions.forMovie`, `gemeinsam`).
                            if (tt.planPresent && app.gemeinsam.value.mayCreate) add(Choice("gemeinsam", translated("Gemeinsam schauen")))
                            add(Choice("metadaten", translated("Metadaten neu einlesen")))
                        }
                        TvMoreButton(entries,
                            mapOf("gesehen" to Glyph.CheckmarkCircleFilled, "vonvorn" to Glyph.Rewind,
                                  "zuruecksetzen" to Glyph.ResetCircle, "gemeinsam" to Glyph.Cluster,
                                  "metadaten" to Glyph.Reload)) { choice ->
                            if (choice == "gemeinsam") { tvCreateOpen(app, target.id, tt.name); return@TvMoreButton }
                            run.launch {
                                when (choice) {
                                    // Mirrors `gesehenHandlung` in `DetailView.swift`: toggle immediately, revert and report on
                                    // failure.
                                    "gesehen" -> {
                                        t = tt.copy(watched = !watchedNow)
                                        val reason = withContext(Dispatchers.IO) { app.kern.watched(target.id, !watchedNow).await() }
                                        if (reason.isNotEmpty()) { t = tt.copy(watched = watchedNow); message = errorString(reason) }
                                    }
                                    "vonvorn" -> app.play.value = PlayRequest(target.id, null)
                                    "zuruecksetzen" -> {
                                        val reason = withContext(Dispatchers.IO) { app.kern.watched(target.id, false).await() }
                                        if (reason.isNotEmpty()) message = errorString(reason)
                                        else { message = translated("Der Fortschritt ist zurückgesetzt."); newLoad() }
                                    }
                                    "metadaten" -> {
                                        val reason = withContext(Dispatchers.IO) { app.kern.metadataRefresh(target.id).await() }
                                        message = if (reason.isEmpty()) translated("Der Server liest die Metadaten neu ein.") else errorString(reason)
                                    }
                                }
                            }
                        }
                    } else {
                        TvButton(null, Glyph.More, description = translated("Mehr")) {}
                    }
                }
                // Above "Similar movies": the collection is the closer relation. Only for titles that belong to
                // one (`Sammlungsreihe` in `TitleRails.swift`).
                if (disrupted && title == null) TvDisruption(app, retry = { disrupted = false; run.launch { load() } })
                if (bottomPresent) {
                    TvCollectionRail(collections, open) { i -> Modifier.tvInFade(bottomAlpha).tvSection(a, "sammlung$i") }
                    if (similar.isNotEmpty()) TvStrip(translated("Ähnliche Filme"), Modifier.tvInFade(bottomAlpha).tvSection(a, "aehnliche")) {
                        items(similar, key = { it.id }) { k -> TvTile(k.poster, k.title, k.subline) { open(Destination(k.id, k.title, k.type)) } }
                    }
                    if (extras.isNotEmpty()) TvStrip(translated("Extras"), Modifier.tvInFade(bottomAlpha).tvSection(a, "extras")) {
                        items(extras, key = { it.id }) { x -> TvTile(x.image, x.name, x.runtime, landscape = true) { app.play.value = PlayRequest(x.id, null) } }
                    }
                    val folks = title?.actors.orEmpty()
                    if (folks.isNotEmpty()) TvStrip(translated("Besetzung"), Modifier.tvInFade(bottomAlpha).tvSection(a, "besetzung")) {
                        items(folks, key = { it.id }) { p -> TvCast(p) { open(Destination(p.id, p.name, "Person", p.role, name)) } }
                    }
                }
                Spacer(Modifier.height(40.dp))
        }
        message?.let { text ->
            TvHintStrip(text, Modifier.align(Alignment.TopCenter).padding(top = 74.dp)) { message = null }
        }
    }
}

/** "24. Juni 1962" in the device language, same conversion as `PersonPage.longDate`. */
private fun tvLongDate(iso: String): String? =
    runCatching { LocalDate.parse(iso).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG)) }.getOrNull()

/**
 * Mirrors tvOS `PersonView`, built like a detail page: round picture, name, birth, place, role in
 * the accent color. The banner cross-fades between the landscape images every six seconds.
 * "Nothing else" waits for Seerr (`seerrReady`), otherwise the message flashes before the
 * filmography is there (same as `PersonView.swift`).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TvPerson(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit) {
    var state by remember(target.id) { mutableStateOf(app.peopleCache[target.id]) }
    // A failed request must not leave a dead end: the page would be empty with nothing focusable.
    // Show the error state with "Try again", focused.
    var failed by remember(target.id) { mutableStateOf(false) }
    var attempt by remember(target.id) { mutableIntStateOf(0) }
    de.paulherter.swiftly.WatchStateChange(app) { attempt++ }
    LaunchedEffect(target.id, attempt) {
        failed = false
        try { state = personRead(withContext(Dispatchers.IO) { app.kern.person(target.id).await() }).also { app.peopleCache[target.id] = it } }
        catch (e: CancellationException) { throw e } catch (_: Exception) { failed = true }
    }
    val s = state
    var requestable by remember(target.id) { mutableStateOf<List<SeerrTile>?>(null) }
    val tmdb = s?.tmdb
    val seerrPresent = app.seerrConnected.value
    LaunchedEffect(tmdb, seerrPresent) {
        if (tmdb == null || !seerrPresent) return@LaunchedEffect
        val ownOnes = s?.title.orEmpty().mapTo(HashSet()) { it.title.lowercase() }
        requestable = try {
            seerrTilesRead(withContext(Dispatchers.IO) { app.kern.seerrFilmography(tmdb.toLong()).await() }).filter { it.title.lowercase() !in ownOnes }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() }
    }
    val seerrReady = requestable != null || !seerrPresent || (s != null && tmdb == null)
    val banner = s?.banner.orEmpty()
    var spot by remember(target.id) { mutableIntStateOf(0) }
    // With "Reduce motion" the first landscape image stays: the switching is the only thing on the
    // page that moves by itself, and the system shortens only the fade, not the switch.
    val calm = motionReduced()
    LaunchedEffect(banner.size, calm) { if (banner.size > 1 && !calm) while (true) { delay(6000); spot++ } }
    val focus = firstFocus(s != null || failed)

    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        // Mirrors `PersonView` `.imageReason(url: bannerNow)`: the background follows the landscape image.
        TvImageReason(banner.getOrNull(if (banner.isEmpty()) 0 else spot % banner.size))
        // Soft and slow: 1.2 s between the title landscape images.
        Backdrop(banner.getOrNull(if (banner.isEmpty()) 0 else spot % banner.size), Modifier.align(Alignment.TopEnd), duration = 1200)
        // Mirrors `HeaderShadow()` as on Start and Detail. The background of this page is opaque, so
        // without it the shadow vanished abruptly on opening a person.
        Box(Modifier.fillMaxWidth()) { HeaderShadow() }
        TvSectionPage { a ->
                // 306.5 dp, the same total height as `TvDetailHeader` (halved `Theme.heroHeightDetail`). tvOS puts
                // `.padding(.top, 140 + headerOffsetDetail)` inside `.frame(height: heroHeightDetail)`. A single
                // `Row` carrying both padding (98 dp) and its own height (177 dp) gave 275 dp with the padding
                // outside the fixed zone. Now the `Box` carries the total height and the `Row` the padding.
                Box(Modifier.fillMaxWidth().height(306.5.dp)) {
                    Row(Modifier.padding(start = TvTheme.edgePage, top = 98.dp),
                        horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                        Box(Modifier.size(TvTheme.posterWidth).clip(CircleShape).background(Theme.area), contentAlignment = Alignment.Center) {
                            Symbol(Glyph.PersonFilled, 33.dp, color = Theme.fontVeryQuiet)
                            AsyncImage(model = s?.image, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                        }
                        Column(Modifier.width(480.dp)) {
                            Text(target.name, style = TvTheme.titleLarge, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            // Two lines as on tvOS (`PersonView.block`): birth date and place in their own `VStack`, not
                            // joined with "·".
                            val birth = s?.born?.let(::tvLongDate)?.let { translated("Geboren %@", it) }
                            Column(Modifier.padding(top = 5.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                                Text(birth.orEmpty(), style = TvTheme.tile, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(s?.place.orEmpty(), style = TvTheme.tile, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                            if (!target.role.isNullOrEmpty() && target.origin != null) {
                                Text(translated("%@ in %@", target.role, target.origin), style = TvTheme.body.copy(fontWeight = FontWeight.Medium),
                                     color = Theme.accent, maxLines = 1, modifier = Modifier.padding(top = 6.dp))
                            }
                            s?.description?.let { Text(it, style = TvTheme.body, color = Theme.fontQuiet, maxLines = 3, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 10.dp)) }
                        }
                    }
                }
                // Without year, with badge, like `TitleStrip` on tvOS (`withUnderRow: false`,
                // `mark: DisplayRules.tileMark(...)`). The badge is already in the JSON, same rule as the
                // library grid.
                if (s != null && s.title.isNotEmpty()) TvStrip(translated("Auf deinem Server"), Modifier.tvSection(a, "server", TvSectionKind.NearHeader)) {
                    items(s.title.size, key = { s.title[it].id }) { i ->
                        val k = s.title[i]
                        TvTile(k.poster, k.title, null, mark = k.mark, markCount = k.markCount,
                                 modifier = if (i == 0) Modifier.focusRequester(focus) else Modifier) { open(Destination(k.id, k.title, k.type)) }
                    }
                }
                requestable?.takeIf { it.isNotEmpty() }?.let { list ->
                    TvStrip(translated("Kann angefragt werden"), Modifier.tvSection(a, "anfragbar",
                               if (s?.title.isNullOrEmpty()) TvSectionKind.NearHeader else TvSectionKind.Flush)) {
                        items(list, key = { it.key }) { t ->
                            TvTile(t.poster, t.title, SeerrMark.shortWord(t.state) ?: t.year?.toString(), opacity = 0.45f) {
                                app.seerrHit[t.key] = t
                                open(Destination(t.key, t.title, "Seerrtitel"))
                            }
                        }
                    }
                }
                // Failed is not empty: "Nothing else on your server with ..." is a statement about the
                // library, and nobody checked if the server did not answer.
                if (s == null && failed) {
                    TvDisruption(app, buttonModifier = Modifier.focusRequester(focus), retry = { attempt++ })
                } else if (s != null && s.disrupted && s.title.isEmpty()) {
                    TvDisruption(app, buttonModifier = Modifier.focusRequester(focus), retry = { attempt++ })
                } else if (s != null && seerrReady && s.title.isEmpty() && requestable.orEmpty().isEmpty()) {
                    Text(translated("Auf deinem Server gibt es sonst nichts mit %@.", target.name), style = TvTheme.body, color = Theme.fontQuiet,
                         modifier = Modifier.padding(start = TvTheme.edgePage, top = 30.dp))
                }
                Spacer(Modifier.height(40.dp))
        }
    }
}

/**
 * Mirrors `GenreView`: the same grid as the library, with the genre name above instead of a chip
 * row, newest first. The name comes from the server and is not translated (`RailTitle(name:)`),
 * hence `TvTheme.rail` and not `titleLarge`.
 */
@Composable
fun TvGenre(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit) {
    var title by remember(target.id) { mutableStateOf<List<GridTile>?>(null) }
    // `disrupted` means failed, empty means empty. `catch { emptyList() }` turned every network error
    // into "nothing in this genre", same as on the phone.
    var disrupted by remember(target.id) { mutableStateOf(false) }
    var attempt by remember(target.id) { mutableIntStateOf(0) }
    de.paulherter.swiftly.WatchStateChange(app) { attempt++ }
    LaunchedEffect(target.id, attempt) {
        disrupted = false
        try {
            title = JSONArray(withContext(Dispatchers.IO) { app.kern.genre(target.id).await() }).let { a -> (0 until a.length()).map { gridTileRead(a.getJSONObject(it)) } }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
            // What is already shown stays; the failure does not replace an existing list.
            if (title.isNullOrEmpty()) { disrupted = true; title = emptyList() }
        }
    }
    val list = title
    val focus = firstFocus(list != null)
    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        // Mirrors `GenreView.swift`: `withUnderRow: false`, as in the library grid.
        TvGrid(list.orEmpty(), focus = focus, open = open, loads = list == null, withUnderRow = false, header = {
            Column {
                Text(target.name, style = TvTheme.rail, color = Theme.font, maxLines = 1,
                     modifier = Modifier.padding(top = 48.dp, bottom = TvTheme.titleSpacing))
                if (disrupted) TvDisruption(app, retry = { attempt++ })
                else if (list != null && list.isEmpty()) {
                    TvEmpty(translated("Nichts in diesem Genre"),
                           translated("In diesem Genre gibt es auf deinem Server gerade keine Filme und Serien."),
                           symbol = Glyph.Tag)
                }
            }
        })
    }
}
