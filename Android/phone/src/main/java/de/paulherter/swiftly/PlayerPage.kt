package de.paulherter.swiftly

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import android.app.Activity
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.snap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.ui.composed
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.zIndex
import kotlinx.coroutines.flow.first
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ActivityInfo
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.net.Uri
import android.os.SystemClock
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.animation.core.LinearEasing
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeOut
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.semantics.onClick
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.motionReduced
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import de.paulherter.swiftly.core.Kern
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import coil3.toBitmap
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.interfaces.IMedia
import org.videolan.libvlc.util.VLCVideoLayout
import java.text.NumberFormat
import android.content.Intent
import androidx.core.content.ContextCompat
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.text.font.FontFamily
import java.util.Locale
import kotlin.math.roundToInt
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.layout.Layout
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.graphics.asImageBitmap
import android.content.res.Configuration
import androidx.compose.ui.layout.ContentScale
import androidx.compose.foundation.Image

/** What to play and from where (iOS `PlayRequest`). `since == null` starts from the beginning. */
data class PlayRequest(val id: String, val since: Double?,
                       /** The version the user picked when a title has several (`MediaSource.id`); empty = the best one. */
                       val sourceID: String = "")

/** Result of `Kern.playbackOpen`: the stream URL and the footer lines. */
data class PlayPlan(val url: String, val lossless: Boolean, val method: String, val title: String,
                     val subtitle: String, val next: Boolean,
                     val series: String? = null, val abbreviation: String? = null, val image: String? = null,
                     val fileRow: String? = null,
                     // For the player header (iOS `titleLine`/`metaText`) and the episode layer.
                     val itemId: String = "", val episode: Boolean = false, val seriesIdentifier: String? = null,
                     val seasonIdentifier: String? = null,
                     val headerLine: String = "", val seasonNr: Int? = null, val episodeNr: Int? = null,
                     val secondaryLine: String? = null,
                     /** Section boundaries in seconds, drawn as notches on the seek bar. */
                     val marks: List<Double> = emptyList(),
                     /** Open with the software decoder right away (`PlaybackPlan.softwareDecoder`, MPEG-4 Part 2). */
                     val softwareDecoder: Boolean = false,
                     /** The next episode for the card: name, short code, still image. */
                     val nextEpisode: CardsEpisode? = null,
                     /** Image for the handover card when the still frame is black (`TakeoverModel.cardImageURL`). */
                     val cardImage: String? = null,
                     /** Dolby Vision profile of an unchanged file (0: unknown), otherwise `null` (`PlayerEngine`). */
                     val dolbyVision: Int? = null,
                     /** Codec of the default audio track (`eac3`, `truehd` …); `""` without sound, `null` if unknown. */
                     val audioCodec: String? = null)

/** Manual track choice per series or movie; same keys as `TrackMemory` in the package. */
private const val AUDIO_JE_TITLE = "tonJeTitel"
private const val UT_JE_TITLE = "utJeTitel"

internal fun playPlanRead(json: String) = JSONObject(json).let { o ->
    PlayPlan(o.getString("url"), o.optBoolean("lossless"), o.optString("methode"), o.optString("titel"),
              o.optString("untertitel"), o.optBoolean("naechste"),
              o.optString("serie").takeIf { !o.isNull("serie") }, o.optString("kuerzel").takeIf { !o.isNull("kuerzel") },
              o.optString("bild").takeIf { !o.isNull("bild") },
              o.optString("dateizeile").takeIf { !o.isNull("dateizeile") },
              o.optString("itemId"), o.optBoolean("episode"), o.optString("serieId").takeIf { !o.isNull("serieId") },
              o.optString("staffelId").takeIf { !o.isNull("staffelId") },
              o.optString("kopfzeile"),
              if (o.isNull("staffelNr")) null else o.optInt("staffelNr"),
              if (o.isNull("folgeNr")) null else o.optInt("folgeNr"),
              o.optString("nebenzeile").takeIf { !o.isNull("nebenzeile") },
              o.optJSONArray("marken")?.let { a -> (0 until a.length()).map { a.getDouble(it) } }.orEmpty(),
              o.optBoolean("softwareDekoder"),
              o.optJSONObject("naechsteFolge")?.let { n ->
                  CardsEpisode(n.getString("id"), n.optString("name"), n.optString("kuerzel"), n.fieldText("bild"))
              },
              if (o.has("kartenbild")) o.fieldText("kartenbild") else null,
              if (o.has("dolbyVision") && !o.isNull("dolbyVision")) o.getInt("dolbyVision") else null,
              if (o.has("audioCodec") && !o.isNull("audioCodec")) o.getString("audioCodec") else null)
}

/** What the delay row shows: text and limits from `Delay` in the package (phone and TV). */
internal data class DelayDisplay(val text: String, val isNull: Boolean, val atStart: Boolean, val atEnd: Boolean)

internal fun delayDisplay(milliseconds: Int): DelayDisplay =
    JSONObject(Kern.delayState(milliseconds.toLong(), Locale.getDefault().toLanguageTag())).let {
        DelayDisplay(it.getString("text"), it.getBoolean("istNull"), it.getBoolean("amAnfang"), it.getBoolean("amEnde"))
    }

/** Trickplay data for the current playback; same math as `Trickplay` in the package. */
data class TrickplayDetail(val width: Int, val height: Int, val tilesWide: Int, val tilesUp: Int,
                           val count: Int, val interval: Int) {
    data class Tile(val sheet: Int, val x: Int, val y: Int, val width: Int, val height: Int)

    /** n = ms / interval, sheet = n / (columns × rows); see `Trickplay.tile(seconds:)`. */
    fun tile(seconds: Double): Tile? {
        val jeSheet = tilesWide * tilesUp
        if (interval <= 0 || jeSheet <= 0 || count <= 0 || width <= 0 || height <= 0 || !seconds.isFinite()) return null
        val ms = maxOf(seconds, 0.0) * 1000
        val n = minOf((ms / interval).toInt(), count - 1)
        val slot = n % jeSheet
        return Tile(n / jeSheet, (slot % tilesWide) * width, (slot / tilesWide) * height, width, height)
    }
}

private fun trickplayDetailRead(json: String): TrickplayDetail? = JSONObject(json).let { o ->
    if (!o.has("breite")) return null
    TrickplayDetail(o.getInt("breite"), o.getInt("hoehe"), o.getInt("kachelnBreit"), o.getInt("kachelnHoch"),
                    o.getInt("anzahl"), o.getInt("intervall"))
}

/**
 * Loads the seasons and the current season's episodes into the series page's caches (iOS
 * `EpisodesLayer.preload`), so the episode layer is ready on open. Same caches as `SeriesPage.kt`
 * (`app.seriesCache`/`app.episodesCache`), so jumping to the series page loads nothing twice.
 */
internal suspend fun episodesPreload(app: SwiftlyApplication, seriesIdentifier: String, seasonIdentifier: String?) {
    try {
        val series = seriesRead(withContext(Dispatchers.IO) { app.kern.series(seriesIdentifier).await() })
        app.seriesCache[seriesIdentifier] = series
        if (series.seasons.isEmpty()) return
        val season = series.seasons.firstOrNull { it.id == seasonIdentifier } ?: series.seasons.firstOrNull { it.id == series.selected } ?: series.seasons.first()
        val episodes = episodesRead(withContext(Dispatchers.IO) { app.kern.episodes(seriesIdentifier, season.id).await() })
        app.episodesCache[season.id] = episodes
    } catch (e: CancellationException) { throw e } catch (_: Exception) {}
}

/** 1:23:45 or 23:45, with tabular digits so the line does not jitter while running. Also used by `tv/TvPlayer.kt`. */
internal fun timeText(seconds: Double): String {
    val s = seconds.coerceAtLeast(0.0).toLong()
    val h = s / 3600
    val m = (s % 3600) / 60
    val r = s % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, r) else "%d:%02d".format(m, r)
}

/** Also used by `tv/TvPlayer.kt` (speed cards). */
internal fun tempoText(value: Float) = NumberFormat.getInstance().format(value) + "×"

internal tailrec fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}

/**
 * The playback **mechanics** without any UI: build VLC, open, poll the clock (`Kern.playbackTick`),
 * apply remote commands, set tracks, report to the server, run the media session.
 *
 * Shared by `PlayerPage` (phone) and `tv/TvPlayer.kt` (TV, mirrors tvOS `PlayerScreen`) so the rules
 * exist once. Pure screen concerns (control visibility, swipe gestures, which sheet is open) stay in the
 * composables: that is where phone and TV may differ (input method).
 */
