package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * Mirrors `ServerDashboardView` (`Sources/iOS/ServerDashboardView.swift`): the server for its
 * administrator. Phone only; every word and number comes from the core (`Kern.dashboardOnce`,
 * `Kern.dashboardLive`).
 *
 * **Two speeds**: the library counts once when the page opens, everything else every second. A
 * stream card is keyed by its id (session and title), so the poster is not loaded again while
 * time, bar and pause move.
 */
@Composable
fun ServerDashboardPage(app: SwiftlyApplication, open: (Destination) -> Unit, back: () -> Unit) {
    val context = LocalContext.current
    var once by remember { mutableStateOf<JSONObject?>(null) }
    var live by remember { mutableStateOf(JSONObject()) }
    var failure by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    val run = rememberCoroutineScope()

    LaunchedEffect(Unit) {
        try {
            once = JSONObject(withContext(Dispatchers.IO) { app.kern.dashboardOnce().await() })
        } catch (e: CancellationException) { throw e } catch (e: Exception) { failure = errorString(context, e) }
        // Every second until the page leaves composition, which cancels this effect.
        while (isActive) {
            val next = runCatching { JSONObject(withContext(Dispatchers.IO) { app.kern.dashboardLive().await() }) }.getOrNull()
            if (next != null) live = next
            delay(1000)
        }
    }

    fun action(perform: suspend () -> String, done: String) {
        run.launch {
            val reason = withContext(Dispatchers.IO) { perform() }
            notice = if (reason.isEmpty()) done else errorString(reason)
        }
    }

    SettingPage(once?.optString("name")?.ifEmpty { null } ?: translated("Server"), back, trimFirstGroup = true) {
        failure?.let {
            Text(it, style = Theme.body, color = Theme.error,
                 modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = Theme.groupTop))
        }
        // One block for what the server is and holds; then what moves: tasks, streams, and the load last.
        once?.let { o ->
            SettingGroup(translated("Server")) {
                // "Name (version)" in one line, as on iPhone.
                Text(androidx.compose.ui.text.buildAnnotatedString {
                    append(o.optString("name"))
                    o.optString("version").takeIf { it.isNotEmpty() }?.let {
                        withStyle(androidx.compose.ui.text.SpanStyle(color = Theme.fontVeryQuiet)) { append("  ($it)") }
                    }
                }, style = Theme.listTitle, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis,
                     modifier = Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing, vertical = 14.dp))
                SeparatorLine()
                NumberRow(listOf(translated("Filme") to o.optInt("movies"), translated("Serien") to o.optInt("series"),
                                 translated("Folgen") to o.optInt("episodes")))
                if (o.has("uhd")) {
                    SeparatorLine()
                    NumberRow(listOf("4K" to o.optInt("uhd"), "HD" to o.optInt("hd"), "SD" to o.optInt("sd")))
                }
            }
        }

        val tasks = live.optJSONArray("tasks") ?: JSONArray()
        if (tasks.length() > 0) {
            SettingGroup(translated("Aufgaben")) {
                for (i in 0 until tasks.length()) {
                    val t = tasks.getJSONObject(i)
                    if (i > 0) SeparatorLine()
                    MeterRow(t.optString("name"), value = t.optString("progressText"), share = t.optDouble("progress", 0.0) / 100)
                }
            }
        }

        GroupsTitle(translated("Wiedergaben"), Modifier.padding(top = Theme.groupTop, bottom = 2.dp))
        val streams = live.optJSONArray("streams") ?: JSONArray()
        if (streams.length() == 0) {
            Text(translated("Gerade spielt niemand etwas ab."), style = Theme.body, color = Theme.fontVeryQuiet,
                 modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 6.dp))
        }
        for (i in 0 until streams.length()) {
            val s = streams.getJSONObject(i)
            key(s.optString("id")) {
                StreamCard(s, Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 10.dp))
            }
        }

        // Two rings for processor and memory, the disks' rate under them, then what is left on every drive.
        val load = live.optJSONObject("load")
        val disks = live.optJSONArray("disks") ?: JSONArray()
        if (load != null || disks.length() > 0) {
            SettingGroup(translated("Auslastung")) {
                load?.let { l ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 18.dp), horizontalArrangement = Arrangement.spacedBy(28.dp, Alignment.CenterHorizontally)) {
                        if (l.has("cpu")) LoadRing(l.optDouble("cpuShare"), l.optString("cpu"), translated("CPU"))
                        if (l.has("memory")) LoadRing(l.optDouble("memoryShare"), l.optString("memory"), translated("RAM"))
                    }
                    if (l.has("diskText")) {
                        SeparatorLine()
                        MeterRow(translated("Festplatten"), value = l.optString("diskText"), share = null)
                    }
                    if (disks.length() > 0) SeparatorLine()
                }
                for (i in 0 until disks.length()) {
                    val d = disks.getJSONObject(i)
                    if (i > 0) SeparatorLine()
                    MeterRow(d.optString("uses"), value = d.optString("freeText"), share = d.optDouble("freeShare"),
                             warn = d.optBoolean("nearlyFull"))
                }
            }
        }

        SettingGroup(translated("Verwaltung")) {
            ProfileRow(Glyph.Rotate, translated("Mediathek scannen"), translated("Alle Bibliotheken nach neuen Dateien durchsuchen"),
                       trailing = Trailing.None) {
                action({ app.kern.librariesScan().await() }, translated("Die Mediathek wird gescannt."))
            }
            SeparatorLine()
            val pending = once?.optBoolean("pendingRestart") == true
            ProfileRow(Glyph.Reload, translated("Server neu starten"),
                       if (pending) translated("Ein Neustart steht aus") else null,
                       characterAccent = pending, trailing = Trailing.None) {
                // Asks first, as the iPhone's action sheet does.
                app.sheet.value = SheetRequest(translated("Server neu starten?"),
                    listOf(Choice("neu", translated("Neu starten"))), null, mapOf("neu" to Glyph.Reload),
                    cautionary = setOf("neu"), note = translated("Wer gerade schaut, wird für eine Minute unterbrochen.")) {
                    action({ app.kern.serverRestart().await() }, translated("Der Server startet neu."))
                }
            }
            SeparatorLine()
            ProfileRow(Glyph.Document, translated("Protokoll"), translated("Die Logdateien des Servers")) {
                open(Destination("serverprotokolle", translated("Protokoll"), "Serverprotokolle"))
            }
        }
        notice?.let {
            Text(it, style = Theme.small, color = Theme.fontVeryQuiet,
                 modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 12.dp))
        }
    }
}

