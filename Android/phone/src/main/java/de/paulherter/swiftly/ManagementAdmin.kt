package de.paulherter.swiftly

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import coil3.compose.AsyncImage
import de.paulherter.swiftly.rustcore.ListLoad
import de.paulherter.swiftly.rustcore.RowWork
import de.paulherter.swiftly.rustcore.SeerrIssueRow
import de.paulherter.swiftly.rustcore.SeerrRequestRow
import de.paulherter.swiftly.rustcore.ServerActionKind
import de.paulherter.swiftly.rustcore.ServerAdminAsk
import de.paulherter.swiftly.rustcore.ServerAdminIntent
import de.paulherter.swiftly.rustcore.ServerAdminPage
import de.paulherter.swiftly.rustcore.ServerAdminState
import de.paulherter.swiftly.rustcore.ServerLogsState
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.smoothRoundedShape

// Phone drawing of the admin sections of the hub (Anfragen queue, Meldungen, Server). State: ManagementAdminModels.kt.

@Composable
private fun Pills(items: List<Triple<String, Boolean, () -> Unit>>) {
    Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = Theme.edgeSpacing), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items.forEach { (title, on, tap) ->
            Text(title, style = Theme.small, color = if (on) Theme.reason else Theme.font,
                 modifier = Modifier.clip(CircleShape).background(if (on) Theme.font else Theme.area).tapOn(tap).padding(horizontal = 12.dp, vertical = 7.dp))
        }
    }
}

@Composable
private fun Quiet(text: String) = Text(text, style = Theme.body, color = Theme.fontQuiet, modifier = Modifier.padding(horizontal = Theme.edgeSpacing))

@Composable
private fun Wait() = Box(Modifier.fillMaxWidth().padding(40.dp), contentAlignment = Alignment.Center) { Spinner(26.dp) }

@Composable
private fun Chip(text: String, accent: Boolean = false, tap: () -> Unit) =
    Text(text, style = Theme.small.copy(fontWeight = FontWeight.SemiBold), color = if (accent) Theme.reason else Theme.font,
         modifier = Modifier.clip(CircleShape).background(if (accent) Theme.font else Theme.area).tapOn(tap).padding(horizontal = 14.dp, vertical = 8.dp))

@Composable
private fun Heading(text: String) = Text(text, style = Theme.small.copy(fontWeight = FontWeight.SemiBold), color = Theme.fontQuiet,
    modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 18.dp, bottom = 6.dp))

@Composable
private fun Card(content: @Composable ColumnScope.() -> Unit) =
    Column(Modifier.padding(horizontal = Theme.edgeSpacing).fillMaxWidth().clip(smoothRoundedShape(16.dp)).background(Theme.area).padding(14.dp),
           verticalArrangement = Arrangement.spacedBy(8.dp), content = content)

// ------------------------------------------------------------------ Anfragen (queue)

@Composable
fun ColumnScope.AdminQueueContent(app: SwiftlyApplication, open: (Destination) -> Unit) {
    val run = rememberCoroutineScope()
    val model = remember { AdminQueueModel(app, run) }
    // Also when a verb on the request page changed the queue (it stays under that page on the stack).
    LaunchedEffect(RequestsChanged.version.intValue) { model.load() }
    val i = model.info
    when {
        i == null || i.load == ListLoad.LOADING || i.load == ListLoad.IDLE -> Wait()
        i.load == ListLoad.OFFLINE || i.load == ListLoad.FAILED -> Quiet(i.error ?: adminWords().seerrOffline)
        else -> {
            Pills(i.pills.map { p -> Triple(p.title + " " + p.count, p.selected) { model.pill(p.pill) } })
            if (i.rows.isEmpty()) Quiet(adminWords().nothingRequested)
            i.rows.forEach { r -> QueueRow(r, open = { open(Destination(r.id.toString(), r.title, "Anfrage")) }, model = model) }
        }
    }
}

