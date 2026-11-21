package de.paulherter.swiftly

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import de.paulherter.swiftly.shared.smoothRoundedShape

/**
 * The app icon as the first-start and sign-in pages show it above their question (`AppIconMark` on Apple).
 *
 * The shipped launcher icon's own two layers (`ic_launcher_background`, `ic_launcher_foreground`), never redrawn.
 * An adaptive icon is a 108 dp box of which the launcher shows the inner 72 dp (`ic_launcher_foreground`), so the layers
 * are drawn 1.5 times the size of the mark and cropped to it: the same picture the home screen shows, and the mark as
 * large in the icon as on Apple. The layers have square corners; the rounding is applied here, [EMBLEM_CORNER] of the
 * height like `Mark.emblemCorner` on Apple.
 */
@Composable
fun AppIconMark(height: Dp, modifier: Modifier = Modifier) {
    Box(modifier.size(height).clip(smoothRoundedShape(height * EMBLEM_CORNER))) {
        Box(Modifier.align(Alignment.Center).requiredSize(height * ADAPTIVE_BOX / ADAPTIVE_VISIBLE)) {
            Image(painterResource(R.drawable.ic_launcher_background), null, Modifier.size(height * ADAPTIVE_BOX / ADAPTIVE_VISIBLE))
            Image(painterResource(R.drawable.ic_launcher_foreground), "Swiftly", Modifier.size(height * ADAPTIVE_BOX / ADAPTIVE_VISIBLE))
        }
    }
}

private const val EMBLEM_CORNER = 230f / 1024f
private const val ADAPTIVE_BOX = 108f
private const val ADAPTIVE_VISIBLE = 72f
