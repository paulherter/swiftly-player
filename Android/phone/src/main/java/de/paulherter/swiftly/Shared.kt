package de.paulherter.swiftly

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.Texts
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.Locale

// Watch together. Mirrors `SharedModel` (Sources/Shared) and `Gemeinsamansichten`
// (Sources/iOS). The flow lives in the package (`SyncPlaySession`), the bridge in the core
// (`Kern.syncPlay...`, `Shared.swift`). This file only holds what is shown and tapped.

data class SharedGroup(val id: String, val name: String, val participant: List<String>,
                           val names: List<String>, val condition: String?)

data class SharedEvent(val id: String, val art: String, val text: String)

/** Mirror of `SyncPlayStatus`; arrives ready-made from the core (`SharedResponse`). */
data class SharedStatus(
    val mayCreate: Boolean = true,
    val mayJoin: Boolean = true,
    /** Groups on the server that the user is not in. */
    val offerings: List<SharedGroup> = emptyList(),
    /** The group the user is in. */
    val group: SharedGroup? = null,
    /** Everyone else in the group, once each. */
    val other: List<String> = emptyList(),
    val event: SharedEvent? = null,
    /** For the "Filmabend verlassen · Wieder beitreten" strip. */
    val lastLeave: String? = null,
    val works: Boolean = false,
    val queueTitle: String? = null,
    val error: String? = null,
    val errorNumber: Int = 0,
    val accepted: Int = 0,
) {
    /** "mit Anna und Ben", without the user. */
    val withWhom: String get() = if (other.isEmpty()) translated("noch niemand dabei") else translated("mit %@", namesList(other))

    /** What the badge counts: open groups, while the user is in none and may join. */
    val openGroups: List<SharedGroup> get() = if (group == null && mayJoin) offerings else emptyList()
}

private fun groupRead(o: JSONObject) = SharedGroup(o.getString("id"), o.optString("name"), o.fieldTexts("teilnehmer"),
                                                         o.fieldTexts("namen"), o.fieldText("zustand"))

internal fun sharedStatusRead(o: JSONObject) = SharedStatus(
    mayCreate = o.optBoolean("darfAnlegen", true),
    mayJoin = o.optBoolean("darfBeitreten", true),
    offerings = o.fieldList("angebote", ::groupRead),
    group = o.optJSONObject("gruppe")?.let(::groupRead),
    other = o.fieldTexts("andere"),
    event = o.optJSONObject("ereignis")?.let { SharedEvent(it.getString("id"), it.getString("art"), it.getString("text")) },
    lastLeave = o.fieldText("zuletztVerlassen"),
    works = o.optBoolean("arbeitet"),
    queueTitle = o.fieldText("schlangeTitel"),
    error = o.fieldText("fehler"),
    errorNumber = o.optInt("fehlerNummer"),
    accepted = o.optInt("angenommen"),
)

/** "Anna und Ben", "Anna, Ben und Eva": `ListFormatter` as on Apple, in the text language. */
internal fun namesList(names: List<String>): String =
    android.icu.text.ListFormatter.getInstance(Locale.forLanguageTag(Texts.language)).format(names)

/** "Anna und Ben schauen gerade" (`SharedSheets.wer`). */
internal fun werWatch(g: SharedGroup): String = when {
    g.names.isEmpty() -> translated("Noch niemand dabei")
    g.names.size == 1 -> translated("%@ schaut gerade", namesList(g.names))
    else -> translated("%@ schauen gerade", namesList(g.names))
}

internal fun stateTextOf(z: String?): String? = when (z) {
    "laeuft" -> translated("Läuft gerade")
    "angehalten" -> translated("Angehalten")
    "wartet" -> translated("Wartet auf alle")
    else -> null
}

/** The icon per event (`SharedModel.zeichen`). */
internal fun eventCharacter(art: String): Glyph = when (art) {
    "dabei" -> Glyph.ClusterFilled
    "gegangen" -> Glyph.Cluster
    "wartet" -> Glyph.Hourglass
    "angehalten" -> Glyph.Pause
    "weiter" -> Glyph.Play
    "gesprungen" -> Glyph.JumpArrows
    else -> Glyph.Warning
}

/**
 * Once at app start: mirror the state from the core, report errors, and open the player when the
 * group sets a title and none is open (`SharedModel.titleLoad`, `wish` in `MainView`).
 * Both wait in the core until something changes, so there is no polling.
 */
fun SwiftlyApplication.sharedListen(run: kotlinx.coroutines.CoroutineScope) {
    run.launch {
        var state = 0L
        var errorWatched = 0
        while (true) {
            val raw = runCatching { withContext(Dispatchers.IO) { kern.syncPlayStatus(state).await() } }.getOrNull()
            if (raw == null) { kotlinx.coroutines.delay(1000); continue }
            val o = JSONObject(raw)
            state = o.optLong("stand", state)
            val new = sharedStatusRead(o.getJSONObject("lage"))
            gemeinsam.value = new
            if (new.errorNumber != errorWatched) {
                errorWatched = new.errorNumber
                // As a banner: the player's hint while playing, otherwise above the main view.
                new.error?.let { sharedError.value = it }
            }
        }
    }
    run.launch {
        while (true) {
            val raw = runCatching { withContext(Dispatchers.IO) { kern.syncPlayRequest().await() } }.getOrNull()
            if (raw.isNullOrEmpty()) { kotlinx.coroutines.delay(500); continue }
            val o = JSONObject(raw)
            play.value = PlayRequest(o.getString("titel"), o.optDouble("ab", 0.0))
        }
    }
}

