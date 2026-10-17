package de.paulherter.swiftly

import android.content.Context
import android.graphics.Bitmap
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.Surface
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.SingletonImageLoader
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import coil3.toBitmap
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import kotlin.coroutines.resume

// MARK: - "Hier weiterschauen" as a card (phone and TV)
//
// Mirrors `Sources/Shared/HandoffStage.swift` (`HandoffStage`, `HandoffExit`).
// All timings, springs and dimensions come from the package (`HandoffCard`) through the core
// (`Kern.handoffStates`, `Kern.handoffLane`,
// `Android/core/swift/Sources/SwiftlyCore/Handoff.swift`) as keyframes, 120 per second, linear
// in between like `calculationMode = .linear`. Only the drawing is here: position, size and
// alpha only, read at draw time (`graphicsLayer`), no effects. With reduced motion (animator
// duration 0): fade only.
//
// On top of everything, including the player: the player is its own activity. So the stage is
// app state (`Uebergabe`), and every activity draws it on top (`HandoffLayer`) on the same
// clock from the tap. If the player opens under the card, it keeps drawing the card in the same
// frame.

/** Keyframes from `Kern.handoffLane`; per point x, y, width, corner, top of the lines (dp). */
class HandoffPath(json: String) {
    private val o = JSONObject(json)
    private val t0 = o.optDouble("t0", 0.0)
    private val dt = o.optDouble("dt", 0.0)
    private val l: FloatArray = o.optJSONArray("l")?.let { a -> FloatArray(a.length()) { a.getDouble(it).toFloat() } } ?: FloatArray(0)
    private val d: FloatArray = o.optJSONArray("d")?.let { a -> FloatArray(a.length()) { a.getDouble(it).toFloat() } } ?: FloatArray(0)
    private val dn = o.optInt("dn", 0)
    val out: Double? = if (o.has("raus") && !o.isNull("raus")) o.getDouble("raus") else null
    /** `new`: the position at `since`; `exit`: the card at rest (x, y, width). */
    val status: FloatArray? = o.optJSONArray("lage")?.let { a -> FloatArray(a.length()) { a.getDouble(it).toFloat() } }

    private fun spot(t: Double, count: Int): Pair<Int, Float> {
        if (count <= 1 || dt <= 0) return 0 to 0f
        val s = ((t - t0) / dt).coerceIn(0.0, (count - 1).toDouble())
        val i = s.toInt().coerceAtMost(count - 2)
        return i to (s - i).toFloat()
    }

    /** x, y, width, corner, line top at time `t`, linear between the points. */
    fun status(t: Double): FloatArray {
        val n = l.size / 5
        if (n == 0) return FloatArray(5)
        val (i, f) = spot(t, n)
        return FloatArray(5) { k -> val a = l[i * 5 + k]; if (n == 1) a else a + (l[(i + 1) * 5 + k] - a) * f }
    }

    fun coverage(t: Double, k: Int = 0): Float {
        if (dn == 0) return 1f
        val n = d.size / dn
        if (n == 0) return 1f
        val (i, f) = spot(t, n)
        val a = d[i * dn + k]
        return if (n == 1) a else a + (d[(i + 1) * dn + k] - a) * f
    }
}

/** The timings from the package (`HandoffPath.Times` in the core). */
class HandoffTimes(o: JSONObject) {
    val pageUntil = o.getDouble("seiteBis")
    val cardsStart = o.getDouble("kartenStart")
    val float = o.getDouble("schweben")
    val loadingBarOut = o.getDouble("ladelinieAb")
    val loadingBarShow = o.getDouble("ladelinieEinblenden")
    val loadingBarTick = o.getDouble("ladelinieTakt")
    val rowsOut = o.getDouble("zeilenAus")
    val blackDuration = o.getDouble("schwarzDauer")
    val cardsOutFrom = o.getDouble("kartenAusVon")
    val end = o.getDouble("ende")
    val atMostWait = o.getDouble("hoechstensWarten")
    val fade = o.getDouble("blende")
    val fadeOut = o.getDouble("blendeAus")
    val exitStart = o.getDouble("abgangStart")
    val waitUntil = o.getDouble("wartenBis")
}

