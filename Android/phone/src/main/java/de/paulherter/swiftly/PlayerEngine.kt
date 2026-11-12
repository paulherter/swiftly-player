package de.paulherter.swiftly

import android.content.Context
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.Gravity
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.SubtitleView
import androidx.media3.common.AudioAttributes
import androidx.media3.exoplayer.audio.AudioCapabilities
import java.util.concurrent.atomic.AtomicLong

/**
 * **Media3 (ExoPlayer) is the only engine on Android.** `PlayItem` talks only to this class; the names still follow
 * the old libVLC `MediaPlayer` so the player code above could stay as it was.
 *
 * Media3 does not draw subtitles into the picture; it hands them out as text or bitmaps, and the `SubtitleView`
 * above the video shows them in our look. Audio delay and subtitle delay live in `Media3Delays.kt`. Sound the
 * device cannot decode comes from the FFmpeg extension (`:ffmpeg`, LGPL, `Werkzeuge/media3-ffmpeg-bauen.sh`).
 *
 * **Threads.** Media3 may only be touched on the main thread, so every call made from another thread is posted to
 * the main thread, and reads from another thread return the last known value.
 */
@OptIn(UnstableApi::class)
class PlayerEngine(private val context: Context, private val isTv: Boolean, private var look: String = "") {
    private var exo: ExoPlayer? = null
    private val audioDelayProcessor = DelayAudioProcessor()
    private var passthroughBuilt = "auto"
    @Volatile private var dvOff = false

    /**
     * Settings that are fixed when Media3 is built (main thread, before `openMedia3`): the sound output mode
     * (`Settings.passthrough`) and whether the Dolby Vision decoder is skipped for this title. A changed output mode
     * takes the player down so the next open builds it again.
     */
    fun media3Configure(passthrough: String, dolbyVisionOff: Boolean) {
        dvOff = dolbyVisionOff
        if (passthrough != passthroughBuilt) { media3Down(); passthroughBuilt = passthrough }
    }
    private var renderers: SwiftlyRenderersFactory? = null

    private val main = Handler(Looper.getMainLooper())
    private fun onMainThread() = Looper.myLooper() == Looper.getMainLooper()
    private fun onMain(block: () -> Unit) { if (onMainThread()) block() else main.post(block) }

    /** A track: id and name. */
    class Track(val id: Int, val name: String?)
    /** What is known about a track; `fourcc` in the four-letter identifier the core reads. */
    class TrackDetail(val id: Int, val audio: Boolean, val language: String?, val fourcc: Int, val channels: Int, val rate: Int,
                      /** Jellyfin index of an attached subtitle file (Media3 only). */
                      val file: Long?)
    /** Playback counters for the stall watch. */
    class Counters(val readBytes: Long, val demuxReadBytes: Long, val displayedPictures: Long, val lostPictures: Long,
                   val decodedVideo: Long, val decodedAudio: Long, val playedAbuffers: Long, val lostAbuffers: Long,
                   val demuxCorrupted: Long, val demuxDiscontinuity: Long)

    sealed interface Event {
        data object Playing : Event
        data object Paused : Event
        data object Stopped : Event
        data object Frame : Event
        data class Buffering(val percent: Float) : Event
        data object Ended : Event
        data object Error : Event
    }

    /** Why the last playback error happened, for the message and the retry. */
    class ErrorKind(val name: String, val soundOutput: Boolean, val decoder: Boolean)
    @Volatile var lastError: ErrorKind? = null
        private set

    private var listener: ((Event) -> Unit)? = null

    fun onEvents(h: ((Event) -> Unit)?) { listener = h }

    private fun emit(e: Event) { listener?.invoke(e) }

    // MARK: Picture

    private var layout: FrameLayout? = null
    private var frame: AspectRatioFrameLayout? = null
    private var subtitleView: CaptionLayer? = null
    /** The text of the cues Media3 handed out last (tests and logs). */
    @Volatile var cueText: String = ""
        private set
    /** How many picture cues (PGS, VobSub) Media3 handed out last. */
    @Volatile var cueBitmaps: Int = 0
        private set
    private var fillFrame = false

    // MARK: Cue at a paused seek (contract line 14)

    /** The parsed cues of every text track; see `SubtitleCueTable`. */
    private val cueTable = SubtitleCueTable()
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    /** True while the cue on screen came from [cueTable] and not from Media3. */
    private var fallbackShown = false

