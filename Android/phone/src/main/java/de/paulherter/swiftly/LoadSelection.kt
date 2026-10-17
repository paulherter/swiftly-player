package de.paulherter.swiftly

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** One episode as the selection needs it; reply from `Kern.loadSelectionEpisodes`. */
private data class LoadEpisode(val id: String, val name: String, val watched: Boolean, val bytes: Long, val ticks: Long)

private fun loadEpisodesRead(json: String): List<LoadEpisode> = JSONArray(json).let { a ->
    (0 until a.length()).map { i ->
        a.getJSONObject(i).let { LoadEpisode(it.getString("id"), it.getString("name"), it.optBoolean("gesehen"), it.optLong("bytes"), it.optLong("ticks")) }
    }
}

/**
 * Mirrors iOS `Ladeauswahl`: **what is downloaded is selected, not guessed.**
 * A tree with three levels (**whole series, season, episode**); each level carries the same
 * round box: empty, partial, full, and "there" for what is already on the device. **The switch
 * selects nothing:** "Unwatched only" decides *what* a tick takes, and the selection is
 * recomputed. Watched episodes stay selectable without the switch, with a quiet title and
 * "watched" before the size; with the switch they are not listed at all.
 * Nothing is downloaded here. The chosen episodes go to `downloadsCreate` and thus into the
 * loading sheet, where space, Wi-Fi and the normal case apply unchanged. The selection is a step before.
 * **Depth goes up:** the sheet stays `area`, the cards sit on `erhoeht`, corner 14.
 */
fun loadSelectionShow(app: SwiftlyApplication, seriesIdentifier: String, name: String, seasons: List<Season>) {
    app.sheet.value = SheetRequest(name, emptyList(), null, content = { close ->
        LoadSelection(app, seriesIdentifier, name, seasons, close)
    }) {}
}

/** Four states: the three of the selection, and **there** for what is already on the device. */
private enum class CheckboxState { Empty, Part, Full, There }

