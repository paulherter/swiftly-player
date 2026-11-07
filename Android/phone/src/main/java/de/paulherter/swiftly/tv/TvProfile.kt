package de.paulherter.swiftly.tv

import de.paulherter.swiftly.support.SupporterAvatarHeart
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.activity.compose.BackHandler
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusGroup
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.findRootCoordinates
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.*
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** Mirrors `SectionSelection` (tvOS): the name only, no icon. The headings on the right
 *  ("PLAYBACK" etc.) are the same wording, not a second label. */
private enum class Compartment(val title: String, val glyph: Glyph) {
    Playback("Wiedergabe", Glyph.Play), Presentation("Darstellung", Glyph.Grid),
    Integration("Integration", Glyph.Plug), Server("Server", Glyph.Server), Account("Konto", Glyph.Person), Swiftly("Swiftly", Glyph.Info),
}

/** Mirrors `SettingsLook` (tvOS 1.1, the settings page as the approved design draws it), tvOS pt / 2. */
internal object SettingsLook {
    /** Gap between symbol column, title and value in a row (28 pt). */
    val rowGap = 14.dp  // tv-spec: unrelated
    /** Gap between a value and its arrow (12 pt). */
    val valueGap = 6.dp
    /** Inside a group, left and right; the focus surface reaches over it by the same amount (26 pt). */
    val groupInset = 13.dp  // tv-spec: unrelated
    /** Between a group title and its box (20 pt). */
    val groupTitleGap = 10.dp
    val hairlineMargin = 14.dp  // tv-spec: unrelated
    val leftHeadingBottom = 8.dp
    val sectionGap = 2.dp
    val accountStripTop = 11.dp
    val accountStripSpacing = 8.dp
    val toggleKnob = 21.dp
    val toggleInset = 2.dp
    /** Row text: 30 pt / 500. */
    val rowText = TvTheme.body.copy(fontSize = 15.sp, fontWeight = FontWeight.Medium)
}

/** The rows are drawn in the settings design (white focus surface over the group, hairline in the row). Only `TvProfile`
 *  switches it on; the same rows on other pages (subtitle look) keep the old look, as `settingsLook` on tvOS. */
internal val LocalSettingsLook = compositionLocalOf { false }

/** A group title of the settings: 44 pt bold, no inset (`SettingsHeading`). */
@Composable
private fun SettingsHeading(text: String, modifier: Modifier = Modifier) {
    Text(text, style = TvTheme.rail, color = Theme.font, modifier = modifier)
}

/** One box with its title above on the bare background (`TVGroup`): title on the background, group `groupsArea`, r24,
 *  26 pt inside on both sides and none above or below (the rows are 84 pt high). */
@Composable
private fun TvGroup(title: String, content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(SettingsLook.groupTitleGap)) {
        SettingsHeading(title)
        Column(Modifier.clip(RoundedCornerShape(TvTheme.cornerArea)).background(Theme.groupsArea)
                   .padding(horizontal = SettingsLook.groupInset), content = content)
    }
}

/** The symbol column of a settings row: symbol 20 in a 26 column, white like the title (it names the row). */
@Composable
private fun RowSymbol(glyph: Glyph?, focus: Boolean) {
    if (glyph == null) return
    Box(Modifier.width(TvSpec.rowSymbolColumn), contentAlignment = Alignment.Center) {
        Symbol(glyph, TvSpec.rowSymbol, color = if (focus) Theme.reason else Theme.font, strength = Strength.Medium)
    }
}

