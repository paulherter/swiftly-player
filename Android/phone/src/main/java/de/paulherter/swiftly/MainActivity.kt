package de.paulherter.swiftly

import android.os.Bundle
import com.google.android.play.core.ktx.launchReview
import com.google.android.play.core.ktx.requestReview
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.layer.drawLayer
import de.paulherter.swiftly.shared.Theme

/** Mirrors `RootView` in Shared: server, sign-in, then the app. */
sealed interface Phase {
    data object Server : Phase
    data class Login(val serverName: String, val version: String) : Phase
    data object Start : Phase
}

/**
 * Forwards the launch to the right entry activity (phone or TV) and finishes the current one
 * before it draws anything. Action, categories, URI and extras travel along.
 */
internal fun ComponentActivity.entrySwitch(target: Class<*>) {
    android.util.Log.i("Swiftly", "Einstieg: ${javaClass.simpleName} -> ${target.simpleName}")
    startActivity(android.content.Intent(intent).setClass(this, target)
        .addFlags(android.content.Intent.FLAG_ACTIVITY_NO_ANIMATION))
    finish()
    @Suppress("DEPRECATION") overridePendingTransition(0, 0)
}

class MainActivity : ComponentActivity() {
    /** Back in front: ask the store again (a purchase may have finished elsewhere, or been refunded). */
    override fun onResume() {
        super.onResume()
        (application as SwiftlyApplication).support.channel.refresh()
    }

    /** The own call for the notification prompt; on teardown remove it only if it is still the current one. */
    private var messageRightCall: (() -> Unit)? = null

    override fun onDestroy() {
        val app = application as SwiftlyApplication
        if (app.messageRightAsk === messageRightCall) app.messageRightAsk = null
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // On TV continue straight into the TV UI. The normal launcher entry (e.g. "Open" after installing
        // from the store) otherwise lands here, in the phone version; only the Leanback launcher opened
        // `TvActivity`. Before the first frame, without a transition.
        if ((application as SwiftlyApplication).isTv) { entrySwitch(de.paulherter.swiftly.tv.TvActivity::class.java); return }
        // Measurement mode as a launch extra, like the launch argument on Apple.
        if (intent?.hasExtra("technikschildMessen") == true)
            (application as SwiftlyApplication).settings.techBadgeMeasure = intent.getBooleanExtra("technikschildMessen", false)
        // Always light status bar icons: the app is dark whatever the system setting is. Without a
        // default, `enableEdgeToEdge` follows the system theme, and on a light theme clock and
        // battery were black on black.
        enableEdgeToEdge(
            statusBarStyle = androidx.activity.SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = androidx.activity.SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
        )
        val app = application as SwiftlyApplication
        // The first download asks for the notification permission (`SwiftlyApplication.messageRightAsk`);
        // nobody needs the answer: if denied, downloads just run without a notification.
        val messageRight = registerForActivityResult(androidx.activity.result.contract.ActivityResultContracts.RequestPermission()) {}
        val ask = { if (android.os.Build.VERSION.SDK_INT >= 33) messageRight.launch(android.Manifest.permission.POST_NOTIFICATIONS) }
        app.messageRightAsk = ask
        messageRightCall = ask
        // On the phone the app stays portrait, only the player is landscape (mirrors iPhone `Orientierung`:
        // `.portrait`, the player allows landscape itself). Otherwise the app stayed landscape after
        // closing when the phone was held that way. Tablets rotate freely, like the iPad.
        if (resources.configuration.smallestScreenWidthDp < 600 && !app.isTv) {
            requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
        setContent {
            var phase by remember { mutableStateOf<Phase>(if (app.sessionAgainFromSet()) Phase.Start else Phase.Server) }
            // Only after the player, with a short delay, as in `RootView`: the prompt comes when someone
            // has just finished watching, not in the middle of playback.
            androidx.compose.runtime.LaunchedEffect(app.ratingDue.value, app.play.value == null) {
                if (!app.ratingDue.value || app.play.value != null) return@LaunchedEffect
                app.ratingDue.value = false
                kotlinx.coroutines.delay(1500)
                runCatching {
                    val handler = com.google.android.play.core.review.ReviewManagerFactory.create(this@MainActivity)
                    val job = handler.requestReview()
                    handler.launchReview(this@MainActivity, job)
                }
            }
            // The one-time hint, same delay, same "only after the player".
            androidx.compose.runtime.LaunchedEffect(app.discordHintDue.value, app.play.value == null) {
                if (!app.discordHintDue.value || app.play.value != null) return@LaunchedEffect
                app.discordHintDue.value = false
                kotlinx.coroutines.delay(1500)
                if (app.play.value != null) { app.discordHintDue.value = true; return@LaunchedEffect }
                discordHintShow(app, this@MainActivity)
            }
            // Signed out: back to server selection.
            androidx.compose.runtime.LaunchedEffect(app.signedOut.intValue) { if (app.signedOut.intValue > 0) phase = Phase.Server }
            // Once per launch, not per rotation, hence remembered.
            var started by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
            // The screen as a recorded layer: the account switch takes its freeze frame from it
            // (`AccountSwitchTransition`) without a second draw pass.
            val screen = androidx.compose.ui.graphics.rememberGraphicsLayer()
            androidx.compose.runtime.SideEffect { AccountSwitchTransition.screen = screen }
            Box(Modifier.fillMaxSize().background(Theme.reason)) {
                Box(Modifier.fillMaxSize().drawWithContent {
                    screen.record { this@drawWithContent.drawContent() }
                    drawLayer(screen)
                }) {
                when (val p = phase) {
                    Phase.Server -> ServerPage(app) { name, version -> phase = Phase.Login(name, version) }
                    is Phase.Login -> LoginPage(app, p.serverName, p.version,
                        otherServer = { phase = Phase.Server }) { phase = Phase.Start }
                    // Fresh after an account switch: stack, sections and pages belong to the previous account.
                    Phase.Start -> androidx.compose.runtime.key(app.accountSwitch.intValue) { MainScreen(app) }
                }
                }
                // The account switch: freeze frame, flying profile picture, ring, above everything.
                AccountSwitchLayer()
                // "Continue here": the card grows out of the badge (`Handoff.kt`).
                HandoffLayer(inPlayer = false)
                if (app.smallWindow.value) ImageImageHint {
                    startActivity(android.content.Intent(this@MainActivity, PlayerActivity::class.java))
                }
                // The curtain falls as a pure cross-fade, 0.45 s: no sliding, no growing.
                androidx.compose.animation.AnimatedVisibility(!started,
                    enter = androidx.compose.animation.EnterTransition.None,
                    exit = androidx.compose.animation.fadeOut(androidx.compose.animation.core.tween(450, easing = de.paulherter.swiftly.shared.Motion.soft))) {
                    StartCurtain { started = true }
                }
            }
        }
    }
}
