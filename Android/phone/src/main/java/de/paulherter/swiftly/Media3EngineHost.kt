package de.paulherter.swiftly

import android.os.Handler
import android.os.Looper
import de.paulherter.swiftly.rustcore.PlayerEngineEvent
import de.paulherter.swiftly.rustcore.PlayerEngineState
import de.paulherter.swiftly.rustcore.PlayerLoad
import de.paulherter.swiftly.rustcore.PlayerPip
import de.paulherter.swiftly.rustcore.PlayerRect
import de.paulherter.swiftly.rustcore.PlayerSubtitleRoute
import de.paulherter.swiftly.rustcore.PlayerTrack
import de.paulherter.swiftly.rustcore.PlayerEngine as CoreEngine

/**
 * The Rust core's `PlayerEngine` (commands out, events in) over the app's Media3 wrapper ([PlayerEngine]): the
 * Media3 code, its delays, track ids, display-rate vote and SurfaceView stay exactly as they are; this class only
 * speaks the core's language.
 *
 * - **Commands return at once.** Every call is posted to the main thread by the wrapper itself; nothing here waits.
 * - **Events never run under a core lock.** The wrapper's events arrive on the main thread and go to [sink]
 *   (`PlayerVm.engineEvent`) from there, the same thread that issued the command, never from inside one.
 * - **Server indexes.** The core speaks Jellyfin stream indexes, Media3 has its own track ids (group x 100 + track).
 *   [audioOrder]/[subtitleOrder] are the server indexes of the title's audio and text streams in container order; Media3
 *   lists its tracks in the same order, so position n is server index `order[n]`. An attached subtitle file carries
 *   its server index in its id (`datei:<index>`), which wins. With no order set the server index is the position.
 * - **Clock.** While a title is open the position goes out every [clockMs] on the main thread (`Clock`), the duration
 *   once it is known.
 */
