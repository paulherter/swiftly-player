package de.paulherter.swiftly

import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.withFrameNanos
import kotlinx.coroutines.launch
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.airbnb.lottie.compose.LottieAnimation
import com.airbnb.lottie.compose.LottieCompositionSpec
import com.airbnb.lottie.compose.rememberLottieComposition
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.motionReduced
import kotlinx.coroutines.delay
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Mirrors `StartCurtain` + `StartAnimation` in `Sources/Shared/StartAnimation.swift`: the same
 * Lottie file, played once, size 440.
 *
 * **Half a beat of run-on** before the curtain falls, otherwise the mark looks merely passed
 * through. If the end never arrives (the app was in the background), it falls after 3.5 seconds at
 * the latest. Both paths go through a latch, so `done` is never called twice.
 *
 * **Frame by frame instead of by the clock.** `animateLottieCompositionAsState` computes progress
 * from elapsed time. Under the curtain the whole app is built at the same time (load core, session,
 * first page), and every long frame skipped a piece of the 1.3 seconds: the triangle jerked, the
 * letters were already half there, or only the end was visible. Now each frame advances by at most
 * a thirtieth: a hitch slows the animation briefly instead of cutting it. The 3.5 second limit
 * starts at the animation's first frame (a slow file load used to cut it off); if the file is not
 * there at all, the curtain falls after the same limit.
 */
@Composable
fun StartCurtain(done: () -> Unit) {
    val composition by rememberLottieComposition(LottieCompositionSpec.Asset("startanimation.json"))
    var progress by remember { mutableFloatStateOf(0f) }
    val inTimes = remember { AtomicBoolean(false) }
    val callOut = { if (inTimes.compareAndSet(false, true)) done() }
    // Lottie does not know "remove animations": then the curtain falls at once.
    val calm = motionReduced()
    LaunchedEffect(calm) { if (calm) callOut() }
    LaunchedEffect(composition) {
        val k = composition
        if (k == null) { delay(3500); if (composition == null) callOut(); return@LaunchedEffect }
        val duration = k.duration.coerceAtLeast(1f)
        launch { delay(3500); callOut() }
        var recent = withFrameNanos { it }
        while (progress < 1f) {
            val now = withFrameNanos { it }
            val step = ((now - recent) / 1_000_000f).coerceIn(0f, 1000f / 30f)
            recent = now
            progress = (progress + step / duration).coerceAtMost(1f)
        }
        delay(500)
        callOut()
    }
    Box(Modifier.fillMaxSize().background(Theme.reason), contentAlignment = Alignment.Center) {
        // The curtain says who is starting, otherwise TalkBack would sit up to 3.5 s in front of a silent surface.
        LottieAnimation(composition, { progress }, Modifier.size(440.dp).clearAndSetSemantics { contentDescription = "Swiftly" })
    }
}
