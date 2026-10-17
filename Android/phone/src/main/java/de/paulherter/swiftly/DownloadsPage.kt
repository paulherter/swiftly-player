package de.paulherter.swiftly

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.motionReduced
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.future.await
import android.net.Uri
import de.paulherter.swiftly.shared.PrimaryButton
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.runtime.getValue
import androidx.compose.runtime.derivedStateOf
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

private fun size(bytes: Long) = Kern.downloadSize(bytes)

/**
 * Mirrors iOS `DownloadRing`: one symbol for all states. Downloading: an arc with a square (the
 * square means pause, not cancel; nothing is discarded here). Done: filled circle with an arrow,
 * not a checkmark, which belongs to "watched".
 */
@Composable
fun DownloadRing(p: DownloadItem?, mass: Dp = 28.dp,
                 /** The estimated progress between two reports, the same value as the number and bar beside it. */
                 shareNow: Double? = null) {
    val raw = if (p?.state == "laedt") shareNow ?: p.share else p?.share
    val share by animateFloatAsState((raw ?: 0.0).toFloat().coerceAtLeast(0.02f), tween(400, easing = LinearEasing), label = "ring")
    Box(Modifier.size(mass), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val thin = 1.5.dp.toPx()
            val thick = 2.dp.toPx()
            val r = size.minDimension / 2
            when (p?.state) {
                null -> drawCircle(Theme.fontQuiet, r - thin / 2, style = Stroke(thin))
                "wartet" -> drawCircle(Theme.fontVeryQuiet, r - thick / 2,
                    style = Stroke(thick, pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 4.dp.toPx()))))
                "laedt", "angehalten" -> {
                    // Same track as `ProgressBar`: white 30 %, the length of the whole.
                    drawCircle(Color.White.copy(alpha = 0.30f), r - thick / 2, style = Stroke(thick))
                    drawArc(if (p.state == "laedt") Theme.accent else Theme.fontQuiet, -90f, 360f * share, false,
                            topLeft = Offset(thick / 2, thick / 2), size = Size(size.width - thick, size.height - thick),
                            style = Stroke(thick, cap = StrokeCap.Round))
                    if (p.state == "laedt") {
                        val k = size.minDimension * 0.32f
                        // The square means pause, not cancel; accent color like the arc.
                        drawRoundRect(Theme.accent, Offset((size.width - k) / 2, (size.height - k) / 2), Size(k, k), CornerRadius(1.5.dp.toPx()))
                    }
                }
                "fertig" -> drawCircle(Theme.accent, r)
                // `error`, not `warning`: an aborted download went wrong.
                "fehler" -> drawCircle(Theme.error, r - thick / 2, style = Stroke(thick))
            }
        }
        when (p?.state) {
            // Mirrors `image(...)` on iPhone: semibold, arrow and exclamation mark 13, pause and play 11.
            null -> Symbol(Glyph.ArrowDown, 13.dp, color = Theme.font, strength = Strength.Semibold, description = translated("Laden"))
            "wartet" -> Symbol(Glyph.Pause, 11.dp, color = Theme.fontVeryQuiet, strength = Strength.Semibold, description = translated("Wartet"))
            "laedt" -> Box(Modifier.semantics { contentDescription = translated("Lädt, anhalten") })
            "angehalten" -> Symbol(Glyph.Play, 11.dp, color = Theme.font, strength = Strength.Semibold, description = translated("Angehalten, fortsetzen"))
            "fertig" -> Symbol(Glyph.ArrowDown, 13.dp, color = Theme.reason, strength = Strength.Semibold, description = translated("Geladen, entfernen"))
            "fehler" -> Symbol(Glyph.Exclamation, 13.dp, color = Theme.error, strength = Strength.Semibold, description = translated("Fehlgeschlagen, erneut versuchen"))
        }
    }
}

/** The ring with a 44 dp touch area; smaller is not tappable. */
@Composable
private fun RingButton(app: SwiftlyApplication, p: DownloadItem?, mass: Dp = 28.dp, shareNow: Double? = null, create: () -> Unit = {}) {
    // Start, pause, resume: a haptic tick on tap, like any other button with consequences.
    val jerk = rememberJerk()
    Box(Modifier.size(44.dp).tapOn { jerk(Jerk.Lightweight); app.downloads.paintTap(p, create) }, contentAlignment = Alignment.Center) {
        DownloadRing(p, mass, shareNow)
    }
}

