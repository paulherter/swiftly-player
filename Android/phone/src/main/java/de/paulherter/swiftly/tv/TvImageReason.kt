package de.paulherter.swiftly.tv

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import de.paulherter.swiftly.ImageColorArea
import de.paulherter.swiftly.ImageTone
import de.paulherter.swiftly.Noise
import de.paulherter.swiftly.shared.Theme

/**
 * Mirrors `ImageReason` in `Sources/tvOS/TVImageReason.swift`: tints the background of a whole page after
 * its backdrop. Insert at the very back of the page (see `TvMain.kt`: `Theme.reason` already lies behind
 * the whole app, `TvImageReason` belongs above it, under all page content).
 *
 * **The math lives in the package** (`AvComputation`, via `ImageTone` in `ImageColor.kt`): tones from the
 * image and the color at every point, brightest at the top right of the backdrop. The core samples the
 * same color that tvOS draws as `MeshGradient`, and the image is scaled up bilinearly.
 *
 * `image` is the same URL that `Backdrop(image, …)` draws.
 */
@Composable
fun TvImageReason(image: String?, modifier: Modifier = Modifier) {
    val context = LocalContext.current

    // Start value from memory, not from nothing, so this page shows the tone in the first frame when
    // another call (e.g. the home page) already knows it.
    var now by remember { mutableStateOf(image?.let { ImageTone.remembered(it) } ?: emptyList()) }
    var before by remember { mutableStateOf<List<Double>?>(null) }
    val coverage = remember { Animatable(1f) }

    // **Only something really new fades**, like `ImageReason.body` (`.task(id: url)`): if the tone is
    // already remembered it is set without animation; computed with 400 ms `easeInOut`.
    LaunchedEffect(image) {
        val remembered = image?.let { ImageTone.remembered(it) }
        val new = when {
            image == null -> emptyList()
            remembered != null -> remembered
            else -> ImageTone.tones(context, image)
        }
        if (new == now && before == null) return@LaunchedEffect
        if (remembered != null) {
            before = null; now = new; coverage.snapTo(1f)
            return@LaunchedEffect
        }
        before = now; now = new
        coverage.snapTo(0f)
        coverage.animateTo(1f, tween(400, easing = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)))
        before = null
    }

    Box(modifier.fillMaxSize()) {
        before?.let { ReasonArea(it) }
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = coverage.value }) { ReasonArea(now) }
    }
}

/**
 * The page background: `AvComputation.points` over the whole area, without falloff (`since` beyond the
 * edge), 16 x 9 points, scaled up bilinearly. Without tones plain `Theme.reason`.
 */
@Composable
private fun ReasonArea(state: List<Double>) {
    val area = remember(state) { ImageColorArea.from(state, 16, 9, 1.0, 1.0, 2.0, 0.0) }
    Canvas(Modifier.fillMaxSize()) {
        if (area == null) { drawRect(Theme.reason); return@Canvas }
        area.draw(this, size.width, size.height)
        // The last bit against banding; see `Noise`/`ImageTone.noise`.
        Noise.draw(this, size.width, size.height)
    }
}
