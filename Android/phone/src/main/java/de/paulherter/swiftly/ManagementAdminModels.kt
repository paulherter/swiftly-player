package de.paulherter.swiftly

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import de.paulherter.swiftly.rustcore.IssuePill
import de.paulherter.swiftly.rustcore.RequestPill
import de.paulherter.swiftly.rustcore.SeerrAdminScreen
import de.paulherter.swiftly.rustcore.SeerrIssueDetail
import de.paulherter.swiftly.rustcore.SeerrIssuesInfo
import de.paulherter.swiftly.rustcore.SeerrRequestDetail
import de.paulherter.swiftly.rustcore.SeerrRequestsInfo
import de.paulherter.swiftly.rustcore.ServerAdminAsk
import de.paulherter.swiftly.rustcore.ServerAdminIntent
import de.paulherter.swiftly.rustcore.ServerAdminPart
import de.paulherter.swiftly.rustcore.ServerAdminVm
import de.paulherter.swiftly.rustcore.ServerLogsIntent
import de.paulherter.swiftly.rustcore.ServerLogsPart
import de.paulherter.swiftly.rustcore.ServerLogsVm
import de.paulherter.swiftly.shared.Texts
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * **State holders of the admin sections** (Anfragen queue, Meldungen, Server) for phone and TV alike: they only hold what
 * the core answered (`SeerrAdminScreen`, `ServerAdminVm`, `ServerLogsVm`); the phone and TV UIs draw it. Mirrors
 * `SeerrAdminFlow` / `ServerAdminModel` / `ServerLogsModel` (Sources/Shared).
 */
private suspend fun <T> io(block: suspend () -> T): T? = withContext(Dispatchers.IO) {
    try { block() } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
}

private fun adminScreen(app: SwiftlyApplication): SeerrAdminScreen = SeerrAdminScreen(app.seerr.hub())

/** The Seerr queue of a manager: approve, decline, retry. */
class AdminQueueModel(private val app: SwiftlyApplication, private val scope: CoroutineScope) {
    var info by mutableStateOf<SeerrRequestsInfo?>(null)
    private var screen: SeerrAdminScreen? = null

    private suspend fun screen(): SeerrAdminScreen? = screen ?: io { adminScreen(app) }?.also { screen = it }

    /** The queue of the last visit first (the core's stash, no call), then one live read of counts, queue and problems side by side. */
    fun load() {
        scope.launch {
            val s = screen() ?: return@launch
            if (info == null) io { s.restoreAll() }?.queue?.let { if (info == null) info = it }
            val tabs = io { s.loadAll() }
            info = if (tabs == null) info else s.requests()
        }
    }
    fun pill(p: RequestPill) { scope.launch { info = screen()?.let { s -> io { s.selectPill(p) } } ?: info } }

    private fun act(id: Long, call: suspend (SeerrAdminScreen) -> SeerrRequestsInfo) {
        scope.launch {
            val s = screen() ?: return@launch
            // The row reads the core's "Wird freigegeben…" while the server answers.
            val running = scope.launch { delay(60); info = s.requests() }
            info = io { call(s) } ?: s.requests()
            running.cancel()
        }
    }
    fun approve(id: Long) = act(id) { it.approve(id) }
    fun decline(id: Long) = act(id) { it.decline(id) }
    fun retry(id: Long) = act(id) { it.retry(id) }
}

/**
 * **One request opened** (iPhone `RequestDetailView` + `SeerrAdminFlow.detail`): the core's card (row on top, label/value rows) and the
 * verbs it allows this account. A verb runs on the core's admin screen, reads the card again and bumps [RequestsChanged], so the
 * list that opened this reads again when it is back on screen.
 */
class RequestDetailModel(private val app: SwiftlyApplication, private val scope: CoroutineScope, private val id: Long) {
    var detail by mutableStateOf<SeerrRequestDetail?>(null)
    var settled by mutableStateOf(false)
    private var screen: SeerrAdminScreen? = null

    private suspend fun screen(): SeerrAdminScreen? = screen ?: io { adminScreen(app) }?.also { screen = it }

    fun load() { scope.launch { val s = screen(); detail = s?.let { io { it.requestDetail(id) } }; settled = true } }

    private fun act(then: () -> Unit = {}, call: suspend (SeerrAdminScreen) -> SeerrRequestsInfo) {
        scope.launch {
            val s = screen() ?: return@launch
            io { call(s) }
            detail = io { s.requestDetail(id) } ?: detail
            RequestsChanged.version.intValue++
            then()
        }
    }
    fun approve() = act { it.approve(id) }
    fun decline() = act { it.decline(id) }
    fun retry() = act { it.retry(id) }
    fun withdraw(then: () -> Unit) = act(then) { it.withdraw(id) }
}

/** A verb on a request changed what the lists show: "Meine Anfragen" and the queue read again when this moves. */
object RequestsChanged { val version = mutableIntStateOf(0) }

/** The reason a season of a Seerr title page may be approved/declined here: the core's rule (`SeasonAdmin` on Apple). */
object SeasonAdmin {
    fun waitingRequest(app: SwiftlyApplication, waiting: Long?): Long? = if (app.seerr.hub().info().canManageRequests) waiting else null