/** Three to five counts side by side: the number large, what it counts below. */
@Composable
private fun NumberRow(entries: List<Pair<String, Int>>) {
    Row(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing, vertical = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for ((label, count) in entries) {
            Column(Modifier.weight(1f)) {
                Text(java.text.NumberFormat.getIntegerInstance().format(count), style = Theme.rail, color = Theme.font,
                     maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(label, style = Theme.small, color = Theme.fontVeryQuiet, maxLines = 1)
            }
        }
    }
}

/** A name, a value on the right and, where there is a share, a bar below. */
@Composable
private fun MeterRow(title: String, value: String, share: Double?, warn: Boolean = false) {
    Column(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing, vertical = 12.dp),
           verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = Theme.body.copy(fontSize = Theme.rowTitleSize, fontWeight = FontWeight.Medium),
                 color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(8.dp))
            Text(value, style = Theme.tile, color = if (warn) Theme.warning else Theme.fontQuiet, maxLines = 1)
        }
        share?.let { Bar(it, if (warn) Theme.warning else Theme.accent) }
    }
}

/** A thin progress bar: track white 12 %, fill in the given tone. */
@Composable
private fun Bar(share: Double, tint: Color) {
    Box(Modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(Theme.margin)) {
        Box(Modifier.fillMaxWidth(share.coerceIn(0.0, 1.0).toFloat()).fillMaxHeight().clip(CircleShape).background(tint))
    }
}