/**
 * Mirrors `ProfileView` on tvOS: **two columns like Apple's own settings**: the sections on the left,
 * their rows on the right, dimmed until one moves over. Look first, then jump; and since there is
 * width, every jump that goes away is a saving. Reordering uses arrows, as a remote has nothing to
 * grab. No offline group, no landscape, no Quick Connect authorization: none of that makes sense
 * on a TV.
 *
 * Layout: the account card top left (image, name, server, divider, account strip with the plus as
 * a field), below it the sections as text only, the selected one in an accent surface and accent
 * text, like `SectionStyle`. On the right a grouped card with hairlines instead of a flat list, rows
 * without icons, drawn switches instead of text, and an arrow on each selection row.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun TvProfile(app: SwiftlyApplication, open: (Destination) -> Unit) {
    val e = app.settings
    var compartment by rememberSaveable { mutableStateOf(Compartment.Playback) }
    var leftFocus by remember { mutableStateOf(true) }
    var rightHasFocus by remember { mutableStateOf(false) }
    val left = firstFocus()
    val right = remember { FocusRequester() }
    // The value row that is open (its title is the key), at most one; closed when the section changes (tvOS: `opened`).
    var opened by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(compartment) { opened = null }
    val rightScroll = rememberScrollState()
    var viewportTop by remember { mutableFloatStateOf(0f) }
    val rowTops = remember { mutableMapOf<String, Float>() }
    val edgeTopPx = with(androidx.compose.ui.platform.LocalDensity.current) { TvTheme.edgeTop.toPx() }
    // **The expanded row scrolls to the top with the same curve and time as the expansion** (tvOS: `reader.scrollTo(new,
    // anchor: .top)` inside the same `withAnimation`). The target is read again each frame, because the list grows while it
    // moves and its end moves with it.
    val calmScroll = de.paulherter.swiftly.shared.motionReduced()
    LaunchedEffect(opened) {
        val key = opened ?: return@LaunchedEffect
        val rowTop = rowTops[key] ?: return@LaunchedEffect
        val start = rightScroll.value.toFloat()
        val contentY = rowTop - viewportTop + start - edgeTopPx
        androidx.compose.animation.core.Animatable(0f).animateTo(1f,
            if (calmScroll) tween(TvSpec.reducedMs) else tween(TvSpec.valueExpandMs, easing = TvSpec.easeInOutCurve)) {
            val goal = start + (contentY.coerceIn(0f, rightScroll.maxValue.toFloat()) - start) * value
            rightScroll.dispatchRawDelta(goal - rightScroll.value)
        }
    }
    val run = rememberCoroutineScope()
    val context = androidx.compose.ui.platform.LocalContext.current
    BackHandler(enabled = !leftFocus) { runCatching { left.requestFocus() } }

    var frameRateAdapt by remember { mutableStateOf(app.store.rememberValue("bildrateAnpassen") != "0") }
    val bitrates = remember { selectionRead(Kern.bitrateLevels()) }
    val passthrough = remember { listOf(
        Choice("auto", translated("Automatisch")),
        Choice("off", translated("Aus (nur PCM)")),
        Choice("ac3", translated("Nur Dolby Digital")),
        Choice("all", translated("Alle erzwingen (auch DTS, TrueHD)"))) }
    val dv7 = remember { listOf(Choice("auto", translated("Automatisch")), Choice("off", translated("Aus (spielt als HDR10)"))) }
    val buffer = remember { JSONArray(Kern.bufferLevels()).let { a -> (0 until a.length()).map { a.getJSONObject(it).let { o -> Choice(o.getString("wert"), o.getString("text")) } } } }
    val seconds = remember { JSONArray(Kern.span()).let { a -> (0 until a.length()).map { a.getInt(it) } } }
    val audioChoice = remember { selectionRead(Kern.languages("")) }
    val subtitleSelection = remember { selectionRead(Kern.languages(translated("Aus"))) }
    fun secondsSelection() = seconds.map { Choice(it.toString(), translated("%lld s", it)) }

    var server by remember { mutableStateOf<Pair<String, String>?>(null) }
    LaunchedEffect(Unit) {
        try {
            val o = JSONObject(withContext(Dispatchers.IO) { app.kern.serverInfo().await() })
            server = o.optString("name") to o.optString("version")
        } catch (x: CancellationException) { throw x } catch (_: Exception) {}
    }
    // For "Genre hinzufuegen" at the bottom: the same list as `GenreSelectionPage` on the phone.
    var allGenres by remember { mutableStateOf<List<String>>(emptyList()) }
    var genresDisturbed by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        allGenres = try {
            JSONArray(withContext(Dispatchers.IO) { app.kern.genres().await() }).let { a -> (0 until a.length()).map { a.getString(it) } }
        } catch (x: CancellationException) { throw x } catch (_: Exception) { genresDisturbed = true; emptyList() }
    }
    // For "Bibliothek hinzufuegen": libraries and collections not yet chosen (`LibrarySelectionPage`).
    var freeLibraries by remember { mutableStateOf<List<de.paulherter.swiftly.StartLibraryItem>>(emptyList()) }
    val selectedIds = app.settings.startLibraries.map { it.id }
    LaunchedEffect(selectedIds) { freeLibraries = de.paulherter.swiftly.startSelectionLoad(app) }
    var verification by remember { mutableStateOf<String?>(null) }
    val cards = remember(app.accountSwitch.intValue) {
        app.store.accounts?.let { b -> runCatching { JSONArray(Kern.bundleOverview(b)).let { a -> (0 until a.length()).map { a.getJSONObject(it) } } }.getOrNull() }.orEmpty()
    }
    val host = cards.firstOrNull { it.optBoolean("aktiv") }?.optString("host").orEmpty()
    val serverRow = listOfNotNull(server?.first?.ifEmpty { null } ?: app.serverName.value,
                                     server?.second?.let { "${ServerKind.from(app.kind()).shownName} $it" }).joinToString(" · ")

    // The look's glow stands still here (`lookGlow(fixed:)` on tvOS): the two columns scroll on their own.
    CompositionLocalProvider(LocalSettingsLook provides true) {
    Box(Modifier.fillMaxSize().background(Theme.reason)) {
    TvGlow(app)
    Column(Modifier.fillMaxSize()
            // Side margin only: the top and bottom margin sits inside the two scrolling columns, so the lists scroll
            // out to the window edge (tvOS: `scrollClipDisabled()`). Measured before: the viewports ended 30 dp
            // inside the screen, and rows were cut mid-picture.
            .padding(horizontal = TvTheme.edgePage)) {
        Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(TvSpec.columnGap)) {
            // **Back to the left means onto the selected section** (tvOS: `.focusSection()` with
            // `.defaultFocus($left, section)`, Back sets `left = section`). Before, the geometric search from
            // the right found the account strip at the top, and Back always jumped to the first row, so
            // `left` now attaches to the selected row.
            //
            // **Scrollable**, like the right column: the account card and seven sections are taller than a
            // 1080 frame. Without scrolling, "Swiftly" got height 0 and focus landed on an invisible row below
            // the screen edge.
            Column(Modifier.width(TvSpec.sectionColumnWidth).focusProperties { enter = { left } }
                    .verticalScroll(rememberScrollState()).padding(vertical = TvTheme.edgeTop).focusGroup()) {
                AccountBlock(app, serverRow, cards,
                           record = { open(Destination("weiteresKonto", translated("Konto hinzufügen"), "WeiteresKonto")) },
                           switchTo = { k -> app.switchAccount(k) })
                // A line instead of a second box (tvOS: `SheetLine`): it says where "who" ends and "where" begins.
                // Design: margin 28 pt above and below.
                Box(Modifier.fillMaxWidth().padding(vertical = SettingsLook.hairlineMargin)
                        .height(TvSpec.hairline).background(Theme.line))
                SettingsHeading(translated("Bereiche"), Modifier.padding(bottom = SettingsLook.leftHeadingBottom))
                Column(verticalArrangement = Arrangement.spacedBy(SettingsLook.sectionGap)) {
                Compartment.entries.filter { it != Compartment.Integration || app.can("seerr") }.forEach { a ->
                    SectionRow(translated(a.title), a.glyph, selected = a == compartment, rests = !leftFocus,
                                 modifier = if (a == compartment) Modifier.focusRequester(left) else Modifier,
                                 focusChanged = { if (it) { compartment = a; leftFocus = true } },
                                 perform = {
                                     // **One frame later**, as tvOS does (`toInGo`): the column only takes focus once it is
                                     // no longer the dimmed, closed one.
                                     leftFocus = false
                                     run.launch {
                                         withFrameNanos { }
                                         runCatching { right.requestFocus() }
                                         kotlinx.coroutines.delay(150)
                                         if (!rightHasFocus) leftFocus = true
                                     }
                                 })
                }
                }
            }
            // Not active yet means switched off, so that no step to the right leads in, only OK does (tvOS: `.disabled(!inside)`).
            // The design shows the right column at full brightness: the area list on the left already says which one it is,
            // so the column is no longer dimmed.
            Column(Modifier.weight(1f)
                    .focusProperties { enter = { if (leftFocus) FocusRequester.Cancel else FocusRequester.Default } }
                    .onFocusChanged { rightHasFocus = it.hasFocus; if (it.hasFocus) leftFocus = false }
                    .onGloballyPositioned { viewportTop = it.positionInRoot().y }
                    .verticalScroll(rightScroll).padding(vertical = TvTheme.edgeTop).focusGroup()) {
                val first = Modifier.focusRequester(right)
                // Playback and Presentation compose their own boxes (`hasGroups` on tvOS); the others get one box titled
                // with the area name.
                val grouped = compartment == Compartment.Playback || compartment == Compartment.Presentation
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(TvSpec.groupGap)) {
                    // One reporter for the value rows below: where each one stands, for the scroll above.
                    val reportRow: (String, Float) -> Unit = { k, y -> rowTops[k] = y }
                    val setOpened: (String?) -> Unit = { opened = it }
                    when (compartment) {
                        Compartment.Playback -> {
                            // If the server does not transcode there is nothing to choose: Direct Play is fixed on and the
                            // bitrate is locked, as on the other versions.
                            val free = e.convertAllowed
                            val directPlay = e.alwaysDirectPlay || !free
                            // Same three boxes as on iPhone: quality, language, behaviour.
                            TvGroup(translated("Qualität")) {
                                // **The anchor hangs on the topmost row that is actually available** (tvOS: `free ? .top : .proceed`):
                                // focus on a disabled row goes nowhere.
                                TvToggleRow(translated("Immer Direct Play"), directPlay, Glyph.Play, enabled = free, modifier = if (free) first else Modifier) {
                                    e.alwaysDirectPlay = !e.alwaysDirectPlay; app.qualityReport()
                                }
                                SeparatorLine()
                                // Disabled while Direct Play is forced, since it would have no effect.
                                TvValueRow(translated("Höchste Bitrate"), Glyph.Gauge, bitrates.firstOrNull { it.value == e.bitratesLimit.toString() }?.text,
                                           opened, setOpened, reportRow, bitrates, e.bitratesLimit.toString(), enabled = !directPlay) {
                                    e.bitratesLimit = it.toInt(); app.qualityReport()
                                }
                                SeparatorLine()
                                // Same storage key as in the player (`TvPlayer`/`TvImageTick`, default on). Not in `Settings`,
                                // because frame rate matching exists only on tvOS/Android TV (`ProfileView.swift` also keeps it via
                                // `@AppStorage`, not in `AppModel`).
                                TvToggleRow(translated("Bildrate an den Film anpassen"), frameRateAdapt, Glyph.Film) {
                                    frameRateAdapt = !frameRateAdapt
                                    app.store.remember("bildrateAnpassen", if (frameRateAdapt) "1" else "0")
                                }
                            }
                            TvGroup(translated("Sprache")) {
                                TvValueRow(translated("Ton"), Glyph.Speaker, audioChoice.firstOrNull { it.value == e.audioLanguage }?.text,
                                           opened, setOpened, reportRow, audioChoice, e.audioLanguage, modifier = if (free) Modifier else first) { e.audioLanguage = it }
                                SeparatorLine()
                                TvToggleRow(translated("Mehrkanal-Ton (5.1)"), e.multiChannelAudio, Glyph.Speaker) { e.multiChannelAudio = !e.multiChannelAudio }
                                SeparatorLine()
                                TvValueRow(translated("Untertitel"), Glyph.Subtitle, subtitleSelection.firstOrNull { it.value == e.subtitleLanguage }?.text,
                                           opened, setOpened, reportRow, subtitleSelection, e.subtitleLanguage) { e.subtitleLanguage = it; if (it.isNotEmpty()) e.subtitleAutomatic = true }
                                SeparatorLine()
                                TvToggleRow(translated("Untertitel automatisch"), e.subtitleAutomatic, Glyph.TextLeft) { e.subtitleAutomatic = !e.subtitleAutomatic }
                                SeparatorLine()
                                // Own page with the live picture (Apple TV: `TVSubtitleLookEntryRow`).
                                TvAction(translated("Aussehen der Untertitel"), Glyph.SizeText,
                                         value = with(de.paulherter.swiftly.SubtitleFacts.of(e.subtitleLook, true)) { entryValue() }) {
                                    open(Destination("untertitelaussehen", translated("Aussehen der Untertitel"), "Untertitelaussehen"))
                                }
                            }
                            TvGroup(translated("Verhalten")) {
                                TvToggleRow(translated("Nächste Folge automatisch"), e.nextAutomatic, Glyph.SkipOutline) { e.nextAutomatic = !e.nextAutomatic }
                                SeparatorLine()
                                TvToggleRow(translated("Intro und Abspann automatisch überspringen"), e.introOutroAutomatic, Glyph.SkipOutline) { e.introOutroAutomatic = !e.introOutroAutomatic }
                                SeparatorLine()
                                TvValueRow(translated("Zurückspulen"), Glyph.Rewind, translated("%lld s", e.backSeconds),
                                           opened, setOpened, reportRow, secondsSelection(), e.backSeconds.toString()) { e.backSeconds = it.toInt() }
                                SeparatorLine()
                                TvValueRow(translated("Vorspulen"), Glyph.FastForward, translated("%lld s", e.forwardSeconds),
                                           opened, setOpened, reportRow, secondsSelection(), e.forwardSeconds.toString()) { e.forwardSeconds = it.toInt() }
                                SeparatorLine()
                                TvValueRow(translated("Puffer"), Glyph.WlanDisruption, buffer.firstOrNull { it.value == e.bufferLevel }?.text,
                                           opened, setOpened, reportRow, buffer, e.bufferLevel) { e.bufferLevel = it }
                                SeparatorLine()
                                TvValueRow(translated("Surround-Ton durchreichen"), Glyph.PlayRectangle, passthrough.firstOrNull { it.value == e.passthrough }?.text,
                                           opened, setOpened, reportRow, passthrough, e.passthrough) { e.passthrough = it }
                                SeparatorLine()
                                TvValueRow(translated("Dolby Vision Profil 7"), Glyph.PlayRectangle, dv7.firstOrNull { it.value == e.dolbyVision7 }?.text,
                                           opened, setOpened, reportRow, dv7, e.dolbyVision7) { e.dolbyVision7 = it }
                                SeparatorLine()
                                TvToggleRow(translated("Dolby Vision mit HDR10+ als HDR10+ spielen"), e.dolbyAsHdr10Plus, Glyph.Film) { e.dolbyAsHdr10Plus = !e.dolbyAsHdr10Plus }
                                SeparatorLine()
                                // Shared setting (`PlayerEndTime` on Apple): the player shows "Endet um ..." instead of the remaining time.
                                TvToggleRow(translated("Endzeit im Player"), e.endTimeInPlayer, Glyph.Clock) { e.endTimeInPlayer = !e.endTimeInPlayer }
                            }
                        }
                        Compartment.Presentation -> {
                            // The look first, as on Apple TV (`TVLookEntryRow`): tile, name and "Ändern"; opens "Wähl deinen Look".
                            val looksShown = tvLookRowShown(app)
                            TvGroup(translated("Darstellung")) {
                            if (looksShown) {
                                TvLookRow(app, first)
                                SeparatorLine()
                            }
                            TvToggleRow(translated("Fortschritt auf Kacheln"), e.progress, Glyph.Bar, modifier = if (looksShown) Modifier else first) { e.progress = !e.progress }
                            SeparatorLine()
                            TvToggleRow(translated("Merkliste"), e.watchlist, Glyph.Bookmark) { e.watchlist = !e.watchlist }
                            SeparatorLine()
                            TvToggleRow(translated("Alphabetische Suche in Listen"), e.alphabet, Glyph.TextBlock) { e.alphabet = !e.alphabet }
                            SeparatorLine()
                            TvToggleRow(translated("Titel als Logo"), e.titleAsLogo, Glyph.TextOutline) { e.titleAsLogo = !e.titleAsLogo }
                            if (e.watchersPlugin == "1") {
                                SeparatorLine()
                                TvToggleRow(translated("Gesehen von"), e.watchersShow, Glyph.Person) { e.watchersShow = !e.watchersShow }
                            }
                            }
                            // **Fixed rows, libraries and collections in one list** (`StartOrder`, as in `ProfileView` on
                            // tvOS): moved with the arrows, a row switched off, a library removed.
                            TvGroup(translated("Startseite")) {
                            val entries = e.startEntries()
                            entries.forEachIndexed { index, r ->
                                if (r.library) {
                                    val id = r.value.removePrefix("bibliothek:")
                                    TvLibraryRow(r.text, canHigh = index != 0, canGoDown = index != entries.lastIndex,
                                        remove = { e.startLibraries = e.startLibraries.filter { it.id != id } },
                                        shove = { step -> e.startEntryShift(r.value, step) })
                                } else {
                                    TvRailsRow(translated(r.text), an = r.value !in e.startOut,
                                                  canHigh = index != 0, canGoDown = index != entries.lastIndex,
                                                  toggle = { e.startOut = if (r.value in e.startOut) e.startOut - r.value else e.startOut + r.value },
                                                  shove = { step -> e.startEntryShift(r.value, step) })
                                }
                                SeparatorLine()
                            }
                            TvToggleRow(translated("Neuzugänge getrennt"), e.newAccessDisconnected, Glyph.Shared) { e.newAccessDisconnected = !e.newAccessDisconnected }
                            SeparatorLine()
                            TvValueRow(translated("Bibliothek hinzufügen"), Glyph.Plus, if (freeLibraries.isEmpty()) translated("Keins offen") else "",
                                       opened, setOpened, reportRow, freeLibraries.map { Choice(it.id, it.name) }, "") { id ->
                                freeLibraries.firstOrNull { it.id == id }?.let { e.startLibraries = e.startLibraries + it }
                            }
                            }
                            TvGroup(translated("Genres")) {
                            // **One list, two forms**: the same value row as "Puffer" etc., not two rows with check marks,
                            // matching `ProfileView.swift`.
                            TvValueRow(translated("Form"), Glyph.Pill, if (e.genreChips) translated("Als Chips") else translated("Als Reihen"),
                                       opened, setOpened, reportRow,
                                       listOf(Choice("reihen", translated("Als eigene Reihen")), Choice("chips", translated("Als Chips über den Reihen"))),
                                       if (e.genreChips) "chips" else "reihen") { e.genreChips = it == "chips" }
                            e.startGenres.forEach { g ->
                                SeparatorLine()
                                TvAction(name = g, value = translated("Entfernen")) { e.startGenres = e.startGenres - g }
                            }
                            SeparatorLine()
                            val freeGenres = allGenres.filter { it !in e.startGenres }
                            TvValueRow(translated("Genre hinzufügen"), Glyph.Plus,
                                       if (genresDisturbed && allGenres.isEmpty()) translated("Server ist abgetaucht")
                                       else if (freeGenres.isEmpty()) translated("Keins offen") else "",
                                       opened, setOpened, reportRow, freeGenres.map { Choice(it, it) }, "") { g -> e.startGenres = e.startGenres + g }
                            }
                        }
                        Compartment.Integration -> {
                            // **A second service, not a second server**, so a status line says whether it is connected, with
                            // the action below. As on tvOS the status line itself is not focusable.
                            TvGroup(translated(compartment.title)) {
                            TvDisplay(translated("Seerr"), translated(if (app.seerrConnected.value) "Verbunden" else "Nicht verbunden"))
                            SeparatorLine()
                            TvAction(translated(if (app.seerrConnected.value) "Ändern" else "Anbinden"), Glyph.SparkleSearch, modifier = first) {
                                open(Destination("seerr", "Seerr", "Seerr"))
                            }
                            }
                        }
                        Compartment.Server -> {
                            // Mirrors `ProfileView.swift` `model.serverName`: the server name, not the stored address; the
                            // host is only the fallback when there is no name.
                            TvGroup(translated(compartment.title)) {
                            TvDisplay(translated("Adresse"), server?.first?.ifEmpty { null } ?: app.serverName.value ?: host.ifEmpty { "—" })
                            SeparatorLine()
                            TvDisplay(translated("Fassung"), server?.second?.let { "${ServerKind.from(app.kind()).shownName} $it" } ?: "—")
                            TvVersionDisplay(app, SwiftlyApplication.VersionRow.removePrefix("Swiftly Player "))
                            SeparatorLine()
                            // Multiple servers; formerly the bundle held exactly one.
                            TvAction(translated("Server hinzufügen"), Glyph.Plus) { open(Destination("serveraufnahme", translated("Server hinzufügen"), "ServerAufnahme")) }
                            SeparatorLine()
                            // For servers behind a service like Cloudflare Access.
                            TvAction(translated("Eigene Header"), Glyph.Keys) { open(Destination("eigenkoepfe", translated("Eigene Header"), "EigeneKoepfe")) }
                            SeparatorLine()
                            // As on tvOS, "Verbindung pruefen" carries the first focus of this section, not "Server
                            // hinzufuegen", as in `ProfileView.swift`.
                            TvAction(translated("Verbindung prüfen"), Glyph.Wlan, value = verification, arrow = false, modifier = first) {
                                verification = translated("Moment…")
                                run.launch {
                                    verification = try {
                                        val o = JSONObject(withContext(Dispatchers.IO) { app.kern.serverInfo().await() })
                                        translated("Erreichbar — Jellyfin %@", o.optString("version"))
                                    } catch (x: CancellationException) { throw x } catch (x: Exception) { errorString(app, x) }
                                }
                            }
                            }
                        }
                        Compartment.Account -> {
                            // **"Weiteres Konto hinzufuegen" is the plus in the account card**, where the accounts are, as on
                            // tvOS. In its place here the second server: the same action as "Server hinzufuegen" in the server
                            // section, the same catalog key and the same target (`ServerAufnahme` -> `TvServerOnboarding`).
                            // Settings follow the account to every device (`SettingsSyncRun`).
                            // Only servers that keep display preferences (`ServerCapability.settingsSync`).
                            val syncs = app.can("settingsSync")
                            TvGroup(translated(compartment.title)) {
                            if (syncs) {
                                TvToggleRow(translated("Einstellungen auf allen Geräten gleich halten"), app.settingsSync.on.value, Glyph.Rotate, modifier = first) {
                                    app.settingsSync.onSet(!app.settingsSync.on.value)
                                }
                                SeparatorLine()
                            }
                            TvAction(translated("Server hinzufügen"), Glyph.Plus, modifier = if (syncs) Modifier else first) {
                                open(Destination("serveraufnahme", translated("Server hinzufügen"), "ServerAufnahme"))
                            }
                            SeparatorLine()
                            // The way back from "off" in the cold-start picker.
                            AskAtLaunchRow(app)
                            SeparatorLine()
                            TvAction(translated("Abmelden"), Glyph.SignOut) { app.signOff() }
                            }
                        }
                        Compartment.Swiftly -> {
                            // Mirrors the "Swiftly" section on tvOS. There QR codes; here the addresses to type in, since a QR
                            // image would need a library of its own. Rating opens the Play Store, which Android TV has; the rest
                            // needs a browser, which is usually missing.
                            // "Support Swiftly" first: the one row of this section that is always worth a look.
                            val supportShown = app.support.available || app.support.isSupporter
                            TvGroup(translated(compartment.title)) {
                            if (supportShown) {
                                TvSupportEntryRow(app, first)
                                SeparatorLine()
                            }
                            TvAction(translated("Swiftly bewerten"), Glyph.Star, modifier = if (supportShown) Modifier else first) {
                                app.addressOpen(context, app.communityAddress("play"))
                            }
                            SeparatorLine()
                            TvDisplay(translated("Discord beitreten"), app.communityAddress("discordKurz"), Glyph.Conversation)
                            SeparatorLine()
                            TvDisplay(translated("Fehler melden"), app.communityAddress("fehlerKurz"), Glyph.Beetle)
                            SeparatorLine()
                            TvAction(translated("Open-Source-Lizenzen"), Glyph.Book) {
                                open(Destination("lizenzen", translated("Open-Source-Lizenzen"), "Lizenzen"))
                            }
                            }
                        }
                    }
                }
            }
        }
    }
    }
    }
}

// MARK: - Rows

/** A section in the left column. Mirrors `SectionStyle` (tvOS 1.1): symbol and name, 30 pt / 600 always (the weight
 *  stays, so the row does not shift). **Focus is white** with dark type, as on every other control; the accent tint
 *  and accent type are the choice. `rests`: selected but handed off to the right column, so grey type on the calm
 *  surface instead of accent. */
