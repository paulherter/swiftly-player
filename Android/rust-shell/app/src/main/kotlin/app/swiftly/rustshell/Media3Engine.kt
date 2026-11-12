package app.swiftly.rustshell

import android.content.Context
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import android.view.SurfaceView
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.VideoSize
import androidx.media3.common.text.CueGroup
import androidx.media3.exoplayer.ExoPlayer
import org.json.JSONArray
import org.json.JSONObject

/**
 * The Android half of the player contract (G3): ExoPlayer drawing into a SurfaceView that lies below the UI surface. It
 * talks to Rust only in JSON lines (`Native.engineCommands()` in, `Native.engineEvent()` out; format in
 * swiftly_player_surface::wire), so the Rust player screen sees the same events as with libmpv.
 */
class Media3Engine(context: Context, private val video: SurfaceView) : Player.Listener {
    private val player = ExoPlayer.Builder(context).build()
    private var lastClock = 0L
    private var lastStats = 0L
    private var firstSent = false
    private var trackIds = mutableMapOf<Int, Tracks.Group>()

    init {
        player.addListener(this)
        player.setVideoSurfaceView(video)
    }

    private fun send(o: JSONObject) {
        Native.engineEvent(o.toString())
    }

    private fun ev(name: String, build: JSONObject.() -> Unit = {}) = send(JSONObject().put("e", name).apply(build))

    /** Applies the command lines Rust queued since the last frame. */
    fun apply(lines: String) {
        for (line in lines.lineSequence().filter { it.isNotBlank() }) {
            val c = JSONObject(line)
            when (c.getString("c")) {
                "load" -> {
                    firstSent = false
                    player.setMediaItem(MediaItem.fromUri(c.getString("url")))
                    if (!c.isNull("start")) player.seekTo((c.getDouble("start") * 1000).toLong())
                    player.prepare()
                    player.playWhenReady = true
                    ev("state") { put("s", "loading") }
                }
                "play" -> player.play()
                "pause" -> player.pause()
                "seek" -> { ev("state") { put("s", "seeking") }; player.seekTo((c.getDouble("s") * 1000).toLong()) }
                "rate" -> player.setPlaybackSpeed(c.getDouble("v").toFloat())
                "volume" -> player.volume = c.getInt("v") / 100f
                "audio" -> select(C.TRACK_TYPE_AUDIO, c.getInt("i"))
                "sub" -> if (c.getInt("i") < 0) {
                    player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
                        .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build()
                } else {
                    player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
                        .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false).build()
                    select(C.TRACK_TYPE_TEXT, c.getInt("i"))
                }
                "stop" -> player.stop()
                // fill, place, delay, pip: not wired in this slice.
            }
        }
    }

    private fun select(type: Int, id: Int) {
        val g = trackIds[id] ?: return
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, 0)).build()
    }

    /** Once per frame: position and the stats line (about 4 and 1 per second). */
    fun tick() {
        val now = SystemClock.uptimeMillis()
        if (player.isPlaying && now - lastClock >= 250) {
            lastClock = now
            ev("clock") { put("p", player.currentPosition / 1000.0) }
        }
        if (now - lastStats >= 1000) {
            lastStats = now
            val d = player.videoDecoderCounters ?: return
            d.ensureUpdated()
            val rendered = d.renderedOutputBufferCount
            val dropped = d.droppedBufferCount + d.skippedOutputBufferCount
            ev("stats") { put("rendered", rendered); put("dropped", dropped); put("codec", player.videoFormat?.sampleMimeType ?: "") }
            Log.i("SwiftlyMedia3", "stats rendered=$rendered dropped=$dropped pos=${player.currentPosition} playing=${player.isPlaying}")
        }
    }

    override fun onPlaybackStateChanged(state: Int) {
        when (state) {
            Player.STATE_BUFFERING -> ev("state") { put("s", "loading") }
            Player.STATE_READY -> {
                ev("duration") { put("d", player.duration / 1000.0) }
                ev("state") { put("s", if (player.isPlaying) "playing" else "paused") }
            }
            Player.STATE_ENDED -> ev("state") { put("s", "ended") }
            else -> {}
        }
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
        if (player.playbackState == Player.STATE_READY) ev("state") { put("s", if (isPlaying) "playing" else "paused") }
    }

    override fun onRenderedFirstFrame() {
        if (!firstSent) { firstSent = true; ev("first"); Log.i("SwiftlyMedia3", "first frame rendered") }
    }

    override fun onVideoSizeChanged(size: VideoSize) {
        ev("size") { put("w", size.width * size.pixelWidthHeightRatio.toDouble()); put("h", size.height) }
    }

    override fun onPlayerError(error: PlaybackException) {
        ev("state") { put("s", "error"); put("msg", error.message ?: error.errorCodeName); put("kind", error.errorCodeName) }
        Log.e("SwiftlyMedia3", "error ${error.errorCodeName}")
    }

    override fun onCues(cueGroup: CueGroup) {
        ev("cue") { put("text", cueGroup.cues.joinToString("\n") { it.text ?: "" }) }
    }

    override fun onTracksChanged(tracks: Tracks) {
        trackIds.clear()
        val audio = JSONArray(); val subs = JSONArray()
        var next = 0
        var activeAudio: Int? = null; var activeSub: Int? = null
        for (g in tracks.groups) {
            val f = g.getTrackFormat(0)
            val id = next++
            val o = JSONObject().put("id", id).put("codec", f.sampleMimeType ?: "").put("lang", f.language)
                .put("name", f.label ?: "").put("ch", f.channelCount.coerceAtLeast(0))
                .put("def", f.selectionFlags and C.SELECTION_FLAG_DEFAULT != 0)
                .put("forced", f.selectionFlags and C.SELECTION_FLAG_FORCED != 0)
            when (g.type) {
                C.TRACK_TYPE_AUDIO -> { audio.put(o); trackIds[id] = g; if (g.isSelected) activeAudio = id }
                C.TRACK_TYPE_TEXT -> { subs.put(o); trackIds[id] = g; if (g.isSelected) activeSub = id }
                C.TRACK_TYPE_VIDEO -> hints(f, g)
            }
        }
        ev("tracks") { put("audio", audio); put("sub", subs); activeAudio?.let { put("aa", it) }; activeSub?.let { put("as", it) } }
    }

    // HDR kind and frame rate for the display; the frame rate also goes to the Surface (frame-rate matching).
    private fun hints(f: androidx.media3.common.Format, g: Tracks.Group) {
        val hdr = when {
            f.sampleMimeType == MimeTypes.VIDEO_DOLBY_VISION -> "dv"
            f.colorInfo?.colorTransfer == C.COLOR_TRANSFER_ST2084 -> "hdr10"
            f.colorInfo?.colorTransfer == C.COLOR_TRANSFER_HLG -> "hlg"
            else -> "sdr"
        }
        ev("hints") { put("hdr", hdr); put("fps", f.frameRate.toDouble()) }
        val s: Surface? = video.holder.surface
        if (f.frameRate > 0 && s != null && s.isValid) {
            s.setFrameRate(f.frameRate, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
        }
        Log.i("SwiftlyMedia3", "video format ${f.sampleMimeType} ${f.width}x${f.height} fps=${f.frameRate} hdr=$hdr")
    }

    fun release() = player.release()
}