/** Fullscreen, rest position and dimensions for one screen (`Kern.handoffStates`), all in dp. */
class HandoffStatus(json: String) {
    private val o = JSONObject(json)
    private fun three(n: String) = o.getJSONArray(n).let { a -> DoubleArray(3) { a.getDouble(it) } }
    val full = three("voll")
    val idle = three("ruhe")
    private val m = o.getJSONObject("masse")
    val corner = m.getDouble("ecke")
    val title = m.getDouble("titel")
    val small = m.getDouble("klein")
    val spacing = m.getDouble("abstand")
    val times = HandoffTimes(o.getJSONObject("zeiten"))
}

private fun list(vararg d: Double) = d.joinToString(",", "[", "]")

/** Title and episode under the card (`HandoffStyle.rows`): "The Mentalist" and "Staffel 6 · Folge 7". */
internal fun handoffRows(name: String, series: String?, season: Int?, episode: Int?): Pair<String, String?> =
    if (!series.isNullOrEmpty()) series to (if (season != null && episode != null) translated("Staffel %lld · Folge %lld", season, episode) else name)
    else name to null

object Handoff {
    private fun note(text: String) = AppLog.writeOut("[Uebergabe] $text")

    /** What this device is called in the hint to the sender; `HandoffCard.sizesRank` knows both. */
    fun ownName(app: SwiftlyApplication) = if (app.isTv) "Android TV" else "Android"

    /** The timings, read once; they do not depend on the screen. */
    val times: HandoffTimes by lazy { HandoffStatus(Kern.handoffStates(1920.0, 1080.0, false)).times }

    // MARK: Receiver

    class Arrival(
        val number: Int, val beginning: Long, val itemID: String, val image: String?,
        val title: String, val under: String?,
        /** Where the badge was (dp), `BadgeOrigin.point`. */
        val provenance: Offset?, val calm: Boolean, val tv: Boolean,
    ) {
        var size: Pair<Double, Double>? = null
        var situations by mutableStateOf<HandoffStatus?>(null)
        var from = DoubleArray(3)
        var transitionOut = times.cardsStart
        var wait by mutableStateOf<HandoffPath?>(null)
        var coverage by mutableStateOf<HandoffPath?>(null)
        var zoom by mutableStateOf<HandoffPath?>(null)
        var zoomOff by mutableStateOf<Double?>(null)
        var ready: Double? = null
        var loadLineSince by mutableStateOf<Double?>(null)
        var cancelSince by mutableStateOf<Double?>(null)
        fun now() = (System.nanoTime() - beginning) / 1e9
    }

    var arrival by mutableStateOf<Arrival?>(null); private set
    private var runCount = 0

    /** Card width at the badge when it opens (`HandoffStyle.badgeWidth`, halved on TV). */
    private fun badgeWidth(tv: Boolean) = if (tv) 30.0 else 44.0

    /**
         * On tap, before the network is asked (`HandoffStage.start`). `provenance` in root pixels;
         * `dichte` converts to dp.
         */
    fun receive(app: SwiftlyApplication, a: Offering, provenance: Offset?, density: Float, calm: Boolean) {
        runCount++
        val (title, under) = handoffRows(a.name, a.series, a.seasonNr, a.episodeNr)
        val e = Arrival(runCount, System.nanoTime(), a.itemID, a.image, title, under,
                        provenance?.takeIf { it != Offset.Zero }?.let { Offset(it.x / density, it.y / density) },
                        calm, app.isTv)
        arrival = e
        note("Karte +0 ms ${if (calm) "blendet auf (reduziert)" else "wächst aus dem Abzeichen"}")
        // The loading line only if the image is still missing at 0.75 s (`HandoffCard.loadLine`).
        app.applicationRun.launch {
            delay((times.loadingBarOut * 1000).toLong())
            if (arrival !== e || e.zoomOff != null) return@launch
            val b = e.ready
            if (b == null || b > times.loadingBarOut) { e.loadLineSince = e.now(); card(e, "Ladelinie") }
        }
    }

    private fun card(e: Arrival, was: String) = note("Karte +${(e.now() * 1000).toInt()} ms $was")

