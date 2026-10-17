package de.paulherter.swiftly

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitTouchSlopOrCancellation
import androidx.compose.foundation.gestures.drag
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.motionReduced
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject
import kotlin.math.ceil
import kotlin.math.roundToInt

// The next episode as a card at the bottom right. Mirrors `Sources/iOS/EpisodeCardsView.swift`
// (phone) and `Sources/tvOS/TVEpisodesCard.swift` (TV), with the shared parts from
// `Sources/Shared/EpisodeCardParts.swift`. Times, springs, sizes and swipe rules come from the
// core (`EpisodeCard` in the package); `OfferingLayer` says when it stands, waits or counts.

/** The next episode as the card shows it, from the playback plan (`Kern.playbackPlanResponse`). */
data class CardsEpisode(val id: String, val name: String, val abbreviation: String, val image: String?)

/**
 * The card zooms into the picture, fixed at start (`CardsSwitch` on Apple). `beginning` and
 * `imageSince` in milliseconds (`SystemClock.elapsedRealtime`), `imageSince` counted from `beginning`.
 */
data class CardsSwitch(val episode: CardsEpisode, val beginning: Long, val imageSince: Long? = null, val failed: Boolean = false)

/**
 * Sizes and times from `Kern.episodeCard`, lengths in dp. The TV halves them (tvOS works in 1920
 * points of width, Android TV in 960 dp).
 */
data class CardsMetrics(
    val width: Float, val corner: Float, val ring: Float, val spacing: Float, val small: Float, val title: Float,
    val appearOmega: Double, val appearLag: Double, val distanceOmega: Double, val zoomOmega: Double,
    val detailsOut: Double, val swap: Double, val imageFade: Double, val offset: Float, val startMetric: Float,
    val focusMetric: Float, val clickPress: Float, val bottomSpacing: Float, val tv: Boolean,
) {
    /** Critically damped from the current state: `spring(dampingRatio = 1, stiffness = ω²)` (`EpisodeCard.spring`). */
    fun <T> spring(omega: Double): FiniteAnimationSpec<T> = spring(dampingRatio = 1f, stiffness = (omega * omega).toFloat())

    /** Height of the two lines under the card plus gap (`rows` on Apple). */
    val rows: Float get() = if (tv) spacing + small * 1.3f + 3f + title * 1.25f
                             else spacing + ceil(small * 1.2f) + 3f + ceil(title * 1.2f)

    companion object {
        fun read(json: String, tv: Boolean): CardsMetrics = JSONObject(json).let { o ->
            val m = if (tv) 0.5f else 1f
            fun l(k: String) = (o.getDouble(k) * m).toFloat()
            CardsMetrics(l("breite"), l("ecke"), l("ring"), l("abstand"), l("klein"), l("titel"),
                o.getDouble("erscheinenOmega"), o.getDouble("erscheinenVerzug"), o.getDouble("wegOmega"), o.getDouble("zoomOmega"),
                o.getDouble("angabenAus"), o.getDouble("tausch"), o.getDouble("bildBlende"), l("versatz"),
                o.getDouble("startmass").toFloat(), o.getDouble("fokusmass").toFloat(), o.getDouble("klickDruck").toFloat(),
                l("untenAbstand"), tv)
        }
    }
}

/**
 * The card with lines, ring, gradient and zoom, phone and TV. `card` is its frame in px,
 * computed from the area (`BoxWithConstraints`). On TV `focus` carries the card and a click
 * starts; on the phone a tap starts, the X and a swipe dismiss.
 */