    /** Approves or declines, off the main thread; the caller reads the page again afterwards. */
    suspend fun decide(app: SwiftlyApplication, request: Long, approve: Boolean) {
        io { val s = adminScreen(app); if (approve) s.approve(request) else s.decline(request) }
    }
}

/** The issue list and the open thread. */
class AdminIssuesModel(private val app: SwiftlyApplication, private val scope: CoroutineScope) {
    var info by mutableStateOf<SeerrIssuesInfo?>(null)
    var detail by mutableStateOf<SeerrIssueDetail?>(null)
    private var screen: SeerrAdminScreen? = null

    private suspend fun screen(): SeerrAdminScreen? = screen ?: io { adminScreen(app) }?.also { screen = it }

    /** The problems of the last visit first (the core's stash, no call), then one live read of counts, queue and problems side by side. */
    fun load() {
        scope.launch {
            val s = screen() ?: return@launch
            if (info == null) io { s.restoreAll() }?.issues?.let { if (info == null) info = it }
            val tabs = io { s.loadAll() }
            info = if (tabs == null) info else s.issues()
        }
    }
    fun pill(p: IssuePill) { scope.launch { info = screen()?.let { s -> io { s.selectIssuePill(p) } } ?: info } }
    fun open(id: Long) { scope.launch { detail = screen()?.let { s -> io { s.openIssue(id) } } } }
    fun close() { scope.launch { screen()?.closeIssue(); detail = null; load() } }
    fun reply(text: String) { if (text.isNotBlank()) scope.launch { detail = screen()?.let { s -> io { s.reply(text) } } ?: detail } }
    fun resolve() { scope.launch { detail = screen()?.let { s -> io { s.resolveIssue() } } ?: detail } }
    fun reopen() { scope.launch { detail = screen()?.let { s -> io { s.reopenIssue() } } ?: detail } }
}

/** The server page and its logs. `start` when the page is on screen, `stop` when it leaves. */
class ServerAdminModel(private val app: SwiftlyApplication, private val scope: CoroutineScope) {
    var part by mutableStateOf<ServerAdminPart?>(null)
    var logs by mutableStateOf<ServerLogsPart?>(null)
    var logsOpen by mutableStateOf(false)
    var message by mutableStateOf("")
    private var vm: ServerAdminVm? = null
    private var logsVm: ServerLogsVm? = null
    private var job: Job? = null

    val ask: ServerAdminAsk get() = (part?.state as? de.paulherter.swiftly.rustcore.ServerAdminState.Ready)?.page?.ask ?: ServerAdminAsk.Nothing

    fun start() {
        job = scope.launch(Dispatchers.IO) {
            val account = app.rk.account() ?: return@launch
            val v = try { app.rk.core().serverAdminVm(account, Texts.language) } catch (e: CancellationException) { throw e } catch (_: Exception) { return@launch }
            vm = v
            v.send(ServerAdminIntent.Start)
            var p = v.part(); part = p
            var seen = p.version
            while (true) {
                runCatching { v.changed(seen) }.getOrNull() ?: break
                p = v.part(); part = p; seen = p.version
            }
        }
    }

    fun stop() { job?.cancel(); scope.launch(Dispatchers.IO) { runCatching { vm?.send(ServerAdminIntent.Stop) } } }

    fun send(intent: ServerAdminIntent) { scope.launch(Dispatchers.IO) { vm?.send(intent) } }

    /** The core's question: the stream message starts with the core's default. */
    fun confirm(withMessage: Boolean) { send(ServerAdminIntent.Confirm(if (withMessage) message else null)); message = "" }
    fun cancel() { send(ServerAdminIntent.Cancel); message = "" }

    fun openLogs() {
        logsOpen = true
        scope.launch(Dispatchers.IO) {
            val account = app.rk.account() ?: return@launch
            val v = try { app.rk.core().serverLogsVm(account, Texts.language) } catch (e: CancellationException) { throw e } catch (_: Exception) { return@launch }
            logsVm = v
            v.send(ServerLogsIntent.Load)
            var p = v.part(); logs = p
            var seen = p.version
            while (true) {
                runCatching { v.changed(seen) }.getOrNull() ?: break
                p = v.part(); logs = p; seen = p.version
            }
        }
    }
    fun openLog(name: String) { scope.launch(Dispatchers.IO) { logsVm?.send(ServerLogsIntent.Open(name)) } }
    /** Back inside the logs: one level up, then out. Returns false when the logs were not open. */
    fun logsBack(): Boolean {
        val inText = logs?.state is de.paulherter.swiftly.rustcore.ServerLogsState.Text
        return when (logsBackStep(logsOpen, inText)) {
            LogsBack.NONE -> false
            LogsBack.TO_LIST -> { scope.launch(Dispatchers.IO) { logsVm?.send(ServerLogsIntent.Back) }; true }
            LogsBack.CLOSE -> { logsOpen = false; logs = null; logsVm = null; true }
        }
    }
}

/** What one Back press does inside the Server section. */
enum class LogsBack { NONE, TO_LIST, CLOSE }

/** The levels of the Server section: the page, the log files, one log's text. Pure, so the order is tested. */
fun logsBackStep(logsOpen: Boolean, inText: Boolean): LogsBack = when {
    !logsOpen -> LogsBack.NONE
    inText -> LogsBack.TO_LIST
    else -> LogsBack.CLOSE
}