class PlayItem(
    private val app: SwiftlyApplication,
    private val context: Context,
    private val run: CoroutineScope,
    private val jerk: (Jerk) -> Unit = {},
) {
    // User-supplied certificate authorities: GnuTLS otherwise reads only the system store (`Certificates`).
    // **`--stereo-mode=1`: decoded audio as stereo while `multiChannelAudio` is off.** If the HDMI output
    // reports bitstream formats, libVLC's AudioTrack output (device `encoded:`/`pcm`) opens multichannel
    // PCM with up to eight channels. AAC 5.1 went out as a 6-channel stream, and some boxes (Mi Box S)
    // play it silent instead of downmixing. The option only affects linear PCM in libVLC
    // (`aout_OutputNew`); AC3/E-AC3/DTS/TrueHD still pass through raw (`digitalAudioApply`).
    //
    // **Subtitles like on Apple** (`SubtitleStyle` in `Sources/Shared/VLCPlayer.swift`): white, thin
    // outline (3 % of text height instead of VLC's 4), light shadow, smaller than VLC's default of 6.25 %
    // of the video height, slightly larger on TV. The font stays Roboto: libVLC 3 on Android only reads
    // `/system/etc/fonts.xml`, which lists only weights 400 and 700, so a bundled font or Roboto Medium
    // is not picked up. ASS with its own style and bitmap subtitles are left alone.
    val vlc = LibVLC(context, ArrayList(listOf("--no-drop-late-frames", "--no-skip-frames") +
        listOf("--freetype-color=16777215", "--freetype-outline-thickness=3",
            "--freetype-outline-opacity=230", "--freetype-shadow-opacity=120",
            "--freetype-shadow-distance=0.04", "--freetype-shadow-angle=-70",
            "--sub-text-scale=" + (if (app.isTv) 88 else 82)) +
        listOfNotNull("--stereo-mode=1".takeUnless { app.settings.multiChannelAudio }) +
        listOfNotNull(Certificates.folder?.let { "--gnutls-dir-trust=$it" })))
    /** VLC for everything, Media3 for Dolby Vision (`PlayerEngine`). */
    val player = PlayerEngine(context, vlc, app.isTv)
    val session = MediaSession(context, "Swiftly")

    // MARK: VLC thread: `stop`, `setMedia`, `play` and `release` do not run on the main thread.
    //
    // **`MediaPlayer.stop()` waits in libVLC for the input thread to end** (`input_Close` -> `vlc_join`).
    // If it hangs on a dead stream, the caller blocks too; on the main thread this was the app's largest
    // ANR (Play Vitals: `vlc_cond_wait` under `PlayItem.newConnect`, phone and TV; less often under
    // `finish`). So every call that can block goes to a dedicated thread, in order. While anything is
    // queued there, the main thread asks VLC nothing that needs the same lock (`time`, `pause`, `play`);
    // `vlcFree` says when it may again, and calls in the meantime queue up behind (`vlcNowOrAfter`).
    // After `aufraeumen` the thread accepts nothing: release happens exactly once, and nobody touches
    // the player afterwards.
    private val vlcThread = java.util.concurrent.Executors.newSingleThreadExecutor { r -> Thread(r, "Swiftly-VLC") }
    private val vlcJobs = java.util.concurrent.atomic.AtomicInteger(0)
    @Volatile private var removed = false
    /**
     * Nothing is queued on the VLC thread and the player is not released. Ask only on the main thread.
     * While Media3 plays, VLC's queue does not matter: Media3 has its own lock-free main thread.
     */
    val vlcFree: Boolean get() = !removed && (player.usesMedia3 || vlcJobs.get() == 0)

    /** Queue at the back of the VLC thread. `false` if the player is already torn down; then nothing runs. */
    private fun inVlcThread(was: String, block: () -> Unit): Boolean {
        if (removed) return false
        vlcJobs.incrementAndGet()
        return try {
            vlcThread.execute {
                val beginning = SystemClock.elapsedRealtime()
                try { block() } catch (e: Exception) { AppLog.writeOut("[VLC] $was gescheitert: ${e.javaClass.simpleName}") }
                finally {
                    vlcJobs.decrementAndGet()
                    val ms = SystemClock.elapsedRealtime() - beginning
                    if (ms >= 1000) AppLog.writeOut("[VLC] $was dauerte $ms ms (im VLC-Faden)")
                }
            }
            true
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            vlcJobs.decrementAndGet()
            false
        }
    }

    /** Immediately if the VLC thread is idle, otherwise behind whatever is queued. */
    private fun vlcNowOrAfter(was: String, block: () -> Unit) {
        if (vlcFree) block() else inVlcThread(was, block)
    }

    /** Stop the stream without waiting for libVLC. */
    private fun stopNow(reason: String) {
        player.stopMedia3()
        inVlcThread("Stopp ($reason)") { player.stopVlc() }
    }

    /** Stop from outside (TV: Home, sleep timer) without waiting for a running stop. */
    fun halt() = vlcNowOrAfter("Pause") { player.pause() }

    var plan by mutableStateOf<PlayPlan?>(null); private set
    var running by mutableStateOf(false); private set
    var position by mutableDoubleStateOf(0.0); private set
    var duration by mutableDoubleStateOf(0.0); private set
    var imageFree by mutableStateOf(false); private set
    var offeringArt by mutableStateOf("keiner"); private set
    var offeringPost by mutableStateOf<Double?>(null); private set
    var offerText by mutableStateOf(""); private set
    /**
     * **The overlay without controls** (`OfferingLayer` in the package, stage 3): `nothing`, `button` or
     * `card`. With `card` the countdown runs, `countdown` from 0 to 1.
     */
    var overlay by mutableStateOf("nichts"); private set
    var countdown by mutableDoubleStateOf(0.0); private set
    var countdownRest by mutableIntStateOf(0); private set
    var countdownLength by mutableDoubleStateOf(7.0); private set
    /**
     * **After a seek the card's fill starts over** (`layer.jumped()`, iOS `fillClock = FillClock()`).
     * Counted so the display restarts instead of continuing.
     */
    var fillNew by mutableIntStateOf(0); private set

    // MARK: Next-episode card C: timings and sizes come from the core.

    /** Sizes, springs and timings of the card, for phone or TV (`Kern.episodeCard`). */
    val cardsMetrics: CardsMetrics by lazy { CardsMetrics.read(Kern.episodeCard(app.isTv), app.isTv) }
    /**
     * **The card is zooming into the picture.** Held from the start so it does not vanish with the offer
     * that the episode change removes (`CardsSwitch`).
     */
    var cardsSwitch by mutableStateOf<CardsSwitch?>(null); private set

    /** After the zoom (or its failure): everything back, no motion. */
    fun cardCleanUp() { cardsSwitch = null }

    /**
     * Applies the UI with the **intended** control visibility (`OfferingLayer.controls`): opening cancels
     * the "next episode" card. "Skip intro" stays six seconds of playback without controls, then only
     * with them. The overlay therefore returns immediately, not on the next tick. On TV focus then
     * goes to the idle surface (`TvPlayer`).
     */
    fun controlsChanged(opened: Boolean) {
        overlay = app.kern.controlsChanged(opened)
    }
    var hint by mutableStateOf<String?>(null)
    var techFixed by mutableStateOf<List<TechRow>>(emptyList()); private set
    var techLive by mutableStateOf<JSONObject?>(null); private set
    var fillFrame by mutableStateOf(app.store.rememberValue("bildfuellend") == "1"); private set
    /**
     * **Whether VLC is buffering although it should be playing.** Counterpart to `stalls` in
     * `Sources/tvOS/PlayerScreen.swift`: VLCKit on Apple has no `Buffering` event, so tvOS measures the
     * stalled clock. Here the player reports its fill level itself (`MediaPlayer.Event.Buffering`, 0..100),
     * which is more accurate and needs no core data.
     */
    var buffers by mutableStateOf(false); private set
    /**
     * **An episode change is running.** The latch from `EpisodeSwitch` in the package, mirrored here for
     * the spinner so a second press never reaches the core.
     */
    var switches by mutableStateOf(false); private set
    var tempo by mutableFloatStateOf(1f); private set
    var sleepTime by mutableIntStateOf(0); private set
    /**
     * While the slider is dragged, the tick does not overwrite the position; only the phone has this.
     * **Observable**: icons and the center control move out of the way while seeking. As a plain field
     * Compose did not see the change; they only vanished when the tick happened to redraw.
     */
    var atPush by mutableStateOf(false)

    // MARK: Delay: mirrors the "Verzögerung" section of `VLCPlayer.swift`; the rules are in the package
    // (`Delay`, via `Kern.delay…`). Local only: SyncPlay aligns movie time, which the
    // delay does not change.
    /** Milliseconds, always a multiple of the step. */
    var subtitleDelay by mutableIntStateOf(0); private set
    var audioDelay by mutableIntStateOf(0); private set

    /** - (-1) or + (+1) in the audio or subtitle row. While held, the core counts the repeats (`Haltezaehler`). */
    fun delayPush(audio: Boolean, bearing: Int) {
        val steps = app.kern.delayPress(if (audio) "ton" else "untertitel")
        val now = if (audio) audioDelay else subtitleDelay
        delaySet(audio, Kern.delayShifted(now.toLong(), bearing.toLong(), steps).toInt())
    }

    fun delaySet(audio: Boolean, milliseconds: Int) {
        if (audio) audioDelay = milliseconds else subtitleDelay = milliseconds
        delayCatchUp()
    }

    /**
     * **libVLC forgets the delay with every new media.** It is tied to the input, as in VLCKit 4 (see
     * `Delay` in the package), also after a rebuild. So it is not set once but re-applied whenever
     * VLC reads something else: on change, on "playing" and on the tick.
     */
    private fun delayCatchUp() {
        // Media3 has no delay: it stays put until VLC plays again.
        if (!vlcFree || player.usesMedia3 || !player.hasMedia()) return
        val ut = subtitleDelay.toLong()
        if (Kern.delaySoftFrom(ut, player.spuDelay)) {
            player.spuDelaySet(Kern.delayMicroseconds(ut))
            AppLog.writeOut("[Verzögerung] Untertitel $ut ms gesetzt, VLC liest ${player.spuDelay} µs")
        }
        val audio = audioDelay.toLong()
        if (Kern.delaySoftFrom(audio, player.audioDelay)) {
            player.audioDelaySet(Kern.delayMicroseconds(audio))
            AppLog.writeOut("[Verzögerung] Ton $audio ms gesetzt, VLC liest ${player.audioDelay} µs")
        }
    }

    // MARK: Watch together: mirrors `sharedAn`/`inGroup` in `Sources/iOS/PlayerScreen.swift`.

    /**
     * **The token from `Kern.syncPlayConnect`**, set on open when the title is the one the group is
     * watching; `0` means alone. The core uses it to assign ticks, steps and detaching.
     */
    var mark by mutableLongStateOf(0L); private set
    val sharedAn: Boolean get() = mark > 0
    /** In a group, pause, resume and seek go to the server as requests, including keys and remote commands. */
    val inGroup: Boolean get() = sharedAn && app.gemeinsam.value.group != null
    /** **No next episode in a group**, otherwise everyone would advance on their own (iOS `lookUp`). */
    val hasNext: Boolean get() = plan?.next == true && !inGroup

    // MARK: Chapters: mirrors `chapter` in iOS `PlayerScreen`; rules live in the core (`ChapterBar`).
    /**
     * Number of usable chapters in the current version; 0 leaves the bar as a single piece. Also serves
     * as a key so the bar is recomputed after loading.
     */
    var chapterCount by mutableIntStateOf(0); private set

    suspend fun chapterLoad() {
        chapterCount = 0
        val n = withContext(Dispatchers.IO) { app.kern.chapterLoad().await() }
        AppLog.writeOut("[Kapitel] " + if (n > 0L) "$n" else "keine")
        chapterCount = n.toInt()
    }

    // MARK: Trickplay: seek preview, mirrors `TrickplayImages` in the package.
    var trickplayDetail by mutableStateOf<TrickplayDetail?>(null); private set
    /** Decoded tile sheets, at most six; as on iOS only a handful is kept. */
    private val trickplaySheets = LinkedHashMap<Int, android.graphics.Bitmap>()
    private val trickplayUnderRoute = mutableSetOf<Int>()
    /** Counts incoming sheets so the preview redraws. */
    var trickplayState by mutableIntStateOf(0); private set

    suspend fun trickplayLoad() {
        trickplayDetail = null
        trickplaySheets.clear()
        trickplayUnderRoute.clear()
        val raw = withContext(Dispatchers.IO) { app.kern.trickplayDetail().await() }
        val hasRead = trickplayDetailRead(raw)
        // As in `TrickplayImages.load` on iOS: one line per title, otherwise the log cannot show whether the
        // server has none or the preview just does not arrive.
        AppLog.writeOut("[Trickplay] " + (hasRead?.let { "${it.width}px, ${it.count} Bilder, alle ${it.interval} ms" } ?: "keins"))
        trickplayDetail = hasRead
    }

    /** The image for a position, cut from its sheet; `null` while the sheet is still loading. */
    fun trickplayImage(seconds: Double): android.graphics.Bitmap? {
        @Suppress("UNUSED_EXPRESSION") trickplayState
        val detail = trickplayDetail ?: return null
        val tile = detail.tile(seconds) ?: return null
        val sheet = trickplaySheets[tile.sheet] ?: run { trickplayRequest(tile.sheet, detail); return null }
        return runCatching { android.graphics.Bitmap.createBitmap(sheet, tile.x, tile.y, tile.width, tile.height) }.getOrNull()
    }

    private fun trickplayRequest(number: Int, detail: TrickplayDetail) {
        if (!trickplayUnderRoute.add(number)) return
        run.launch {
            val address = withContext(Dispatchers.IO) { app.kern.trickplayAddress(detail.width.toLong(), number.toLong()).await() }
            val image = if (address.isEmpty()) null else runCatching {
                (SingletonImageLoader.get(context).execute(ImageRequest.Builder(context).data(address).allowHardware(false).build())
                    as? SuccessResult)?.image?.toBitmap()
            }.getOrNull()
            trickplayUnderRoute.remove(number)
            if (image == null) AppLog.writeOut("[Trickplay] Blatt $number kam nicht (Adresse ${address.isNotEmpty()})")
            if (image != null) {
                trickplaySheets[number] = image
                if (trickplaySheets.size > 6) trickplaySheets.remove(trickplaySheets.keys.first())
                trickplayState++
            }
        }
    }

    private val showsImage = booleanArrayOf(false)
    private val end = booleanArrayOf(false)
    /** The video surface (`VLCVideoLayout`); its still frame goes out as the card on a handover. */
    var videoArea: android.view.View? = null
    /**
     * **This playback comes from a handover** (`VLCPlayerView.handoffFadeIn`): it starts muted
     * under the card and fades the audio in over 0.6 s at the first frame. Applies to exactly one start.
     */
    private var handoffFadeIn = false
    /** Playback is being handed to another device; commands no longer count. */
    private var givesOff = false
    /** VLC reported end of file; the card countdown keeps running there although nothing plays. */
    val atFileEnd: Boolean get() = end[0]
    /** Already reported as "stopped"; otherwise teardown reports it (small window swiped away). */
    private val ended = booleanArrayOf(false)
    private var sleepJob: kotlinx.coroutines.Job? = null
    private val debugBuild = (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0

    val backS: Int get() = app.settings.backSeconds
    val preS: Int get() = app.settings.forwardSeconds

    fun installEventListener() {
        networkObserve()
        audioObserve()
        player.onEvents { e ->
            when (e) {
                // **Report pause and resume when the engine reports them**, not on the press, where the previous state was
                // still current (like `VLCPlayerView.runsReported`). The core decides once per change and only for
                // a started title; `Stopped` reports nothing, the end goes through `playbackEnd`.
                // Whoever resumes by hand takes focus back (after a permanent loss).
                PlayerEngine.Event.Playing -> {
                    running = true; focusFetch(); app.kern.runStateReported(true, pointNow()); delayCatchUp()
                    if (handoffFadeIn) vlcNowOrAfter("stumm") { player.volume = 0 }
                }
                PlayerEngine.Event.Paused -> { running = false; app.kern.runStateReported(false, pointNow()) }
                PlayerEngine.Event.Stopped -> running = false
                PlayerEngine.Event.Frame -> showsImage[0] = true
                is PlayerEngine.Event.Buffering -> buffers = e.percent < 100f
                // **A dropped connection looks like end of file** (mirrors `stateSwitched` on iOS): if the last
                // good position is well before the end, it was a dead stream, not the end.
                PlayerEngine.Event.Ended -> { running = false; if (!teardown("Ende")) end[0] = true }
                PlayerEngine.Event.Error -> {
                    // **Media3 fails: the same file with VLC**, the base layer then. The flag is set whenever it
                    // fails, before or after the first frame, so a title never goes back and forth between the engines.
                    val wasMedia3 = player.usesMedia3
                    if (wasMedia3) {
                        media3Failed = true
                        if (!imageFree) { run.launch { media3GiveUp() }; return@onEvents }
                    }
                    // Before the first frame the UI keeps showing "loading"; at least the log should say so.
                    if (!imageFree) AppLog.writeOut("[VLC] Fehler vor dem ersten Bild")
                    // A dead stream is rebuilt (`teardown`), and `mediaOpen` then picks VLC. Otherwise there is
                    // nothing to rebuild: with Media3 VLC takes over at once, with VLC the viewer is told.
                    if (!teardown("Fehler")) {
                        if (wasMedia3) run.launch { media3GiveUp() }
                        else hint = translated("Die Folge konnte nicht geladen werden.")
                    }
                }
                is PlayerEngine.Event.TextTrackNew -> subtitleTrackNew(e.id)
            }
        }
    }

    private fun pointNow(): Double = if (!vlcFree) position else (player.time / 1000.0).takeIf { it > 0 } ?: position

    /**
     * **The activity goes to the background**: report the state immediately with the real play state,
     * since Android does not pause playback then (picture-in-picture, service).
     */
    fun backgroundReport() = app.kern.backgroundReport(pointNow(), !vlcFree || !player.isPlaying)

    /** Tear down VLC and the drawing surface; counterpart to `installEventListener`. */
    fun cleanUp() {
        networkSignOut()
        audioSignOut()
        // **Closing means leaving**, without confirmation; the strip offers the way back.
        if (mark > 0) app.kern.syncPlayDetach(mark)
        if (!ended[0]) app.playbackEnd(endPoint())
        // The player closed before the card released it (`HandoffStage.playerDistance`).
        plan?.itemId?.let { Handoff.playerDistance(app, it) }
        // The main thread detaches the surface (as on moving to the background, where VLC keeps playing);
        // stop and release run on the VLC thread behind everything queued there. Afterwards it accepts nothing.
        player.onEvents(null)
        player.detach()
        player.media3Down()
        inVlcThread("Abbau") {
            player.stopVlc()
            player.releaseVlc()
            vlc.release()
        }
        removed = true
        vlcThread.shutdown()
    }

    fun installSession() {
        session.setCallback(object : MediaSession.Callback() {
            override fun onPlay() { if (!player.isPlaying) toggle() }
            override fun onPause() { if (player.isPlaying) toggle() }
            override fun onSeekTo(pos: Long) { vault(pos / 1000.0) }
            override fun onFastForward() { vault(position + preS) }
            override fun onRewind() { vault(position - backS) }
            override fun onSkipToNext() { if (hasNext) run.launch { nextEpisode() } }
        })
        session.isActive = true
    }

    fun sessionCleanUp() {
        PlaybackService.from(context)
        app.mediaToken = null
        keepScreenAwake(false)
        session.isActive = false
        session.release()
    }

    private var screenAwake = false

    /**
     * **On TV the screen follows the play state.** `PlayerActivity` sets `FLAG_KEEP_SCREEN_ON` only on
     * the phone; on TV, Google TV showed the screensaver over the running picture after 10 to 15 minutes.
     * The flag is set while VLC plays and cleared on pause and end, so the screensaver may run again.
     */
    private fun keepScreenAwake(an: Boolean) {
        if (!app.isTv || an == screenAwake) return
        val window = context.activity()?.window ?: return
        screenAwake = an
        if (an) window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun sessionReport() {
        keepScreenAwake(running)
        var actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_SEEK_TO or PlaybackState.ACTION_FAST_FORWARD or PlaybackState.ACTION_REWIND
        // "Next" only if there is one; "previous" never. Greyed out is more honest than doing nothing.
        if (hasNext) actions = actions or PlaybackState.ACTION_SKIP_TO_NEXT
        session.setPlaybackState(PlaybackState.Builder().setActions(actions)
            .setState(if (running) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED, (position * 1000).toLong(),
                      if (running) tempo else 0f).build())
    }

    /** Title, series, episode, length and the still image for notification and lock screen. */
    suspend fun metaDataUpdate() {
        val p = plan ?: return
        fun metadata(image: android.graphics.Bitmap?) = MediaMetadata.Builder().apply {
            putString(MediaMetadata.METADATA_KEY_TITLE, p.title)
            p.series?.let { putString(MediaMetadata.METADATA_KEY_ALBUM, it); p.abbreviation?.let { k -> putString(MediaMetadata.METADATA_KEY_ARTIST, k) } }
            if (duration > 0) putLong(MediaMetadata.METADATA_KEY_DURATION, (duration * 1000).toLong())
            image?.let { putBitmap(MediaMetadata.METADATA_KEY_ART, it) }
        }.build()
        session.setMetadata(metadata(null))
        // Notification and lock screen: the service reads title and buttons from the session.
        app.mediaToken = session.sessionToken
        PlaybackService.an(context, p.title, p.subtitle)
        val address = p.image ?: return
        val image = runCatching {
            (SingletonImageLoader.get(context).execute(ImageRequest.Builder(context).data(address).size(600).allowHardware(false).build())
                as? SuccessResult)?.image?.toBitmap()
        }.getOrNull()
        session.setMetadata(metadata(image))
    }

    fun launch(new: PlayPlan, since: Double?) {
        // Delay: the same title or series keeps it, otherwise null (iOS `episodeApply`).
        plan?.let { alt ->
            fun keep(ms: Int) = Kern.delayForNewTitle(ms.toLong(), alt.itemId, alt.seriesIdentifier.orEmpty(),
                                                                    new.itemId, new.seriesIdentifier.orEmpty()).toInt()
            subtitleDelay = keep(subtitleDelay)
            audioDelay = keep(audioDelay)
        }
        plan = new
        run.launch { trickplayLoad() }
        run.launch { chapterLoad() }
        imageFree = false
        showsImage[0] = false
        buffers = false
        end[0] = false
        position = since ?: 0.0
        since?.takeIf { it > 1 }?.let { app.kern.playbackPoint(it) }
        powerGuardBackSet()
        firstFrameLevel = 0
        // XviD/DivX straight to software: libVLC 3 otherwise hands MPEG-4 Part 2 to MediaCodec (log:
        // "using c2.android.mpeg4.decoder"), like VLC 4 on Apple with VideoToolbox.
        softwareDecoder = new.softwareDecoder
        media3Failed = false
        firstFrameHint = null
        restoring = false
        waitsNetwork = false
        lastGoodPoint = since ?: 0.0
        handoffFadeIn = Handoff.receives(new.itemId)
        mediaOpen(new.url, since)
        if (handoffFadeIn) { inVlcThread("stumm") { player.volume = 0 }; AppLog.writeOut("[Ton] stumm unter der Übergabe-Karte") }
        lookUp(new)
    }

    /**
     * **Next episode and sections after the start**, from disk only; from the server both came with the
     * plan. Offline everything is already there; online the core asks the server
     * (`Kern.playbackLookUp`, mirrors `lookUp(fuer:)` on iOS).
     */
    private fun lookUp(of: PlayPlan) {
        if (!of.url.startsWith("file:")) return
        run.launch {
            val new = runCatching { withContext(Dispatchers.IO) { app.kern.playbackLookUp().await() } }.getOrDefault("")
            app.logWrite()
            if (new.isEmpty() || ended[0]) return@launch
            val p = playPlanRead(new)
            if (plan?.itemId == p.itemId && plan?.url == p.url) plan = p
        }
    }

    /** Build the media and play it, at start and on rebuild after a drop (`newConnect`). */
    private fun mediaOpen(url: String, since: Double?) {
        filesPrepare()
        // Behind a proxy, the forwarder (OkHttp) fetches the stream with the user's own headers; libVLC
        // cannot send any. Without headers the URL stays as it is.
        val vlcAddress = StreamForwarder.gemeinsam.address(url)
        if (vlcAddress != url) AppLog.writeOut("[VLC] Strom ueber den Weiterleiter")
        // On the side, without waiting: how the device reaches the server. Log only (`NetworkProbe`).
        NetworkProbe.start(context, url)
        // **Media3** (`PlayerEngine`) for Dolby Vision when file and device can, or for everything if set
        // so (`playerEngine`). Not after a rescue with the software decoder, and not once Media3 has failed
        // for this title.
        val dv = plan?.dolbyVision
        val choice = app.settings.playerEngine
        // Without a decoder extension Media3 drops a sound it cannot play without an error: the title goes to
        // Media3 only if it can play the default sound track (`EngineChoice`). An unknown file (from disk) counts as no.
        val audioPlayable = plan?.audioCodec?.let { PlayerEngine.audioPlayable(context, it) } ?: false
        val media3 = EngineChoice.decide(choice, softwareDecoder, media3Failed, dv, dolbyVisionHere, audioPlayable) == EngineChoice.Engine.MEDIA3
        if (media3) {
            AppLog.writeOut("[Media3] " + (dv?.let { "Dolby Vision (Profil $it)" } ?: "ohne Dolby Vision") + ", Einstellung $choice → Media3")
            val subtitles = files.map { it.index to StreamForwarder.gemeinsam.address(it.address) }
            files.clear()
            openGeneration++
            // VLC lets go of the previous media on its own thread; Media3 starts at once on this one.
            inVlcThread("Stopp (Media3)") { player.stopVlc() }
            player.openMedia3(vlcAddress, since, subtitles)
            player.play()
            return
        }
        if (dv != null || choice == "exoplayer") AppLog.writeOut("[Media3] bleibt bei VLC: " +
            EngineChoice.reasonVlc(choice, softwareDecoder, media3Failed, audioPlayable) + " (Ton ${plan?.audioCodec ?: "unbekannt"})")
        player.media3Down()
        // Main thread, before the open is queued: VLC gets its views back here, not on the VLC thread.
        player.vlcViewsAttach()
        val generation = ++openGeneration
        val media = Media(vlc, Uri.parse(vlcAddress))
        // If the connection drops briefly, VLC recovers instead of reporting the end.
        media.addOption(":http-reconnect")
        // **Join with `:start-time`.** Dropped on iOS because VLCKit 4 shifted the timeline with it and
        // reported a false end; libVLC 3 does not have that, and `rampUpIdle` from `EpisodeEnd` filters a
        // false end in the first seconds anyway.
        since?.takeIf { it > 1 }?.let { media.addOption(":start-time=$it") }
        // **Software decoder after the second first-frame rescue**, or from the start for MPEG-4
        // Part 2 (`FirstFrame.softwareOption`, `FirstFrame.softwareFromStart`).
        if (softwareDecoder) {
            media.setHWDecoderEnabled(false, false)
            media.addOption(Kern.firstFrameSoftwareOption())
            AppLog.writeOut("[Bild] Dekoderwahl ${Kern.firstFrameSoftwareOption()}")
        }
        // Buffer from settings; "Normal" keeps VLC's default.
        JSONArray(Kern.bufferLevels()).let { a -> (0 until a.length()).map { a.getJSONObject(it) } }
            .firstOrNull { it.getString("wert") == app.settings.bufferLevel }
            ?.takeIf { !it.isNull("netz") }?.let { media.addOption(":network-caching=${it.getInt("netz")}") }
        // `setMedia` closes a still-open stream like `stop`, so it runs on the VLC thread behind the stop.
        val placed = inVlcThread("Oeffnen") {
            // A newer open (VLC or Media3) came after this one while it waited: it replaces this one anyway.
            if (generation != openGeneration) { media.release(); return@inVlcThread }
            player.openVlc(media)
            media.release()
            digitalAudioApply()
            player.play()
            // A fallback from Media3 starts VLC at 1x; the speed the viewer set (shown in the UI) goes on now.
            VlcHandover.rateAfterOpen(tempo)?.let { player.rateSet(it) }
        }
        if (!placed) media.release()
    }

    /**
     * **Bitstream passthrough when the output reports it.** Mirrors the excerpt in
     * `Sources/Shared/VLCPlayer.swift` (`session.currentRoute.outputs`, `maximumOutputNumberOfChannels`),
     * which only logs the channel count because `AVAudioSession` routes to HDMI/AirPlay by itself.
     * libVLC on Android does not: `forceAudioDigitalEncodings` must name which formats the connected
     * TV or AVR can pass through raw (`AudioDeviceInfo.encodings`), otherwise VLC downmixes AC3/DTS/TrueHD
     * to PCM on the client although the sink could take them.
     *
     * Without a matching output (phone speaker, most Bluetooth headphones) the device list has none of
     * the wanted encodings; then the previous downmix stays and phone behavior does not change.
     */
    private fun digitalAudioApply() {
        val manager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        val known = buildSet {
            add(AudioFormat.ENCODING_AC3); add(AudioFormat.ENCODING_E_AC3)
            add(AudioFormat.ENCODING_DTS); add(AudioFormat.ENCODING_DTS_HD)
            if (android.os.Build.VERSION.SDK_INT >= 32) add(AudioFormat.ENCODING_DOLBY_TRUEHD)
        }
        val digitalOutputs = buildSet {
            add(AudioDeviceInfo.TYPE_HDMI); add(AudioDeviceInfo.TYPE_HDMI_ARC); add(AudioDeviceInfo.TYPE_LINE_DIGITAL)
            if (android.os.Build.VERSION.SDK_INT >= 33) add(AudioDeviceInfo.TYPE_HDMI_EARC)
        }
        val outputs = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter { it.type in digitalOutputs }
        // For the log: the PCM channels the output reports (empty means "any").
        outputs.forEach { AppLog.writeOut("[VLC] Ausgang ${it.type}: Kanaele ${it.channelCounts.toList()}, " +
            "Kodierungen ${it.encodings.map(::encodingName)}, " +
            "Mehrkanal-Ton ${if (app.settings.multiChannelAudio) "an" else "aus"}") }
        val reported = outputs.flatMap { it.encodings.toList() }.filter { it in known }.distinct()
        // **Reported does not mean accepted.** `AudioDeviceInfo.encodings` is what the device believes about
        // the output; some boxes list every encoding their audio HAL knows even if the TV behind them takes
        // only stereo PCM (plezy#2442: DTS arrived as 2.0; jellyfin-androidtv#5785: E-AC3 stuttered). Only the
        // direct path says whether a bitstream goes through **now**: from Android 13 the profiles of the
        // current route, from 10 `isDirectPlaybackSupported`. Whatever fails there, VLC decodes itself:
        // better PCM than silence. Below 10 it stays with what is reported.
        val encoding = reported.filter { directPossible(manager, it) }
        passedOn = encoding.toSet()
        if (reported.isNotEmpty()) AppLog.writeOut("[VLC] Durchreichen: ${encoding.map(::encodingName)}" +
            (reported - encoding.toSet()).takeIf { it.isNotEmpty() }?.let { r -> ", abgelehnt ${r.map(::encodingName)}" }.orEmpty())
        if (encoding.isEmpty()) return
        player.audioDigitalOutputSet(true)
        player.audioDigitalEncodingsForce(encoding.toIntArray())
    }

    /** The encodings `digitalAudioApply` last gave to VLC; for `audioReport`. */
    @Volatile private var passedOn: Set<Int> = emptySet()

    private val filmAudio: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build()

    /** Does the current route accept this bitstream directly? Model: ExoPlayer's `AudioCapabilities`. */
    private fun directPossible(manager: AudioManager, encoding: Int): Boolean = when {
        android.os.Build.VERSION.SDK_INT >= 33 ->
            manager.getDirectProfilesForAttributes(filmAudio).any { it.format == encoding }
        android.os.Build.VERSION.SDK_INT >= 29 -> AudioTrack.isDirectPlaybackSupported(
            AudioFormat.Builder().setEncoding(encoding).setSampleRate(48_000)
                .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build(), filmAudio)
        else -> true
    }

    private fun encodingName(k: Int): String = when (k) {
        AudioFormat.ENCODING_AC3 -> "AC3"; AudioFormat.ENCODING_E_AC3 -> "E-AC3"
        AudioFormat.ENCODING_E_AC3_JOC -> "E-AC3-JOC"; AudioFormat.ENCODING_DTS -> "DTS"
        AudioFormat.ENCODING_DTS_HD -> "DTS-HD"; AudioFormat.ENCODING_DOLBY_TRUEHD -> "TrueHD"
        AudioFormat.ENCODING_PCM_16BIT -> "PCM16"; AudioFormat.ENCODING_PCM_FLOAT -> "PCMf"
        else -> "#$k"
    }

    /**
     * **Does the track pass through raw, or does VLC decode?** Counterpart to `channelsPostMeasure` on Apple:
     * a silent downmix (plezy#2442) should show in the log, not only at the receiver. libVLC does not say
     * what the output actually opens, so the evidence is what is selected, how many channels the file has
     * and whether its format is on the passthrough list. Decoded with `multiChannelAudio` off means stereo:
     * that is intended, not an error.
     */
    private fun audioReport() {
        val id = player.audioTrack
        val track = player.trackDetails()[id]?.takeIf { it.audio } ?: return
        // The identifier (`i_codec`), not `codec`, which is a description depending on the libVLC version.
        // libVLC 3 reports TrueHD as `trhd`, libVLC 4 as `mlpa`.
        val codec = (0..3).map { ((track.fourcc shr (8 * it)) and 0xFF).toChar() }.joinToString("").trim().lowercase()
        val format = when (codec) {
            "a52" -> AudioFormat.ENCODING_AC3; "eac3" -> AudioFormat.ENCODING_E_AC3
            "dts" -> AudioFormat.ENCODING_DTS; "mlp", "mlpa", "trhd" -> AudioFormat.ENCODING_DOLBY_TRUEHD
            else -> null
        }
        val raw = format != null && (format in passedOn ||
            (format == AudioFormat.ENCODING_DTS && AudioFormat.ENCODING_DTS_HD in passedOn))
        val distance = when {
            raw -> "durchgereicht"
            player.usesMedia3 -> "Media3"
            app.settings.multiChannelAudio -> "dekodiert, bis ${track.channels} Kanaele"
            else -> "dekodiert, Stereo"
        }
        AppLog.writeOut("[Audio] beim Oeffnen: $codec ${track.channels}ch ${track.rate} Hz · $distance")
    }

    /**
     * **The position for "stopped"**, read before stopping because VLC resets its clock then. Before the
     * first frame the start position applies (iOS: the view's `position`, not VLC's time): VLC still
     * reports 0 there, and going back before loading finished set the server progress to zero
     * (findroid#896). On rebuild after a drop, the last good position.
     */
    private fun endPoint(): Double = when {
        !imageFree -> position
        restoring -> lastGoodPoint
        !vlcFree -> position
        else -> (player.time / 1000.0).coerceAtLeast(0.0)
    }

    /**
     * **Playback goes to another device** (`handIn` in the `PlayerScreen.swift` of iOS, tvOS and macOS):
     * the position goes to the server at once (the other side waits for it), the picture stays and leaves
     * as a card; closing happens once it is out. `false`: no picture; the player closes as usual.
     */
    private suspend fun handIn(target: String, close: () -> Unit): Boolean {
        if (givesOff) return true
        givesOff = true
        val spot = endPoint()
        ended[0] = true
        app.doneWatch(spot, duration)
        app.playbackEnd(spot)
        vlcNowOrAfter("Pause") { if (player.isPlaying) player.pause() }
        val ok = Handoff.handIn(app, context, videoArea, target, plan, Motion.reduced(context)) {
            stopNow("Abgabe")
            close()
        }
        if (!ok) { ended[0] = false; givesOff = false }
        return ok
    }

    fun finish(close: () -> Unit) {
        val spot = endPoint()
        ended[0] = true
        app.doneWatch(spot, duration)
        app.playbackEnd(spot)
        stopNow("Schliessen")
        close()
    }

    suspend fun nextEpisode(fromCard: Boolean = false) = changeTo("", "Nächste Folge konnte nicht geladen werden.", fromCard = fromCard)

    /**
     * **The card was pressed** (or its countdown ran out): it zooms to the full picture and covers the
     * change (`toNextEpisode(fromCard:)`). `layer.gedrueckt` in the core, then the change.
     */
    fun cardStart() {
        if (switches || cardsSwitch != null) return
        jerk(Jerk.Lightweight)
        app.kern.offeringPressed()
        overlay = "nichts"
        run.launch { nextEpisode(fromCard = true) }
    }

    /**
     * **The offer button was pressed**, in the overlay or in the controls. Seeks past the section or goes
     * to the next episode via the stage-1 change. `false` if nothing is offered.
     */
    fun offeringRun(): Boolean {
        if (offeringArt == "keiner" || offerText.isEmpty()) return false
        app.kern.offeringPressed()
        overlay = "nichts"
        val to = offeringPost
        // "Next episode": a light tick to confirm the press (haptics).
        if (offeringArt == "ueberspringen" && to != null) vault(to) else { jerk(Jerk.Lightweight); run.launch { nextEpisode() } }
        return true
    }

    /** Back or a direction key: closes only the overlay; a countdown is cancelled. `true` if something was open. */
    fun offeringClose(): Boolean {
        if (overlay == "nichts") return false
        val toward = app.kern.offeringClose()
        overlay = "nichts"
        return toward
    }

    /**
     * Switch to a chosen episode in the running player; mirrors `changeInto` in
     * `Sources/tvOS/PlayerScreen.swift` (from the `Folgenblatt`). Same flow as `nextEpisode`, but with a
     * free ID instead of the queued next episode.
     */
    suspend fun changeInto(id: String) = changeTo(id, "Die Folge konnte nicht geladen werden.")

    /**
     * **Episode choice in the player.** In a group nobody switches alone: it resets the queue and
     * everyone loads the episode, as when creating one (`bitTitle`).
     */
    suspend fun episodeSelect(id: String) {
        if (inGroup) app.kern.syncPlayPleaseTitle(id) else changeInto(id)
    }

    /**
     * **Quality changed: same title, reloaded at the same position.** Mirrors the quality choice in the
     * player on iOS/tvOS/macOS. Unlike `changeTo`: no other title, and the position stays the resume
     * position instead of zero.
     */
    suspend fun qualitySwitch() {
        if (switches || ended[0]) return
        switches = true
        val spot = (if (vlcFree) player.time / 1000.0 else position).coerceAtLeast(0.0)
        try {
            val answer = JSONObject(withContext(Dispatchers.IO) { app.kern.qualitySwitch(spot).await() })
            app.toStop(answer.fieldText("nachmeldung"))
            app.logWrite()
            when (answer.optString("ergebnis")) {
                "gewechselt" -> {
                    val new = answer.fieldText("spielplan")
                    if (new != null && !ended[0]) {
                        val newPlan = playPlanRead(new)
                        // Limit chosen but the original plays: either the file already fits or the server does not
                        // transcode. Say so instead of staying silent.
                        if (!app.settings.alwaysDirectPlay && newPlan.method == "Direct Play") {
                            hint = translated("Läuft in Originalqualität. Der Server wandelt nichts um.")
                        }
                        stopNow("Qualitaet")
                        launch(newPlan, spot)
                    }
                }
                "gescheitert" -> hint = errorString(context, Exception(answer.fieldText("fehler")
                    ?: translated("Nächste Folge konnte nicht geladen werden.")))
            }
        } catch (e: CancellationException) { throw e } catch (e: Exception) {
            hint = errorString(context, e)
        } finally {
            switches = false
        }
    }

    /**
     * **The flow lives in the package** (`EpisodeSwitch`, via `Kern.episodeSwitch`): latch, stop and plan
     * side by side, abort on close, stop exactly once; same as iOS, tvOS and macOS.
     *
     * - **The old episode keeps playing until the new one is there.** Before, `player.stop()` stopped it
     *   ahead of the request; if that failed, the player stayed black with no way out. Now the message
     *   comes via `errorString` and the old episode stays.
     * - Closed while the core was planning: `cancelled`, nothing starts. If `switched` arrives after
     *   closing, nothing starts either; closing already reported the stop of the new episode.
     */
    private suspend fun changeTo(id: String, failure: String, since: Double? = null, fromCard: Boolean = false) {
        if (switches || ended[0]) return
        switches = true
        // **From the card: it zooms to the full picture** and covers the change. Not in a group, not for a
        // freely chosen episode. The swap happens only once it covers the picture (`swap`).
        val episode = plan?.nextEpisode
        val zooms = fromCard && id.isEmpty() && !inGroup && episode != null
        if (zooms && episode != null) {
            cardsSwitch = CardsSwitch(episode, SystemClock.elapsedRealtime())
            AppLog.writeOut("[Karte] Start → ${episode.id}")
        }
        val swapOff = if (zooms) SystemClock.elapsedRealtime() + (cardsMetrics.swap * 1000).toLong() else 0L
        offeringArt = "keiner"
        overlay = "nichts"
        val spot = (if (vlcFree) player.time / 1000.0 else position).coerceAtLeast(0.0)
        app.doneWatch(spot, duration)
        try {
            val answer = JSONObject(withContext(Dispatchers.IO) { app.kern.episodeSwitch(id, spot).await() })
            app.toStop(answer.fieldText("nachmeldung"))
            app.logWrite()
            when (answer.optString("ergebnis")) {
                "gewechselt" -> {
                    val new = answer.fieldText("spielplan")
                    // Swap only once the card covers the picture, otherwise black shows around it.
                    val rest = swapOff - SystemClock.elapsedRealtime()
                    if (rest > 0) delay(rest)
                    if (new != null && !ended[0]) {
                        stopNow("Folgenwechsel")
                        launch(playPlanRead(new), since)
                        cardsSwitch?.let { AppLog.writeOut("[Karte] Tausch nach ${SystemClock.elapsedRealtime() - it.beginning} ms") }
                    }
                }
                "gescheitert" -> hint = errorString(context, Exception(answer.fieldText("fehler") ?: translated(failure)))
            }
            if (answer.optString("ergebnis") != "gewechselt") cardsSwitch?.let { cardsSwitch = it.copy(failed = true) }
        } catch (e: CancellationException) { throw e } catch (e: Exception) {
            hint = errorString(context, e)
            cardsSwitch?.let { cardsSwitch = it.copy(failed = true) }
        } finally {
            switches = false
        }
    }

    // MARK: Stream watch: mirrors `VLCPlayer.swift` (iOS/tvOS): network changes and hangs.
    // `:http-reconnect` only acts when the connection breaks. If it stays open and nothing arrives,
    // libVLC waits indefinitely; if it breaks, libVLC reports an end of file and the player closed or
    // advanced to the next episode. The thresholds are decided by `StreamWatch` in the package (via the core).

    /**
     * **The stream is being rebuilt** (iOS `restoring`). The UI then shows "Connection lost", and
     * the tick reports the last good position instead of VLC's time, which sits at the end of the file
     * after a drop.
     */
    var restoring by mutableStateOf(false); private set
    private var lastGoodPoint = 0.0
    private var streamStandsSince: Long? = null
    private var streamLastTime = -1L
    private var streamRead = 0L
    private var streamBufferGrew = 0L
    private var lastImages = -1L
    private var imagesStateSince: Long? = null
    private var lastJump = 0L
    private var lastNewLayout = 0L
    private var lastRat = ""
    private var tracksPostLayout = false
    private var networkReachable = true
    private var waitsNetwork = false
    private var networkSwitchSince: Long? = null
    private var lastNetwork: android.net.Network? = null
    private var networkCallback: android.net.ConnectivityManager.NetworkCallback? = null

    private fun powerGuardBackSet() {
        streamStandsSince = null; streamLastTime = -1; streamRead = 0; streamBufferGrew = SystemClock.elapsedRealtime()
        lastImages = -1; imagesStateSince = null; lastRat = ""
        firstFrameRun = 0.0; firstFrameBefore = -1.0; firstFrameWatched = false
    }

    // MARK: First frame: mirrors `VLCPlayer.firstFrameCheck`, rule `FirstFrame` in the package (via the core).
    // `StreamWatch.imagesState` is silent as long as no frame has ever arrived; a stream with a running
    // clock and audio but no first frame therefore stayed black, unreported and without intervention.

    /** What has been tried for this title (`FirstFrame.Level` as a number); per title, not per rebuild. */
    private var firstFrameLevel = 0
    /** Movie time since the last rebuild during which the clock ran. */
    private var firstFrameRun = 0.0
    private var firstFrameBefore = -1.0
    private var firstFrameWatched = false
    /** After the second rescue the title stays on the software decoder, also across a network rebuild. */
    private var softwareDecoder = false
    /** Media3 has failed for this title: it keeps playing with VLC (`media3GiveUp`). */
    private var media3Failed = false
    /** Incremented per open; a queued VLC open from before is dropped (read on the VLC thread). */
    @Volatile private var openGeneration = 0
    /** A Dolby Vision decoder and a display with Dolby Vision, asked once per player. */
    private val dolbyVisionHere: Boolean by lazy {
        PlayerEngine.dolbyVisionPossible(context).also { AppLog.writeOut("[Media3] Gerät kann Dolby Vision: $it") }
    }

    /**
     * Media3 failed, before the first frame or later: the same spot with VLC (the base layer there instead of
     * nothing). `media3Failed` stays set for the title, across every later rebuild (`mediaOpen`).
     */
    private fun media3GiveUp() {
        val p = plan ?: return
        if (ended[0] || !player.usesMedia3) return
        media3Failed = true
        val spot = if (imageFree) pointNow() else position
        AppLog.writeOut("[Media3] gescheitert${if (imageFree) " nach dem ersten Bild" else ""} → VLC bei ${spot.toInt()} s")
        powerGuardBackSet()
        end[0] = false
        mediaOpen(p.url, spot)
    }
    /** Picture-in-picture: a missing frame is not the rule's business there. Set by `PlayerPage`. */
    var smallWindow = false
    /** For the tech overlay; `null` as long as no intervention happened. */
    var firstFrameHint by mutableStateOf<String?>(null); private set

    /** Once per tick, only while the clock runs. `true` if rebuilt. */
    private fun firstFrameCheck(): Boolean {
        if (ended[0] || switches || !player.isPlaying) return false
        val spot = player.time / 1000.0
        firstFrameRun += Kern.firstFrameGrowth(firstFrameBefore, spot)
        firstFrameBefore = spot
        val values = player.counters() ?: return false
        val shown = values.displayedPictures
        if (shown > 0) {
            if (!firstFrameWatched && firstFrameLevel != 0)
                AppLog.writeOut("[Bild] erstes Bild nach Rettung (Stufe $firstFrameLevel) bei ${spot.toInt()} s · Dekoder ${if (softwareDecoder) "Software" else "frei"}")
            firstFrameWatched = true
            return false
        }
        val codec = app.kern.firstFrameVideoCodec()
        val rat = Kern.firstFrameRat(codec.isNotEmpty(), smallWindow, shown.toInt().toLong(), firstFrameRun, firstFrameLevel.toLong())
        if (rat == "nichts" || rat == "warten") return false
        AppLog.writeOut("[Bild] kein erstes Bild nach ${firstFrameRun.toInt()} s Laufzeit bei ${spot.toInt()} s · Server $codec" +
            " · dekodiert ${values.decodedVideo}, gezeigt $shown, verloren ${values.lostPictures} · Ton gespielt ${values.playedAbuffers}" +
            " · Dekoder ${if (softwareDecoder) "Software" else "frei"} → $rat")
        firstFrameLevel = Kern.firstFrameNext(rat, firstFrameLevel.toLong()).toInt()
        firstFrameHint = Kern.firstFrameHint(firstFrameLevel.toLong()).ifEmpty { null }
        if (rat == "aufgeben") return false
        if (rat == "softwareDekoder") softwareDecoder = true
        val p = plan ?: return false
        AppLog.writeOut("[Netz] kein erstes Bild${if (softwareDecoder) ", jetzt mit Software-Dekoder" else ""} → Strom neu aufbauen bei ${spot.toInt()} s")
        // Like `newConnect`, but at the position where the clock currently is and without a lockout: the
        // rule itself waits out each stage's grace period.
        lastNewLayout = SystemClock.elapsedRealtime()
        lastGoodPoint = spot
        restoring = true
        tracksPostLayout = true
        powerGuardBackSet()
        end[0] = false
        stopNow("kein erstes Bild")
        app.kern.playbackPoint(spot)
        mediaOpen(p.url, spot)
        return true
    }

    private fun fromSlab() = plan?.url?.startsWith("file:") != false

    /**
     * **Where the network goes** (iOS `NWPathMonitor` -> `legSwitched`). A change is only noted:
     * a full buffer keeps playing, and the stream is rebuilt only if the picture really stalls. If
     * playback had already stopped without network, it is caught up immediately.
     */
    // MARK: Audio focus and headphones

    /**
     * **Audio focus like any Android player** (findroid#536). libVLC does not request it: a call, an
     * alarm or another app used to play right over the movie. On loss the player pauses; after only a
     * short loss (call, navigation) it resumes by itself. Ducking for an announcement is left to the
     * system (`setWillPauseWhenDucked(false)`).
     */
    private var focusRequest: android.media.AudioFocusRequest? = null
    /** Only a focus loss paused; then regaining resumes, otherwise never. */
    private var focusPause = false

    private fun focusFetch() {
        val manager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        val petition = focusRequest ?: android.media.AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(filmAudio)
            .setWillPauseWhenDucked(false)
            .setOnAudioFocusChangeListener { art ->
                when (art) {
                    AudioManager.AUDIOFOCUS_LOSS -> { focusPause = false; vlcNowOrAfter("Pause") { if (player.isPlaying) player.pause() } }
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> if (vlcFree && player.isPlaying) { focusPause = true; player.pause() }
                    AudioManager.AUDIOFOCUS_GAIN -> if (focusPause) { focusPause = false; vlcNowOrAfter("Weiter") { if (!player.isPlaying) player.play() } }
                }
                AppLog.writeOut("[Ton] Audiofokus ${focusName(art)}")
            }.build().also { focusRequest = it }
        runCatching { manager.requestAudioFocus(petition) }
    }

    private fun focusName(art: Int) = when (art) {
        AudioManager.AUDIOFOCUS_GAIN -> "zurueck"
        AudioManager.AUDIOFOCUS_LOSS -> "verloren"
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> "kurz verloren"
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> "leiser"
        else -> art.toString()
    }

    /**
     * **Headphones unplugged, Bluetooth gone: pause** instead of continuing loudly on the speaker
     * (`ACTION_AUDIO_BECOMING_NOISY`), like any media app.
     */
    private val headerListenerDistance = object : android.content.BroadcastReceiver() {
        override fun onReceive(k: Context?, i: Intent?) {
            if (i?.action != AudioManager.ACTION_AUDIO_BECOMING_NOISY) return
            AppLog.writeOut("[Ton] Ausgang weg, angehalten")
            focusPause = false
            vlcNowOrAfter("Pause") { if (player.isPlaying) player.pause() }
        }
    }
    private var headerListenerSignedIn = false

    private fun audioObserve() {
        focusFetch()
        if (headerListenerSignedIn) return
        runCatching {
            ContextCompat.registerReceiver(context, headerListenerDistance, android.content.IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
                                           ContextCompat.RECEIVER_NOT_EXPORTED)
            headerListenerSignedIn = true
        }
    }

    private fun audioSignOut() {
        focusRequest?.let { a -> runCatching { (context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager)?.abandonAudioFocusRequest(a) } }
        if (headerListenerSignedIn) { runCatching { context.unregisterReceiver(headerListenerDistance) }; headerListenerSignedIn = false }
    }

    private fun networkObserve() {
        if (networkCallback != null) return
        val management = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager ?: return
        val callback = object : android.net.ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: android.net.Network) { run.launch { networkPresent(network) } }
            override fun onLost(network: android.net.Network) { run.launch { networkDistance(network) } }
        }
        if (runCatching { management.registerDefaultNetworkCallback(callback) }.isSuccess) networkCallback = callback
    }

    /**
     * **A network that costs nothing**, for `Prebuffer`: not metered (Wi-Fi, cable) and without data saver
     * for this app. Like `!isExpensive && !isConstrained` on iOS.
     */
    private fun networkFavorable(): Boolean {
        val management = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager ?: return false
        val capable = management.getNetworkCapabilities(management.activeNetwork ?: return false) ?: return false
        return capable.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            && management.restrictBackgroundStatus != android.net.ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED
    }

    private fun networkSignOut() {
        val callback = networkCallback ?: return
        networkCallback = null
        runCatching { (context.getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager)?.unregisterNetworkCallback(callback) }
    }

    private fun networkPresent(network: android.net.Network) {
        val before = lastNetwork
        lastNetwork = network
        networkReachable = true
        if (waitsNetwork) {
            AppLog.writeOut("[Netz] wieder da → nachholen")
            waitsNetwork = false
            newConnect("Netz zurueck")
            return
        }
        if (before == null || before == network) return
        networkSwitchSince = SystemClock.elapsedRealtime()
        AppLog.writeOut("[Netz] Wechsel — Puffer laeuft weiter")
    }

    private fun networkDistance(network: android.net.Network) {
        if (lastNetwork != null && network != lastNetwork) return
        networkReachable = false
        if (lastGoodPoint > 1 && !fromSlab()) waitsNetwork = true
        AppLog.writeOut("[Netz] kein Weg mehr — vorgemerkt bei ${lastGoodPoint.toInt()} s")
    }

    private fun rat(standstill: Long, now: Long) = Kern.streamWatchRat(standstill / 1000.0,
        networkSwitchSince?.let { (now - it) / 1000.0 } ?: -1.0, false,
        (now - lastJump) / 1000.0, (now - streamBufferGrew) / 1000.0)

    /**
     * Once per tick (iOS `checkStandstill` + `imageFlow`): if the clock stands although VLC plays, or
     * it runs but no new frame arrives, `StreamWatch` decides whether to rebuild.
     */
    private fun streamCheck() {
        // Before the first frame the stream still seeks its start position; that is not a hang (iOS `firstPoint`).
        if (ended[0] || switches || fromSlab() || !imageFree || !player.isPlaying) { streamStandsSince = null; return }
        val t = player.time
        val now = SystemClock.elapsedRealtime()
        val values = player.counters()
        // If the buffer grows, the stream is alive. VLC counts in `int`; read as unsigned (`PlayerEngine.counters`).
        val hasRead = values?.readBytes ?: 0L
        if (hasRead > streamRead) streamBufferGrew = now
        streamRead = hasRead

        if (t == streamLastTime || t <= 0) {
            val since = streamStandsSince ?: now.also { streamStandsSince = it }
            val r = rat(now - since, now)
            if (r != lastRat && r != "nochNicht") AppLog.writeOut("[Netz] Bild steht seit ${(now - since) / 1000} s → $r")
            lastRat = r
            if (r == "neuVerbinden") newConnect("Bild steht seit ${(now - since) / 1000} s")
            return
        }
        // The clock runs again: a rebuild succeeded.
        if (restoring && streamLastTime > 0) {
            restoring = false
            AppLog.writeOut("[Netz] wiederhergestellt bei ${t / 1000} s")
            if (tracksPostLayout && player.audioTracksCount > 0) { tracksPostLayout = false; languagesApply() }
        }
        streamLastTime = t
        streamStandsSince = null
        lastRat = ""
        // **The clock runs, but does a frame arrive?** (iOS `imageFlow`: measured 76 s of frozen picture with
        // a running clock.)
        val images = values?.displayedPictures ?: -1L
        if (Kern.streamWatchImagesState(lastImages, images)) { if (imagesStateSince == null) imagesStateSince = now } else imagesStateSince = null
        lastImages = images
        imagesStateSince?.let { since ->
            if (rat(now - since, now) == "neuVerbinden") {
                imagesStateSince = null
                newConnect("kein neues Bild seit ${(now - since) / 1000} s, Uhr laeuft weiter")
                return
            }
        }
        // Record only what is plausible: after a drop this would otherwise be the end of the file.
        val spot = t / 1000.0
        if (!restoring && (duration <= 0 || spot < duration - 1)) lastGoodPoint = spot
    }

    /** VLC reports end or error. `true` if it was a drop and the stream is being rebuilt. */
    private fun teardown(condition: String): Boolean {
        if (ended[0] || switches || fromSlab() || !imageFree || lastGoodPoint <= 1) return false
        val freshValue = networkSwitchSince?.let { SystemClock.elapsedRealtime() - it < Kern.streamWatchNetworkChangeDeadline() * 1000 } ?: false
        if (!(if (duration > 0) lastGoodPoint < duration - 10 else freshValue)) return false
        AppLog.writeOut("[Netz] Zustand $condition: Strom tot bei ${lastGoodPoint.toInt()} s von ${duration.toInt()} s")
        run.launch { newConnect("Strom abgerissen") }
        return true
    }

    /**
     * **Reopen the stream and seek to the last good position** (iOS `newConnect`). Without network only
     * note it; `networkPresent` catches up. After a change Android reports several times; the 5 s lockout keeps
     * the stream from being rebuilt in a loop and never finishing.
     */
    private fun newConnect(reason: String) {
        val p = plan ?: return
        if (ended[0] || switches || fromSlab() || lastGoodPoint <= 1) return
        // Already here: the UI says what is going on, and the tick holds the good position.
        restoring = true
        if (!networkReachable) {
            waitsNetwork = true
            AppLog.writeOut("[Netz] $reason, aber kein Netz — vorgemerkt bei ${lastGoodPoint.toInt()} s")
            return
        }
        val now = SystemClock.elapsedRealtime()
        val wait = 5000 - (now - lastNewLayout)
        if (wait > 0) {
            // After an end or error VLC no longer plays, so the watch does not fire again; without this second
            // attempt the notice would stay forever.
            if (!player.isPlaying) run.launch { delay(wait); if (restoring && !player.isPlaying) newConnect(reason) }
            return
        }
        lastNewLayout = now
        AppLog.writeOut("[Netz] $reason → Strom neu aufbauen bei ${lastGoodPoint.toInt()} s")
        powerGuardBackSet()
        end[0] = false
        // Apply the track choice by `TrackRule` again once the new stream runs; otherwise it brings VLC's
        // own preselection and disabled subtitles came back on by themselves (iOS).
        tracksPostLayout = true
        stopNow("Neuaufbau")
        app.kern.playbackPoint(lastGoodPoint)
        mediaOpen(p.url, lastGoodPoint)
    }

    /**
     * A manual seek from the bar, a key or a remote command. **In a group a request**: the display is
     * already at the target (`jumped(on:)` on iOS); the seek happens when the command comes back.
     */
    fun vault(target: Double) {
        if (inGroup) {
            val z = if (duration > 0) target.coerceIn(0.0, duration) else target.coerceAtLeast(0.0)
            position = z
            app.kern.syncPlayPleaseJump(z)
            return
        }
        jumpReally(target)
    }

    private fun jumpReally(target: Double) {
        lastJump = SystemClock.elapsedRealtime()
        val z = if (duration > 0) target.coerceIn(0.0, duration) else target.coerceAtLeast(0.0)
        vlcNowOrAfter("Sprung") { player.time = (z * 1000).toLong() }
        position = z
        // Immediately with the target position, queued and not awaited; also "seek to" from the dashboard.
        // The core holds the target until VLC is there, and the offer follows it at once.
        val answer = JSONObject(app.kern.jumpReported(z))
        if (answer.has("position")) {
            position = answer.getDouble("position")
            offeringAdopt(answer)
        }
        // The card's countdown restarts after a seek (seeking to the end must not advance immediately).
        if (overlay == "karte") fillNew++
    }

    private fun offeringAdopt(answer: JSONObject) {
        offeringArt = answer.optString("angebot", "keiner")
        offeringPost = if (answer.isNull("nach")) null else answer.getDouble("nach")
        offerText = answer.optString("angebotstext")
        overlay = answer.optString("einblendung", "nichts")
        countdown = answer.optDouble("countdown", 0.0)
        countdownRest = answer.optInt("countdownRest", 0)
        countdownLength = answer.optDouble("countdownLaenge", 7.0)
    }

    fun toggle() {
        jerk(Jerk.Medium)
        // In a group the button only flips when the command comes back, then for everyone at the same time.
        if (inGroup) { app.kern.syncPlayPleaseToggle(running); return }
        // Reported from VLC's `Playing`/`Paused` (`installEventListener`).
        if (!vlcFree) { if (running) halt() else vlcNowOrAfter("Weiter") { player.play() }; return }
        if (player.isPlaying) player.pause() else resume()
    }

    /**
     * **Resume at the viewer's request**, after a long pause a bit back (`PauseJumpBack`, iOS
     * `resume`). The position is set while stopped, then it plays: the first new frame is already the
     * earlier one, and the display takes the target at the same moment. Not before the first frame (the
     * start position is not set yet) and not in a group.
     */
    fun resume() {
        if (imageFree && !restoring) {
            val target = app.kern.resumeTarget(pointNow(), inGroup || sharedAn)
            if (target >= 0) jumpReally(target)
        }
        vlcNowOrAfter("Weiter") { player.play() }
    }

    fun tempoSet(new: Float) {
        tempo = new
        player.rateSet(new)
    }

    fun imageFillingSet(new: Boolean) {
        fillFrame = new
        player.fillFrameSet(new)
        app.store.remember("bildfuellend", if (new) "1" else "0")
    }

    fun sleepTimeSet(minutes: Int) {
        sleepTime = minutes
        sleepJob?.cancel()
        if (minutes <= 0) return
        sleepJob = run.launch {
            delay(minutes * 60_000L)
            halt()
            sleepTime = 0
            hint = translated("Schlafzeit abgelaufen.")
        }
    }

    // Tracks: mirrors `VLCPlayerView` in `Sources/Shared/VLCPlayer.swift`.
    // The core decides via `TrackRule`/`TrackMapping`; only libVLC lives here.

    /** An external subtitle file of the episode: Jellyfin index, URL, MD5 of the URL. */
    private class SubtitleFile(val index: Long, val address: String, val attribute: String)
    private val files = ArrayDeque<SubtitleFile>()
    /** The file whose track is currently expected, since when, and which subtitle tracks existed before. */
    private var fileLoads: SubtitleFile? = null
    private var fileSince = 0L
    private var tracksPreFile: Set<Int> = emptySet()
    /**
     * **VLC track ID -> identifier as in libVLC 4** (`<md5 of the URL>/spu/<n>`). libVLC 3 does not put the
     * MD5 before the track; the track that appears new after attaching a file is its own.
     */
    private val fileTracks = HashMap<Int, String>()
    /** Jellyfin index -> MD5 of the address, for Media3, which gets the files right when opening. */
    private val fileAttributes = HashMap<Long, String>()
    private var tracksSelected = false

    /** New per episode: fetch the files from the plan and give their signature to the core. None from disk. */
    private fun filesPrepare() {
        files.clear(); fileLoads = null; fileTracks.clear(); fileAttributes.clear(); tracksSelected = false
        val list = runCatching { JSONArray(app.kern.subtitleFiles()) }.getOrNull() ?: return
        for (i in 0 until list.length()) {
            val o = list.getJSONObject(i)
            val address = o.getString("adresse")
            val attribute = java.security.MessageDigest.getInstance("MD5").digest(address.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            app.kern.subtitleAttributeSet(o.getLong("index"), attribute)
            files.addLast(SubtitleFile(o.getLong("index"), address, attribute))
            fileAttributes[o.getLong("index")] = attribute
        }
    }

    /**
     * **External subtitles as slaves**, one after another, only after the file's tracks are chosen, so the
     * new track is clearly the attached file's. `select = false`: whether it is on is decided by
     * `TrackRule`. On Apple they are attached before opening (VLCKit 4 knows the MD5).
     */
    private fun nextFile() {
        val d = files.removeFirstOrNull()
        fileLoads = d
        if (d == null) return
        tracksPreFile = player.spuTracks?.map { it.id }?.toSet().orEmpty()
        fileSince = SystemClock.elapsedRealtime()
        val attached = player.slaveAdd(IMedia.Slave.Type.Subtitle, Uri.parse(StreamForwarder.gemeinsam.address(d.address)), false)
        AppLog.writeOut("[Spuren] Datei ${d.index} angehaengt $attached, Merkmal ${d.attribute}")
        if (!attached) nextFile()
    }

    private fun subtitleTrackNew(id: Int) {
        val d = fileLoads
        if (d != null && id >= 0 && id !in tracksPreFile && id !in fileTracks) {
            fileTracks[id] = "${d.attribute}/spu/${fileTracks.values.count { it.startsWith(d.attribute) }}"
            AppLog.writeOut("[Spuren] Datei ${d.index} ist Spur $id")
            nextFile()
        }
        if (!tracksSelected) return
        val selected = app.kern.openSubtitle(tracksJson(false)).toInt()
        if (selected >= 0) player.spuTrack = selected
        app.logWrite()
    }

    /** If a file's track does not show up (broken file, server gone), try the next one. */
    private fun fileDeadline() {
        if (fileLoads != null && SystemClock.elapsedRealtime() - fileSince > 8000) {
            AppLog.writeOut("[Spuren] Datei ${fileLoads?.index} kam nicht")
            nextFile()
        }
    }

    /** The tracks of one kind as JSON for the core, with language, codec and channels from the media where known. */
    private fun tracksJson(audio: Boolean): String {
        val list = (if (audio) player.audioTracks else player.spuTracks)?.filter { it.id >= 0 }.orEmpty()
        val details = player.trackDetails()
        val a = JSONArray()
        for (t in list) {
            // With Media3 the track of a file carries its Jellyfin index (`TrackDetail.file`).
            val file = fileTracks[t.id] ?: details[t.id]?.file?.let { i -> fileAttributes[i]?.let { "$it/spu/0" } }
            val m = if (file == null) details[t.id] else null
            a.put(JSONObject().apply {
                put("id", t.id)
                put("kennung", file ?: ((if (audio) "audio/" else "spu/") + t.id))
                put("name", t.name.orEmpty())
                m?.language?.takeIf { it.isNotEmpty() }?.let { put("sprache", it) }
                m?.fourcc?.takeIf { it != 0 }?.let { put("fourcc", it) }
                m?.takeIf { it.audio }?.channels?.takeIf { it > 0 }?.let { put("kanaele", it) }
            })
        }
        return a.toString()
    }

    /**
     * Audio and subtitles by `TrackRule`, once per title when the tracks are known: manual choice per
     * series or movie, settings, server defaults, forced subtitles, otherwise off.
     */
    private fun languagesApply() {
        val e = app.settings
        val answer = JSONObject(app.kern.tracksSelect(
            tracksJson(true), tracksJson(false), player.audioTrack.toLong(), e.audioLanguage, e.subtitleLanguage,
            e.subtitleAutomatic, app.store.rememberValue(AUDIO_JE_TITLE) ?: "{}", app.store.rememberValue(UT_JE_TITLE) ?: "{}"))
        if (answer.has("ton") && !answer.isNull("ton")) player.audioTrack = answer.getInt("ton")
        // Actively turn off: the file often brings its own preselection.
        player.spuTrack = answer.optInt("untertitel", -1)
        tracksSelected = true
        audioReport()
        app.logWrite()
        nextFile()
    }

    /** Chosen by hand: applies at once and to the whole series. */
    fun audioFromHand(id: Int) {
        player.audioTrack = id
        app.store.remember(AUDIO_JE_TITLE, app.kern.audioFromHand(tracksJson(true), id.toLong(), app.store.rememberValue(AUDIO_JE_TITLE) ?: "{}"))
    }

    /** `-1` means off; that also applies to the whole series, the next episode stays without. */
    fun subtitleFromHand(id: Int) {
        player.spuTrack = id
        app.store.remember(UT_JE_TITLE, app.kern.subtitleFromHand(tracksJson(false), id.toLong(), app.store.rememberValue(UT_JE_TITLE) ?: "{}"))
    }

    /** Audio "Deutsch · AAC · 5.1", subtitles with format, "Erzwungen", "Hörgeschädigt", "Datei", instead of libVLC's "Track 1 - [English]". */
    fun trackList(audio: Boolean): List<Pair<Int, String>> {
        val names = runCatching { JSONObject(app.kern.trackNames(tracksJson(true), tracksJson(false))) }.getOrNull() ?: return emptyList()
        val a = names.optJSONArray(if (audio) "ton" else "untertitel") ?: return emptyList()
        return (0 until a.length()).map { a.getJSONObject(it) }.map { o ->
            val parts = listOfNotNull(o.getString("text"),
                translated("Erzwungen").takeIf { o.optBoolean("erzwungen") },
                translated("Hörgeschädigt").takeIf { o.optBoolean("hoergeschaedigt") },
                translated("Datei").takeIf { o.optBoolean("datei") })
            o.getInt("id") to parts.joinToString(" · ")
        }
    }

    /** Count only while someone is looking; same tick as `PlaybackTick`, for the same reason. */
    suspend fun techBadgeTick(active: Boolean) {
        if (!active || plan == null) { techLive = null; return }
        techFixed = JSONArray(app.kern.techFixed(app.settings.techBadgeMeasure)).let { a ->
            (0 until a.length()).map { a.getJSONObject(it).let { o ->
                TechRow(o.fieldText("schluessel")?.let { k -> translated(k) }, o.getString("text"), o.getString("art"), o.optBoolean("kopf"))
            } }
        }
        while (true) {
            // VLC counts in `int`, which overflows past 2 GB; `PlayerEngine.counters` reads it unsigned.
            val values = if (vlcFree) player.counters() else null
            if (values != null) {
                techLive = JSONObject(app.kern.techTick(
                    values.readBytes, values.demuxReadBytes, values.displayedPictures, values.lostPictures,
                    values.decodedVideo, values.decodedAudio, values.playedAbuffers, values.lostAbuffers,
                    values.demuxCorrupted, values.demuxDiscontinuity, position, player.isPlaying))
            }
            delay(2000)
        }
    }

    /**
     * **The state for the group, on every display tick** (`bridgeCatchUp` on iOS): title, whether the
     * picture is up and no change is running, the displayed position (after a seek the target, until VLC
     * is there) and whether VLC plays. Between ticks the core advances the position with the clock.
     */
    private fun sharedReport(wish: PlayRequest) {
        val m = mark
        if (m <= 0) return
        app.kern.syncPlayTick(m, plan?.itemId ?: wish.id, imageFree && !switches && !restoring, position, player.isPlaying)
    }

    /**
     * **The group's steps as soon as the session issues them**, at the time it computed, not on the next
     * tick. Ends when the core has detached the player (empty answer).
     */
    private suspend fun stepRun(m: Long) {
        while (true) {
            val raw = runCatching { withContext(Dispatchers.IO) { app.kern.syncPlayStep(m).await() } }.getOrNull()
            if (raw.isNullOrEmpty() || mark != m) return
            val o = JSONObject(raw)
            when (o.optString("art")) {
                // libVLC: `play()` and `pause()` set the state, they do not toggle.
                "weiter" -> vlcNowOrAfter("Weiter") { player.play() }
                "anhalten" -> halt()
                "springen" -> jumpReally(o.optDouble("wert", position))
                // The group watches something else: switch in the open player, from the group's position.
                "laden" -> {
                    val title = o.optString("titel")
                    val since = o.optDouble("wert", 0.0)
                    if (plan?.itemId == title) jumpReally(since)
                    else run.launch { changeTo(title, "Die Folge konnte nicht geladen werden.", since) }
                }
            }
        }
    }

    /**
     * Open, then the tick. Mirrors `observe()` in `Sources/tvOS/PlayerScreen.swift`, with the URL choice
     * (disk before server) and the remote commands from `PlayerPage` that existed before.
     */
    suspend fun openAndTick(wish: PlayRequest, close: () -> Unit) {
        // **If the title belongs to the group, join right away**, before opening, like `onAppear` on iOS.
        // The tick reports "ready" only when the picture is up.
        mark = runCatching { withContext(Dispatchers.IO) { app.kern.syncPlayConnect(wish.id).await() } }.getOrDefault(0L)
        if (mark > 0) run.launch { stepRun(mark) }
        try {
            // **Disk before any server**; in flight mode a timeout would wait otherwise.
            val slab = app.downloads.file(wish.id)
            val entries = app.downloads.entries(wish.id)
            val answer = if (slab != null && entries != null) {
                val image = app.downloads.imageFile(entries.id).takeIf { it.exists() }?.let { "file://" + it.absolutePath }.orEmpty()
                app.kern.playbackFromTheSlab(entries.json().toString(), slab.absolutePath, image)
            } else withContext(Dispatchers.IO) { app.kern.playbackOpen(wish.id, wish.sourceID).await() }
            launch(playPlanRead(answer), wish.since)
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
            hint = translated("Die Folge konnte nicht geladen werden.")
            return
        }
        var onlyTime = false
        val closeState = app.playerClose.intValue
        while (true) {
            delay(250)
            // Account switch or sign-out: this player first, with the stop for the old account.
            if (app.playerClose.intValue != closeState) { finish(close); return }
            // If a stop or open is still queued on the VLC thread, every question to VLC would wait here.
            if (!vlcFree) continue
            // **Only the time in between** (mirrors iOS `observe`): in the half-second tick it started late
            // after playing and counted unevenly.
            onlyTime = !onlyTime
            if (onlyTime) {
                if (!switches && imageFree && !restoring) {
                    val z = app.kern.displayTime((player.time / 1000.0).coerceAtLeast(0.0), atPush)
                    if (z >= 0 && !atPush) position = z
                }
                sharedReport(wish)
                continue
            }
            // **Commands from the dashboard or another device**; the socket deposits them.
            runCatching { JSONArray(app.kern.remoteCommands()) }.getOrNull()?.let { a ->
                for (i in 0 until a.length()) {
                    val b = a.getJSONObject(i)
                    when (b.optString("art")) {
                        "pause" -> if (player.isPlaying) toggle()
                        "weiter" -> if (!player.isPlaying) toggle()
                        "umschalten" -> toggle()
                        // **Another device takes over** (the notice came shortly before): the picture leaves as a card
                        // (`HandoffExit`). Otherwise, dashboard or another app, as usual.
                        "stopp" -> {
                            val target = app.kern.handoffTargetTake()
                            if (target.isNotEmpty() && handIn(target, close)) return
                            finish(close); return
                        }
                        "springen" -> vault(b.optDouble("wert", position))
                        "vor" -> vault(position + preS)
                        "zurueck" -> vault(position - backS)
                        "naechste" -> if (hasNext) nextEpisode()
                        // Mirrors `case .previous: break` in `PlayerScreen.swift` (tvOS/iOS): no effect.
                    }
                }
            }
            // Debug build only: `adb shell run-as <bundle-id> touch files/meldungen-haengen`
            // makes every report hang for 60 s, like a server that does not answer.
            if (debugBuild) app.kern.messagesHanging(java.io.File(context.filesDir, "meldungen-haengen").exists())
            app.logWrite()
            // During the change the tick is silent; the old stream's time would already belong to the new episode.
            if (switches) { sharedReport(wish); continue }
            if (!firstFrameCheck()) streamCheck()
            delayCatchUp()
            val length = (player.length / 1000.0).coerceAtLeast(0.0)
            // During the rebuild the last good position, not VLC's time: after a drop that jumps to the end.
            val reported = if (restoring) lastGoodPoint else (player.time / 1000.0).coerceAtLeast(0.0)
            val answer = JSONObject(app.kern.playbackTick(
                if (restoring) maxOf(length, duration) else length, reported, showsImage[0], player.isPlaying,
                player.audioTracksCount > 0, atPush, app.settings.introOutroAutomatic))
            if (answer.optBoolean("ladeschirmWeg")) {
                imageFree = true
                // From a handover: the card now zooms onto the picture, the audio fades in.
                Handoff.imagePresent(app, plan?.itemId ?: wish.id)
                if (handoffFadeIn) {
                    handoffFadeIn = false
                    run.launch { for (i in 1..12) { delay(50); vlcNowOrAfter("Aufblenden") { player.volume = i * 100 / 12 } } }
                    AppLog.writeOut("[Ton] blendet auf (Übergabe)")
                }
                // The new episode's first frame is up: the card's preview image may fade out.
                cardsSwitch?.takeIf { it.imageSince == null }?.let {
                    val since = SystemClock.elapsedRealtime() - it.beginning
                    cardsSwitch = it.copy(imageSince = since)
                    AppLog.writeOut("[Karte] erstes Bild nach $since ms")
                }
            }
            if (answer.optBoolean("spurenAnwenden")) languagesApply()
            fileDeadline()
            // After a seek the core returns the target position until VLC is there.
            if (!atPush && answer.has("position")) position = answer.getDouble("position")
            if (!restoring || length > 0) duration = length
            if (imageFree && position > 0) app.playPoint = PlayRequest(plan?.itemId ?: wish.id, position, if ((plan?.itemId ?: wish.id) == wish.id) wish.sourceID else "")
            sessionReport()
            // If the card was up, it zooms into the picture on expiry (`toNextEpisode(fromCard: cardBefore)`).
            val cardBefore = overlay == "karte"
            if (answer.has("angebot")) offeringAdopt(answer)
            // "Skip intro and outro automatically": the same step as the button; the core picks the section, once each.
            if (answer.optBoolean("autoUeberspringen")) { AppLog.writeOut("[Abschnitt] überspringt automatisch"); offeringRun() }
            sharedReport(wish)
            // **Prepare the next episode** while this one still plays; when and over which network is decided
            // by the core (`Prebuffer`): from three minutes before the end, Wi-Fi or cable without data saver.
            if (!switches && app.kern.prebufferDue(position, duration, networkFavorable())) {
                run.launch(Dispatchers.IO) { app.kern.episodePrepare().await(); app.logWrite() }
            }
            // Whether automatic is decided by the core (card, not cancelled; if it counts, it owns this).
            if (answer.optBoolean("weiterschalten")) {
                if (cardBefore) AppLog.writeOut("[Karte] Countdown abgelaufen")
                nextEpisode(fromCard = cardBefore)
            }
            else if (end[0] && !hasNext) { finish(close); break }
        }
    }
}

/**
 * Mirrors `PlayerScreen` in `Sources/iOS/PlayerScreen.swift`.
 *
 * **Decisions live in the package; here only picture and finger.** `PlayItem` (above) holds VLC,
 * the tick and the reports; the TV uses the same piece (`tv/TvPlayer.kt`).
 *
 * - Controls appear fast (180 ms) and leave slowly (340 ms), after 4 s idle; not while paused,
 *   dragging or with a sheet open.
 * - **A tap toggles after 260 ms**; a second one before that seeks and leaves the controls as they
 *   were (toggling at once and reverting flashed on every double tap).
 * - The center pauses, also with hidden controls; whoever taps there means the button.
 * - Two fingers switch hard between fit and fill; a smooth zoom that lands wrong looked more broken
 *   on iOS than a toggle.
 * - The position is read **before** pausing: VLC resets its clock on pause.
 */
@Composable
fun PlayerPage(app: SwiftlyApplication, wish: PlayRequest, smallWindow: Boolean, imageImage: () -> Boolean, close: () -> Unit) {
    val context = LocalContext.current
    val run = rememberCoroutineScope()
    val jerk = rememberJerk()
    // Landscape, hidden system bars and "keep screen on" are set by `PlayerActivity` before the first
    // frame (mirrors `PlayerFrame` on iOS). Set here, the player rotated to landscape only after opening,
    // rotated back once more on close, and the bars flashed on teardown.

    val mediaWork = remember { PlayItem(app, context, run, jerk) }
    // **Re-attach the video surface** if Android tore it down on moving to the background; otherwise
    // audio kept playing and the picture stayed black until restart.
    val area = remember { arrayOfNulls<VLCVideoLayout>(1) }
    @Suppress("DEPRECATION")
    val lifeRun = androidx.compose.ui.platform.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifeRun) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_PAUSE) mediaWork.backgroundReport()
            if (event == androidx.lifecycle.Lifecycle.Event.ON_START && !mediaWork.player.isAttached()) {
                area[0]?.let { mediaWork.player.attach(it) }
            }
        }
        lifeRun.addObserver(observer)
        onDispose { lifeRun.removeObserver(observer) }
    }
    var visible by remember { mutableStateOf(true) }
    var touched by remember { mutableIntStateOf(0) }
    var leap by remember { mutableStateOf<Jump?>(null) }
    var tickBack by remember { mutableIntStateOf(0) }
    var tickPre by remember { mutableIntStateOf(0) }
    /**
     * **One of the three layers**: audio & subtitles, episodes, settings (mirrors `PlayerLayer` on iOS).
     * Full screen above the video; the controls below give way.
     */
    var openLayer by remember { mutableStateOf<String?>(null) }
    /** The last opened layer; stays on close so the title still sits above the episodes while they fade out. */
    var lastOpened by remember { mutableStateOf<String?>(null) }
    val settingsConfig = LocalConfiguration.current
    val portrait = settingsConfig.orientation == Configuration.ORIENTATION_PORTRAIT
    // iOS `narrow`: window under 500 wide, i.e. portrait on a phone.
    val narrow = settingsConfig.screenWidthDp < 500
    val margin = playerEdge(portrait)

    DisposableEffect(mediaWork) {
        mediaWork.installEventListener()
        onDispose { mediaWork.cleanUp() }
    }

    DisposableEffect(mediaWork.session) {
        mediaWork.installSession()
        onDispose { mediaWork.sessionCleanUp() }
    }
    // Title, series, episode, length and the still image; the image follows, the rest is there at once.
    LaunchedEffect(mediaWork.plan, mediaWork.duration > 0) { mediaWork.metaDataUpdate() }

    // Tech overlay: the fixed lines once per title, the counted ones every two seconds: fast enough to
    // watch a stutter, slow enough to read the numbers. Runs only while visible: a forgotten counter
    // would itself be the load it measures.
    LaunchedEffect(app.settings.techBadge, mediaWork.plan) { mediaWork.techBadgeTick(app.settings.techBadge) }

    // Preload the series and the current season as soon as the player shows an episode, so the episode
    // layer is ready on first open (mirrors `EpisodesLayer.preload` on iOS).
    LaunchedEffect(mediaWork.plan?.itemId) {
        val p = mediaWork.plan
        if (p != null && p.episode && p.seriesIdentifier != null) episodesPreload(app, p.seriesIdentifier, p.seasonIdentifier)
    }

    val unfoldLayer: (String) -> Unit = { which -> touched++; lastOpened = which; openLayer = which }
    val layerClose: () -> Unit = { openLayer = null; visible = true; touched++ }

    BackHandler(enabled = openLayer != null) { layerClose() }
    BackHandler(enabled = openLayer == null) { mediaWork.finish(close) }

    // Open, then the tick.
    LaunchedEffect(wish) { mediaWork.openAndTick(wish, close) }
    // **Display rate to the film, at most 60 Hz** (`PlayerEngine.displayRateKeep`). Once a second: cheap when
    // nothing changed, and it catches a rebuilt surface (small window, episode change).
    LaunchedEffect(wish) {
        while (true) {
            delay(1000)
            if (mediaWork.vlcFree && mediaWork.imageFree) mediaWork.player.displayRateKeep(
                if (android.os.Build.VERSION.SDK_INT >= 30) runCatching { context.display }.getOrNull() else null)
        }
    }

    val sheetOpen = app.sheet.value != null
    // The overlay follows the intended controls (mirrors `onChange(of: controlsVisible)` on iOS): on
    // open it is already "on", and its first hide does not dismiss "skip recap".
    LaunchedEffect(visible) { mediaWork.controlsChanged(visible) }
    // Take nothing away while paused, not while seeking, and not while a layer is open (iOS `!layerOpen`).
    LaunchedEffect(visible, mediaWork.running, mediaWork.atPush, sheetOpen, touched, openLayer) {
        if (visible && mediaWork.running && !mediaWork.atPush && !sheetOpen && openLayer == null) { delay(4000); visible = false }
    }
    LaunchedEffect(mediaWork.hint) { if (mediaWork.hint != null) { delay(5000); mediaWork.hint = null } }
    LaunchedEffect(leap) { if (leap != null) { delay(700); leap = null } }

    /** Mirrors `scrub` on iOS: button and double tap seek the same, both with feedback at the edge. */
    val scrub: (Int) -> Unit = { bearing ->
        val seconds = if (bearing < 0) mediaWork.backS else mediaWork.preS
        // Light, not medium: a ten-second seek is smaller than lifting the slider.
        jerk(Jerk.Lightweight)
        mediaWork.vault(mediaWork.position + bearing * seconds.toDouble())
        if (bearing < 0) tickBack++ else tickPre++
        // **Tapped repeatedly, it counts up**: +10 s, +20 s, +30 s, while the display of the previous seeks
        // in the same direction is still up.
        val untilFrom = leap?.takeIf { it.bearing == bearing }?.seconds ?: 0
        leap = Jump(bearing, untilFrom + seconds, if (bearing < 0) tickBack else tickPre)
        if (visible) touched++
    }

    // **What is visible when**, the same three questions as on iOS: `scrimPresent` (controls intended,
    // picture up, not in the small window), `controlsPresent` (plus no layer open) and the standing title
    // (controls or episode layer). No controls before the first frame; otherwise they lay over the
    // loading screen, and the title bobbed up and down on an episode change.
    val layerOpen = openLayer != null
    mediaWork.smallWindow = smallWindow
    val scrimPresent = visible && mediaWork.imageFree && !smallWindow
    val controlsPresent = scrimPresent && !layerOpen
    val titlePresent = (controlsPresent || openLayer == "folgen") && !smallWindow
    val scrimCoverage by animateFloatAsState(if (scrimPresent) 1f else 0f, fadeCurve(scrimPresent, false), label = "schleier")
    val controlsCoverage by animateFloatAsState(if (controlsPresent) 1f else 0f, fadeCurve(controlsPresent, layerOpen), label = "steuerung")
    val titleCoverage by animateFloatAsState(if (titlePresent) 1f else 0f, fadeCurve(titlePresent, layerOpen), label = "titel")

    // **The overlay at the bottom right** (mirrors `offeringPresent`/`cardPresent`/`buttonPresent` on iOS): skip shows for
    // the first six seconds of the section, afterwards only with the controls; the "next episode" card
    // with controls closed. While they are open it waits (gone, countdown pauses) and the normal button
    // shows there.
    val offeringPresent = mediaWork.offeringArt != "keiner" && mediaWork.offerText.isNotEmpty() && mediaWork.imageFree && openLayer == null
        && !sheetOpen && !smallWindow && !mediaWork.switches && !mediaWork.atPush
        && (mediaWork.overlay != "nichts" || (controlsPresent && mediaWork.offeringArt == "naechste"))
    val cardPresent = mediaWork.cardsSwitch != null || (offeringPresent && mediaWork.overlay == "karte")
    val buttonPresent = offeringPresent && mediaWork.overlay != "karte" && mediaWork.cardsSwitch == null
    val cardScrim by animateFloatAsState(if (cardPresent && mediaWork.cardsSwitch == null) 1f else 0f,
        fadeCurve(cardPresent, false), label = "kartenschleier")
    LaunchedEffect(cardPresent) {
        if (mediaWork.cardsSwitch == null) AppLog.writeOut(if (cardPresent) "[Karte] erscheint bei ${mediaWork.position.toInt()} s von ${mediaWork.duration.toInt()} s"
                                                         else "[Karte] geht (abgesagt oder Steuerung)")
    }

    val plan = mediaWork.plan
    val hasEpisodes = plan?.episode == true && plan.seriesIdentifier != null
    val title = plan?.headerLine?.takeIf { it.isNotEmpty() } ?: plan?.title.orEmpty()
    val meta = plan?.let {
        if (it.episode && it.seasonNr != null && it.episodeNr != null) translated("Staffel %lld · Folge %lld", it.seasonNr, it.episodeNr)
        else if (it.episode) it.subtitle.takeIf { u -> u.isNotEmpty() }
        else it.secondaryLine?.takeIf { n -> n.isNotEmpty() }
    }
    // iOS `unten = -10`: the bar's hit area reaches slightly into the safe area, so the visible bar
    // sits just above the gesture bar.
    val footBottom = (margin.bottom + PlayerMetric.bottom).coerceAtLeast(0.dp)

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(factory = { ctx -> VLCVideoLayout(ctx).also { area[0] = it; mediaWork.videoArea = it; mediaWork.player.attach(it) } },
                    modifier = Modifier.fillMaxSize())

        // **Tap areas**, above the picture, below the controls. Mirrors `tapAreas` + `tippen(bearing:)`:
        // **the first tap toggles at once, nothing is reverted.** A second one on the same side within
        // 260 ms seeks and leaves the controls as the first one set them.
        Box(Modifier.fillMaxSize()
            .pointerInput(Unit) {
                var lastOne = 0L
                var lastPage = 0
                // A tap is over within a third of a second; if the finger moves more than 14 dp it is a swipe.
                val pressDuration = 300L
                val distanceLimit = 14f * density
                fun wasTapped(spot: Offset) {
                    val page = if (spot.x < size.width / 2) -1 else 1
                    val now = SystemClock.elapsedRealtime()
                    if (now - lastOne < 260 && page == lastPage) {
                        lastOne = 0L
                        scrub(page)
                    } else {
                        lastOne = now
                        lastPage = page
                        visible = !visible
                        touched++
                    }
                }
                // **One tap or two.** If the finger keeps moving or a second one arrives, it is not a tap.
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    var output = ""
                    val early = withTimeoutOrNull(pressDuration) {
                        while (true) {
                            val e = awaitPointerEvent()
                            if (e.changes.size >= 2) return@withTimeoutOrNull "zwei"
                            val f = e.changes.firstOrNull { it.id == down.id } ?: return@withTimeoutOrNull "weg"
                            if (!f.pressed) return@withTimeoutOrNull if (f.isConsumed) "weg" else "hoch"
                            if ((f.position - down.position).getDistance() > distanceLimit) return@withTimeoutOrNull "weg"
                        }
                        @Suppress("UNREACHABLE_CODE") ""
                    }
                    output = early ?: "gehalten"
                    when (output) {
                        "hoch" -> wasTapped(down.position)
                        "gehalten" -> {
                            // A long press stays a tap.
                            val up = waitForUpOrCancellation()
                            if (up != null) wasTapped(down.position)
                        }
                    }
                }
            }
            .pointerInput(Unit) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    var mass = 1f
                    var toggled = false
                    do {
                        val event = awaitPointerEvent()
                        if (event.changes.size >= 2) {
                            mass *= event.calculateZoom()
                            if (!toggled && mass > 1.15f) { mediaWork.imageFillingSet(true); toggled = true }
                            if (!toggled && mass < 0.85f) { mediaWork.imageFillingSet(false); toggled = true }
                        }
                    } while (event.changes.any { it.pressed })
                }
            }) {
            // Where the pause button sits, a tap pauses even when it is hidden. Lies under the controls: when
            // visible, the real button catches the tap.
            if (mediaWork.imageFree && !smallWindow) Box(Modifier.align(Alignment.Center).size(108.dp, 132.dp).onTap { mediaWork.toggle() })
        }

        // **Start veil**: black until VLC has the first frame; closing works earlier, at the position of the
        // controls' X (mirrors `startScrim`). Fades with 0.3 s easeOut, like `firstImagePresent` on iOS.
        // If the card zooms into the picture it covers the change, so no loading screen on top.
        AnimatedVisibility(!mediaWork.imageFree && mediaWork.cardsSwitch == null, enter = EnterTransition.None, exit = fadeOut(tween(300, easing = EaseOut))) {
            Box(Modifier.fillMaxSize().background(Color.Black)) {
                val h = mediaWork.hint
                if (h == null) Loader(Modifier.align(Alignment.Center))
                else Text(h, style = Theme.body.copy(textAlign = TextAlign.Center), color = Theme.fontQuiet,
                          modifier = Modifier.align(Alignment.Center).padding(horizontal = 48.dp))
                Row(Modifier.fillMaxWidth().padding(start = margin.page, end = margin.page, top = margin.top)
                        .padding(horizontal = PlayerMetric.page).padding(top = PlayerMetric.top),
                    horizontalArrangement = Arrangement.End) {
                    IconButton(Glyph.Cross, translated("Player schließen")) { mediaWork.finish(close) }
                }
            }
        }

        // **Connection lost** (mirrors `connectionHint` on iOS): not an error but an intermediate state,
        // so quiet and without a button. It disappears by itself when the stream runs again.
        AnimatedVisibility(mediaWork.restoring && mediaWork.imageFree && !smallWindow, Modifier.align(Alignment.Center),
                           enter = fadeIn(tween(200)), exit = fadeOut(tween(200))) {
            Column(Modifier.clip(RoundedCornerShape(Theme.corner)).background(Color.Black.copy(alpha = 0.7f))
                    .padding(horizontal = 22.dp, vertical = 18.dp).clearAndSetSemantics {},
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Loader(size = 26.dp, strength = 2.5.dp)
                Text(translated("Verbindung unterbrochen"), style = Theme.listTitle, color = Theme.font)
                Text(translated("Läuft weiter, sobald das Netz zurück ist."), style = Theme.small, color = Theme.fontQuiet)
            }
        }

        // `Playerschleier`: flat, pure black at 42 % (`Theme.reason` lifted HDR video on iOS). **While the next
        // episode's card is up it dims the picture** as with open controls, and the card lies in front.
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = maxOf(scrimCoverage, cardScrim).coerceIn(0f, 1f) }.background(Color.Black.copy(alpha = 0.42f)))

        // **The next episode's card** (variant C): in the tree as long as a next episode exists, so entering
        // and leaving springs start from the current state. Fully inside the safe area, narrower on narrow
        // devices (`EpisodeCard.width`); tap starts, the X or a swipe cancels.
        if (!mediaWork.inGroup && !smallWindow && (mediaWork.plan?.nextEpisode != null || mediaWork.cardsSwitch != null)) {
            val m = mediaWork.cardsMetrics
            val large = settingsConfig.smallestScreenWidthDp >= 600
            val edgePage = margin.page
            val edgeBottom = margin.bottom
            EpisodeCard(mediaWork, cardPresent, card = { w, h, d ->
                val safeWidth = w / d - edgePage.value * 2
                val width = Kern.episodeCardWidth(safeWidth.toDouble(), large, false).toFloat()
                val height = width * 9f / 16f
                val bottom = edgeBottom.value + m.bottomSpacing
                val x = w / d - edgePage.value - PlayerMetric.page.value - width
                val y = h / d - bottom - m.rows - height
                androidx.compose.ui.geometry.Rect(x * d, y * d, (x + width) * d, (y + height) * d)
            }) { jerk(Jerk.Lightweight); mediaWork.offeringClose() }
        }

        // **The tech overlay.** Information, not a control. **Directly on the movie**: above the veil so it
        // stays readable, but below title, buttons and bar, and so also below the layers. **It slides with the
        // controls**: open, it sits under the title row; closed, it moves to the top edge where that row was.
        // Motion instead of fade, same curve as the controls; with reduced motion it jumps.
        if (app.settings.techBadge && !smallWindow && mediaWork.techFixed.isNotEmpty()) {
            val reduced = motionReduced()
            val up by animateFloatAsState(if (controlsPresent) 0f else 1f,
                if (reduced) snap() else fadeCurve(controlsPresent, layerOpen), label = "technikschild")
            val distance = with(LocalDensity.current) { (PlayerMetric.button + Theme.tileSpacing).toPx() }
            Box(Modifier.fillMaxSize()
                    .padding(start = margin.page + PlayerMetric.page, top = margin.top + PlayerMetric.top + PlayerMetric.button + Theme.tileSpacing)
                    .offset { IntOffset(0, -(up * distance).roundToInt()) }) {
                TechBadge(mediaWork.techFixed, mediaWork.techLive, { mediaWork.position }, mediaWork.duration,
                              app.settings.techBadgeMeasure, far = false, hint = mediaWork.firstFrameHint)
            }
        }

        // **The controls stay and only fade their opacity** (mirrors `.opacity(controlsPresent ? 1 : 0)` instead
        // of `if`). Before, they were inserted and removed on every tap, and the title above jumped while the
        // rest was still fading. Hidden, they accept no tap.
        val active = controlsPresent
        val iconsPresent = active && !mediaWork.atPush
        // **Hidden, the bar does not follow the time.** The tick moves `position` every 250 ms; the bar read
        // it even at opacity 0 and the window drew four frames a second over the film. On phones that is
        // what kept the display at its top rate. It reads again as soon as the controls start to appear.
        val barAwake by remember { derivedStateOf { controlsCoverage > 0f || mediaWork.atPush } }
        val barTime = remember { DoubleArray(1) }
        val barPosition: () -> Double = if (barAwake) ({ mediaWork.position.also { barTime[0] = it } }) else ({ barTime[0] })
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = controlsCoverage.coerceIn(0f, 1f) }) {
            // **Center of the screen, not of the safe area**: in landscape there is more room below than above.
            // While seeking only the bar counts; the center gives way.
            CenterControls(mediaWork.running, mediaWork.backS, mediaWork.preS, tickBack, tickPre, narrow, iconsPresent,
                Modifier.align(Alignment.Center).graphicsLayer { alpha = if (mediaWork.atPush) 0f else 1f },
                back = { scrub(-1) }, toggle = { mediaWork.toggle() }, forward = { scrub(1) })

            Column(Modifier.fillMaxSize().padding(start = margin.page, end = margin.page, top = margin.top, bottom = footBottom)) {
                // **Header:** title placeholder (`stateTitle` is shown above it), quietly the meta line below;
                // only icons on the right, which give way while seeking. The title stays.
                Row(Modifier.fillMaxWidth().padding(horizontal = PlayerMetric.page).padding(top = PlayerMetric.top),
                    verticalAlignment = Alignment.Top) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(title, style = titleStyle, maxLines = 1, modifier = Modifier.alpha(0f).clearAndSetSemantics {})
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                            // **In a group the group shows here**, where otherwise season and episode or year and runtime
                            // stand. That is state, so accent color.
                            val group = if (mediaWork.inGroup) app.gemeinsam.value.group else null
                            if (group != null) Box(Modifier.weight(1f, fill = false)) {
                                GroupsRow(group.name, app.gemeinsam.value.withWhom, metaStyle.fontSize)
                            }
                            else meta?.let { Text(it, style = metaStyle, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                              modifier = Modifier.weight(1f, fill = false)) }
                            if (plan != null && !plan.lossless) Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                                Symbol(Glyph.Warning, 12.dp, color = Theme.warning)
                                Text(plan.method, style = metaStyle, color = Theme.warning, maxLines = 1)
                            }
                        }
                    }
                    Spacer(Modifier.width(12.dp))
                    IconRail(hasEpisodes, iconsPresent, Modifier.graphicsLayer { alpha = if (mediaWork.atPush) 0f else 1f },
                                unfoldLayer) { mediaWork.finish(close) }
                }
                mediaWork.hint?.let {
                    Text(it, style = Theme.small.copy(textAlign = TextAlign.Center), color = Theme.fontQuiet,
                         modifier = Modifier.fillMaxWidth().padding(horizontal = PlayerMetric.page).padding(top = 10.dp))
                }
                Spacer(Modifier.weight(1f))
                // **The bar across the full width**, time on the left, remaining time on the right (mirrors `footer`).
                Box(Modifier.fillMaxWidth().height(PlayerMetric.bar).padding(horizontal = PlayerMetric.page)) {
                    TimeRow(app, barPosition, mediaWork.duration, mediaWork.atPush, active, mediaWork.plan?.marks.orEmpty(), mediaWork.chapterCount, { mediaWork.trickplayImage(it) },
                              { mediaWork.atPush = it; touched++ }) { mediaWork.vault(it) }
                }
            }
        }

        // **The offer button**: "Skip intro" / "Next episode" (mirrors `offeringPresent` in
        // `Sources/iOS/PlayerScreen.swift`). **In one place, whether the controls are open or not**: at the
        // right just above the bar, with the same dimensions as the footer. Gone while seeking or with a
        // layer open. Cancel with Back (iOS: two-finger swipe); no X of its own, as on iOS.
        // Back cancels the overlay: the card or the skip button without controls.
        BackHandler(enabled = mediaWork.overlay != "nichts" && offeringPresent && !controlsPresent && mediaWork.cardsSwitch == null) { mediaWork.offeringClose() }
        Box(Modifier.fillMaxSize().padding(start = margin.page, end = margin.page, bottom = footBottom + PlayerMetric.bar + PlayerMetric.overBar)
                .padding(horizontal = PlayerMetric.page),
            contentAlignment = Alignment.BottomEnd) {
            // The button, but not while the card is there. Fades in and out softly.
            AnimatedVisibility(visible = buttonPresent, enter = fadeIn(fadeUp), exit = fadeOut(fadeTo)) {
                OfferingPill(mediaWork.offeringArt, mediaWork.offerText, null, null, mediaWork) {
                    mediaWork.offeringRun()
                }
            }
        }

        // Feedback while seeking: the same rotation as on the buttons (mirrors `jumpBackMessage`).
        val rememberedJump = remember { arrayOfNulls<Jump>(1) }
        leap?.let { rememberedJump[0] = it }
        AnimatedVisibility(leap != null, enter = fadeIn(tween(150, easing = EaseInOut)), exit = fadeOut(tween(150, easing = EaseInOut))) {
            rememberedJump[0]?.let { s ->
                Box(Modifier.fillMaxSize().padding(horizontal = margin.page).padding(horizontal = 44.dp),
                    contentAlignment = if (s.bearing < 0) Alignment.CenterStart else Alignment.CenterEnd) {
                    key(s.bearing, s.tick) { JumpMark(s.bearing, s.seconds) }
                }
            }
        }

        // **What happens in the group, briefly at the top**, so nobody wonders why the movie stands still.
        // Below the X row, above everything except the layers; accepts no tap.
        val event = if (mediaWork.inGroup && !smallWindow) app.gemeinsam.value.event else null
        val rememberedEvent = remember { arrayOfNulls<SharedEvent>(1) }
        event?.let { rememberedEvent[0] = it }
        AnimatedVisibility(event != null, Modifier.align(Alignment.TopCenter).zIndex(4f)
                .padding(top = margin.top + PlayerMetric.top + PlayerMetric.button + 8.dp),
            enter = fadeIn(fadeUp), exit = fadeOut(fadeTo)) {
            rememberedEvent[0]?.let { e -> key(e.id) { GroupsEvent(e) } }
        }
        // A group message (`SyncPlayError`) in the player, where its own messages show.
        val sharedError = app.sharedError.value
        LaunchedEffect(sharedError) { sharedError?.let { mediaWork.hint = it; app.sharedError.value = null } }

        // During the episode change the old episode keeps playing; the spinner says something is coming.
        if (mediaWork.imageFree && mediaWork.switches && mediaWork.cardsSwitch == null) Loader(Modifier.align(Alignment.Center))

        // **The three layers**: full screen above the video, fade 0.2 s easeOut; the controls below give way
        // in the same beat (`fadeCurve`).
        AnimatedContent(targetState = if (smallWindow) null else openLayer, modifier = Modifier.fillMaxSize().zIndex(5f),
            transitionSpec = { fadeIn(layersCurve) togetherWith fadeOut(layersCurve) }, label = "ebene") { layer ->
            when (layer) {
                "spuren" -> TracksLayer(mediaWork, margin, portrait, layerClose)
                "einstellungen" -> SettingsLayer(app, mediaWork, margin, portrait, layerClose) { mediaWork.finish(close) }
                "folgen" -> {
                    val p = mediaWork.plan
                    if (p != null && p.seriesIdentifier != null) EpisodesLayer(app, p.seriesIdentifier, p.itemId, p.seasonIdentifier, title, margin,
                        close = layerClose,
                        start = { id -> layerClose(); if (id != p.itemId) run.launch { mediaWork.episodeSelect(id) } })
                }
                else -> Box(Modifier.fillMaxSize())
            }
        }

        // **The standing title** (mirrors `stateTitle`). With the episode layer it lies above and stays,
        // also during its fade-out (`lastOpened`). With the other layers it lies below and disappears
        // with the meta line. One line, truncated with "…".
        Row(Modifier.fillMaxWidth().zIndex(if (lastOpened == "folgen") 6f else 3f)
                .padding(start = margin.page, end = margin.page, top = margin.top)
                .padding(horizontal = PlayerMetric.page).padding(top = PlayerMetric.top)
                .graphicsLayer { alpha = titleCoverage.coerceIn(0f, 1f) }) {
            Text(title, style = titleStyle, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis,
                 modifier = Modifier.weight(1f))
            // Room for the icon row so the title gets the same width as in the header.
            Spacer(Modifier.width(12.dp + iconRailsWidth(hasEpisodes)))
        }
    }
}

