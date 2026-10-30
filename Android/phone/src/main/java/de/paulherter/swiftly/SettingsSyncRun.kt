package de.paulherter.swiftly

import androidx.compose.runtime.mutableStateOf
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/**
 * Mirrors `SettingsSyncRun`: **keeps the synced settings equal across devices** through the Jellyfin
 * account's display preferences. The rules (keys, encoding, who wins) are in the package
 * (`SettingsSync`, through `Kern.settingsSyncRun`); this class only watches the device and applies.
 *
 * Starts on every account change (launch, sign-in, switch) and when the app comes to the front,
 * never in the way; a failure (offline, old server, no right) is forgotten. After a change it waits
 * two seconds, then fetches, compares and writes.
 */
class SettingsSyncRun(private val app: SwiftlyApplication, private val run: CoroutineScope) {
    private companion object {
        const val ON = "einstellungenSync"
        const val TIME = "einstellungenSyncZeit"
        const val ACCOUNT = "einstellungenSyncKonto"
        const val REMOTE = "einstellungenSyncServer"
        val bools = listOf("utAuto", "naechsteAuto", "introAbspannAuto", "restzeitAlsEnde", "titelAlsLogo", "fortschritt",
                           "merklisteAn", "alphabetAn", "neuGetrennt", "genreChips")
        val ints = listOf("vorSek", "zurueckSek")
        val texts = listOf("tonSprache", "utSprache")
        val lists = listOf("startReihen", "startAus", "startGenres")
        val names = texts + bools.take(4) + ints + bools.drop(4) + lists + "startBibliotheken"
    }

    private val store get() = app.store

    /** The switch in the settings. **On by default.** */
    val on = mutableStateOf(store.rememberValue(ON) != "0")
    fun onSet(value: Boolean) {
        on.value = value
        store.remember(ON, if (value) "1" else "0")
        if (value) request(null)
    }

    private var waiting: Job? = null
    private var running = false
    private var again = false
    private var applying = false
    private var lastRun = 0L
    private var snapshot: Map<String, String> = emptyMap()

    /** Once, after the store exists. A change to a synced key stamps the time and schedules a run. */
    fun attach() {
        snapshot = values()
        store.onChange = { key ->
            if (!applying && names.contains(key.substringBefore('|'))) changed()
        }
        app.seerrChanged = { seerrChanged() }
    }

    /** When the Seerr connection last changed here, per server; see `SettingsSync.seerrStep`. */
    private fun seerrTimeKey(): String = "seerrSyncZeit|" + app.seerrServer()

    private fun seerrChanged() {
        store.remember(seerrTimeKey(), System.currentTimeMillis().toString())
        if (on.value) request(1000)
    }

    /** After an account switch the per-server entry has another device key; that is no change by the user. */
    fun rebind() { snapshot = values() }

    private fun number(key: String): Double = store.rememberValue(key)?.toDoubleOrNull() ?: 0.0

    private fun changed() {
        val now = values()
        if (now == snapshot) return
        snapshot = now
        val seen = number(REMOTE)
        val nowMs = System.currentTimeMillis().toDouble()
        // Never earlier than what the server already holds.
        store.remember(TIME, (if (seen >= nowMs) seen + 1 else nowMs).toLong().toString())
        if (on.value) request(2000)
    }

    // MARK: Reading the device

    private fun values(): Map<String, String> {
        val out = linkedMapOf<String, String>()
        for (n in bools) store.rememberValue(n)?.takeIf { it == "1" || it == "0" }?.let { out[n] = (it == "1").toString() }
        for (n in ints) store.rememberValue(n)?.toIntOrNull()?.takeIf { it in 0..3600 }?.let { out[n] = it.toString() }
        for (n in texts) store.rememberValue(n)?.let { out[n] = it }
        for (n in lists) store.rememberValue(n)?.takeIf { runCatching { JSONArray(it) }.isSuccess }?.let { out[n] = it }
        store.rememberValue("startBibliotheken|" + app.settings.serverKey())
            ?.takeIf { runCatching { JSONArray(it) }.isSuccess }?.let { out["startBibliotheken"] = it }
        return out
    }

    // MARK: Talking to the server

    fun request(delayMs: Long?) {
        if (!on.value || app.accountId().isEmpty()) return
        waiting?.cancel()
        waiting = run.launch {
            if (delayMs != null) delay(delayMs)
            drain()
        }
    }

    /** One run at a time; a request that arrives during a run asks for one more. */
    private suspend fun drain() {
        waiting = null
        if (running) { again = true; return }
        running = true
        try {
            do {
                again = false
                if (!on.value) break
                // A bad answer must not stop syncing for the rest of the process.
                try { runOnce() } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) {}
            } while (again)
        } finally {
            running = false
        }
    }

    private suspend fun runOnce() {
        lastRun = System.currentTimeMillis()
        val account = app.accountId() + "|" + app.activeServer().orEmpty()
        val started = store.rememberValue(TIME)
        val other = store.rememberValue(ACCOUNT) != account
        val seerrKey = seerrTimeKey()
        val seerrStarted = store.rememberValue(seerrKey)
        val raw = runCatching {
            app.kern.settingsSyncRun(JSONObject(values()).toString(), number(TIME), number(REMOTE), other,
                                     app.seerrStored().orEmpty(), number(seerrKey)).await()
        }.getOrNull() ?: return
        // The account changed while the answer was on its way: that answer belongs to the one that left.
        if (app.accountId() + "|" + app.activeServer().orEmpty() != account) return
        val o = JSONObject(raw)
        when (o.optString("seerr")) {
            "adopt" -> if (store.rememberValue(seerrKey) == seerrStarted) {
                app.seerrAdopt(o.optString("seerrAccess"))
                store.remember(seerrKey, o.optDouble("seerrStamp").toLong().toString())
                AppLog.writeOut("[Abgleich] Seerr vom Server übernommen")
            } else again = true
            "push" -> store.remember(seerrKey, o.optDouble("seerrStamp").toLong().toString())
        }
        val remote = o.optDouble("remote", 0.0)
        if (remote > 0) store.remember(REMOTE, remote.toLong().toString())
        when (o.optString("decision")) {
            "apply" -> {
                // Changed here while the answer was on its way: that change must not be overwritten.
                if (store.rememberValue(TIME) != started) { again = true; return }
                val v = o.getJSONObject("values")
                apply(v.keys().asSequence().associateWith { v.getString(it) })
                store.remember(TIME, o.optDouble("stamp").toLong().toString())
                store.remember(ACCOUNT, account)
                AppLog.writeOut("[Abgleich] Einstellungen vom Server übernommen")
            }
            "push" -> {
                store.remember(TIME, o.optDouble("stamp").toLong().toString())
                store.remember(ACCOUNT, account)
                AppLog.writeOut("[Abgleich] Einstellungen zum Server geschrieben")
            }
            "nothing", "empty" -> store.remember(ACCOUNT, account)
            else -> AppLog.writeOut("[Abgleich] übersprungen")
        }
    }

    private suspend fun apply(values: Map<String, String>) {
        applying = true
        try { app.settings.applySynced(values) } finally { applying = false }
        // What was just written is not a change of the user's.
        snapshot = values()
    }

    /** App to the front: at most once a minute. */
    fun toFront() {
        if (System.currentTimeMillis() - lastRun > 60_000) request(null)
    }
}
