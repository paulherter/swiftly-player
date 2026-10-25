package de.paulherter.swiftly

import androidx.compose.foundation.layout.RowScope
import androidx.compose.ui.unit.Dp
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.animation.core.EaseInOut
import de.paulherter.swiftly.core.Kern
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.foundation.selection.toggleable
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import de.paulherter.swiftly.shared.Theme
import androidx.compose.animation.core.Animatable
import de.paulherter.swiftly.shared.Motion
import kotlinx.coroutines.launch
import de.paulherter.swiftly.shared.translated
import org.json.JSONArray
import kotlin.reflect.KProperty

/** A library or collection as its own home row (`StartLibrary` in the package). */
data class StartLibraryItem(val id: String, val name: String, val collection: Boolean)

/** A remembered value: Compose state, written to storage on every change. */
private class RememberValue<T>(private val store: Store, private val key: String, beginning: T, private val write: (T) -> String) {
    private val condition = mutableStateOf(beginning)
    operator fun getValue(owner: Any?, characteristic: KProperty<*>): T = condition.value
    operator fun setValue(owner: Any?, characteristic: KProperty<*>, value: T) {
        condition.value = value
        store.remember(key, write(value))
    }
}

/**
 * The settings: same keys and defaults as `AppModel` on iOS (`alwaysDirectPlay`, `bitratesLimit`,
 * `startRails`, ...). The allowed values are defined in the package (`Bitrate`, `Span`,
 * `BufferLevel`, `LanguageSelection`, `StartRailsEpisode`). Downloads, Seerr and tech badge are missing
 * until they exist on Android.
 */
class Settings(store: Store) {
    private val a = store
    private fun bool(k: String, guideline: Boolean) = a.rememberValue(k)?.let { it == "1" } ?: guideline
    private fun figure(k: String, guideline: Int) = a.rememberValue(k)?.toIntOrNull() ?: guideline
    private fun list(k: String) = a.rememberValue(k)?.let { raw ->
        runCatching { JSONArray(raw).let { j -> (0 until j.length()).map { j.getString(it) } } }.getOrNull()
    } ?: emptyList()
    private val yesNo: (Boolean) -> String = { if (it) "1" else "0" }
    private val asList: (List<String>) -> String = { JSONArray(it).toString() }