// MARK: Dimensions and curves: mirrors `Playermass` in `Sources/iOS/PlayerLayers.swift` (iPhone values).

/** All player dimensions in one place, shared with the layers so their X sits exactly on the player's X. */
private object PlayerMetric {
    /** Left and right margin, inside the safe area (`Theme.rand(wide: false)`). */
    val page = Theme.edgeSpacing
    val top = 16.dp
    /** Above the bottom safe area; negative: the hit area reaches into it. */
    val bottom = (-10).dp
    /** Hit area of the icon buttons. */
    val button = 44.dp
    /** Distance of the skip pill above the bar. */
    val overBar = 20.dp
    /** Height of the time row, i.e. the slider's hit area. */
    val bar = 44.dp
}

/**
 * **The player uses the same type scale as the rest.** It had a second one (19 bold / 14 / 13), which
 * was removed on Apple and not yet here. Title 20, detail 12, time 13. **Bold only on the page
 * title**; the player title is a bar row, not a page title.
 */
private val titleStyle = Theme.rail
private val metaStyle = Theme.small

/**
 * **The player's safe area**: what remains after `.ignoresSafeArea(edges: mass.topSkip)` on iOS.
 * Horizontally the cutout, **equal on both sides** (in landscape the iPhone's safe area is symmetric;
 * indenting only one side left the header crooked). At the top only in portrait, at the bottom the
 * gesture bar.
 *
 * Always the values **without visibility**: the system bars are hidden in the player and come in
 * briefly on swipe. With the visible values, header and bar jumped each time.
 */
