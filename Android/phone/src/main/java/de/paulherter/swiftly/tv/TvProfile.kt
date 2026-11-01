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
private enum class Compartment(val title: String) {
    Playback("Wiedergabe"), Languages("Sprachen"), Presentation("Darstellung"),
    Integration("Integration"), Server("Server"), Account("Konto"), Swiftly("Swiftly"),
}

@Composable
private fun GroupsHeader(text: String) {
    Text(text, style = TvTheme.rail,
         color = Theme.fontQuiet, modifier = Modifier.padding(start = TvSpec.rowInset, bottom = TvSpec.groupsTitleBottom))
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
    // The same three values as `Settings.playerEngine`.
    val engines = remember { listOf(
        Choice("dolbyVision", translated("VLC, Dolby Vision mit ExoPlayer")),
        Choice("exoplayer", translated("Immer ExoPlayer")),
        Choice("vlc", translated("Immer VLC"))) }
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
                Box(Modifier.fillMaxWidth().padding(start = TvSpec.rowInset, top = TvSpec.accountSeparatorVertical, bottom = TvSpec.accountSeparatorVertical)
                        .height(TvSpec.hairline).background(Theme.line))
                GroupsHeader(translated("Bereiche"))
                Compartment.entries.filter { it != Compartment.Integration || app.can("seerr") }.forEach { a ->
                    SectionRow(translated(a.title), selected = a == compartment, rests = !leftFocus,
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
            // Dimmed means visible but not active yet: no step to the right leads in, only OK does (tvOS: `.disabled(!inside)`
            // with `.opacity(inside ? 1 : 0.5)` eased over 0.2 s).
            val dim by animateFloatAsState(if (leftFocus) TvSpec.valueDimmedAlpha else 1f,
                                          tvTween(TvSpec.valueDimMs, TvSpec.easeInOutCurve), label = "rightDim")
            Column(Modifier.weight(1f).graphicsLayer { alpha = dim }
                    .focusProperties { enter = { if (leftFocus) FocusRequester.Cancel else FocusRequester.Default } }
                    .onFocusChanged { rightHasFocus = it.hasFocus; if (it.hasFocus) leftFocus = false }
                    .onGloballyPositioned { viewportTop = it.positionInRoot().y }
                    .verticalScroll(rightScroll).padding(vertical = TvTheme.edgeTop).focusGroup()) {
                val first = Modifier.focusRequester(right)
                GroupsHeader(translated(compartment.title))
                Column(Modifier.padding(TvSpec.listCardInset).clip(RoundedCornerShape(TvTheme.cornerTile)).background(Theme.area)) {
                    // One reporter for the value rows below: where each one stands, for the scroll above.
                    val reportRow: (String, Float) -> Unit = { k, y -> rowTops[k] = y }
                    val setOpened: (String?) -> Unit = { opened = it }
                    when (compartment) {
                        Compartment.Playback -> {
                            // If the server does not transcode there is nothing to choose: Direct Play is fixed on and the
                            // bitrate is locked, as on the other versions.
                            val free = e.convertAllowed
                            val directPlay = e.alwaysDirectPlay || !free
                            // **The anchor hangs on the topmost row that is actually available** (tvOS: `free ? .top : .proceed`):
                            // focus on a disabled row goes nowhere.
                            TvToggleRow(translated("Immer Direct Play"), directPlay, enabled = free, modifier = if (free) first else Modifier) {
                                e.alwaysDirectPlay = !e.alwaysDirectPlay; app.qualityReport()
                            }
                            SeparatorLine()
                            // Disabled while Direct Play is forced, since it would have no effect.
                            TvValueRow(translated("Höchste Bitrate"), bitrates.firstOrNull { it.value == e.bitratesLimit.toString() }?.text,
                                       opened, setOpened, reportRow, bitrates, e.bitratesLimit.toString(), enabled = !directPlay) {
                                e.bitratesLimit = it.toInt(); app.qualityReport()
                            }
                            SeparatorLine()
                            TvValueRow(translated("Puffer"), buffer.firstOrNull { it.value == e.bufferLevel }?.text,
                                       opened, setOpened, reportRow, buffer, e.bufferLevel, modifier = if (free) Modifier else first) { e.bufferLevel = it }
                            SeparatorLine()
                            TvValueRow(translated("Player"), engines.firstOrNull { it.value == e.playerEngine }?.text,
                                       opened, setOpened, reportRow, engines, e.playerEngine) { e.playerEngine = it }
                            SeparatorLine()
                            TvToggleRow(translated("Mehrkanal-Ton (5.1)"), e.multiChannelAudio) { e.multiChannelAudio = !e.multiChannelAudio }
                            SeparatorLine()
                            TvToggleRow(translated("Untertitel automatisch"), e.subtitleAutomatic) { e.subtitleAutomatic = !e.subtitleAutomatic }
                            SeparatorLine()
                            // Same storage key as in the player (`TvPlayer`/`TvImageTick`, default on). Not in `Settings`,
                            // because frame rate matching exists only on tvOS/Android TV (`ProfileView.swift` also keeps it via
                            // `@AppStorage`, not in `AppModel`).
                            TvToggleRow(translated("Bildrate an den Film anpassen"), frameRateAdapt) {
                                frameRateAdapt = !frameRateAdapt
                                app.store.remember("bildrateAnpassen", if (frameRateAdapt) "1" else "0")
                            }
                            SeparatorLine()
                            TvToggleRow(translated("Nächste Folge automatisch"), e.nextAutomatic) { e.nextAutomatic = !e.nextAutomatic }
                            SeparatorLine()
                            TvToggleRow(translated("Intro und Abspann automatisch überspringen"), e.introOutroAutomatic) { e.introOutroAutomatic = !e.introOutroAutomatic }
                            SeparatorLine()
                            TvValueRow(translated("Zurückspulen"), translated("%lld s", e.backSeconds),
                                       opened, setOpened, reportRow, secondsSelection(), e.backSeconds.toString()) { e.backSeconds = it.toInt() }
                            SeparatorLine()
                            TvValueRow(translated("Vorspulen"), translated("%lld s", e.forwardSeconds),
                                       opened, setOpened, reportRow, secondsSelection(), e.forwardSeconds.toString()) { e.forwardSeconds = it.toInt() }
                        }
                        Compartment.Languages -> {
                            TvValueRow(translated("Ton"), audioChoice.firstOrNull { it.value == e.audioLanguage }?.text,
                                       opened, setOpened, reportRow, audioChoice, e.audioLanguage, modifier = first) { e.audioLanguage = it }
                            SeparatorLine()
                            TvValueRow(translated("Untertitel"), subtitleSelection.firstOrNull { it.value == e.subtitleLanguage }?.text,
                                       opened, setOpened, reportRow, subtitleSelection, e.subtitleLanguage) { e.subtitleLanguage = it; if (it.isNotEmpty()) e.subtitleAutomatic = true }
                            SeparatorLine()
                            // Own page with the live picture (Apple TV: `TVSubtitleLookEntryRow`).
                            TvAction(translated("Aussehen der Untertitel"),
                                     value = with(de.paulherter.swiftly.SubtitleFacts.of(e.subtitleLook, true)) { entryValue() }) {
                                open(Destination("untertitelaussehen", translated("Aussehen der Untertitel"), "Untertitelaussehen"))
                            }
                        }
                        Compartment.Presentation -> {
                            // The look first, as on Apple TV (`TVLookEntryRow`): tile, name and "Ändern"; opens "Wähl deinen Look".
                            val looksShown = tvLookRowShown(app)
                            if (looksShown) {
                                TvLookRow(app, first)
                                SeparatorLine()
                            }
                            TvToggleRow(translated("Fortschritt auf Kacheln"), e.progress, modifier = if (looksShown) Modifier else first) { e.progress = !e.progress }
                            SeparatorLine()
                            TvToggleRow(translated("Merkliste"), e.watchlist) { e.watchlist = !e.watchlist }
                            TvToggleRow(translated("Alphabetische Suche in Listen"), e.alphabet) { e.alphabet = !e.alphabet }
                            SeparatorLine()
                            TvToggleRow(translated("Titel als Logo"), e.titleAsLogo) { e.titleAsLogo = !e.titleAsLogo }
                            SeparatorLine()
                            GroupsHeader(translated("Startseite"))
                            val rails = remember(e.startRails, e.newAccessDisconnected) { selectionRead(Kern.startRails(e.startRails.toTypedArray(), e.newAccessDisconnected)) }
                            fun move(r: Choice, step: Int) {
                                e.startRails = JSONArray(Kern.startRailShifted(r.value, step.toLong(), e.startRails.toTypedArray(), e.newAccessDisconnected))
                                    .let { a -> (0 until a.length()).map { a.getString(it) } }
                            }
                            rails.forEachIndexed { index, r ->
                                TvRailsRow(translated(r.text), an = r.value !in e.startOut,
                                              canHigh = index != 0, canGoDown = index != rails.lastIndex,
                                              toggle = { e.startOut = if (r.value in e.startOut) e.startOut - r.value else e.startOut + r.value },
                                              shove = { step -> move(r, step) })
                                SeparatorLine()
                            }
                            TvToggleRow(translated("Neuzugänge getrennt"), e.newAccessDisconnected) { e.newAccessDisconnected = !e.newAccessDisconnected }
                            SeparatorLine()
                            GroupsHeader(translated("Bibliotheken und Sammlungen"))
                            // Own rows from the server, after the fixed ones (as in `ProfileView` on tvOS).
                            val libraries = e.startLibraries
                            libraries.forEachIndexed { index, b ->
                                TvLibraryRow(b.name, canHigh = index != 0, canGoDown = index != libraries.lastIndex,
                                    remove = { e.startLibraries = e.startLibraries.filter { it.id != b.id } },
                                    shove = { step ->
                                        val list = e.startLibraries.toMutableList()
                                        val from = list.indexOfFirst { it.id == b.id }
                                        val to = from + step
                                        if (from >= 0 && to in list.indices) { list.removeAt(from); list.add(to, b); e.startLibraries = list }
                                    })
                                SeparatorLine()
                            }
                            TvValueRow(translated("Bibliothek hinzufügen"), if (freeLibraries.isEmpty()) translated("Keins offen") else "",
                                       opened, setOpened, reportRow, freeLibraries.map { Choice(it.id, it.name) }, "") { id ->
                                freeLibraries.firstOrNull { it.id == id }?.let { e.startLibraries = e.startLibraries + it }
                            }
                            SeparatorLine()
                            GroupsHeader(translated("Genres"))
                            // **One list, two forms**: the same value row as "Puffer" etc., not two rows with check marks,
                            // matching `ProfileView.swift`.
                            TvValueRow(translated("Form"), if (e.genreChips) translated("Als Chips") else translated("Als Reihen"),
                                       opened, setOpened, reportRow,
                                       listOf(Choice("reihen", translated("Als eigene Reihen")), Choice("chips", translated("Als Chips über den Reihen"))),
                                       if (e.genreChips) "chips" else "reihen") { e.genreChips = it == "chips" }
                            e.startGenres.forEach { g ->
                                SeparatorLine()
                                TvAction(name = g, value = translated("Entfernen")) { e.startGenres = e.startGenres - g }
                            }
                            SeparatorLine()
                            val freeGenres = allGenres.filter { it !in e.startGenres }
                            TvValueRow(translated("Genre hinzufügen"),
                                       if (genresDisturbed && allGenres.isEmpty()) translated("Server ist abgetaucht")
                                       else if (freeGenres.isEmpty()) translated("Keins offen") else "",
                                       opened, setOpened, reportRow, freeGenres.map { Choice(it, it) }, "") { g -> e.startGenres = e.startGenres + g }
                        }
                        Compartment.Integration -> {
                            // **A second service, not a second server**, so a status line says whether it is connected, with
                            // the action below. As on tvOS the status line itself is not focusable.
                            TvDisplay(translated("Seerr"), translated(if (app.seerrConnected.value) "Verbunden" else "Nicht verbunden"))
                            SeparatorLine()
                            TvAction(translated(if (app.seerrConnected.value) "Ändern" else "Anbinden"), modifier = first) {
                                open(Destination("seerr", "Seerr", "Seerr"))
                            }
                        }
                        Compartment.Server -> {
                            // Mirrors `ProfileView.swift` `model.serverName`: the server name, not the stored address; the
                            // host is only the fallback when there is no name.
                            TvDisplay(translated("Adresse"), server?.first?.ifEmpty { null } ?: app.serverName.value ?: host.ifEmpty { "—" })
                            SeparatorLine()
                            TvDisplay(translated("Fassung"), server?.second?.let { "${ServerKind.from(app.kind()).shownName} $it" } ?: "—")
                            TvVersionDisplay(app, SwiftlyApplication.VersionRow.removePrefix("Swiftly Player "))
                            SeparatorLine()
                            // Multiple servers; formerly the bundle held exactly one.
                            TvAction(translated("Server hinzufügen")) { open(Destination("serveraufnahme", translated("Server hinzufügen"), "ServerAufnahme")) }
                            SeparatorLine()
                            // For servers behind a service like Cloudflare Access.
                            TvAction(translated("Eigene Header")) { open(Destination("eigenkoepfe", translated("Eigene Header"), "EigeneKoepfe")) }
                            SeparatorLine()
                            // As on tvOS, "Verbindung pruefen" carries the first focus of this section, not "Server
                            // hinzufuegen", as in `ProfileView.swift`.
                            TvAction(translated("Verbindung prüfen"), value = verification, arrow = false, modifier = first) {
                                verification = translated("Moment…")
                                run.launch {
                                    verification = try {
                                        val o = JSONObject(withContext(Dispatchers.IO) { app.kern.serverInfo().await() })
                                        translated("Erreichbar — Jellyfin %@", o.optString("version"))
                                    } catch (x: CancellationException) { throw x } catch (x: Exception) { errorString(app, x) }
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
                            if (syncs) {
                                TvToggleRow(translated("Einstellungen auf allen Geräten gleich halten"), app.settingsSync.on.value, modifier = first) {
                                    app.settingsSync.onSet(!app.settingsSync.on.value)
                                }
                                SeparatorLine()
                            }
                            TvAction(translated("Server hinzufügen"), modifier = if (syncs) Modifier else first) {
                                open(Destination("serveraufnahme", translated("Server hinzufügen"), "ServerAufnahme"))
                            }
                            SeparatorLine()
                            // The way back from "off" in the cold-start picker.
                            AskAtLaunchRow(app)
                            SeparatorLine()
                            TvAction(translated("Abmelden")) { app.signOff() }
                        }
                        Compartment.Swiftly -> {
                            // Mirrors the "Swiftly" section on tvOS. There QR codes; here the addresses to type in, since a QR
                            // image would need a library of its own. Rating opens the Play Store, which Android TV has; the rest
                            // needs a browser, which is usually missing.
                            // "Support Swiftly" first: the one row of this section that is always worth a look.
                            val supportShown = app.support.available || app.support.isSupporter
                            if (supportShown) {
                                TvSupportEntryRow(app, first)
                                SeparatorLine()
                            }
                            TvAction(translated("Swiftly bewerten"), modifier = if (supportShown) Modifier else first) {
                                app.addressOpen(context, app.communityAddress("play"))
                            }
                            SeparatorLine()
                            TvDisplay(translated("Discord beitreten"), app.communityAddress("discordKurz"))
                            SeparatorLine()
                            TvDisplay(translated("Fehler melden"), app.communityAddress("fehlerKurz"))
                            SeparatorLine()
                            TvAction(translated("Open-Source-Lizenzen")) {
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

// MARK: - Rows

/** A section in the left column. Mirrors `SectionStyle`: four states, no icon; selected carries
 *  accent surface and accent text, focused the calm surface. `rests`: selected but handed off to
 *  the right column, so grey type on the calm surface instead of accent. */
@Composable
private fun SectionRow(title: String, selected: Boolean, rests: Boolean, modifier: Modifier = Modifier,
                          focusChanged: (Boolean) -> Unit = {}, perform: () -> Unit) {
    FocusArea(modifier.fillMaxWidth(), magnifier = 1f, focusChanged = focusChanged, perform = perform) { focus ->
        val target = when {
            selected && focus -> Theme.accent.copy(alpha = TvSpec.sectionSelectedFocusedOpacity)
            selected && rests -> Theme.area
            selected          -> Theme.accent.copy(alpha = TvSpec.sectionSelectedOpacity)
            focus             -> TvTheme.focusArea
            else              -> TvTheme.focusArea.copy(alpha = 0f)
        }
        val reason by animateColorAsState(target, tvTween(TvSpec.focusMs), label = "sectionSurface")
        val ink by animateColorAsState(if (selected) (if (rests) Theme.fontQuiet else Theme.accent) else Theme.font,
                                       tvTween(TvSpec.focusMs), label = "sectionInk")
        Row(Modifier.fillMaxWidth().height(TvTheme.rowsHeight).clip(RoundedCornerShape(TvTheme.corner))
                .background(reason).padding(horizontal = TvSpec.rowInset),
            verticalAlignment = Alignment.CenterVertically) {
            // The weight stays when it rests: you should find where you were when going back.
            Text(title, style = TvTheme.body.copy(
                     fontWeight = if (selected || focus) FontWeight.SemiBold else FontWeight.Medium),
                 color = ink, maxLines = 1)
        }
    }
}

/** The version row; supporters see the heart and "Supporter" next to the number. */
@Composable
private fun TvVersionDisplay(app: SwiftlyApplication, version: String) {
    Row(Modifier.fillMaxWidth().height(TvTheme.rowsHeight).padding(horizontal = TvSpec.rowInset),
        verticalAlignment = Alignment.CenterVertically) {
        Text("Swiftly", style = TvTheme.body, color = Theme.font, maxLines = 1, modifier = Modifier.weight(1f))
        if (app.support.isSupporter) {
            Symbol(Glyph.HeartFilled, 11.dp, color = Theme.accent)
            Text(translated("Unterstützer"), style = TvTheme.tile, color = Theme.accent, maxLines = 1,
                 modifier = Modifier.padding(start = TvSpec.supporterGapStart, end = TvSpec.supporterGapEnd))
        }
        Text(version, style = TvTheme.tile, color = Theme.fontQuiet, maxLines = 1)
    }
}

/** Row without action, a status only. Mirrors `DisplayRow`. Unlike every row beside it not a
 *  button: a status without effect that still accepts focus is a trap on a TV. */
@Composable
private fun TvDisplay(title: String, value: String, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().height(TvTheme.rowsHeight).padding(horizontal = TvSpec.rowInset),
        verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = TvTheme.body, color = Theme.font,
             maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(TvSpec.rowSpacerMin))
        Text(value, style = TvTheme.tile, color = Theme.fontQuiet, maxLines = 1)
    }
}

/** Row that triggers something, with or without value and trailing arrow. Mirrors `ActionRow` with
 *  `RowsStyle`. `name` is the server's wording (genre) and does not go through the catalog. `expanded`
 *  (a value row) turns the arrow up. `enabled = false` is dimmed on title, value and arrow and takes
 *  no focus. */
@Composable
internal fun TvAction(title: String = "", name: String? = null, value: String? = null,
                        arrow: Boolean = value != null, expanded: Boolean = false, enabled: Boolean = true,
                        modifier: Modifier = Modifier, perform: () -> Unit) {
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
private fun TvValueRow(title: String, value: String?, opened: String?, setOpened: (String?) -> Unit,
                          report: (String, Float) -> Unit, entries: List<Choice>, selected: String,
                          enabled: Boolean = true, modifier: Modifier = Modifier, select: (String) -> Unit) {
    val open = opened == title
    val header = remember { FocusRequester() }
    Column(Modifier.fillMaxWidth().onGloballyPositioned { report(title, it.positionInRoot().y) }) {
        TvAction(title, value = value ?: "", expanded = open, enabled = enabled,
                 modifier = modifier.focusRequester(header)) { setOpened(if (open) null else title) }
        androidx.compose.animation.AnimatedVisibility(open,
            enter = androidx.compose.animation.expandVertically(tvTween(TvSpec.valueExpandMs, TvSpec.easeInOutCurve)) +
                    androidx.compose.animation.fadeIn(tvTween(TvSpec.valueExpandMs, TvSpec.easeInOutCurve)),
            exit = androidx.compose.animation.shrinkVertically(tvTween(TvSpec.valueExpandMs, TvSpec.easeInOutCurve)) +
                    androidx.compose.animation.fadeOut(tvTween(TvSpec.valueExpandMs, TvSpec.easeInOutCurve))) {
            Column(Modifier.fillMaxWidth().padding(start = TvSpec.rowInset).focusGroup()) {
                entries.forEach { c ->
                    val isSelected = c.value == selected
                    FocusArea(Modifier.fillMaxWidth().semantics { this.selected = isSelected }, magnifier = 1f, perform = {
                        select(c.value); setOpened(null); runCatching { header.requestFocus() }
                    }) { focus ->
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
 *  motion. Focus sits on the row, not on the switch. Disabled keeps its position, dimmed. */
@Composable
internal fun TvToggle(an: Boolean, enabled: Boolean = true) {
    val width = TvSpec.toggleWidth; val height = TvSpec.toggleHeight; val circle = TvSpec.toggleKnob; val inset = TvSpec.toggleInset
    val animation = if (enabled) tvTween<Dp>(TvSpec.toggleMs, TvSpec.easeInOutCurve) else snap<Dp>()
    val offset by animateDpAsState(if (an) width - circle - inset else inset, animation, label = "schalterVersatz")
    val track = when {
        !enabled -> if (an) Theme.accent.copy(alpha = TvSpec.toggleTrackOnDisabledOpacity) else Color.White.copy(alpha = TvSpec.toggleTrackOffDisabledOpacity)
        else     -> if (an) Theme.accent else Color.White.copy(alpha = TvSpec.toggleTrackOffOpacity)
    }
    val knob = when {
        !enabled -> Color.White.copy(alpha = TvSpec.toggleKnobDisabledOpacity)
        else     -> if (an) Theme.reason else Color.White
    }
    val capsule by animateColorAsState(track, if (enabled) tvTween(TvSpec.toggleMs, TvSpec.easeInOutCurve) else snap(), label = "schalterKapsel")
    val button by animateColorAsState(knob, if (enabled) tvTween(TvSpec.toggleMs, TvSpec.easeInOutCurve) else snap(), label = "schalterKnopf")
    Box(Modifier.width(width).height(height).clip(CircleShape).background(capsule)) {
        Box(Modifier.offset(x = offset, y = inset).size(circle).clip(CircleShape).background(button))
    }
}

/** Row with a switch on the right. Mirrors `ToggleRow`. The whole row is pressed. */
@Composable
internal fun TvToggleRow(title: String, an: Boolean, enabled: Boolean = true, modifier: Modifier = Modifier, perform: () -> Unit) {
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
    Row(Modifier.fillMaxWidth().padding(end = TvSpec.rowInset), verticalAlignment = Alignment.CenterVertically,
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
    Row(Modifier.fillMaxWidth().padding(end = TvSpec.rowInset), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(TvSpec.rowSpacing)) {
        TvAction(name = name, value = translated("Entfernen"), arrow = false, modifier = Modifier.weight(1f), perform = remove)
        TvButton(null, Glyph.AngleUp, height = TvSpec.iconButtonHeight, released = canHigh, description = translated("Nach oben")) { shove(-1) }
        TvButton(null, Glyph.AngleDown, height = TvSpec.iconButtonHeight, released = canGoDown, description = translated("Nach unten")) { shove(1) }
    }
}

/** Hairline between rows. Mirrors `SeparatorLine`. */
@Composable
private fun SeparatorLine() {
    Box(Modifier.fillMaxWidth().padding(horizontal = TvSpec.rowInset).height(TvSpec.hairline).background(Theme.line))
}

// MARK: - Account

/** Who is signed in, on the page itself without a card. Mirrors `accountBlock`: image, name, server, below it the
 *  other accounts and the plus. */
@Composable
private fun AccountBlock(app: SwiftlyApplication, serverRow: String, cards: List<JSONObject>,
                        record: () -> Unit, switchTo: (String) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(start = TvSpec.rowInset)) {
        Box {
            ProfileImage(app, TvSpec.accountAvatar)
            SupporterAvatarHeart(app, TvSpec.accountAvatar)
        }
        Text(app.username(), style = TvTheme.rail,
             color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.padding(top = TvSpec.accountNameTop))
        // Server data, not catalog text.
        Text(serverRow, style = TvTheme.small, color = Theme.fontQuiet, maxLines = 1,
             modifier = Modifier.padding(top = TvSpec.accountServerTop))
        Box(Modifier.padding(top = TvSpec.accountStripTop)) { AccountsStrip(cards, record, switchTo) }
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

    Row(Modifier.fillMaxWidth().focusGroup(), horizontalArrangement = Arrangement.spacedBy(TvSpec.accountStripSpacing)) {
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
            // A field on `area` instead of a dashed circle, focus ring matching and square.
            val form = RoundedCornerShape(Theme.corner)
            Box(Modifier.size(size).background(Theme.area, form)
                    .then(if (focus) Modifier.border(2.dp, Color.White, form) else Modifier),
                contentAlignment = Alignment.Center) {
                Symbol(Glyph.Plus, 12.dp, color = Theme.fontQuiet, strength = Strength.Semibold, description = translated("Weiteres Konto hinzufügen"))
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
            Box(Modifier.fillMaxSize().background(Theme.raised), contentAlignment = Alignment.Center) {
                Text(name.take(1).uppercase(), color = Theme.font,
                     style = TextStyle(fontSize = (size.value * 0.38f).sp, fontWeight = FontWeight.SemiBold))
            }
        })
}
