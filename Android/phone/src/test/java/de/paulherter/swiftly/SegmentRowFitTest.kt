package de.paulherter.swiftly

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** "Outline" must never wrap beside a 212 dp strip on a 360 dp phone; it moves the strip below instead. */
class SegmentRowFitTest {
    @Test fun aTitleThatDoesNotFitStacks() = assertTrue(SegmentRowFit.stacks(64.dp, 354.dp, 212.dp))
    @Test fun aShortTitleStaysBeside() = assertFalse(SegmentRowFit.stacks(40.dp, 354.dp, 182.dp))
}
