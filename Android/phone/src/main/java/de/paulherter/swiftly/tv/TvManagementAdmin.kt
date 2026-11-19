package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import kotlinx.coroutines.delay
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import de.paulherter.swiftly.AdminIssuesModel
import de.paulherter.swiftly.AdminQueueModel
import de.paulherter.swiftly.Destination
import de.paulherter.swiftly.ServerAdminModel
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.rustcore.ListLoad
import de.paulherter.swiftly.rustcore.RowWork
import de.paulherter.swiftly.rustcore.ServerActionKind
import de.paulherter.swiftly.rustcore.ServerAdminAsk
import de.paulherter.swiftly.rustcore.ServerAdminIntent
import de.paulherter.swiftly.rustcore.ServerAdminPage
import de.paulherter.swiftly.rustcore.ServerAdminState
import de.paulherter.swiftly.rustcore.ServerLogsState
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.adminWords

// TV drawing of the admin sections of the hub: every row is a focus target for the D-pad; Back leaves a sub-view
// (thread, logs) first, then the hub. State: ManagementAdminModels.kt (shared with the phone).

@Composable
private fun Quiet(text: String) = Text(text, style = TvTheme.body, color = Theme.fontQuiet)

@Composable
fun TvAdminQueueContent(app: SwiftlyApplication, open: (Destination) -> Unit, firstRow: Modifier) {
    val run = rememberCoroutineScope()
    val model = remember { AdminQueueModel(app, run) }
    LaunchedEffect(Unit) { model.load() }
    val i = model.info
    when {
        i == null || i.load == ListLoad.LOADING || i.load == ListLoad.IDLE -> Quiet(adminWords().loading)
        i.load == ListLoad.OFFLINE || i.load == ListLoad.FAILED -> Quiet(i.error ?: adminWords().seerrOffline)
        else -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                i.pills.forEachIndexed { n, p -> TvButton(p.title + " " + p.count, height = 48.dp, active = p.selected, modifier = if (n == 0) firstRow else Modifier) { model.pill(p.pill) } }
            }
            if (i.rows.isEmpty()) Quiet(adminWords().nothingRequested)
            i.rows.forEach { r ->
                TvAction(name = listOfNotNull(r.title, r.year?.let { "($it)" }).joinToString(" "), value = r.workText ?: r.badge.line, arrow = false) {
                    open(Destination(r.art + ":" + r.tmdb, r.title, "Seerrtitel"))
                }
                if (r.work != RowWork.WORKING && (r.canApprove || r.canDecline || r.canRetry)) Row(Modifier.padding(start = 24.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (r.canApprove) TvButton(adminWords().approve, height = 48.dp) { model.approve(r.id) }
                    if (r.canDecline) TvButton(adminWords().decline, height = 48.dp) { model.decline(r.id) }
                    if (r.canRetry) TvButton(adminWords().retry, height = 48.dp) { model.retry(r.id) }
                }
            }
        }
    }
}

@Composable
fun TvAdminIssuesContent(app: SwiftlyApplication, firstRow: Modifier) {
    val run = rememberCoroutineScope()
    val model = remember { AdminIssuesModel(app, run) }
    LaunchedEffect(Unit) { model.load() }
    val d = model.detail
    BackHandler(enabled = d != null) { model.close() }
    val i = model.info
    if (d != null) {
        // **Focus moves into the opened thread** (first action). The row that was clicked has left the composition, so Compose would
        // drop focus to the first tab of the hub; `firstFocus` only runs once, when the page first appeared.
        val threadFocus = remember { FocusRequester() }
        LaunchedEffect(d.row.id) {
            androidx.compose.runtime.withFrameNanos { }
            repeat(6) { if (runCatching { threadFocus.requestFocus(); true }.getOrDefault(false)) return@LaunchedEffect; delay(TvTheme.focusDeadline) }
        }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(d.row.title, style = TvTheme.titleLarge, color = Theme.font)
            Text(listOfNotNull(d.row.kindWord, d.row.place, d.row.timeText, d.row.statusWord).joinToString(" · "), style = TvTheme.small, color = Theme.fontQuiet)
            d.messages.forEach { m ->
                Text(m.author + (m.whenText?.let { " · $it" } ?: ""), style = TvTheme.small, color = Theme.fontQuiet)
                Text(m.text, style = TvTheme.body, color = Theme.font)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
                if (d.canResolve) TvButton(adminWords().resolve, height = 52.dp, modifier = Modifier.focusRequester(threadFocus)) { model.resolve() }
                if (d.canReopen) TvButton(adminWords().reopen, height = 52.dp, modifier = Modifier.focusRequester(threadFocus)) { model.reopen() }
                TvButton(adminWords().back, height = 52.dp, modifier = if (d.canResolve || d.canReopen) Modifier else Modifier.focusRequester(threadFocus)) { model.close() }
            }
        }
        return
    }
    when {
        i == null || i.load == ListLoad.LOADING || i.load == ListLoad.IDLE -> Quiet(adminWords().loading)
        i.load == ListLoad.OFFLINE || i.load == ListLoad.FAILED -> Quiet(i.error ?: adminWords().seerrOffline)
        else -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                i.pills.forEachIndexed { n, p -> TvButton(p.title + " " + p.count, height = 48.dp, active = p.selected, modifier = if (n == 0) firstRow else Modifier) { model.pill(p.pill) } }
            }
            if (i.rows.isEmpty()) Quiet(adminWords().noReports)
            i.rows.forEach { r -> TvAction(name = r.title, value = listOfNotNull(r.kindWord, r.statusWord).joinToString(" · "), arrow = true) { model.open(r.id) } }
        }
    }
}