    /** Never transcode. The reason for this app, so on by default. */
    var alwaysDirectPlay by RememberValue(a, "immerDirectPlay", bool("immerDirectPlay", true), yesNo)
    /** Mbit/s, 0 means unlimited. Applies only without forced Direct Play. */
    var bitratesLimit by RememberValue(a, "bitratenGrenze", figure("bitratenGrenze", 0)) { it.toString() }
    var landscapeFixed by RememberValue(a, "querformatFest", bool("querformatFest", true), yesNo)
    var progress by RememberValue(a, "fortschritt", bool("fortschritt", true), yesNo)
    /** Whether the watchlist appears: page, filter and the button on detail pages (mirrors `watchlistShown`). */
    var watchlist by RememberValue(a, "merklisteAn", bool("merklisteAn", true), yesNo)
    /** Empty means: as the file. */
    var audioLanguage by RememberValue(a, "tonSprache", a.rememberValue("tonSprache").orEmpty()) { it }
    /** Empty means: off. */
    var subtitleLanguage by RememberValue(a, "utSprache", a.rememberValue("utSprache").orEmpty()) { it }
    var subtitleAutomatic by RememberValue(a, "utAuto", bool("utAuto", false), yesNo)
    /** `"1"`/`"0"`, empty: never toggled, so the account applies (`nextAutomaticAccount`). */
    private var nextAutomaticSelection by RememberValue(a, "naechsteAuto", a.rememberValue("naechsteAuto").orEmpty()) { it }
    /**
         * `EnableNextEpisodeAutoPlay` of the current account, `"1"`/`"0"`/empty. Not stored; fetched
         * fresh at each start and account switch (`SwiftlyApplication.accountPreGiftFetch`).
         */
    var nextAutomaticAccount by mutableStateOf("")
    /** Rule in the package (`Weiterschalten.gilt`): own choice before account before "on". Like `AppModel` on iOS. */
    var nextAutomatic: Boolean
        get() = Kern.nextAutomaticApplies(nextAutomaticSelection, nextAutomaticAccount)
        set(value) { nextAutomaticSelection = if (value) "1" else "0" }
    /** "Skip intro and outro automatically"; off by default (iOS: `introAbspannAuto`). The pick is in the core (`SectionLogic.automatic`). */
    var introOutroAutomatic by RememberValue(a, "introAbspannAuto", bool("introAbspannAuto", false), yesNo)
    var newAccessDisconnected by RememberValue(a, "neuGetrennt", bool("neuGetrennt", true), yesNo)
    var startRails by RememberValue(a, "startReihen", list("startReihen"), asList)
    var startOut by RememberValue(a, "startAus", list("startAus"), asList)
    var startGenres by RememberValue(a, "startGenres", list("startGenres"), asList)
    /** The current account's server, lowercase and without trailing slash; the choice belongs to it. Set by the application. */
    var serverKey: () -> String = { "" }
    private val librariesState = mutableIntStateOf(0)
    private var librariesRaw: String? = null
    private var librariesLoaded = false
    private fun librariesKey() = "startBibliotheken|" + serverKey()
    /** After an account or server switch: read the new server's choice. */
    fun librariesNewRead() { librariesLoaded = false; librariesState.intValue++ }
    /**
         * Libraries and collections as their own home rows, in the chosen order, per server
         * (`startLibraries|<server>`), as on Apple. Reading is tolerant: a missing key or a broken
         * entry never takes the whole choice with it. An id that no longer exists there stays and
         * just yields no row.
         */
    var startLibraries: List<StartLibraryItem>
        get() {
            librariesState.intValue
            if (!librariesLoaded) { librariesRaw = a.rememberValue(librariesKey()); librariesLoaded = true }
            return librariesRaw?.let { raw ->
                runCatching { JSONArray(raw) }.getOrNull()?.let { j ->
                    (0 until j.length()).mapNotNull { i ->
                        val o = j.optJSONObject(i) ?: return@mapNotNull null
                        val id = o.optString("id").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                        StartLibraryItem(id, o.optString("name"), o.optBoolean("sammlung", false))
                    }
                }
            }?.distinctBy { it.id } ?: emptyList()
        }
        set(value) {
            val clean = value.filter { it.id.isNotEmpty() }.distinctBy { it.id }
            val raw = JSONArray(clean.map { org.json.JSONObject().put("id", it.id).put("name", it.name).put("sammlung", it.collection) }).toString()
            librariesRaw = raw; librariesLoaded = true
            a.remember(librariesKey(), raw)
            librariesState.intValue++
        }
    /** The stored choice as JSON for the core. */
    fun startLibrariesJson(): String = JSONArray(startLibraries.map {
        org.json.JSONObject().put("id", it.id).put("name", it.name).put("sammlung", it.collection) }).toString()
    /** Genres as chips above the rows instead of as rows of their own; never both. */
    var genreChips by RememberValue(a, "genreChips", bool("genreChips", false), yesNo)
    /** Title as logo on movie and series pages (`titleAsLogo`); off by default. */
    var titleAsLogo by RememberValue(a, "titelAlsLogo", bool("titelAlsLogo", false), yesNo)
    /** Off by default. */
    var downloadsAn by RememberValue(a, "downloadsAn", bool("downloadsAn", false), yesNo)
    /**
         * `Policy.EnableContentDownloading` of the current account, `"1"`/`"0"`/empty. Not stored;
         * fetched fresh at each start and account switch (`SwiftlyApplication.accountPreGiftFetch`).
         */
    var downloadRightAccount by mutableStateOf("")
    /**
         * Whether a download button appears: switch and account permission. Rule in the package
         * (`DownloadPermission.offer`), like `AppModel.downloadButtonShow` on iOS. The "Downloads" tab
         * and its settings row depend only on `downloadsAn`: what is stored on the phone must stay
         * reachable even without permission.
         */
    val downloadButtonShow: Boolean
        get() = Kern.downloadButtonShow(downloadRightAccount, downloadsAn)
    /**
         * `Policy.EnableVideoPlaybackTranscoding` of the current account, `"1"`/`"0"`/empty. Not
         * stored; fetched fresh at each start and account switch (`SwiftlyApplication.accountPreGiftFetch`).
         */
    var convertAllowedAccount by mutableStateOf("")
    /** Without a server answer: allowed, so the quality choice stays in the player. */
    val convertAllowed: Boolean
        get() = convertAllowedAccount != "0"
    /**
         * Whether a smaller quality can be chosen when downloading (image and audio permission),
         * decided in the package (`DownloadQuality.waehlbar`). `"1"`/`"0"`, allowed without an answer.
         */
    var downloadQualityAccount by mutableStateOf("")
    val downloadQualitySelectable: Boolean
        get() = downloadQualityAccount != "0"
    /** Original files are large, so wait on mobile data. */
    var onlyOverWLAN by RememberValue(a, "nurUeberWLAN", bool("nurUeberWLAN", true), yesNo)
    /**
         * Output decoded multichannel audio (AAC/FLAC 5.1, 7.1) unchanged. Off: libVLC downmixes it
         * to stereo (`--stereo-mode=1` in `PlayItem`). Off by default because some boxes (Mi Box S)
         * accept 6-channel PCM and then play silence, and nothing the device reports about its output
         * reveals which box does that (not measured: no such box at hand). Passthrough (AC3/DTS) is not
         * affected. Takes effect the next time the player opens.
         */
    var multiChannelAudio by RememberValue(a, "mehrkanalTon", bool("mehrkanalTon", false), yesNo)
    var bufferLevel by RememberValue(a, "pufferstufe", a.rememberValue("pufferstufe") ?: "normal") { it }
    /**
     * **Which engine plays** (`PlayerEngine`): `dolbyVision` is VLC, with Dolby Vision files on ExoPlayer
     * (default); `exoplayer` is everything on ExoPlayer; `vlc` is everything on VLC, Dolby Vision then as the
     * base layer. Takes effect the next time something opens. Media3 is used only if it can play
     * the picture and the default sound itself (`EngineChoice`); if it fails, VLC takes over.
     */
    var playerEngine by RememberValue(a, "playerEngine", a.rememberValue("playerEngine") ?: "dolbyVision") { it }
    var backSeconds by RememberValue(a, "zurueckSek", figure("zurueckSek", 10)) { it.toString() }
    var forwardSeconds by RememberValue(a, "vorSek", figure("vorSek", 30)) { it.toString() }
    /** Off until someone looks for it: it changes nothing about playback, it only shows what it does. */
    var techBadge by RememberValue(a, "technikschild", bool("technikschild", false), yesNo)
    /**
         * The measuring mode of the tech badge: all rows, no maximum height. Not a switch: a debugging
         * tool, not for viewers (mirrors `techBadgeMeasure`, a launch argument there). Set via the
         * start extra `techBadgeMeasure` (`adb shell am start ... --ez technikschildMessen true`).
         */
    var techBadgeMeasure by RememberValue(a, "technikschildMessen", bool("technikschildMessen", false), yesNo)
}

