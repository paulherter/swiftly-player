package de.paulherter.swiftly

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import android.app.PictureInPictureParams
import de.paulherter.swiftly.tv.backKey
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.view.WindowManager
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import android.content.res.Configuration
import android.os.Bundle
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.Lifecycle

/**
 * The player in its own activity, in the app's task so it sits on top.
 *
 * On iOS the small window keeps running while you browse the app. On Android picture-in-picture
 * is a whole activity: with the player in the main activity, the whole app would shrink into the
 * window. With its own task the app stays usable next to it.
 *
 * Only this activity rotates to landscape, and it is not recreated for that (`configChanges`).
 * Before, rotation recreated the main activity and opened the title twice.
 *
 * Leaving puts it into the small window instead of only offering a button as iOS does: Android
 * does not reliably keep playing in the background without a foreground service. If the window is
 * swiped away, playback ends; the player reports "stopped".
 */
class PlayerActivity : ComponentActivity() {
    private val smallWindow = mutableStateOf(false)
    private val wish = mutableStateOf<PlayRequest?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = androidx.activity.SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = androidx.activity.SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
        )
        val app = application as SwiftlyApplication
        // The player cross-fades instead of sliding (mirrors iOS `PlayerFrame`: `.crossDissolve`, 0.3 s).
        // Sliding came from the bottom in landscape and from the side in portrait; a fade has no
        // direction. The app below does not move. Same fade on TV.
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            overrideActivityTransition(OVERRIDE_TRANSITION_OPEN, if (Handoff.arrival != null) R.anim.hold else R.anim.player_enter, R.anim.hold)
            overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, R.anim.hold, R.anim.player_exit)
        }
        if (!app.isTv) {
            // Landscape before the first frame, and only the player. The orientation is in the manifest
            // (`sensorLandscape`) so the system knows it at launch and the app behind stays portrait.
            // Setting it in `PlayerPage` on first composition made the player open in portrait and
            // rotate afterwards, and rotate again on close when restoring. Only users who turned the
            // rotation lock off may also use portrait.
            if (!app.settings.landscapeFixed) requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_USER
            // No system bars and screen kept on while this activity lives. Nothing is restored on close:
            // the window goes with it, and showing the bars again would only flash.
            WindowCompat.getInsetsController(window, window.decorView).apply {
                systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                hide(WindowInsetsCompat.Type.systemBars())
            }
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        wish.value = app.play.value ?: againRecord(app, savedInstanceState) ?: run { finish(); return }
        // Enter the small window with the gesture, not after. Swiping up first sent the activity to the
        // background; Android then tore down the video surface and the small window stayed black,
        // even after bringing it back. From Android 12 the system shrinks it itself.
        // Never on TV: screensaver and Home send the activity to the background without anyone
        // leaving the player; with auto-enter the picture kept running as a window over the
        // screensaver, and closing it ended the player (see `onPictureInPictureModeChanged`).
        if (android.os.Build.VERSION.SDK_INT >= 31 && imageImageAllowed(app.isTv, packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE))) {
            runCatching { setPictureInPictureParams(PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).setAutoEnterEnabled(true).build()) }
        }
        setContent {
            // The tile menu needs its own holder here: the player runs in its own activity, so
            // `LocalTileMenu` from `MainScreen` does not reach over. Without it
            // `LocalTileMenu.current` would be `null` and a long press on an episode in the player
            // episode list would do nothing.
            var tileMenu by remember { mutableStateOf<TileMenuRequest?>(null) }
            // TV: the tile menu hangs on `app.sheet` (`tileMenuPanel`), which `TvPanel` below already
            // draws. Phone: own holder, drawn by `TileMenuStatus`.
            fun tileMenuOpen(w: TileMenuRequest) {
                if (app.isTv) tileMenuPanel(app, w) {} else tileMenu = w
            }
            CompositionLocalProvider(LocalTileMenu provides ::tileMenuOpen) {
            Box(Modifier.fillMaxSize().background(Color.Black)) {
                wish.value?.let { w ->
                    // A new request (from the app while the small window runs) rebuilds the player.
                    // TV gets its own player (`tv/TvPlayer.kt`, mirrors tvOS `PlayerScreen.swift`) instead of
                    // the phone player: no picture-in-picture, remote instead of touch. Both share the
                    // mechanics in `PlayItem`.
                    key(w) {
                        if (app.isTv) de.paulherter.swiftly.tv.TvPlayer(app, w) { finish() }
                        else PlayerPage(app, w, smallWindow.value, ::imageImage) { finish() }
                    }
                }
                if (!smallWindow.value) if (app.isTv) de.paulherter.swiftly.tv.TvPanel(app) else SheetStatus(app)
                // "Continue here": the card above everything, also above the player (`Handoff.kt`).
                if (!smallWindow.value) HandoffLayer(inPlayer = true)
                // Phone: the same tile menu as everywhere else, above everything. TV needs no holder of its own:
                // `tileMenuPanel` hangs on `app.sheet`, which `TvPanel` above already draws.
                // `open`: never reached in the player, whose episode list only shows
                // "watched"/"unwatched" (`TileMenuRequest.inPlayer`), no "Go to overview".
                if (!app.isTv && !smallWindow.value) TileMenuStatus(app, tileMenu, {}) { tileMenu = null }
            }
            }
        }
    }

    /**
     * After the process was killed, Android rebuilds this activity from its saved state and
     * `app.play` is empty. It used to finish immediately, leaving the user on the home screen with
     * no explanation. Now it resumes the title at the last known position. The session is otherwise
     * set by the main activity, which is not underneath yet.
     */
    private fun againRecord(app: SwiftlyApplication, condition: Bundle?): PlayRequest? {
        val id = condition?.getString(PLAY_ID) ?: return null
        if (!app.sessionAgainFromSet() && app.downloads.file(id) == null) return null
        val w = PlayRequest(id, condition.getDouble(PLAY_OFF, 0.0).takeIf { it > 1 }, condition.getString(PLAY_SOURCE).orEmpty())
        app.playHandOver = w
        app.play.value = w
        AppLog.writeOut("Player nach Prozessende wieder aufgenommen")
        return w
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        val app = application as SwiftlyApplication
        (app.playPoint?.takeIf { app.play.value != null } ?: app.play.value)?.let {
            outState.putString(PLAY_ID, it.id)
            it.since?.let { since -> outState.putDouble(PLAY_OFF, since) }
            if (it.sourceID.isNotEmpty()) outState.putString(PLAY_SOURCE, it.sourceID)
        }
    }

    override fun finish() {
        super.finish()
        if (android.os.Build.VERSION.SDK_INT < 34) {
            @Suppress("DEPRECATION")
            overridePendingTransition(R.anim.hold, R.anim.player_exit)
        }
    }

    // On TV, send Back past Compose to the callback chain (`tv/TvBack.kt`); otherwise an open
    // layer swallowed the key before Android 13.
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean =
        if ((application as SwiftlyApplication).isTv)
            de.paulherter.swiftly.tv.KeysLock.check(event) || (backKey(event) ?: super.dispatchKeyEvent(event))
        else super.dispatchKeyEvent(event)

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        (application as SwiftlyApplication).play.value?.let { wish.value = it }
    }

    /** `false` if the device has no picture-in-picture. */
    fun imageImage(): Boolean {
        if (!imageImageAllowed((application as SwiftlyApplication).isTv, packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE))) return false
        return runCatching { enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build()) }
            .getOrDefault(false)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Before Android 12 there is no automatic shrinking, so the hint stays on leaving. Never on TV
        // (`imageImage` checks): the screensaver may only pause the player.
        if (!isFinishing && android.os.Build.VERSION.SDK_INT < 31) imageImage()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        smallWindow.value = isInPictureInPictureMode
        (application as SwiftlyApplication).smallWindow.value = isInPictureInPictureMode
        // Out of the small window without the activity coming back to the front: swiped away.
        if (!isInPictureInPictureMode && !lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) finish()
    }

    override fun onDestroy() {
        super.onDestroy()
        if (isFinishing) (application as SwiftlyApplication).let { it.play.value = null; it.playHandOver = null; it.playPoint = null }
        (application as SwiftlyApplication).smallWindow.value = false
    }
}

