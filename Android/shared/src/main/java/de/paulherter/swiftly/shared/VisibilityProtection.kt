package de.paulherter.swiftly.shared

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.Window
import android.view.WindowManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalContext
import java.util.WeakHashMap

/**
 * Screen protection while a secret field is visible (password, header value).
 *
 * Sets `FLAG_SECURE` on the activity window: the app switcher thumbnail stays blank, and
 * screenshots and recordings do not show the mask. Only while the field is attached; the player
 * is in its own activity and untouched, as is picture-in-picture. Several fields on one page
 * count; only the last one clears the flag. Mirrors the sign-in protection on iOS.
 */
@Composable
fun VisibilityProtection() {
    val window = LocalContext.current.activityWindow() ?: return
    DisposableEffect(window) {
        val n = (lockOut[window] ?: 0) + 1
        lockOut[window] = n
        if (n == 1) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        onDispose {
            val rest = (lockOut[window] ?: 1) - 1
            if (rest <= 0) {
                lockOut.remove(window)
                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            } else lockOut[window] = rest
        }
    }
}

private val lockOut = WeakHashMap<Window, Int>()

private tailrec fun Context.activityWindow(): Window? = when (this) {
    is Activity -> window
    is ContextWrapper -> baseContext.activityWindow()
    else -> null
}
