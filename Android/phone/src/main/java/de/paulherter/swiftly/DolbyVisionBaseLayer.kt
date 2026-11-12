package de.paulherter.swiftly

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.ExtractorsFactory
import androidx.media3.extractor.ForwardingExtractor
import androidx.media3.extractor.TrackOutput

/**
 * **Plays the HEVC base layer of a Dolby Vision track as plain HEVC (HDR10).**
 *
 * Media3 falls back from a Dolby Vision decoder to an HEVC one only for profiles 4 and 8 (and 9 to AVC); a profile 7
 * (dual layer, the Blu-ray remuxes) has no such fallback, so a device without a profile 7 decoder gets sound and no
 * picture at all. The base layer of every profile except 5 is ordinary HEVC, so while `off()` says so, the video
 * track of the file is announced to Media3 as `video/hevc`. Profile 5 has no HDR10 base layer and is left alone.
 */
@UnstableApi
class DolbyVisionBaseLayerExtractors(private val off: () -> Boolean, private val cues: SubtitleCueTable? = null) : ExtractorsFactory {
    private val delegate = DefaultExtractorsFactory()

    override fun createExtractors(): Array<Extractor> = wrap(delegate.createExtractors())

    override fun createExtractors(uri: Uri, responseHeaders: Map<String, List<String>>): Array<Extractor> =
        wrap(delegate.createExtractors(uri, responseHeaders))

    private fun wrap(all: Array<Extractor>): Array<Extractor> = Array(all.size) { Base(all[it], off, cues) }

    private class Base(private val inner: Extractor, private val off: () -> Boolean, private val cues: SubtitleCueTable?) : ForwardingExtractor(inner) {
        override fun init(output: ExtractorOutput) {
            inner.init(object : ExtractorOutput by output {
                override fun track(id: Int, type: Int): TrackOutput {
                    val real = output.track(id, type)
                    // Text arrives here already parsed (`application/x-media3-cues`), one sample per cue with its real time.
                    if (type == C.TRACK_TYPE_TEXT && cues != null) return CueTap(real, cues)
                    return object : TrackOutput by real {
                        override fun format(format: Format) {
                            real.format(if (off()) baseLayerOf(format) else format)
                        }
                    }
                }
            })
        }
    }

    companion object {
        /** `dvhe.05` (profile 5) has no base layer; every other Dolby Vision video format is HEVC (or AVC for profile 9) underneath. */
        fun baseLayerOf(format: Format): Format {
            if (format.sampleMimeType != MimeTypes.VIDEO_DOLBY_VISION) return format
            val codecs = format.codecs.orEmpty()
            return when {
                codecs.startsWith("dvhe.05") || codecs.startsWith("dvh1.05") -> format
                codecs.startsWith("dvav") || codecs.startsWith("dva1") ->
                    format.buildUpon().setSampleMimeType(MimeTypes.VIDEO_H264).setCodecs(null).build()
                else -> format.buildUpon().setSampleMimeType(MimeTypes.VIDEO_H265).setCodecs(null).build()
            }
        }
    }
}
