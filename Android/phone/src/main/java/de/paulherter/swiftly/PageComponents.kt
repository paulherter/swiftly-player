package de.paulherter.swiftly

import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.drawscope.DrawScope
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.findRootCoordinates
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.SecondaryButton
import de.paulherter.swiftly.shared.QuietButton
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.motionReduced
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.State
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.animation.core.spring
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import androidx.compose.ui.platform.LocalView
import android.view.HapticFeedbackConstants
import android.os.Build
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.translated

/**
 * The amount of the scope switch; `areaContent()` reads it. Only the content grows, not the
 * header, which stays fixed like the bar at the bottom.
 */
val LocalSectionMetric = staticCompositionLocalOf<Animatable<Float, AnimationVector1D>?> { null }

/**
 * `areaContent()`: anchored at the top (`scaleEffect(anchor: .top)`). Anchored at the bottom,
 * the top edge moved, and that is where the header gradient sits; the bare ground would gap
 * below it for two tenths of a second.
 */
fun Modifier.areaContent(): Modifier = composed {
    val mass = LocalSectionMetric.current
    if (mass == null) Modifier
    else Modifier.graphicsLayer { val m = mass.value; scaleX = m; scaleY = m; transformOrigin = TransformOrigin(0.5f, 0f) }
}

/**
 * Fade in once, the first time it appears (`PosterTile.present`). Remembered across the scope switch:
 * on iOS the scope stays in place and does not fade in again.
 */
fun Modifier.reveal(): Modifier = composed {
    var present by rememberSaveable { mutableStateOf(false) }
    val coverage = remember { Animatable(if (present) 1f else 0f) }
    LaunchedEffect(Unit) { if (!present) { coverage.animateTo(1f, Motion.reveal()); present = true } }
    Modifier.graphicsLayer { alpha = coverage.value }
}

/**
 * `PressRow`: rows darken, buttons shrink. The press applies instantly; release fades over
 * 120 ms. A duration on the finger feels like delay.
 */
fun Modifier.pressRow(perform: () -> Unit): Modifier = composed {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val scrim = remember { Animatable(0f) }
    LaunchedEffect(pressed) { if (pressed) scrim.snapTo(1f) else scrim.animateTo(0f, Motion.release()) }
    Modifier.drawBehind { drawRect(Color.White.copy(alpha = 0.06f * scrim.value)) }.clickable(source, null, onClick = perform)
}

/**
 * `Theme.PressText`: press shown by alpha only, for text directly on image color: 60 % while
 * pressed, release fades as everywhere.
 */
fun Modifier.pressText(perform: () -> Unit): Modifier = composed {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val press = remember { Animatable(0f) }
    LaunchedEffect(pressed) { if (pressed) press.snapTo(1f) else press.animateTo(0f, Motion.release()) }
    graphicsLayer { alpha = 1f - 0.4f * press.value }.clickable(source, null, onClick = perform)
}

/**
 * Seen only gets darker (`Gesehenhaken`, `colorMultiply(0.45)`): multiplied rather than
 * transparent, so on a page with image color no color shows through the still image.
 */
val WATCHED_DIM = androidx.compose.ui.graphics.ColorFilter.tint(Color(0.45f, 0.45f, 0.45f), androidx.compose.ui.graphics.BlendMode.Modulate)

/** `pressRow` with long press: the context menu of a row on iOS (`.contextMenu`). */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
fun Modifier.pressRowLong(lengthy: () -> Unit, perform: () -> Unit): Modifier = composed {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val scrim = remember { Animatable(0f) }
    val jerk = rememberJerk()
    LaunchedEffect(pressed) { if (pressed) scrim.snapTo(1f) else scrim.animateTo(0f, Motion.release()) }
    Modifier.drawBehind { drawRect(Color.White.copy(alpha = 0.06f * scrim.value)) }
        .combinedClickable(source, null, onLongClick = { jerk(Jerk.Medium); lengthy() }, onClick = perform)
}

enum class Jerk { Lightweight, Medium, Success }

/** `Theme.jerk`: on press, never only on the server's answer; a late tick belongs to nothing. */
@Composable
fun rememberJerk(): (Jerk) -> Unit {
    val viewRef = LocalView.current
    return remember(viewRef) {
        { r ->
            viewRef.performHapticFeedback(when (r) {
                Jerk.Lightweight -> HapticFeedbackConstants.CLOCK_TICK
                Jerk.Medium -> HapticFeedbackConstants.CONTEXT_CLICK
                Jerk.Success -> if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.CONTEXT_CLICK
            })
        }
    }
}

/**
 * Mirrors `Theme.PressButton`: every button gives way. Scale 0.97 and alpha 0.85, the press at
 * once, release 0.12 s `easeOut`. No ripple: that is Material, not this app. With reduced
 * motion only the alpha remains.
 */