    /**
     * A moment after a seek: when Media3 has handed out no cue but the selected track has one active at the new position,
     * draw that one. Media3 keeps its own cues when it has them (it clears [fallbackShown] with the first real cue).
     */
    private val fallbackCheck = Runnable {
        val e = exo ?: return@Runnable
        if (cueText.isNotEmpty() || cueBitmaps > 0) return@Runnable
        val format = e.currentTracks.groups.firstNotNullOfOrNull { g ->
            if (g.type != C.TRACK_TYPE_TEXT) null else (0 until g.length).firstOrNull { g.isTrackSelected(it) }?.let { g.getTrackFormat(it) }
        } ?: return@Runnable
        val at = (e.currentPosition - (renderers?.subtitleDelayMs ?: 0)) * 1000L
        val cues = cueTable.activeAt(format.id, at)
        if (cues.isEmpty()) return@Runnable
        fallbackShown = true
        cueText = cues.mapNotNull { it.text?.toString() }.joinToString("\n")
        subtitleView?.setCues(cues)
    }

    // MARK: Pre-roll for a far jump with a subtitle track on (contract line 4 and 14; `PreRoll`)

    private var preRoll: PreRoll.State = PreRoll.State.Idle
    /** The picture is shown again with the first frame at the target. */
    private var unhideOnFrame = false
    /** Where the film was opened (ms): the track chosen right after the opening is read from before that point. */
    private var openedAtMs = 0L

    private fun subtitleOn(e: ExoPlayer): Boolean = e.currentTracks.groups.any { g ->
        g.type == C.TRACK_TYPE_TEXT && (0 until g.length).any { g.isTrackSelected(it) }
    }

    private val preRollTick = object : Runnable {
        override fun run() {
            val s = preRoll as? PreRoll.State.Reading ?: return
            val e = exo ?: return
            if (PreRoll.readyToLand(s, e.bufferedPosition, e.playbackState == Player.STATE_ENDED, android.os.SystemClock.uptimeMillis())) land(s, e)
            else mainHandler.postDelayed(this, 80)
        }
    }

    /** One place for the seek: a plain Media3 seek, or the hidden read from earlier (main thread). */
    private fun seekTo(target: Long, force: Boolean = false) {
        val e = exo ?: return
        val from = PreRoll.start(target, e.currentPosition, e.bufferedPosition, force || subtitleOn(e), force)
        if (from == null) { preRollCancel(e); e.seekTo(target); return }
        val resume = (preRoll as? PreRoll.State.Reading)?.resume ?: e.playWhenReady
        preRoll = PreRoll.State.Reading(target, from, resume, android.os.SystemClock.uptimeMillis() + PreRoll.TIMEOUT_MS)
        e.playWhenReady = false
        frame?.alpha = 0f
        AppLog.writeOut("[Media3] Untertitel-Vorlauf $from → $target")
        e.seekTo(from)
        mainHandler.removeCallbacks(preRollTick)
        mainHandler.postDelayed(preRollTick, 80)
    }

    private fun land(s: PreRoll.State.Reading, e: ExoPlayer) {
        preRoll = PreRoll.State.Idle
        unhideOnFrame = true
        e.seekTo(s.target)
        e.playWhenReady = s.resume
        updateMirror(e)
        mainHandler.postDelayed({ if (unhideOnFrame) { unhideOnFrame = false; frame?.alpha = 1f } }, 1500)
    }

    private fun preRollCancel(e: ExoPlayer?) {
        mainHandler.removeCallbacks(preRollTick)
        val s = preRoll as? PreRoll.State.Reading
        preRoll = PreRoll.State.Idle
        if (s != null && e != null) { e.playWhenReady = s.resume; updateMirror(e) }
        unhideOnFrame = false
        frame?.alpha = 1f
    }

    /** Attach the video surface: a `SurfaceView` of Media3's own inside `l`. */
    fun attach(l: FrameLayout) {
        layout = l
        attachMedia3()
    }

    fun isAttached(): Boolean = frame?.parent != null

    fun detach() { removeFrame() }

