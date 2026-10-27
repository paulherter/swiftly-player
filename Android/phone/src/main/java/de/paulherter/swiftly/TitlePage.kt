package de.paulherter.swiftly

import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.semantics.clearAndSetSemantics
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import android.content.Intent
import android.net.Uri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.role
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.shared.Theme
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.ui.draw.drawBehind
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.Locale

data class WithAct(val id: String, val name: String, val role: String?, val image: String?)
data class FileInfo(val container: String?, val video: String?, val audio: List<String>, val subtitle: String, val hasSubtitle: Boolean)
data class Extra(val id: String, val name: String, val image: String?, val runtime: String?)

/** Response of `Kern.title`; the lines are already formatted there. */
data class Title(
    val id: String, val name: String, val type: String, val secondaryLine: String,
    /** "2026 · 1 h 52 min" without genre, for the TV (`TvDetailHeader`). */
    val yearRuntime: String, val headerImage: String?,
    val rating: Double?, val sharing: String?,
    /** A playback plan exists; without it the buttons stay disabled. */
    val planPresent: Boolean, val lossless: Boolean, val method: String?,
    val resumeFrom: Double?, val resumeText: String?,
    val description: String?, val direction: List<String>, val actors: List<WithAct>,
    val remembered: Boolean, val watched: Boolean, val trailer: String?, val file: FileInfo?,
    /** TV only, see `Tile.backdrop`. */
    val backdrop: String? = null,
    /** "25 min left" under the main button, and the fraction for the bar below it. */
    val remainingTime: String? = null,
    val progress: Double? = null,
    /** Title logo if the server has one, see `TitleMark`. */
    val logo: String? = null,
    /** The versions to choose from when the play button is pressed (`MediaVersions.choices`); empty = no choice. */
    val versions: List<Version> = emptyList(),
)

/** One version of a title: its source ID and the line shown in the choice ("Name · 1080p · HEVC · 18,6 GB"). */
data class Version(val id: String, val label: String)

/**
 * Mirrors the play button of `ItemDetailView` (iOS): **a title with several versions asks which one on
 * press** (4K next to 1080p, theatrical next to extended cut). One version, or a finished copy on the
 * device (the downloaded file is the one that plays), starts at once. A download still running does not
 * count: playback then streams from the server.
 */
internal fun playOrChoose(app: SwiftlyApplication, t: Title?, id: String, since: Double?, beforePlay: () -> Unit = {}) {
    val versions = if (app.downloads.file(id) == null) t?.versions.orEmpty() else emptyList()
    if (versions.isEmpty()) { beforePlay(); app.play.value = PlayRequest(id, since); return }
    app.sheet.value = SheetRequest(translated("Fassung wählen"), versions.map { Choice(it.id, it.label) }, null, longRows = true) { source ->
        beforePlay(); app.play.value = PlayRequest(id, since, source)
    }
}

internal fun JSONObject.fieldText(inputField: String): String? = if (isNull(inputField)) null else getString(inputField)
internal fun JSONObject.fieldNumber(inputField: String): Double? = if (isNull(inputField)) null else getDouble(inputField)
internal fun JSONObject.fieldTexts(inputField: String): List<String> =
    optJSONArray(inputField)?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
internal fun <T> JSONObject.fieldList(inputField: String, read: (JSONObject) -> T): List<T> =
    optJSONArray(inputField)?.let { a -> (0 until a.length()).map { read(a.getJSONObject(it)) } } ?: emptyList()

internal fun titleRead(json: String): Title = JSONObject(json).let { o ->
    Title(o.getString("id"), o.getString("name"), o.optString("typ"), o.optString("nebenzeile"),
          o.optString("jahrLaufzeit"), o.fieldText("kopfbild"),
          o.fieldNumber("bewertung"), o.fieldText("freigabe"),
          o.optBoolean("planDa"), o.optBoolean("lossless"), o.fieldText("methode"),
          o.fieldNumber("fortsetzenAb"), o.fieldText("fortsetzenText"),
          o.fieldText("beschreibung"), o.fieldTexts("regie"),
          o.fieldList("darsteller") { WithAct(it.getString("id"), it.getString("name"), it.fieldText("rolle"), it.fieldText("bild")) },
          o.optBoolean("gemerkt"), o.optBoolean("gesehen"), o.fieldText("trailer"),
          o.optJSONObject("datei")?.let { d ->
              FileInfo(d.fieldText("container"), d.fieldText("video"), d.fieldTexts("ton"), d.optString("untertitel"), d.optBoolean("hatUntertitel"))
          }, if (o.has("kulisse")) o.fieldText("kulisse") else null,
          o.fieldText("restzeit"), o.fieldNumber("fortschritt"), o.fieldText("logo"),
          o.fieldList("fassungen") { Version(it.getString("id"), it.getString("label")) })
}