fun Modifier.tapOn(perform: () -> Unit): Modifier = composed {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val press = remember { Animatable(0f) }
    LaunchedEffect(pressed) { if (pressed) press.snapTo(1f) else press.animateTo(0f, Motion.release()) }
    val calm = motionReduced()
    graphicsLayer {
        val d = press.value
        if (!calm) { val m = 1f - (1f - Motion.PressMetric) * d; scaleX = m; scaleY = m }
        alpha = 1f - 0.15f * d
    }.clickable(source, null, onClick = perform)
}

/** A tap with no feedback at all, for surfaces that are not buttons (scrim, image area). */
fun Modifier.onTap(perform: () -> Unit): Modifier = composed {
    clickable(remember { MutableInteractionSource() }, null, onClick = perform)
}

/**
 * Header and content in one measuring pass, the counterpart of `.safeAreaInset(edge: .top)`.
 *
 * Both pages used to measure their header with `onSizeChanged` and pass the height as top
 * padding to the list. That needs a drawn frame: on a scope switch the page is rebuilt, the
 * height was zero in the first frame, the content sat at the top and jumped down one frame
 * later, a flicker on every switch. Here the header is measured first and the content built
 * with its height in the same pass. The header is drawn last, so above the content that scrolls
 * under it.
 */
@Composable
fun HeaderAndContent(header: @Composable () -> Unit, content: @Composable (headerHeight: Dp) -> Unit) {
    SubcomposeLayout(Modifier.fillMaxSize()) { limits ->
        val headerParts = subcompose("kopf", header).map { it.measure(limits.copy(minWidth = 0, minHeight = 0)) }
        val height = headerParts.maxOfOrNull { it.height } ?: 0
        val contentParts = subcompose("inhalt") { content(height.toDp()) }.map { it.measure(limits) }
        layout(limits.maxWidth, limits.maxHeight) {
            contentParts.forEach { it.place(0, 0) }
            headerParts.forEach { it.place(0, 0) }
        }
    }
}

/**
 * Mirrors `HeaderHistory` in `Style.swift`: dark, no glow. Strong at the top, soft at the bottom,
 * nine stops so the falloff has no kink; it extends 17 below the header. A colored glow no
 * longer exists; it was dropped on purpose.
 */
fun DrawScope.headerGradient(coverage: Float) {
    if (coverage <= 0f) return
    val g = Theme.reason
    drawRect(Brush.verticalGradient(
        0f to g.copy(alpha = 0.98f), 0.30f to g.copy(alpha = 0.94f), 0.48f to g.copy(alpha = 0.85f),
        0.62f to g.copy(alpha = 0.70f), 0.73f to g.copy(alpha = 0.52f), 0.82f to g.copy(alpha = 0.34f),
        0.89f to g.copy(alpha = 0.19f), 0.95f to g.copy(alpha = 0.09f), 1f to g.copy(alpha = 0f),
        startY = 0f, endY = size.height + 17.dp.toPx()),
        size = Size(size.width, size.height + 17.dp.toPx()), alpha = coverage)
}

/**
 * Mirrors `BlurHeader(offset:)` in `Style.swift`: the header of a root page. The content
 * scrolls underneath, and the `headerGradient` only fades in once something is actually below it:
 * over the first 30 points of travel. At rest it covers nothing and would be pure decoration.
 * No hairline: the gradient fades into the ground and has no edge to hide.
 *
 * Side margin 18, bottom 12: the header ends where the scroll area starts.
 */
@Composable
fun RootHeader(offset: () -> Float, modifier: Modifier = Modifier, margin: Boolean = true, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth()
            .drawBehind { headerGradient((offset() / 30f).coerceIn(0f, 1f)) }
            .statusBarsPadding()
            .then(if (margin) Modifier.padding(horizontal = Theme.edgeSpacing) else Modifier)
            .padding(bottom = 12.dp), content = content)
}

/**
 * Mirrors `ValueRail` in `Style.swift`: "Alle" and "A-Z" go away while scrolling instead of
 * scrolling along, by alpha only, never by height.
 *
 * On the iPhone this one element took four attempts: the row sits in the header, the header
 * determines where the scroll area starts, and a height change changes the offset that drives
 * it, a feedback loop that produces stuck frames and jumping. So it keeps its place and fades
 * over 44 points of travel (30 pill height + 14 spacing). Half closed, it no longer accepts
 * taps: a sheet opened from a disappearing row is a trap.
 */
@Composable
fun ValueRail(offset: () -> Float, modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    val toward by remember { derivedStateOf { offset() / Theme.valueRailsDistance.value >= 0.5f } }
    Row(modifier.fillMaxWidth().padding(top = 14.dp)
            .graphicsLayer { alpha = 1f - (offset() / Theme.valueRailsDistance.value).coerceIn(0f, 1f) }
            .then(if (toward) Modifier.clearAndSetSemantics {}.pointerInput(Unit) {
                awaitPointerEventScope { while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() } }
            } else Modifier),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp), content = content)
}

