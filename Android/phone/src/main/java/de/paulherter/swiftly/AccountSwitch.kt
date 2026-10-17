package de.paulherter.swiftly

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import android.view.Choreographer
import kotlin.coroutines.resume
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * The account switch as a motion; mirrors `AccountSwitchTransition` in `Sources/iOS/Transitions.swift`.
 *
 * 1. Tap: a still of the screen lies over everything and moves off to the right as a page (spring
 *    0.42, no overshoot, 80 ms after the tap); next to it the profile picture flies in an arc to
 *    the top right.
 * 2. Right after, before anything moves, the stack jumps back without animation, invisibly under
 *    the still. The old account's rows are gone at once.
 * 3. Switch: 0.3 s before the picture comes to rest (`AccountSwitchCurve.change`). The rebuild
 *    costs the main run time, and then the picture only moves by fractions of a point.
 * 4. Swap: when the picture rests, the real one sits there; the ring pops on landing.
 * 5. Rows: staggered 30 ms later (`railEntrance`).
 *
 * The path is computed by the package (`AccountSwitchCurve`, via `Kern.accountSwitchCurve`) as
 * sample points, 120 per second; here it is only read per frame without rebuilding. Position and
 * size sit in the `graphicsLayer`, read at draw time. Reduce motion: crossfade only, no flight.
 */
object AccountSwitchTransition {
    /** The new account flies; `replaced`: the real picture in the header is already in place (step 4). */
    data class Transition(val account: String, val replaced: Boolean = false)

    class Curve(json: String) {
        private val o = JSONObject(json)
        val swap = o.getDouble("tausch")
        val landing = o.getDouble("landung")
        val paintEnd = o.getDouble("ringEnde")
        val change = o.getDouble("wechsel")
        val targetSize = o.getDouble("zielgroesse").toFloat()
        val lane: FloatArray = o.getJSONArray("bahn").let { a -> FloatArray(a.length()) { a.getDouble(it).toFloat() } }
        val ring: FloatArray = o.getJSONArray("ring").let { a -> FloatArray(a.length()) { a.getDouble(it).toFloat() } }

        /** x, y, size (dp) at time `t`; linear between sample points, like `calculationMode = .linear`. */
        fun status(t: Double): Triple<Float, Float, Float> {
            val n = lane.size / 3 - 1
            if (n <= 0 || t >= swap) return Triple(lane[lane.size - 3], lane[lane.size - 2], lane[lane.size - 1])
            val spot = (t.coerceAtLeast(0.0) / swap * n)
            val i = spot.toInt().coerceIn(0, n - 1)
            val f = (spot - i).toFloat()
            fun w(k: Int) = lane[i * 3 + k] + (lane[(i + 1) * 3 + k] - lane[i * 3 + k]) * f
            return Triple(w(0), w(1), w(2))
        }

        /** Size and opacity of the ring `r` seconds after landing. */
        fun ring(r: Double): Pair<Float, Float> {
            if (r < 0 || r > 0.8) return 1f to 0f
            val i = (r / 0.8 * 96).toInt().coerceIn(0, 96)
            return ring[i * 2] to ring[i * 2 + 1]
        }
    }

    /** What is on stage. All frames in root coordinates (px). */
    class Stage(val stillImage: ImageBitmap?, val cap: Rect?, val area: Color, val curve: Curve?,
                 val name: String, val image: String?, val start: Long, val calm: Boolean, val number: Int)

    var stage by mutableStateOf<Stage?>(null); private set
    var transition by mutableStateOf<Transition?>(null); private set
    /** Between tap and release; the home page holds back its rows meanwhile. */
    var waits by mutableStateOf(false); private set
    /** Rises on tap: the main view rebuilds under the still (stack empty). */
    var back by mutableIntStateOf(0); private set
    /** Rises when the rows may come; then staggered (`railEntrance`). */
    var sharing by mutableIntStateOf(0); private set
    var sharingAround = 0L; private set
    /** Where the profile picture stands at the top, in root coordinates; reported by the header. */
    var target: Rect = Rect.Zero; private set
    /** The target the path was computed for at the tap. The header still springs and ends up elsewhere later. */
    var targetTap: Rect = Rect.Zero; private set
    /** The screen as a recorded layer (`MainActivity`), from which the still is made. */
    var screen: GraphicsLayer? = null

    private var switchTo: (() -> Unit)? = null
    /** The account has already switched; before that the home page does not load (it would fetch the old account). */
    val switched: Boolean get() = switchTo == null
    private var runCount = 0