/** The facade reports "not signed in" as an identifier because the wording lives in the app catalog. */
internal fun errorString(reason: String) = if (reason == "nichtAngemeldet") translated("Nicht angemeldet.") else reason

/**
 * The sentence for a caught exception; never raw `e.message`.
 *
 * Without network, "No connection." comes first: curl then only reports that the name cannot be
 * resolved, which would turn into "no server at this address", wrong since the address is fine.
 * An exception from the core is exactly `java.lang.Exception` (swift-java `throwAsException`),
 * and its message was already built by the facade via `readableError`. Everything else arises in
 * Kotlin (network during download, a broken response) and gets a fixed sentence.
 */
internal fun errorString(context: android.content.Context, error: Throwable): String {
    val network = context.getSystemService(android.net.ConnectivityManager::class.java)
    val online = runCatching {
        network?.activeNetwork?.let { network.getNetworkCapabilities(it) }
            ?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
    }.getOrDefault(true)
    if (!online) return translated("Keine Verbindung.")
    if (error.javaClass == Exception::class.java) error.message?.takeIf { it.isNotBlank() }?.let { return it }
    if (error is java.io.IOException) return translated("Der Server hat nicht geantwortet.")
    return translated("Fehlgeschlagen")
}

/**
 * Mirrors `ItemDetailView` in `Sources/Shared/BrowseViews.swift`, narrow version.
 *
 * No spinner, no error page, as on iOS: the page appears at once with what the tap brought along
 * and is completed quietly. The last state is remembered in the app so returning from a deeper
 * page does not rebuild it.
 */
