package de.paulherter.swiftly

import androidx.media3.common.Format
import androidx.media3.common.text.Cue
import androidx.media3.common.util.Consumer
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ParsableByteArray
import androidx.media3.extractor.TrackOutput
import androidx.media3.extractor.text.CueDecoder
import androidx.media3.extractor.text.CuesWithTiming
import androidx.media3.extractor.text.DefaultSubtitleParserFactory
import androidx.media3.extractor.text.SubtitleParser
import java.util.concurrent.ConcurrentHashMap

/**
 * The cue list of every parsed text track, kept next to Media3.
 *
 * Media3 hands cues out only as its text renderer reads them. After a forward seek into a cue that began before the
 * target (and was not buffered), nothing reached the renderer, so a paused jump showed no text until play (contract
 * line 14). [activeAt] answers "what is on screen at this position" from the list, so the player can draw it until
 * Media3 delivers cues again.
 */
@UnstableApi
class SubtitleCueTable {
    private val byTrack = ConcurrentHashMap<String, List<CuesWithTiming>>()

    /**
     * Adds `cues` to what the track already has. An external file arrives as one parse with every cue; an embedded track
     * (Matroska, MP4) is parsed one sample at a time as it is read, and reading a sample again after a seek must not
     * list its text twice.
     */
    internal fun publish(trackId: String?, cues: List<CuesWithTiming>) {
        if (trackId == null) return
        byTrack.compute(trackId) { _, old ->
            val known = old.orEmpty()
            val fresh = cues.filter { c -> known.none { it.startTimeUs == c.startTimeUs && it.endTimeUs == c.endTimeUs && it.cues.map(::same) == c.cues.map(::same) } }
            if (fresh.isEmpty()) old else (known + fresh).sortedBy { it.startTimeUs }
        }
    }

    /** What makes two cues the same one (`Cue.equals` is not usable in plain JVM tests). */
    private fun same(c: Cue): Pair<String?, Boolean> = c.text?.toString() to (c.bitmap != null)

    fun clear() = byTrack.clear()

    /** Text cues that are active at `positionUs` in the track `trackId` (empty when unknown or between cues). */
    fun activeAt(trackId: String?, positionUs: Long): List<Cue> {
        // The selected track's format id carries the container prefix (`1:datei:2`); the parser saw `datei:2`.
        val id = trackId ?: return emptyList()
        val all = byTrack[id] ?: byTrack.entries.firstOrNull { id.endsWith(":" + it.key) }?.value ?: return emptyList()
        return all.filter { it.startTimeUs <= positionUs && positionUs < it.endTimeUs }.flatMap { it.cues }
    }
}

/** Wraps Media3's parsers: the cue list goes to [table] while the parse runs as usual. */
@UnstableApi
class RecordingSubtitleParsers(
    private val table: SubtitleCueTable,
    private val inner: SubtitleParser.Factory = DefaultSubtitleParserFactory(),
) : SubtitleParser.Factory {
    override fun supportsFormat(format: Format): Boolean = inner.supportsFormat(format)
    override fun getCueReplacementBehavior(format: Format): Int = inner.getCueReplacementBehavior(format)
    override fun create(format: Format): SubtitleParser = Recording(inner.create(format), inner.create(format), format.id, table)

    /** `parser` answers Media3 exactly as before; `recorder` (a second instance) parses the same bytes for the full list. */
    private class Recording(
        private val parser: SubtitleParser, private val recorder: SubtitleParser,
        private val id: String?, private val table: SubtitleCueTable,
    ) : SubtitleParser by parser {
        override fun parse(data: ByteArray, offset: Int, length: Int, outputOptions: SubtitleParser.OutputOptions, output: Consumer<CuesWithTiming>) {
            val seen = ArrayList<CuesWithTiming>()
            runCatching { recorder.parse(data, offset, length, SubtitleParser.OutputOptions.allCues(), Consumer { seen += it }) }
            if (seen.isNotEmpty()) table.publish(id, seen.sortedBy { it.startTimeUs })
            parser.parse(data, offset, length, outputOptions, output)
        }
        override fun parse(data: ByteArray, outputOptions: SubtitleParser.OutputOptions, output: Consumer<CuesWithTiming>) =
            parse(data, 0, data.size, outputOptions, output)
    }
}

/**
 * **Fills the cue table from an embedded text track.** Media3 parses Matroska and MP4 text while it extracts and hands
 * each cue on as one sample (`application/x-media3-cues`) at its real time; the parser factory sees only the sample's
 * bytes, without that time, so the table is fed here, where the sample is passed on. Everything goes through to
 * `real` unchanged. Picture cues (PGS) are left out: a film holds thousands of full-size bitmaps.
 */
