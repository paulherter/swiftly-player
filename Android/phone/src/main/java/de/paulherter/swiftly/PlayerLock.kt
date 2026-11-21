package de.paulherter.swiftly

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull

/**
 * **"Bildschirm sperren"**: counterpart to `ScreenLockOverlay` in `Sources/iOS/PlayerMenus.swift`. Swallows every
 * touch; a tap shows for two seconds how to unlock, holding for 0.6 s unlocks. Back is swallowed too.
 */
@Composable
fun PlayerLockOverlay(unlock: () -> Unit, modifier: Modifier = Modifier) {
    // Counts taps; the hint shows for two seconds after the last one.
    var taps by remember { mutableIntStateOf(0) }
    var hint by remember { androidx.compose.runtime.mutableStateOf(false) }
    val jerk = rememberJerk()
    LaunchedEffect(taps) { if (taps > 0) { hint = true; delay(2000); hint = false } }
    BackHandler(enabled = true) { taps++ }
    val gesturesText = translated("Zum Entsperren gedrückt halten")
    Box(modifier.fillMaxSize()
        .pointerInput(Unit) {
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false)
                down.consume()
                val started = System.nanoTime()
                val up = withTimeoutOrNull(600L) { waitForUpOrCancellation() }
                if (up == null && System.nanoTime() - started >= 590_000_000L) { jerk(Jerk.Success); unlock() }
                else if (up != null) { up.consume(); taps++ }
            }
        }
        .semantics {
            contentDescription = translated("Bildschirm gesperrt") + ". " + gesturesText
            customActions = listOf(CustomAccessibilityAction(translated("Entsperren")) { unlock(); true })
        }) {
        AnimatedVisibility(hint, Modifier.align(Alignment.Center), enter = fadeIn(tween(150)), exit = fadeOut(tween(200))) {
            Row(Modifier.height(40.dp).clip(CircleShape).background(Theme.raised).padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Symbol(Glyph.Padlock, 14.dp, color = Theme.font, strength = Strength.Semibold)
                Text(gesturesText, style = Theme.listTitle, color = Theme.font, maxLines = 1)
            }
        }
    }
}
