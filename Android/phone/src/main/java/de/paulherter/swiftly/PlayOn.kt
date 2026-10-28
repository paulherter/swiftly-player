package de.paulherter.swiftly

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import de.paulherter.swiftly.shared.translated
import org.json.JSONArray
import org.json.JSONObject

// "Übergeben an …": mirrors `PlayOutputs` in `Sources/Shared/TakeoverModel.swift`. The rule (which
// devices, how an order is built) lives in the package; the core runs it (`Kern.playTargets`,
// `playHandOver`). An action in the player, not a mode: "Play" always plays on this device. A TV
// hands over too, to another TV.

/** A device a title can be handed to: its ID and name, never the session, which changes with every app start on the TV. */
data class PlayOutputChoice(val deviceID: String, val name: String)

/** From the last takeover poll (`offeringsFetch`); the core keeps the list, no request of its own. */
internal fun SwiftlyApplication.playTargetsTake() {
    playTargets.value = runCatching {
        JSONArray(kern.playTargets()).let { a ->
            (0 until a.length()).map { a.getJSONObject(it) }.map { PlayOutputChoice(it.getString("deviceId"), it.getString("name")) }
        }
    }.getOrDefault(emptyList())
}

/** The poll rests while the player is open: one question for "Übergeben an …" when it opens. */
suspend fun SwiftlyApplication.playTargetsRefresh() {
    runCatching { withContext(Dispatchers.IO) { kern.takeoverOfferings().await() } }
    playTargetsTake()
}

/**
 * **The running title from the player to the TV** (`PlayOutputs.handOver`): same position, version and
 * tracks. `true` only if the TV took it; then the player leaves.
 */
suspend fun SwiftlyApplication.playOnHandOver(output: PlayOutputChoice, position: Double): Boolean {
    val answer = runCatching {
        JSONObject(withContext(Dispatchers.IO) { kern.playHandOver(output.deviceID, output.name, position).await() })
    }.getOrNull()
    val reason = answer?.optString("grund") ?: "nichtVerbunden"
    val name = answer?.optString("name")?.takeIf { it.isNotEmpty() } ?: output.name
    when (reason) {
        "" -> { message.value = translated("Spielt auf „%@“", name); return true }
        "weg" -> message.value = translated("„%@“ ist nicht mehr erreichbar.", output.name)
        else -> message.value = errorString(reason)
    }
    return false
}

/**
 * **Titles sent from another device** (`RemoteControl.playHear`): opened like any request, replacing
 * what plays, as the Jellyfin web client does. Phone and TV. The core drops the order while the
 * device watches together (`Kern.playArrived`).
 */
fun SwiftlyApplication.playOrdersListen(run: kotlinx.coroutines.CoroutineScope) {
    run.launch {
        while (true) {
            val raw = runCatching { withContext(Dispatchers.IO) { kern.playOrderWait().await() } }.getOrNull()
            if (raw.isNullOrEmpty()) { kotlinx.coroutines.delay(500); continue }
            val o = JSONObject(raw)
            val w = PlayRequest(o.getString("titel"), o.optDouble("ab", 0.0), o.optString("fassung"))
            val playerOpen = play.value != null && playHandOver != null
            play.value = w
            // **A running player takes it itself.** The main view lies stopped behind it and would
            // not see the request until the player closes; the player (`singleTask`) rebuilds for it
            // in `onNewIntent`.
            if (playerOpen) {
                playHandOver = w
                startActivity(android.content.Intent(this@playOrdersListen, PlayerActivity::class.java)
                    .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
            }
        }
    }
}
