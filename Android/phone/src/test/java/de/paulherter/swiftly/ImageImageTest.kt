package de.paulherter.swiftly

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ImageImageTest {
    @Test fun handyMayIfDeviceCan() = assertTrue(imageImageAllowed(isTv = false, canImageInImage = true))
    @Test fun handyWithoutFunctionNot() = assertFalse(imageImageAllowed(isTv = false, canImageInImage = false))
    @Test fun tvNever() {
        assertFalse(imageImageAllowed(isTv = true, canImageInImage = true))
        assertFalse(imageImageAllowed(isTv = true, canImageInImage = false))
    }
}
