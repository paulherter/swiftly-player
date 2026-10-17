package de.paulherter.swiftly.tv

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.Offering
import de.paulherter.swiftly.SheetRequest
import de.paulherter.swiftly.SharedGroup
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.Choice
import de.paulherter.swiftly.takeoverIcon
import de.paulherter.swiftly.werWatch
import de.paulherter.swiftly.stateTextOf
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// Watch together on TV. Behavior as on iOS (`Gemeinsamansichten`), controls as in the other
// panels: the sheets are `TvPanel`s on the right edge, and what the phone sheet shows as text
// is a paragraph under the heading (`SheetRequest.subline`).
//
// No name field: nobody types a name with a remote, so the group is called "Filmabend" like the
// phone default (empty -> package default).

/** The panels outlive the page that opens them, and so do their callbacks. */
private val panelRun = MainScope()

/** Mirrors the "Gemeinsam schauen" sheet: title row and its sentence, then "Gruppe öffnen". */
fun tvCreateOpen(app: SwiftlyApplication, titleIdentifier: String, titleLine: String) {
    app.sheet.value = SheetRequest(translated("Gemeinsam schauen"), listOf(Choice("oeffnen", translated("Gruppe öffnen"))), null,
        mapOf("oeffnen" to Glyph.ClusterFilled),
        subline = titleLine + "\n\n" +
            translated("Alle auf deinem Server sehen die Gruppe und können mit einsteigen. Pause und Springen gelten dann für alle.")) {
        panelRun.launch { withContext(Dispatchers.IO) { app.kern.syncPlayCreate("", titleIdentifier).await() } }
    }
}

/** Mirrors the "Beitreten" sheet: group name, who is watching, the state, what applies. */
fun tvJoinOpen(app: SwiftlyApplication, g: SharedGroup) {
    val rows = listOfNotNull(werWatch(g), stateTextOf(g.condition), translated("Pause und Springen gelten für alle."))
    app.sheet.value = SheetRequest(g.name, listOf(Choice("beitreten", translated("Beitreten"))), null,
        mapOf("beitreten" to Glyph.ClusterFilled), subline = rows.joinToString("\n")) {
        panelRun.launch { withContext(Dispatchers.IO) { app.kern.syncPlayJoin(g.id).await() } }
    }
}

/** Mirrors the "Läuft gerade" picker: other devices first, then the groups. */
fun tvSelectionOpen(app: SwiftlyApplication, continueWatching: (Offering) -> Unit) {
    val offerings = app.offerings.value
    val groups = app.gemeinsam.value.openGroups
    val entries = offerings.map { Choice("u:" + it.session, listOf(it.device ?: translated("Gerät"), it.titleLine).joinToString(" · ")) } +
        groups.map { Choice("g:" + it.id, it.name + " · " + werWatch(it)) }
    val icons = offerings.associate { "u:" + it.session to takeoverIcon(it.art) } + groups.associate { "g:" + it.id to Glyph.ClusterFilled }
    app.sheet.value = SheetRequest(translated("Läuft gerade"), entries, null, icons) { value ->
        when {
            value.startsWith("u:") -> offerings.firstOrNull { it.session == value.drop(2) }?.let(continueWatching)
            value.startsWith("g:") -> groups.firstOrNull { it.id == value.drop(2) }?.let { g ->
                panelRun.launch { withContext(Dispatchers.IO) { app.kern.syncPlayJoin(g.id).await() } }
            }
        }
    }
}

/**
 * Mirrors `ReturnPathStrip`: "Filmabend verlassen · Wieder beitreten", shown for eight seconds.
 *
 * Takes focus on TV: the strip appears after the player closes, exactly when focus has just
 * returned to the trigger. It takes focus (OK rejoins) and hands it back to the trigger when it
 * disappears (`FocusRemember.postPlayer`). Without focus the button could not be reached with a
 * remote.
 */
@Composable
fun TvReturnPathStrip(app: SwiftlyApplication) {
    val name = app.gemeinsam.value.lastLeave
    val remembered = remember { arrayOfNulls<String>(1) }
    if (name != null) remembered[0] = name
    val button = remember { FocusRequester() }
    var hasFocus by remember { mutableStateOf(false) }
    val run = rememberCoroutineScope()
    LaunchedEffect(name != null) {
        if (name != null) {
            // After `FocusRemember.playerTo`, otherwise that would grab focus again right away.
            delay(TvTheme.focusDeadline * 3)
            repeat(4) { if (runCatching { button.requestFocus() }.isSuccess) return@LaunchedEffect; delay(TvTheme.focusDeadline) }
        } else if (hasFocus) {
            FocusRemember.postPlayer?.let { runCatching { it.requestFocus() } }
        }
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        AnimatedVisibility(name != null, enter = fadeIn(tween(220)), exit = fadeOut(tween(220))) {
            Row(Modifier.padding(bottom = TvTheme.edgeTop).clip(RoundedCornerShape(50)).background(Theme.area)
                    .padding(start = 22.dp, end = 8.dp, top = 6.dp, bottom = 6.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(translated("%@ verlassen", remembered[0].orEmpty()), style = TvTheme.body, color = Theme.font,
                     maxLines = 1, overflow = TextOverflow.Ellipsis)
                FocusArea(Modifier.focusRequester(button).onFocusChanged { hasFocus = it.hasFocus }, magnifier = TvTheme.focusMagnifierSmall,
                    perform = { run.launch { withContext(Dispatchers.IO) { app.kern.syncPlayAgainJoin().await() } } }) { focus ->
                    Text(translated("Wieder beitreten"), style = TvTheme.button, color = if (focus) Theme.reason else Theme.accent,
                         modifier = Modifier.clip(RoundedCornerShape(50)).background(if (focus) Color.White else Color.Transparent)
                             .padding(horizontal = 14.dp, vertical = 6.dp))
                }
            }
        }
    }
}