/** Mirrors `Zaehlmarke`: 13 Medium, tabular digits, `schriftSehrLeise`. */
@Composable
fun CountMark(count: Int) {
    Text(java.text.NumberFormat.getInstance().format(count), style = Theme.tile.copy(fontFeatureSettings = "tnum"),
         color = Theme.fontVeryQuiet, modifier = Modifier.semantics { contentDescription = translated("%lld Titel", count) })
}

/** Mirrors `HeaderTargets` in `Style.swift`: watchlist and profile, 44 each, the same on every main page. */
@Composable
fun HeaderTargets(app: SwiftlyApplication, open: (Destination) -> Unit, front: @Composable () -> Unit = {}) {
    // `vorn`: what only one page has (Edit on Downloads); left of the rest because it comes and goes.
    Row(verticalAlignment = Alignment.CenterVertically) {
        TakeoverCharacter(app)
        front()
        // Filled, but not a state: here the bookmark is a destination, not a marker.
        Box(Modifier.size(44.dp).tapOn { open(Destination("merkliste", translated("Merkliste"), "Merkliste")) },
            contentAlignment = Alignment.Center) {
            Symbol(Glyph.BookmarkFilled, 20.dp, color = Theme.font, description = translated("Merkliste"))
        }
        // `ProfileTarget`: the 34 icon in a 44 hit area, shifted 7 outward so the circle sits flush at the
                // edge, not the hit area.
                // The account switch flies here (`AccountSwitchTransition.targetReport`); while the new profile image
                // is in transit, there is none yet.
        val transition = AccountSwitchTransition.transition
        Box(Modifier.offset(x = 7.dp).size(44.dp).tapOn { open(Destination("profil", translated("Profil"), "Profil")) }, contentAlignment = Alignment.Center) {
            Box(Modifier.size(34.dp)
                    .onGloballyPositioned { AccountSwitchTransition.targetReport(it.boundsInRoot(), (it.findRootCoordinates().size.width).toFloat()) }
                    .graphicsLayer { alpha = if (transition != null && !transition.replaced) 0f else 1f }) {
                ProfileImage(app, 34.dp)
            }
        }
    }
}

/** The account's image, otherwise the letter; only once it is clear none is coming (`ProfileCharacter`). */
@Composable
fun ProfileImage(app: SwiftlyApplication, size: Dp) {
    SubcomposeAsyncImage(
        model = app.kern.userImage((size.value * 3).toLong()).orElse(null), contentDescription = app.username(),
        contentScale = ContentScale.Crop,
        modifier = Modifier.size(size).clip(CircleShape),
        error = {
            Box(Modifier.fillMaxSize().background(Theme.raised), contentAlignment = Alignment.Center) {
                // Letter = size x 0.38 semibold (`ProfileCharacter`).
                Text(app.username().take(1).uppercase(), color = Theme.font,
                     style = TextStyle(fontSize = (size.value * 0.38f).sp, fontWeight = FontWeight.SemiBold))
            }
        }
    )
}

/**
 * The bar at the bottom of the image: flush with the bottom edge, 4 high, square.
 *
 * The track is white 30 %, not 25: read as a dark track means "something is missing here", a
 * light one means "this is the whole length, and this far you are". 30 is allowed and wanted
 * as a surface; as a text color the same value would be forbidden (2.67:1).
 */
@Composable
fun ProgressBar(share: Double, modifier: Modifier = Modifier,
                       /**
                                               * Capsule where it stands free in a row, as in the download list. On a tile it
                                               * stays square: there it forms the edge of the image. The filled part is itself
                                               * a capsule, otherwise it ends straight on the inside.
                                               */
                       round: Boolean = false) {
    val form = if (round) CircleShape else RectangleShape
    Box(modifier.fillMaxWidth().height(4.dp).clip(form).background(Color.White.copy(alpha = 0.30f))) {
        Box(Modifier.fillMaxHeight().fillMaxWidth(share.toFloat().coerceIn(0f, 1f)).clip(form).background(Theme.accent))
    }
}