/** Reads a choice list from the facade: `[{"wert","text"}]`. */
fun selectionRead(json: String): List<Choice> = JSONArray(json).let { a ->
    (0 until a.length()).map { a.getJSONObject(it).let { o -> Choice(o.getString("wert"), o.getString("text")) } }
}

/** Whether tiles show their progress bar ("Fortschritt auf Kacheln"). */
val LocalProgressShow = compositionLocalOf { true }

/** Mirrors `LibraryFilter.offered(_:watchlist:)`: the filters a page offers, without the watchlist when it is off. */
fun offeredFilters(filters: List<String>, watchlist: Boolean): List<String> =
    if (watchlist) filters else filters - "merkliste"

// MARK: Subpage building blocks

/**
 * Mirrors `SubpageHeader`: back 44, title 22 semibold, so the arrow sits equally far from the
 * edge everywhere. `right` carries the count badge, `bottom` is 18 and 0 where a value row below
 * brings its own 14. `top = false` inside a `RootHeader` that already clears the status area.
 */
@Composable
fun SubpageHeader(title: String, back: () -> Unit, bottom: Dp = 18.dp, top: Boolean = true,
                    right: @Composable RowScope.() -> Unit = {}) {
    Row(Modifier.fillMaxWidth().then(if (top) Modifier.statusBarsPadding() else Modifier)
            .padding(start = 8.dp, end = 12.dp, bottom = bottom),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(44.dp).tapOn(back), contentAlignment = Alignment.Center) {
            Symbol(Glyph.AngleLeft, 20.dp, color = Theme.font, strength = Strength.Semibold, description = translated("Zurück"))
        }
        Text(title, style = Theme.subpageTitle,
             color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        right()
    }
}

/** A subpage: header, scrolling content below it down to the gesture bar. */
@Composable
fun SettingPage(title: String, back: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().background(Theme.reason)) {
        SubpageHeader(title, back)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 40.dp),
               content = content)
    }
}

/**
 * Mirrors `CardView`: the one allowed surface on settings pages, corner 14 (`cornerCard`) and fill
 * `groupsArea`.
 *
 * `area` (#262626) is for buttons: small objects that must stand out from the ground. A
 * settings card is the opposite, a large calm block, and the same tone looks much brighter on
 * it.
 */
@Composable
fun CardView(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing).clip(RoundedCornerShape(Theme.cornerCard))
               .background(Theme.groupsArea), content = content)
}