/** May the player enter the small window? Only on phones, and only if the device supports it. */
internal fun imageImageAllowed(isTv: Boolean, canImageInImage: Boolean): Boolean = !isTv && canImageInImage

private const val PLAY_ID = "spiel.id"
private const val PLAY_OFF = "spiel.ab"
private const val PLAY_SOURCE = "spiel.fassung"

/**
 * As on iOS: while the film runs in the small window, the app below shows where it is, not itself.
 * Before, the whole app stood there to use and the film seemed to have disappeared. A tap brings
 * it back to full size.
 */
@androidx.compose.runtime.Composable
fun ImageImageHint(retrieve: () -> Unit) {
    Box(Modifier.fillMaxSize().background(de.paulherter.swiftly.shared.Theme.reason).onTap(retrieve),
        contentAlignment = androidx.compose.ui.Alignment.Center) {
        androidx.compose.foundation.layout.Column(horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally,
            verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(14.dp)) {
            Symbol(Glyph.ImageInImage, 30.dp, color = de.paulherter.swiftly.shared.Theme.fontVeryQuiet, strength = Strength.Medium)
            androidx.compose.material3.Text(de.paulherter.swiftly.shared.translated("Dieses Video wird im Bild-im-Bild wiedergegeben."),
                style = de.paulherter.swiftly.shared.Theme.body, color = de.paulherter.swiftly.shared.Theme.fontQuiet,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.padding(horizontal = 40.dp))
        }
    }
}
