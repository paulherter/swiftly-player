package de.paulherter.swiftly.rustcore.host

/**
 * The words the Rust core sends and the Android UIs compare with `==` (switch result, offering, overlay, first-frame and
 * stream-watch advice, the engine command names of the Media3 shell).
 *
 * Every UI comparison against a core word goes through a constant here, never a string literal. `CoreWordsContractTest`
 * reads `crates/swiftly-uniffi/data/core-words.json` (written by the Rust test `core_words_contract`) and fails for any constant here
 * whose word the core does not send. A word the core never sends used to break silently (an older build: "Next episode"
 * did nothing). Add a constant only for a word the UI really compares; the test checks the rest.
 *
 * Pure Kotlin on purpose: `:rustcore` (and through it the phone app) and the Rust shell's Gradle project both compile this
 * one file (`src/words`).
 */
object CoreWords {
    /** `ergebnis` of an episode or quality switch (`playback.ergebnis`). */
    object Ergebnis {
        const val GROUP = "playback.ergebnis"
        const val SWITCHED = "gewechselt"
        const val FAILED = "gescheitert"
    }

    /** `angebot`: what the button at the bottom right offers (`playback.angebot`). */
    object Angebot {
        const val GROUP = "playback.angebot"
        const val NOBODY = "keiner"
        const val SKIP = "ueberspringen"
        const val NEXT = "naechste"
    }

    /** `einblendung`: how the offering shows (`playback.einblendung`). */
    object Einblendung {
        const val GROUP = "playback.einblendung"
        const val NOTHING = "nichts"
        const val CARD = "karte"
    }

    /** `art` of a row in the playback info sheet (`playback.infoArt`). */
    object InfoArt {
        const val GROUP = "playback.infoArt"
        const val GOOD = "gut"
    }

    /** What to do while the first picture stays black (`player.firstFrameRat`). */
    object FirstFrameRat {
        const val GROUP = "player.firstFrameRat"
        const val NOTHING = "nichts"
        const val WAIT = "warten"
        const val SOFTWARE_DECODER = "softwareDekoder"
        const val GIVE_UP = "aufgeben"
    }

    /** What the stream guard advises while the picture stands (`player.streamWatchRat`). */
    object StreamWatchRat {
        const val GROUP = "player.streamWatchRat"
        const val NOT_YET = "nochNicht"
        const val NEW_CONNECT = "neuVerbinden"
    }

    /** The command names (`c`) the Media3 shell drains from the core (`engine.command`). */
    object EngineCommand {
        const val GROUP = "engine.command"
        const val LOAD = "load"
        const val PLAY = "play"
        const val PAUSE = "pause"
        const val SEEK = "seek"
        const val RATE = "rate"
        const val VOLUME = "volume"
        const val DELAY = "delay"
        const val SUBDELAY = "subdelay"
        const val AUDIO = "audio"
        const val SUB = "sub"
        const val FILL = "fill"
        const val PLACE = "place"
        const val STOP = "stop"
        const val PIP = "pip"
    }
}
