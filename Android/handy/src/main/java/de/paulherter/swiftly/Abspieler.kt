package de.paulherter.swiftly

import android.content.Context
import android.hardware.display.DisplayManager
import android.net.Uri
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
import androidx.media3.common.text.CueGroup
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.interfaces.IMedia
import org.videolan.libvlc.util.VLCVideoLayout

/**
 * **Zwei Maschinen hinter einem Griff.** libVLC spielt alles — nur Dolby Vision geht an Media3.
 *
 * libVLC 3 fordert bei MediaCodec nie `video/dolby-vision` an, sondern immer `video/hevc`: der Dekoder
 * verwirft die DV-Schicht, und der Fernseher schaltet auf die Basisschicht (HDR10 oder HDR10+). Media3
 * nimmt den DV-Dekoder des Geraets, wenn es einen gibt. `Spielwerk` spricht nur mit dieser Klasse;
 * die Namen folgen libVLCs `MediaPlayer`, damit der Rest des Players bleiben konnte, wie er war.
 *
 * Im Media3-Betrieb fehlt, was nur VLC kann: Ton- und Untertitelverzoegerung. **Untertitel zeichnet Media3
 * nicht ins Bild** wie VLC — es reicht sie als Text oder Bild heraus, die `SubtitleView` ueber dem Video
 * zeigt sie, im Stil von VLC hier (weiss, schwarze Kontur, ohne Kasten).
 */
@OptIn(UnstableApi::class)
class Abspieler(private val kontext: Context, val vlc: LibVLC, private val fernseher: Boolean) {
    val vlcSpieler = MediaPlayer(vlc)
    private var exo: ExoPlayer? = null
    /** Laeuft gerade Media3 statt VLC? */
    val mitMedia3: Boolean get() = exo != null

    /** Eine Spur, wie VLCs `TrackDescription`: id und Name. */
    class Spur(val id: Int, val name: String?)
    /** Was ueber eine Spur bekannt ist — `fourcc` in VLCs Kennung, damit der Kern sie gleich liest. */
    class Spurangabe(val id: Int, val ton: Boolean, val sprache: String?, val fourcc: Int, val kanaele: Int, val rate: Int,
                     /** Jellyfin-Index einer angehaengten Untertiteldatei (nur Media3). */
                     val datei: Long?)
    /** VLCs `Media.Stats`, vorzeichenlos gelesen. */
    class Zaehler(val readBytes: Long, val demuxReadBytes: Long, val displayedPictures: Long, val lostPictures: Long,
                  val decodedVideo: Long, val decodedAudio: Long, val playedAbuffers: Long, val lostAbuffers: Long,
                  val demuxCorrupted: Long, val demuxDiscontinuity: Long)

    sealed interface Ereignis {
        data object Laeuft : Ereignis
        data object Angehalten : Ereignis
        data object Gestoppt : Ereignis
        data object Bild : Ereignis
        data class Puffer(val prozent: Float) : Ereignis
        data object Ende : Ereignis
        data object Fehler : Ereignis
        data class TextspurNeu(val id: Int) : Ereignis
    }

    private var hoerer: (Ereignis) -> Unit = {}

    fun ereignisseAn(h: (Ereignis) -> Unit) {
        hoerer = h
        vlcSpieler.setEventListener { e ->
            if (mitMedia3) return@setEventListener
            when (e.type) {
                MediaPlayer.Event.Playing -> h(Ereignis.Laeuft)
                MediaPlayer.Event.Paused -> h(Ereignis.Angehalten)
                MediaPlayer.Event.Stopped -> h(Ereignis.Gestoppt)
                MediaPlayer.Event.Vout -> if (e.voutCount > 0) h(Ereignis.Bild)
                MediaPlayer.Event.Buffering -> h(Ereignis.Puffer(e.buffering))
                MediaPlayer.Event.EndReached -> h(Ereignis.Ende)
                MediaPlayer.Event.EncounteredError -> h(Ereignis.Fehler)
                MediaPlayer.Event.ESAdded -> if (e.esChangedType == IMedia.Track.Type.Text) h(Ereignis.TextspurNeu(e.esChangedID))
            }
        }
    }