private data class Rand(val page: Dp, val top: Dp, val bottom: Dp)

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun playerEdge(portrait: Boolean): Rand {
    val density = LocalDensity.current
    val bearing = LocalLayoutDirection.current
    val cutout = WindowInsets.displayCutout
    val page = maxOf(cutout.getLeft(density, bearing), cutout.getRight(density, bearing))
    val top = if (portrait) maxOf(cutout.getTop(density), WindowInsets.statusBarsIgnoringVisibility.getTop(density)) else 0
    val bottom = WindowInsets.navigationBarsIgnoringVisibility.getBottom(density)
    return with(density) { Rand(page.toDp(), top.toDp(), bottom.toDp()) }
}

/** `.snappy(duration: 0.18, extraBounce: 0)`: one spring (response 0.18 s, bounce 0.15); a second tap need not wait. */
private val fadeUp: FiniteAnimationSpec<Float> = spring(dampingRatio = 0.85f, stiffness = 1218f, visibilityThreshold = 0.001f)
/** `.smooth(duration: 0.34)`: unhurried, no overshoot. */
private val fadeTo: FiniteAnimationSpec<Float> = spring(dampingRatio = 1f, stiffness = 341f, visibilityThreshold = 0.001f)
/** `PlayerScreen.layersCurve`, `.easeOut(duration: 0.2)`: the layers and, while one opens, the controls. */
private val layersCurve: FiniteAnimationSpec<Float> = tween(200, easing = EaseOut)