@Composable
private fun LoadSelection(app: SwiftlyApplication, seriesIdentifier: String, name: String, seasons: List<Season>, close: () -> Unit) {
    val v = app.downloads
    // Observed: what finishes while the sheet is open switches to "there".
    v.entries.value
    var episodes by remember { mutableStateOf<Map<String, List<LoadEpisode>>>(emptyMap()) }
    var selected by remember { mutableStateOf(emptySet<String>()) }
    var openSeason by remember { mutableStateOf<String?>(null) }
    var onlyUnwatched by remember { mutableStateOf(false) }
    var loads by remember { mutableStateOf(true) }
    /** **The failure case belongs here.** If the fetch fails, the selection must not stand empty. */
    var disrupted by remember { mutableStateOf(false) }
    var free by remember { mutableLongStateOf(v.free()) }
    /** Original until someone taps the badge and picks something else. */
    var quality by remember { mutableStateOf("original") }

    val allEpisodes = seasons.flatMap { episodes[it.id].orEmpty() }
    fun lies(f: LoadEpisode) = v.entries(f.id) != null
    /** What a tick takes: without the switch everything, with it only unwatched; what is already there, never. */
    fun takeable(list: List<LoadEpisode>) = list.filter { !lies(it) && (!onlyUnwatched || !it.watched) }
    /** What the list shows: with "Unwatched only" watched episodes are not listed at all. */
    fun visible(list: List<LoadEpisode>) = if (onlyUnwatched) list.filter { !it.watched } else list
    fun state(all: List<LoadEpisode>, presentCounts: Boolean = true): CheckboxState {
        val list = visible(all)
        if (presentCounts && list.isNotEmpty() && list.all { lies(it) }) return CheckboxState.There
        val take = takeable(list)
        if (take.isEmpty()) return CheckboxState.Empty
        val an = take.count { it.id in selected }
        return if (an == 0) CheckboxState.Empty else if (an == take.size) CheckboxState.Full else CheckboxState.Part
    }
    // As long as not every season is read, the series is not "there".
    val stateAll = state(allEpisodes, presentCounts = !loads)
    val selectedEpisodes = allEpisodes.filter { it.id in selected }
    /** **The footer computes in the chosen quality:** the real size for the original, estimated otherwise. */
    fun bytesIn(q: String) = selectedEpisodes.sumOf { Kern.downloadEstimated(q, it.bytes, it.ticks) }
    val bytes = bytesIn(quality)
    /** The tiers by the selection's best file, or the whole series while nothing is selected. */
    val selectable = app.settings.downloadQualitySelectable
    val offered = remember(selected, episodes, selectable) {
        val base = if (selectedEpisodes.isEmpty()) allEpisodes else selectedEpisodes
        qualitiesRead(Kern.downloadQualities(selectable, JSONArray(base.map { JSONArray(listOf(it.bytes, it.ticks)) }).toString()))
    }
    // If the chosen tier disappears, the original applies again.
    LaunchedEffect(offered) { if (offered.none { it.id == quality }) quality = "original" }

    fun toggle(list: List<LoadEpisode>) {
        val take = takeable(list)
        if (take.isEmpty()) return
        val ids = take.map { it.id }.toSet()
        selected = if (take.all { it.id in selected }) selected - ids else selected + ids
    }
    /** After the switch: everything no longer takeable drops out. */
    fun newCompute() { selected = selected intersect takeable(allEpisodes).map { it.id }.toSet() }

    /** **Each season once, one after another.** `nil` means failed, `[]` means empty. */
    suspend fun loadAll() {
        loads = true
        disrupted = false
        free = v.free()
        for (st in seasons) {
            if (episodes[st.id] != null) continue
            try {
                val list = loadEpisodesRead(withContext(Dispatchers.IO) { app.kern.loadSelectionEpisodes(seriesIdentifier, st.id).await() })
                episodes = episodes + (st.id to list)
            } catch (e: CancellationException) { throw e } catch (_: Exception) { disrupted = true }
        }
        loads = false
        // What was downloaded since the last open is no longer selectable.
        newCompute()
    }
    var attempt by remember { mutableIntStateOf(0) }
    LaunchedEffect(attempt) { loadAll() }

    fun episodesNumber(n: Int) = if (n == 1) translated("1 Folge") else translated("%lld Folgen", n)
    /** "23 episodes · 31.4 GB": count and size in one go. */
    fun numberAndSize(n: Int, b: Long) = episodesNumber(n) + " · " + Kern.downloadSize(b)

    if (disrupted && allEpisodes.isEmpty()) {
        DisturbHint(app.serverAddress(), Modifier.padding(bottom = 16.dp), spacingTop = 10.dp, retry = { attempt++ })
        return
    }

    // **As tall as the cards, at most 440**, and the height follows the same curve as the sheet
    // (`sheetMotion`) instead of jumping after expanding.
    Column(Modifier.animateContentSize(Motion.sheet()).heightIn(min = 58.dp, max = 440.dp).verticalScroll(rememberScrollState())
               .padding(bottom = 12.dp),
           verticalArrangement = Arrangement.spacedBy(12.dp)) {
        // The series card: "Whole series" and the switch.
        Column(Modifier.padding(horizontal = 16.dp).clip(RoundedCornerShape(Theme.cornerCard)).background(Theme.raised)) {
            // "Whole series" names only what is still missing.
            val right = when {
                loads -> translated("wird gelesen …")
                stateAll == CheckboxState.There -> translated("alles da")
                allEpisodes.isNotEmpty() && visible(allEpisodes).isEmpty() -> translated("alles gesehen")
                else -> takeable(allEpisodes).let { numberAndSize(it.size, it.sumOf { f -> f.bytes }) }
            }
            SelectionRow(stateAll, translated("Ganze Serie"), right, perform = { toggle(allEpisodes) })
            SheetLine()
            Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(translated("Nur ungesehene"), style = Theme.listTitle, color = Theme.font, modifier = Modifier.weight(1f))
                    Spacer(Modifier.width(12.dp))
                    // Flipping the switch changes not the selection but its base set.
                    ToggleSwitch(onlyUnwatched) { onlyUnwatched = it; newCompute() }
                }
                Text(translated("Entscheidet, was ein Haken auswählt."), style = Theme.small, color = Theme.fontVeryQuiet)
            }
        }

        // The season card: expandable, episodes only indented, no second surface.
        Column(Modifier.padding(horizontal = 16.dp).clip(RoundedCornerShape(Theme.cornerCard)).background(Theme.raised)) {
            seasons.forEachIndexed { nr, st ->
                val all = episodes[st.id]
                val ownOnes = visible(all.orEmpty())
                val box = state(ownOnes)
                val right = when {
                    all == null -> if (loads) translated("wird gelesen …") else "—"
                    all.isEmpty() -> translated("Keine Folgen")
                    ownOnes.isEmpty() -> translated("alles gesehen")
                    box == CheckboxState.There -> translated("alles da")
                    else -> takeable(ownOnes).let { if (it.isEmpty()) translated("alles da") else episodesNumber(it.size) }
                }
                val on = openSeason == st.id
                SelectionRow(box, st.name, right, expanded = on, perform = { toggle(ownOnes) },
                             expand = { openSeason = if (on) null else st.id })
                AnimatedVisibility(on, enter = expandVertically(Motion.sheet()) + fadeIn(Motion.sheet()),
                                   exit = shrinkVertically(Motion.sheet()) + fadeOut(Motion.sheet())) {
                    Column {
                        all.orEmpty().forEach { f ->
                            // The switch removes watched episodes from the list softly, not abruptly.
                            AnimatedVisibility(!(onlyUnwatched && f.watched),
                                enter = expandVertically(Motion.sheet()) + fadeIn(Motion.sheet()),
                                exit = shrinkVertically(Motion.sheet()) + fadeOut(Motion.sheet())) {
                                Column {
                                    // Continuous, also under the indented episodes.
                                    SheetLine()
                                    val p = v.entries(f.id)
                                    // **Watched is shown before choosing;** a downloaded episode says it is there.
                                    val size = if (f.bytes > 0) Kern.downloadSize(f.bytes) else "—"
                                    val episodeRight = when {
                                        p == null -> if (f.watched) translated("gesehen") + " · " + size else size
                                        p.state == "fertig" -> translated("geladen")
                                        p.state == "laedt" -> translated("lädt")
                                        else -> translated("wartet")
                                    }
                                    SelectionRow(if (p != null) CheckboxState.There else if (f.id in selected) CheckboxState.Full else CheckboxState.Empty,
                                                 f.name, episodeRight, small = true, inset = 38.dp, quiet = f.watched,
                                                 perform = { toggle(listOf(f)) })
                                }
                            }
                        }
                    }
                }
                if (nr < seasons.size - 1) SheetLine()
            }
        }
    }

    // **The footer computes along.** Left what is chosen, right what stays free afterwards.
    Column(Modifier.padding(top = 4.dp, bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SheetLine()
        Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(if (selected.isEmpty()) translated("Nichts gewählt") else numberAndSize(selected.size, bytes),
                 style = Theme.tile.copy(fontFeatureSettings = "tnum"), color = Theme.font, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(8.dp))
            // Whether it suffices is decided by `DownloadRules.footSpace`, with the same reserve as the following sheet.
            val slot = JSONObject(Kern.downloadFooterSpace(bytes, free))
            if (slot.getBoolean("reicht")) {
                Text(translated("Danach %@ frei", Kern.downloadSize(slot.getLong("bytes"))),
                     style = Theme.small.copy(fontFeatureSettings = "tnum"), color = Theme.fontVeryQuiet)
            } else {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    Symbol(Glyph.Info, 12.dp, color = Theme.warning, strength = Strength.Semibold)
                    Text(translated("%@ zu wenig", Kern.downloadSize(slot.getLong("bytes"))),
                         style = Theme.small.copy(fontFeatureSettings = "tnum"), color = Theme.warning)
                }
            }
        }
        // **The quality is shown, not in fine print**, and if the server may transcode, the badge is
        // also the choice of a smaller version.
        Box(Modifier.padding(horizontal = 16.dp)) {
            QualityBadge(quality, offered, selectable,
                               size = { q -> if (selected.isEmpty()) 0L else bytesIn(q) }) { quality = it }
        }
        // **With arrow**, as in the series' button row. Disabled on `erhoeht`: on a sheet in `area`
        // a disabled button in `area` would be just quiet text.
        Box(Modifier.padding(horizontal = 16.dp)) {
            PlayButton(Glyph.ArrowDown,
                       if (selected.isEmpty()) translated("Laden") else translated("%@ laden", episodesNumber(selected.size)),
                       an = selected.isNotEmpty(), main = true, lockedArea = Theme.raised) {
                val ids = allEpisodes.filter { it.id in selected }.map { it.id }
                close()
                // One sheet at a time: the loading sheet comes when this one is down.
                app.downloadsCreate(ids, name, waitFor = 260, quality = quality)
            }
        }
    }
}