@Composable
private fun SectionRow(title: String, glyph: Glyph, selected: Boolean, rests: Boolean, modifier: Modifier = Modifier,
                          focusChanged: (Boolean) -> Unit = {}, perform: () -> Unit) {
    FocusArea(modifier.fillMaxWidth().semantics { this.selected = selected }, magnifier = TvTheme.focusMagnifierWide,
              lift = true, liftCorner = TvTheme.corner, focusChanged = focusChanged, perform = perform) { focus ->
        val target = when {
            focus             -> Color.White
            selected && rests -> Theme.area
            selected          -> Theme.accent.copy(alpha = TvSpec.sectionSelectedOpacity)
            else              -> Color.White.copy(alpha = 0f)
        }
        val reason by animateColorAsState(target, tvTween(TvSpec.focusMs), label = "sectionSurface")
        val ink = when {
            focus -> Theme.reason
            !selected -> Theme.font
            rests -> Theme.fontQuiet
            else -> Theme.accent
        }
        Row(Modifier.fillMaxWidth().height(TvTheme.rowsHeight).clip(RoundedCornerShape(TvTheme.corner))
                .background(reason).padding(horizontal = TvSpec.rowInset),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(TvSpec.rowSpacing)) {
            Box(Modifier.width(TvSpec.rowSymbolColumn), contentAlignment = Alignment.Center) {
                Symbol(glyph, TvSpec.rowSymbol, color = ink, strength = Strength.Medium)
            }
            Text(title, style = SettingsLook.rowText.copy(fontWeight = FontWeight.SemiBold), color = ink, maxLines = 1)
        }
    }
}