@UnstableApi
class CueTap(private val real: TrackOutput, private val table: SubtitleCueTable) : TrackOutput by real {
    private var trackId: String? = null
    private var tapped = false
    private val sample = java.io.ByteArrayOutputStream()
    private val decoder = CueDecoder()

    override fun format(format: Format) {
        trackId = format.id
        tapped = format.sampleMimeType == MimeTypes.APPLICATION_MEDIA3_CUES
        sample.reset()
        real.format(format)
    }

    override fun sampleData(data: androidx.media3.common.DataReader, length: Int, allowEndOfInput: Boolean, sampleDataPart: Int): Int {
        tapped = false // cue samples come as byte arrays; anything read from a stream is not one of ours
        return real.sampleData(data, length, allowEndOfInput, sampleDataPart)
    }

    override fun sampleData(data: ParsableByteArray, length: Int, sampleDataPart: Int) {
        if (tapped) sample.write(data.data, data.position, length)
        real.sampleData(data, length, sampleDataPart)
    }

    override fun sampleMetadata(timeUs: Long, flags: Int, size: Int, offset: Int, cryptoData: TrackOutput.CryptoData?) {
        if (tapped && sample.size() >= size + offset) {
            val bytes = sample.toByteArray()
            runCatching { decoder.decode(timeUs, bytes, bytes.size - size - offset, size) }.getOrNull()?.takeIf { c -> c.cues.none { it.bitmap != null } }?.let { table.publish(trackId, listOf(it)) }
        }
        sample.reset()
        real.sampleMetadata(timeUs, flags, size, offset, cryptoData)
    }
}

/**
 * **Pre-roll for a far jump with a subtitle track on** (contract line 4 and 14). Media3 starts reading at the keyframe at
 * the target, so a picture cue (PGS) or an embedded text cue that began a little before the target is never read and
 * nothing shows until the next cue. The engine therefore first reads from [LOOKBACK_MS] earlier, hidden and paused, and
 * lands at the target once the buffer holds it; the text renderer then finds the cue that began before. Only the
 * decisions live here (plain JVM, tested); `PlayerEngine` owns the player.
 *
 * What the others do: libmpv's demuxer seeks subtitle tracks back by a pre-roll and reads on to the target (its
 * "subtitle preroll"), and the Apple engine starts its subtitle reader at the last display set before the target. Both
 * read the track from before the target; this is the same idea for a muxed stream that has to be read in order.
 */
object PreRoll {
    /** How far before the target the reading starts. A display set rarely stays up longer; 10 s costs one short read. */
    const val LOOKBACK_MS = 10_000L
    /** Jumps shorter than this keep Media3's plain seek (a 10 s skip button must not hide the picture). */
    const val FAR_MS = 20_000L
    /** The target counts as read once the buffer is this far past it. */
    private const val MARGIN_MS = 400L
    /** Give up waiting for the data (slow link) after this long and land anyway. */
    const val TIMEOUT_MS = 8_000L

    /** One state for the whole job: nothing running, or reading from [from] to land at [target]. */
    sealed interface State {
        data object Idle : State
        /** `resume`: whether the film played before the jump (it is held paused while reading). */
        data class Reading(val target: Long, val from: Long, val resume: Boolean, val deadlineMs: Long) : State
    }

    /**
     * Where to start reading for a jump to `targetMs`, or null for a plain seek. `force` is the resume case (the film was
     * just opened at the target, the track chosen afterwards): always read from earlier.
     */
    fun start(targetMs: Long, positionMs: Long, bufferedMs: Long, subtitleOn: Boolean, force: Boolean = false,
              lookbackMs: Long = LOOKBACK_MS, farMs: Long = FAR_MS): Long? {
        if (!subtitleOn || targetMs <= 0) return null
        val from = (targetMs - lookbackMs).coerceAtLeast(0)
        if (force) return from
        val insideBuffer = targetMs >= positionMs && targetMs <= bufferedMs
        if (insideBuffer) return null
        if (Math.abs(targetMs - positionMs) < farMs) return null
        return from
    }

    /** True when the reading is done: the buffer is past the target, the film ended, or the time is up. */
    fun readyToLand(s: State.Reading, bufferedMs: Long, ended: Boolean, nowMs: Long): Boolean =
        ended || bufferedMs >= s.target + MARGIN_MS || nowMs >= s.deadlineMs
}