/**
 * One row of the selection: **circle 22, hit area 44**; the 44 extends 11 beyond the circle on
 * each side, and indent and spacing subtract it again. The episode row carries the 52 of the
 * other sheets, the season row one step above (58). Without a disclosure arrow the row beside
 * it does the same as the circle.
 */
@Composable
private fun SelectionRow(box: CheckboxState, title: String, right: String, small: Boolean = false, inset: Dp = 16.dp,
                         expanded: Boolean? = null, quiet: Boolean = false, perform: () -> Unit, expand: (() -> Unit)? = null) {
    val value = when (box) { CheckboxState.Part -> translated("teilweise"); CheckboxState.There -> translated("geladen"); else -> "" }
    Row(Modifier.fillMaxWidth().heightIn(min = if (small) 52.dp else 58.dp).padding(start = inset - 11.dp, end = 16.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(44.dp).then(if (box == CheckboxState.There) Modifier else Modifier.tapOn(perform))
                .semantics { contentDescription = title; stateDescription = value; selected = box == CheckboxState.Full },
            contentAlignment = Alignment.Center) {
            BoxImage(box)
        }
        Spacer(Modifier.width(2.dp))
        Row(Modifier.weight(1f).heightIn(min = 44.dp).pressRow { (expand ?: perform)() },
            verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = TextStyle(fontSize = if (small) 13.sp else 15.sp, fontWeight = if (small) FontWeight.Medium else FontWeight.SemiBold),
                 color = if (box == CheckboxState.There || quiet) Theme.fontQuiet else Theme.font,
                 maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(10.dp))
            Text(right, style = Theme.small.copy(fontFeatureSettings = "tnum"), color = Theme.fontVeryQuiet, maxLines = 1)
            if (expanded != null) {
                val rotation by animateFloatAsState(if (expanded) 0f else -90f, Motion.sheet(), label = "pfeil")
                Spacer(Modifier.width(10.dp))
                Symbol(Glyph.AngleDown, 12.dp, Modifier.graphicsLayer { rotationZ = rotation },
                       color = Theme.fontVeryQuiet, strength = Strength.Semibold,
                       description = translated(if (expanded) "Zuklappen" else "Aufklappen"))
            }
        }
    }
}