@Composable
private fun QueueRow(r: SeerrRequestRow, open: () -> Unit, model: AdminQueueModel) {
    Row(Modifier.fillMaxWidth().pressRow(open).padding(horizontal = Theme.edgeSpacing, vertical = 6.dp).semantics { contentDescription = "queue-row-" + r.id },
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        AsyncImage(model = tmdbImage(r.poster, 185), contentDescription = r.title, contentScale = ContentScale.Crop,
                   modifier = Modifier.size(48.dp, 72.dp).clip(smoothRoundedShape(6.dp)).background(Theme.area).tapOn(open))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(listOfNotNull(r.title, r.year?.let { "($it)" }).joinToString(" "), style = Theme.listTitle, color = Theme.font, maxLines = 2)
            Text(r.badge.line, style = Theme.small, color = SeerrBadgeMark.color(r.badge.kind))
            listOfNotNull(r.requestedBy, r.detail).takeIf { it.isNotEmpty() }?.let { Text(it.joinToString(" · "), style = Theme.small, color = Theme.fontQuiet) }
            r.workText?.let { Text(it, style = Theme.small, color = if (r.work == RowWork.FAILED) Theme.accent else Theme.fontQuiet) }
            if (r.work != RowWork.WORKING) Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (r.canApprove) Chip(adminWords().approve, accent = true) { model.approve(r.id) }
                if (r.canDecline) Chip(adminWords().decline) { model.decline(r.id) }
                if (r.canRetry) Chip(adminWords().retry) { model.retry(r.id) }
                if (r.canWithdraw && !r.canDecline) Chip(adminWords().withdraw) { model.decline(r.id) }
            }
        }
    }
}

// ------------------------------------------------------------------ Meldungen (issues)

@Composable
fun ColumnScope.AdminIssuesContent(app: SwiftlyApplication, open: (Destination) -> Unit, onThread: (Boolean) -> Unit = {}) {
    val run = rememberCoroutineScope()
    val model = remember { AdminIssuesModel(app, run) }
    LaunchedEffect(Unit) { model.load() }
    val d = model.detail
    LaunchedEffect(d != null) { onThread(d != null) }
    // Back inside a thread goes up one level (to the list), not out of the hub; the TV page does the same.
    BackHandler(enabled = d != null) { model.close() }
    val i = model.info
    if (d != null) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Chip("‹ " + adminWords().reports) { model.close() }
            IssueHead(d.row, open)
            Card {
                d.messages.forEach { m ->
                    Column {
                        Text(m.author + (m.whenText?.let { " · $it" } ?: ""), style = Theme.small, color = Theme.fontQuiet)
                        Text(m.text, style = Theme.body, color = Theme.font)
                    }
                }
            }
            d.error?.let { Quiet(it) }
            var text by remember { mutableStateOf("") }
            if (d.canReply) Card {
                BasicTextField(text, { text = it }, textStyle = Theme.body.copy(color = Theme.font), cursorBrush = SolidColor(Theme.font),
                               modifier = Modifier.fillMaxWidth().semantics { contentDescription = "issue-reply" })
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Chip(adminWords().reply, accent = true) { model.reply(text); text = "" }
                    if (d.canResolve) Chip(adminWords().resolve) { model.resolve() }
                    if (d.canReopen) Chip(adminWords().reopen) { model.reopen() }
                }
            }
        }
        return
    }
    when {
        i == null || i.load == ListLoad.LOADING || i.load == ListLoad.IDLE -> Wait()
        i.load == ListLoad.OFFLINE || i.load == ListLoad.FAILED -> Quiet(i.error ?: adminWords().seerrOffline)
        else -> {
            Pills(i.pills.map { p -> Triple(p.title + " " + p.count, p.selected) { model.pill(p.pill) } })
            if (i.rows.isEmpty()) Quiet(adminWords().noReports)
            i.rows.forEach { r -> Box(Modifier.pressRow { model.open(r.id) }) { IssueHead(r, open) } }
        }
    }
}