    // MARK: Bild

    private var flaeche: VLCVideoLayout? = null
    private var rahmen: AspectRatioFrameLayout? = null
    private var untertitelflaeche: SubtitleView? = null
    private var bildfuellend = false

    /** Die Videoflaeche anhaengen — VLC an seine `VLCVideoLayout`, Media3 an eine eigene `SurfaceView` darin. */
    fun anhaengen(l: VLCVideoLayout) {
        flaeche = l
        if (mitMedia3) media3Anhaengen() else if (!vlcSpieler.vlcVout.areViewsAttached()) vlcSpieler.attachViews(l, null, true, false)
    }

    fun haengtAn(): Boolean = if (mitMedia3) rahmen?.parent != null else vlcSpieler.vlcVout.areViewsAttached()

    fun abhaengen() {
        if (vlcSpieler.vlcVout.areViewsAttached()) vlcSpieler.detachViews()
        rahmenWeg()
    }

    private fun media3Anhaengen() {
        val l = flaeche ?: return
        val e = exo ?: return
        if (vlcSpieler.vlcVout.areViewsAttached()) vlcSpieler.detachViews()
        // VLCs eigene Flaechen verstecken: zwei SurfaceViews uebereinander haben keine feste Reihenfolge.
        for (i in 0 until l.childCount) l.getChildAt(i).visibility = View.GONE
        val r = rahmen ?: AspectRatioFrameLayout(kontext).also { neu ->
            neu.addView(SurfaceView(kontext), FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            // Ueber dem Bild, im Rahmen des Videos — wie `PlayerView` es macht.
            val ut = SubtitleView(kontext).apply {
                setStyle(CaptionStyleCompat(android.graphics.Color.WHITE, android.graphics.Color.TRANSPARENT,
                    android.graphics.Color.TRANSPARENT, CaptionStyleCompat.EDGE_TYPE_OUTLINE, android.graphics.Color.BLACK, null))
                // VLCs Vorgabe sind 6,25 % der Bildhoehe, hier wie dort verkleinert (`--sub-text-scale`).
                setFractionalTextSize(0.0625f * (if (fernseher) 0.88f else 0.82f))
                setApplyEmbeddedStyles(true)
                setApplyEmbeddedFontSizes(false)
            }
            neu.addView(ut, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            untertitelflaeche = ut
            rahmen = neu
        }
        r.resizeMode = if (bildfuellend) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
        if (r.parent == null) l.addView(r, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER))
        r.visibility = View.VISIBLE
        e.setVideoSurfaceView(r.getChildAt(0) as SurfaceView)
    }

    private fun rahmenWeg() {
        val r = rahmen ?: return
        (r.getChildAt(0) as? SurfaceView)?.let { exo?.clearVideoSurfaceView(it) }
        (r.parent as? FrameLayout)?.removeView(r)
        rahmen = null
        untertitelflaeche = null
        flaeche?.let { l -> for (i in 0 until l.childCount) l.getChildAt(i).visibility = View.VISIBLE }
    }

    fun bildfuellendSetzen(neu: Boolean) {
        bildfuellend = neu
        vlcSpieler.videoScale = if (neu) MediaPlayer.ScaleType.SURFACE_FIT_SCREEN else MediaPlayer.ScaleType.SURFACE_BEST_FIT
        rahmen?.resizeMode = if (neu) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
    }

    // MARK: Oeffnen

    /** VLC spielt das Medium — Media3 wird dafuer abgebaut, falls es lief. */
    fun vlcOeffnen(media: Media) {
        media3Weg()
        flaeche?.let { if (!vlcSpieler.vlcVout.areViewsAttached()) vlcSpieler.attachViews(it, null, true, false) }
        vlcSpieler.media = media
        vlcSpieler.videoScale = if (bildfuellend) MediaPlayer.ScaleType.SURFACE_FIT_SCREEN else MediaPlayer.ScaleType.SURFACE_BEST_FIT
    }

    /** Gelesene Bytes fuer die Stromwacht — VLC zaehlt sie selbst, Media3 meldet sie hier. */
    private var gelesen = 0L
    private val zaehlerHoerer = object : TransferListener {
        override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
        override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
        override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) { gelesen += bytesTransferred }
        override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
    }