    /**
         * The stage knows its screen: layouts and path on first use; if it rotates while the card
         * waits, the card flies from where it is to the new rest position (`newAlign`).
         */
    internal fun screen(e: Arrival, width: Double, height: Double) {
        val alt = e.size
        if (alt != null && kotlin.math.abs(alt.first - width) < 0.5 && kotlin.math.abs(alt.second - height) < 0.5) return
        e.size = width to height
        val new = HandoffStatus(Kern.handoffStates(width, height, e.tv))
        val before = e.situations
        e.situations = new
        if (before == null) {
            val u = e.provenance
            e.from = if (u != null && !e.calm) doubleArrayOf(u.x.toDouble(), u.y.toDouble(), badgeWidth(e.tv)) else new.idle
            e.coverage = HandoffPath(Kern.handoffLane("""{"art":"deckung","fernseher":${e.tv}}"""))
            // Also at rest: the path from the rest position, read only at 0 where it stands still.
            e.wait = lane(e, "warten", 0.0)
            return
        }
        card(e, "Drehung auf ${width.toInt()}×${height.toInt()}")
        if (e.zoomOff != null) return
        if (e.calm) { e.from = new.idle; e.wait = lane(e, "warten", 0.0); return }
        val t = e.now()
        val now = HandoffPath(Kern.handoffLane("""{"art":"neu","fernseher":${e.tv},"von":${list(*e.from)},""" +
            """"ruhe":${list(*before.idle)},"flugAb":${e.transitionOut},"ab":$t}"""))
        now.status?.let { e.from = doubleArrayOf(it[0].toDouble(), it[1].toDouble(), it[2].toDouble()) }
        e.transitionOut = t
        e.wait = lane(e, "warten", t)
    }

    private fun lane(e: Arrival, art: String, since: Double): HandoffPath {
        val l = e.situations!!
        return HandoffPath(Kern.handoffLane("""{"art":"$art","fernseher":${e.tv},"von":${list(*e.from)},""" +
            """"ruhe":${list(*l.idle)},"voll":${list(*l.full)},"flugAb":${e.transitionOut},"ab":$since,"bis":${times.waitUntil}}"""))
    }

    /** Before the player starts: the ground over the page is up, otherwise the activity switch would show. */
    suspend fun prePlayer() {
        val e = arrival ?: return
        val rest = times.pageUntil - e.now()
        if (rest > 0) delay((rest * 1000).toLong())
    }

    /** The player is up (invisible under the card). From here the card waits at most `atMostWait`. */
    fun playerComes(app: SwiftlyApplication, itemID: String) {
        val e = arrival ?: return
        card(e, "Player geöffnet")
        app.applicationRun.launch {
            delay((times.atMostWait * 1000).toLong())
            if (arrival !== e || e.zoomOff != null || e.cancelSince != null) return@launch
            card(e, "kein erstes Bild — Karte gibt trotzdem frei")
            zoomIn(app, e, e.now())
        }
    }

    /** The next playback comes from this handover: it starts muted and fades the sound in. */
    fun receives(itemID: String): Boolean = arrival?.let { it.itemID == itemID && it.zoomOff == null && it.cancelSince == null } == true

    /** The first frame is up; now the card zooms (at the earliest at `float`). */
    fun imagePresent(app: SwiftlyApplication, itemID: String) {
        val e = arrival ?: return
        if (e.zoomOff != null || e.cancelSince != null || e.itemID != itemID) return
        card(e, "erstes Bild")
        zoomIn(app, e, e.now())
    }

    private fun zoomIn(app: SwiftlyApplication, e: Arrival, t: Double) {
        e.ready = t
        val z = if (e.calm) t else maxOf(times.float, t)
        if (!e.calm && e.situations != null) e.zoom = lane(e, "zoom", z)
        e.zoomOff = z
        card(e, "Zoom ab +${(z * 1000).toInt()} ms")
        val until = z + if (e.calm) times.fadeOut + 0.05 else times.end
        app.applicationRun.launch {
            delay(((until - e.now()) * 1000).toLong().coerceAtLeast(0))
            if (arrival !== e) return@launch
            card(e, "fertig")
            arrival = null
        }
    }

    /** The handover failed or the player closed earlier: the stage fades out. */
    fun cancel(app: SwiftlyApplication, reason: String) {
        val e = arrival ?: return
        if (e.cancelSince != null) return
        card(e, "abgebrochen: $reason")
        e.cancelSince = e.now()
        app.applicationRun.launch {
            delay(((times.fade + 0.05) * 1000).toLong())
            if (arrival === e) arrival = null
        }
    }