/**
 * Mirrors `DownloadField`: the fifth field of the action row, next to the watchlist (both mean
 * "for later"). Without downloads enabled the row has four fields.
 */
@Composable
internal fun RowScope.DownloadField(app: SwiftlyApplication, id: String, title: String) {
    val p = app.downloads.entries(id)
    val jerk = rememberJerk()
    // 48 x 48 like every other field of the action row (it was the only one at 44). The download
    // choice behind it is unchanged; this is only about the field.
    Box(Modifier.weight(1f).height(Theme.buttonHeight).clip(RoundedCornerShape(Theme.corner)).background(buttonArea(LocalImageColor.current))
            .tapOn { jerk(Jerk.Lightweight); app.downloads.paintTap(p) { app.downloadsCreate(listOf(id), title) } },
        contentAlignment = Alignment.Center) {
        // A plain arrow without a download, a filled circle when downloaded; both 17 semibold like the
        // neighbor. The ring (22) is shown only while it runs, waits or hangs.
        when (p?.state) {
            null -> Symbol(Glyph.ArrowDown, 17.dp, color = Theme.font, strength = Strength.Semibold, description = translated("Laden"))
            "fertig" -> Symbol(Glyph.LoadCircleFilled, 17.dp, color = Theme.accent, strength = Strength.Semibold, description = translated("Geladen, entfernen"))
            else -> DownloadRing(p, 22.dp)
        }
    }
}

/**
 * Mirrors `LoadSheet`, shown before every start. Which of the three layouts applies is decided by
 * `DownloadRules.slot` and `mayLoad`, not by the sheet. A movie picks its quality here
 * (`qualitySelect`); a series brings it from the download choice.
 */
fun loadSheetShow(app: SwiftlyApplication, newOne: List<DownloadItem>, images: Map<String, String>, title: String,
                    qualitySelect: Boolean = false) {
    val v = app.downloads
    val free = v.free()
    val slot = JSONObject(Kern.downloadSpace(newOne.sumOf { it.bytes }, free, DownloadItem.list(v.entries.value)))
    val header = if (slot.getBoolean("reicht")) translated("%@ laden", title) else translated("Nicht genug Platz")
    app.sheet.value = SheetRequest(header, emptyList(), null, content = { close ->
        LoadContent(app, newOne, images, free, qualitySelect, close)
    }) {}
}