/** The round box: empty as a ring in `schriftSehrLeise` (3:1 on `erhoeht`), partial and full in accent, there as a quiet tick. */
@Composable
private fun BoxImage(k: CheckboxState) {
    Crossfade(k, animationSpec = Motion.toggle(), label = "kasten") { z ->
        Box(Modifier.size(22.dp), contentAlignment = Alignment.Center) {
            when (z) {
                CheckboxState.Empty -> Canvas(Modifier.fillMaxSize()) {
                    val b = 1.6.dp.toPx()
                    drawCircle(Theme.fontVeryQuiet, size.minDimension / 2 - b / 2, style = Stroke(b))
                }
                CheckboxState.Part -> {
                    Box(Modifier.fillMaxSize().clip(CircleShape).background(Theme.accent))
                    Symbol(Glyph.Minus, 12.dp, color = Theme.onAccent, strength = Strength.Semibold)
                }
                CheckboxState.Full -> {
                    Box(Modifier.fillMaxSize().clip(CircleShape).background(Theme.accent))
                    Symbol(Glyph.Checkmark, 11.dp, color = Theme.onAccent, strength = Strength.Semibold)
                }
                // Quiet, no circle: an accent tick would mean "selected"; this one says nothing is left to do.
                CheckboxState.There -> Symbol(Glyph.Checkmark, 15.dp, color = Theme.fontVeryQuiet, strength = Strength.Semibold)
            }
        }
    }
}

