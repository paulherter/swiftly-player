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
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.interfaces.IMedia
import org.videolan.libvlc.util.VLCVideoLayout

/**
 * **Two engines behind one handle.** libVLC plays everything; only Dolby Vision goes to Media3.
 *
 * libVLC 3 never asks MediaCodec for `video/dolby-vision`, only for `video/hevc`: the decoder drops the
 * Dolby Vision layer and the TV switches to the base layer (HDR10 or HDR10+). Media3 uses the device's
 * Dolby Vision decoder if it has one. `PlayItem` talks only to this class; the names follow libVLC's
 * `MediaPlayer`, so the rest of the player could stay as it was.
 *
 * Media3 lacks what only VLC can do: audio and subtitle delay. **Media3 does not draw subtitles into the
 * picture** like VLC; it hands them out as text or bitmaps, and the `SubtitleView` above the video shows
 * them in VLC's look here (white, black outline, no box).
 *
 * **Threads.** `PlayItem` runs everything that can block in libVLC on its own thread (`Swiftly-VLC`).
 * Media3 may only be touched on the main thread, so every Media3 call made from another thread is posted
 * to the main thread, and reads from another thread return the last known value. Media3 itself is
 * created, opened and released on the main thread only.
 *
 * **Without FFmpeg decoders from Jellyfin's Media3 build** (it is published under the GPL-3.0): sound the
 * device cannot decode or pass through (often DTS and TrueHD) stays with libVLC, see `EngineChoice`.
 * */
@OptIn(UnstableApi::class)
class PlayerEngine(private val context: Context, val vlc: LibVLC, private val isTv: Boolean) {
    val vlcPlayer = MediaPlayer(vlc)
    private var exo: ExoPlayer? = null
    /** Is Media3 playing instead of VLC? Readable from any thread. */
    @Volatile var usesMedia3: Boolean = false
        private set

    private val main = Handler(Looper.getMainLooper())
    private fun onMainThread() = Looper.myLooper() == Looper.getMainLooper()
    private fun onMain(block: () -> Unit) { if (onMainThread()) block() else main.post(block) }