private fun badgeTint(kind: String): Color = when (kind) {
    "resolution" -> Theme.badgeResolution
    "range" -> Theme.badgeRange
    "video" -> Theme.badgeVideo
    else -> Theme.badgeAudio
}

/** Mirrors `LoadRing`: the share as an arc in the accent on a quiet track, the number in the middle. */
@Composable
private fun LoadRing(share: Double, value: String, label: String) {
    val accent = Theme.accent
    val animated by androidx.compose.animation.core.animateFloatAsState(share.coerceIn(0.0, 1.0).toFloat(),
        androidx.compose.animation.core.tween(900), label = "ring")
    Box(Modifier.size(112.dp).semantics(mergeDescendants = true) {}, contentAlignment = Alignment.Center) {
        androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
            val line = 10.dp.toPx()
            val inset = line / 2
            val arcSize = androidx.compose.ui.geometry.Size(size.width - line, size.height - line)
            val topLeft = androidx.compose.ui.geometry.Offset(inset, inset)
            val stroke = androidx.compose.ui.graphics.drawscope.Stroke(line, cap = androidx.compose.ui.graphics.StrokeCap.Round)
            drawArc(Theme.raised, 0f, 360f, false, topLeft, arcSize, style = stroke)
            drawArc(accent, -90f, 360f * animated, false, topLeft, arcSize, style = stroke)
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(value, style = Theme.section.copy(fontFeatureSettings = "tnum"), color = Theme.font)
            Text(label, style = Theme.small, color = Theme.fontVeryQuiet)
        }
    }
}