/** Mirrors `ValuePill` in `Style.swift`: shows the value, not the options. */
@Composable
fun ValuePill(symbol: Glyph, text: String, perform: () -> Unit) {
    // Fill without border, and `area` instead of `erhoeht`. They were the only buttons in the app
        // with an outline and looked like a foreign kind. `erhoeht` is what lies on a surface; the
        // pill lies on the page. `minHeight` so growing system text does not clip the label.
    Row(Modifier.heightIn(min = Theme.pillsHeight).clip(CircleShape).background(Theme.area)
            .tapOn(perform).padding(horizontal = 11.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Symbol(symbol, 12.dp, color = Theme.fontQuiet, strength = Strength.Medium)
        Text(text, style = Theme.tile, color = Theme.font)
    }
}

/**
 * The watched state on a thumbnail. Mirrors `Gesehenhaken` in `Components.swift`: check mark on a
 * dark disc at the top right, in the episode list and the download list. The image surface
 * itself darkens (0.45). 0.78 like every other dark disc on an image.
 */
@Composable
fun BoxScope.WatchedCheckmark() {
    Box(Modifier.align(Alignment.TopEnd).padding(5.dp).size(18.dp).clip(CircleShape).background(Theme.reason.copy(alpha = 0.78f)),
        contentAlignment = Alignment.Center) {
        Symbol(Glyph.Checkmark, 10.dp, color = Theme.font, strength = Strength.Semibold, description = translated("Gesehen"))
    }
}

/** Mirrors `Kachelplakette` in `Style.swift`: check mark, "3 offen" or "2 Staffeln". The rule is in `DisplayRules.tileMark`. */
@Composable
fun TileBadge(mark: String, figure: Int, modifier: Modifier = Modifier) {
    val wording = when (mark) {
        "offen" -> translated("%lld offen", figure)
        "staffeln" -> if (figure == 1) translated("1 Staffel") else translated("%lld Staffeln", figure)
        else -> null
    }
    val form = RoundedCornerShape(9.dp)
    Row(modifier.padding(6.dp).clip(form).background(Theme.reason.copy(alpha = 0.78f)).border(1.dp, Theme.margin, form)
            .padding(horizontal = if (wording == null) 5.dp else 6.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        if (mark == "gesehen") Symbol(Glyph.Checkmark, 10.dp, color = Theme.font, strength = Strength.Semibold)
        wording?.let { Text(it, style = Theme.badge, color = Theme.font) }
    }
}

/**
 * One pulse for all placeholders: one clock, not thirty. With a clock per field, placeholders
 * loaded later breathed against those already showing (iOS dropped that for the same reason).
 */
val LocalLoadingPulse = compositionLocalOf<State<Float>?> { null }

@Composable
fun LoadingPulse(): State<Float> {
    // "Reduce motion" does not stop an infinite loop. With animations disabled Android sets the
        // duration of all Compose animations to zero. For a one-shot motion that is right; a loop with
        // duration 0 just keeps pulsing harshly. So this asks the way `Theme.motionReduced` does on
        // Apple, and the placeholder stays still at full alpha.
    if (motionReduced()) return remember { mutableFloatStateOf(1f) }
    return rememberInfiniteTransition(label = "laden").animateFloat(
        0.5f, 1f, infiniteRepeatable(tween(900, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "hell")
}

/** Mirrors `Ladefeld`: breathes between half and full alpha, 0.9 s, on the shared clock. */
@Composable
fun LoadField(modifier: Modifier, corner: Dp = Theme.cornerTile) {
    val pulse = LocalLoadingPulse.current
    Box(modifier.graphicsLayer { alpha = pulse?.value ?: 0.75f }.clip(RoundedCornerShape(corner)).background(Theme.area))
}

/** Mirrors `TilePlaceholder`: 2:3 poster, two lines below. */
@Composable
fun TilePlaceholder() {
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        LoadField(Modifier.fillMaxWidth().aspectRatio(2f / 3f))
        Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
            LoadField(Modifier.fillMaxWidth().height(11.dp), 3.dp)
            LoadField(Modifier.size(42.dp, 9.dp), 3.dp)
        }
    }
}

/**
 * Mirrors `Leerzustand` in `Sources/Shared/Style.swift`.
 *
 * The spacing comes from that source: icon 44 in a circle of 78, 22, heading 20 semibold with
 * `lockRail`, 7, text 15 `schriftLeise` at most 262 wide, 24, main button, 16, quiet
 * button. Buttons stacked.
 *
 * - The circle has no border: no drawn edges.
 * - The icon is 44 for both states, otherwise they are two different empty states.
 * - Heading 20 and text 15; 19 and 14 are on no scale.
 * - The main button is not an accent capsule: the accent never carries a surface, and the one
 *   filled surface on the page is white with dark text. It is the shared `Hauptknopf`, only as
 *   wide as its text: a failure is not a form.
 *
 * `loads` makes the icon breathe, for "trying right now". No spinner: the icon keeps saying what
 * this is about. With reduced motion the breathing is dropped; Android only zeroes one-shot
 * animations, an infinite loop would keep running.
 *
 * An empty state gets a button only if there is something to do.
 */
@Composable
fun EmptyState(symbol: Glyph, headerLine: String, text: String, loads: Boolean = false,
                primaryButton: Pair<String, () -> Unit>? = null, quietButton: Pair<String, () -> Unit>? = null) {
    // Appears with alpha and from 0.97: `.opacity.combined(with: .scale(0.97))`.
    val on = remember { Animatable(0f) }
    LaunchedEffect(Unit) { on.animateTo(1f, Motion.reveal()) }
    val calm = motionReduced()
    val breath = if (loads && !calm) LocalLoadingPulse.current?.value ?: 1f else 1f
    Column(Modifier.fillMaxSize().graphicsLayer { alpha = on.value; val m = 0.97f + 0.03f * on.value; scaleX = m; scaleY = m }
               .padding(horizontal = 34.dp),
           horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.Center) {
        Box(Modifier.size(Theme.circleEmpty).clip(CircleShape).background(Theme.area),
            contentAlignment = Alignment.Center) {
            Symbol(symbol, 44.dp, Modifier.graphicsLayer { alpha = breath }, color = Theme.fontQuiet)
        }
        Text(headerLine, style = Theme.rail, color = Theme.font, modifier = Modifier.padding(top = 22.dp, bottom = 7.dp))
        Text(text, style = Theme.body.copy(lineHeight = 21.sp, textAlign = TextAlign.Center),
             color = Theme.fontQuiet, modifier = Modifier.widthIn(max = 262.dp))
        primaryButton?.let { (title, perform) ->
            PrimaryButton(title, stretches = false, modifier = Modifier.padding(top = 24.dp), action = perform)
        }
        quietButton?.let { (title, perform) ->
            QuietButton(title, modifier = Modifier.padding(top = if (primaryButton == null) 24.dp else 16.dp), action = perform)
        }
    }
}

/**
 * A failed section inside a page. Mirrors `DisturbHint` in `Sources/Shared/Style.swift`.
 *
 * Counterpart of the full-page `Leerzustand`: that one says "nothing here", this one says "I
 * don't know, the server did not answer". A server error must not appear as "nothing here",
 * and where only the episode list or the similar row did not answer, the rest of the page is
 * there.
 *
 * The wording is the same as in the empty state: the same two catalog keys, set smaller since
 * the page header is already there. A second wording for the same situation would be a second
 * answer to the same question.
 *
 * `address`: who did not answer. Without it, the app's own Jellyfin; on a Seerr page it is
 * Seerr, since a wrong address would send the troubleshooting the wrong way.
 *
 * `erneut`: only where there is something to repeat. If the section reloads with the whole
 * page, the button is absent: one that loads the page twice is worse than none.
 *
 * `spacingTop` is 40 below an empty hint and 0 below a row heading that brings its own spacing.
 */
@Composable
fun DisturbHint(address: String?, modifier: Modifier = Modifier, spacingTop: Dp = 40.dp,
                 retry: (() -> Unit)? = null) {
    Column(modifier.fillMaxWidth().padding(top = spacingTop, start = 34.dp, end = 34.dp),
           horizontalAlignment = Alignment.CenterHorizontally) {
        // The only icon in the app at 30: the size is on no scale and is taken from the source so the
                // same hint looks the same on all platforms.
        Symbol(Glyph.ServerRoute, 30.dp, color = Theme.fontQuiet)
        Text(translated("Server ist abgetaucht"), style = Theme.categoryLarge, color = Theme.font,
             modifier = Modifier.padding(top = 14.dp, bottom = 6.dp))
        Text(translated("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                        address ?: translated("Der Server")),
             style = Theme.small.copy(fontSize = 14.sp, lineHeight = 16.sp, textAlign = TextAlign.Center),
             color = Theme.fontVeryQuiet, modifier = Modifier.widthIn(max = 262.dp))
        // A real button from the kit, not just text: as a quiet button "Erneut versuchen" had no
                // surface and no border and did not read as a button. Now the secondary button, as wide as
                // its text, the same shape as every other second button.
        retry?.let { SecondaryButton(translated("Erneut versuchen"), stretches = false, accent = true,
                                 modifier = Modifier.padding(top = 16.dp), action = it) }
    }
}

/**
 * Mirrors `SwipeRow` in `Style.swift`: dragging left reveals an action, 96 wide. Open or
 * closed, never in between. Dragged past 168 it triggers itself and snaps shut; the row changes
 * its check mark at the same moment, which hides the snap. The color behind only appears while
 * dragging, otherwise it flashes when the list is built.
 */
@Composable
fun SwipeRow(symbol: Glyph, text: String, color: Color = Theme.accent, perform: () -> Unit, content: @Composable () -> Unit) {
    val density = LocalDensity.current
    val inputField = with(density) { 96.dp.toPx() }
    val threshold = with(density) { 168.dp.toPx() }
    val distance = remember { Animatable(0f) }
    val run = rememberCoroutineScope()
    // A tick when the action triggers, on a tap on the field and on the full swipe;
        // `SwipeRow` on iOS gives one too.
    val jerk = rememberJerk()
    Box(Modifier.fillMaxWidth()) {
        Box(Modifier.matchParentSize().graphicsLayer { alpha = if (distance.value < -0.5f) 1f else 0f }.background(color)) {
            Column(Modifier.align(Alignment.CenterEnd).width(96.dp).fillMaxHeight()
                    .onTap { jerk(Jerk.Medium); run.launch { distance.snapTo(0f) }; perform() },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Symbol(symbol, 17.dp, color = Theme.reason, strength = Strength.Semibold)
                Text(text, style = Theme.small.copy(fontSize = 11.sp, fontWeight = FontWeight.Medium), color = Theme.reason)
            }
        }
        // Opaque only while dragging: then the action color lies underneath. Closed, the row is
                // transparent; a solid ground drew a hard edge over image color at the first episode.
        Box(Modifier.graphicsLayer { translationX = distance.value }.drawBehind { if (distance.value < -0.5f) drawRect(Theme.reason) }
            .draggable(rememberDraggableState { d -> run.launch { distance.snapTo((distance.value + d).coerceAtMost(0f)) } },
                Orientation.Horizontal,
                onDragStopped = { tempo ->
                    when {
                        -distance.value > threshold -> { jerk(Jerk.Medium); perform(); distance.snapTo(0f) }
                        -distance.value > inputField / 2 || tempo < -700 * density.density -> distance.animateTo(-inputField, Motion.leap())
                        else -> distance.animateTo(0f, Motion.leap())
                    }
                })) {
            content()
        }
    }
}

// MARK: Sheet

/** `beside`: the detail after the text in 12, "· 10 Folgen" in the Seerr season sheet. */
data class Choice(val value: String, val text: String, val beside: String? = null)

/** What a `SelectionSheet` shows. `select` receives the entry's `value`. */
class SheetRequest(val title: String, val entries: List<Choice>, val selected: String?,
                  /** Icon per `value`, the `ActionSheet` on iOS; without it the `SelectionSheet`. */
                  val icons: Map<String, Glyph> = emptyMap(),
                  /** Multi-select with an initial set: then a tap does not close, the footer confirms. */
                  val moreCompartment: Set<String>? = null,
                  /** Rows that cannot be chosen, with their reason ("vorhanden"). A dead check mark would be worse than none. */
                  val locked: Map<String, String> = emptyMap(),
                  /** Actions in `warning`: `TitleAction.cautionary` ("Entfernen", "Alles entfernen"). */
                  val cautionary: Set<String> = emptySet(),
                  val completionText: (Int) -> String = { "" },
                  val completion: ((Set<String>) -> Unit)? = null,
                  /** Own content instead of the rows: the download sheet has values and buttons, no choice. */
                  val content: (@Composable ColumnScope.(close: () -> Unit) -> Unit)? = null,
                  /**
                                     * A heading before an entry (`value` -> heading): divider, then the heading. In the
                                     * title menu of Movies and Series this puts "Bibliotheken" above the libraries, set
                                     * apart from "Alle" and "Sammlungen", which are not libraries (`SelectionSheet.category`).
                                     */
                  val categories: Map<String, String> = emptyMap(),
                  /**
                                     * TV only: a paragraph under the panel heading, what the phone sheet shows as its own
                                     * content (watch together: title, who is watching, what applies).
                                     */
                  val subline: String? = null,
                  val select: (String) -> Unit)

/**
 * Mirrors `SelectionSheet` + `SheetModifier` in `Style.swift`. Lies above the bar: on iOS the
 * sheet hangs behind `.sectionBar()`. So the main view holds it (`app.sheet`), not the page
 * that opens it.
 *
 * The card springs like Apple's sheet (`sheetMotion`), follows the finger 1:1 downward and
 * upward only against the rubber edge; the scrim brightens along while dragging.
 */
@Composable
fun SheetStatus(app: SwiftlyApplication) {
    val wish = app.sheet.value
    // The last request stays so the card leaves with content when closing.
    val remembered = remember { arrayOfNulls<SheetRequest>(1) }
    if (wish != null) remembered[0] = wish
    val opened = wish != null
    val close = { app.sheet.value = null }
    val pull = remember { Animatable(0f) }
    var height by remember { mutableIntStateOf(1) }
    val run = rememberCoroutineScope()
    // Back pulls the card along, like dragging the handle, up to a quarter of its height. On release
        // it leaves; if cancelled it springs back. Otherwise it would close only at the end of the
        // gesture, without preview.
    androidx.activity.compose.PredictiveBackHandler(enabled = opened) { events ->
        try {
            events.collect { e -> pull.snapTo(e.progress * height * 0.25f) }
            close()
        } catch (e: kotlinx.coroutines.CancellationException) {
            run.launch { pull.animateTo(0f, spring(dampingRatio = 0.956f, stiffness = 280f)) }
            throw e
        }
    }
    LaunchedEffect(wish) { if (wish != null) pull.snapTo(0f) }
    val scrim by animateFloatAsState(if (opened) 0.55f else 0f, Motion.sheet(), label = "schleier")
    val scrimPresent by remember { derivedStateOf { scrim > 0.001f } }
    Box(Modifier.fillMaxSize()) {
        // Alpha in the graphics layer: recomposes only when the scrim appears or leaves.
        if (scrimPresent) Box(Modifier.fillMaxSize()
            .graphicsLayer { alpha = scrim * (1f - (pull.value / height).coerceIn(0f, 1f)) }
            .background(Color.Black).onTap(close))
        AnimatedVisibility(opened, Modifier.align(Alignment.BottomCenter),
            enter = slideInVertically(Motion.sheet()) { it },
            exit = slideOutVertically(Motion.sheet()) { it }) {
            remembered[0]?.let { w -> SheetCard(w, pull, { h -> height = h }, close) }
        }
    }
}

/** `UIScrollView`'s rubber edge, Apple's coefficient c = 0.55. */
private fun rubber(distance: Float, d: Float): Float = (1f - 1f / (distance * 0.55f / d + 1f)) * d

@Composable
private fun SheetCard(w: SheetRequest, pull: Animatable<Float, AnimationVector1D>, heightReport: (Int) -> Unit, close: () -> Unit) {
    val density = LocalDensity.current.density
    val run = rememberCoroutineScope()
    var height by remember { mutableIntStateOf(1) }
    val raw = remember { floatArrayOf(0f) }
    var pick by remember(w) { mutableStateOf(w.moreCompartment) }
    // Corner 28 (`cornerSheet`), not 16. A sheet from below is the largest rounding on the scale;
        // `eckeFlaeche` belongs to the panel in the picture.
    val top = RoundedCornerShape(topStart = Theme.cornerSheet, topEnd = Theme.cornerSheet)
    Column(Modifier.fillMaxWidth()
        .onSizeChanged { height = it.height; heightReport(it.height) }
        .graphicsLayer { translationY = pull.value }
        // The surface extends under the card: if it springs past its target, nothing shows below.
        .drawBehind { drawRect(Theme.area, topLeft = Offset(0f, size.height - 1f), size = Size(size.width, 400.dp.toPx())) }
        .clip(top).background(Theme.area)
        .draggable(rememberDraggableState { d ->
                raw[0] += d
                val target = if (raw[0] >= 0f) raw[0] else -rubber(-raw[0], height.toFloat())
                run.launch { pull.snapTo(target) }
            }, Orientation.Vertical,
            onDragStarted = { raw[0] = pull.value },
            onDragStopped = { tempo ->
                // A quarter of the height or a fast flick closes; otherwise it springs back. When flicked the
                                // card leaves at its own speed instead of stalling briefly.
                if (pull.value > height * 0.25f || tempo > 700 * density) {
                    pull.animateTo(height.toFloat(), Motion.toss(), initialVelocity = tempo.coerceAtLeast(0f))
                    close()
                }
                else { raw[0] = 0f; pull.animateTo(0f, spring(dampingRatio = 0.956f, stiffness = 280f), initialVelocity = tempo) }
            })
        .navigationBarsPadding()) {
        Box(Modifier.align(Alignment.CenterHorizontally).padding(top = 8.dp).size(36.dp, 5.dp)
            .clip(CircleShape).background(Color.White.copy(alpha = 0.18f)))
        // Heading 17 semibold, 5 above / 14 below, and no line below. The line used to separate the
                // heading from its own rows.
        Text(w.title, style = Theme.categoryLarge,
             color = Theme.font, maxLines = 1,
             modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 5.dp, bottom = 14.dp))
        val own = w.content
        when {
            own != null -> own(close)
            w.moreCompartment != null -> SeasonSelection(w, pick.orEmpty(), { pick = it }, close)
            w.icons.isNotEmpty() -> Actions(w, close)
            else -> SelectionRows(w, close)
        }
    }
}

/** The cancel row at the foot of a sheet, `SheetCancel`: 15 Medium `schriftLeise`, at least 54. */
@Composable
internal fun SheetCancel(close: () -> Unit) {
    Box(Modifier.fillMaxWidth().heightIn(min = 54.dp).pressRow(close), contentAlignment = Alignment.Center) {
        Text(translated("Abbrechen"), style = Theme.buttonText, color = Theme.fontQuiet)
    }
}

/** `SheetLine`: full width, from card edge to card edge. */
@Composable
internal fun SheetLine() = Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))