/** The version row; supporters see the heart and "Supporter" next to the number. */
@Composable
private fun TvVersionDisplay(app: SwiftlyApplication, version: String) {
    Row(Modifier.fillMaxWidth().heightIn(min = TvTheme.rowsHeight),
        verticalAlignment = Alignment.CenterVertically) {
        Text("Swiftly", style = SettingsLook.rowText, color = Theme.font, maxLines = 1, modifier = Modifier.weight(1f))
        if (app.support.isSupporter) {
            Symbol(Glyph.HeartFilled, 11.dp, color = Theme.accent)
            Text(translated("Unterstützer"), style = TvTheme.tile, color = Theme.accent, maxLines = 1,
                 modifier = Modifier.padding(start = TvSpec.supporterGapStart, end = TvSpec.supporterGapEnd))
        }
        Text(version, style = SettingsLook.rowText, color = Theme.fontVeryQuiet, maxLines = 1)
    }
}

/** Row without action, a status only. Mirrors `DisplayRow`. Unlike every row beside it not a
 *  button: a status without effect that still accepts focus is a trap on a TV. */
@Composable
private fun TvDisplay(title: String, value: String, glyph: Glyph? = null, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().heightIn(min = TvTheme.rowsHeight),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(SettingsLook.rowGap)) {
        RowSymbol(glyph, false)
        Text(title, style = SettingsLook.rowText, color = Theme.font,
             maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(TvSpec.rowSpacerMin))
        Text(value, style = SettingsLook.rowText, color = Theme.fontVeryQuiet, maxLines = 1)
    }
}