@Composable
private fun IssueHead(r: SeerrIssueRow, open: (Destination) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        AsyncImage(model = tmdbImage(r.poster, 185), contentDescription = r.title, contentScale = ContentScale.Crop,
                   modifier = Modifier.size(40.dp, 60.dp).clip(smoothRoundedShape(6.dp)).background(Theme.area))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(r.title, style = Theme.listTitle, color = Theme.font, maxLines = 2)
            Text(listOfNotNull(r.kindWord, r.place, r.timeText, r.statusWord).joinToString(" · "), style = Theme.small, color = if (r.isOpen) Theme.accent else Theme.fontQuiet)
            Text(r.message, style = Theme.small, color = Theme.fontQuiet, maxLines = 2)
            r.reporter?.let { Text(it, style = Theme.small, color = Theme.fontQuiet) }
        }
    }
}

// ------------------------------------------------------------------ Server

@Composable
fun ColumnScope.ServerAdminContent(app: SwiftlyApplication, onLogs: (Boolean) -> Unit = {}) {
    val run = rememberCoroutineScope()
    val model = remember { ServerAdminModel(app, run) }
    DisposableEffect(Unit) { model.start(); onDispose { model.stop() } }
    LaunchedEffect(model.logsOpen) { onLogs(model.logsOpen) }
    // Back inside the logs: text -> file list -> server page, one level per press; only then the hub is left.
    BackHandler(enabled = model.logsOpen) { model.logsBack() }
    if (model.logsOpen) { ServerLogsContent(model); return }
    when (val s = model.part?.state) {
        null, ServerAdminState.Loading -> Wait()
        is ServerAdminState.Failed -> { Quiet(s.hint); Box(Modifier.padding(Theme.edgeSpacing)) { Chip(adminWords().retry) { model.send(ServerAdminIntent.Retry) } } }
        is ServerAdminState.NotAllowed -> Quiet(s.hint)
        is ServerAdminState.Ready -> ServerPageBody(s.page, model)
    }
    // Screen level: the question is a window of its own, there only while the core asks.
    ServerAskDialog(model)
}

@Composable
private fun ServerPageBody(p: ServerAdminPage, model: ServerAdminModel) {
    Text(p.name + "  " + p.version, style = Theme.listTitle, color = Theme.font, modifier = Modifier.padding(horizontal = Theme.edgeSpacing))
    p.notice?.let { Quiet(it) }
    Card {
        p.counts.chunked(3).forEach { row ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                row.forEach { n -> Column { Text(n.text, style = Theme.listTitle, color = Theme.font); Text(n.label, style = Theme.small, color = Theme.fontQuiet) } }
            }
        }
    }
    if (p.tasks.isNotEmpty()) {
        Heading(p.tasksTitle)
        Card { p.tasks.forEach { t ->
            Column(Modifier.fillMaxWidth().tapOn { model.send(ServerAdminIntent.AskStopTask(t.id)) }) {
                Text(t.name, style = Theme.body, color = Theme.font)
                t.progress?.let { Bar(it) }
                t.progressText?.let { Text(it, style = Theme.small, color = Theme.fontQuiet) }
            }
        } }
    }
    Heading(p.streamsTitle)
    if (p.streams.isEmpty()) Quiet(p.streamsEmpty)
    p.streams.forEach { s ->
        Box(Modifier.padding(bottom = 8.dp)) { Card {
            Column(Modifier.fillMaxWidth().tapOn { model.send(ServerAdminIntent.AskStopStream(s.sessionId)) }) {
                Text(listOfNotNull(s.title, s.addition).joinToString(" · "), style = Theme.listTitle, color = Theme.font, maxLines = 2)
                Text(s.userName + " · " + s.deviceLine, style = Theme.small, color = Theme.fontQuiet)
                Bar(s.share)
                Text(s.timeLine + (if (s.paused) " ⏸" else ""), style = Theme.small, color = Theme.fontQuiet)
                Text(s.deliveryText + " · " + s.deliveryLine, style = Theme.small, color = if (s.cautionary) Theme.accent else Theme.fontQuiet)
            }
        } }
    }
    p.load?.let { l ->
        Heading(p.loadTitle)
        Card {
            listOfNotNull(l.cpu, l.memory).forEach { m -> Text(m.label + "  " + m.text, style = Theme.body, color = Theme.font); Bar(m.share) }
            l.diskIo?.let { Text(it.label + "  " + it.text, style = Theme.body, color = Theme.font) }
            p.disks.forEach { d -> Text(d.title + "  " + d.freeText, style = Theme.small, color = if (d.nearlyFull) Theme.accent else Theme.fontQuiet); Bar(d.freeShare) }
        }
    }
    Heading(p.actionsTitle)
    Card { p.actions.forEach { a ->
        Column(Modifier.fillMaxWidth().semantics { contentDescription = "server-action-" + a.kind.name.lowercase() }.tapOn {
            when (a.kind) {
                ServerActionKind.SCAN_LIBRARIES -> model.send(ServerAdminIntent.Scan)
                ServerActionKind.RESTART -> model.send(ServerAdminIntent.AskRestart)
                ServerActionKind.LOGS -> model.openLogs()
            }
        }.padding(vertical = 4.dp)) {
            Text(a.title, style = Theme.listTitle, color = if (a.accent) Theme.accent else Theme.font)
            a.under?.let { Text(it, style = Theme.small, color = Theme.fontQuiet) }
        }
    } }
    Box(Modifier.height(24.dp))
}