/**
 * Mirrors `Gruppentitel`: 20 semibold in normal case, `lockRail`, `schriftLeise`.
 *
 * The uppercase level still exists (`Theme.group`) but only for badges: an uppercase heading
 * reads like an alarm on a page of calm rows. 10 instead of 8 below, since a gap that suits an
 * 11 pt line sticks to a 20 pt one.
 */
@Composable
fun GroupsTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, style = Theme.rail,
         color = Theme.fontQuiet, modifier = modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing).padding(bottom = 10.dp))
}

/** Mirrors `Einstellungsgruppe`: group title, the card below it. */
@Composable
fun SettingGroup(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column {
        // 26 above, 10 + 2 below.
        GroupsTitle(title, Modifier.padding(top = 26.dp, bottom = 2.dp))
        CardView(content)
    }
}

/**
 * The line between a card's rows: `SheetLine`, full width from card edge to card edge. On
 * iPhone settings cards carry the full-width line because the rounded card itself is already the
 * group.
 */
@Composable
fun SeparatorLine() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))
}

/** Mirrors `Footer` under a group: 12 (`small`), very quiet. 13 Regular is not in the type scale. */
@Composable
fun Footer(text: String) {
    Text(text, style = Theme.small.copy(lineHeight = 17.sp), color = Theme.fontVeryQuiet,
         modifier = Modifier.padding(horizontal = Theme.edgeSpacing * 2).padding(top = 8.dp))
}

/**
 * Mirrors `Schalter`: custom instead of `Switch`, since the platform one brings its own
 * dimensions and motion and looks foreign next to flat surfaces. 46 x 28, the knob punches a
 * hole in the ground in the accent.
 */
@Composable
fun ToggleSwitch(an: Boolean, change: (Boolean) -> Unit) {
    val status by animateFloatAsState(if (an) 1f else 0f, tween(150, easing = EaseInOut), label = "schalter")
    // Off: surface `rand` (white 12 %), on: `accent`, knob `reason`.
    Box(Modifier.size(46.dp, 28.dp).clip(CircleShape).background(lerp(Theme.margin, Theme.accent, status))
            // For TalkBack a switch with state, not a nameless surface.
            .toggleable(an, remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, null,
                role = androidx.compose.ui.semantics.Role.Switch) { change(it) }.padding(3.dp)) {
        Box(Modifier.offset(x = 18.dp * status).size(22.dp).clip(CircleShape).background(lerp(Color.White, Theme.reason, status)))
    }
}

/**
 * Mirrors `RowsLayout`: icon 17 in a 20-wide column, title 15 semibold, subtitle 12
 * `schriftSehrLeise`, 14 spacing, 14 vertical.
 *
 * Title 16 and subtitle 13 are on no scale. White at 45 % for the subtitle is replaced by the
 * full value `schriftSehrLeise`, which does not tip over a poster and measures 5.78:1 on the
 * group surface.
 */
@Composable
fun RowsLayout(symbol: Glyph, title: String, under: String?, color: Color, modifier: Modifier,
                         verticalRight: Int = 14, drawColor: Color = Theme.font, right: @Composable RowScope.() -> Unit) {
    Row(modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing, vertical = verticalRight.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        // The icon stays white even when the title is dimmed, like `RowsLayout` on iPhone.
        Box(Modifier.width(Theme.characterColumn), contentAlignment = Alignment.Center) { Symbol(symbol, 17.dp, color = drawColor) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Theme.listTitle, color = color)
            under?.let { Text(it, style = Theme.small, color = Theme.fontVeryQuiet) }
        }
        right()
    }
}

/**
 * The chevron on the right of a row: `schriftSehrLeise`, as on Apple.
 *
 * White at 28 % measures 2.47:1, which fails even for a control glyph (3:1). Size stays 20:
 * Apple's chevron is a 13 pt glyph, while Material's `KeyboardArrowRight` includes its own
 * padding and at 20 dp draws a mark of the same height.
 */
@Composable
private fun Arrow() {
    Symbol(Glyph.AngleRight, 13.dp, color = Theme.fontVeryQuiet, strength = Strength.Semibold)
}

/**
 * Mirrors `ChoiceRow`: toggles something; the whole row takes the tap. `locked`: the server
 * decides, not the switch, like "Immer Direct Play" when the server does not transcode.
 */
