package de.paulherter.swiftly

import android.content.Intent

/**
 * Debug builds only (callers check `BuildConfig.DEBUG`): launch extras the live runner (`Werkzeuge/android-live.py`) uses to
 * drive the real player without taps. `testSince` = resume seconds, `testSubtitle` = index in the subtitle track list (`-1` off),
 * `testPauseAt` = seconds to seek to and pause at once the tracks are applied, `testNext` = go to the next episode once,
 * `testReload` = `quality` (the replan the quality menu triggers) or `subtitle` (the first subtitle track, as picked in the menu) once, after
 * the pause step, then the state four seconds later (`[Test] nach ...` in the log).
 */
object DebugPlay {
    @Volatile var since: Double? = null
    @Volatile var subtitle: Int? = null
    @Volatile var pauseAt: Double? = null
    @Volatile var next: Boolean = false
    @Volatile var reload: String? = null

    fun read(intent: Intent?) {
        since = intent?.getStringExtra("testSince")?.toDoubleOrNull()
        subtitle = intent?.getStringExtra("testSubtitle")?.toIntOrNull()
        pauseAt = intent?.getStringExtra("testPauseAt")?.toDoubleOrNull()
        next = intent?.getStringExtra("testNext") == "1"
        reload = intent?.getStringExtra("testReload")
    }
}