/** Value and arrow at the right end of a row (`SettingsValue`); on the white focus surface both turn dark. */
@Composable
private fun SettingsValue(value: String, arrow: Boolean, expanded: Boolean, enabled: Boolean, focus: Boolean) {
    val ink = if (focus) Theme.reason else Theme.fontVeryQuiet
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(SettingsLook.valueGap)) {
        Text(value, style = SettingsLook.rowText, color = ink, maxLines = 1)
        if (arrow) Symbol(if (expanded) Glyph.AngleUp else Glyph.AngleDown, TvSpec.valueIcon, color = ink, strength = Strength.Semibold)
    }
}

/** Row that triggers something, with or without value and trailing arrow. Mirrors `ActionRow` with
 *  `SettingsRowsStyle` (the old `RowsStyle` anywhere the settings look is off). `name` is the server's wording (genre)
 *  and does not go through the catalog. `expanded` (a value row) turns the arrow up. `enabled = false` is dimmed
 *  and takes no focus. */
@Composable
internal fun TvAction(title: String = "", glyph: Glyph? = null, name: String? = null, value: String? = null,
                        arrow: Boolean = value != null, expanded: Boolean = false, enabled: Boolean = true,
                        modifier: Modifier = Modifier, perform: () -> Unit) {
    if (LocalSettingsLook.current) {
        TvSettingsRow(modifier, enabled = enabled, spacing = SettingsLook.rowGap, perform = perform) { focus ->
            RowSymbol(glyph, focus)
            Text(name ?: title, style = SettingsLook.rowText, color = if (focus) Theme.reason else Theme.font,
                 maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            if (value != null) SettingsValue(value, arrow, expanded, enabled, focus)
        }
        return
    }
    FocusArea(modifier.fillMaxWidth().focusProperties { canFocus = enabled }, magnifier = 1f, perform = { if (enabled) perform() }) { focus ->
        Row(Modifier.fillMaxWidth().height(TvTheme.rowsHeight).clip(RoundedCornerShape(TvTheme.corner))
                .background(tvFocusSurface(focus)).padding(horizontal = TvSpec.rowInset),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(TvSpec.rowSpacing)) {
            Text(name ?: title, style = TvTheme.body.copy(fontWeight = if (focus) FontWeight.SemiBold else FontWeight.Medium),
                 color = if (enabled) Theme.font else Theme.fontVeryQuiet,
                 maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            if (value != null) {
                Text(value, style = TvTheme.tile, color = if (enabled) Theme.fontQuiet else Theme.fontVeryQuiet, maxLines = 1)
                if (arrow) Symbol(if (expanded) Glyph.AngleUp else Glyph.AngleDown, TvSpec.valueIcon,
                                  color = Theme.fontVeryQuiet.copy(alpha = if (enabled) 1f else 0.5f), strength = Strength.Semibold)
            }
        }
    }
}

/** A row with a value that opens its choice **below it** instead of a sheet (tvOS: `valueRow`). One open at a
 *  time; the choice is the same row shape, indented, with a check on the current one. A choice closes the row and
 *  hands focus back to it. */
@Composable
private fun TvValueRow(title: String, glyph: Glyph?, value: String?, opened: String?, setOpened: (String?) -> Unit,
                          report: (String, Float) -> Unit, entries: List<Choice>, selected: String,
                          enabled: Boolean = true, modifier: Modifier = Modifier, select: (String) -> Unit) {
    val open = opened == title
    val header = remember { FocusRequester() }
    Column(Modifier.fillMaxWidth().onGloballyPositioned { report(title, it.positionInRoot().y) }) {
        TvAction(title, glyph, value = value ?: "", expanded = open, enabled = enabled,
                 modifier = modifier.focusRequester(header)) { setOpened(if (open) null else title) }
        androidx.compose.animation.AnimatedVisibility(open,
            enter = androidx.compose.animation.expandVertically(tvTween(TvSpec.valueExpandMs, TvSpec.easeInOutCurve)) +
                    androidx.compose.animation.fadeIn(tvTween(TvSpec.valueExpandMs, TvSpec.easeInOutCurve)),
            exit = androidx.compose.animation.shrinkVertically(tvTween(TvSpec.valueExpandMs, TvSpec.easeInOutCurve)) +
                    androidx.compose.animation.fadeOut(tvTween(TvSpec.valueExpandMs, TvSpec.easeInOutCurve))) {
            // Settings look: the choices start under the title (symbol column + gap), not under the symbol.
            val look = LocalSettingsLook.current
            Column(Modifier.fillMaxWidth()
                       .padding(start = if (look) TvSpec.rowSymbolColumn + SettingsLook.rowGap else TvSpec.rowInset).focusGroup()) {
                entries.forEach { c ->
                    val isSelected = c.value == selected
                    val choiceMod = Modifier.semantics { this.selected = isSelected }
                    val pick = { select(c.value); setOpened(null); runCatching { header.requestFocus() }; Unit }
                    if (look) {
                        TvSettingsRow(choiceMod, spacing = TvSpec.rowSpacing, perform = pick) { focus ->
                            Box(Modifier.width(TvSpec.choiceCheckWidth), contentAlignment = Alignment.Center) {
                                if (isSelected) Symbol(Glyph.Checkmark, TvSpec.valueIcon, color = if (focus) Theme.reason else Theme.accent, strength = Strength.Semibold)
                            }
                            Text(c.text, style = SettingsLook.rowText.copy(fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Medium),
                                 color = if (focus) Theme.reason else Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                        }
                    } else FocusArea(choiceMod.fillMaxWidth(), magnifier = 1f, perform = pick) { focus ->
                        Row(Modifier.fillMaxWidth().height(TvTheme.rowsHeight).clip(RoundedCornerShape(TvTheme.corner))
                                .background(tvFocusSurface(focus)).padding(horizontal = TvSpec.rowInset),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(TvSpec.rowSpacing)) {
                            Box(Modifier.width(TvSpec.choiceCheckWidth), contentAlignment = Alignment.Center) {
                                if (isSelected) Symbol(Glyph.Checkmark, TvSpec.valueIcon, color = Theme.accent, strength = Strength.Semibold)
                            }
                            Text(c.text, style = TvTheme.body.copy(fontWeight = if (focus) FontWeight.SemiBold else FontWeight.Medium),
                                 color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                        }
                    }
                }
            }
        }
    }
}

/** The drawn switch. Mirrors `Schalter` (tvOS). Not a Material `Switch`: own size, own radius, own
 *  motion. Focus sits on the row, not on the switch. Disabled keeps its position, dimmed. In the settings look
 *  (design): the knob is white in both states, off is white 18 %, on a focused row dark 18 %, on is the accent. */
@Composable
internal fun TvToggle(an: Boolean, enabled: Boolean = true, focus: Boolean = false) {
    val look = LocalSettingsLook.current
    val width = TvSpec.toggleWidth; val height = TvSpec.toggleHeight
    val circle = if (look) SettingsLook.toggleKnob else TvSpec.toggleKnob
    val inset = if (look) SettingsLook.toggleInset else TvSpec.toggleInset
    val animation = if (enabled) tvTween<Dp>(TvSpec.toggleMs, TvSpec.easeInOutCurve) else snap<Dp>()
    val offset by animateDpAsState(if (an) width - circle - inset else inset, animation, label = "schalterVersatz")
    val track = when {
        !enabled -> if (an) Theme.accent.copy(alpha = TvSpec.toggleTrackOnDisabledOpacity) else Color.White.copy(alpha = TvSpec.toggleTrackOffDisabledOpacity)
        an -> Theme.accent
        look && focus -> Theme.reason.copy(alpha = 0.18f)
        look -> Color.White.copy(alpha = 0.18f)
        else -> Color.White.copy(alpha = TvSpec.toggleTrackOffOpacity)
    }
    val knob = when {
        !enabled -> Color.White.copy(alpha = TvSpec.toggleKnobDisabledOpacity)
        look -> Color.White
        else -> if (an) Theme.reason else Color.White
    }
    val capsule by animateColorAsState(track, if (enabled) tvTween(TvSpec.toggleMs, TvSpec.easeInOutCurve) else snap(), label = "schalterKapsel")
    val button by animateColorAsState(knob, if (enabled) tvTween(TvSpec.toggleMs, TvSpec.easeInOutCurve) else snap(), label = "schalterKnopf")
    Box(Modifier.width(width).height(height).clip(CircleShape).background(capsule)) {
        Box(Modifier.offset(x = offset, y = inset).size(circle).clip(CircleShape).background(button))
    }
}

/** Row with a switch on the right. Mirrors `ToggleRow`. The whole row is pressed. */
@Composable
internal fun TvToggleRow(title: String, an: Boolean, glyph: Glyph? = null, enabled: Boolean = true, modifier: Modifier = Modifier, perform: () -> Unit) {
    if (LocalSettingsLook.current) {
        TvSettingsRow(modifier, enabled = enabled, spacing = SettingsLook.rowGap, perform = perform) { focus ->
            RowSymbol(glyph, focus)
            Text(title, style = SettingsLook.rowText, color = if (focus) Theme.reason else Theme.font, maxLines = 1,
                 overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(TvSpec.rowSpacerMin))
            TvToggle(an, enabled, focus)
        }
        return
    }
    FocusArea(modifier.fillMaxWidth().focusProperties { canFocus = enabled }, magnifier = 1f, perform = { if (enabled) perform() }) { focus ->
        Row(Modifier.fillMaxWidth().height(TvTheme.rowsHeight).clip(RoundedCornerShape(TvTheme.corner))
                .background(tvFocusSurface(focus)).padding(horizontal = TvSpec.rowInset),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(TvSpec.rowSpacing)) {
            Text(title, style = TvTheme.body.copy(fontWeight = if (focus) FontWeight.SemiBold else FontWeight.Medium),
                 color = if (enabled) Theme.font else Theme.fontVeryQuiet, maxLines = 1,
                 overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            TvToggle(an, enabled)
        }
    }
}

/** A Home row: on or off, and where it belongs. Mirrors `RailsRow`. Arrows instead of a drag
 *  handle, since a remote has nothing to grab. */
@Composable
private fun TvRailsRow(name: String, an: Boolean, canHigh: Boolean, canGoDown: Boolean,
                           toggle: () -> Unit, shove: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(TvSpec.rowSpacing)) {
        TvToggleRow(name, an, modifier = Modifier.weight(1f), perform = toggle)
        TvButton(null, Glyph.AngleUp, height = TvSpec.iconButtonHeight, released = canHigh, description = translated("Nach oben")) { shove(-1) }
        TvButton(null, Glyph.AngleDown, height = TvSpec.iconButtonHeight, released = canGoDown, description = translated("Nach unten")) { shove(1) }
    }
}

/** A chosen library or collection: OK removes it, the arrows move it. The name comes from the server. */
@Composable
private fun TvLibraryRow(name: String, canHigh: Boolean, canGoDown: Boolean,
                               remove: () -> Unit, shove: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(TvSpec.rowSpacing)) {
        TvAction(name = name, value = translated("Entfernen"), arrow = false, modifier = Modifier.weight(1f), perform = remove)
        TvButton(null, Glyph.AngleUp, height = TvSpec.iconButtonHeight, released = canHigh, description = translated("Nach oben")) { shove(-1) }
        TvButton(null, Glyph.AngleDown, height = TvSpec.iconButtonHeight, released = canGoDown, description = translated("Nach unten")) { shove(1) }
    }
}

/** Hairline between rows. Mirrors `SeparatorLine` in the settings look: the line is the last pixel inside the 84 pt
 *  high row, so it takes no height of its own. */
@Composable
private fun SeparatorLine() {
    Box(Modifier.fillMaxWidth().height(0.dp).drawBehind {
        drawRect(Theme.line, topLeft = androidx.compose.ui.geometry.Offset(0f, -1.dp.toPx()),
                 size = androidx.compose.ui.geometry.Size(size.width, 1.dp.toPx()))
    })
}

// MARK: - Account

/** Who is signed in, on the page itself without a card. Mirrors `accountBlock`: image, name, server, below it the
 *  other accounts and the plus. */
@Composable
private fun AccountBlock(app: SwiftlyApplication, serverRow: String, cards: List<JSONObject>,
                        record: () -> Unit, switchTo: (String) -> Unit) {
    Column(Modifier.fillMaxWidth()) {
        Box {
            ProfileImage(app, TvSpec.accountAvatar)
            SupporterAvatarHeart(app, TvSpec.accountAvatar)
        }
        Text(app.username(), style = TvTheme.rail,
             color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.padding(top = TvSpec.accountNameTop))
        // Server data, not catalog text.
        Text(serverRow, style = TvTheme.small, color = Theme.fontVeryQuiet, maxLines = 1,
             modifier = Modifier.padding(top = TvSpec.accountServerTop))
        Box(Modifier.padding(top = SettingsLook.accountStripTop)) { AccountsStrip(cards, record, switchTo) }
    }
}

/** The other accounts and the plus, at the bottom of the account card. Mirrors `Kontenstreifen`.
 *  **The signed-in account is no longer part of it**; it is shown larger above. Counts all
 *  accounts from all servers of the bundle, not just the active one, the same reach as
 *  `model.accounts` on tvOS (`AccountBundle.accounts` across all servers). */
@Composable
private fun AccountsStrip(cards: List<JSONObject>, record: () -> Unit, switchTo: (String) -> Unit) {
    val size = TvSpec.accountStripCircle
    val app = androidx.compose.ui.platform.LocalContext.current.applicationContext as SwiftlyApplication
    val density = androidx.compose.ui.platform.LocalDensity.current.density
    val calm = de.paulherter.swiftly.shared.motionReduced()
    val other = cards.flatMap { k ->
        val accounts = k.optJSONArray("konten") ?: JSONArray()
        (0 until accounts.length()).map { accounts.getJSONObject(it) }
    }.filter { !it.optBoolean("aktiv") }

    Row(Modifier.fillMaxWidth().focusGroup(), horizontalArrangement = Arrangement.spacedBy(SettingsLook.accountStripSpacing)) {
        other.forEach { account ->
            // **Switching, with motion** (`AccountSwitchTransition`): the image lifts off from here.
            val frameRect = remember { arrayOf(androidx.compose.ui.geometry.Rect.Zero) }
            FocusArea(magnifier = TvTheme.focusMagnifierSmall, perform = {
                de.paulherter.swiftly.AccountSwitchTransition.start(app, account.optString("kennung"), account.optString("name"),
                    account.optString("bild").ifEmpty { null }, frameRect[0], Theme.area, density, calm)
            }) { focus ->
                Box(Modifier.size(size).onGloballyPositioned { frameRect[0] = it.boundsInRoot() }.clip(CircleShape)
                        .then(if (focus) Modifier.border(2.dp, Color.White, CircleShape) else Modifier)) {
                    AccountCircle(account.optString("name"), account.optString("bild").ifEmpty { null }, size)
                }
            }
        }
        FocusArea(magnifier = TvTheme.focusMagnifierSmall, perform = record) { focus ->
            // Design (tvOS 1.1): a round field, white 10 %, the same size as the circles next to it; the plus in white.
            Box(Modifier.size(size).background(Color.White.copy(alpha = 0.10f), CircleShape)
                    .then(if (focus) Modifier.border(2.dp, Color.White, CircleShape) else Modifier),
                contentAlignment = Alignment.Center) {
                Symbol(Glyph.Plus, 15.dp, color = Theme.font, strength = Strength.Semibold, description = translated("Weiteres Konto hinzufügen"))
            }
        }
    }
}

/** The image of another account, otherwise its initial: the same pattern as `ProfileImage`, only for
 *  an account that is not the current one (own address instead of `app.kern`). */
@Composable
internal fun AccountCircle(name: String, image: String?, size: Dp) {
    SubcomposeAsyncImage(model = image, contentDescription = name, contentScale = ContentScale.Crop,
        modifier = Modifier.size(size).clip(CircleShape),
        error = {
            Box(Modifier.fillMaxSize().background(Theme.profileBrush(name)), contentAlignment = Alignment.Center) {
                Text(name.take(1).uppercase(), color = Theme.font,
                     style = TextStyle(fontSize = (size.value * 0.38f).sp, fontWeight = FontWeight.SemiBold))
            }
        })
}