    /** The player closed before the card released it. */
    fun playerDistance(app: SwiftlyApplication, itemID: String) {
        val e = arrival ?: return
        if (e.itemID == itemID && e.zoomOff == null) cancel(app, "Player geschlossen")
    }

    // MARK: Sender

    class Exit(val number: Int, val beginning: Long, val image: ImageBitmap, val full: DoubleArray, val pages: Double,
                 val title: String, val under: String?, val calm: Boolean, val lane: HandoffPath?,
                 val situations: HandoffStatus, val out: Double) {
        fun now() = (System.nanoTime() - beginning) / 1e9
    }

    var exit by mutableStateOf<Exit?>(null); private set

    /**
         * The sender's picture leaves as a card (`HandoffExit.start`): the player pauses, the
         * still frame is taken (if it is black, the episode image), and the stage lays itself exactly
         * over the video position, opaque across the screen. The card shrinks, hovers briefly and flies
         * out, up toward the larger device, down toward the smaller. Then `done`: the player closes.
         * `false` if there is neither still nor episode image; then the player closes as usual.
         */
    suspend fun handIn(app: SwiftlyApplication, context: Context, area: View?, target: String, plan: PlayPlan?,
                        calm: Boolean, done: () -> Unit): Boolean {
        val stop = System.nanoTime()
        fun time(was: String) = note("Abgang +${(System.nanoTime() - stop) / 1_000_000} ms $was")
        time("an $target${if (calm) " (reduziert)" else ""}")
        if (area == null) { time("keine Fläche — Player schließt wie sonst"); return false }
        val root = area.rootView
        val density = context.resources.displayMetrics.density
        val screenB = root.width / density.toDouble()
        val screenH = root.height / density.toDouble()
        // Request gravity right away; the first measurement arrives after a few hundredths of a second.
        val heaviness = if (!app.isTv && !calm) Gravity(context) else null
        try {
            var image: Bitmap? = null
            var frameRect: Rect? = null
            stillImage(area)?.let { (b, r) ->
                val bright = brightness(b)
                if (bright < 0.04) time("Standbild schwarz (Helligkeit ${"%.3f".format(bright)}) — Folgenbild")
                else { image = b; frameRect = r; time("Standbild da") }
            } ?: time("kein Standbild — Folgenbild")
            var pages = image?.let { it.width.toDouble() / it.height.coerceAtLeast(1) } ?: (16.0 / 9)
            if (image == null) {
                val url = plan?.cardImage
                image = url?.let { u -> withContext(Dispatchers.IO) { runCatching {
                    (SingletonImageLoader.get(context).execute(ImageRequest.Builder(context).data(u).size(1280).allowHardware(false).build())
                        as? SuccessResult)?.image?.toBitmap()
                }.getOrNull() } }
                frameRect = areaFrame(area)
                pages = 16.0 / 9
                if (image != null) time("Folgenbild da")
            }
            val b = image
            val r = frameRect
            if (b == null || r == null) { time("weder Standbild noch Folgenbild — Player schließt wie sonst"); return false }
            // Where the video sat in the surface: fitted by the image itself (dp).
            val rb = r.width / density.toDouble(); val rh = r.height / density.toDouble()
            val vb = minOf(rb, rh * pages)
            val full = doubleArrayOf(r.center.x / density.toDouble(), r.center.y / density.toDouble(), vb)
            val situations = HandoffStatus(Kern.handoffStates(screenB, screenH, app.isTv))
            val (title, under) = plan?.let { p ->
                if (p.episode) handoffRows(p.title, p.headerLine, p.seasonNr, p.episodeNr) else p.title to null
            } ?: ("" to null)
            val lane: HandoffPath?
            val out: Double
            if (calm) {
                lane = null
                out = times.fadeOut
            } else {
                val top = Kern.handoffToTop(ownName(app), target)
                val g = heaviness?.measurement()
                val status = when (runCatching { area.display?.rotation }.getOrNull()) {
                    Surface.ROTATION_180 -> "kopfueber"
                    Surface.ROTATION_90 -> "querHomeRechts"
                    Surface.ROTATION_270 -> "querHomeLinks"
                    else -> "hoch"
                }
                // Android measures the opposing force (upright y = +9.81); `CMDeviceMotion.gravity` gives gravity
                                // itself in g (upright y = -1). So flip and divide.
                val gravity = g?.let { ",\"schwerkraft\":${list(-it[0] / 9.81, -it[1] / 9.81)},\"oberflaeche\":\"$status\"" } ?: ""
                if (g != null) time("Schwerkraft ${"%.2f, %.2f, %.2f".format(-g[0] / 9.81, -g[1] / 9.81, -g[2] / 9.81)} · Oberfläche $status")
                lane = HandoffPath(Kern.handoffLane("""{"art":"abgang","fernseher":${app.isTv},"voll":${list(*full)},""" +
                    """"schirm":${list(screenB, screenH)},"nachOben":$top$gravity}"""))
                out = lane.out ?: 2.0
                time("fliegt nach ${if (top) "oben" else "unten"}, draußen nach ${(out * 1000).toInt()} ms")
            }
            runCount++
            val a = Exit(runCount, System.nanoTime(), b.asImageBitmap(), full, pages, title, under, calm, lane, situations, out)
            exit = a
            time("Bühne deckt den Player ab ihrem ersten Bild")
            app.applicationRun.launch {
                delay(((out - a.now()) * 1000).toLong().coerceAtLeast(0))
                time("Karte draußen — Player schließt unter der Bühne")
                done()
                // The activity fades out on close (`player_exit`); after that the stage is gone.
                delay(((0.5 + times.fade + 0.05) * 1000).toLong())
                if (exit === a) exit = null
            }
            return true
        } finally {
            heaviness?.from()
        }
    }