@Composable
private fun Bar(share: Double) = Box(Modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(Theme.reason)) {
    Box(Modifier.fillMaxWidth(share.toFloat().coerceIn(0f, 1f)).height(4.dp).background(Theme.font))
}

@Composable
private fun ServerAskDialog(model: ServerAdminModel) {
    val ask = model.ask
    if (ask is ServerAdminAsk.Nothing) return
    Dialog(onDismissRequest = { model.cancel() }) {
        Column(Modifier.clip(smoothRoundedShape(20.dp)).background(Theme.area).padding(20.dp).semantics { contentDescription = "server-ask" },
               verticalArrangement = Arrangement.spacedBy(12.dp)) {
            val (title, note, action) = when (ask) {
                is ServerAdminAsk.Restart -> Triple(ask.title, ask.note, ask.action)
                is ServerAdminAsk.StopTask -> Triple(ask.title, null, ask.action)
                is ServerAdminAsk.StopStream -> Triple(ask.title, ask.line, ask.action)
                else -> Triple("", null, "")
            }
            Text(title, style = Theme.listTitle, color = Theme.font)
            note?.let { Text(it, style = Theme.small, color = Theme.fontQuiet) }
            if (ask is ServerAdminAsk.StopStream) {
                if (model.message.isEmpty()) model.message = ask.message
                Text(ask.messageLabel, style = Theme.small, color = Theme.fontQuiet)
                BasicTextField(model.message, { model.message = it }, textStyle = Theme.body.copy(color = Theme.font), cursorBrush = SolidColor(Theme.font))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Chip(action, accent = true) { model.confirm(ask is ServerAdminAsk.StopStream) }
                Chip(adminWords().cancel) { model.cancel() }
            }
        }
    }
}

@Composable
private fun ColumnScope.ServerLogsContent(model: ServerAdminModel) {
    Box(Modifier.padding(horizontal = Theme.edgeSpacing)) { Chip("‹ " + adminWords().server) { model.logsBack() } }
    when (val s = model.logs?.state) {
        null, ServerLogsState.Loading -> Wait()
        is ServerLogsState.Files -> s.rows.forEach { r ->
            Column(Modifier.fillMaxWidth().pressRow { model.openLog(r.name) }.padding(horizontal = Theme.edgeSpacing, vertical = 8.dp)) {
                Text(r.name, style = Theme.body, color = Theme.font); Text(listOfNotNull(r.sizeText, r.day).joinToString(" · "), style = Theme.small, color = Theme.fontQuiet)
            }
        }
        is ServerLogsState.Empty -> Quiet(s.hint)
        is ServerLogsState.Text -> { Text(s.name, style = Theme.listTitle, color = Theme.font, modifier = Modifier.padding(Theme.edgeSpacing))
            Text(s.text, style = Theme.small, color = Theme.fontQuiet, modifier = Modifier.padding(horizontal = Theme.edgeSpacing)) }
        is ServerLogsState.Failed -> Quiet(s.hint)
    }
}