@Composable
private fun LoadContent(app: SwiftlyApplication, original: List<DownloadItem>, images: Map<String, String>,
                       free: Long, qualitySelect: Boolean, close: () -> Unit) {
    val v = app.downloads
    var choice by remember { mutableStateOf("original") }
    // The items in the chosen quality: Matroska and estimated size once converting.
    val newOne = remember(choice) {
        if (!qualitySelect || choice == "original") original
        else JSONArray(Kern.downloadInQuality(DownloadItem.list(original), choice)).let { a ->
            (0 until a.length()).map { DownloadItem.read(a.getJSONObject(it)) }
        }
    }
    val bytes = newOne.sumOf { it.bytes }
    val converted = newOne.any { it.converted }
    val slot = remember(bytes) { JSONObject(Kern.downloadSpace(bytes, free, DownloadItem.list(v.entries.value))) }
    val selectable = app.settings.downloadQualitySelectable
    val offered = remember(selectable) {
        qualitiesRead(Kern.downloadQualities(selectable, JSONArray(original.map { JSONArray(listOf(it.bytes, it.runtimeTicks ?: 0L)) }).toString()))
    }
    val selectionShow = qualitySelect && selectable && offered.size > 1
    /** The size with "≈" when estimated. */
    fun sizeText(b: Long) = (if (converted) "≈ " else "") + size(b)
    @Composable fun qualityRow() {
        Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(translated("Qualität"), style = TextStyle(fontSize = 15.sp), color = Theme.fontQuiet, modifier = Modifier.weight(1f))
            QualityBadge(choice, offered, true,
                               size = { q -> original.sumOf { Kern.downloadEstimated(q, it.bytes, it.runtimeTicks ?: 0L) } }) { choice = it }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))
    }
    val load = { v.insert(newOne, images) }
    Column(Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 4.dp, bottom = 16.dp)) {
        when {
            !slot.getBoolean("reicht") -> {
                SheetRow(translated("Diese Datei"), sizeText(bytes))
                // The obvious way out is a smaller version; if that is enough, the sheet switches.
                if (selectionShow) qualityRow()
                SheetRow(translated("Frei auf dem Gerät"), size(free), cautionary = true)
                if (slot.getBoolean("reichtNachAufraeumen")) {
                    SheetRow(translated("Gesehene Titel"), size(slot.getLong("entbehrlichBytes")))
                    ButtonRail {
                        PlayButton(Glyph.Papierkorb, translated("Gesehene entfernen und laden"), true, main = true) {
                            close()
                            val distance = slot.getJSONArray("entbehrlich").let { a -> (0 until a.length()).map { a.getString(it) } }
                            v.remove(distance)
                            load()
                        }
                        PlayButton(Glyph.Cross, translated("Abbrechen"), true, main = false, perform = close)
                    }
                } else {
                    SheetHint(translated("Auch nach dem Entfernen der gesehenen Titel reicht der Platz nicht. In den Einstellungen unter Offline steht, was belegt ist."))
                    ButtonRail { PlayButton(Glyph.Checkmark, translated("Verstanden"), true, main = false, perform = close) }
                }
            }
            !v.mayLoad() -> {
                SheetRow(translated("Größe"), sizeText(bytes))
                SheetRow(translated("Kein WLAN"), translated("Mobilfunk"), cautionary = true)
                ButtonRail {
                    PlayButton(Glyph.Clock, translated("In die Warteschlange"), true, main = true) { close(); load() }
                    PlayButton(Glyph.BarReception, translated("Jetzt über Mobilfunk laden"), true, main = false) {
                        close(); app.settings.onlyOverWLAN = false; load()
                    }
                }
                SheetHint(translated("Der Download startet von selbst, sobald WLAN da ist."))
            }
            else -> {
                SheetRow(translated("Größe"), sizeText(bytes))
                if (selectionShow) qualityRow()
                else {
                    // If the series comes converted from the choice, the tier is shown first.
                    val q = newOne.firstOrNull()?.takeIf { it.converted }?.let { Kern.downloadBadge(it.quality.orEmpty()) }
                    val c = newOne.singleOrNull()?.container?.uppercase()
                    listOfNotNull(q, c).takeIf { it.isNotEmpty() }?.let { SheetRow(translated("Qualität"), it.joinToString(" · ")) }
                }
                SheetRow(translated("Danach frei"), size(slot.getLong("freiDanach")))
                ButtonRail { PlayButton(Glyph.ArrowDown, translated("Laden"), true, main = true) { close(); load() } }
                if (converted) SheetHint(translated("Der Server wandelt die Datei beim Laden um. Die Größe ist geschätzt."))
                else SheetHint(translated("Swiftly lädt die Originaldatei, in derselben Qualität wie beim Streamen."))
            }
        }
    }
}

@Composable
private fun SheetRow(title: String, value: String, cautionary: Boolean = false) {
    // `heightIn(min=)`, not `height()`: with large system fonts the rows grow instead of hitting a
    // fixed height.
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = TextStyle(fontSize = 15.sp), color = Theme.fontQuiet, modifier = Modifier.weight(1f))
        Text(value, style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium, fontFeatureSettings = "tnum"),
             color = if (cautionary) Theme.warning else Theme.font)
    }
    Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))
}

@Composable
private fun ButtonRail(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.padding(top = 18.dp), verticalArrangement = Arrangement.spacedBy(10.dp), content = content)
}

@Composable
private fun SheetHint(text: String) {
    Text(text, style = TextStyle(fontSize = 13.sp, lineHeight = 18.sp), color = Theme.fontVeryQuiet, modifier = Modifier.padding(top = 12.dp))
}

private data class DownloadGroup(val id: String, val title: String, val bytes: Long, val seriesIdentifier: String?, val episodes: List<String>)

private fun groupsRead(json: String): List<DownloadGroup> = JSONArray(json).let { a ->
    (0 until a.length()).map { i ->
        val o = a.getJSONObject(i)
        DownloadGroup(o.getString("id"), o.getString("titel"), o.optLong("bytes"), o.fieldText("serienId"),
                       o.getJSONArray("folgen").let { f -> (0 until f.length()).map { f.getString(it) } })
    }
}

private fun rung(p: DownloadItem) = Kern.downloadQualityName(p.quality.orEmpty())