@Composable
fun ChoiceRow(symbol: Glyph, title: String, under: String? = null, an: Boolean, locked: Boolean = false, change: (Boolean) -> Unit) {
    // Locked means dimmed text, not transparent: white at 40 % over our ground gives a strong gray,
        // which looks like a button that does not respond rather than one that is still waiting.
    val color = if (locked) Theme.fontVeryQuiet else Theme.font
    RowsLayout(symbol, title, under, color, if (locked) Modifier else Modifier.pressRow { change(!an) }) {
        ToggleSwitch(an, if (locked) { _: Boolean -> } else change)
    }
}

/** Mirrors `ValueRow`: shows a value and, if tappable, leads to its picker. Dimmed when it does not apply. */
@Composable
fun ValueRow(symbol: Glyph, title: String, under: String? = null, value: String? = null, dimmedDown: Boolean = false, perform: (() -> Unit)? = null) {
    val color = if (dimmedDown) Theme.fontVeryQuiet else Theme.font
    // A button gives way (`Theme.PressButton`); dimmed it is none and carries no chevron.
    val active = perform != null && !dimmedDown
    RowsLayout(symbol, title, under, color, if (active) Modifier.tapOn(perform!!) else Modifier) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            value?.let { Text(it, style = Theme.body, color = Theme.fontQuiet, maxLines = 1) }
            if (active) Arrow()
        }
    }
}

/**
 * Mirrors `ProfileRow`: leads elsewhere, 14 vertical like every list row. `characterAccent`: only
 * the icon in accent, the title stays white (Quick Connect); a profile page without a colored
 * dot reads lifeless.
 */
@Composable
fun ProfileRow(symbol: Glyph, title: String, under: String? = null, characterAccent: Boolean = false, perform: () -> Unit) {
    RowsLayout(symbol, title, under, Theme.font, Modifier.tapOn(perform),
                 drawColor = if (characterAccent) Theme.accent else Theme.font) { Arrow() }
}

/**
 * Reorder with a handle on the right, the counterpart of the list in edit mode on iOS. The row
 * follows the finger; when it crosses half the height of its neighbor, the two swap.
 */
@Composable
fun <T> SortBar(entries: List<T>, key: (T) -> String, move: (T, Int) -> Unit,
                     row: @Composable (T) -> Unit) {
    val current by rememberUpdatedState(entries)
    var dragged by remember { mutableStateOf<String?>(null) }
    var pull by remember { mutableFloatStateOf(0f) }
    val jerk = rememberJerk()
    val run = rememberCoroutineScope()
    Column {
        entries.forEachIndexed { i, entryRecord ->
            val identifier = key(entryRecord)
            if (i > 0) SeparatorLine()
            key(identifier) {
                var height by remember { mutableIntStateOf(1) }
                // A row that swaps places without being dragged glides to the new one: the swap is the
                                // feedback of this gesture, and a jump would look like a bug.
                val offset = remember { Animatable(0f) }
                var before by remember { mutableIntStateOf(i) }
                LaunchedEffect(i) {
                    if (i != before && dragged != identifier) {
                        offset.snapTo((before - i) * height.toFloat())
                        before = i
                        offset.animateTo(0f, tween(150, easing = Motion.soft))
                    } else before = i
                }
                Row(Modifier.fillMaxWidth().onSizeChanged { height = it.height }
                        .zIndex(if (dragged == identifier) 1f else 0f)
                        .graphicsLayer { translationY = if (dragged == identifier) pull else offset.value }
                        .background(if (dragged == identifier) Theme.raised else Color.Transparent),
                    verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) { row(entryRecord) }
                    Box(Modifier.size(44.dp).padding(end = 6.dp)
                            .pointerInput(identifier) {
                                fun release() {
                                    val rest = pull
                                    dragged = null
                                    pull = 0f
                                    // Releasing also glides into place instead of jumping.
                                    run.launch { offset.snapTo(rest); offset.animateTo(0f, tween(150, easing = Motion.soft)) }
                                }
                                detectVerticalDragGestures(
                                    onDragStart = { dragged = identifier; pull = 0f },
                                    onDragEnd = { release() },
                                    onDragCancel = { release() },
                                    onVerticalDrag = { change, d ->
                                        change.consume()
                                        pull += d
                                        val list = current
                                        val spot = list.indexOfFirst { key(it) == identifier }
                                        if (pull > height / 2f && spot in 0 until list.lastIndex) {
                                            move(list[spot], 1); pull -= height; jerk(Jerk.Lightweight)
                                        } else if (pull < -height / 2f && spot > 0) {
                                            move(list[spot], -1); pull += height; jerk(Jerk.Lightweight)
                                        }
                                    })
                            },
                        contentAlignment = Alignment.Center) {
                        Symbol(Glyph.Handle, 17.dp, color = Theme.fontVeryQuiet)
                    }
                }
            }
        }
    }
}