/** Mirrors `StreamCard`: the poster down the whole left edge; title and who watches, badges, device; bar, time and delivery with rate. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun StreamCard(s: JSONObject, modifier: Modifier) {
    val posterWidth = 84.dp
    val tone = if (s.optBoolean("deliveryGood")) Theme.accent else Theme.warning
    Row(modifier.fillMaxWidth().height(IntrinsicSize.Min).heightIn(min = posterWidth * 1.5f)
            .clip(RoundedCornerShape(Theme.cornerCard)).background(Theme.groupsArea)) {
        Box(Modifier.width(posterWidth).fillMaxHeight().background(Theme.raised)) {
            s.optString("poster").takeIf { it.isNotEmpty() && s.has("poster") }?.let {
                AsyncImage(model = it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            }
        }
        Column(Modifier.weight(1f).padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(androidx.compose.ui.text.buildAnnotatedString {
                        append(s.optString("title"))
                        if (s.has("titleAddition")) {
                            withStyle(Theme.tile.toSpanStyle().copy(color = Theme.fontVeryQuiet)) { append("  " + s.optString("titleAddition")) }
                        }
                    }, style = Theme.listTitle, color = Theme.font, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    if (s.has("subtitle")) Text(s.optString("subtitle"), style = Theme.small, color = Theme.fontQuiet, maxLines = 1)
                }
                UserChip(s.optString("user"), s.optString("userImage").takeIf { s.has("userImage") })
            }
            val badges = s.optJSONArray("badges") ?: JSONArray()
            if (badges.length() > 0) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    for (i in 0 until badges.length()) {
                        val b = badges.getJSONObject(i)
                        Text(b.optString("text"), style = Theme.small.copy(fontWeight = FontWeight.SemiBold), color = Theme.font,
                             modifier = Modifier.clip(RoundedCornerShape(5.dp)).background(badgeTint(b.optString("kind")))
                                 .padding(horizontal = 6.dp, vertical = 2.dp))
                    }
                }
            }
            Text(s.optString("device"), style = Theme.small, color = Theme.fontVeryQuiet, maxLines = 2)
            Spacer(Modifier.weight(1f))
            Bar(s.optDouble("share", 0.0), Theme.fontQuiet)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Symbol(if (s.optBoolean("paused")) Glyph.Pause else Glyph.Play, 11.dp, color = Theme.fontQuiet)
                Text(s.optString("timeLine"), style = Theme.small.copy(fontFeatureSettings = "tnum"),
                     color = Theme.fontQuiet, maxLines = 1, modifier = Modifier.weight(1f))
                Text(s.optString("delivery"), style = Theme.small.copy(fontWeight = FontWeight.SemiBold), color = tone, maxLines = 1,
                     modifier = Modifier.clip(CircleShape).background(tone.copy(alpha = 0.16f)).padding(horizontal = 7.dp, vertical = 2.dp))
            }
        }
    }
}

@Composable
private fun UserChip(name: String, image: String?) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Box(Modifier.size(20.dp).clip(CircleShape).background(Theme.raised), contentAlignment = Alignment.Center) {
            Text(name.take(1).uppercase(), style = Theme.small, color = Theme.font)
            image?.let { AsyncImage(model = it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
        }
        Text(name, style = Theme.small, color = Theme.fontQuiet, maxLines = 1)
    }
}

/** The server's log files, newest first. */
@Composable
fun ServerLogsPage(app: SwiftlyApplication, open: (Destination) -> Unit, back: () -> Unit) {
    val context = LocalContext.current
    var files by remember { mutableStateOf<JSONArray?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        try { files = JSONArray(withContext(Dispatchers.IO) { app.kern.serverLogs().await() }) }
        catch (e: CancellationException) { throw e } catch (e: Exception) { failure = errorString(context, e) }
    }
    SettingPage(translated("Protokoll"), back) {
        failure?.let { Text(it, style = Theme.body, color = Theme.error, modifier = Modifier.padding(horizontal = Theme.edgeSpacing)) }
        val list = files ?: return@SettingPage
        if (list.length() == 0) return@SettingPage
        CardView {
            for (i in 0 until list.length()) {
                val f = list.getJSONObject(i)
                if (i > 0) SeparatorLine()
                val date = if (f.has("modified")) android.text.format.DateUtils.formatDateTime(context, f.optLong("modified"),
                    android.text.format.DateUtils.FORMAT_SHOW_DATE or android.text.format.DateUtils.FORMAT_SHOW_TIME or
                    android.text.format.DateUtils.FORMAT_ABBREV_MONTH) else null
                ValueRow(Glyph.Document, f.optString("name"), under = listOfNotNull(date, f.optString("size")).joinToString(" · "),
                         chevron = true) {
                    open(Destination(f.optString("name"), f.optString("name"), "Serverprotokoll"))
                }
            }
        }
    }
}

/** The end of one log file, scrolled to the bottom where the latest lines are. */
@Composable
fun ServerLogPage(app: SwiftlyApplication, name: String, back: () -> Unit) {
    val context = LocalContext.current
    var text by remember { mutableStateOf<String?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(name) {
        try { text = withContext(Dispatchers.IO) { app.kern.serverLog(name).await() } }
        catch (e: CancellationException) { throw e } catch (e: Exception) { failure = errorString(context, e) }
    }
    val scroll = rememberScrollState()
    LaunchedEffect(text) { if (text != null) scroll.scrollTo(scroll.maxValue) }
    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            SubpageHeader(name, back)
            failure?.let { Text(it, style = Theme.body, color = Theme.error, modifier = Modifier.padding(horizontal = Theme.edgeSpacing)) }
            Box(Modifier.weight(1f).verticalScroll(scroll).horizontalScroll(rememberScrollState())
                    .navigationBarsPadding().padding(horizontal = Theme.edgeSpacing, vertical = 12.dp)) {
                SelectionContainer {
                    Text(text.orEmpty(), style = Theme.small.copy(fontFamily = FontFamily.Monospace), color = Theme.fontQuiet, softWrap = false)
                }
            }
        }
    }
}