/** Like `Downloadzeile.subline`: episode or runtime, then the state. Downloading and errors replace everything. */
private fun subline(p: DownloadItem, loaded: Long = p.loaded): String {
    val parts = mutableListOf<String>()
    // Translated: German "F" for Folge, English "E" for episode. Was hard-coded "F", even in English.
    if (p.season != null && p.episode != null) parts += translated("S%d F%d", p.season, p.episode)
    else p.runtimeTicks?.takeIf { it > 0 }?.let { parts += translated("%lld Min.", (it / 600_000_000L).toInt()) }
    when (p.state) {
        // Fixed unit, fixed digits (`DownloadRules.progress`): `size` switched mid-download from
        // "845 MB" to "1 GB" and "1,01 GB", and the row changed width at every step. When
        // converting, the end is estimated, so "≈" precedes it.
        "laedt" -> return JSONArray(Kern.downloadProgress(loaded, p.bytes)).let { f ->
            translated("%@ von %@", f.getString(0), (if (p.converted) "≈ " else "") + f.getString(1))
        }
        "wartet" -> { parts += translated("wartet"); if (p.converted) parts += rung(p) }
        "angehalten" -> { parts += translated("angehalten"); if (p.converted) parts += rung(p) }
        "fehler" -> return p.reason ?: translated("Fehlgeschlagen")
        else -> {
            parts += size(p.bytes)
            // The chosen tier is shown where the container is otherwise shown.
            if (p.converted) parts += rung(p) else p.container?.let { parts += it.uppercase() }
            // Quiet, no error color: the file is still running.
            if (!p.stillOnTheServer) parts += translated("nicht mehr auf dem Server")
        }
    }
    return parts.joinToString(" · ")
}


/**
 * Mirrors `DownloadsView`. On top what is still running, below what is on the device; a series is
 * one row. Removal goes through "Edit", not swiping: running items are selectable too, and so is
 * a series as a whole. The storage bar deliberately has no fixed upper limit.
 */
@Composable
fun DownloadsPage(app: SwiftlyApplication, open: (Destination) -> Unit) {
    val v = app.downloads
    val all = v.entries.value
    val ongoing = all.filter { it.state != "fertig" }.sortedBy { it.created }
    val finished = all.filter { it.state == "fertig" }
    val groups = remember(finished) { groupsRead(Kern.downloadGroups(DownloadItem.list(finished))) }
    var edit by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf(emptySet<String>()) }
    LaunchedEffect(all.isEmpty()) { if (all.isEmpty()) { edit = false; selected = emptySet() } }
    val network = v.network.value
    fun toggle(ids: List<String>) { selected = if (ids.all { it in selected }) selected - ids.toSet() else selected + ids }

    val list = rememberLazyListState()
    val density = LocalDensity.current
    val offset by remember {
        derivedStateOf { if (list.firstVisibleItemIndex > 0) 100f else list.firstVisibleItemScrollOffset / density.density }
    }

    Box(Modifier.fillMaxSize().background(Theme.reason)) {
    HeaderAndContent(header = {
        RootHeader({ offset }) {
            // Centered, not at the top: without a line under the title, the top looks off. No usage under
            // the title: the same information is at the storage bar, and a page title with a sub-line
            // would look different from every other root page.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(translated("Downloads"), style = Theme.titleLarge, color = Theme.font, modifier = Modifier.weight(1f))
                HeaderTargets(app, open) {
                    if (all.isNotEmpty()) EditButton(edit) { edit = it; if (!it) selected = emptySet() }
                }
            }
            if (all.isNotEmpty()) Box(Modifier.padding(top = 12.dp)) { CacheBar(all.sumOf { it.bytes }, remember(all) { v.free() }) }
        }
    }) { headerDp ->
        LazyColumn(Modifier.fillMaxSize().areaContent(), state = list,
                   contentPadding = PaddingValues(top = headerDp, bottom = if (edit) 84.dp else 24.dp)) {
            if (ongoing.isNotEmpty()) {
                item(key = "kopf-laufend") {
                    GroupsTitle(translated(if (network) "Lädt gerade" else "Wartet auf Netz"), Modifier.padding(top = 4.dp))
                }
                items(ongoing, key = { "l-" + it.id }) { p ->
                    DownloadRow(app, p, v.imageFile(p.id), p.art == "folge", edit, p.id in selected,
                        perform = if (edit) { { toggle(listOf(p.id)) } } else null,
                        modifier = Modifier.animateItem())
                }
            }
            if (groups.isNotEmpty()) {
                // No heading above the downloaded items. It used to say "On the device", but on the downloads
                // page everything is on the device, so it said nothing. The gap to "Downloading" above stays.
                item(key = "abstand-geraet") { Spacer(Modifier.height(if (ongoing.isEmpty()) 4.dp else 26.dp)) }
                items(groups, key = { "g-" + it.id }) { g ->
                    val sid = g.seriesIdentifier
                    val first = all.firstOrNull { it.id == g.episodes.firstOrNull() }
                    if (sid != null && first != null) {
                        // One row in both positions, no swap, so it slides with the others.
                        DownloadRow(app, first, v.imageFile(sid), false, edit, g.episodes.all { it in selected },
                            perform = { if (edit) toggle(g.episodes) else open(Destination(sid, g.title, "Downloadserie")) },
                            group = g.title to (translated("%lld Folgen", g.episodes.size) + " · " + size(g.bytes)
                                + Kern.downloadShared(DownloadItem.list(all.filter { it.id in g.episodes })).let { if (it.isEmpty()) "" else " · $it" }),
                            modifier = Modifier.animateItem())
                    } else if (first != null) {
                        DownloadRow(app, first, v.imageFile(first.id), first.art == "folge", edit, first.id in selected,
                            perform = { if (edit) toggle(listOf(first.id)) else app.play.value = PlayRequest(first.id, first.resumeFrom) },
                            modifier = Modifier.animateItem())
                    }
                }
            }
        }
    }
    if (all.isEmpty()) {
        EmptyState(Glyph.LoadCircle, translated("Noch nichts geladen"),
            translated("Lad was runter, bevor der Zug ins Funkloch fährt."))
    }
    if (edit) {
        DeleteBar(app, selected, Modifier.align(Alignment.BottomCenter)) {
            v.remove(selected)
            selected = emptySet()
            edit = false
        }
    }
    }
}