@Composable
fun TitlePage(app: SwiftlyApplication, target: Destination, open: (Destination) -> Unit, back: () -> Unit) {
    var title by remember(target.id) { mutableStateOf(app.titleCache[target.id]) }
    var similar by remember(target.id) { mutableStateOf<List<GridTile>>(emptyList()) }
    var extras by remember(target.id) { mutableStateOf<List<Extra>>(emptyList()) }
    var similarDisturbed by remember(target.id) { mutableStateOf(false) }
    var collections by remember(target.id) { mutableStateOf<List<CollectionRailsData>>(emptyList()) }
    /** Everything below the description has been answered, see `load`. */
    var bottomPresent by remember(target.id) { mutableStateOf(false) }
    var fieldAttempt by remember(target.id) { mutableIntStateOf(0) }
    /** The title itself did not arrive; otherwise the page would stay half empty forever with no hint. */
    var titleDisturbed by remember(target.id) { mutableStateOf(false) }
    var remembered by remember(target.id) { mutableStateOf(title?.remembered ?: false) }
    var watched by remember(target.id) { mutableStateOf(title?.watched ?: false) }
    var message by remember { mutableStateOf<String?>(null) }
    val section = rememberCoroutineScope()
    val context = LocalContext.current
    val jerk = rememberJerk()

    suspend fun refresh() {
        try {
            val new = titleRead(withContext(Dispatchers.IO) { app.kern.title(target.id).await() })
            title = new
            app.titleCache[target.id] = new
            remembered = new.remembered
            watched = new.watched
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }

    /** `titleField` was read; `null` if the request failed. */
    suspend fun fieldFetch(): Pair<List<GridTile>, List<Extra>>? = try {
        val o = JSONObject(withContext(Dispatchers.IO) { app.kern.titleField(target.id).await() })
        o.fieldList("aehnliche") { gridTileRead(it) } to
            o.fieldList("extras") { Extra(it.getString("id"), it.getString("name"), it.fieldText("bild"), it.fieldText("laufzeit")) }
    } catch (e: CancellationException) { throw e } catch (_: Exception) { null }

    fun fieldAccept(surroundings: Pair<List<GridTile>, List<Extra>>?) {
        if (surroundings != null) { similar = surroundings.first; extras = surroundings.second; similarDisturbed = false }
        else similarDisturbed = similar.isEmpty()
    }

    /**
     * Everything below the description arrives at once (mirrors `ItemDetailView.bottomPresent` on iOS).
     * Cast, extras, collection and similar titles used to arrive one by one, squeeze into the page
     * and push the rest down. Now the page waits for all requests and fades them in together with the
     * evidence line: no placeholders and no empty hint while loading is still in progress.
     */
    suspend fun load() {
        coroutineScope {
            val a = async { try { titleRead(withContext(Dispatchers.IO) { app.kern.title(target.id).await() }) }
                            catch (e: CancellationException) { throw e } catch (_: Exception) { null } }
            val b = async { fieldFetch() }
            val c = async { collectionRailsLoad(app.kern, target.id) }
            val new = a.await(); val surroundings = b.await(); val rails = c.await()
            // From here on without interruption: everything lands in the same frame.
            new?.let { title = it; app.titleCache[target.id] = it; remembered = it.remembered; watched = it.watched }
            titleDisturbed = new == null && title == null
            fieldAccept(surroundings)
            collections = rails
            bottomPresent = true
        }
    }

    LaunchedEffect(target.id) { load() }
    // "Try again" under "Similar titles" only re-queries the surroundings.
    LaunchedEffect(target.id, fieldAttempt) { if (fieldAttempt > 0) fieldAccept(fieldFetch()) }

    // Reload after watching: progress, watched state and plan have changed.
    val playsNow = app.play.value != null
    var hasPlay by remember { mutableStateOf(false) }
    LaunchedEffect(playsNow) { if (playsNow) hasPlay = true else if (hasPlay) { hasPlay = false; refresh() } }
    // And once more when the end report is through; only then does the server know the position.
    // Also after a change to the watch state (tile menu), like `pagesRefresh` on iOS.
    val ended = app.playbackEnded.intValue + app.watchStateChanged.intValue
    val endedInitial = remember { ended }
    LaunchedEffect(ended) { if (ended != endedInitial) refresh() }

    /** Toggle first, then ask; if the server says no, revert and report, as on iOS. */
    fun toggle(an: Boolean, setDown: (Boolean) -> Unit, question: suspend (Boolean) -> String, remember: (Title, Boolean) -> Title) {
        jerk(Jerk.Lightweight)
        setDown(an)
        section.launch {
            val reason = withContext(Dispatchers.IO) { question(an) }
            if (reason.isNotEmpty()) { setDown(!an); message = errorString(reason) }
            else app.titleCache[target.id]?.let { app.titleCache[target.id] = remember(it, an) }
        }
    }

    val scroll = rememberScrollState()
    val density = LocalDensity.current.density
    val t = title
    val name = t?.name ?: target.name

    // The colour of the header image under the page (`MoodReason`): at the content of the scroll
    // area, with transparent instead of solid surfaces above it (`LocalImageColor`).
    val mood = rememberImageAudio(t?.headerImage)
    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        CompositionLocalProvider(LocalImageColor provides true, LocalImageAudio provides mood.tones) {
        Column(Modifier.fillMaxSize().verticalScroll(scroll).moodReason(mood, Theme.heroHeightValue)) {
            Hero(t?.headerImage, name, t?.secondaryLine.orEmpty(), mood,
                logo = if (app.settings.titleAsLogo) t?.logo else null)

            Column(Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 14.dp),
                   verticalArrangement = Arrangement.spacedBy(14.dp)) {
                ProofRow(t)
                // Button and action row as one block: 8 between them, 14 to everything else.
                Column(Modifier.padding(bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                val menu = LocalTileMenu.current
                PlayButtons(t,
                    // Long press: the title's tile menu, as on its tile.
                    lengthy = menu?.let { m -> {
                        m(TileMenuRequest(target.id, name, t?.type?.ifEmpty { null } ?: "Movie", t?.headerImage, landscape = true,
                                             t?.secondaryLine, afterwards = { section.launch { refresh() } }))
                    } }) { since -> playOrChoose(app, t, target.id, since) { jerk(Jerk.Medium) } }
                if (titleDisturbed && t == null) DisturbHint(app.serverAddress(), spacingTop = 12.dp,
                    retry = { titleDisturbed = false; section.launch { load() } })
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (app.settings.watchlist) {
                        ActionButton(if (remembered) Glyph.BookmarkFilled else Glyph.Bookmark, translated("Merkliste"), remembered) {
                            toggle(!remembered, { remembered = it }, { app.kern.remember(target.id, it).await() }) { alt, an -> alt.copy(remembered = an) }
                        }
                    }
                    // The fifth field, only when the feature is on; next to the watchlist, as the "for later" pair.
                    if (app.settings.downloadButtonShow && t?.type != "Series") DownloadField(app, target.id, name)
                    // On iOS the server's trailer plays in the app's own player, which is still to come; until then the external one.
                    ActionButton(Glyph.Film, translated("Trailer"), false) {
                        val address = t?.trailer
                        val went = address != null && runCatching {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(address)))
                        }.isSuccess
                        if (!went) message = translated("Für diesen Titel liegt kein Trailer vor.")
                    }
                    ActionButton(if (watched) Glyph.CheckmarkCircleFilled else Glyph.CheckmarkCircle, translated("Gesehen"), watched) {
                        toggle(!watched, { watched = it }, { app.kern.watched(target.id, it).await() }) { alt, an -> alt.copy(watched = an) }
                    }
                    ActionButton(Glyph.More, translated("Mehr"), false) {
                        // `TitleActions.forMovie`.
                        val entries = buildList {
                            if (t != null && t.planPresent && t.resumeFrom != null) {
                                add(Choice("vonvorn", translated("Von vorn abspielen")))
                                add(Choice("zuruecksetzen", translated("Fortschritt zurücksetzen")))
                            }
                            // Only with a file and the right (`TitleActions.forMovie`, `gemeinsam`).
                            if (t != null && t.planPresent && app.gemeinsam.value.mayCreate) add(Choice("gemeinsam", translated("Gemeinsam schauen")))
                            add(Choice("metadaten", translated("Metadaten neu einlesen")))
                        }
                        app.sheet.value = SheetRequest(name, entries, null,
                            mapOf("vonvorn" to Glyph.Rewind, "zuruecksetzen" to Glyph.ResetCircle,
                                  "gemeinsam" to Glyph.Cluster, "metadaten" to Glyph.Reload)) { choice ->
                            // The next sheet once this one is out; swapping in place jumped in height.
                            if (choice == "gemeinsam") { section.launch { kotlinx.coroutines.delay(SheetSwitch); sharedCreateOpen(app, target.id, name) }; return@SheetRequest }
                            section.launch {
                                when (choice) {
                                    "vonvorn" -> app.play.value = PlayRequest(target.id, null)
                                    "zuruecksetzen" -> {
                                        val reason = withContext(Dispatchers.IO) { app.kern.watched(target.id, false).await() }
                                        if (reason.isNotEmpty()) message = errorString(reason)
                                        else { message = translated("Der Fortschritt ist zurückgesetzt."); refresh() }
                                    }
                                    "metadaten" -> {
                                        val reason = withContext(Dispatchers.IO) { app.kern.metadataRefresh(target.id).await() }
                                        message = if (reason.isEmpty()) translated("Der Server liest die Metadaten neu ein.") else errorString(reason)
                                    }
                                }
                            }
                        }
                    }
                }
                }
                // `description`: blurb, 8 below it "Director" in 12, 5 in between.
                t?.description?.let { text ->
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        CollapsibleText(text)
                        if (t.direction.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                            Text(translated("Regie"), style = Theme.small, color = Theme.fontQuiet)
                            Text(t.direction.joinToString(", "), style = Theme.small, color = Theme.font)
                        }
                    }
                }
            }

            // Everything below fades in together once `load` is done (see there).
            AnimatedVisibility(bottomPresent, enter = fadeIn(Motion.reveal()), exit = fadeOut()) {
            Column {
            if (t != null && t.actors.isNotEmpty()) Segment(translated("Besetzung"), 14.dp) {
                // The same person can appear twice in the cast; `tilesWithKey` counts them through.
                tilesWithKey(t.actors, { it.id }) { p -> CastTile(p) { open(Destination(p.id, p.name, "Person", p.role, name)) } }
            }
            if (extras.isNotEmpty()) Segment(translated("Extras"), 12.dp) {
                tilesWithKey(extras, { it.id }) { e -> ExtraTile(e) { jerk(Jerk.Medium); app.play.value = PlayRequest(e.id, null) } }
            }
            // Above "Similar titles": the collection is the closer relation. Only for titles that belong to one (`Sammlungsreihe`).
            CollectionRail(collections, open)
            if (similar.isNotEmpty()) Segment(translated("Ähnliche Titel"), Theme.tileSpacing) {
                tilesWithKey(similar, { it.id }) { k -> GridTileView(k, Modifier.width(Theme.tileWidth)) { open(Destination(k.id, k.title, k.type)) } }
            } else if (similarDisturbed) {
                // Only this section did not answer; the server formula for it alone.
                Column(Modifier.padding(top = Theme.railsSpacing), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(translated("Ähnliche Titel"), style = Theme.rail, color = Theme.font, modifier = Modifier.padding(horizontal = Theme.edgeSpacing))
                    DisturbHint(app.serverAddress(), spacingTop = 0.dp, retry = { fieldAttempt++ })
                }
            }
            t?.file?.let { FileExcerpt(it) }
            }
            }
            Spacer(Modifier.navigationBarsPadding().height(24.dp))
        }
        }

        DetailHeader(name, { ((scroll.value / density - 150f) / 70f).coerceIn(0f, 1f) }, back)
        HintStrip(message, Modifier.align(Alignment.BottomCenter)) { message = null }
    }
}