/**
 * Mirrors `SelectionSheet` in `Style.swift`. The check mark is on the left and always there as
 * space, even when it shows nothing, otherwise the labels shift when the choice changes.
 * Chosen means full white and semibold, not accent: "this is it" is rank, not state. 17 on at
 * least 52, no lines between rows, at most 340 high, then Cancel.
 */
@Composable
private fun SelectionRows(w: SheetRequest, close: () -> Unit) {
    Column(Modifier.heightIn(max = 340.dp).verticalScroll(rememberScrollState())) {
        w.entries.forEach { e ->
            w.categories[e.value]?.let { over ->
                // `SeparatorLine` (inset from the edge), then the heading: 11 semibold tracked in capitals,
                                // `schriftSehrLeise`, `tileSpacing` above, 4 below.
                Box(Modifier.padding(start = Theme.edgeSpacing).fillMaxWidth().height(1.dp).background(Theme.line))
                Text(over.uppercase(), style = Theme.group, color = Theme.fontVeryQuiet,
                     modifier = Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing)
                         .padding(top = Theme.tileSpacing, bottom = 4.dp).semantics { heading() })
            }
            val an = e.value == w.selected
            Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).pressRow { close(); w.select(e.value) }
                    .padding(horizontal = Theme.edgeSpacing),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(Modifier.width(18.dp), contentAlignment = Alignment.Center) {
                    if (an) Symbol(Glyph.Checkmark, 17.dp, color = Theme.font, strength = Strength.Semibold)
                }
                Text(e.text, style = Theme.categoryLarge.copy(fontWeight = if (an) FontWeight.SemiBold else FontWeight.Normal, letterSpacing = 0.sp),
                     color = if (an) Theme.font else Theme.fontQuiet, modifier = Modifier.weight(1f))
            }
        }
    }
    SheetCancel(close)
}