/**
 * Mirrors `EditButton`: pencil and cross at the top right; the same button on the download
 * list and on the page of a downloaded series. 17 semibold, in edit mode the cross in the accent.
 */
@Composable
internal fun EditButton(edit: Boolean, setDown: (Boolean) -> Unit) {
    Box(Modifier.size(44.dp).tapOn { setDown(!edit) }, contentAlignment = Alignment.Center) {
        Symbol(if (edit) Glyph.Cross else Glyph.Pencil, 17.dp,
               color = if (edit) Theme.accent else Theme.font, strength = Strength.Semibold,
               description = translated("Bearbeiten"))
    }
}

/**
 * Mirrors `DeleteBar`: the main button at full width, disabled while nothing is selected;
 * before it, the sheet with "Remove". "Remove 3 · 7.42 GB".
 */
@Composable
internal fun DeleteBar(app: SwiftlyApplication, selected: Set<String>, modifier: Modifier, remove: () -> Unit) {
    val jerk = rememberJerk()
    val bytes = app.downloads.entries.value.filter { it.id in selected }.sumOf { it.bytes }
    val title = translated("%lld entfernen", selected.size) + " · " + size(bytes)
    Box(modifier.fillMaxWidth().background(Theme.reason)
            .padding(horizontal = Theme.edgeSpacing).padding(top = 8.dp, bottom = 8.dp)) {
        PrimaryButton(title, released = selected.isNotEmpty()) {
            app.sheet.value = SheetRequest(title, listOf(Choice("weg", translated("Entfernen"))), null,
                                          mapOf("weg" to Glyph.Papierkorb), cautionary = setOf("weg")) { jerk(Jerk.Medium); remove() }
        }
    }
}

/**
 * Mirrors `cacheBar`, instead of an upper limit: our share in the accent, free space in
 * `erhoeht`, together the whole capsule. 6 high.
 */
@Composable
private fun CacheBar(used: Long, free: Long) {
    val whole = (used + free.coerceAtLeast(0)).coerceAtLeast(1).toFloat()
    val own = (used / whole).coerceIn(0f, 1f)
    Row(Modifier.fillMaxWidth().height(6.dp).clip(CircleShape).clearAndSetSemantics {}) {
        if (own > 0f) Box(Modifier.weight(own).fillMaxHeight().background(Theme.accent))
        if (own < 1f) Box(Modifier.weight(1f - own).fillMaxHeight().background(Theme.raised))
    }
}

/**
 * One clock for all downloading rows. It runs only while at least one row is visibly downloading
 * (the list builds only visible rows), and only on the main thread: registered and unregistered
 * from `DisposableEffect`.
 */