// MARK: Sheets

/** How long a sheet needs to slide out before the next one appears (More -> "Gemeinsam schauen"). */
internal const val SheetSwitch = 300L

/**
 * "Series · Season 2 · Episode 3" for an episode, otherwise the name; without it the sheet does
 * not say which episode the group will watch (`SharedSheets.titleLine`).
 */
internal fun sharedTitleRow(name: String, series: String?, season: Int?, episode: Int?): String = when {
    series.isNullOrEmpty() -> name
    season != null && episode != null -> "$series · " + translated("Staffel %lld · Folge %lld", season, episode)
    else -> "$series · $name"
}

/**
 * Mirrors the "Gemeinsam schauen" sheet in `SharedSheets`: title row, "Name der Gruppe"
 * prefilled with "Filmabend", the sentence below, "Gruppe öffnen". The sheet closes as soon as
 * the server has accepted (`accepted`), not after waiting for the control channel.
 */
fun sharedCreateOpen(app: SwiftlyApplication, titleIdentifier: String, titleLine: String) {
    app.sheet.value = SheetRequest(translated("Gemeinsam schauen"), emptyList(), null, content = { close ->
        val status = app.gemeinsam.value
        var name by remember { mutableStateOf(translated("Filmabend")) }
        val onOpen = remember { status.accepted }
        val run = androidx.compose.runtime.rememberCoroutineScope()
        val focus = LocalFocusManager.current
        LaunchedEffect(status.accepted) { if (status.accepted != onOpen) close() }
        fun open() {
            focus.clearFocus()
            run.launch {
                if (withContext(Dispatchers.IO) { app.kern.syncPlayCreate(name, titleIdentifier).await() }) close()
            }
        }
        Column(Modifier.padding(horizontal = Theme.edgeSpacing).padding(bottom = 12.dp)) {
            Text(titleLine, style = Theme.body, color = Theme.fontQuiet, modifier = Modifier.padding(bottom = 16.dp))
            Text(translated("Name der Gruppe"), style = Theme.small, color = Theme.fontVeryQuiet, modifier = Modifier.padding(bottom = 6.dp))
            Box(Modifier.fillMaxWidth().heightIn(min = 44.dp).background(Theme.raised, RoundedCornerShape(Theme.cornerField))
                    .padding(horizontal = 14.dp), contentAlignment = Alignment.CenterStart) {
                if (name.isEmpty()) Text(translated("Filmabend"), style = Theme.body.copy(fontSize = 17.sp), color = Theme.fontVeryQuiet)
                BasicTextField(name, { name = it }, singleLine = true,
                    textStyle = Theme.body.copy(fontSize = 17.sp, color = Theme.font),
                    cursorBrush = SolidColor(Theme.accent),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { focus.clearFocus() }),
                    modifier = Modifier.fillMaxWidth())
            }
            Text(translated("Alle auf deinem Server sehen die Gruppe und können mit einsteigen. Pause und Springen gelten dann für alle."),
                 style = Theme.body, color = Theme.fontQuiet, modifier = Modifier.padding(top = 14.dp, bottom = 18.dp))
            PrimaryButton(translated("Gruppe öffnen"), released = !status.works, lockedArea = Theme.raised) { open() }
        }
        SheetLine()
        SheetCancel(close)
    }) { }
}

/** Mirrors the "Beitreten" sheet: group name as heading, who is watching, the state in accent. */
fun sharedJoinOpen(app: SwiftlyApplication, g: SharedGroup) {
    app.sheet.value = SheetRequest(g.name, emptyList(), null, content = { close ->
        val status = app.gemeinsam.value
        val onOpen = remember { status.accepted }
        val run = androidx.compose.runtime.rememberCoroutineScope()
        LaunchedEffect(status.accepted) { if (status.accepted != onOpen) close() }
        Column(Modifier.padding(horizontal = Theme.edgeSpacing).padding(bottom = 12.dp)) {
            Text(werWatch(g), style = Theme.body, color = Theme.fontQuiet)
            stateTextOf(g.condition)?.let { Text(it, style = Theme.small, color = Theme.accent, modifier = Modifier.padding(top = 6.dp)) }
            Text(translated("Pause und Springen gelten für alle."), style = Theme.small, color = Theme.fontVeryQuiet,
                 modifier = Modifier.padding(top = 10.dp, bottom = 18.dp))
            PrimaryButton(translated("Beitreten"), released = !status.works, lockedArea = Theme.raised) {
                run.launch { if (withContext(Dispatchers.IO) { app.kern.syncPlayJoin(g.id).await() }) close() }
            }
        }
        SheetLine()
        SheetCancel(close)
    }) { }
}