/** `PlayerScreen.kurve(present:layer:)`: fast in, unhurried out; if a layer takes the place, in the layer's beat. */
private fun fadeCurve(present: Boolean, layer: Boolean) = if (present) fadeUp else if (layer) layersCurve else fadeTo

/** A seek to display: direction, seconds and a counter so two seeks in a row animate again. */
private data class Jump(val bearing: Int, val seconds: Int, val tick: Int)

// MARK: Building blocks

/**
 * **Pressing like an iOS button**: no ripple, no shadow; the icon dims on touch and fades back on
 * release. Hidden (`active == false`) the button accepts no tap; it goes to the tap areas below
 * (iOS `allowsHitTesting`).
 */
private fun Modifier.iconPress(active: Boolean, description: String, perform: () -> Unit): Modifier = composed {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val coverage by animateFloatAsState(if (pressed) 0.35f else 1f,
        if (pressed) snap() else tween(200, easing = EaseOut), label = "druck")
    val click = if (active) Modifier.clickable(interactionSource = source, indication = null, role = Role.Button, onClick = perform)
                    .semantics { contentDescription = description }
                else Modifier
    this.then(click).graphicsLayer { alpha = coverage }
}

/**
 * `.symbolEffect(.bounce, options: .speed(1.7))`: plays once and returns to rest by itself. Briefly
 * larger, then springs back.
 */