    /** Gravity at departure: how the phone is actually held (`CMMotionManager`). */
    private class Gravity(context: Context) : SensorEventListener {
        private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        @Volatile private var last: FloatArray? = null
        init {
            sensors?.getDefaultSensor(Sensor.TYPE_GRAVITY)?.let { sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME) }
        }
        override fun onSensorChanged(e: SensorEvent) { last = e.values.copyOf() }
        override fun onAccuracyChanged(s: Sensor?, a: Int) {}
        /** Wait at most 120 ms, as on Apple (6 x 20 ms). */
        suspend fun measurement(): DoubleArray? {
            var n = 0
            while (last == null && n < 6) { delay(20); n++ }
            return last?.let { doubleArrayOf(it[0].toDouble(), it[1].toDouble(), it[2].toDouble()) }
        }
        fun from() { runCatching { sensors?.unregisterListener(this) } }
    }

    /** libVLC's video surface (`surface_video`) in the `VLCVideoLayout`. */
    private fun videoArea(v: View): SurfaceView? {
        val all = mutableListOf<SurfaceView>()
        fun searching(x: View) {
            if (x is SurfaceView && x.visibility == View.VISIBLE && x.width > 0) all += x
            if (x is ViewGroup) for (i in 0 until x.childCount) searching(x.getChildAt(i))
        }
        searching(v)
        return all.firstOrNull { s -> runCatching { s.resources.getResourceEntryName(s.id) }.getOrNull() == "surface_video" } ?: all.firstOrNull()
    }

    private fun areaFrame(v: View): Rect {
        val place = IntArray(2)
        v.getLocationInWindow(place)
        return Rect(place[0].toFloat(), place[1].toFloat(), (place[0] + v.width).toFloat(), (place[1] + v.height).toFloat())
    }

    /** The still frame (`VLCPlayerView.standbild`): `PixelCopy` from the video surface, up to 0.6 s. */
    private suspend fun stillImage(area: View): Pair<Bitmap, Rect>? {
        val s = videoArea(area) ?: return null
        if (s.width <= 0 || s.height <= 0 || s.holder.surface?.isValid != true) return null
        val b = Bitmap.createBitmap(s.width, s.height, Bitmap.Config.ARGB_8888)
        val ok = withTimeoutOrNull(600) {
            suspendCancellableCoroutine { k ->
                runCatching {
                    PixelCopy.request(s, b, { r -> if (k.isActive) k.resume(r == PixelCopy.SUCCESS) }, Handler(Looper.getMainLooper()))
                }.onFailure { if (k.isActive) k.resume(false) }
            }
        } ?: false
        return if (ok) b to areaFrame(s) else null
    }

    /** Mean brightness 0..1, downscaled to 16 x 16 points (`HandoffExit.brightness`). */
    private fun brightness(b: Bitmap): Double {
        val k = Bitmap.createScaledBitmap(b, 16, 16, true)
        var sum = 0.0
        for (y in 0 until 16) for (x in 0 until 16) {
            val p = k.getPixel(x, y)
            sum += 0.2126 * ((p shr 16) and 0xFF) + 0.7152 * ((p shr 8) and 0xFF) + 0.0722 * (p and 0xFF)
        }
        return sum / 256 / 255
    }
}