private object DownloadTick {
    val strike = mutableLongStateOf(0L)
    private var user = 0
    private var run: kotlinx.coroutines.Job? = null
    private val section = kotlinx.coroutines.MainScope()
    fun an() { if (user++ == 0) run = section.launch { while (true) { delay(250); strike.longValue++ } } }
    fun from() { if (--user == 0) { run?.cancel(); run = null } }
}

/** Like `Downloadzeile.underColor`: accent while downloading, `error` on error, otherwise very quiet. */
private fun underColor(p: DownloadItem) = when (p.state) {
    "laedt" -> Theme.accent
    "fehler" -> Theme.error
    else -> Theme.fontVeryQuiet
}

/**
 * Mirrors `Downloadzeile`: still 116 x 65 (landscape) or poster 64 x 96, spacing 12, title 15
 * semibold on one line, sub-line 12 with tabular digits in the state color, below it the shared
 * `ProgressBar` as a capsule. Vertical padding 10.
 *
 * While downloading the row keeps counting, four times a second on one clock for all rows
 * (`DownloadTick`). A loop per row at 30 ticks per second meant six loops with a JNI call and a
 * recomposition per frame for six downloads, for a number nobody reads that fast. The manager
 * reports at most once a second; in between `ProgressEstimator` in the core keeps
 * estimating. Number, bar and ring read the same value. Estimating happens only while bytes
 * really arrive: paused, waiting, failed or offline, the number is shown immediately.
 *
 * In edit mode the circle slides in from the left and pushes the row ahead of it, with the sheet
 * curve and for all rows at once; with reduced motion it is a cross-fade.
 */
@Composable
private fun DownloadRow(app: SwiftlyApplication, p: DownloadItem, image: File, landscape: Boolean,
                          edit: Boolean, selected: Boolean, perform: (() -> Unit)?, lengthy: (() -> Unit)? = null,
                          /** Title and sub-line when the row stands for a whole series. */
                          group: Pair<String, String>? = null, modifier: Modifier = Modifier) {
    val comesWas = group == null && p.state == "laedt" && app.downloads.network.value
    DisposableEffect(p.id, comesWas) {
        if (comesWas) DownloadTick.an() else Kern.downloadEstimatorHalt(p.id)
        onDispose { if (comesWas) DownloadTick.from() }
    }
    val loaded = when {
        // Reading the tick ties the row to the clock: it recomposes on every tick, otherwise not.
        comesWas -> { DownloadTick.strike.longValue; Kern.downloadEstimatorValue(p.id, p.loaded) }
        group == null && (p.state == "angehalten" || p.state == "laedt") -> maxOf(Kern.downloadEstimatorValue(p.id, p.loaded), p.loaded)
        else -> p.loaded
    }
    val share = if (p.bytes > 0) (loaded.toDouble() / p.bytes).coerceIn(0.0, 1.0) else p.share
    val calm = motionReduced()

    Row(modifier.fillMaxWidth().dim(perform, lengthy).padding(horizontal = Theme.edgeSpacing, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        AnimatedVisibility(edit,
            enter = if (calm) fadeIn(Motion.fadeReduced())
                    else expandHorizontally(Motion.sheet(), Alignment.Start) + slideInHorizontally(Motion.sheet()) { -it } + fadeIn(Motion.sheet()),
            exit = if (calm) fadeOut(Motion.fadeReduced())
                   else shrinkHorizontally(Motion.sheet(), Alignment.Start) + slideOutHorizontally(Motion.sheet()) { -it } + fadeOut(Motion.sheet())) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                // 20 semibold: the row heading, and thus the next real size.
                Symbol(if (selected) Glyph.CheckmarkCircleFilled else Glyph.Ring, 20.dp, color = if (selected) Theme.accent else Theme.fontVeryQuiet,
                       strength = Strength.Semibold)
                Spacer(Modifier.width(12.dp))
            }
        }
        // Watched as in the episode list, also offline: the state is stored in the item. Only on a
        // single row; a series row stands for many episodes.
        val watched = group == null && p.watched
        // Watched is only darker, not transparent, as in the episode list (`WATCHED_DIM`).
        Box(Modifier.size(if (landscape) 116.dp else 64.dp, if (landscape) 65.dp else 96.dp).clip(RoundedCornerShape(Theme.cornerTile)).background(Theme.area)) {
            AsyncImage(model = image, contentDescription = null, contentScale = ContentScale.Crop,
                       colorFilter = if (watched) WATCHED_DIM else null, modifier = Modifier.fillMaxSize())
            if (watched) WatchedCheckmark()
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(group?.first ?: p.title, style = Theme.listTitle, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(group?.second ?: subline(p, loaded), style = Theme.small.copy(fontFeatureSettings = "tnum"),
                 color = if (group != null) Theme.fontVeryQuiet else underColor(p), maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (group == null && (p.state == "laedt" || p.state == "angehalten")) {
                share?.let { ProgressBar(it, Modifier.padding(top = 5.dp), round = true) }
            }
        }
        if (group != null) {
            Spacer(Modifier.width(12.dp))
            Symbol(Glyph.AngleRight, 13.dp, color = Theme.fontVeryQuiet, strength = Strength.Semibold)
        } else {
            AnimatedVisibility(!edit,
                enter = if (calm) fadeIn(Motion.fadeReduced()) else expandHorizontally(Motion.sheet(), Alignment.End) + fadeIn(Motion.sheet()),
                exit = if (calm) fadeOut(Motion.fadeReduced()) else shrinkHorizontally(Motion.sheet(), Alignment.End) + fadeOut(Motion.sheet())) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Spacer(Modifier.width(12.dp))
                    RingButton(app, p, shareNow = share)
                }
            }
        }
    }
}