private fun Modifier.hop(tick: Int): Modifier = composed {
    val scale = remember { Animatable(1f) }
    LaunchedEffect(tick) {
        if (tick == 0) return@LaunchedEffect
        scale.animateTo(1.16f, tween(80, easing = EaseOut))
        scale.animateTo(1f, spring(dampingRatio = 0.5f, stiffness = 700f))
    }
    graphicsLayer { scaleX = scale.value; scaleY = scale.value }
}

/** One of the icon buttons at the top right, in the player and on the layers (`IconButton`): 44 hit area, white. */
@Composable
private fun IconButton(symbol: Glyph, description: String, active: Boolean = true, perform: () -> Unit) {
    Box(Modifier.size(PlayerMetric.button).iconPress(active, description, perform), contentAlignment = Alignment.Center) {
        // `mass.symbol`: 19 medium, white.
        Symbol(symbol, 19.dp, color = Color.White, strength = Strength.Medium)
    }
}

/** The buttons at the top right, spacing 2 like `iconRail` on the iPhone. */
@Composable
private fun IconRail(hasEpisodes: Boolean, active: Boolean, modifier: Modifier, open: (String) -> Unit, close: () -> Unit) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        IconButton(Glyph.Subtitle, translated("Audio & Untertitel"), active) { open("spuren") }
        if (hasEpisodes) IconButton(Glyph.Pile, translated("Folgen"), active) { open("folgen") }
        IconButton(Glyph.SliderControl, translated("Einstellungen"), active) { open("einstellungen") }
        IconButton(Glyph.Cross, translated("Player schließen"), active) { close() }
    }
}

private fun iconRailsWidth(hasEpisodes: Boolean): Dp {
    val count = if (hasEpisodes) 4 else 3
    return PlayerMetric.button * count + 2.dp * (count - 1)
}

/**
 * Centered in the picture, mirrors `centerControls`: edge 46 (narrow 40) for the seek buttons, 78 (60)
 * for pause, spacing 52 (34). Forward and backward use the same icon, mirrored, with the span inside.
 */
@Composable
private fun CenterControls(running: Boolean, backS: Int, preS: Int, tickBack: Int, tickPre: Int, narrow: Boolean,
                            active: Boolean, modifier: Modifier, back: () -> Unit, toggle: () -> Unit, forward: () -> Unit) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(if (narrow) 34.dp else 52.dp),
        verticalAlignment = Alignment.CenterVertically) {
        SeekButton(true, backS, tickBack, narrow, active, translated("%lld Sekunden zurück", backS), back)
        PauseButton(running, narrow, active, toggle)
        SeekButton(false, preS, tickPre, narrow, active, translated("%lld Sekunden vor", preS), forward)
    }
}

@Composable
private fun SeekButton(back: Boolean, seconds: Int, tick: Int, narrow: Boolean, active: Boolean, description: String, perform: () -> Unit) {
    // `gobackward.10` at 30 pt (narrow 24), medium. Material has the arrow circle with a number only for
    // 5, 10 and 30 seconds, so every span uses the same empty circle with its own digit, so 15 does not
    // look different from 10.
    val glyph = if (narrow) 24.dp else 30.dp
    val digit = with(LocalDensity.current) { (glyph * 0.37f).toSp() }
    Box(Modifier.size(if (narrow) 40.dp else 46.dp).iconPress(active, description, perform), contentAlignment = Alignment.Center) {
        Box(Modifier.hop(tick), contentAlignment = Alignment.Center) {
            Symbol(if (back) Glyph.Rewind else Glyph.FastForward, glyph, color = Color.White, strength = Strength.Medium)
            // The circle sits 4 % below the icon's center (arrow head on top).
            Text("$seconds", style = TextStyle(fontSize = digit, fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum",
                                                letterSpacing = (-0.2).sp),
                 color = Color.White, maxLines = 1, modifier = Modifier.offset(y = glyph * 0.04f))
        }
    }
}

