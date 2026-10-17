package de.paulherter.swiftly.tv

import android.view.KeyEvent
import androidx.activity.ComponentActivity

/**
 * **On TV the Back key goes straight to the `OnBackPressedDispatcher`**, bypassing Compose.
 *
 * Compose interprets an unconsumed Back as the focus direction "Exit". In a focus group with
 * `exit = Cancel` (player layers, season picker, sheets) the press then counts as consumed. Before
 * Android 13 (Fire OS 7/8, older Android TV devices) it never reaches `onKeyDown`, the activity does
 * not track the key, and no `BackHandler` fires: the layer could not be closed. From Android 13 the
 * system calls the callback chain itself; here all versions get the same path. The on-screen keyboard
 * sees the key earlier (pre-IME) and still closes itself.
 *
 * `null`: no Back key, pass on normally.
 */
internal fun ComponentActivity.backKey(e: KeyEvent): Boolean? {
    if (e.keyCode != KeyEvent.KEYCODE_BACK) return null
    if (e.action == KeyEvent.ACTION_UP && !e.isCanceled) onBackPressedDispatcher.onBackPressed()
    return true
}

/**
 * **After a long press the rest of that press belongs to nobody.** Long OK opens the tile menu and
 * focus jumps into the sheet, but the remote keeps sending: repeats (KeyDown with `repeatCount > 0`)
 * and finally the KeyUp. These reached the sheet's first row, which took them as a click ("Mark as
 * watched"); the sheet closed, focus went back to the tile, and the next repeats triggered there and
 * in the player, which then jumped through the layers by itself. Now the activity consumes everything
 * from a key that was held for a long press, until it is released.
 *
 * `check` runs in `dispatchKeyEvent` before Compose; `afterLongPress` calls `FocusArea`.
 */
internal object KeysLock {
    private val bottom = HashSet<Int>()
    private val locked = HashSet<Int>()

    fun afterLongPress() { locked.addAll(bottom) }

    /** `true`: consumed, do not pass on. */
    fun check(e: KeyEvent): Boolean {
        val code = e.keyCode
        return when (e.action) {
            KeyEvent.ACTION_DOWN -> {
                if (e.repeatCount == 0) { bottom.add(code); locked.remove(code); false }
                else code in locked
            }
            KeyEvent.ACTION_UP -> { bottom.remove(code); locked.remove(code) }
            else -> false
        }
    }
}