    private fun attachMedia3() {
        val l = layout ?: return
        val e = exo ?: return
        val r = frame ?: AspectRatioFrameLayout(context).also { neu ->
            neu.addView(SurfaceView(context), FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            // Above the picture, inside the video frame, as `PlayerView` does it.
            val sv = CaptionLayer(context).apply { subtitleStyleApply(this) }
            neu.addView(sv, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            subtitleView = sv
            frame = neu
        }
        r.resizeMode = if (fillFrame) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
        if (r.parent == null) l.addView(r, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER))
        r.visibility = View.VISIBLE
        e.setVideoSurfaceView(r.getChildAt(0) as SurfaceView)
    }

    /**
     * **The captions from the stored look** (spec section 9, contract line 8). The numbers come from the package
     * (`Kern.subtitleLookFacts`); `CaptionLayer` draws them like the Apple overlay (Inter SemiBold, outline in
     * percent of the font size) instead of Media3's fixed 2 dp edge. Embedded styles stay on only with "keep
     * the file's style"; the file's own sizes never apply.
     */
    private fun subtitleStyleApply(view: CaptionLayer) {
        val f = runCatching { org.json.JSONObject(KernRules.subtitleLookFacts(look, SubtitleBase.of(isTv))) }.getOrNull()
        view.apply(f)
    }

    /** The caption layer on screen (tests read pixels from it). */
    val captionLayer: CaptionLayer? get() = subtitleView

    /** A look that changed while a video runs (sync, settings): applied at once, main thread. */
    fun lookSet(json: String) = onMain {
        if (json == look) return@onMain
        look = json
        subtitleView?.let { subtitleStyleApply(it) }
    }

    private fun removeFrame() {
        val r = frame ?: return
        (r.getChildAt(0) as? SurfaceView)?.let { exo?.clearVideoSurfaceView(it) }
        (r.parent as? FrameLayout)?.removeView(r)
        frame = null
        subtitleView = null
    }

    fun fillFrameSet(new: Boolean) {
        fillFrame = new
        frame?.resizeMode = if (new) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
    }

    // MARK: Open

    /**
     * Bytes read, for the stream watch: Media3 reports them here. Written on
     * Media3's loader thread, read on the main thread: an `AtomicLong`, a plain `Long` can tear on 32-bit devices.
     */
    private val bytesRead = AtomicLong(0)
    private val byteCounter = object : TransferListener {
        override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
        override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
        override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) { bytesRead.addAndGet(bytesTransferred.toLong()) }
        override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
    }


    /**
     * **Media3 plays the address from `since` seconds** (main thread). External subtitles go in right away
     * (`subtitles`: Jellyfin index and address).
     */
    fun openMedia3(address: String, since: Double?, subtitles: List<Pair<Long, String>>, formats: Map<Long, String> = emptyMap()) {
        val e = exo ?: buildMedia3().also { exo = it }
        displayRateReset()
        attachMedia3()
        val configs = subtitles.mapNotNull { (index, url) ->
            val kind = subtitleKind(url, formats[index]) ?: return@mapNotNull null
            MediaItem.SubtitleConfiguration.Builder(Uri.parse(url)).setId("datei:$index").setMimeType(kind).build()
        }
        val item = MediaItem.Builder().setUri(address).setSubtitleConfigurations(configs).build()
        preRollCancel(null)
        openedAtMs = ((since ?: 0.0) * 1000).toLong().coerceAtLeast(0)
        reportedPlaying = false
        seen.clear()
        e.setMediaItem(item, ((since ?: 0.0) * 1000).toLong().coerceAtLeast(0))
        e.prepare()
    }