    /** A track like libVLC's `TrackDescription`: id and name. */
    class Track(val id: Int, val name: String?)
    /** What is known about a track; `fourcc` in libVLC's identifier so the core reads it the same way. */
    class TrackDetail(val id: Int, val audio: Boolean, val language: String?, val fourcc: Int, val channels: Int, val rate: Int,
                      /** Jellyfin index of an attached subtitle file (Media3 only). */
                      val file: Long?)
    /** libVLC's `Media.Stats`, read unsigned. */
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
        data class TextTrackNew(val id: Int) : Event
    }

    private var listener: ((Event) -> Unit)? = null

    fun onEvents(h: ((Event) -> Unit)?) {
        listener = h
        if (h == null) { vlcPlayer.setEventListener(null); return }
        vlcPlayer.setEventListener { e ->
            if (usesMedia3) return@setEventListener
            when (e.type) {
                MediaPlayer.Event.Playing -> h(Event.Playing)
                MediaPlayer.Event.Paused -> h(Event.Paused)
                MediaPlayer.Event.Stopped -> h(Event.Stopped)
                MediaPlayer.Event.Vout -> if (e.voutCount > 0) h(Event.Frame)
                MediaPlayer.Event.Buffering -> h(Event.Buffering(e.buffering))
                MediaPlayer.Event.EndReached -> h(Event.Ended)
                MediaPlayer.Event.EncounteredError -> h(Event.Error)
                MediaPlayer.Event.ESAdded -> if (e.esChangedType == IMedia.Track.Type.Text) h(Event.TextTrackNew(e.esChangedID))
            }
        }
    }

    private fun emit(e: Event) { listener?.invoke(e) }

    // MARK: Picture

    private var layout: VLCVideoLayout? = null
    private var frame: AspectRatioFrameLayout? = null
    private var subtitleView: SubtitleView? = null
    private var fillFrame = false

    /** Attach the video surface: VLC to its `VLCVideoLayout`, Media3 to a `SurfaceView` of its own inside it. */
    fun attach(l: VLCVideoLayout) {
        layout = l
        if (usesMedia3) attachMedia3() else if (!vlcPlayer.vlcVout.areViewsAttached()) vlcPlayer.attachViews(l, null, true, false)
    }

    fun isAttached(): Boolean = if (usesMedia3) frame?.parent != null else vlcPlayer.vlcVout.areViewsAttached()

    fun detach() {
        if (vlcPlayer.vlcVout.areViewsAttached()) vlcPlayer.detachViews()
        removeFrame()
    }

    private fun attachMedia3() {
        val l = layout ?: return
        val e = exo ?: return
        if (vlcPlayer.vlcVout.areViewsAttached()) vlcPlayer.detachViews()
        // Hide VLC's own surfaces: two SurfaceViews on top of each other have no fixed order.
        for (i in 0 until l.childCount) l.getChildAt(i).visibility = View.GONE
        val r = frame ?: AspectRatioFrameLayout(context).also { neu ->
            neu.addView(SurfaceView(context), FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            // Above the picture, inside the video frame, as `PlayerView` does it.
            val sv = SubtitleView(context).apply {
                setStyle(CaptionStyleCompat(android.graphics.Color.WHITE, android.graphics.Color.TRANSPARENT,
                    android.graphics.Color.TRANSPARENT, CaptionStyleCompat.EDGE_TYPE_OUTLINE, android.graphics.Color.BLACK, null))
                // VLC's default is 6.25 % of the picture height, made smaller here as there (`--sub-text-scale`).
                setFractionalTextSize(0.0625f * (if (isTv) 0.88f else 0.82f))
                setApplyEmbeddedStyles(true)
                setApplyEmbeddedFontSizes(false)
            }
            neu.addView(sv, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            subtitleView = sv
            frame = neu
        }
        r.resizeMode = if (fillFrame) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
        if (r.parent == null) l.addView(r, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER))
        r.visibility = View.VISIBLE
        e.setVideoSurfaceView(r.getChildAt(0) as SurfaceView)
    }

    private fun removeFrame() {
        val r = frame ?: return
        (r.getChildAt(0) as? SurfaceView)?.let { exo?.clearVideoSurfaceView(it) }
        (r.parent as? FrameLayout)?.removeView(r)
        frame = null
        subtitleView = null
        layout?.let { l -> for (i in 0 until l.childCount) l.getChildAt(i).visibility = View.VISIBLE }
    }

    fun fillFrameSet(new: Boolean) {
        fillFrame = new
        vlcPlayer.videoScale = if (new) MediaPlayer.ScaleType.SURFACE_FIT_SCREEN else MediaPlayer.ScaleType.SURFACE_BEST_FIT
        frame?.resizeMode = if (new) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
    }

    // MARK: Open

    /**
     * Give VLC its views back (main thread, before `openVlc` is queued): Media3 took them away in `attachMedia3`,
     * and view and surface callbacks belong on the main thread. Only an attach, no blocking libVLC call.
     */
    fun vlcViewsAttach() {
        val l = layout
        if (VlcHandover.attachNeeded(l != null, vlcPlayer.vlcVout.areViewsAttached())) vlcPlayer.attachViews(l!!, null, true, false)
    }

    /** Hand the media to VLC. Runs on the VLC thread; Media3 is down and the views are attached beforehand (main thread). */
    fun openVlc(media: Media) {
        vlcPlayer.media = media
        vlcPlayer.videoScale = if (fillFrame) MediaPlayer.ScaleType.SURFACE_FIT_SCREEN else MediaPlayer.ScaleType.SURFACE_BEST_FIT
    }

    /**
     * Bytes read, for the stream watch: VLC counts them itself, Media3 reports them here. Written on
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
     * (`subtitles`: Jellyfin index and address); Media3 cannot attach them afterwards like VLC.
     */
    fun openMedia3(address: String, since: Double?, subtitles: List<Pair<Long, String>>) {
        val e = exo ?: buildMedia3().also { exo = it }
        usesMedia3 = true
        attachMedia3()
        val configs = subtitles.mapNotNull { (index, url) ->
            val kind = subtitleKind(url) ?: return@mapNotNull null
            MediaItem.SubtitleConfiguration.Builder(Uri.parse(url)).setId("datei:$index").setMimeType(kind).build()
        }
        val item = MediaItem.Builder().setUri(address).setSubtitleConfigurations(configs).build()
        reportedPlaying = false
        seen.clear()
        e.setMediaItem(item, ((since ?: 0.0) * 1000).toLong().coerceAtLeast(0))
        e.prepare()
    }

    private fun buildMedia3(): ExoPlayer {
        val factory = DefaultRenderersFactory(context)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF)
            .setEnableDecoderFallback(true)
        val sources = DefaultDataSource.Factory(context, DefaultHttpDataSource.Factory().setUserAgent("Swiftly")
            .setAllowCrossProtocolRedirects(true)).setTransferListener(byteCounter)
        return ExoPlayer.Builder(context, factory)
            .setMediaSourceFactory(DefaultMediaSourceFactory(sources))
            // `PlayItem` manages audio focus itself, as with VLC.
            .setAudioAttributes(androidx.media3.common.AudioAttributes.Builder().setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), false)
            .build().also { it.addListener(media3Listener) }
    }

    /** Take Media3 down (main thread), if it was running. */
    fun media3Down() {
        val e = exo ?: run { usesMedia3 = false; return }
        usesMedia3 = false
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
        exoPlaying = e.playWhenReady && (e.playbackState == Player.STATE_READY || e.playbackState == Player.STATE_BUFFERING)
    }

    private val media3Listener = object : Player.Listener {
        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            val e = exo ?: return
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
                    if (e.playWhenReady && !reportedPlaying) { reportedPlaying = true; emit(Event.Playing) }
                }
                Player.STATE_ENDED -> { reportedPlaying = false; emit(Event.Ended) }
                Player.STATE_IDLE -> if (reportedPlaying) { reportedPlaying = false; emit(Event.Stopped) }
            }
        }

        override fun onRenderedFirstFrame() = emit(Event.Frame)

        override fun onCues(cueGroup: CueGroup) { subtitleView?.setCues(cueGroup.cues) }

        override fun onPlayerError(error: PlaybackException) {
            AppLog.writeOut("[Media3] Fehler ${error.errorCodeName}: ${error.message}")
            emit(Event.Error)
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            if (videoSize.width > 0 && videoSize.height > 0)
                frame?.setAspectRatio(videoSize.width * videoSize.pixelWidthHeightRatio / videoSize.height)
        }

        override fun onTracksChanged(tracks: Tracks) {
            for (s in tracksOf(C.TRACK_TYPE_TEXT)) if (seen.add(s.first)) emit(Event.TextTrackNew(s.first))
            exo?.videoFormat?.let { AppLog.writeOut("[Media3] Video ${it.sampleMimeType} ${it.codecs.orEmpty()} ${it.width}×${it.height}") }
        }
    }

    // MARK: Control: the same names as libVLC's `MediaPlayer`.

    val isPlaying: Boolean get() = if (usesMedia3) exoPlaying else vlcPlayer.isPlaying

    /** Milliseconds. */
    var time: Long
        get() = if (!usesMedia3) vlcPlayer.time else exo?.takeIf { onMainThread() }?.currentPosition?.also { exoTime = it } ?: exoTime
        set(value) { if (usesMedia3) onMain { exo?.seekTo(value.coerceAtLeast(0)) } else vlcPlayer.time = value }

    /** Milliseconds, 0 while unknown. */
    val length: Long get() = if (!usesMedia3) vlcPlayer.length
        else exo?.takeIf { onMainThread() }?.duration?.let { if (it == C.TIME_UNSET) 0L else it } ?: 0L

    fun play() { if (usesMedia3) onMain { exo?.playWhenReady = true } else vlcPlayer.play() }
    fun pause() { if (usesMedia3) onMain { exo?.playWhenReady = false } else vlcPlayer.pause() }

    /** Stop VLC (VLC thread; it can block). Does not touch Media3. */
    fun stopVlc() { vlcPlayer.stop() }
    /** Stop Media3 (main thread). */
    fun stopMedia3() { onMain { exo?.stop() } }

    /** 0…100 as with VLC. */
    var volume: Int
        get() = if (!usesMedia3) vlcPlayer.volume else exo?.takeIf { onMainThread() }?.let { (it.volume * 100).toInt() } ?: 100
        set(value) { if (usesMedia3) onMain { exo?.volume = value.coerceIn(0, 100) / 100f } else vlcPlayer.volume = value }

    fun rateSet(value: Float) { if (usesMedia3) onMain { exo?.setPlaybackSpeed(value) } else vlcPlayer.rate = value }

    fun hasMedia(): Boolean = if (usesMedia3) exo?.takeIf { onMainThread() }?.let { it.mediaItemCount > 0 } ?: true else vlcPlayer.hasMedia()

    /** Release VLC's player (VLC thread). Media3 has been released beforehand (`media3Down`, main thread). */
    fun releaseVlc() { vlcPlayer.release() }

    // MARK: Sound for VLC: Media3 passes through by itself what the output reports.

    fun audioDigitalOutputSet(on: Boolean) { if (!usesMedia3) vlcPlayer.setAudioDigitalOutputEnabled(on) }
    fun audioDigitalEncodingsForce(k: IntArray) { if (!usesMedia3) vlcPlayer.forceAudioDigitalEncodings(k) }

    // MARK: Delay: VLC only.

    val spuDelay: Long get() = if (usesMedia3) 0 else vlcPlayer.spuDelay
    val audioDelay: Long get() = if (usesMedia3) 0 else vlcPlayer.audioDelay
    fun spuDelaySet(us: Long) { if (!usesMedia3) vlcPlayer.setSpuDelay(us) }
    fun audioDelaySet(us: Long) { if (!usesMedia3) vlcPlayer.setAudioDelay(us) }

    fun slaveAdd(kind: Int, uri: Uri, select: Boolean): Boolean = if (usesMedia3) false else vlcPlayer.addSlave(kind, uri, select)

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
    }

    val audioTracks: List<Track>? get() = if (usesMedia3) tracksOf(C.TRACK_TYPE_AUDIO).map { Track(it.first, it.second.label) }
        else vlcPlayer.audioTracks?.map { Track(it.id, it.name) }
    val spuTracks: List<Track>? get() = if (usesMedia3) tracksOf(C.TRACK_TYPE_TEXT).map { Track(it.first, it.second.label) }
        else vlcPlayer.spuTracks?.map { Track(it.id, it.name) }
    val audioTracksCount: Int get() = if (usesMedia3) tracksOf(C.TRACK_TYPE_AUDIO).size else vlcPlayer.audioTracksCount

    var audioTrack: Int
        get() = if (usesMedia3) selectedOf(C.TRACK_TYPE_AUDIO) else vlcPlayer.audioTrack
        set(id) { if (usesMedia3) choose(C.TRACK_TYPE_AUDIO, id) else vlcPlayer.audioTrack = id }
    var spuTrack: Int
        get() = if (usesMedia3) selectedOf(C.TRACK_TYPE_TEXT) else vlcPlayer.spuTrack
        set(id) { if (usesMedia3) choose(C.TRACK_TYPE_TEXT, id) else vlcPlayer.spuTrack = id }

    /** Language, codec and channels per track id; with VLC from the media. */
    fun trackDetails(): Map<Int, TrackDetail> {
        if (usesMedia3) {
            return (tracksOf(C.TRACK_TYPE_AUDIO).map { it to true } + tracksOf(C.TRACK_TYPE_TEXT).map { it to false })
                .associate { (s, audio) ->
                    val f = s.second
                    s.first to TrackDetail(s.first, audio, f.language?.takeIf { it != C.LANGUAGE_UNDETERMINED }, fourccOf(f),
                        f.channelCount.coerceAtLeast(0), f.sampleRate.coerceAtLeast(0),
                        // Media3 may put something in front of the id when merging.
                        f.id?.substringAfter("datei:", "")?.takeWhile { it.isDigit() }?.toLongOrNull())
                }
        }
        val m = vlcPlayer.media ?: return emptyMap()
        try {
            return (0 until m.trackCount).mapNotNull { m.getTrack(it) }.associate { t ->
                val audio = t as? IMedia.AudioTrack
                t.id to TrackDetail(t.id, audio != null, t.language, t.fourcc, audio?.channels ?: 0, audio?.rate ?: 0, null)
            }
        } finally { m.release() }
    }

    /** The file's frame rate once known, for `TvImageTick`. */
    fun frameRate(): Double? {
        if (usesMedia3) return exo?.takeIf { onMainThread() }?.videoFormat?.frameRate?.takeIf { it > 0 }?.toDouble()
        val s = vlcPlayer.currentVideoTrack ?: return null
        if (s.frameRateDen <= 0) return null
        return s.frameRateNum.toDouble() / s.frameRateDen.toDouble()
    }

    /** Counters like VLC's `Media.Stats`; with Media3 from the decoder counters and the bytes read. */
    fun counters(): Counters? {
        if (usesMedia3) {
            val e = exo?.takeIf { onMainThread() } ?: return null
            val v = e.videoDecoderCounters?.also { it.ensureUpdated() }
            val a = e.audioDecoderCounters?.also { it.ensureUpdated() }
            val shown = (v?.renderedOutputBufferCount ?: 0).toLong()
            val read = bytesRead.get()
            return Counters(read, read, shown, (v?.droppedBufferCount ?: 0).toLong(),
                shown + (v?.droppedBufferCount ?: 0) + (v?.skippedOutputBufferCount ?: 0),
                (a?.renderedOutputBufferCount ?: 0).toLong(), (a?.renderedOutputBufferCount ?: 0).toLong(), 0, 0, 0)
        }
        val m = vlcPlayer.media ?: return null
        val w = m.stats
        m.release()
        w ?: return null
        fun raw(x: Int) = x.toLong() and 0xFFFFFFFFL
        return Counters(raw(w.readBytes), raw(w.demuxReadBytes), raw(w.displayedPictures), raw(w.lostPictures),
            raw(w.decodedVideo), raw(w.decodedAudio), raw(w.playedAbuffers), raw(w.lostAbuffers),
            raw(w.demuxCorrupted), raw(w.demuxDiscontinuity))
    }

    companion object {
        /**
         * **Can this device show Dolby Vision?** A Dolby Vision decoder and a display that reports Dolby
         * Vision; otherwise Media3 gains nothing and VLC stays (it plays the same base layer).
         */
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
         * **Can Media3 play this sound without a decoder extension?** The device decodes it (MediaCodec) or can
         * pass it through to the output. `codec` is the Jellyfin name of the default track (`""`: no sound).
         */
        fun audioPlayable(context: Context, codec: String): Boolean {
            if (codec.isEmpty()) return true
            val mime = EngineChoice.audioMime(codec) ?: return false
            if (mime == MimeTypes.AUDIO_RAW) return true
            val decodes = runCatching { MediaCodecUtil.getDecoderInfos(mime, false, false).isNotEmpty() }.getOrDefault(false)
            if (decodes) return true
            return runCatching {
                val format = Format.Builder().setSampleMimeType(mime).setChannelCount(6).setSampleRate(48_000).build()
                AudioCapabilities.getCapabilities(context, AudioAttributes.DEFAULT, null)
                    .isPassthroughPlaybackSupported(format, AudioAttributes.DEFAULT)
            }.getOrDefault(false)
        }

        /** Subtitle files Media3 can load alongside, by the ending of the address. */
        private fun subtitleKind(url: String): String? = when (Uri.parse(url).lastPathSegment?.substringAfterLast('.')?.lowercase()) {
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
