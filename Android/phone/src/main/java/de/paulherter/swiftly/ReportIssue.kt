package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.rustcore.ReportIssueFlow
import de.paulherter.swiftly.rustcore.ReportIssueInfo
import de.paulherter.swiftly.rustcore.ReportIssuePhase
import de.paulherter.swiftly.rustcore.SeerrAdminScreen
import de.paulherter.swiftly.rustcore.SeerrMenuKind
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Texts
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.smoothRoundedShape
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * **"Problem melden"** (iPhone `ReportIssueSheet`): the four kinds, a few words, send. The state machine, the words
 * and the rules (a report needs words, one send, a refusal in Seerr's own words) are the core's `ReportIssueFlow`;
 * this only draws `info()` and forwards the taps. The same sheet opens from the player (with the position) and from
 * the Mehr menu of a title.
 */
private const val REPORT_ENTRY = "problem-melden"

/** The Seerr entry of a title's Mehr menu ("Problem melden", in the core's words), or none without a Seerr connection / the right. */
internal suspend fun seerrReportEntry(app: SwiftlyApplication): String? = withContext(Dispatchers.IO) {
    try {
        app.seerr.hub().titleMenu().firstOrNull { it.kind == SeerrMenuKind.REPORT_PROBLEM }?.text
    } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
}

internal const val MORE_REPORT = REPORT_ENTRY

/** Opens the report sheet for a library item; `false` when the title has no TMDB id (nothing opens). */
internal suspend fun reportIssueOpen(app: SwiftlyApplication, itemId: String, seconds: Double?): Boolean {
    val account = app.rk.account() ?: return false
    val flow = withContext(Dispatchers.IO) {
        try {
            val flow = SeerrAdminScreen(app.seerr.hub()).reportFlow()
            if (app.rk.core().reportStartItem(flow, account, Texts.language, itemId, seconds)) flow else null
        } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
    } ?: return false
    app.sheet.value = SheetRequest(flow.info().heading, emptyList(), null, heading = false, scrollContent = false, content = { close -> ReportIssueContent(flow, close) }) {}
    return true
}

@Composable
private fun ColumnScope.ReportIssueContent(flow: ReportIssueFlow, close: () -> Unit) {
    val run = rememberCoroutineScope()
    var info by remember { mutableStateOf(flow.info()) }
    DisposableEffect(flow) { onDispose { flow.dismiss() } }
    fun refresh() { info = flow.info() }
    // With the keyboard up (landscape in the player leaves about 160 dp above it) the card keeps only what must stay in
    // reach: the scroll area above, the send row pinned below it. The cancel row goes; Back closes the keyboard.
    val keyboardUp = WindowInsets.ime.getBottom(LocalDensity.current) > 0

    // Everything that can scroll away: heading, title, the four kinds, the field, an error line.
    Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState())) {
        androidx.compose.material3.Text(info.heading, style = Theme.categoryLarge, color = Theme.font, maxLines = 1,
            modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 5.dp, bottom = 14.dp))
        Column(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing).padding(bottom = 10.dp)) {
            Text1(info.title, semibold = true)
            info.line?.let { Text1(it, quiet = true) }
        }
        if (info.phase is ReportIssuePhase.Sent) {
            Row(Modifier.fillMaxWidth().heightIn(min = Theme.rowHeight).padding(horizontal = Theme.edgeSpacing)
                    .semantics { contentDescription = "report-sent" },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Symbol(Glyph.CheckmarkCircle, 18.dp, color = Theme.accent)
                androidx.compose.material3.Text(info.sentText, style = Theme.body, color = Theme.font)
            }
        } else {
            info.kinds.forEachIndexed { i, k ->
                Row(Modifier.fillMaxWidth().heightIn(min = 46.dp).pressRow { flow.setKind(k.kind); refresh() }
                        .padding(horizontal = Theme.edgeSpacing).semantics { contentDescription = "report-kind-$i" },
                    verticalAlignment = Alignment.CenterVertically) {
                    androidx.compose.material3.Text(k.text, style = Theme.body, color = Theme.font, modifier = Modifier.weight(1f))
                    if (k.selected) Symbol(Glyph.Checkmark, 14.dp, color = Theme.accent, strength = Strength.Semibold)
                }
            }
            Box(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing, vertical = 10.dp).clip(smoothRoundedShape(Theme.cornerField))
                    .background(Theme.area).padding(horizontal = 14.dp, vertical = 11.dp)) {
                if (info.message.isEmpty()) androidx.compose.material3.Text(info.placeholder, style = Theme.body, color = Theme.fontVeryQuiet)
                BasicTextField(info.message, { flow.setMessage(it); refresh() }, textStyle = Theme.body.copy(color = Theme.font),
                    cursorBrush = SolidColor(Theme.font), keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    modifier = Modifier.fillMaxWidth().semantics { contentDescription = "report-message" })
            }
            (info.phase as? ReportIssuePhase.Failed)?.let {
                androidx.compose.material3.Text(it.text, style = Theme.small, color = Theme.warning,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing).padding(bottom = 10.dp).semantics { contentDescription = "report-error" })
            }
        }
    }
    // Pinned below the scroll area: the send row (or "Done" once sent) never scrolls out of reach.
    SheetLine()
    if (info.phase is ReportIssuePhase.Sent) {
        Box(Modifier.fillMaxWidth().heightIn(min = Theme.rowHeight).pressRow(close), contentAlignment = Alignment.Center) {
            androidx.compose.material3.Text(info.doneText, style = Theme.buttonText, color = Theme.accent)
        }
        return
    }
    Box(Modifier.fillMaxWidth().heightIn(min = Theme.rowHeight)
            .then(if (info.canSend) Modifier.pressRow {
                run.launch {
                    val sent = async(Dispatchers.IO) { runCatching { flow.send() } }
                    delay(40); refresh()
                    sent.await(); refresh()
                }
            } else Modifier).semantics { contentDescription = "report-send" },
        contentAlignment = Alignment.Center) {
        androidx.compose.material3.Text(info.sendLabel, style = Theme.buttonText, color = if (info.canSend) Theme.accent else Theme.fontVeryQuiet)
    }
    if (!keyboardUp) {
        SheetLine()
        Box(Modifier.fillMaxWidth().heightIn(min = Theme.rowHeight).pressRow(close), contentAlignment = Alignment.Center) {
            androidx.compose.material3.Text(info.cancelText, style = Theme.buttonText, color = Theme.font)
        }
    }
}

@Composable
private fun Text1(text: String, semibold: Boolean = false, quiet: Boolean = false) =
    androidx.compose.material3.Text(text, style = if (quiet) Theme.small else Theme.body.copy(fontWeight = if (semibold) FontWeight.SemiBold else FontWeight.Normal),
        color = if (quiet) Theme.fontQuiet else Theme.font, maxLines = 1)