/**
 * Mirrors `SelectionTap` + `Abdunkeln`: no gray surface. Tapping here only selects or plays; the
 * content dims briefly (0.6), which is enough feedback. The press shows immediately, the release
 * fades out over 120 ms. Without an action the row stays still.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
private fun Modifier.dim(perform: (() -> Unit)?, lengthy: (() -> Unit)?): Modifier = composed {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val an = perform != null
    val press = remember { Animatable(0f) }
    LaunchedEffect(pressed, an) { if (pressed && an) press.snapTo(1f) else press.animateTo(0f, Motion.release()) }
    graphicsLayer { alpha = 1f - 0.4f * press.value }
        .combinedClickable(source, null, enabled = an || lengthy != null, onLongClick = lengthy, onClick = { perform?.invoke() })
}

/**
 * Mirrors `DownloadSeriesView`: the series on the device, as a detail page. Big picture on top with
 * name and "N episodes · X GB", a play button, below it the episodes by season. Built from the
 * series page blocks (`Hero`, `PlayButton`, `DetailHeader`), no design of its own.
 *
 * Everything comes from disk, since there may be no network: the picture is the saved header
 * image of the series, else the landscape image of the next episode, else the poster. If an
 * older download lacks the header image, it is fetched once when online.
 *
 * Three ways to remove: swipe left, long press ("Remove download"), or Edit at the top with
 * selection circles and the button at the bottom, as in the list. When the last episode is gone
 * the page goes back.
 */