    private fun buildMedia3(): ExoPlayer {
        val factory = SwiftlyRenderersFactory(context, audioDelayProcessor, passthroughBuilt)
            .also { renderers = it }
            // Dolby Vision off (profile 7 setting, Fire TV HDR10+ switch): without the DV decoder Media3 takes the HEVC
            // base layer (HDR10) of profile 4/7/8; profile 5 has none, so it is never switched off.
            .setMediaCodecSelector { mime, secure, tunneling ->
                if (dvOff && mime == MimeTypes.VIDEO_DOLBY_VISION) emptyList()
                else androidx.media3.exoplayer.mediacodec.MediaCodecSelector.DEFAULT.getDecoderInfos(mime, secure, tunneling)
            }
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
            .setEnableDecoderFallback(true)
        val sources = DefaultDataSource.Factory(context, DefaultHttpDataSource.Factory().setUserAgent("Swiftly")
            .setAllowCrossProtocolRedirects(true)).setTransferListener(byteCounter)
        return ExoPlayer.Builder(context, factory)
            .setMediaSourceFactory(DefaultMediaSourceFactory(sources, DolbyVisionBaseLayerExtractors({ dvOff }, cueTable))
                .setSubtitleParserFactory(RecordingSubtitleParsers(cueTable)))
            // `PlayItem` manages audio focus itself, as with VLC.
            .setAudioAttributes(androidx.media3.common.AudioAttributes.Builder().setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), false)
            .build().also {
                it.addListener(media3Listener)
                // Phone: the display rate is voted by `displayRateKeep`, not by Media3. Media3 votes the film's own
                // rate (23.976), and on a 60/120 Hz panel the only even multiple of that is 120. TV keeps
                // Media3's default; there `TvImageTick` switches the output mode.
                if (!isTv) it.videoChangeFrameRateStrategy = C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_OFF
            }
    }

    /** Take Media3 down (main thread), if it was running. */
    fun media3Down() {
        val e = exo ?: return
        preRollCancel(null)
        removeFrame()
        e.removeListener(media3Listener)
        e.release()
        exo = null
        exoPlaying = false
    }

    private var reportedPlaying = false
    private val seen = HashSet<Int>()
    /** Mirror for reads from other threads. */
    @Volatile private var exoPlaying = false
    @Volatile private var exoTime = 0L

    private fun updateMirror(e: ExoPlayer) {
        val wants = (preRoll as? PreRoll.State.Reading)?.resume ?: e.playWhenReady
        exoPlaying = wants && (e.playbackState == Player.STATE_READY || e.playbackState == Player.STATE_BUFFERING)
    }

    private val media3Listener = object : Player.Listener {
        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            val e = exo ?: return
            if (preRoll is PreRoll.State.Reading) return
            updateMirror(e)
            if (playWhenReady && e.playbackState == Player.STATE_READY && !reportedPlaying) { reportedPlaying = true; emit(Event.Playing) }
            if (!playWhenReady && reportedPlaying) { reportedPlaying = false; emit(Event.Paused) }
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            val e = exo ?: return
            updateMirror(e)
            when (playbackState) {
                Player.STATE_BUFFERING -> emit(Event.Buffering(0f))
                Player.STATE_READY -> {
                    emit(Event.Buffering(100f))
                    if (e.playWhenReady && !reportedPlaying && preRoll !is PreRoll.State.Reading) { reportedPlaying = true; emit(Event.Playing) }
                }
                Player.STATE_ENDED -> { reportedPlaying = false; emit(Event.Ended) }
                Player.STATE_IDLE -> if (reportedPlaying) { reportedPlaying = false; emit(Event.Stopped) }
            }
        }

        override fun onRenderedFirstFrame() {
            if (unhideOnFrame && preRoll is PreRoll.State.Idle) { unhideOnFrame = false; frame?.alpha = 1f }
            emit(Event.Frame)
            // The live runner (`Werkzeuge/android-live.py`) waits for this line: the format is known by now.
            AppLog.writeOut("[Media3] Erstes Bild")
            exo?.videoFormat?.let { AppLog.writeOut("[Media3] Video ${it.sampleMimeType} ${it.codecs.orEmpty()} ${it.width}×${it.height}") }
        }

        override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
            if (reason != Player.DISCONTINUITY_REASON_SEEK) return
            fallbackShown = false
            mainHandler.removeCallbacks(fallbackCheck)
            mainHandler.postDelayed(fallbackCheck, 250)
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) { if (isPlaying) { fallbackShown = false; mainHandler.removeCallbacks(fallbackCheck) } }

        override fun onCues(cueGroup: CueGroup) {
            // Our own cue (below) stays while Media3 only says "nothing" after the seek; any real cue replaces it.
            if (fallbackShown && cueGroup.cues.isEmpty() && exo?.isPlaying != true) return
            fallbackShown = false
            cueBitmaps = cueGroup.cues.count { it.bitmap != null }
            cueText = cueGroup.cues.mapNotNull { it.text?.toString() }.joinToString("\n")
            subtitleView?.setCues(cueGroup.cues)
        }

        override fun onPlayerError(error: PlaybackException) {
            AppLog.writeOut("[Media3] Fehler ${error.errorCodeName}: ${error.message}")
            lastError = ErrorKind(error.errorCodeName,
                soundOutput = error.errorCode == PlaybackException.ERROR_CODE_AUDIO_TRACK_INIT_FAILED ||
                    error.errorCode == PlaybackException.ERROR_CODE_AUDIO_TRACK_WRITE_FAILED ||
                    error.errorCode == PlaybackException.ERROR_CODE_AUDIO_TRACK_OFFLOAD_INIT_FAILED ||
                    error.errorCode == PlaybackException.ERROR_CODE_AUDIO_TRACK_OFFLOAD_WRITE_FAILED,
                decoder = error.errorCode == PlaybackException.ERROR_CODE_DECODER_INIT_FAILED ||
                    error.errorCode == PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED ||
                    error.errorCode == PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES ||
                    error.errorCode == PlaybackException.ERROR_CODE_DECODING_FAILED)
            emit(Event.Error)
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            if (videoSize.width > 0 && videoSize.height > 0)
                frame?.setAspectRatio(videoSize.width * videoSize.pixelWidthHeightRatio / videoSize.height)
        }

        override fun onTracksChanged(tracks: Tracks) {
            exo?.videoFormat?.let { AppLog.writeOut("[Media3] Video ${it.sampleMimeType} ${it.codecs.orEmpty()} ${it.width}×${it.height}") }
        }
    }

    // MARK: Control: the same names as libVLC's `MediaPlayer`.

    val isPlaying: Boolean get() = exoPlaying

    /** Milliseconds. */
    var time: Long
        get() = exo?.takeIf { onMainThread() }?.currentPosition?.also { exoTime = it } ?: exoTime
        set(value) { onMain { seekTo(value.coerceAtLeast(0)) } }

    /** Milliseconds, 0 while unknown. */
    val length: Long get() = exo?.takeIf { onMainThread() }?.duration?.let { if (it == C.TIME_UNSET) 0L else it } ?: 0L

    fun play() { onMain { setWanted(true) } }
    fun pause() { onMain { setWanted(false) } }

    /** Play or pause; during a pre-roll the player stays held and only the wish for after the landing changes. */
    private fun setWanted(play: Boolean) {
        val s = preRoll
        if (s is PreRoll.State.Reading) { preRoll = s.copy(resume = play); exo?.let { updateMirror(it) }; return }
        exo?.playWhenReady = play
    }

    /** Stop Media3 (main thread). */
    fun stopMedia3() { onMain { exo?.stop() } }

    /** 0…100 as with VLC. */
    var volume: Int
        get() = exo?.takeIf { onMainThread() }?.let { (it.volume * 100).toInt() } ?: 100
        set(value) { onMain { exo?.volume = value.coerceIn(0, 100) / 100f } }

    fun rateSet(value: Float) { onMain { exo?.setPlaybackSpeed(value) } }

    fun hasMedia(): Boolean = exo?.takeIf { onMainThread() }?.let { it.mediaItemCount > 0 } ?: true

    // MARK: Delay (Media3Delays.kt)

    /** Media3: audio delay (silence in the sink) and subtitle delay (late clock for the text renderer), in ms. */
    fun delaysMedia3Set(audioMs: Int, subtitleMs: Int) {
        audioDelayProcessor.wantedMs = audioMs
        renderers?.subtitleDelayMs = subtitleMs
    }

    // MARK: Tracks: Media3 ids are group × 100 + track; -1 means off, as with VLC.

    private fun tracksOf(kind: Int): List<Pair<Int, Format>> {
        val e = exo?.takeIf { onMainThread() } ?: return emptyList()
        val list = ArrayList<Pair<Int, Format>>()
        e.currentTracks.groups.forEachIndexed { g, group ->
            if (group.type != kind) return@forEachIndexed
            for (t in 0 until group.length) if (group.isTrackSupported(t, true)) list += (g * 100 + t) to group.getTrackFormat(t)
        }
        return list
    }

    private fun selectedOf(kind: Int): Int {
        val e = exo?.takeIf { onMainThread() } ?: return -1
        e.currentTracks.groups.forEachIndexed { g, group ->
            if (group.type != kind) return@forEachIndexed
            for (t in 0 until group.length) if (group.isTrackSelected(t)) return g * 100 + t
        }
        return -1
    }

    private fun choose(kind: Int, id: Int) = onMain {
        val e = exo ?: return@onMain
        val p = e.trackSelectionParameters.buildUpon()
        val group = e.currentTracks.groups.getOrNull(id / 100)
        if (id < 0 || group == null || group.type != kind || id % 100 >= group.length) {
            p.setTrackTypeDisabled(kind, true)
        } else {
            p.setTrackTypeDisabled(kind, false).setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, id % 100))
        }
        e.trackSelectionParameters = p.build()
        AppLog.writeOut("[Media3] ${if (kind == C.TRACK_TYPE_TEXT) "Untertitel" else "Ton"} → $id")
        if (kind == C.TRACK_TYPE_TEXT && id < 0) subtitleView?.setCues(emptyList())
        // A film opened inside a cue (resume) never read the cue's start: read from before the opening point.
        if (kind == C.TRACK_TYPE_TEXT && id >= 0 && preRoll is PreRoll.State.Idle && openedAtMs > 0 &&
            Math.abs(e.currentPosition - openedAtMs) < 4_000) seekTo(e.currentPosition, force = true)
    }

    val audioTracks: List<Track>? get() = tracksOf(C.TRACK_TYPE_AUDIO).map { Track(it.first, it.second.label) }
    val spuTracks: List<Track>? get() = tracksOf(C.TRACK_TYPE_TEXT).map { Track(it.first, it.second.label) }
    val audioTracksCount: Int get() = tracksOf(C.TRACK_TYPE_AUDIO).size

    var audioTrack: Int
        get() = selectedOf(C.TRACK_TYPE_AUDIO)
        set(id) { choose(C.TRACK_TYPE_AUDIO, id) }
    var spuTrack: Int
        get() = selectedOf(C.TRACK_TYPE_TEXT)
        set(id) { choose(C.TRACK_TYPE_TEXT, id) }

    /** Language, codec and channels per track id. */
    fun trackDetails(): Map<Int, TrackDetail> =
        (tracksOf(C.TRACK_TYPE_AUDIO).map { it to true } + tracksOf(C.TRACK_TYPE_TEXT).map { it to false })
            .associate { (s, audio) ->
                val f = s.second
                s.first to TrackDetail(s.first, audio, f.language?.takeIf { it != C.LANGUAGE_UNDETERMINED }, fourccOf(f),
                    f.channelCount.coerceAtLeast(0), f.sampleRate.coerceAtLeast(0),
                    // Media3 may put something in front of the id when merging.
                    f.id?.substringAfter("datei:", "")?.takeWhile { it.isDigit() }?.toLongOrNull())
            }

    /** The file's frame rate once known, for `TvImageTick`. */
    fun frameRate(): Double? = exo?.takeIf { onMainThread() }?.videoFormat?.frameRate?.takeIf { it > 0 }?.toDouble()

    // MARK: Display rate (phone)

    /** The film's frame rate, measured once per opening . */
    private var filmRate: Double? = null
    private var rateTries = 0
    /** The layers already given a vote, by identity: a SurfaceView gets a new `SurfaceControl` after it was rebuilt. */
    private val voted = java.util.IdentityHashMap<android.view.SurfaceControl, Float>()

    /** The vote for the display mode `rateModeId` (-1: not computed). */
    private var rateModeId = -1
    private var rateTarget = 0f
    private var rateRates: List<Float> = emptyList()

    private fun displayRateReset() { filmRate = null; rateTries = 0; voted.clear(); rateModeId = -1 }

    /**
     * **Phone: ask for a display rate that fits the film, at most 60 Hz** (main thread, from the player tick).
     * Without a vote the system guesses from the video layer alone, and for 23.976 fps it picks 120 Hz on
     * 60/120 Hz panels because that is the only even multiple; the panel then stays at its top rate for the
     * whole film. The vote is placed on the video layer with `ONLY_IF_SEAMLESS`, so the picture never goes
     * black for a mode switch. It goes with the layer when the player closes; nothing to undo.
     */
    fun displayRateKeep(display: Display?) {
        if (isTv || android.os.Build.VERSION.SDK_INT < 31 || display == null) return
        val fps = filmRate ?: run {
            if (rateTries >= 40) return
            rateTries++
            frameRate()?.takeIf { it > 1 && it < 250 }?.also { filmRate = it } ?: return
        }
        @Suppress("DEPRECATION")
        val current = display.mode
        // `supportedModes` copies its array on every call; the answer only changes with the display mode.
        if (current.modeId != rateModeId) {
            val rates = display.supportedModes
                .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
                .flatMap { listOf(it.refreshRate) + it.alternativeRefreshRates.toList() }
            rateTarget = PhoneFrameRate.target(fps, rates)
            rateRates = rates
            rateModeId = current.modeId
        }
        val target = rateTarget
        val rates = rateRates
        for (sv in videoSurfaces()) {
            val sc = sv.surfaceControl?.takeIf { it.isValid } ?: continue
            if (voted[sc] == target) continue
            runCatching {
                // A Transaction owns native memory; close it after apply().
                val transaction = android.view.SurfaceControl.Transaction()
                try {
                    transaction
                        .setFrameRate(sc, target, android.view.Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE,
                            android.view.Surface.CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS)
                        .apply()
                } finally {
                    transaction.close()
                }
                voted[sc] = target
                AppLog.writeOut("[Bildrate] Film ${"%.3f".format(fps)} fps → Anzeige $target Hz (Modi ${rates.distinct().sorted()})")
            }
        }
    }

    /** The visible video surface: Media3's own SurfaceView. */
    private fun videoSurfaces(): List<SurfaceView> = listOfNotNull(frame?.getChildAt(0) as? SurfaceView)

    /** Counters from the decoder counters and the bytes read. */
    fun counters(): Counters? {
        val e = exo?.takeIf { onMainThread() } ?: return null
        val v = e.videoDecoderCounters?.also { it.ensureUpdated() }
        val a = e.audioDecoderCounters?.also { it.ensureUpdated() }
        val shown = (v?.renderedOutputBufferCount ?: 0).toLong()
        val read = bytesRead.get()
        return Counters(read, read, shown, (v?.droppedBufferCount ?: 0).toLong(),
            shown + (v?.droppedBufferCount ?: 0) + (v?.skippedOutputBufferCount ?: 0),
            (a?.renderedOutputBufferCount ?: 0).toLong(), (a?.renderedOutputBufferCount ?: 0).toLong(), 0, 0, 0)
    }

    companion object {
        /**
         * **Can this device show Dolby Vision?** A Dolby Vision decoder and a display that reports Dolby
         * Vision.
         */
        /**
         * **Does any Dolby Vision decoder on this device take profile 7 (dual layer)?** Many do not (Pixel: no frames at
         * all, only sound); without one the HEVC base layer (HDR10) is the way, as with the setting "off".
         */
        /** Is there any Dolby Vision decoder at all (the emulator and many TVs have none)? */
        fun dolbyVisionAnyDecoder(): Boolean =
            runCatching { MediaCodecUtil.getDecoderInfos(MimeTypes.VIDEO_DOLBY_VISION, false, false).isNotEmpty() }.getOrDefault(false)

        /**
         * **Play the HEVC base layer (HDR10) instead of Dolby Vision?** Profiles 4, 7 and 8 carry a plain HEVC base layer;
         * profile 5 has none (the server transcodes it) and profile 10 is AV1 (own rules). Without a Dolby Vision
         * decoder the device fails at once (`ERROR_CODE_DECODING_FAILED` at index 0) for a `dvhe.08` track.
         */
        fun dolbyVisionBaseLayerNeeded(profile: Int?, anyDecoder: Boolean): Boolean =
            profile != null && profile != 5 && profile != 10 && !anyDecoder

        fun dolbyVision7Decodable(): Boolean = runCatching {
            MediaCodecUtil.getDecoderInfos(MimeTypes.VIDEO_DOLBY_VISION, false, false).any { info ->
                info.capabilities?.profileLevels?.any {
                    it.profile == android.media.MediaCodecInfo.CodecProfileLevel.DolbyVisionProfileDvheDtb
                } == true
            }
        }.getOrDefault(false)

        fun dolbyVisionPossible(context: Context): Boolean {
            val decoder = runCatching { MediaCodecUtil.getDecoderInfos(MimeTypes.VIDEO_DOLBY_VISION, false, false).isNotEmpty() }
                .getOrDefault(false)
            if (!decoder) return false
            val display = (context.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager)?.getDisplay(Display.DEFAULT_DISPLAY) ?: return false
            @Suppress("DEPRECATION")
            val kinds = if (android.os.Build.VERSION.SDK_INT >= 34) display.mode.supportedHdrTypes
                        else display.hdrCapabilities?.supportedHdrTypes ?: IntArray(0)
            @Suppress("DEPRECATION")
            return Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION in kinds
        }

        /**
         * **Can Media3 play this sound (device decoder, passthrough or the FFmpeg extension)?** The device decodes it (MediaCodec) or can
         * pass it through to the output. `codec` is the Jellyfin name of the default track (`""`: no sound).
         */
        fun audioPlayable(context: Context, codec: String): Boolean {
            if (codec.isEmpty()) return true
            val mime = EngineChoice.audioMime(codec) ?: return false
            if (mime == MimeTypes.AUDIO_RAW) return true
            val decodes = runCatching { MediaCodecUtil.getDecoderInfos(mime, false, false).isNotEmpty() }.getOrDefault(false)
            if (decodes) return true
            // The LGPL FFmpeg extension (`:ffmpeg`, libs from Werkzeuge/media3-ffmpeg-bauen.sh) decodes AC-3, E-AC-3,
            // TrueHD/MLP, DTS (incl. HD core), FLAC, Opus, Vorbis, AAC, MP3 and ALAC in software.
            if (runCatching { androidx.media3.decoder.ffmpeg.FfmpegLibrary.supportsFormat(mime) }.getOrDefault(false)) return true
            return runCatching {
                val format = Format.Builder().setSampleMimeType(mime).setChannelCount(6).setSampleRate(48_000).build()
                AudioCapabilities.getCapabilities(context, AudioAttributes.DEFAULT, null)
                    .isPassthroughPlaybackSupported(format, AudioAttributes.DEFAULT)
            }.getOrDefault(false)
        }

        /** Subtitle files Media3 can load alongside, by the ending of the address. */
        private fun subtitleKind(url: String, hint: String? = null): String? = when (Uri.parse(url).lastPathSegment?.takeIf { '.' in it }?.substringAfterLast('.')?.lowercase() ?: hint?.lowercase()) {
            "srt", "subrip" -> MimeTypes.APPLICATION_SUBRIP
            "vtt", "webvtt" -> MimeTypes.TEXT_VTT
            "ass", "ssa" -> MimeTypes.TEXT_SSA
            "ttml" -> MimeTypes.APPLICATION_TTML
            else -> null
        }

        /** libVLC's four-letter identifier (`fourcc`, lowest byte first) from Media3's MIME type. */
        private fun fourccOf(f: Format): Int {
            val mime = if (f.sampleMimeType == MimeTypes.APPLICATION_MEDIA3_CUES) f.codecs else f.sampleMimeType
            val k = when (mime) {
                MimeTypes.AUDIO_AAC -> "mp4a"; MimeTypes.AUDIO_AC3 -> "a52 "
                MimeTypes.AUDIO_E_AC3, MimeTypes.AUDIO_E_AC3_JOC -> "eac3"
                MimeTypes.AUDIO_DTS, MimeTypes.AUDIO_DTS_HD, MimeTypes.AUDIO_DTS_EXPRESS -> "dts "
                MimeTypes.AUDIO_TRUEHD -> "trhd"; MimeTypes.AUDIO_FLAC -> "flac"; MimeTypes.AUDIO_ALAC -> "alac"
                MimeTypes.AUDIO_OPUS -> "opus"; MimeTypes.AUDIO_MPEG -> "mp3 "; MimeTypes.AUDIO_VORBIS -> "vorb"
                MimeTypes.APPLICATION_SUBRIP -> "subt"; MimeTypes.TEXT_SSA -> "ssa "; MimeTypes.APPLICATION_PGS -> "bdpg"
                MimeTypes.APPLICATION_VOBSUB -> "spu "; MimeTypes.APPLICATION_TX3G -> "tx3g"; MimeTypes.TEXT_VTT -> "wvtt"
                MimeTypes.APPLICATION_TTML -> "stpp"; MimeTypes.APPLICATION_DVBSUBS -> "dvbs"
                else -> return 0
            }
            return k.foldIndexed(0) { i, sum, z -> sum or (z.code shl (8 * i)) }
        }
    }
}

/**
 * Which display rate a phone asks for while a film runs. **Never above 60 Hz**: the lowest rate the panel
 * offers up to 60 that the film divides evenly (24 → 24/48, 25 → 50, 30 → 30/60, 60 → 60). If none
 * divides evenly (24 fps on a 60/120 Hz panel), 60 Hz with pulldown, as the iPhone plays it, instead
 * of 120 Hz for the whole film.
 */
internal object PhoneFrameRate {
    const val CEILING = 60.5f

    fun target(fps: Double, rates: List<Float>): Float {
        val low = rates.filter { it >= 1f && it <= CEILING }.distinct().sorted()
        low.firstOrNull { r ->
            val factor = r / fps
            factor >= 0.99 && kotlin.math.abs(factor - kotlin.math.round(factor)) < 0.01
        }?.let { return it }
        return low.lastOrNull() ?: 60f
    }
}
