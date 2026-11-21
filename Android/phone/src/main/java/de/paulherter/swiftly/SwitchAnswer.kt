package de.paulherter.swiftly

import de.paulherter.swiftly.rustcore.host.CoreWords
import org.json.JSONObject

/**
 * **What the core answered to an episode or quality switch** (`Kern.episodeSwitch` / `Kern.qualitySwitch`), as one value
 * with one case per outcome, so the player has to decide every one of them (`when` without `else`).
 *
 * The words are the core's (`outcome_word` in `legacy_playback_run.rs`): `gewechselt`, `gesperrt`, `abgebrochen`,
 * `gescheitert`. Anything else (an empty answer, a word from another core version) is [Unknown]: it is shown and logged,
 * never ignored; before, an outcome without a branch left the old episode playing with nothing on screen.
 */
sealed interface SwitchAnswer {
    /** A stop the server did not take, to be sent later (`toStop`). */
    val pending: String?

    /** The new episode is planned; `plan` is its play plan JSON (null: the core moved on without one). */
    data class Switched(val plan: String?, override val pending: String?) : SwitchAnswer

    /** A switch was already running, or the player is closed. The old episode stays. */
    data class Locked(override val pending: String?) : SwitchAnswer

    /** The player was closed while the core planned. Nothing starts. */
    data class Cancelled(override val pending: String?) : SwitchAnswer

    /** No plan for the new episode; `error` is the core's wording. The old episode stays. */
    data class Failed(val error: String?, override val pending: String?) : SwitchAnswer

    /** A word this app does not know. The old episode stays. */
    data class Unknown(val word: String, override val pending: String?) : SwitchAnswer

    companion object {
        fun read(text: String): SwitchAnswer {
            val o = runCatching { JSONObject(text) }.getOrElse { return Unknown("keine Antwort", null) }
            val pending = o.fieldText("nachmeldung")
            return when (val word = o.optString("ergebnis")) {
                CoreWords.Ergebnis.SWITCHED -> Switched(o.fieldText("spielplan"), pending)
                CoreWords.Ergebnis.LOCKED -> Locked(pending)
                CoreWords.Ergebnis.CANCELLED -> Cancelled(pending)
                CoreWords.Ergebnis.FAILED -> Failed(o.fieldText("fehler"), pending)
                else -> Unknown(word.ifEmpty { "ohne Ergebnis" }, pending)
            }
        }
    }
}
