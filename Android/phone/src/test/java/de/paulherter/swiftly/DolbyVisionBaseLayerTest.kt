package de.paulherter.swiftly

import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import org.junit.Assert.assertEquals
import org.junit.Test

@UnstableApi
class DolbyVisionBaseLayerTest {
    private fun dv(codecs: String) = Format.Builder().setSampleMimeType(MimeTypes.VIDEO_DOLBY_VISION).setCodecs(codecs).build()

    @Test fun profile7BecomesPlainHevc() {
        assertEquals(MimeTypes.VIDEO_H265, DolbyVisionBaseLayerExtractors.baseLayerOf(dv("dvhe.07.06")).sampleMimeType)
        assertEquals(MimeTypes.VIDEO_H265, DolbyVisionBaseLayerExtractors.baseLayerOf(dv("dvh1.08.03")).sampleMimeType)
    }

    @Test fun profile5HasNoBaseLayerAndStays() {
        assertEquals(MimeTypes.VIDEO_DOLBY_VISION, DolbyVisionBaseLayerExtractors.baseLayerOf(dv("dvhe.05.06")).sampleMimeType)
    }

    @Test fun profile9BecomesAvc() {
        assertEquals(MimeTypes.VIDEO_H264, DolbyVisionBaseLayerExtractors.baseLayerOf(dv("dvav.09.03")).sampleMimeType)
    }

    @Test fun otherFormatsAreUntouched() {
        val hevc = Format.Builder().setSampleMimeType(MimeTypes.VIDEO_H265).build()
        assertEquals(hevc, DolbyVisionBaseLayerExtractors.baseLayerOf(hevc))
    }
}
