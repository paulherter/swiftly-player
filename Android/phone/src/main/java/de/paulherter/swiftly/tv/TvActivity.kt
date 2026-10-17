package de.paulherter.swiftly.tv

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.layer.drawLayer
import de.paulherter.swiftly.Phase
import de.paulherter.swiftly.StartCurtain
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.entrySwitch
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Theme

/**
 * Mirrors `Sources/tvOS/RootView.swift`: the same flow as on the phone, with a UI for three meters
 * of distance. Starts via `LEANBACK_LAUNCHER`; shares kernel, accounts, settings and player with
 * the phone version in the same app.
 *
 * **Second entry: a tap on a Watch Next entry** (`TvContinueWatchingShelf`) delivers the address
 * "swiftly://titel/<id>" via the intent, the same pattern as `onOpenURL` on tvOS
 * (`MainView.swift`). `singleTask` in the manifest sends such a tap into this already running
 * activity (`onNewIntent`) instead of opening a second one beside it.
 */
class TvActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Reverse of `MainActivity`: a phone arriving here (e.g. via a swiftly:// link) gets the phone
        // version.
        if (!(application as SwiftlyApplication).isTv) { entrySwitch(de.paulherter.swiftly.MainActivity::class.java); return }
        // Measure mode of the tech shield as a start extra, like `-technikschildMessen YES` on Apple.
        if (intent?.hasExtra("technikschildMessen") == true)
            (application as SwiftlyApplication).settings.techBadgeMeasure = intent.getBooleanExtra("technikschildMessen", false)
        val app = application as SwiftlyApplication
        app.deepLink.value = intent?.data
        setContent {
            var phase by remember { mutableStateOf<Phase>(if (app.sessionAgainFromSet()) Phase.Start else Phase.Server) }
            LaunchedEffect(app.signedOut.intValue) { if (app.signedOut.intValue > 0) phase = Phase.Server }
            var started by rememberSaveable { mutableStateOf(false) }
            // The screen as a recorded layer, source of the still frame for the account switch (`AccountSwitchTransition`).
            val screen = androidx.compose.ui.graphics.rememberGraphicsLayer()
            SideEffect { de.paulherter.swiftly.AccountSwitchTransition.screen = screen }
            Box(Modifier.fillMaxSize().background(Theme.reason)) {
                Box(Modifier.fillMaxSize().drawWithContent {
                    screen.record { this@drawWithContent.drawContent() }
                    drawLayer(screen)
                }) {
                when (val p = phase) {
                    // Mirrors `RootView` on tvOS: real TV pages instead of the phone pages that stood here before
                    // (`ServerPage`, `LoginPage`, `QuickConnectLogin`). See `TvLogin.kt`.
                    Phase.Server -> TvServerPage(app) { name, version -> phase = Phase.Login(name, version) }
                    is Phase.Login -> TvLoginPage(app, p.serverName, p.version,
                        otherServer = { phase = Phase.Server }) { phase = Phase.Start }
                    // Fresh after an account switch: the stacks belong to the previous account.
                    Phase.Start -> key(app.accountSwitch.intValue) { TvMain(app) }
                }
                }
                // The account switch: still frame, flying profile image, ring, above everything.
                de.paulherter.swiftly.AccountSwitchLayer()
                // "Continue watching here": the card grows out of the badge (`Handoff.kt`).
                de.paulherter.swiftly.HandoffLayer(inPlayer = false)
                // The one-time Discord notice, only once the player is closed, as in `RootView` on tvOS.
                var discordHint by remember { mutableStateOf(false) }
                LaunchedEffect(app.discordHintDue.value, app.play.value == null) {
                    if (!app.discordHintDue.value || app.play.value != null) return@LaunchedEffect
                    app.discordHintDue.value = false
                    kotlinx.coroutines.delay(1500)
                    if (app.play.value != null) { app.discordHintDue.value = true; return@LaunchedEffect }
                    discordHint = true
                }
                if (discordHint) TvDiscordHint(app.communityAddress("discordKurz")) { discordHint = false }
                AnimatedVisibility(!started, enter = EnterTransition.None, exit = fadeOut(tween(450, easing = Motion.soft))) {
                    StartCurtain { started = true }
                }
            }
        }
    }

    // Back past Compose to the callback chain (`TvBack.kt`).
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean =
        KeysLock.check(event) || (backKey(event) ?: super.dispatchKeyEvent(event))

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        (application as SwiftlyApplication).deepLink.value = intent.data
    }
}
