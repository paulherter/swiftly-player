package de.paulherter.swiftly

import org.junit.Assert.assertNotNull
import org.junit.Test

/** A server transcode arrives as an HLS playlist: Media3 plays it only with its HLS module on the class path. */
class HlsSupportTest {
    @Test
    fun media3HlsModuleIsBundled() {
        assertNotNull(Class.forName("androidx.media3.exoplayer.hls.HlsMediaSource"))
    }
}