/** One tier, as `Kern.downloadQualities` returns it. */
data class QualityLevel(val id: String, val row: String, val badge: String)

fun qualitiesRead(json: String): List<QualityLevel> = JSONArray(json).let { a ->
    (0 until a.length()).map { i -> a.getJSONObject(i).let { QualityLevel(it.getString("id"), it.getString("zeile"), it.getString("plakette")) } }
}

/**
 * Mirrors iOS `QualityBadge`. Original is the default; if the server may transcode, a tap
 * opens a list of smaller tiers with their estimated size. If it may not, the badge stays and a
 * sentence below says why there is nothing to choose.
 */
@Composable
fun QualityBadge(choice: String, offered: List<QualityLevel>, selectable: Boolean,
                       size: (String) -> Long, select: (String) -> Unit) {
    val expandable = selectable && offered.size > 1
    var opened by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box {
            Row(Modifier.then(if (expandable) Modifier.heightIn(min = 44.dp) else Modifier)
                    .then(if (expandable) Modifier.tapOn { opened = true } else Modifier)
                    .semantics { contentDescription = translated("Qualität") + ", " + Kern.downloadBadge(choice) },
                verticalAlignment = Alignment.CenterVertically) {
                Row(Modifier.clip(RoundedCornerShape(Theme.cornerSmall)).background(Theme.accent.copy(alpha = 0.15f))
                        .padding(horizontal = 10.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (choice == "original") Symbol(Glyph.Checkmark, 11.dp, color = Theme.accent, strength = Strength.Semibold)
                    Text(Kern.downloadBadge(choice), style = Theme.small.copy(fontFeatureSettings = "tnum"), color = Theme.accent)
                    if (expandable) Symbol(Glyph.AngleDown, 11.dp, color = Theme.accent, strength = Strength.Semibold)
                }
            }
            DropdownMenu(opened, onDismissRequest = { opened = false }, containerColor = Theme.raised,
                         shape = RoundedCornerShape(Theme.cornerCard)) {
                offered.forEach { q ->
                    val g = size(q.id)
                    DropdownMenuItem(
                        text = {
                            Column {
                                Text(q.row, style = Theme.listTitle, color = Theme.font)
                                if (g > 0) Text((if (q.id == "original") "" else "≈ ") + Kern.downloadSize(g),
                                                style = Theme.small.copy(fontFeatureSettings = "tnum"), color = Theme.fontVeryQuiet)
                            }
                        },
                        trailingIcon = if (q.id == choice) ({ Symbol(Glyph.Checkmark, 15.dp, color = Theme.accent, strength = Strength.Semibold) }) else null,
                        onClick = { opened = false; select(q.id) })
                }
            }
        }
        if (!selectable) {
            Text(translated("Kleinere Fassungen gibt der Server für dieses Konto nicht frei."),
                 style = Theme.small, color = Theme.fontVeryQuiet)
        }
    }
}