private fun linear(t: Double, a: Double, b: Double): Float = ((t - a) / (b - a)).coerceIn(0.0, 1.0).toFloat()

/**
 * The stage, on top in every activity: main view, TV and player. Accepts no taps. `inPlayer`:
 * only there does the sender's picture depart too.
 */
@Composable
fun HandoffLayer(inPlayer: Boolean) {
    Handoff.arrival?.let { ArrivalStage(it) }
    if (inPlayer) Handoff.exit?.let { ExitStage(it) }
}

@Composable
private fun clock(beginning: Long): androidx.compose.runtime.State<Double> {
    val time = remember(beginning) { mutableDoubleStateOf((System.nanoTime() - beginning) / 1e9) }
    LaunchedEffect(beginning) { while (true) withFrameNanos { n -> time.doubleValue = ((n - beginning) / 1e9).coerceAtLeast(0.0) } }
    return time
}

/** The card, built at full size and moved and scaled while drawing (`transform.scale`). */
private fun Modifier.cardsStatus(density: Float, base: Float, status: () -> FloatArray?): Modifier = graphicsLayer {
    val l = status() ?: return@graphicsLayer
    val m = l[2] / base
    transformOrigin = TransformOrigin(0.5f, 0.5f)
    translationX = l[0] * density - base * density / 2
    translationY = l[1] * density - base * density / 2 * 9 / 16
    scaleX = m; scaleY = m
    // The visible corner `HandoffCard.corner`, computed before scaling (`cornerRadius * basis / breite`).
    shape = RoundedCornerShape((l[3] / m.coerceAtLeast(0.001f)).dp)
    clip = true
}