/** Mirrors `Heldbild` + `HeroRunOut`: 300 high, gradient 190, title and subline at the bottom left. */
@Composable
internal fun Hero(image: String?, name: String, secondaryLine: String, mood: AvState? = null, logo: String? = null) {
    Box(Modifier.fillMaxWidth().height(Theme.heroHeightValue)) {
        AsyncImage(model = image, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        HeroRunOut(Modifier.align(Alignment.BottomStart), mood)
        Column(Modifier.align(Alignment.BottomStart).padding(horizontal = Theme.edgeSpacing).padding(bottom = 16.dp),
               verticalArrangement = Arrangement.spacedBy(4.dp)) {
            // The title above a hero image is the page title: same level as "Settings". The letter-spacing
            // comes with the level.
            // At most two lines: a very long title otherwise pushed the subline out of the frame.
            // With "title as logo" (Settings, Appearance) the logo goes here once it is ready.
            TitleMark(name, logo, row = 28.dp) {
                Text(name, style = Theme.title, color = Theme.font, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            // The subline keeps its space even while empty. The title appears at once (from the target), the
            // subline only after loading, and the column hangs from the bottom. If the line came in later,
            // the title moved up by one line height.
            Text(secondaryLine.ifEmpty { " " }, style = Theme.small, color = Theme.fontQuiet,
                 maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** Mirrors `HeroRunOut`: 190 high so the title is not blank on bright posters either. */
@Composable
internal fun HeroRunOut(modifier: Modifier = Modifier, mood: AvState? = null) {
    // With an image colour it does not end in `reason` but in the mesh below (`HeroRunOut(image:)`):
    // exactly the section that lies under the page at this point.
    Box(modifier.fillMaxWidth().height(190.dp)
        .background(Brush.verticalGradient(*HeroLevels.map { (status, a) -> status to Theme.reason.copy(alpha = a) }.toTypedArray()))
        .then(if (mood != null) Modifier.heroRunOutColor(mood, Theme.heroHeightValue, 190.dp) else Modifier))
}

/**
 * Mirrors `ProofRow`: direct play or the reason, rating, certification. Minimum height 26 and
 * faded in as a whole so the button below does not move.
 */
@Composable
private fun ProofRow(t: Title?) =
    ProofRow(t != null, t?.planPresent == true, t?.lossless == true, t?.method, t?.rating, t?.sharing)

@Composable
internal fun ProofRow(loaded: Boolean, planPresent: Boolean, lossless: Boolean, method: String?, rating: Double?, sharing: String?,
                        /** A free-form evidence text instead of the playback plan; on the Seerr page, the status. */
                        own: Triple<Glyph, String, Color>? = null) {
    val visible by animateFloatAsState(if (loaded) 1f else 0f, Motion.reveal(), label = "beleg")
    // 8 between the capsules as on iOS; 14 applied while the rating had no capsule.
    Row(Modifier.heightIn(min = 26.dp).alpha(visible), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (own != null) {
            val (symbolText, word, color) = own
            ProofMark(symbolText, word, color, Strength.Semibold)
        } else if (planPresent) {
            // Direct play carries the checkmark in semibold, the hint the triangle in regular.
            val color = if (lossless) Theme.accent else Theme.warning
            ProofMark(if (lossless) Glyph.Checkmark else Glyph.Warning, if (lossless) "Direct Play" else method.orEmpty(),
                       color, if (lossless) Strength.Semibold else Strength.Normal)
        }
        // Same capsule as direct play: the rating used to be the only bare item in the row. Star in
        // semibold in `schriftLeise`.
        rating?.let { b ->
            ProofMark(Glyph.StarFilled, String.format(Locale.ROOT, "%.1f", b).replace('.', ','), Theme.fontQuiet, Strength.Semibold)
        }
        sharing?.takeIf { it.isNotBlank() }?.let {
            // `Badge`: 13 medium `schriftLeise` on 15 % of the same colour, 10/4 inside, corner 8.
            Text(it, style = Theme.tile, color = Theme.fontQuiet,
                 modifier = Modifier.clip(RoundedCornerShape(Theme.cornerSmall)).background(Theme.fontQuiet.copy(alpha = 0.15f))
                     .padding(horizontal = 10.dp, vertical = 4.dp))
        }
    }
}

/**
 * Mirrors `primaryButton`: one button, not two: "Resume from ..." or "Play". "From the start" is
 * in the More sheet; a second button below was redundant. Below it, 9 gap, the remaining time in
 * 12 and the progress. Disabled without a plan.
 */
@Composable
private fun PlayButtons(t: Title?, lengthy: (() -> Unit)? = null, play: (Double?) -> Unit) {
    val ready = t?.planPresent == true
    Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
        val since = t?.resumeText
        if (since != null) PlayButton(Glyph.Play, translated("Fortsetzen ab %@", since), ready, main = true, lengthy = lengthy) { play(t.resumeFrom) }
        else PlayButton(Glyph.Play, translated("Abspielen"), ready, main = true, lengthy = lengthy) { play(null) }
        t?.remainingTime?.let { Text(it, style = Theme.small, color = Theme.fontQuiet) }
        t?.progress?.takeIf { it > 0 }?.let { ProgressBar(it, Modifier.clip(RoundedCornerShape(2.dp))) }
    }
}

/**
 * Mirrors `PrimaryButtonStyle` / `SecondaryButtonStyle`: 48 high, corner 10. White, never accent: the
 * accent carries state, not a button colour.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
internal fun PlayButton(symbol: Glyph, text: String, an: Boolean, main: Boolean,
                        /** Disabled on a sheet in `area` needs `erhoeht`; otherwise only a quiet text colour remains. */
                        lockedArea: Color = Theme.area,
                        /** Long press: the title's tile menu (`TileMenu.swift`, main button). */
                        lengthy: (() -> Unit)? = null, perform: () -> Unit) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    // `PrimaryButtonStyle`: white, 75 % pressed; `SecondaryButtonStyle`: 10 %, 16 % pressed. On immediately, 120 ms off.
    val press = remember { Animatable(0f) }
    LaunchedEffect(pressed) { if (pressed) press.snapTo(1f) else press.animateTo(0f, Motion.release()) }
    val jerk = rememberJerk()
    val color = when { !an -> Theme.fontVeryQuiet; main -> Theme.reason; else -> Theme.font }
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(RoundedCornerShape(Theme.corner))
            .drawBehind {
                drawRect(when {
                    !an -> lockedArea
                    // Main: white, 75 percent when pressed. Secondary: `area`, pressed `pressedArea`:
                    // two named tones instead of two computed ones.
                    main -> Color.White.copy(alpha = 1f - 0.25f * press.value)
                    else -> androidx.compose.ui.graphics.lerp(Theme.area, Theme.pressedArea, press.value)
                })
            }
            .then(when {
                !an -> Modifier
                lengthy != null -> Modifier.combinedClickable(source, null,
                    onLongClick = { jerk(Jerk.Medium); lengthy() }, onClick = perform)
                else -> Modifier.clickable(source, null, onClick = perform)
            }),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically) {
        // The icon carries the button's type size: 17 semibold on the main button, 15 medium on the secondary.
        Symbol(symbol, if (main) 17.dp else 15.dp, color = color, strength = if (main) Strength.Semibold else Strength.Medium)
        // Main button 17 semibold, secondary 15 medium; 16 is on no type scale.
        Text(text, style = if (main) Theme.categoryLarge else Theme.buttonText, color = color)
    }
}

/** Mirrors `Aktionsknopf`: 44 high, surface, corner 10, active in accent. */
@Composable
internal fun RowScope.ActionButton(symbol: Glyph, description: String, active: Boolean, perform: () -> Unit) {
    // All fields of a row have the same size: 48 x 48. Transparent over an image colour; when active
    // only the icon takes the accent, never the surface.
    Box(Modifier.weight(1f).height(Theme.buttonHeight).clip(RoundedCornerShape(Theme.corner)).background(buttonArea(LocalImageColor.current)).tapOn(perform)
            .semantics { this.selected = active; role = androidx.compose.ui.semantics.Role.Button },
        contentAlignment = Alignment.Center) {
        // `Theme.categoryLarge`: 17 semibold.
        Symbol(symbol, 17.dp, color = if (active) Theme.accent else Theme.font, strength = Strength.Semibold, description = description)
    }
}

/** Mirrors `CollapsibleText`: one line with an arrow, fully shown when expanded. The full text was too heavy for the page. */
@Composable
internal fun CollapsibleText(text: String) {
    var opened by remember { mutableStateOf(false) }
    val rotation by animateFloatAsState(if (opened) 180f else 0f, Motion.leap(), label = "pfeil")
    // `PressRow`, not a press button: a paragraph does not shrink. Text in full weight, 15 with 3 spacing.
    // Over an image colour no surface (`Theme.PressText`): a light box showed behind the text on
    // press; the press then shows only in the text's opacity.
    val onImage = LocalImageColor.current
    Row(Modifier.fillMaxWidth().animateContentSize(Motion.leap()).then(if (onImage) Modifier.pressText { opened = !opened } else Modifier.pressRow { opened = !opened }),
        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(text, style = Theme.body.copy(lineHeight = 21.sp), color = Theme.font,
             maxLines = if (opened) Int.MAX_VALUE else 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Symbol(Glyph.AngleDown, 12.dp, Modifier.padding(top = 4.dp).graphicsLayer { rotationZ = rotation },
               color = Theme.fontVeryQuiet, strength = Strength.Semibold)
    }
}

/** Mirrors `Abschnitt`: 26 spacing on top, row title, horizontal row. */
@Composable
internal fun Segment(title: String, spacing: Dp, content: LazyListScope.() -> Unit) {
    // `Abschnitt`: `railsSpacing` (28) on top, row title in its level's letter-spacing, 12 to the row.
    Column(Modifier.padding(top = Theme.railsSpacing), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, style = Theme.rail, color = Theme.font,
             modifier = Modifier.padding(horizontal = Theme.edgeSpacing))
        LazyRow(contentPadding = PaddingValues(horizontal = Theme.edgeSpacing),
                horizontalArrangement = Arrangement.spacedBy(spacing), content = content)
    }
}

/**
 * `items` with a stable key even if an identifier occurs twice. The same person can be in the
 * cast twice, the same title recommended twice, and a duplicate key throws in Compose. The repeat
 * therefore gets `#2`, `#3`. With a key, a tile keeps its state (loaded image) on reload instead of
 * being rebuilt by position.
 */
internal fun <T> LazyListScope.tilesWithKey(list: List<T>, identifier: (T) -> String,
                                                    content: @Composable LazyItemScope.(T) -> Unit) {
    val counted = HashMap<String, Int>()
    val key = list.map { e ->
        val k = identifier(e)
        val n = (counted[k] ?: 0) + 1
        counted[k] = n
        if (n == 1) k else "$k#$n"
    }
    items(list.size, key = { key[it] }) { content(list[it]) }
}

/** Mirrors `CastTile`: circle 76, name on two lines, role, 84 wide. */
@Composable
internal fun CastTile(p: WithAct, perform: () -> Unit = {}) {
    // Without an image the circle stays empty; `Picture` draws no icon there.
    Column(Modifier.width(84.dp).tapOn(perform), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(7.dp)) {
        AsyncImage(model = p.image, contentDescription = null, contentScale = ContentScale.Crop,
            modifier = Modifier.size(76.dp).clip(CircleShape).background(Theme.area))
        // Name 12 medium, as in `CastTile`, not the 13 under a poster.
        Text(p.name, style = Theme.tile.copy(fontSize = 12.sp, textAlign = TextAlign.Center),
             color = Theme.font, maxLines = 2, overflow = TextOverflow.Ellipsis)
        p.role?.let {
            Text(it, style = Theme.small.copy(textAlign = TextAlign.Center), color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** Mirrors `extrasRail`: 210 x 118, title, runtime only if known. */
@Composable
internal fun ExtraTile(e: Extra, play: () -> Unit) {
    Column(Modifier.width(210.dp).clickable(onClick = play), verticalArrangement = Arrangement.spacedBy(7.dp)) {
        AsyncImage(model = e.image, contentDescription = null, contentScale = ContentScale.Crop,
                   modifier = Modifier.size(210.dp, 118.dp).clip(RoundedCornerShape(Theme.cornerTile)).background(Theme.area))
        Text(e.name, style = Theme.tile, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis)
        e.runtime?.let { Text(it, style = Theme.small, color = Theme.fontVeryQuiet, maxLines = 1) }
    }
}

/** Mirrors `fileExcerpt`: container, video, up to two audio tracks, subtitles; audio in accent. */
@Composable
private fun FileExcerpt(d: FileInfo) {
    // Group title 22 on top, then a line above and below every row; values in full weight,
    // right-aligned with tabular digits (`FileRow`), 8 vertical.
    Column(Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 22.dp)) {
        // `Gruppentitel` brings its own side margin: on iPhone it sits one step indented above the
        // rows; the same here.
        Text(translated("Datei"), style = Theme.rail,
             color = Theme.fontQuiet, modifier = Modifier.padding(start = Theme.edgeSpacing, bottom = 10.dp))
        val rows = buildList {
            d.container?.let { add(translated("Container") to it) }
            d.video?.let { add(translated("Video") to it) }
            // The second audio row does not repeat the label.
            d.audio.forEachIndexed { i, audio -> add((if (i == 0) translated("Ton") else " ") to audio) }
            add(translated("Untertitel") to d.subtitle)
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))
        rows.forEach { (name, value) ->
            Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Text(name, style = Theme.small, color = Theme.fontQuiet)
                Spacer(Modifier.weight(1f))
                Text(value, style = Theme.small.copy(textAlign = TextAlign.End, fontFeatureSettings = "tnum"), color = Theme.font)
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))
        }
    }
}

/**
 * Mirrors `DetailHeader`: back on the left, the title fades in from 150 over 70 points, the
 * gradient over the image turns into the background meanwhile, and the hairline comes along. The
 * strength is only read in the draw phase, so scrolling does not redraw the page.
 */
@Composable
internal fun DetailHeader(title: String, strength: () -> Float, back: () -> Unit,
                        /** A button on the right, e.g. Edit; without it an empty 44 field keeps the title centred. */
                        right: (@Composable () -> Unit)? = null) {
    Box(Modifier.fillMaxWidth()
            // Over the hero image the header gradient at 70 %, which yields with the bar.
            .drawBehind { headerGradient(0.7f * (1f - strength())) }) {
        // Glass on iPhone, solid background here (platform): Compose cannot blur what lies behind a
        // view (`RenderEffect` only affects its own layer). A background that fades in with the bar
        // carries the title just as well.
        Box(Modifier.matchParentSize().graphicsLayer { alpha = strength() }.background(Theme.reason))
        Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(1.dp).graphicsLayer { alpha = strength() }.background(Theme.line))
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(start = 8.dp, end = Theme.edgeSpacing, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(44.dp).tapOn(back), contentAlignment = Alignment.Center) {
                Symbol(Glyph.AngleLeft, 20.dp, color = Theme.font, strength = Strength.Semibold, description = translated("Zurück"))
            }
            Text(title, style = Theme.categoryLarge, color = Theme.font,
                 maxLines = 1, overflow = TextOverflow.Ellipsis,
                 modifier = Modifier.weight(1f).padding(horizontal = 4.dp).graphicsLayer { alpha = strength() }.clearAndSetSemantics {})
            // On the right the same space as the arrow on the left, so the title does not sit crooked.
            if (right != null) right() else Spacer(Modifier.width(44.dp))
        }
    }
}

/** Mirrors `Hinweisstreifen`: capsule at the bottom, goes away by itself after three seconds. */
@Composable
internal fun HintStrip(text: String?, modifier: Modifier, close: () -> Unit) {
    LaunchedEffect(text) { if (text != null) { delay(3000); close() } }
    val remembered = remember { arrayOfNulls<String>(1) }
    if (text != null) remembered[0] = text
    // Moves a quarter of its own height; a pure crossfade appeared out of nothing.
    AnimatedVisibility(text != null, modifier,
        enter = fadeIn(tween(200, easing = Motion.soft)) + slideInVertically(tween(200, easing = Motion.soft)) { it / 4 },
        exit = fadeOut(tween(150, easing = Motion.soft)) + slideOutVertically(tween(150, easing = Motion.soft)) { it / 4 }) {
        // A strip from `area`, without a border; the surface is already the object.
        Text(remembered[0].orEmpty(), style = Theme.body.copy(textAlign = TextAlign.Center), color = Theme.font,
             modifier = Modifier.navigationBarsPadding().padding(start = 24.dp, end = 24.dp, bottom = 34.dp).clip(CircleShape).background(Theme.area)
                 .padding(horizontal = 18.dp, vertical = 12.dp))
    }
}

/**
 * The capsule all evidence items sit in; mirrors `mark(...)` in `ProofRow`: icon 11, word 13
 * medium, 6 between, left 8, right 10, top/bottom 4, surface 15 % of the colour, corner
 * `cornerSmall`. One capsule, not three; the row drifted apart that way before.
 */
@Composable
private fun ProofMark(symbolText: Glyph, word: String, color: Color, strength: Strength) {
    Row(Modifier.clip(RoundedCornerShape(Theme.cornerSmall)).background(color.copy(alpha = 0.15f))
            .padding(start = 8.dp, end = 10.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Symbol(symbolText, 11.dp, color = color, strength = strength)
        Text(word, style = Theme.tile, color = color)
    }
}