@Composable
fun EpisodeCard(mediaWork: PlayItem, present: Boolean, card: (width: Float, height: Float, density: Float) -> Rect,
                focus: FocusRequester? = null, cancel: () -> Unit) {
    val m = mediaWork.cardsMetrics
    val change = mediaWork.cardsSwitch
    val episode = change?.episode ?: mediaWork.plan?.nextEpisode ?: return
    val calm = motionReduced()
    val detailsPresent = present && change == null
    val run = androidx.compose.runtime.rememberCoroutineScope()

    val fadeInValue = remember { Animatable(0f) }
    val zoom = remember { Animatable(0f) }
    val image = remember { Animatable(1f) }
    var drag by remember { mutableStateOf(Offset.Zero) }

    // In with a delay (not during the zoom), out at once; springs from the current state.
    LaunchedEffect(present) {
        if (present) {
            if (mediaWork.cardsSwitch == null && !calm) delay((m.appearLag * 1000).toLong())
            fadeInValue.animateTo(1f, if (calm) Motion.fadeReduced() else m.spring(m.appearOmega))
        } else {
            fadeInValue.animateTo(0f, if (calm) Motion.fadeReduced() else m.spring(m.distanceOmega))
            // Gone is gone: forget the swipe once the card has left.
            drag = Offset.Zero
        }
    }
    // The zoom to the full picture; if the switch fails, back to the corner and out.
    LaunchedEffect(change != null, change?.failed) {
        val w = mediaWork.cardsSwitch ?: return@LaunchedEffect
        if (w.failed) {
            AppLog.writeOut("[Karte] Wechsel gescheitert, zurück")
            zoom.animateTo(0f, if (calm) Motion.fadeReduced() else m.spring(m.distanceOmega))
            fadeInValue.snapTo(0f); image.snapTo(1f)
            mediaWork.cardCleanUp()
        } else {
            drag = Offset.Zero
            zoom.animateTo(1f, if (calm) Motion.fadeReduced() else m.spring(m.zoomOmega))
        }
    }
    // The first frame of the new episode is up: the preview fades out, at the earliest from the swap.
    LaunchedEffect(change?.imageSince) {
        val w = mediaWork.cardsSwitch ?: return@LaunchedEffect
        val imageSince = w.imageSince ?: return@LaunchedEffect
        val wait = Kern.episodeCardFadeFrom(imageSince / 1000.0) * 1000 - (android.os.SystemClock.elapsedRealtime() - w.beginning)
        if (wait > 0) delay(wait.toLong())
        image.animateTo(0f, if (calm) Motion.fadeReduced() else tween((m.imageFade * 1000).toInt(), easing = EaseInOut))
        AppLog.writeOut("[Karte] Ende nach ${android.os.SystemClock.elapsedRealtime() - w.beginning} ms")
        // Back without motion, like `withTransaction(still)` on Apple; otherwise the card flashed in the corner.
        fadeInValue.snapTo(0f); zoom.snapTo(0f); image.snapTo(1f)
        mediaWork.cardCleanUp()
    }

    val details by animateFloatAsState(if (detailsPresent) 1f else 0f,
        if (calm) Motion.fadeReduced() else tween((m.detailsOut * 1000).toInt(), easing = EaseOut), label = "angaben")
    val scrim by animateFloatAsState(if (detailsPresent && present) 1f else 0f,
        if (calm) Motion.fadeReduced() else tween((m.detailsOut * 1000).toInt(), easing = EaseOut), label = "kartenschleier")
    val fillContent = cardsFill(mediaWork, detailsPresent)

    /** The end of a swipe: far enough or with momentum, the card is gone; otherwise it springs back. */
    fun swipeEnd(distance: Offset, momentum: Offset, density: Float) {
        // How far the momentum would carry it (`predictedEndTranslation`): a quarter of the velocity.
        val sx = (distance.x + momentum.x * 0.25f) / density
        val sy = (distance.y + momentum.y * 0.25f) / density
        if (Kern.episodeCardSwipedAway((distance.x / density).toDouble(), (distance.y / density).toDouble(), sx.toDouble(), sy.toDouble())) {
            AppLog.writeOut("[Karte] weggewischt")
            cancel()
        } else run.launch {
            val start = drag
            val back = Animatable(1f)
            back.animateTo(0f, if (calm) Motion.fadeReduced() else m.spring(m.distanceOmega)) { drag = start * value }
        }
    }

    val densityNow = LocalDensity.current.density
    val frameRect = remember { arrayOf(Rect.Zero) }
    BoxWithConstraints(Modifier.fillMaxSize().then(if (focus == null && detailsPresent) Modifier.pointerInput(Unit) {
        // Swiping away to the right or down: only on the card, measured on the resting box, not on the
        // card following the finger (`Folgenkarte.gezogen/weggewischt`).
        val tempo = VelocityTracker()
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            if (!frameRect[0].contains(down.position)) return@awaitEachGesture
            var distance = Offset.Zero
            tempo.resetTracking()
            tempo.addPosition(down.uptimeMillis, down.position)
            fun setDown() {
                drag = Offset((Kern.episodeCardDragged((distance.x / density).toDouble()) * density).toFloat(),
                                (Kern.episodeCardDragged((distance.y / density).toDouble()) * density).toFloat())
            }
            val start = awaitTouchSlopOrCancellation(down.id) { c, over -> c.consume(); distance += over } ?: return@awaitEachGesture
            setDown()
            val done = drag(start.id) { c ->
                distance += c.positionChange()
                c.consume()
                tempo.addPosition(c.uptimeMillis, c.position)
                setDown()
            }
            if (done) { val v = tempo.calculateVelocity(); swipeEnd(distance, Offset(v.x, v.y), densityNow) }
            else drag = Offset.Zero
        }
    } else Modifier)) {
        val density = LocalDensity.current.density
        val w = constraints.maxWidth.toFloat()
        val h = constraints.maxHeight.toFloat()
        val k = card(w, h, density)
        frameRect[0] = k
        // The gradient at the bottom right keeps the text legible on any credits. It only fades.
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = scrim }.drawBehind {
            withTransform({ scale(size.width, size.height, pivot = Offset.Zero) }) {
                drawRect(Brush.radialGradient(0f to Color.Black.copy(alpha = 0.78f), 0.7f to Color.Transparent,
                    center = Offset(0.88f, 0.92f), radius = 0.75f), size = Size(1f, 1f))
            }
        })

        // Only the card moves in and out: from the right, from 94 % size, with opacity.
        Box(Modifier.fillMaxSize().graphicsLayer {
            val e = fadeInValue.value
            val z = zoom.value
            alpha = e
            val s = if (z > 0f) 1f else m.startMetric + (1f - m.startMetric) * e
            scaleX = s; scaleY = s
            transformOrigin = TransformOrigin(k.center.x / w.coerceAtLeast(1f), k.center.y / h.coerceAtLeast(1f))
            val distance = if (calm) 0f else (1f - e) * m.offset * (if (m.tv) 2f else 1f) * density
            translationX = distance + (if (z > 0f) 0f else drag.x)
            translationY = if (z > 0f) 0f else drag.y
        }) {
            val z = zoom.value
            val r = Rect(k.left * (1 - z), k.top * (1 - z), k.right + (w - k.right) * z, k.bottom + (h - k.bottom) * z)
            CardImage(mediaWork, episode, m, r, 1f - z, details, image.value, fillContent, change == null && present, focus)
            val d = LocalDensity.current
            // Two lines under the card: "S6 · E11 ... in 5 s", below it the title.
            Column(Modifier.offset { IntOffset(k.left.roundToInt(), (k.bottom + m.spacing * density + (1f - details) * (if (calm) 0f else (if (m.tv) 12f else 6f)) * density).roundToInt()) }
                    .width(with(d) { k.width.toDp() }).graphicsLayer { alpha = details },
                verticalArrangement = Arrangement.spacedBy(if (m.tv) 6.dp else 3.dp)) {
                val small = TextStyle(fontSize = m.small.sp, fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum")
                Row(horizontalArrangement = Arrangement.spacedBy(if (m.tv) 24.dp else 12.dp)) {
                    Text(episode.abbreviation, style = small, color = Theme.fontVeryQuiet, maxLines = 1)
                    Spacer(Modifier.weight(1f))
                    Text(translated("in %lld s", mediaWork.countdownRest), style = small, color = Theme.fontVeryQuiet, maxLines = 1)
                }
                Text(episode.name, style = TextStyle(fontSize = m.title.sp, fontWeight = FontWeight.SemiBold), color = Theme.font,
                     maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            // The round X at the card corner: card gone, countdown off, the credits keep playing.
            if (focus == null) {
                Box(Modifier.offset { IntOffset((k.right - 18.dp.toPx() - 22.dp.toPx()).roundToInt(), (k.top + 18.dp.toPx() - 22.dp.toPx()).roundToInt()) }
                        .size(44.dp).graphicsLayer { alpha = details }
                        .then(if (detailsPresent) Modifier.clickable(remember { MutableInteractionSource() }, null) {
                            AppLog.writeOut("[Karte] × gedrückt"); cancel()
                        }.semantics { contentDescription = translated("Karte schließen") } else Modifier),
                    contentAlignment = Alignment.Center) {
                    Box(Modifier.size(24.dp).clip(CircleShape).background(Theme.area.copy(alpha = 0.85f)), contentAlignment = Alignment.Center) {
                        Symbol(Glyph.Cross, 11.dp, color = Theme.font, strength = Strength.Semibold)
                    }
                }
            }
        }
    }
}

/** The card itself: preview on black; ring, corner and shadow fade with the zoom (`CardsShape`). */
@Composable
private fun CardImage(mediaWork: PlayItem, episode: CardsEpisode, m: CardsMetrics, r: Rect, rest: Float, details: Float,
                       image: Float, fillContent: Float, operable: Boolean, focus: FocusRequester?) {
    val d = LocalDensity.current
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val focused by source.collectIsFocusedAsState()
    val calm = motionReduced()
    // TV: the focused card rises by 6 %, a click presses it in; not during the zoom.
    val hoist = if (focus != null && focused && rest >= 1f) m.focusMetric else 1f
    val press = if (pressed) 1f - m.clickPress else 1f
    val mass by animateFloatAsState(if (calm) 1f else hoist * press,
        if (focus != null) m.spring(m.appearOmega) else Motion.toggle(), label = "kartenmass")
    val corner = (m.corner * rest).dp
    Box(Modifier.offset { IntOffset(r.left.roundToInt(), r.top.roundToInt()) }
            .size(with(d) { r.width.toDp() }, with(d) { r.height.toDp() })
            .graphicsLayer { scaleX = mass; scaleY = mass; alpha = if (focus == null && pressed) 0.85f else 1f }
            .shadow((17f * rest).dp, RoundedCornerShape(corner), ambientColor = Color.Black, spotColor = Color.Black.copy(alpha = 0.6f * rest))
            .clip(RoundedCornerShape(corner)).background(Color.Black)
            .then(if (focus != null && operable) Modifier.focusRequester(focus) else Modifier)
            .semantics {
                contentDescription = translated("Nächste Folge abspielen: %@", episode.abbreviation)
                stateDescription = translated("Startet in %lld Sekunden", mediaWork.countdownRest)
                if (focus == null) customActions = listOf(CustomAccessibilityAction(translated("Karte schließen")) { mediaWork.offeringClose(); true })
            }
            .clickable(source, null, enabled = operable) { mediaWork.cardStart() },
        contentAlignment = Alignment.Center) {
        AsyncImage(model = episode.image, contentDescription = null, contentScale = ContentScale.Crop,
                   modifier = Modifier.fillMaxSize().graphicsLayer { alpha = image })
        CountdownRing(fillContent, m.ring.dp, Modifier.graphicsLayer { alpha = details })
    }
}

/**
 * The countdown ring (`CountdownRing`): disc black 50 %, track white 18 %, the fraction in
 * accent, the play icon inside. Sizes in proportion to the design (56 grid).
 */
@Composable
fun CountdownRing(share: Float, throughMeasure: Dp, modifier: Modifier = Modifier) {
    Box(modifier.size(throughMeasure), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val stroke = size.minDimension * 3f / 56f
            val radius = size.minDimension / 2f - stroke
            drawCircle(Color.Black.copy(alpha = 0.5f))
            drawCircle(Color.White.copy(alpha = 0.18f), radius = radius, style = Stroke(stroke))
            drawArc(Theme.accent, -90f, 360f * share.coerceIn(0f, 1f), useCenter = false,
                    topLeft = Offset(center.x - radius, center.y - radius), size = Size(radius * 2, radius * 2),
                    style = Stroke(stroke, cap = StrokeCap.Round))
        }
        Symbol(Glyph.Play, throughMeasure * 0.3f, Modifier.offset(x = throughMeasure * 0.03f), color = Theme.font)
    }
}

/**
 * The card's fill as one continuous motion (`FillClock`), and after a jump from the start
 * (`fillNew`). During the zoom it stays where it was.
 */
@Composable
fun cardsFill(mediaWork: PlayItem, counts: Boolean): Float {
    val share = mediaWork.countdown.takeIf { mediaWork.overlay == "karte" }
    val value = remember { Animatable(0f) }
    LaunchedEffect(share != null, mediaWork.running, mediaWork.atFileEnd, counts, mediaWork.fillNew) {
        if (!counts) { value.stop(); return@LaunchedEffect }
        if (share == null) { value.snapTo(0f); return@LaunchedEffect }
        val since = if (mediaWork.fillNew > 0 && share < value.value) share.toFloat() else maxOf(value.value, share.toFloat())
        value.snapTo(since)
        if (!mediaWork.running && !mediaWork.atFileEnd) return@LaunchedEffect
        val rest = ((1f - since) * mediaWork.countdownLength * 1000).toInt().coerceAtLeast(1)
        value.animateTo(1f, tween(rest, easing = androidx.compose.animation.core.LinearEasing))
    }
    return value.value
}