/** `pause.fill` / `play.fill` at 48 pt (narrow 36): swap without sliding (`.replace.offUp`); must switch at once. */
@Composable
private fun PauseButton(running: Boolean, narrow: Boolean, active: Boolean, perform: () -> Unit) {
    val scale = if (narrow) 0.75f else 1f
    Box(Modifier.size(if (narrow) 60.dp else 78.dp).iconPress(active, translated(if (running) "Anhalten" else "Abspielen"), perform),
        contentAlignment = Alignment.Center) {
        AnimatedContent(running, contentAlignment = Alignment.Center, label = "pause",
            transitionSpec = {
                (fadeIn(tween(90)) + scaleIn(spring(dampingRatio = 0.8f, stiffness = 900f), initialScale = 0.5f)) togetherWith
                    (fadeOut(tween(60)) + scaleOut(tween(60), targetScale = 0.5f)) using SizeTransform(clip = false)
            }) { an ->
            // `pause.fill` / `play.fill`, 48 (narrow 36) medium.
            Symbol(if (an) Glyph.Pause else Glyph.Play, 48.dp * scale, color = Color.White, strength = Strength.Medium)
        }
    }
}

/** Feedback while seeking (mirrors `Sprungmarke`): 108 round, black 45 %, icon 32, "10 s" below. */
@Composable
private fun JumpMark(bearing: Int, seconds: Int) {
    var rotated by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { rotated = 1 }
    Column(Modifier.size(108.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.45f)),
        verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally) {
        Symbol(if (bearing > 0) Glyph.FastForward else Glyph.Rewind, 32.dp, Modifier.hop(rotated),
               color = Color.White, strength = Strength.Medium)
        // With sign because it counts up: +10 s, +20 s, +30 s.
        Text((if (bearing < 0) "−" else "+") + translated("%lld s", seconds), style = Theme.tile.copy(fontFeatureSettings = "tnum"), color = Color.White)
    }
}

/** Mirrors `Loader`: an arc in accent color, 0.7 s per turn, linear. */
@Composable
private fun Loader(modifier: Modifier = Modifier, size: Dp = 34.dp, strength: Dp = 3.dp) {
    val rotation by rememberInfiniteTransition(label = "lader")
        .animateFloat(0f, 360f, infiniteRepeatable(tween(700, easing = LinearEasing)), label = "drehung")
    Canvas(modifier.size(size).graphicsLayer { rotationZ = rotation }) {
        val s = strength.toPx()
        drawArc(Theme.accent, 0f, 0.22f * 360f, useCenter = false, topLeft = Offset(s / 2, s / 2),
                size = Size(this.size.width - s, this.size.height - s), style = Stroke(s, cap = StrokeCap.Round))
    }
}

/** Dimensions of the chapter bar (iOS `Zeitregler`): gap as wide as a notch; no piece gets narrower. */
internal object ChapterMass { const val gap = 2.0; const val minWidth = 8.0 }

/** One piece of the bar: share from/to and its frame in dp, computed in the core (`ChapterBar`). */
internal class ChapterPiece(val from: Double, val until: Double, val x: Float, val width: Float)

internal class ChapterBarsShape(val pieces: List<ChapterPiece>, val snap: List<Double>)

internal fun chapterBarRead(json: String): ChapterBarsShape = JSONObject(json).let { o ->
    val s = o.getJSONArray("stuecke"); val f = o.getJSONArray("fang")
    ChapterBarsShape(
        List(s.length()) { i -> s.getJSONArray(i).let { ChapterPiece(it.getDouble(0), it.getDouble(1), it.getDouble(2).toFloat(), it.getDouble(3).toFloat()) } },
        List(f.length()) { f.getDouble(it) })
}

/**
 * Mirrors `TimeRow` + `Zeitregler` on iOS. Time left, remaining time right, 13 with tabular digits,
 * quiet. **At rest only the line** (4 thick), **while seeking 6 and a handle in accent color**, the
 * only accent spot in the player; the played part stays white. Above it, only while seeking, the
 * trickplay preview with time, just above the hit area and above the handle.
 */
@Composable
private fun TimeRow(app: SwiftlyApplication, position: () -> Double, duration: Double, atPush: Boolean, active: Boolean, marks: List<Double>,
                      chapterCount: Int,
                      preview: (Double) -> android.graphics.Bitmap?,
                      shove: (Boolean) -> Unit, jump: (Double) -> Unit) {
    var target by remember { mutableStateOf<Double?>(null) }
    // `position` is a lambda: it is read only here, otherwise every tick would recompose the whole player page.
    val shown = target ?: position()
    val digits = Theme.tile.copy(fontWeight = FontWeight.Normal, fontFeatureSettings = "tnum")
    val handleScale by animateFloatAsState(if (atPush) 1f else 0.4f, Motion.toggle(), label = "griffSkala")
    val handleCoverage by animateFloatAsState(if (atPush) 1f else 0f, Motion.toggle(), label = "griffDeckung")
    val length by rememberUpdatedState(duration)
    val pushNow by rememberUpdatedState(shove)
    val jumpNow by rememberUpdatedState(jump)
    val marksNow by rememberUpdatedState(marks.toDoubleArray())
    val jerk = rememberJerk()
    // **Remaining time or end: a tap toggles**: "-12:34" or "Ends at 22:41"; the choice persists.
    var asEnd by remember { mutableStateOf(app.store.rememberValue("restzeitAlsEnde") == "1") }
    Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Text(timeText(shown), style = digits, color = Theme.fontQuiet)
        BoxWithConstraints(Modifier.weight(1f).fillMaxHeight()
            // **Acts at once, no threshold**, like `DragGesture(minimumDistance: 0)`: touching down already
            // thickens the bar, shows the handle and sets the position. Release seeks.
            .then(if (active) Modifier.pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    down.consume()
                    // **It snaps to the notches** (`NotchesSnap`): close enough to a section boundary it sits exactly on it,
                    // with a light tick on snapping, once, not on every movement there.
                    var inSnapped = -1.0
                    // **Plus the cuts between chapters**, only the visible ones with room beside them
                    // (`ChapterBar.snapCuts`, from the core); once per grab, the width does not change meanwhile.
                    val snapMarks = marksNow + chapterBarRead(
                        app.kern.chapterBar(length, (size.width / density).toDouble(), ChapterMass.minWidth, ChapterMass.gap)).snap
                    fun spot(x: Float): Double {
                        val raw = (x / size.width).coerceIn(0f, 1f).toDouble() * length
                        val notch = Kern.notch(raw, length, snapMarks, (size.width / density).toDouble())
                        if (notch < 0) { inSnapped = -1.0; return raw }
                        if (notch != inSnapped) { inSnapped = notch; jerk(Jerk.Lightweight) }
                        return notch
                    }
                    target = spot(down.position.x)
                    pushNow(true)
                    // Even on cancel (bar hidden, second finger) do not stay stuck in seeking.
                    var letGo = false
                    try {
                        while (true) {
                            val event = awaitPointerEvent()
                            val finger = event.changes.firstOrNull { it.id == down.id } ?: break
                            if (!finger.pressed) break
                            target = spot(finger.position.x)
                            finger.consume()
                        }
                        letGo = true
                    } finally {
                        if (letGo) target?.let { jumpNow(it) }
                        target = null
                        pushNow(false)
                    }
                }
            } else Modifier)
            // TalkBack reads the position and can adjust it, like `accessibilityAdjustableAction`.
            .semantics {
                // With chapter: "12:00 / 45:00, chapter name", the server's name, untranslated.
                stateDescription = timeText(shown) + " / " + timeText(duration) +
                    (if (chapterCount > 0) app.kern.chapterName(shown).let { if (it.isEmpty()) "" else ", $it" } else "")
                if (duration > 0) progressBarRangeInfo = ProgressBarRangeInfo(shown.toFloat().coerceIn(0f, duration.toFloat()), 0f..duration.toFloat())
                setProgress { value -> jump(value.toDouble()); true }
            },
            contentAlignment = Alignment.CenterStart) {
            val share = if (duration > 0) (shown / duration).toFloat().coerceIn(0f, 1f) else 0f
            val width = maxWidth
            // **One piece per chapter** (mirrors `ChapterMask`): the core says gap, cuts and which are too narrow;
            // without chapters it is one piece across the full width. While seeking only the piece under the
            // finger rises to 6, the others stay at 4.
            val bar = remember(chapterCount, duration, width) {
                chapterBarRead(app.kern.chapterBar(duration, width.value.toDouble(), ChapterMass.minWidth, ChapterMass.gap))
            }
            val elevated = if (atPush) app.kern.chapterPiece(share.toDouble(), duration, width.value.toDouble(), ChapterMass.minWidth).toInt() else -1
            // **Notches at the section boundaries**, 2 wide in `reason`: where the intro starts does not say where
            // it ends, and that is what you want to see before grabbing.
            val notches = if (duration > 0) marks.map { (it / duration).toFloat() }.filter { it > 0.01f && it < 0.99f } else emptyList()
            bar.pieces.forEachIndexed { i, piece ->
                key(i) {
                    val height by animateDpAsState(if (i == elevated) 6.dp else 4.dp, Motion.toggle(), label = "stueck")
                    // Track white 18 %, the played part white.
                    Box(Modifier.offset(x = piece.x.dp).width(piece.width.dp).height(height)
                        .clip(CircleShape).background(Color.White.copy(alpha = 0.18f))) {
                        Box(Modifier.width((width * share - piece.x.dp).coerceIn(0.dp, piece.width.dp))
                            .fillMaxHeight().background(Color.White))
                        notches.forEach { spot ->
                            Box(Modifier.offset(x = width * spot - 1.dp - piece.x.dp).width(2.dp).fillMaxHeight().background(Theme.reason))
                        }
                    }
                }
            }
            Box(Modifier.offset(x = width * share - 9.dp).size(18.dp)
                .graphicsLayer { scaleX = handleScale; scaleY = handleScale; alpha = handleCoverage }
                .clip(CircleShape).background(Theme.accent))
            if (atPush) {
                val image = preview(shown)
                // Bottom edge 2 above the hit area, horizontally above the handle; at the edge the box stays
                // entirely on the bar.
                Column(Modifier.align(Alignment.TopStart).layout { measurable, _ ->
                        val p = measurable.measure(Constraints())
                        layout(0, 0) {
                            val total = width.roundToPx()
                            val half = p.width / 2
                            val x = (total * share).roundToInt().coerceIn(half, maxOf(total - half, half)) - half
                            p.place(x, -p.height - 2.dp.roundToPx())
                        }
                    },
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    image?.let {
                        Image(it.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Crop,
                            modifier = Modifier.size(160.dp, 90.dp).clip(RoundedCornerShape(Theme.corner))
                                .border(1.dp, Theme.margin, RoundedCornerShape(Theme.corner)))
                    }
                    // Semibold, not bold; on its own capsule since no veil lies here. **With a chapter its name stands
                    // before the time**, in the same capsule: one line, at most as wide as the preview image; a long
                    // name is truncated, never the time.
                    val name = if (chapterCount > 0) app.kern.chapterName(shown) else ""
                    Row(Modifier.widthIn(max = 160.dp).clip(CircleShape).background(Theme.reason.copy(alpha = 0.82f))
                            .padding(horizontal = 8.dp, vertical = 3.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        if (name.isNotEmpty()) {
                            Text(name, style = digits.copy(fontFeatureSettings = null), color = Theme.font, maxLines = 1,
                                 overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                        }
                        Text(timeText(shown), style = digits.copy(fontWeight = FontWeight.SemiBold), color = Theme.font, maxLines = 1)
                    }
                }
            }
        }
        val rest = (duration - shown).coerceAtLeast(0.0)
        val context = LocalContext.current
        val end = if (asEnd) translated("Endet um %@",
            android.text.format.DateFormat.getTimeFormat(context).format(java.util.Date(System.currentTimeMillis() + (rest * 1000).toLong()))) else null
        Text(end ?: ("−" + timeText(rest)), style = digits, color = Theme.fontQuiet, maxLines = 1,
             // Hidden, the remaining time accepts no tap: it goes to the tap areas below and shows the controls.
             // Before, it toggled invisibly between remaining time and end.
             modifier = (if (active) Modifier.onTap {
                 asEnd = !asEnd
                 app.store.remember("restzeitAlsEnde", if (asEnd) "1" else "0")
             } else Modifier).semantics {
                 contentDescription = end ?: translated("Restzeit")
                 role = Role.Button
                 onClick(label = translated("Wechselt zwischen Restzeit und Ende")) { asEnd = !asEnd; app.store.remember("restzeitAlsEnde", if (asEnd) "1" else "0"); true }
             })
    }
}

// MARK: The three layers: mirrors `PlayerLayers.swift` on iOS.

/**
 * **Base of every layer:** pure black, accepts every tap (does nothing with it) so nothing below seeks.
 *
 * **No blur.** iOS puts `.ultraThinMaterial` under 72 % black. VLC draws into a `SurfaceView`
 * here (`attachViews(…, useTextureView = false)`); the system composes its picture separately and a
 * `RenderEffect` on the view does not reach it, so the blur that was here did nothing. Replacement:
 * a bit more black, so the sharp picture below looks as calm as the soft one on iOS.
 */
@Composable
private fun LayersReason() {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.8f)).pointerInput(Unit) { detectTapGestures { } })
}

/** Header row of a layer: left what the layer shows, right the X, exactly on the player's X. */
@Composable
private fun LayersHeader(close: () -> Unit, left: @Composable () -> Unit = {}) {
    Row(Modifier.fillMaxWidth().padding(horizontal = PlayerMetric.page).padding(top = PlayerMetric.top), verticalAlignment = Alignment.Top) {
        Box(Modifier.weight(1f)) { left() }
        Spacer(Modifier.width(12.dp))
        IconButton(Glyph.Cross, translated("Schließen"), perform = close)
    }
}

/**
 * Columns side by side, **centered**, below the X row (`top + button + 6`). Each column at most 210,
 * spacing 40 (portrait 16); if the width is not enough, all get equally narrower.
 */
@Composable
private fun ColumnsRail(margin: Rand, portrait: Boolean, count: Int, content: @Composable (Dp) -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize().padding(start = margin.page, end = margin.page, top = margin.top, bottom = margin.bottom)
            .padding(horizontal = PlayerMetric.page).padding(top = PlayerMetric.top + PlayerMetric.button + 6.dp)) {
        val spacing = if (portrait) 16.dp else 40.dp
        val width = minOf(210.dp, (maxWidth - spacing * (count - 1)) / count)
        Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(spacing, Alignment.CenterHorizontally)) { content(width) }
    }
}

/** A column with a fixed heading; only the rows below scroll, each column on its own. */
@Composable
private fun SelectionColumn(title: String, width: Dp, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.width(width).fillMaxHeight()) {
        Text(title, style = titleStyle, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.padding(horizontal = 10.dp).padding(bottom = 8.dp).semantics { heading() })
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(bottom = 12.dp),
               verticalArrangement = Arrangement.spacedBy(2.dp), content = content)
    }
}

