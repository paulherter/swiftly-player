package de.paulherter.swiftly

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.rustcore.DeletePhase
import de.paulherter.swiftly.rustcore.SeerrAdminScreen
import de.paulherter.swiftly.rustcore.SeerrDeleteInfo
import de.paulherter.swiftly.rustcore.SeerrMenuKind
import de.paulherter.swiftly.rustcore.StepState
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Texts
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * **"Vom Server löschen"** (iPhone `DeleteFlowSheet`): confirm with one row per version, then the core's steps with
 * their state, "Nochmal versuchen" resumes at the failed step. The state machine, the ticks, the steps and the words
 * are the core's (`SeerrAdminScreen.deleteInfo()` / `deleteToggle` / `deleteRunChosen` / `deleteRetry`); this only draws
 * `info` and forwards the taps. Only admins and only with "Löschen vom Server sperren" off get the entry (core rule).
 */
internal const val MORE_DELETE = "vom-server-loeschen"

/** The delete entry of a title's Mehr menu in the core's words, or none (no Seerr, no right, device lock on). */
internal suspend fun seerrDeleteEntry(app: SwiftlyApplication): String? = withContext(Dispatchers.IO) {
    try {
        app.seerr.hub().titleMenu().firstOrNull { it.kind == SeerrMenuKind.DELETE_FROM_SERVER }?.text
    } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
}

/** Opens the delete sheet for a library item; `false` when the core offers nothing (no TMDB id, Seerr does not know it). [finished]: the title is gone, the page goes back. */
internal suspend fun deleteFlowOpen(app: SwiftlyApplication, itemId: String, finished: () -> Unit): Boolean {
    val account = app.rk.account() ?: return false
    val (screen, info) = withContext(Dispatchers.IO) {
        try {
            val screen = SeerrAdminScreen(app.seerr.hub())
            screen to app.rk.core().deletePrepareItem(screen, account, Texts.language, itemId)
        } catch (e: CancellationException) { throw e } catch (_: Exception) { null to null }
    }
    if (screen == null || info == null) return false
    app.sheet.value = SheetRequest(translated("Vom Server löschen"), emptyList(), null, content = { close -> DeleteContent(screen, info, close, finished) }) {}
    return true
}

@Composable
private fun ColumnScope.DeleteContent(screen: SeerrAdminScreen, first: SeerrDeleteInfo, close: () -> Unit, finished: () -> Unit) {
    val run = rememberCoroutineScope()
    var info by remember { mutableStateOf(first) }
    // The page behind goes back once the title is gone, however the sheet was closed (button, scrim, back).
    DisposableEffect(screen) { onDispose { if (screen.deleteInfo().phase == DeletePhase.DONE) finished() } }

    /** Runs a core step call while the steps are read again every moment, so each shows when it starts and when it is done. */
    fun follow(call: suspend () -> SeerrDeleteInfo) {
        run.launch {
            // Not a child of the sheet: closing it must not abort a delete half way.
            val work = CoroutineScope(Dispatchers.IO).async { runCatching { call() }.getOrNull() }
            while (work.isActive) { info = screen.deleteInfo(); delay(120) }
            info = work.await() ?: screen.deleteInfo()
        }
    }

    if (info.phase == DeletePhase.CONFIRM) {
        DeleteText(info.title, semibold = true)
        androidx.compose.material3.Text(translated("Die Dateien werden gelöscht. Das lässt sich nicht zurücknehmen."), style = Theme.small, color = Theme.fontQuiet,
            modifier = Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing).padding(top = 4.dp, bottom = 10.dp))
        info.versions.forEach { v ->
            Row(Modifier.fillMaxWidth().heightIn(min = 50.dp).pressRow { info = screen.deleteToggle(v.is4k) }
                    .padding(horizontal = Theme.edgeSpacing).semantics { contentDescription = "delete-version-${v.label}" },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Symbol(if (v.chosen) Glyph.CheckboxFilled else Glyph.Checkbox, 17.dp, color = if (v.chosen) Theme.accent else Theme.fontVeryQuiet)
                androidx.compose.material3.Text(v.label, style = Theme.body, color = Theme.font, modifier = Modifier.weight(1f))
                v.size?.let { androidx.compose.material3.Text(it, style = Theme.small, color = Theme.fontVeryQuiet) }
            }
        }
        val any = info.versions.any { it.chosen }
        SheetLine()
        Box(Modifier.fillMaxWidth().heightIn(min = Theme.rowHeight)
                .then(if (any) Modifier.pressRow { follow { screen.deleteRunChosen() } } else Modifier)
                .semantics { contentDescription = "delete-confirm" }, contentAlignment = Alignment.Center) {
            androidx.compose.material3.Text(translated("Löschen"), style = Theme.buttonText, color = if (any) Theme.warning else Theme.fontVeryQuiet)
        }
        SheetLine()
        SheetCancel(close)
        return
    }

    DeleteText(info.headline ?: info.title, semibold = true)
    info.steps.forEach { step ->
        Row(Modifier.fillMaxWidth().heightIn(min = 46.dp).padding(horizontal = Theme.edgeSpacing)
                .semantics { contentDescription = "delete-step-${step.kind.name.lowercase()}-${step.state.name.lowercase()}" },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.size(22.dp), contentAlignment = Alignment.Center) {
                when (step.state) {
                    StepState.DONE -> Symbol(Glyph.CheckmarkCircleFilled, 19.dp, color = Theme.accent)
                    StepState.RUNNING -> Spinner(16.dp)
                    StepState.FAILED -> Symbol(Glyph.Warning, 18.dp, color = Theme.warning)
                    StepState.PENDING -> Symbol(Glyph.Ring, 17.dp, color = Theme.fontVeryQuiet)
                }
            }
            androidx.compose.material3.Text(step.label, style = Theme.body, color = if (step.state == StepState.PENDING) Theme.fontVeryQuiet else Theme.font)
        }
    }
    info.error?.let {
        androidx.compose.material3.Text(it, style = Theme.small, color = Theme.warning,
            modifier = Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing, vertical = 10.dp).semantics { contentDescription = "delete-error" })
    }
    if (info.phase != DeletePhase.RUNNING) {
        SheetLine()
        if (info.canRetry) {
            Box(Modifier.fillMaxWidth().heightIn(min = Theme.rowHeight).pressRow { follow { screen.deleteRetry() } }
                    .semantics { contentDescription = "delete-retry" }, contentAlignment = Alignment.Center) {
                androidx.compose.material3.Text(translated("Nochmal versuchen"), style = Theme.buttonText, color = Theme.accent)
            }
            SheetLine()
        }
        Box(Modifier.fillMaxWidth().heightIn(min = Theme.rowHeight).pressRow(close).semantics { contentDescription = "delete-close" },
            contentAlignment = Alignment.Center) {
            androidx.compose.material3.Text(translated("Schließen"), style = Theme.buttonText, color = Theme.fontQuiet)
        }
    }
}

@Composable
private fun DeleteText(text: String, semibold: Boolean = false, loose: Boolean = false) =
    androidx.compose.material3.Text(text, style = Theme.body.copy(fontWeight = if (semibold) FontWeight.SemiBold else FontWeight.Normal),
        color = Theme.font, maxLines = 2,
        modifier = Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing).padding(vertical = if (loose) 8.dp else 2.dp))
