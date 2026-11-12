package de.paulherter.swiftly

import org.junit.Assert.assertEquals
import org.junit.Test

/** Contract line 8a: 16 dp above the picture's bottom edge, raised adds 7 % of the picture height. */
class SubtitleMarginTest {
    @Test fun baseIsSixteenDp() = assertEquals(16f * 2.625f, SubtitleMargin.px(1080, 2.625f, raised = false), 0.001f)

    @Test fun raisedAddsSevenPercentOfThePicture() = assertEquals(16f * 2f + 0.07f * 1000f, SubtitleMargin.px(1000, 2f, raised = true), 0.001f)

    @Test fun letterboxedPictureUsesItsOwnHeight() = assertEquals(16f + 0.07f * 400f, SubtitleMargin.px(400, 1f, raised = true), 0.001f)
}