class Media3EngineHost(
    private val engine: PlayerEngine,
    private val clockMs: Long = 250,
) : CoreEngine {
    /** Set to `{ vm.engineEvent(it) }` after `Core.playerVm`. */
    @Volatile var sink: ((PlayerEngineEvent) -> Unit)? = null
    @Volatile var audioOrder: List<Long> = emptyList()
    @Volatile var subtitleOrder: List<Long> = emptyList()
    /** Applies the settings that fix how Media3 is built (`PlayerEngine.media3Configure`) before every load. */
    @Volatile var configure: ((PlayerLoad) -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())
    private var attempt = 0
    private var lastDuration = 0L
    private var wantedAudio: Long? = null
    private var ticking = false
    private var lastState: PlayerEngineState? = null

    private fun emit(e: PlayerEngineEvent) { sink?.invoke(e) }
    private fun state(s: PlayerEngineState) { if (s != lastState) { lastState = s; emit(PlayerEngineEvent.State(s)) } }

    init {
        engine.onEvents { e ->
            when (e) {
                PlayerEngine.Event.Playing -> { state(PlayerEngineState.Playing); announceTracks(); startClock() }
                PlayerEngine.Event.Paused -> state(PlayerEngineState.Paused)
                PlayerEngine.Event.Stopped -> state(PlayerEngineState.Idle)
                PlayerEngine.Event.Frame -> emit(PlayerEngineEvent.FirstFrame)
                is PlayerEngine.Event.Buffering -> if (e.percent < 100f) state(PlayerEngineState.Loading) else announceTracks()
                PlayerEngine.Event.Ended -> { state(PlayerEngineState.Ended); ticking = false }
                PlayerEngine.Event.Error -> {
                    val kind = engine.lastError
                    state(PlayerEngineState.Error("Media3: ${kind?.name ?: "unknown"}", kind?.name))
                    ticking = false
                }
            }
        }
    }

    private fun startClock() {
        if (ticking) return
        ticking = true
        main.post(object : Runnable {
            override fun run() {
                if (!ticking) return
                val seconds = engine.time / 1000.0
                emit(PlayerEngineEvent.Clock(seconds, seconds))
                val length = engine.length
                if (length > 0 && length != lastDuration) { lastDuration = length; emit(PlayerEngineEvent.Duration(length / 1000.0)) }
                main.postDelayed(this, clockMs)
            }
        })
    }

    // ---- track mapping --------------------------------------------------------------------------------------------

    private fun serverIndexOf(order: List<Long>, position: Int, detail: PlayerEngine.TrackDetail?): Long =
        detail?.file ?: order.getOrNull(position) ?: position.toLong()

    private fun announceTracks() {
        val details = engine.trackDetails()
        fun list(audio: Boolean, order: List<Long>): List<PlayerTrack> {
            val tracks = (if (audio) engine.audioTracks else engine.spuTracks).orEmpty()
            return tracks.mapIndexed { position, t ->
                val d = details[t.id]
                PlayerTrack(
                    id = serverIndexOf(order, position, d), codec = d?.let { fourcc(it.fourcc) }.orEmpty(), language = d?.language,
                    name = t.name.orEmpty(), channels = (d?.channels ?: 0).toLong(), isDefault = false, isForced = false,
                )
            }
        }
        val audio = list(true, audioOrder)
        val subs = list(false, subtitleOrder)
        fun active(tracks: List<PlayerTrack>, selected: Int, source: List<PlayerEngine.Track>?): Long? =
            source?.indexOfFirst { it.id == selected }?.takeIf { it >= 0 }?.let { tracks.getOrNull(it)?.id }
        emit(PlayerEngineEvent.Tracks(
            audio = audio, subtitles = subs,
            activeAudio = active(audio, engine.audioTrack, engine.audioTracks),
            activeSubtitle = active(subs, engine.spuTrack, engine.spuTracks),
        ))
    }

    private fun fourcc(code: Int): String = if (code == 0) "" else
        String(byteArrayOf((code shr 24).toByte(), (code shr 16).toByte(), (code shr 8).toByte(), code.toByte())).trim()

    /** The Media3 track id for a server index, or `null`. */
    private fun engineId(audio: Boolean, serverIndex: Int): Int? {
        val order = if (audio) audioOrder else subtitleOrder
        val tracks = (if (audio) engine.audioTracks else engine.spuTracks).orEmpty()
        val details = engine.trackDetails()
        tracks.firstOrNull { details[it.id]?.file == serverIndex.toLong() }?.let { return it.id }
        val position = if (order.isEmpty()) serverIndex else order.indexOf(serverIndex.toLong())
        return tracks.getOrNull(position)?.id?.takeIf { position >= 0 }
    }

    // ---- PlayerEngine -----------------------------------------------------------------------------------------------

    override fun load(request: PlayerLoad) {
        attempt += 1
        val n = attempt
        wantedAudio = request.audioServerIndex
        lastState = null
        state(PlayerEngineState.Loading)
        configure?.invoke(request)
        main.post {
            val files = request.externalSubtitles.mapIndexedNotNull { i, s ->
                // The core hands the files in the order of their engine track ids; the server index sits in the name.
                (subtitleOrder.getOrNull(i) ?: (-1L - i)) to s.url
            }
            engine.openMedia3(request.url, request.start, files)
            emit(PlayerEngineEvent.LoadFinished(n.toUInt()))
        }
    }

    override fun play() = engine.play()
    override fun pause() = engine.pause()
    override fun seek(seconds: Double) { engine.time = (seconds * 1000).toLong() }
    override fun setRate(tempo: Float) = engine.rateSet(tempo)
    override fun setVolume(percent: UByte) { engine.volume = percent.toInt() }
    private var audioDelay = 0
    private var subtitleDelay = 0
    override fun setAudioDelay(milliseconds: Int) { audioDelay = milliseconds; engine.delaysMedia3Set(audioDelay, subtitleDelay) }
    override fun setSubtitleDelay(milliseconds: Int) { subtitleDelay = milliseconds; engine.delaysMedia3Set(audioDelay, subtitleDelay) }

    override fun selectAudio(serverIndex: Int): Boolean {
        val id = engineId(true, serverIndex) ?: return false
        engine.audioTrack = id
        return true
    }

    /** Media3 hands subtitles out as cues and the app's `SubtitleView` draws them: the core's `EngineDrawn` route. */
    override fun selectSubtitle(serverIndex: Int): PlayerSubtitleRoute {
        if (serverIndex < 0) { engine.spuTrack = -1; return PlayerSubtitleRoute.CUES }
        val id = engineId(false, serverIndex) ?: return PlayerSubtitleRoute.UNSUPPORTED
        engine.spuTrack = id
        return PlayerSubtitleRoute.CUES
    }

    override fun setFill(on: Boolean) = engine.fillFrameSet(on)
    /** The Android surface fills its own frame; the layout decides the place (the Compose side). */
    override fun place(rect: PlayerRect) {}
    override fun stop(resetDisplay: Boolean) { ticking = false; engine.stopMedia3(); }
    /** Picture in picture belongs to the activity (`PlayerActivity`), which reports `PipActive` itself. */
    override fun pip(command: PlayerPip) {}
}
