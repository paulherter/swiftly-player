package de.paulherter.swiftly

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

// "Senden an": mirrors `PlayOutputs` in `Sources/Shared/TakeoverModel.swift`. The rule (which
// devices, how a title becomes an order) lives in the package; the core runs it
// (`Kern.playTargets`, `playOn`, `playHandOver`, `playOrderWait`).
//
// **An action on a title, not a mode**: "Play" always plays on this device. A remembered output
// would send every tap to a TV with nothing on the phone saying so. A TV sends too, to another TV.

/** A device a title can be sent to: its ID and name, never the session, which changes with every app start on the TV. */
data class PlayOutputChoice(val deviceID: String, val name: String)

/** From the last takeover poll (`offeringsFetch`); the core keeps the list, no request of its own. */
internal fun SwiftlyApplication.playTargetsTake() {
    playTargets.value = runCatching {
        JSONArray(kern.playTargets()).let { a ->
            (0 until a.length()).map { a.getJSONObject(it) }.map { PlayOutputChoice(it.getString("deviceId"), it.getString("name")) }
        }
    }.getOrDefault(emptyList())
}

/** The poll rests while the player is open: one question for "Hand over to…" when it opens. */
suspend fun SwiftlyApplication.playTargetsRefresh() {
    runCatching { withContext(Dispatchers.IO) { kern.takeoverOfferings().await() } }
    playTargetsTake()
}

/**
 * **"Senden an": a title to a TV** (`PlayOutputs.send`). The TV builds its own plan with its own
 * profile, so nothing is transcoded. If the TV is gone, a message says so and nothing plays here
 * instead.
 */
suspend fun SwiftlyApplication.playOnSend(itemID: String, output: PlayOutputChoice) {
    val e = settings
    val answer = runCatching {
        JSONObject(withContext(Dispatchers.IO) {
            kern.playOn(output.deviceID, output.name, itemID, -1.0, "",
                        e.audioLanguage, e.subtitleLanguage, e.subtitleAutomatic,
                        store.rememberValue("tonJeTitel") ?: "{}", store.rememberValue("utJeTitel") ?: "{}").await()
        })
    }.getOrNull()
    playAnswer(answer, output)
}

/**
 * **The running title from the player to the TV** (`PlayOutputs.handOver`): same position, version and
 * tracks. `true` only if the TV took it; then the player leaves.
 */
suspend fun SwiftlyApplication.playOnHandOver(output: PlayOutputChoice, position: Double): Boolean {
    val answer = runCatching {
        JSONObject(withContext(Dispatchers.IO) { kern.playHandOver(output.deviceID, output.name, position).await() })
    }.getOrNull()
    return playAnswer(answer, output)
}

private fun SwiftlyApplication.playAnswer(answer: JSONObject?, output: PlayOutputChoice): Boolean {
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
 * what plays, as the Jellyfin web client does. Phone and TV.
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

/**
 * **"Senden an" on a tile or a detail page**: a sheet with the TVs in reach, the title goes to the one
 * tapped. A series goes as the episode the viewer is at, as "Play" on its tile does. Only offered while
 * a TV is in reach (`playTargets`).
 */
fun SwiftlyApplication.sendToShow(itemID: String, type: String?, name: String) {
    val targets = playTargets.value
    if (targets.isEmpty()) return
    // The title heads the sheet; "Senden an" was on the button that opened it.
    sheet.value = SheetRequest(name, targets.map { Choice(it.deviceID, it.name) }, null,
        targets.associate { it.deviceID to Glyph.Tv }) { chosen ->
        val target = targets.firstOrNull { it.deviceID == chosen } ?: return@SheetRequest
        applicationRun.launch {
            val id = if (type == "Series") {
                runCatching { JSONObject(withContext(Dispatchers.IO) { kern.series(itemID).await() }).optJSONObject("stand")?.getString("id") }.getOrNull()
                    ?: run { message.value = translated("Danach kommt nichts mehr."); return@launch }
            } else itemID
            playOnSend(id, target)
        }
    }
}