    /** Only if it really stands at the top right: in the middle of pushing a page it stands further left (measured: 846 instead of 949 px). */
    fun targetReport(frameRect: Rect, width: Float) {
        // At rest the edge is 16 dp from the screen edge; 30 dp allows the spring to settle, but not a push.
        if (frameRect.width > 0 && frameRect.right > width - 30 * (frameRect.width / 34f)) target = frameRect
    }

    private fun note(text: String) = AppLog.writeOut("[Kontowechsel] $text")

    /**
     * Tap on an account: `from` is the frame of its profile picture, `area` the colour under it in
     * the card (it covers the spot on the still, since the picture is already flying).
     */
    fun start(app: SwiftlyApplication, identifier: String, name: String, image: String?, from: Rect, area: Color,
                density: Float, calm: Boolean) {
        if (waits) { note("zweiter Tipp ignoriert"); return }
        runCount++
        val myOwn = runCount
        waits = true
        switchTo = { app.switchAccount(identifier) }
        app.applicationRun.launch {
            val beginning = System.nanoTime()
            val stillImage = runCatching { screen?.toImageBitmap() }.getOrNull()
            targetTap = target
            val curve = if (!calm && from.width > 0 && target.width > 0) runCatching {
                Curve(Kern.accountSwitchCurve((from.center.x / density).toDouble(), (from.center.y / density).toDouble(),
                    (from.width / density).toDouble(), (target.center.x / density).toDouble(), (target.center.y / density).toDouble(),
                    (target.width / density).toDouble()))
            }.getOrNull() else null
            stage = Stage(stillImage, from.takeIf { curve != null }?.inflate(3 * density), area, curve, name, image,
                            beginning, calm, myOwn)
            if (curve != null) transition = Transition(identifier)
            note("1: Tipp, Flug ${if (curve == null) "aus" else "an"}, Standbild in ${(System.nanoTime() - beginning) / 1_000_000} ms")
            // One frame later: under the still the stack jumps back before anything moves.
            // Not `withFrameNanos`: the application scope is not a Compose scope and has no
            // `MonotonicFrameClock`, so the app crashed right at the account switch. The Choreographer
            // gives the same "one frame later" without Compose.
            nextImage()
            back++
            note("1b: Stapel leer (unter dem Standbild)")
            fun applies() = runCount == myOwn
            suspend fun until(t: Double) { delay(((t - (System.nanoTime() - beginning) / 1e9) * 1000).toLong().coerceAtLeast(0)) }
            until(curve?.change ?: (if (calm) 0.15 else 0.45))
            if (!applies()) return@launch
            switchRun()
            if (curve != null) {
                until(curve.swap)
                if (!applies()) return@launch
                val e = curve.status(curve.swap); val d = density
                note("MESSEN Tausch: Bild Mitte ${e.first * d}/${e.second * d} Groesse ${e.third * d} px, echtes Ziel ${target} (${target.width}x${target.height}), beim Tipp ${targetTap}")
                note("4: Bild ruht, Tausch gegen das echte (${(curve.swap * 1000).toInt()} ms nach Tipp)")
                transition = transition?.copy(replaced = true)
            }
            delay(30)
            if (!applies()) return@launch
            note("5: Reihen duerfen kommen")
            share()
            until((curve?.paintEnd ?: 0.3) + 0.1)
            if (applies()) finish()
        }
    }

    private fun switchRun() {
        val w = switchTo ?: return
        switchTo = null
        val a = System.nanoTime()
        w()
        note("2: Konto gewechselt in ${(System.nanoTime() - a) / 1_000_000} ms")
    }

    private fun share() {
        waits = false
        sharingAround = android.os.SystemClock.elapsedRealtime()
        sharing++
    }

    private fun finish() {
        stage = null
        transition = null
        if (waits) share()
    }

    /**
     * The profile page opens while the switch is still running (the profile at the top can be
     * tapped again at once): everything pending is done immediately. The account switches now, still
     * and picture go, and the home page may build its rows.
     */
    fun complete() {
        if (stage == null && !waits) return
        note("Profil geoeffnet, Rest sofort")
        runCount++
        switchRun()
        transition = transition?.copy(replaced = true)
        finish()
    }
}

/**
 * The stage above everything: the still moves away, the profile picture flies, the ring pops.
 * Sits in `MainActivity` above the main view, which rebuilds underneath. Accepts no taps; the
 * profile at the top can be tapped again at once.
 */