/** Check mark and name: selected white and semibold, otherwise 62 % white (mirrors `LayersRow`). */
@Composable
private fun LayersRow(text: String, selected: Boolean, perform: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(Theme.cornerField)).pressRow(perform)
            .semantics { this.selected = selected }.padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.width(18.dp), contentAlignment = Alignment.CenterStart) {
            Symbol(Glyph.Checkmark, 14.dp, Modifier.alpha(if (selected) 1f else 0f), color = Theme.font, strength = Strength.Semibold)
        }
        // **Selected means white, no weight change**: the check mark on the left already says it, and in a
        // column with `maxLines(1)` semibold truncated even more than regular.
        Text(text, style = Theme.body,
             color = if (selected) Theme.font else Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/**
 * **Delay: last row of the audio and subtitle columns** (mirrors `Verzoegerungszeile` in
 * `Sources/iOS/PlayerLayers.swift`, rationale there). - and + shift by 50 ms; held they repeat and
 * speed up (`Haltezaehler` in the package). The reset arrow sets zero and keeps its place so
 * - value + does not jump sideways on reset. For TalkBack one element with earlier/later/reset.
 */
@Composable
private fun DelayRow(milliseconds: Int, shove: (Int) -> Unit, reset: () -> Unit) {
    val a = remember(milliseconds) { delayDisplay(milliseconds) }
    val title = translated("Verzögerung")
    Column(Modifier.fillMaxWidth().padding(top = 10.dp).clearAndSetSemantics {
            contentDescription = title
            stateDescription = a.text
            customActions = listOf(
                androidx.compose.ui.semantics.CustomAccessibilityAction(translated("Früher")) { shove(-1); true },
                androidx.compose.ui.semantics.CustomAccessibilityAction(translated("Später")) { shove(1); true },
                androidx.compose.ui.semantics.CustomAccessibilityAction(translated("Zurücksetzen")) { reset(); true })
        }, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(title, style = Theme.small, color = Theme.fontVeryQuiet, modifier = Modifier.padding(horizontal = 10.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            DelayKey(Glyph.Minus, a.atStart) { shove(-1) }
            Text(a.text, style = Theme.body.copy(fontFeatureSettings = "tnum"), textAlign = TextAlign.Center, maxLines = 1,
                 color = if (a.isNull) Theme.fontQuiet else Theme.font, modifier = Modifier.weight(1f))
            DelayKey(Glyph.Plus, a.atEnd) { shove(1) }
            val coverage by animateFloatAsState(if (a.isNull) 0f else 1f, label = "zuruecksetzen")
            Box(Modifier.size(PlayerMetric.button).iconPress(!a.isNull, translated("Zurücksetzen"), reset).alpha(coverage),
                contentAlignment = Alignment.Center) {
                Symbol(Glyph.Ruecksetzen, 16.dp, color = Theme.fontQuiet, strength = Strength.Medium)
            }
        }
    }
}

/**
 * - or + of the delay row: one press immediately, **held it repeats** (like `buttonRepeatBehavior` on
 * iOS), after 400 ms every 100 ms. The interval is below the `railsGap` of the hold counter, so
 * the core counts the series and speeds up. At the limit dimmed and without effect.
 */
@Composable
private fun DelayKey(symbolText: Glyph, locked: Boolean, perform: () -> Unit) {
    val current by rememberUpdatedState(perform)
    val lockedNow by rememberUpdatedState(locked)
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val coverage by animateFloatAsState(if (pressed) 0.35f else 1f,
        if (pressed) snap() else tween(200, easing = EaseOut), label = "druck")
    Box(Modifier.size(PlayerMetric.button).graphicsLayer { alpha = coverage }.pointerInput(Unit) {
            detectTapGestures(onPress = { place ->
                if (lockedNow) return@detectTapGestures
                val press = androidx.compose.foundation.interaction.PressInteraction.Press(place)
                source.emit(press)
                current()
                val hold = kotlinx.coroutines.coroutineScope {
                    val redo = launch {
                        delay(400)
                        while (!lockedNow) { current(); delay(100) }
                    }
                    tryAwaitRelease().also { redo.cancel() }
                }
                source.emit(if (hold) androidx.compose.foundation.interaction.PressInteraction.Release(press)
                            else androidx.compose.foundation.interaction.PressInteraction.Cancel(press))
            })
        }, contentAlignment = Alignment.Center) {
        Symbol(symbolText, 17.dp, color = if (locked) Theme.fontVeryQuiet else Theme.font, strength = Strength.Semibold)
    }
}

/** Audio & subtitles: two columns, each scrolls on its own. */
@Composable
private fun TracksLayer(mediaWork: PlayItem, margin: Rand, portrait: Boolean, close: () -> Unit) {
    var audioSelection by remember { mutableIntStateOf(mediaWork.player.audioTrack) }
    var utSelection by remember { mutableIntStateOf(mediaWork.player.spuTrack) }
    val audio = remember { mediaWork.trackList(audio = true) }
    val ut = remember { mediaWork.trackList(audio = false) }
    Box(Modifier.fillMaxSize()) {
        LayersReason()
        ColumnsRail(margin, portrait, 2) { width ->
            SelectionColumn(translated("Audio"), width) {
                audio.forEach { (id, name) -> LayersRow(name, id == audioSelection) { audioSelection = id; mediaWork.audioFromHand(id) } }
                DelayRow(mediaWork.audioDelay, { mediaWork.delayPush(true, it) }) { mediaWork.delaySet(true, 0) }
            }
            SelectionColumn(translated("Untertitel"), width) {
                LayersRow(translated("Aus"), utSelection == -1) { utSelection = -1; mediaWork.subtitleFromHand(-1) }
                ut.forEach { (id, name) -> LayersRow(name, id == utSelection) { utSelection = id; mediaWork.subtitleFromHand(id) } }
                DelayRow(mediaWork.subtitleDelay, { mediaWork.delayPush(false, it) }) { mediaWork.delaySet(false, 0) }
            }
        }
        Box(Modifier.padding(start = margin.page, end = margin.page, top = margin.top)) { LayersHeader(close) }
    }
}

/** Picture / sleep timer / tech overlay / quality: as on iOS, without speed. */
@Composable
private fun SettingsLayer(app: SwiftlyApplication, mediaWork: PlayItem, margin: Rand, portrait: Boolean, close: () -> Unit,
                               groupLeave: () -> Unit) {
    val e = app.settings
    // Only for playback from the server, and only if the account may transcode. **Not in a group**
    // (iOS `qualitySelection`): reloading reports stop and start past it, and you would keep playing alone.
    val qualityShow = e.convertAllowed && mediaWork.plan?.url?.startsWith("file") != true && !mediaWork.inGroup
    val group = if (mediaWork.inGroup) app.gemeinsam.value.group else null
    val run = rememberCoroutineScope()
    Box(Modifier.fillMaxSize()) {
        LayersReason()
        ColumnsRail(margin, portrait, 3 + (if (qualityShow) 1 else 0) + (if (group != null) 1 else 0)) { width ->
            // **Together first**: who is in, and below it the output. The names do nothing.
            if (group != null) SelectionColumn(translated("Gemeinsam · %@", group.name), width) {
                group.participant.forEach { name ->
                    Row(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp).semantics(mergeDescendants = true) {},
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(Modifier.width(18.dp), contentAlignment = Alignment.CenterStart) {
                            Symbol(Glyph.PersonFilled, 14.dp, color = Theme.fontVeryQuiet)
                        }
                        Text(name, style = Theme.listTitle, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(Theme.cornerField)).pressRow(groupLeave)
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.width(18.dp), contentAlignment = Alignment.CenterStart) {
                        Symbol(Glyph.SignOut, 14.dp, color = Theme.accent, strength = Strength.Semibold)
                    }
                    Text(translated("Gruppe verlassen"), style = Theme.listTitle, color = Theme.accent, maxLines = 1)
                }
            }
            SelectionColumn(translated("Bild"), width) {
                LayersRow(translated("Original"), !mediaWork.fillFrame) { mediaWork.imageFillingSet(false) }
                LayersRow(translated("Füllen"), mediaWork.fillFrame) { mediaWork.imageFillingSet(true) }
            }
            SelectionColumn(translated("Schlafzeit"), width) {
                LayersRow(translated("Aus"), mediaWork.sleepTime == 0) { mediaWork.sleepTimeSet(0) }
                listOf(15, 30, 45, 60, 90).forEach { m ->
                    LayersRow(translated("%lld Min.", m), mediaWork.sleepTime == m) { mediaWork.sleepTimeSet(m) }
                }
            }
            SelectionColumn(translated("Technikschild"), width) {
                LayersRow(translated("Aus"), !app.settings.techBadge) { app.settings.techBadge = false }
                LayersRow(translated("An"), app.settings.techBadge) { app.settings.techBadge = true }
            }
            // **Quality: Direct Play or an upper limit.** A limit means the server may transcode, so Direct Play
            // is off. Works like the setting in the app and reloads the movie at the same position.
            if (qualityShow) {
                val bitrates = remember { selectionRead(Kern.bitrateLevels()) }
                // `-1`: Direct Play. Otherwise a bitrate limit; `0` means unlimited.
                fun select(megabit: Int) {
                    val before = e.alwaysDirectPlay to e.bitratesLimit
                    if (megabit < 0) e.alwaysDirectPlay = true
                    else { e.alwaysDirectPlay = false; e.bitratesLimit = megabit }
                    if (before == (e.alwaysDirectPlay to e.bitratesLimit)) return
                    app.qualityReport()
                    close()
                    run.launch { mediaWork.qualitySwitch() }
                }
                SelectionColumn(translated("Qualität"), width) {
                    LayersRow(translated("Direct Play"), e.alwaysDirectPlay) { select(-1) }
                    bitrates.forEach { b ->
                        val value = b.value.toIntOrNull() ?: 0
                        LayersRow(b.text, !e.alwaysDirectPlay && e.bitratesLimit == value) { select(value) }
                    }
                }
            }
        }
        Box(Modifier.padding(start = margin.page, end = margin.page, top = margin.top)) { LayersHeader(close) }
    }
}

/**
 * The series' episodes, the same rows as on the series page (`EpisodesRow`, `SeasonChips`). The title
 * sits exactly where it sat in the player (`stateTitle`, does not fade); the season row takes
 * the place of the meta line. List preloaded (`episodesPreload`): on open it is already there, with the
 * current episode in the middle; only a season change fades in again.
 */
@Composable
private fun EpisodesLayer(app: SwiftlyApplication, seriesIdentifier: String, runningId: String, seasonIdentifier: String?, title: String, margin: Rand,
                        close: () -> Unit, start: (String) -> Unit) {
    // Mirrors `passendeStaffel(toward:)`: the current episode's season, not the one last chosen on the series page.
    fun matching(list: List<Season>, remembered: String?) =
        list.firstOrNull { it.id == seasonIdentifier }?.id ?: list.firstOrNull { it.id == remembered }?.id ?: list.firstOrNull()?.id
    val preloaded = remember(seriesIdentifier) { app.seriesCache[seriesIdentifier] }
    var seasons by remember(seriesIdentifier) { mutableStateOf(preloaded?.seasons.orEmpty()) }
    var selected by remember(seriesIdentifier) { mutableStateOf(preloaded?.let { matching(it.seasons, it.selected) }) }
    var episodes by remember(seriesIdentifier) { mutableStateOf(selected?.let { app.episodesCache[it] }.orEmpty()) }
    var seasonSwitched by remember { mutableStateOf(false) }
    val reveal = remember { Animatable(1f) }
    val run = rememberCoroutineScope()
    // Already in the first frame roughly where the current episode is; afterwards exactly centered.
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = (episodes.indexOfFirst { it.id == runningId } - 1).coerceAtLeast(0))

    // **Reload after a change to watch state** (tile menu): the check mark on the image and the swipe row
    // should be right at once, not on the next open of the layer.
    suspend fun episodesRefresh() {
        val g = selected ?: return
        try {
            val f = episodesRead(withContext(Dispatchers.IO) { app.kern.episodes(seriesIdentifier, g).await() })
            if (selected == g) { episodes = f; app.episodesCache[g] = f }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }

    LaunchedEffect(seriesIdentifier) {
        try {
            val s = seriesRead(withContext(Dispatchers.IO) { app.kern.series(seriesIdentifier).await() })
            app.seriesCache[seriesIdentifier] = s
            seasons = s.seasons
            if (selected == null || seasons.none { it.id == selected }) selected = matching(seasons, s.selected)
            val g = selected ?: return@LaunchedEffect
            if (episodes.isEmpty()) app.episodesCache[g]?.let { episodes = it }
            val f = episodesRead(withContext(Dispatchers.IO) { app.kern.episodes(seriesIdentifier, g).await() })
            if (selected == g) { episodes = f; app.episodesCache[g] = f }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }

    // **The current episode in view, centered** (mirrors `scrollTo(item.id, anchor: .center)`).
    LaunchedEffect(episodes) {
        if (seasonSwitched) {
            // The new season fades in instead of appearing hard (`easeOut(duration: 0.25)`).
            seasonSwitched = false
            reveal.snapTo(0f)
            launch { reveal.animateTo(1f, tween(250, easing = EaseOut)) }
        }
        val index = episodes.indexOfFirst { it.id == runningId }
        if (index < 0) return@LaunchedEffect
        listState.scrollToItem(index)
        val entryRecord = snapshotFlow { listState.layoutInfo.visibleItemsInfo.firstOrNull { it.index == index } }.first { it != null }
            ?: return@LaunchedEffect
        val info = listState.layoutInfo
        listState.scrollBy(-((info.viewportEndOffset - info.viewportStartOffset) / 2f - entryRecord.size / 2f))
    }

    Box(Modifier.fillMaxSize()) {
        LayersReason()
        Column(Modifier.fillMaxSize().padding(top = margin.top)) {
            Box(Modifier.padding(horizontal = margin.page)) {
                LayersHeader(close) {
                    // Placeholder: the title itself is in the player (`stateTitle`) and does not fade.
                    Text(title, style = titleStyle, maxLines = 1, modifier = Modifier.alpha(0f).clearAndSetSemantics {})
                }
            }
            // **The series page's row, edge to edge**, not inside the header: there the close button would
            // cut it short, and it scrolls under the layer's margin. The first chip starts under the title
            // (layer margin plus the header's own). Only from two seasons, as on the series page; 3 above as
            // the meta line it replaces.
            if (seasons.size > 1) SeasonChips(seasons, selected, edge = margin.page + PlayerMetric.page, spacing = Modifier.padding(top = 3.dp)) { new ->
                if (new != selected) {
                    selected = new
                    seasonSwitched = true
                    app.episodesCache[new]?.let { episodes = it }
                    run.launch {
                        try {
                            val f = episodesRead(withContext(Dispatchers.IO) { app.kern.episodes(seriesIdentifier, new).await() })
                            if (selected == new) { episodes = f; app.episodesCache[new] = f }
                        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
                    }
                }
            }
            LazyColumn(state = listState, contentPadding = PaddingValues(bottom = 12.dp + margin.bottom),
                       modifier = Modifier.weight(1f).padding(top = 10.dp, start = margin.page, end = margin.page).graphicsLayer { alpha = reveal.value }) {
                itemsIndexed(episodes, key = { _, f -> f.id }) { i, f ->
                    if (i > 0) Box(Modifier.padding(start = Theme.edgeSpacing).fillMaxWidth().height(1.dp).background(Theme.line))
                    Box(Modifier.background(if (f.id == runningId) Color.White.copy(alpha = 0.08f) else Color.Transparent)
                            .semantics { this.selected = f.id == runningId }) {
                        // Long press: the tile menu, in the player only with the watch state
                        // (`TileMenuRequest.inPlayer`); the row itself already starts the episode.
                        val menu = LocalTileMenu.current
                        val lengthy: (() -> Unit)? = menu?.let { m -> {
                            m(TileMenuRequest(f.id, f.title, "Episode", f.image, landscape = true, f.subline,
                                                 inPlayer = true, afterwards = { run.launch { episodesRefresh() } }))
                        } }
                        EpisodesRow(f, lengthy = lengthy) { start(f.id) }
                    }
                }
            }
        }
    }
}

/**
 * **The offer button**, the same in the controls and in the overlay (`Angebotsknopf` on iOS): white
 * pill, corner 12, 40 high, skip icon and bold 15. `share` (0..1): the countdown to the next
 * episode as a fill from the left, **dark on white**, not in accent color, which in the player
 * belongs solely to the bar's handle while seeking. TalkBack reads the label and, during the
 * countdown, the seconds until start.
 */
@Composable
fun OfferingPill(art: String, text: String, share: Double?, seconds: Int?, mediaWork: PlayItem, action: () -> Unit) {
    val fillContent = continuousFill(share, mediaWork.running, mediaWork.countdownLength)
    Row(Modifier.height(40.dp).clip(RoundedCornerShape(Theme.cornerField))
            .background(Color.White)
            .drawBehind { if (share != null) drawRect(Theme.reason.copy(alpha = 0.16f), size = size.copy(width = size.width * fillContent)) }
            .iconPress(true, text, action)
            .semantics(mergeDescendants = true) {
                if (seconds != null) stateDescription = translated("Startet in %lld Sekunden", seconds)
            }
            .padding(horizontal = 18.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Symbol(Glyph.Skip, 15.dp, color = Theme.reason, strength = Strength.Semibold)
        // Semibold, not bold: three weights, and bold only on the page title.
        Text(text, style = Theme.listTitle, color = Theme.reason, maxLines = 1)
    }
}

/**
 * **The card's fill as one continuous motion** (following it tick by tick stuttered); counterpart to
 * `FillClock` in the package. Running: linear from the current state to full over the remaining
 * time. Stopped: holds exactly there. Resumed: from there, never backwards. Without a card null.
 */
@Composable
fun continuousFill(share: Double?, running: Boolean, length: Double): Float {
    val value = remember { androidx.compose.animation.core.Animatable(0f) }
    val present = share != null
    LaunchedEffect(present, running) {
        if (!present) { value.snapTo(0f); return@LaunchedEffect }
        if (!running) { value.stop(); return@LaunchedEffect }
        val since = maxOf(value.value, (share ?: 0.0).toFloat())
        value.snapTo(since)
        val rest = ((1f - since) * length * 1000).toInt().coerceAtLeast(1)
        value.animateTo(1f, tween(rest, easing = LinearEasing))
    }
    return value.value
}

/** A fixed line of the tech overlay from `Kern.techFixed`: name quiet, value bright; `header` is the delivery. */
data class TechRow(val name: String?, val text: String, val art: String, val header: Boolean)

/**
 * **The tech overlay**, mirrors `TechBadge` in Sources/Shared. Top left, accepts nothing.
 *
 * **Only what a viewer wants to know**: delivery, reason, picture, audio, subtitles, file and buffer
 * are core lines and always shown; the loss line only if something was lost. Position, demuxer,
 * display, run, decoder and stream counters appear only in measuring mode (`techBadgeMeasure`,
 * via a start extra). Beyond the core lines [Kappliste] takes lines only while 55 % of the offered
 * height suffices: drop rather than scroll, the overlay takes no input.
 *
 * Font of the scale (`small`, tabular digits) instead of monospace; background `reason` at 0.78, no
 * border. `far`: the TV, 420 wide, spacing 7, padding 20/16, corner `cornerSmall`.
 * "Late" is missing: libVLC on Android does not count late frames; a zero would be a lie.
 *
 * Not `private`: `tv/TvPlayer.kt` shows the same overlay in the same place.
 */
@Composable
fun TechBadge(fixed: List<TechRow>, live: JSONObject?, position: () -> Double, duration: Double, measure: Boolean, far: Boolean,
                  modifier: Modifier = Modifier, hint: String? = null) {
    val digits = "tnum"
    val font = Theme.small.copy(fontFeatureSettings = digits)
    val headerFont = Theme.tile.copy(fontWeight = FontWeight.SemiBold, fontFeatureSettings = digits)
    val spacing = if (far) 7.dp else 4.dp
    fun comma(x: Double, set: Int = 1) = String.format(Locale.getDefault(), "%.${set}f", x)
    val rows = mutableListOf<Pair<Boolean, @Composable () -> Unit>>()
    fun kern(z: @Composable () -> Unit) { rows += true to z }
    fun rest(z: @Composable () -> Unit) { rows += false to z }
    @Composable fun measureRow(text: String, conspicuous: Boolean) {
        if (conspicuous) Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            Symbol(Glyph.Warning, 10.dp, color = Theme.warning)
            Text(text, style = font, color = Theme.warning)
        } else Text(text, style = font, color = Theme.fontQuiet)
    }
    @Composable fun detail(name: String, value: String, conspicuous: Boolean = false) {
        if (conspicuous) measureRow("$name $value", true)
        else Text(buildAnnotatedString {
            withStyle(SpanStyle(color = Theme.fontQuiet)) { append(name) }
            withStyle(SpanStyle(color = Theme.font)) { append(" $value") }
        }, style = font)
    }
    // **If no frame ever arrived, that goes under the header** (mirrors `TechBadge.swift`, `FirstFrame` in
    // the package). After header and transcode reason, before "Bild", like on Apple.
    val hintPre = fixed.indexOfFirst { !it.header && it.name != null }.let { if (it < 0) fixed.size else it }
    fun hintRow() = hint?.let { h -> kern { Text(h, style = font, color = Theme.warning,
        maxLines = if (measure) Int.MAX_VALUE else 2, overflow = TextOverflow.Ellipsis) } }
    fixed.forEachIndexed { i, z ->
        if (i == hintPre) hintRow()
        when {
            z.header -> kern { Text(z.text, style = headerFont, color = if (z.art == "gut") Theme.accent else Theme.warning) }
            z.name == null -> kern { Text(z.text, style = font, color = Theme.warning, maxLines = if (measure) Int.MAX_VALUE else 2,
                                          overflow = TextOverflow.Ellipsis) }
            else -> kern { detail(z.name, z.text) }
        }
    }
    if (hintPre == fixed.size) hintRow()
    live?.let { w ->
        // **Buffer: seconds of reserve and what arrives**, one line. KiB only when measuring.
        val seconds = w.fieldNumber("vorratSekunden")
        val parts = buildList {
            seconds?.let { add("${comma(it)} s") }
            if (measure) add("${w.optLong("vorratKiB")} KiB")
            w.fieldText("eingang")?.let { add("${translated("Eingang")} $it") }
        }
        if (parts.isNotEmpty()) kern { detail(translated("Puffer"), parts.joinToString(" · "), (seconds ?: Double.MAX_VALUE) < 2) }
        val discarded = w.optLong("verworfen"); val audioDistance = w.optLong("tonVerloren")
        val loss = discarded > 0 || audioDistance > 0
        if (measure || loss) rest { measureRow("${translated("Verworfen")} $discarded · ${translated("Ton weg")} $audioDistance", loss) }
    }
    if (measure) {
        if (duration > 1) rest { measureRow("${translated("Stelle")} ${timeText(position())} / ${timeText(duration)}", false) }
        live?.let { w ->
            // A hairline: above it the file, below it what counts up while playing.
            rest { Box(Modifier.padding(vertical = spacing / 2).width(if (far) 260.dp else 150.dp).height(1.dp).background(Theme.margin)) }
            val should = w.fieldNumber("soll")
            w.fieldText("demuxer")?.let { rest { measureRow("${translated("Demuxer")} $it", false) } }
            val shows = w.fieldNumber("zeigt")
            rest { measureRow("${translated("Zeigt Ø")} ${shows?.let { comma(it) } ?: "—"} fps · ${translated("Gezeigt")} ${w.optLong("gezeigt")}",
                             shows != null && should != null && shows < should - 2) }
            val run = w.fieldNumber("lauf")
            rest { measureRow("${translated("Lauf")} ${run?.let { "${(it * 100).roundToInt()} %" } ?: "—"}", (run ?: 1.0) < 0.97) }
            val decoded = w.fieldNumber("dekodiert")
            rest { measureRow("${translated("Dekodiert Ø")} ${decoded?.let { comma(it) } ?: "—"} fps",
                             decoded != null && should != null && decoded < should - 2) }
            val broken = w.optLong("beschaedigt"); val jumps = w.optLong("spruenge")
            rest { measureRow("${translated("Beschädigt")} $broken · ${translated("Sprünge")} $jumps", broken > 0 || jumps > 0) }
        }
    }
    val form = RoundedCornerShape(if (far) Theme.cornerSmall else Theme.corner)
    Box(modifier.clip(form).background(Theme.reason.copy(alpha = 0.78f))
            .padding(horizontal = if (far) 20.dp else 12.dp, vertical = if (far) 16.dp else 10.dp)
            .width(if (far) 420.dp else 260.dp)
            .clearAndSetSemantics { contentDescription = fixed.joinToString(", ") { listOfNotNull(it.name, it.text).joinToString(" ") } }) {
        TruncatedList(spacing, if (measure) null else 0.55f, rows.map { it.first }) { rows.forEach { it.second() } }
    }
}

/**
 * **A column with a maximum height that drops rows instead of scrolling** (mirrors `TruncatedList`). Core
 * lines always stay; it takes the others from the top while they fit in `share` of the offered
 * height, and stops at the first that no longer fits. The order is the ranking.
 */
@Composable
private fun TruncatedList(spacing: Dp, share: Float?, kern: List<Boolean>, content: @Composable () -> Unit) {
    Layout(content) { parts, constraints ->
        val limit = if (share != null && constraints.hasBoundedHeight) constraints.maxHeight * share else Float.POSITIVE_INFINITY
        val padding = spacing.roundToPx()
        val free = constraints.copy(minWidth = 0, minHeight = 0, maxHeight = Constraints.Infinity)
        var sum = 0; var full = false
        val state = parts.mapIndexed { i, t ->
            val g = t.measure(free)
            val new = sum + (if (sum == 0) 0 else padding) + g.height
            if (!kern.getOrElse(i) { false } && (full || new > limit)) { full = true; null } else { sum = new; g }
        }
        val width = if (constraints.hasBoundedWidth) constraints.maxWidth else state.maxOfOrNull { it?.width ?: 0 } ?: 0
        layout(width, sum) {
            var y = 0
            state.forEach { g -> if (g != null) { g.place(0, y); y += g.height + padding } }
        }
    }
}