/**
 * Mirrors `ActionSheet` in `Style.swift`: each row triggers something and the sheet closes.
 * Icon 17 in 20 width, 14 to the text, text 17, `warning` for warning actions. Lines between
 * the rows and one above Cancel.
 */
@Composable
private fun Actions(w: SheetRequest, close: () -> Unit) {
    w.entries.forEachIndexed { i, e ->
        if (i > 0) SheetLine()
        val color = if (e.value in w.cautionary) Theme.warning else Theme.font
        Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).pressRow { close(); w.select(e.value) }
                .padding(horizontal = Theme.edgeSpacing),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(Modifier.width(Theme.characterColumn), contentAlignment = Alignment.Center) {
                w.icons[e.value]?.let { Symbol(it, 17.dp, color = color) }
            }
            Text(e.text, style = Theme.categoryLarge.copy(fontWeight = FontWeight.Normal, letterSpacing = 0.sp), color = color,
                 modifier = Modifier.weight(1f))
        }
    }
    SheetLine()
    SheetCancel(close)
}

/**
 * Mirrors `seasonSheet` in `SeerrDetailView.swift`: checkbox on the right, rows 15 on at least
 * 50 without lines, at most 320 high; below, a full-width line and the confirm button, 15
 * semibold on at least 54, in accent once something is chosen.
 */