@Composable
fun AccountSwitchLayer() {
    val b = AccountSwitchTransition.stage ?: return
    val density = LocalDensity.current.density
    var time by remember(b.number) { mutableFloatStateOf(0f) }
    LaunchedEffect(b.number) {
        while (true) withFrameNanos { n -> time = ((n - b.start) / 1e9).toFloat().coerceAtLeast(0f) }
    }
    val distance = remember(b.number) { Animatable(0f) }
    LaunchedEffect(b.number) {
        if (b.calm) { distance.animateTo(1f, tween(200, easing = LinearEasing)); return@LaunchedEffect }
        // Like a normal back: spring 0.42, no overshoot, 80 ms after the tap.
        // (2π / 0.42)² ≈ 224.
        delay(80)
        distance.animateTo(1f, spring(dampingRatio = 1f, stiffness = 224f))
    }
    Box(Modifier.fillMaxSize()) {
        // 1. The still; on it the card colour covers the tapped picture, which is already flying.
        b.stillImage?.let { s ->
            Box(Modifier.fillMaxSize().graphicsLayer {
                if (b.calm) alpha = 1f - distance.value else translationX = distance.value * size.width
            }) {
                Image(s, contentDescription = null, contentScale = ContentScale.FillBounds, modifier = Modifier.fillMaxSize())
                b.cap?.let { d -> Canvas(Modifier.fillMaxSize()) { drawCircle(b.area, d.width / 2, d.center) } }
            }
        }
        val k = b.curve ?: return@Box
        val transition = AccountSwitchTransition.transition
        // 2. The flying picture: built once, then only moved and scaled (read at draw time).
        if (transition != null && !transition.replaced) {
            val base = (k.status(0.0).third * 1.06f)
            Box(Modifier.size(base.dp).graphicsLayer {
                val (x, y, s) = k.status(time.toDouble())
                transformOrigin = TransformOrigin(0.5f, 0.5f)
                translationX = x * density - base * density / 2
                translationY = y * density - base * density / 2
                // The header still springs on tap, so the target at landing differs from the one at the tap.
                // The difference is included until the swap so the picture lands exactly where the real one
                // stands.
                val p = (time / k.swap.toFloat()).coerceIn(0f, 1f)
                val z = AccountSwitchTransition.target; val z0 = AccountSwitchTransition.targetTap
                val corrected = z.width > 0 && z0.width > 0
                val dx = if (corrected) (z.center.x - z0.center.x) * p else 0f
                val dy = if (corrected) (z.center.y - z0.center.y) * p else 0f
                val f = if (corrected) 1f + (z.width / z0.width - 1f) * p else 1f
                translationX += dx; translationY += dy
                scaleX = s / base * f; scaleY = s / base * f
            }) { ProfileCharacter(b.name, b.image, base.dp) }
        }
        // 3. The ring, only hinted at: from landing on, at most 55 %.
        val target = k.status(k.swap)
        Canvas(Modifier.size(52.dp).graphicsLayer {
            val (m, d) = k.ring(time - k.landing)
            translationX = target.first * density - 26 * density
            translationY = target.second * density - 26 * density
            scaleX = m; scaleY = m; alpha = d
        }) { drawCircle(Theme.accent, radius = size.minDimension / 2 - 1.dp.toPx(), style = Stroke(2.dp.toPx())) }
    }
}

/**
 * The home rows come staggered when an account switch releases them (`Reihenauftritt`): each row
 * 80 ms later, spring 0.55/0.82 from 14 dp lower and 96 %, opacity linear 0.22 s. Rows that do not
 * come from a switch simply appear.
 */
fun Modifier.railEntrance(index: Int): Modifier = composed {
    val round = AccountSwitchTransition.sharing
    val freshValue = round > 0 && android.os.SystemClock.elapsedRealtime() - AccountSwitchTransition.sharingAround < 1500
    val calm = de.paulherter.swiftly.shared.motionReduced()
    val status = remember(round) { Animatable(if (freshValue) 0f else 1f) }
    val coverage = remember(round) { Animatable(if (freshValue) 0f else 1f) }
    LaunchedEffect(round) {
        if (status.value >= 1f) return@LaunchedEffect
        if (calm) { coverage.animateTo(1f, Motion.fadeReduced()); status.snapTo(1f); return@LaunchedEffect }
        delay(80L * index)
        launch { coverage.animateTo(1f, tween(220, easing = LinearEasing)) }
        // response 0.55, damping 0.82: (2π / 0.55)² ≈ 130.
        status.animateTo(1f, spring(dampingRatio = 0.82f, stiffness = 130f))
    }
    graphicsLayer {
        val l = status.value
        transformOrigin = TransformOrigin(0.5f, 0f)
        val m = 0.96f + 0.04f * l
        scaleX = m; scaleY = m
        translationY = (1f - l) * 14.dp.toPx()
        alpha = coverage.value
    }
}

/** Waits for the main thread's next frame, without a Compose clock. */
private suspend fun nextImage() = suspendCancellableCoroutine<Unit> { proceed ->
    Choreographer.getInstance().postFrameCallback { if (proceed.isActive) proceed.resume(Unit) }
}
