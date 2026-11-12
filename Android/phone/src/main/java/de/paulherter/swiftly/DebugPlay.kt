package de.paulherter.swiftly

import android.content.Intent

/**
 * Debug builds only (callers check `BuildConfig.DEBUG`): launch extras the live runner (`Werkzeuge/android-live.py`) uses to
 * drive the real player without taps. `testSince` = resume seconds, `testSubtitle` = index in the subtitle track list (`-1` off),
 * `testPauseAt` = seconds to seek to and pause at once the tracks are applied, `testNext` = go to the next episode once.
 */
object DebugPlay {
    @Volatile var since: Double? = null
    @Volatile var subtitle: Int? = null
    @Volatile var pauseAt: Double? = null
    @Volatile var next: Boolean = false

    fun read(intent: Intent?) {
        since = intent?.getStringExtra("testSince")?.toDoubleOrNull()
        subtitle = intent?.getStringExtra("testSubtitle")?.toIntOrNull()
        pauseAt = intent?.getStringExtra("testPauseAt")?.toDoubleOrNull()
        next = intent?.getStringExtra("testNext") == "1"
    }
}
