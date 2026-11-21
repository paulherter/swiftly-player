package de.paulherter.swiftly

import de.paulherter.swiftly.shared.translated
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * **A page follows the reloads the core starts by itself** (a change from another device through the server socket,
 * a link that came back after a real drop, a delete): the core counts them per account (`Core.listsStaleAfter`), and a
 * page that reads its rows one-shot reloads when the count moves, as the core's own Home and library models do
 * (`CacheChange::ListsStale`; Apple: `followSettledChanges`). Call it from a `LaunchedEffect`: it runs until cancelled.
 *
 * A burst of messages (marking a season watched) reloads once: the count is read again after a short pause. A signal that
 * arrives while the page loads waits for that load and then reloads once more, so no change is lost. `reload` keeps the
 * rows on screen (no spinner, no blanking).
 */
internal suspend fun followListsStale(app: SwiftlyApplication, busy: () -> Boolean, reload: suspend () -> Unit) {
    var seen = withContext(Dispatchers.IO) { app.rk.listsStaleVersion() }
    while (true) {
        withContext(Dispatchers.IO) { app.rk.listsStaleAfter(seen) }
        delay(1000)
        seen = withContext(Dispatchers.IO) { app.rk.listsStaleVersion() }
        snapshotFlow(busy).first { !it }
        reload()
    }
}

/** A Home answer that says "the server did not answer": a quiet reload keeps the rows it has instead of taking it. */
internal fun homeDisturbed(json: String): Boolean = runCatching { JSONObject(json).optBoolean("gestoert", false) }.getOrDefault(false)

/**
 * Why the Home answer is a failure, from the core's own state (`zustand` / `ausfall` in the answer of `Kern.home`, the
 * shared `Load` of the page): `offline`, `server`, `abgelehnt` or `unlesbar`; `null` for content and for a server that
 * answered with nothing. A page that only draws `reihen` shows an empty screen for the first four.
 */
internal fun homeFailure(json: String): String? =
    runCatching { JSONObject(json).takeIf { it.optString("zustand") in setOf("offline", "fehler") }?.optString("ausfall") }.getOrNull()?.takeIf { it.isNotEmpty() }

/**
 * The two failures whose words are "does not answer" (`offline`, `server`): over rows that are already on the page the notice
 * stands above them (`HomeView` on iPhone, `home.rs` on the desktop). A refused sign-in or an unreadable answer have their own page.
 */
internal fun homeSilent(failure: String?): Boolean = failure == "offline" || failure == "server"

/** Heading and sentence of the whole-page Home error for a [homeFailure]; the words of `LoadFailure::copy` in the core. */
internal fun homeTrouble(address: String, failure: String?): Pair<String, String> = when (failure) {
    "abgelehnt" -> translated("Anmeldung abgelehnt") to translated("%@ hat die Anmeldung abgelehnt. Wechsel den Server oder melde dich neu an.", address)
    "unlesbar" -> translated("Antwort unlesbar") to translated("%@ hat etwas geschickt, das die App nicht lesen kann. Versuch es gleich nochmal.", address)
    else -> translated("Server ist abgetaucht") to translated("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", address)
}