@Composable
fun DownloadSeriesPage(app: SwiftlyApplication, target: Destination, back: () -> Unit) {
    val v = app.downloads
    val episodes = v.entries.value.filter { it.seriesIdentifier == target.id }.sortedWith(compareBy({ it.season ?: 0 }, { it.episode ?: 0 }))
    LaunchedEffect(episodes.isEmpty()) { if (episodes.isEmpty()) back() }
    var edit by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf(emptySet<String>()) }
    var caughtUp by remember { mutableStateOf<File?>(null) }

    // `DownloadRules.nextEpisode`: the first unwatched finished one, otherwise from the start.
    val next = remember(episodes) { JSONObject(Kern.downloadNextEpisode(DownloadItem.list(episodes))) }
    val nextEpisode = episodes.firstOrNull { it.id == next.fieldText("id") }
    val headerImage = caughtUp ?: v.headerImage(target.id)
        ?: (nextEpisode ?: episodes.firstOrNull())?.let { p -> v.imageFile(p.id).takeIf { it.exists() } }
        ?: v.imageFile(target.id).takeIf { it.exists() }
    val detail = translated("%lld Folgen", episodes.size) + " · " + size(episodes.sumOf { it.bytes })

    LaunchedEffect(target.id) {
        if (v.headerImage(target.id) != null) return@LaunchedEffect
        val address = runCatching { app.kern.downloadHeaderImage(target.id, app.headerImageWidth()).await() }.getOrNull()
        if (!address.isNullOrEmpty()) caughtUp = v.headerImageCatchUp(target.id, address)
    }

    fun remove(ids: Collection<String>) { v.remove(ids) }
    fun toggle(id: String) { selected = if (id in selected) selected - id else selected + id }

    val list = rememberLazyListState()
    val density = LocalDensity.current
    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        LazyColumn(Modifier.fillMaxSize(), state = list,
                   contentPadding = PaddingValues(bottom = if (edit) 84.dp else 32.dp)) {
            item(key = "held") {
                Hero(headerImage?.let { Uri.fromFile(it).toString() }, target.name, detail)
            }
            item(key = "knopf") {
                Box(Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 14.dp, bottom = 22.dp)) {
                    PlayButton(Glyph.Play, next.fieldText("knopftext") ?: translated("Abspielen"),
                               an = nextEpisode != null, main = true) {
                        // At the saved position, the same with and without network.
                        nextEpisode?.let { app.play.value = PlayRequest(it.id, it.resumeFrom) }
                    }
                }
            }
            episodes.groupBy { it.season }.forEach { (number, season) ->
                if (number != null) item(key = "s-$number") {
                    GroupsTitle(translated("Staffel %lld", number), Modifier.padding(top = 6.dp))
                }
                items(season, key = { it.id }) { p ->
                    Box(Modifier.animateItem()) {
                        SwipeRow(Glyph.Papierkorb, translated("Entfernen"), color = Theme.error, perform = { remove(listOf(p.id)) }) {
                            DownloadRow(app, p, v.imageFile(p.id), true, edit, p.id in selected,
                                perform = when {
                                    edit -> { { toggle(p.id) } }
                                    p.state == "fertig" -> { { app.play.value = PlayRequest(p.id, p.resumeFrom) } }
                                    else -> null
                                },
                                lengthy = {
                                    app.sheet.value = SheetRequest(p.title, listOf(Choice("weg", translated("Download entfernen"))), null,
                                                                  mapOf("weg" to Glyph.Papierkorb), cautionary = setOf("weg")) { remove(listOf(p.id)) }
                                })
                        }
                    }
                }
                item(key = "e-$number") { Spacer(Modifier.height(16.dp)) }
            }
            item(key = "fuss") { Spacer(Modifier.navigationBarsPadding()) }
        }
        DetailHeader(target.name, {
            if (list.firstVisibleItemIndex > 0) 1f
            else ((list.firstVisibleItemScrollOffset / density.density - 150f) / 70f).coerceIn(0f, 1f)
        }, back, right = { EditButton(edit) { edit = it; if (!it) selected = emptySet() } })
        if (edit) {
            DeleteBar(app, selected, Modifier.align(Alignment.BottomCenter).navigationBarsPadding()) {
                remove(selected)
                selected = emptySet()
                edit = false
            }
        }
    }
}

/**
 * Mirrors the "Offline" group in `SettingsView`: off until someone wants it. Turning it off
 * with titles on the device asks instead of silently deleting.
 */
@Composable
fun OfflineGroup(app: SwiftlyApplication) {
    val e = app.settings
    val v = app.downloads
    SettingGroup(translated("Offline")) {
        ChoiceRow(Glyph.LoadCircle, translated("Downloads"), translated("Titel aufs Gerät laden und offline schauen"), e.downloadsAn) { an ->
            val count = v.entries.value.size
            if (!an && count > 0) {
                app.sheet.value = SheetRequest(translated("%lld Titel bleiben auf dem Gerät", count),
                    listOf(Choice("behalten", translated("Behalten")), Choice("weg", translated("Alles entfernen"))), null,
                    mapOf("behalten" to Glyph.Checkmark, "weg" to Glyph.Papierkorb), cautionary = setOf("weg")) { choice ->
                    if (choice == "weg") v.allRemove()
                    e.downloadsAn = false
                }
            } else e.downloadsAn = an
        }
        if (e.downloadsAn) {
            SeparatorLine()
            ChoiceRow(Glyph.Wlan, translated("Nur über WLAN"), translated("Downloads warten, bis du im WLAN bist"), e.onlyOverWLAN) {
                e.onlyOverWLAN = it
                v.tick()
            }
            SeparatorLine()
            val done = v.entries.value.filter { it.state == "fertig" }
            ValueRow(Glyph.Drive, translated("Speicher"), translated("%lld Titel auf diesem Gerät", done.size),
                      value = size(done.sumOf { it.bytes }))
        }
    }
}