/**
 * Mirrors the "Läuft gerade" picker: what plays on other devices first ("Hier weiterschauen"),
 * then the groups ("Beitreten"). Icon 17 in accent, title and subtitle, the action on the right.
 */
fun sharedSelectionOpen(app: SwiftlyApplication, continueWatching: (Offering) -> Unit) {
    app.sheet.value = SheetRequest(translated("Läuft gerade"), emptyList(), null, content = { close ->
        val run = androidx.compose.runtime.rememberCoroutineScope()
        app.offerings.value.forEach { a ->
            SheetLine()
            SelectionRow(takeoverIcon(a.art), a.device ?: translated("Gerät"), a.titleLine, translated("Hier weiterschauen")) {
                close(); continueWatching(a)
            }
        }
        app.gemeinsam.value.openGroups.forEach { g ->
            SheetLine()
            SelectionRow(Glyph.ClusterFilled, g.name, werWatch(g), translated("Beitreten")) {
                run.launch { if (withContext(Dispatchers.IO) { app.kern.syncPlayJoin(g.id).await() }) close() }
            }
        }
        SheetLine()
        SheetCancel(close)
    }) { }
}

@Composable
private fun SelectionRow(symbol: Glyph, title: String, under: String, action: String, perform: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 58.dp).pressRow(perform).padding(horizontal = Theme.edgeSpacing),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(Modifier.width(26.dp), contentAlignment = Alignment.Center) { Symbol(symbol, 17.dp, color = Theme.accent) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(title, style = Theme.listTitle, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(under, style = Theme.small, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(action, style = Theme.listTitle, color = Theme.accent)
    }
}

/**
 * Mirrors `ReturnPathStrip`: "Filmabend verlassen · Wieder beitreten", undo instead of a
 * confirmation. Capsule in `area`, 34 above the bottom edge and 24 from the side, like every
 * hint. Shown for eight seconds, which the package enforces.
 */
@Composable
fun ReturnPathStrip(app: SwiftlyApplication, bottom: androidx.compose.ui.unit.Dp = 34.dp) {
    val name = app.gemeinsam.value.lastLeave
    val remembered = remember { arrayOfNulls<String>(1) }
    if (name != null) remembered[0] = name
    val run = androidx.compose.runtime.rememberCoroutineScope()
    Box(Modifier.fillMaxSize().navigationBarsPadding(), contentAlignment = Alignment.BottomCenter) {
        AnimatedVisibility(name != null, enter = fadeIn(tween(220)), exit = fadeOut(tween(220))) {
            Row(Modifier.padding(bottom = bottom, start = 24.dp, end = 24.dp)
                    .background(Theme.area, RoundedCornerShape(50)).padding(start = 18.dp, end = 12.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(translated("%@ verlassen", remembered[0].orEmpty()), style = Theme.body.copy(fontSize = 13.sp),
                     color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                Box(Modifier.heightIn(min = 44.dp).tapOn { run.launch { withContext(Dispatchers.IO) { app.kern.syncPlayAgainJoin().await() } } },
                    contentAlignment = Alignment.Center) {
                    Text(translated("Wieder beitreten"), style = Theme.body.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold),
                         color = Theme.accent)
                }
            }
        }
    }
}

// MARK: In the player

/**
 * Mirrors `GroupsRow`: "Filmabend · mit Anna und Ben" under the title, where year and runtime
 * normally are. The name uses the accent because being in a group is a state.
 */
@Composable
fun GroupsRow(name: String, withWhom: String, size: androidx.compose.ui.unit.TextUnit, color: androidx.compose.ui.graphics.Color = Theme.fontQuiet) {
    Row(Modifier.semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Symbol(Glyph.ClusterFilled, (size.value + 1).dp, color = Theme.accent)
        Text(name, style = Theme.body.copy(fontSize = size, fontWeight = FontWeight.SemiBold), color = Theme.accent, maxLines = 1)
        Text("· $withWhom", style = Theme.body.copy(fontSize = size), color = color, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Mirrors `GroupsEvent`: briefly at the top of the picture, who joined, who left, why the film stopped. */
@Composable
fun GroupsEvent(e: SharedEvent, modifier: Modifier = Modifier, style: androidx.compose.ui.text.TextStyle = Theme.body,
                    symbolText: androidx.compose.ui.unit.Dp = 15.dp, height: androidx.compose.ui.unit.Dp = 44.dp) {
    Row(modifier.heightIn(min = height).background(Theme.area, RoundedCornerShape(50)).padding(horizontal = 16.dp)
            .semantics(mergeDescendants = true) { contentDescription = e.text },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Symbol(eventCharacter(e.art), symbolText, color = Theme.accent)
        Text(e.text, style = style, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** The device icon of a handover offer, same as in the badge. */
internal fun takeoverIcon(art: String): Glyph = when (art) {
    "telefon" -> Glyph.Phone
    "tablet" -> Glyph.Tablet
    "rechner" -> Glyph.Laptop
    "fernseher" -> Glyph.Tv
    else -> Glyph.PlayTv
}