@Composable
private fun Rows(title: String, under: String?, width: Double, l: HandoffStatus, line: (@Composable () -> Unit)?,
                   modifier: Modifier) {
    val density = LocalDensity.current
    val titleSp = with(density) { l.title.dp.toSp() }
    val smallSp = with(density) { l.small.dp.toSp() }
    Box(modifier.requiredWidth(width.dp)) {
        Column(Modifier.fillMaxWidth().padding(top = (2 + l.spacing * 0.35).dp),
               verticalArrangement = Arrangement.spacedBy((l.spacing * 0.25).dp)) {
            Text(title, style = TextStyle(fontSize = titleSp, fontWeight = FontWeight.SemiBold), color = Theme.font,
                 maxLines = 1, overflow = TextOverflow.Ellipsis)
            under?.let { Text(it, style = TextStyle(fontSize = smallSp), color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
        line?.invoke()
    }
}

@Composable
private fun ArrivalStage(e: Handoff.Arrival) {
    val z = Handoff.times
    val time by clock(e.beginning)
    val density = LocalDensity.current.density
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val b = maxWidth.value.toDouble(); val h = maxHeight.value.toDouble()
        LaunchedEffect(b, h) { Handoff.screen(e, b, h) }
        val l = e.situations ?: return@BoxWithConstraints
        // The whole stage: fades out smoothly after the zoom, faded on abort.
        Box(Modifier.fillMaxSize().graphicsLayer {
            val t = time
            var a = 1f
            e.zoomOff?.let { za ->
                a = if (e.calm) 1f - linear(t, za, za + z.fadeOut) else (e.zoom?.coverage(t - za) ?: 1f)
            }
            e.cancelSince?.let { s -> a *= 1f - linear(t, s, s + z.fade) }
            alpha = a
        }) {
            // The ground over the page; the page steps back.
            Box(Modifier.fillMaxSize().graphicsLayer {
                alpha = if (e.calm) linear(time, 0.0, z.fade) else (e.coverage?.coverage(time, 1) ?: 0f)
            }.background(Theme.reason))
            // Black like the player's ground, from the zoom on.
            if (!e.calm) Box(Modifier.fillMaxSize().graphicsLayer {
                alpha = e.zoomOff?.let { za -> linear(time, za, za + z.blackDuration) } ?: 0f
            }.background(Color.Black))
            val base = l.full[2].toFloat()
            fun status(t: Double): FloatArray? {
                if (e.calm) return e.wait?.status(0.0)
                val za = e.zoomOff
                return if (za != null && t >= za) e.zoom?.status(t - za) ?: e.wait?.status(t) else e.wait?.status(t)
            }
            Box(Modifier.requiredSize(base.dp, (base * 9 / 16).dp).align(Alignment.TopStart)
                    .cardsStatus(density, base) { status(time) }
                    .graphicsLayer {
                        alpha = if (e.calm) linear(time, z.cardsStart, z.cardsStart + z.fade)
                                else (e.coverage?.coverage(time, 0) ?: 0f)
                    }
                    .background(Theme.area)) {
                if (e.image != null) AsyncImage(e.image, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            }
            // Title and episode below; the loading line on top if the image is slow.
            Rows(e.title, e.under, l.idle[2], l, line = {
                val since = e.loadLineSince
                if (since != null) Box(Modifier.fillMaxWidth().height(2.dp).graphicsLayer {
                    alpha = linear(time, since, since + z.loadingBarShow)
                }.clip(RoundedCornerShape(1.dp)).background(Theme.margin)) {
                    val width = l.idle[2].toFloat()
                    Box(Modifier.requiredWidth((width * 0.3f).dp).height(2.dp).align(Alignment.TopStart).graphicsLayer {
                        val w = width * 0.3f
                        val u = (((time - since) / z.loadingBarTick) % 1.0).toFloat()
                        translationX = ((-w / 2) + (width + w) * u - w / 2) * density
                    }.clip(RoundedCornerShape(1.dp)).background(Theme.accent))
                }
            }, modifier = Modifier.align(Alignment.TopStart).graphicsLayer {
                val t = time
                val k = status(t) ?: return@graphicsLayer
                translationX = (k[0] - l.idle[2].toFloat() / 2) * density
                translationY = k[4] * density
                alpha = if (e.calm) linear(t, z.cardsStart, z.cardsStart + z.fade)
                        else (e.coverage?.coverage(t, 2) ?: 0f) * (e.zoomOff?.let { za -> 1f - linear(t, za, za + z.rowsOut) } ?: 1f)
            })
        }
    }
}

@Composable
private fun ExitStage(a: Handoff.Exit) {
    val z = Handoff.times
    val time by clock(a.beginning)
    val density = LocalDensity.current.density
    val l = a.situations
    Box(Modifier.fillMaxSize()) {
        // Opaque over the player until it has closed.
        Box(Modifier.fillMaxSize().background(Theme.reason))
        // Mirror of the receiver: black leaves as the card shrinks.
        Box(Modifier.fillMaxSize().graphicsLayer {
            alpha = if (a.calm) 1f - linear(time, 0.0, z.fadeOut) else 1f - linear(time, z.exitStart, z.exitStart + z.blackDuration)
        }.background(Color.Black))
        val vb = a.full[2].toFloat()
        Box(Modifier.requiredSize(vb.dp, (vb / a.pages).dp).align(Alignment.TopStart).graphicsLayer {
            val status = if (a.calm) floatArrayOf(a.full[0].toFloat(), a.full[1].toFloat(), vb, 0f, 0f) else a.lane?.status(time)
            if (status != null) {
                val m = status[2] / vb
                transformOrigin = TransformOrigin(0.5f, 0.5f)
                translationX = status[0] * density - vb * density / 2
                translationY = status[1] * density - (vb / a.pages.toFloat()) * density / 2
                scaleX = m; scaleY = m
                shape = RoundedCornerShape((status[3] / m.coerceAtLeast(0.001f)).dp)
                clip = true
            }
            if (a.calm) alpha = 1f - linear(time, 0.0, z.fadeOut)
        }) {
            Image(a.image, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
        if (!a.calm) a.lane?.status?.let { card ->
            Rows(a.title, a.under, card[2].toDouble(), l, line = null, modifier = Modifier.align(Alignment.TopStart).graphicsLayer {
                val k = a.lane.status(time)
                translationX = (k[0] - card[2] / 2) * density
                translationY = k[4] * density
                alpha = a.lane.coverage(time, 0)
            })
        }
    }
}
