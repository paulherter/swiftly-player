package de.paulherter.swiftly

import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.RemoteChannel
import de.paulherter.swiftly.rustcore.RemoteCommandKind
import de.paulherter.swiftly.rustcore.RemoteEvent
import de.paulherter.swiftly.rustcore.SyncPlayHost
import de.paulherter.swiftly.rustcore.SyncPlayModel
import de.paulherter.swiftly.rustcore.SyncPlayPage
import de.paulherter.swiftly.rustcore.SyncPlayPlayer
import de.paulherter.swiftly.rustcore.SyncPlayStep
import de.paulherter.swiftly.rustcore.host.AndroidWebSocketLink
import de.paulherter.swiftly.rustcore.host.LambdaRemoteListener
import de.paulherter.swiftly.rustcore.host.SyncPlayJson
import de.paulherter.swiftly.rustcore.takeoverIsHandoff
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject

/**
 * **A slot exactly one caller waits on** (`WaitCompartment` of the old core): something in it returns at once, otherwise the
 * call waits until something is put in. A second waiter replaces the first with `""` (the first belonged to a player that closed).
 */
internal class WaitSlot {
    private val lock = Any()
    private val lying = ArrayDeque<String>()
    private var waiting: CompletableDeferred<String>? = null

    fun put(entry: String) {
        val w = synchronized(lock) {
            val w = waiting
            if (w != null) { waiting = null; w } else { lying.addLast(entry); if (lying.size > 50) lying.removeFirst(); null }
        }
        w?.complete(entry)
    }

    suspend fun fetch(): String {
        val mine = CompletableDeferred<String>()
        val old: CompletableDeferred<String>?
        synchronized(lock) {
            if (lying.isNotEmpty()) return lying.removeFirst()
            old = waiting
            waiting = mine
        }
        old?.complete("")
        return mine.await()
    }

    /** Discards everything; whoever waits gets `""` and stops. */
    fun wipe() {
        val w = synchronized(lock) { val w = waiting; waiting = null; lying.clear(); w }
        w?.complete("")
    }
}

/**
 * **Watching together and the control channel on the Rust core**, answering the old `Kern` calls (`syncPlay*`, `remote*`, `playOrderWait`,
 * `handoffTargetTake`) with the old JSON. The core's `SyncPlayModel` runs the protocol; this class is the glue the old Swift core had:
 * the player as the session sees it (tick, steps slot, mark), the state as `{"stand", "lage"}`, the request slot for a title the group
 * sets while no player is open, and the `RemoteChannel` the app starts itself over the OkHttp websocket.
 */