    /**
     * **Media3 spielt die Adresse ab `ab` Sekunden** — fuer Dolby Vision. Externe Untertitel gehen gleich mit
     * (`untertitel`: Jellyfin-Index und Adresse); nachtraeglich anhaengen wie bei VLC kann Media3 nicht.
     */
    fun media3Oeffnen(adresse: String, ab: Double?, untertitel: List<Pair<Long, String>>) {
        if (vlcSpieler.hasMedia()) vlcSpieler.stop()
        val e = exo ?: media3Bauen().also { exo = it }
        media3Anhaengen()
        val unterlagen = untertitel.mapNotNull { (index, url) ->
            val art = untertitelArt(url) ?: return@mapNotNull null
            MediaItem.SubtitleConfiguration.Builder(Uri.parse(url)).setId("datei:$index").setMimeType(art).build()
        }
        val eintrag = MediaItem.Builder().setUri(adresse).setSubtitleConfigurations(unterlagen).build()
        gemeldetLaeuft = false
        gesehen.clear()
        e.setMediaItem(eintrag, ((ab ?: 0.0) * 1000).toLong().coerceAtLeast(0))
        e.prepare()
    }

    private fun media3Bauen(): ExoPlayer {
        // FFmpeg nur, wenn das Geraet den Ton selbst nicht kann (DTS, TrueHD ohne Durchreichen).
        val werke = DefaultRenderersFactory(kontext)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
            .setEnableDecoderFallback(true)
        val quellen = DefaultDataSource.Factory(kontext, DefaultHttpDataSource.Factory().setUserAgent("Swiftly")
            .setAllowCrossProtocolRedirects(true)).setTransferListener(zaehlerHoerer)
        return ExoPlayer.Builder(kontext, werke)
            .setMediaSourceFactory(DefaultMediaSourceFactory(quellen))
            // Den Audiofokus fuehrt `Spielwerk` selbst, wie bei VLC.
            .setAudioAttributes(androidx.media3.common.AudioAttributes.Builder().setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), false)
            .build().also { it.addListener(media3Hoerer) }
    }

    private fun media3Weg() {
        val e = exo ?: return
        rahmenWeg()
        e.removeListener(media3Hoerer)
        e.release()
        exo = null
    }

    private var gemeldetLaeuft = false
    private val gesehen = HashSet<Int>()

    private val media3Hoerer = object : Player.Listener {
        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            val e = exo ?: return
            if (playWhenReady && e.playbackState == Player.STATE_READY && !gemeldetLaeuft) { gemeldetLaeuft = true; hoerer(Ereignis.Laeuft) }
            if (!playWhenReady && gemeldetLaeuft) { gemeldetLaeuft = false; hoerer(Ereignis.Angehalten) }
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            val e = exo ?: return
            when (playbackState) {
                Player.STATE_BUFFERING -> hoerer(Ereignis.Puffer(0f))
                Player.STATE_READY -> {
                    hoerer(Ereignis.Puffer(100f))
                    if (e.playWhenReady && !gemeldetLaeuft) { gemeldetLaeuft = true; hoerer(Ereignis.Laeuft) }
                }
                Player.STATE_ENDED -> { gemeldetLaeuft = false; hoerer(Ereignis.Ende) }
                Player.STATE_IDLE -> if (gemeldetLaeuft) { gemeldetLaeuft = false; hoerer(Ereignis.Gestoppt) }
            }
        }

        override fun onRenderedFirstFrame() = hoerer(Ereignis.Bild)

        override fun onCues(cueGroup: CueGroup) { untertitelflaeche?.setCues(cueGroup.cues) }

        override fun onPlayerError(error: PlaybackException) {
            Protokoll.schreib("[Media3] Fehler ${error.errorCodeName}: ${error.message}")
            hoerer(Ereignis.Fehler)
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            if (videoSize.width > 0 && videoSize.height > 0)
                rahmen?.setAspectRatio(videoSize.width * videoSize.pixelWidthHeightRatio / videoSize.height)
        }

        override fun onTracksChanged(tracks: Tracks) {
            for (s in spurenVon(C.TRACK_TYPE_TEXT)) if (gesehen.add(s.id)) hoerer(Ereignis.TextspurNeu(s.id))
            exo?.videoFormat?.let { Protokoll.schreib("[Media3] Video ${it.sampleMimeType} ${it.codecs.orEmpty()} ${it.width}×${it.height}") }
        }
    }

    // MARK: Steuerung — dieselben Namen wie libVLCs `MediaPlayer`.

    val isPlaying: Boolean get() = exo?.let { it.playWhenReady && (it.playbackState == Player.STATE_READY || it.playbackState == Player.STATE_BUFFERING) }
        ?: vlcSpieler.isPlaying

    /** Millisekunden. */
    var time: Long
        get() = exo?.currentPosition ?: vlcSpieler.time
        set(wert) { exo?.seekTo(wert.coerceAtLeast(0)) ?: run { vlcSpieler.time = wert } }

    /** Millisekunden, 0 solange unbekannt. */
    val length: Long get() = exo?.duration?.let { if (it == C.TIME_UNSET) 0L else it } ?: vlcSpieler.length

    fun play() { exo?.let { it.playWhenReady = true } ?: vlcSpieler.play() }
    fun pause() { exo?.let { it.playWhenReady = false } ?: vlcSpieler.pause() }
    fun stop() { exo?.stop() ?: vlcSpieler.stop() }

    /** 0…100 wie bei VLC. */
    var volume: Int
        get() = exo?.let { (it.volume * 100).toInt() } ?: vlcSpieler.volume
        set(wert) { exo?.let { it.volume = wert.coerceIn(0, 100) / 100f } ?: run { vlcSpieler.volume = wert } }

    fun rateSetzen(wert: Float) { exo?.setPlaybackSpeed(wert) ?: run { vlcSpieler.rate = wert } }

    fun hasMedia(): Boolean = exo?.let { it.mediaItemCount > 0 } ?: vlcSpieler.hasMedia()

    fun release() {
        media3Weg()
        if (vlcSpieler.vlcVout.areViewsAttached()) vlcSpieler.detachViews()
        vlcSpieler.release()
    }

    // MARK: Ton fuer VLC — Media3 reicht von selbst durch, was der Ausgang meldet.

    fun setAudioDigitalOutputEnabled(an: Boolean) { if (!mitMedia3) vlcSpieler.setAudioDigitalOutputEnabled(an) }
    fun forceAudioDigitalEncodings(k: IntArray) { if (!mitMedia3) vlcSpieler.forceAudioDigitalEncodings(k) }

    // MARK: Verzoegerung — nur VLC.

    val spuDelay: Long get() = if (mitMedia3) 0 else vlcSpieler.spuDelay
    val audioDelay: Long get() = if (mitMedia3) 0 else vlcSpieler.audioDelay
    fun setSpuDelay(us: Long) { if (!mitMedia3) vlcSpieler.setSpuDelay(us) }
    fun setAudioDelay(us: Long) { if (!mitMedia3) vlcSpieler.setAudioDelay(us) }

    fun addSlave(art: Int, uri: Uri, waehlen: Boolean): Boolean = if (mitMedia3) false else vlcSpieler.addSlave(art, uri, waehlen)

    // MARK: Spuren — Media3-ids sind Gruppe × 100 + Spur; -1 heisst aus, wie bei VLC.

    private fun spurenVon(art: Int): List<Pair<Int, Format>> {
        val e = exo ?: return emptyList()
        val liste = ArrayList<Pair<Int, Format>>()
        e.currentTracks.groups.forEachIndexed { g, gruppe ->
            if (gruppe.type != art) return@forEachIndexed
            for (t in 0 until gruppe.length) if (gruppe.isTrackSupported(t, true)) liste += (g * 100 + t) to gruppe.getTrackFormat(t)
        }
        return liste
    }

    private val Pair<Int, Format>.id get() = first

    private fun gewaehlt(art: Int): Int {
        val e = exo ?: return -1
        e.currentTracks.groups.forEachIndexed { g, gruppe ->
            if (gruppe.type != art) return@forEachIndexed
            for (t in 0 until gruppe.length) if (gruppe.isTrackSelected(t)) return g * 100 + t
        }
        return -1
    }

    private fun waehlen(art: Int, id: Int) {
        val e = exo ?: return
        val p = e.trackSelectionParameters.buildUpon()
        val gruppe = e.currentTracks.groups.getOrNull(id / 100)
        if (id < 0 || gruppe == null || gruppe.type != art || id % 100 >= gruppe.length) {
            p.setTrackTypeDisabled(art, true)
        } else {
            p.setTrackTypeDisabled(art, false).setOverrideForType(TrackSelectionOverride(gruppe.mediaTrackGroup, id % 100))
        }
        e.trackSelectionParameters = p.build()
        Protokoll.schreib("[Media3] ${if (art == C.TRACK_TYPE_TEXT) "Untertitel" else "Ton"} → $id")
        if (art == C.TRACK_TYPE_TEXT && id < 0) untertitelflaeche?.setCues(emptyList())
    }

    val audioTracks: List<Spur>? get() = if (mitMedia3) spurenVon(C.TRACK_TYPE_AUDIO).map { Spur(it.first, it.second.label) }
        else vlcSpieler.audioTracks?.map { Spur(it.id, it.name) }
    val spuTracks: List<Spur>? get() = if (mitMedia3) spurenVon(C.TRACK_TYPE_TEXT).map { Spur(it.first, it.second.label) }
        else vlcSpieler.spuTracks?.map { Spur(it.id, it.name) }
    val audioTracksCount: Int get() = if (mitMedia3) spurenVon(C.TRACK_TYPE_AUDIO).size else vlcSpieler.audioTracksCount

    var audioTrack: Int
        get() = if (mitMedia3) gewaehlt(C.TRACK_TYPE_AUDIO) else vlcSpieler.audioTrack
        set(id) { if (mitMedia3) waehlen(C.TRACK_TYPE_AUDIO, id) else vlcSpieler.audioTrack = id }
    var spuTrack: Int
        get() = if (mitMedia3) gewaehlt(C.TRACK_TYPE_TEXT) else vlcSpieler.spuTrack
        set(id) { if (mitMedia3) waehlen(C.TRACK_TYPE_TEXT, id) else vlcSpieler.spuTrack = id }

    /** Sprache, Codec und Kanaele je Spur-id — bei VLC aus dem Medium. */
    fun spurangaben(): Map<Int, Spurangabe> {
        if (mitMedia3) {
            return (spurenVon(C.TRACK_TYPE_AUDIO).map { it to true } + spurenVon(C.TRACK_TYPE_TEXT).map { it to false })
                .associate { (s, ton) ->
                    val f = s.second
                    s.first to Spurangabe(s.first, ton, f.language?.takeIf { it != C.LANGUAGE_UNDETERMINED }, kennungAus(f),
                        f.channelCount.coerceAtLeast(0), f.sampleRate.coerceAtLeast(0),
                        // Media3 kann der Kennung beim Zusammenfuehren etwas voranstellen.
                        f.id?.substringAfter("datei:", "")?.takeWhile { it.isDigit() }?.toLongOrNull())
                }
        }
        val m = vlcSpieler.media ?: return emptyMap()
        try {
            return (0 until m.trackCount).mapNotNull { m.getTrack(it) }.associate { t ->
                val ton = t as? IMedia.AudioTrack
                t.id to Spurangabe(t.id, ton != null, t.language, t.fourcc, ton?.channels ?: 0, ton?.rate ?: 0, null)
            }
        } finally { m.release() }
    }

    /** Die Bildrate der Datei, sobald bekannt — fuer `TvBildtakt`. */
    fun bildrate(): Double? {
        exo?.let { e -> return e.videoFormat?.frameRate?.takeIf { it > 0 }?.toDouble() }
        val s = vlcSpieler.currentVideoTrack ?: return null
        if (s.frameRateDen <= 0) return null
        return s.frameRateNum.toDouble() / s.frameRateDen.toDouble()
    }

    /** Zaehler wie VLCs `Media.Stats` — bei Media3 aus den Dekoder-Zaehlern und den gelesenen Bytes. */
    fun zaehler(): Zaehler? {
        exo?.let { e ->
            val v = e.videoDecoderCounters?.also { it.ensureUpdated() }
            val a = e.audioDecoderCounters?.also { it.ensureUpdated() }
            val gezeigt = (v?.renderedOutputBufferCount ?: 0).toLong()
            return Zaehler(gelesen, gelesen, gezeigt, (v?.droppedBufferCount ?: 0).toLong(),
                gezeigt + (v?.droppedBufferCount ?: 0) + (v?.skippedOutputBufferCount ?: 0),
                (a?.renderedOutputBufferCount ?: 0).toLong(), (a?.renderedOutputBufferCount ?: 0).toLong(), 0, 0, 0)
        }
        val m = vlcSpieler.media ?: return null
        val w = m.stats
        m.release()
        w ?: return null
        fun roh(x: Int) = x.toLong() and 0xFFFFFFFFL
        return Zaehler(roh(w.readBytes), roh(w.demuxReadBytes), roh(w.displayedPictures), roh(w.lostPictures),
            roh(w.decodedVideo), roh(w.decodedAudio), roh(w.playedAbuffers), roh(w.lostAbuffers),
            roh(w.demuxCorrupted), roh(w.demuxDiscontinuity))
    }

    companion object {
        /**
         * **Kann dieses Geraet Dolby Vision zeigen?** Ein DV-Dekoder und ein Bildschirm, der DV meldet —
         * sonst bringt Media3 nichts, und VLC bleibt (dort laeuft dieselbe Basisschicht).
         */
        fun dolbyVisionMoeglich(kontext: Context): Boolean {
            val dekoder = runCatching { MediaCodecUtil.getDecoderInfos(MimeTypes.VIDEO_DOLBY_VISION, false, false).isNotEmpty() }
                .getOrDefault(false)
            if (!dekoder) return false
            val anzeige = (kontext.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager)?.getDisplay(Display.DEFAULT_DISPLAY) ?: return false
            @Suppress("DEPRECATION")
            val arten = if (android.os.Build.VERSION.SDK_INT >= 34) anzeige.mode.supportedHdrTypes
                        else anzeige.hdrCapabilities?.supportedHdrTypes ?: IntArray(0)
            @Suppress("DEPRECATION")
            return Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION in arten
        }

        /** Untertiteldateien, die Media3 nebenher laden kann — nach der Endung der Adresse. */
        private fun untertitelArt(url: String): String? = when (Uri.parse(url).lastPathSegment?.substringAfterLast('.')?.lowercase()) {
            "srt", "subrip" -> MimeTypes.APPLICATION_SUBRIP
            "vtt", "webvtt" -> MimeTypes.TEXT_VTT
            "ass", "ssa" -> MimeTypes.TEXT_SSA
            "ttml" -> MimeTypes.APPLICATION_TTML
            else -> null
        }

        /** VLCs vierstellige Kennung (`fourcc`, kleinstes Byte zuerst) aus Media3s MIME-Typ. */
        private fun kennungAus(f: Format): Int {
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
            return k.foldIndexed(0) { i, summe, z -> summe or (z.code shl (8 * i)) }
        }
    }
}