@Composable
fun TvServerAdminContent(app: SwiftlyApplication, firstRow: Modifier) {
    val run = rememberCoroutineScope()
    val model = remember { ServerAdminModel(app, run) }
    DisposableEffect(Unit) { model.start(); onDispose { model.stop() } }
    BackHandler(enabled = model.logsOpen) { model.logsBack() }
    if (model.logsOpen) { TvLogs(model, firstRow); return }
    when (val s = model.part?.state) {
        null, ServerAdminState.Loading -> Quiet(adminWords().loading)
        is ServerAdminState.Failed -> Column { Quiet(s.hint); TvButton(adminWords().retry, height = 52.dp, modifier = firstRow) { model.send(ServerAdminIntent.Retry) } }
        is ServerAdminState.NotAllowed -> Quiet(s.hint)
        is ServerAdminState.Ready -> TvServerBody(s.page, model, firstRow)
    }
    TvAskDialog(model)
}

@Composable
private fun TvServerBody(p: ServerAdminPage, model: ServerAdminModel, firstRow: Modifier) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(p.name + "  " + p.version, style = TvTheme.body, color = Theme.font)
        p.notice?.let { Quiet(it) }
        Text(p.counts.joinToString("   ") { it.text + " " + it.label }, style = TvTheme.small, color = Theme.fontQuiet)
        // Actions first: the D-pad lands on them, the long lists follow below.
        p.actions.forEachIndexed { n, a ->
            TvAction(name = a.title, value = a.under, arrow = false, modifier = if (n == 0) firstRow else Modifier) {
                when (a.kind) {
                    ServerActionKind.SCAN_LIBRARIES -> model.send(ServerAdminIntent.Scan)
                    ServerActionKind.RESTART -> model.send(ServerAdminIntent.AskRestart)
                    ServerActionKind.LOGS -> model.openLogs()
                }
            }
        }
        p.load?.let { l ->
            Text(p.loadTitle, style = TvTheme.small, color = Theme.fontQuiet, modifier = Modifier.padding(top = 10.dp))
            listOfNotNull(l.cpu, l.memory).forEach { Text(it.label + "  " + it.text, style = TvTheme.body, color = Theme.font) }
            l.diskIo?.let { Text(it.label + "  " + it.text, style = TvTheme.body, color = Theme.font) }
            p.disks.forEach { Text(it.title + "  " + it.freeText, style = TvTheme.small, color = Theme.fontQuiet) }
        }
        if (p.tasks.isNotEmpty()) {
            Text(p.tasksTitle, style = TvTheme.small, color = Theme.fontQuiet, modifier = Modifier.padding(top = 10.dp))
            p.tasks.forEach { t -> TvAction(name = t.name, value = t.progressText, arrow = false) { model.send(ServerAdminIntent.AskStopTask(t.id)) } }
        }
        Text(p.streamsTitle, style = TvTheme.small, color = Theme.fontQuiet, modifier = Modifier.padding(top = 10.dp))
        if (p.streams.isEmpty()) Quiet(p.streamsEmpty)
        p.streams.forEach { s ->
            TvAction(name = listOfNotNull(s.title, s.addition).joinToString(" · "), value = s.userName + " · " + s.timeLine, arrow = false) {
                model.send(ServerAdminIntent.AskStopStream(s.sessionId))
            }
        }
    }
}

@Composable
private fun TvLogs(model: ServerAdminModel, firstRow: Modifier) {
    when (val s = model.logs?.state) {
        null, ServerLogsState.Loading -> Quiet(adminWords().loading)
        is ServerLogsState.Files -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            s.rows.forEachIndexed { n, r -> TvAction(name = r.name, value = r.sizeText, arrow = false, modifier = if (n == 0) firstRow else Modifier) { model.openLog(r.name) } }
        }
        is ServerLogsState.Empty -> Quiet(s.hint)
        is ServerLogsState.Text -> Column { Text(s.name, style = TvTheme.body, color = Theme.font); Text(s.text.takeLast(2500), style = TvTheme.small, color = Theme.fontQuiet) }
        is ServerLogsState.Failed -> Quiet(s.hint)
    }
}

/** The core's question at screen level: a window of its own, only while the core asks; Back cancels. */
@Composable
private fun TvAskDialog(model: ServerAdminModel) {
    val ask = model.ask
    if (ask is ServerAdminAsk.Nothing) return
    val first = firstFocus()
    Dialog(onDismissRequest = { model.cancel() }) {
        Column(Modifier.clip(RoundedCornerShape(20.dp)).background(Theme.area).padding(28.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            val (title, note, action) = when (ask) {
                is ServerAdminAsk.Restart -> Triple(ask.title, ask.note, ask.action)
                is ServerAdminAsk.StopTask -> Triple(ask.title, null, ask.action)
                is ServerAdminAsk.StopStream -> Triple(ask.title, ask.line, ask.action)
                else -> Triple("", null, "")
            }
            Text(title, style = TvTheme.body, color = Theme.font)
            note?.let { Text(it, style = TvTheme.small, color = Theme.fontQuiet) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                // The cancel button takes the first focus: a stray OK never restarts the server.
                TvButton(adminWords().cancel, height = 52.dp, modifier = Modifier.focusRequester(first)) { model.cancel() }
                TvButton(action, height = 52.dp) { model.confirm(ask is ServerAdminAsk.StopStream) }
            }
        }
    }
}