internal class RustSyncPlay(
    private val core: Core,
    private val account: AccountRef,
    language: String,
    selfName: String?,
    private val scope: CoroutineScope,
    /** Does the title exist for this account? (`false`: the group's title cannot be played here.) */
    private val titleExists: suspend (String) -> Boolean,
    /** A play order carried audio/subtitle indices for this item (`PlayArrived`). */
    private val ordered: (String, Long?, Long?) -> Unit,
    private val log: (String) -> Unit,
) {
    private val lock = Any()
    private val steps = WaitSlot()
    private val requests = WaitSlot()
    private val orders = WaitSlot()
    private var attached: Attached? = null
    private var marks = 0L
    private var channel: RemoteChannel? = null
    private val commands = ArrayDeque<JSONObject>()
    private var hint: Pair<String, Long>? = null

    /** The player as the session reads it (`CorePlayer` of the old core). */
    private inner class Attached(val mark: Long, title: String) {
        private var title = title
        private var ready = false
        private var point = 0.0
        private var moved = false
        private var at = System.nanoTime()
        private var waits: String? = null

        @Synchronized fun tick(title: String, ready: Boolean, spot: Double, running: Boolean) {
            moved = running && Math.abs(spot - point) > 0.01 && Math.abs(spot - point) < 3
            this.title = title; this.ready = ready; point = spot; at = System.nanoTime()
            if (waits == title) waits = null
        }

        @Synchronized fun load(title: String, since: Double) {
            waits = title; ready = false
            steps.put(stepJson("laden", since, title))
        }

        @Synchronized fun jump(target: Double) { point = target; moved = false; at = System.nanoTime() }

        @Synchronized fun view(): SyncPlayPlayer {
            val spot = if (!moved) point else point + ((System.nanoTime() - at) / 1e9).coerceIn(0.0, 0.5)
            return SyncPlayPlayer(title, ready && waits == null, spot)
        }
    }

    private fun stepJson(kind: String, value: Double? = null, title: String? = null): String =
        JSONObject().put("art", kind).apply { value?.let { put("wert", it) }; title?.let { put("titel", it) } }.toString()

    private val host = object : SyncPlayHost {
        override fun playerStep(step: SyncPlayStep) {
            when (step) {
                is SyncPlayStep.Proceed -> steps.put(stepJson("weiter"))
                is SyncPlayStep.Halt -> steps.put(stepJson("anhalten"))
                is SyncPlayStep.Jump -> { synchronized(lock) { attached }?.jump(step.seconds); steps.put(stepJson("springen", step.seconds)) }
            }
        }

        override fun loadTitle(title: String, since: Double) {
            scope.launch {
                if (!titleExists(title)) { model.titleLoadFailed(); return@launch }
                val player = synchronized(lock) { attached }
                if (player != null) player.load(title, since)
                else requests.put(JSONObject().put("titel", title).put("ab", since).toString())
            }
        }
    }

    val model: SyncPlayModel = core.syncPlayModel(account, language, selfName, host)

    // ---- State -------------------------------------------------------------------------------------------------

    /** `Kern.syncPlayStatus`: the state as soon as it is newer than `to`. */
    suspend fun status(to: Long): String {
        val v = model.changed(to.toULong()).toLong()
        return JSONObject().put("stand", v).put("lage", SyncPlayJson.state(model.page())).toString()
    }

    suspend fun request(): String = requests.fetch()

    private suspend fun decided(before: SyncPlayPage): Boolean {
        val outcome = withTimeoutOrNull(20_000) {
            var seen = before.version
            while (true) {
                val p = model.page()
                if (p.detail.accepted > before.detail.accepted) return@withTimeoutOrNull true
                if (p.detail.errorCount > before.detail.errorCount) return@withTimeoutOrNull false
                seen = model.changed(maxOf(seen, p.version))
            }
            @Suppress("UNREACHABLE_CODE") false
        } ?: false
        if (outcome) withTimeoutOrNull(6_000) {
            var seen = 0uL
            while (model.page().current == null) seen = model.changed(seen.coerceAtLeast(model.page().version))
        }
        return outcome
    }

    suspend fun create(name: String, title: String): Boolean {
        val before = model.page()
        if (before.works) return false
        model.create(name, title)
        return decided(before)
    }

    suspend fun join(group: String): Boolean {
        val before = model.page()
        if (before.works || before.detail.offerings.none { it.id == group }) return false
        model.join(group)
        return decided(before)
    }

    fun rejoin() = model.rejoin()
    fun offeringsAsk() = model.offeringsAsk()

    // ---- The player --------------------------------------------------------------------------------------------

    /** `Kern.syncPlayConnect`: a mark (> 0) if the title is what the group watches, otherwise 0. */
    suspend fun connect(title: String): Long {
        if (!belongs(title)) return 0
        val player: Attached
        synchronized(lock) {
            marks += 1
            player = Attached(marks, title)
            attached = player
        }
        steps.wipe()
        model.playerAttached(player.view())
        return player.mark
    }

    private fun belongs(title: String): Boolean {
        val p = model.page()
        return p.current != null && p.queueTitle == title
    }

    fun detach(mark: Long) {
        synchronized(lock) { if (attached?.mark != mark) return; attached = null }
        steps.wipe()
        model.playerDetached()
    }

    private var tickRuns = false

    fun tick(mark: Long, title: String, ready: Boolean, spot: Double, running: Boolean) {
        val player = synchronized(lock) { attached?.takeIf { it.mark == mark } } ?: return
        player.tick(title, ready, spot, running)
        val trigger = synchronized(lock) { if (tickRuns) false else { tickRuns = true; true } }
        if (!trigger) return
        scope.launch {
            try { model.playerUpdate(player.view()); model.playerTick() } finally { synchronized(lock) { tickRuns = false } }
        }
    }

    suspend fun step(mark: Long): String {
        if (synchronized(lock) { attached?.mark } != mark) return ""
        return steps.fetch()
    }

    private fun update() { synchronized(lock) { attached }?.let { model.playerUpdate(it.view()) } }

    fun pleaseToggle(running: Boolean) { update(); model.requestToggle(running) }
    fun pleaseTitle(title: String) { update(); model.requestTitle(title, 0.0) }
    fun pleaseJump(seconds: Double) { update(); model.requestJump(maxOf(0.0, seconds)) }

    // ---- The control channel -----------------------------------------------------------------------------------

    /** `Kern.remoteControlStart`: report the capabilities, listen, feed the group. */
    fun controlStart() {
        if (channel != null) return
        val made = core.remoteChannel(account, AndroidWebSocketLink(), LambdaRemoteListener({ event -> events.execute { runCatching { arrived(event) } } }, {
            scope.launch { runCatching { core.reportCapabilities(account) }.onFailure { log("Fähigkeiten nicht gemeldet: ${it.message}") } }
        }))
        synchronized(lock) { if (channel != null) { made.stop(); return }; channel = made }
        made.start()
        model.rightFetch()
    }

    /** `Kern.remoteControlEnd`: sign-out and account switch. */
    fun controlEnd() {
        val old = synchronized(lock) { val c = channel; channel = null; c }
        old?.stop()
        model.finish()
        synchronized(lock) { commands.clear(); hint = null }
        orders.wipe()
        requests.wipe()
        steps.wipe()
    }

    /** Events are handled off the Rust callback thread: calling back into the core from inside the callback made JNA detach the thread under the running call (runtime abort). One thread keeps the order. */
    private val events = java.util.concurrent.Executors.newSingleThreadExecutor { Thread(it, "remote-events").apply { isDaemon = true } }

    private fun arrived(event: RemoteEvent) {
        when (event) {
            is RemoteEvent.SyncPlay -> { update(); model.feed(event.text) }
            is RemoteEvent.ConnectionLost -> model.linkLost()
            is RemoteEvent.ConnectionAgain -> model.linkAgain()
            is RemoteEvent.Handoff -> synchronized(lock) { hint = event.device to System.nanoTime() }
            is RemoteEvent.Command -> stash(event.command)
            is RemoteEvent.Play -> playArrived(event.order)
            else -> {}
        }
    }

    private fun stash(c: RemoteCommandKind) {
        val o = when (c) {
            is RemoteCommandKind.Pause -> JSONObject().put("art", "pause")
            is RemoteCommandKind.Proceed -> JSONObject().put("art", "weiter")
            is RemoteCommandKind.Toggle -> JSONObject().put("art", "umschalten")
            is RemoteCommandKind.Stop -> JSONObject().put("art", "stopp")
            is RemoteCommandKind.JumpOn -> JSONObject().put("art", "springen").put("wert", c.seconds)
            is RemoteCommandKind.Forward -> JSONObject().put("art", "vor")
            is RemoteCommandKind.Back -> JSONObject().put("art", "zurueck")
            is RemoteCommandKind.Next -> JSONObject().put("art", "naechste")
            is RemoteCommandKind.Previous -> JSONObject().put("art", "vorige")
        }
        synchronized(lock) { commands.addLast(o); if (commands.size > 20) commands.removeFirst() }
    }

    /** `Kern.remoteCommands`. */
    fun commandsTake(): String = synchronized(lock) { JSONArray(commands.toList()).also { commands.clear() }.toString() }

    /** `Kern.handoffTargetTake`: who takes over, once, and only if the hint is fresh. */
    fun hintTake(): String {
        val h = synchronized(lock) { hint.also { hint = null } } ?: return ""
        return if (takeoverIsHandoff((System.nanoTime() - h.second) / 1e9)) h.first else ""
    }

    private fun playArrived(order: de.paulherter.swiftly.rustcore.RemotePlayOrder) {
        val id = order.itemIds.getOrNull(order.startIndex.toInt()) ?: return
        // Not while watching together: the group owns the player and the title.
        if (model.page().current != null) { log("[Abspielen auf] Auftrag ignoriert: Gruppe aktiv ($id)"); return }
        ordered(id, order.audioIndex, order.subtitleIndex)
        log("[Abspielen auf] Auftrag: $id ab ${order.start.toInt()} s")
        orders.put(JSONObject().put("titel", id).put("ab", order.start).put("fassung", order.mediaSourceId ?: "").toString())
    }

    suspend fun orderWait(): String = orders.fetch()
}
