package de.paulherter.swiftly

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DolbyVisionNoDecoderTest {
    @Test fun profile8WithoutDecoderPlaysTheBaseLayer() {
        assertTrue(PlayerEngine.dolbyVisionBaseLayerNeeded(8, anyDecoder = false))
        assertTrue(PlayerEngine.dolbyVisionBaseLayerNeeded(4, anyDecoder = false))
    }

    @Test fun profile5And10HaveNoBaseLayerToFallBackTo() {
        assertFalse(PlayerEngine.dolbyVisionBaseLayerNeeded(5, anyDecoder = false))
        assertFalse(PlayerEngine.dolbyVisionBaseLayerNeeded(10, anyDecoder = false))
    }

    @Test fun withDecoderOrWithoutDolbyVisionNothingChanges() {
        assertFalse(PlayerEngine.dolbyVisionBaseLayerNeeded(8, anyDecoder = true))
        assertFalse(PlayerEngine.dolbyVisionBaseLayerNeeded(null, anyDecoder = false))
    }
}