@Composable
private fun SeasonSelection(w: SheetRequest, amount: Set<String>, setDown: (Set<String>) -> Unit, close: () -> Unit) {
    Column(Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState())) {
        w.entries.forEach { e ->
            val reason = w.locked[e.value]
            val an = e.value in amount
            Row(Modifier.fillMaxWidth().heightIn(min = 50.dp)
                    .then(if (reason != null) Modifier else Modifier.pressRow { setDown(if (an) amount - e.value else amount + e.value) })
                    .padding(horizontal = Theme.edgeSpacing),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(e.text, style = Theme.body, color = if (reason == null) Theme.font else Theme.fontVeryQuiet)
                e.beside?.let { Text(it, style = Theme.small, color = Theme.fontVeryQuiet) }
                Spacer(Modifier.weight(1f).widthIn(min = 8.dp))
                if (reason != null) Text(reason, style = Theme.small, color = Theme.fontVeryQuiet)
                else Symbol(if (an) Glyph.CheckboxFilled else Glyph.Checkbox, 17.dp, color = if (an) Theme.accent else Theme.fontVeryQuiet)
            }
        }
    }
    SheetLine()
    val completion = w.completion
    Box(Modifier.fillMaxWidth().heightIn(min = 54.dp)
            .then(if (amount.isEmpty() || completion == null) Modifier else Modifier.pressRow { close(); completion(amount) }),
        contentAlignment = Alignment.Center) {
        Text(w.completionText(amount.size), style = Theme.listTitle, color = if (amount.isEmpty()) Theme.fontVeryQuiet else Theme.accent)
    }
}
