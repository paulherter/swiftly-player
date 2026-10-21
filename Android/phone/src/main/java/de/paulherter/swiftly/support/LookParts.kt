package de.paulherter.swiftly.support

import android.os.Handler
import android.os.Looper
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.keyframes
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Motion
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Wordmark
import de.paulherter.swiftly.shared.motionReduced
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.tapOn
import kotlin.math.max

// The parts the looks panel, the support sheet and the profile share (`LookGiftSheet`,
// `SupportGrowSheet`, `SupportProfileParts`, `LookAccentDots` on iPhone).

/** The sheets' text: `giftFont(size, weight)`. */
internal fun giftFont(size: Float, weight: FontWeight = FontWeight.Normal) = TextStyle(fontSize = size.sp, fontWeight = weight)

// MARK: - Light

/**
 * SwiftUI's `EllipticalGradient`: a radial gradient squeezed to `rx` by `ry`. Drawn as a circle of
 * radius `rx`, scaled vertically by `ry / rx` around its center; the rectangle covers the whole area.
 */
internal fun DrawScope.ellipseGradient(center: Offset, rx: Float, ry: Float, vararg stops: Pair<Float, Color>) {
    if (rx <= 0f || ry <= 0f) return
    val k = ry / rx
    scale(1f, k, pivot = center) {
        val top = center.y + (0f - center.y) / k
        val bottom = center.y + (size.height - center.y) / k
        drawRect(Brush.radialGradient(*stops, center = center, radius = rx),
                 topLeft = Offset(0f, top), size = androidx.compose.ui.geometry.Size(size.width, bottom - top))
    }
}

/**
 * **The light at the top of the looks sheets** (`CardLight`): the look's color from the top
 * center, its second tone from the top right corner, 260 high. Moves with `Motion.change`.
 */
@Composable
fun BoxScope.CardLightBackdrop(tone: Color, tint: Color?) {
    val t by animateColorAsState(tone, Motion.change(), label = "licht")
    val n by animateColorAsState(tint ?: tone, Motion.change(), label = "licht2")
    val density = LocalDensity.current
    Box(Modifier.align(Alignment.TopCenter).fillMaxWidth().height(260.dp).drawBehind {
        val w = size.width
        with(density) {
            ellipseGradient(Offset(w / 2, 0f), w * 0.5f, 130.dp.toPx(),
                0f to t.copy(alpha = 0.30f), 0.45f to t.copy(alpha = 0.12f), 0.75f to t.copy(alpha = 0.03f), 1f to t.copy(alpha = 0f))
            ellipseGradient(Offset(w, 0f), w * 0.6f, 156.dp.toPx(),
                0f to n.copy(alpha = 0.11f), 0.5f to n.copy(alpha = 0.05f), 1f to n.copy(alpha = 0f))
        }
    })
}

/**
 * **The glow of the home page** (`LookGlowLayer`): the look's color from the top center, the
 * second tone from beyond the right edge, as tall as the screen is wide (at least 390 counted).
 * `scrolled` moves it up with the page (read while drawing, so scrolling never recomposes).
 */
@Composable
fun LookGlowLayer(color: Color, tint: Color?, strength: Float, modifier: Modifier = Modifier, scrolled: () -> Float = { 0f }) {
    val c by animateColorAsState(color, Motion.change(), label = "schein")
    val n by animateColorAsState(tint ?: color, Motion.change(), label = "schein2")
    val s by animateFloatAsState(strength, Motion.change(), label = "staerke")
    val width = LocalConfiguration.current.screenWidthDp
    val reach = max(width, 390) * 2.16f * 0.25f
    val density = LocalDensity.current
    Box(modifier.fillMaxWidth().height((reach * 2).dp).drawBehind {
        if (s <= 0.001f) return@drawBehind
        val w = size.width
        val r = with(density) { reach.dp.toPx() }
        val y = -with(density) { scrolled().dp.toPx() }
        ellipseGradient(Offset(w / 2, y), w * 0.75f, r,
            0f to c.copy(alpha = s), 0.35f to c.copy(alpha = 0.62f * s), 0.7f to c.copy(alpha = 0.22f * s), 1f to c.copy(alpha = 0f))
        ellipseGradient(Offset(w * 1.25f, y), w * 0.9f, r * 1.2f,
            0f to n.copy(alpha = 0.36f * s), 0.5f to n.copy(alpha = 0.16f * s), 1f to n.copy(alpha = 0f))
    })
}

// MARK: - Tiles and buttons

/** The look's icon as a tile, rounded like an app icon (`LookTile`): corner 22.5 %, a faint edge. */
@Composable
fun LookTileView(icon: AppIcons.Icon, size: Dp, modifier: Modifier = Modifier, corner: Dp = size * 0.225f) {
    val shape = RoundedCornerShape(corner)
    Box(modifier.size(size).clip(shape).border(1.dp, Color.White.copy(alpha = 0.08f), shape)) {
        // The adaptive layers are 108 wide, the launcher shows the middle 72: the same crop here.
        Image(painterResource(icon.background), null, Modifier.fillMaxSize().graphicsLayer { scaleX = 1.5f; scaleY = 1.5f })
        Image(painterResource(icon.foreground), null, Modifier.fillMaxSize().graphicsLayer { scaleX = 1.5f; scaleY = 1.5f })
    }
}

/** The two buttons of the looks sheets (`GiftButton`): 50 high, corner 10, white or raised. */
@Composable
fun GiftButton(text: String, primary: Boolean, modifier: Modifier = Modifier, action: () -> Unit) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val mass by animateFloatAsState(if (pressed) 0.97f else 1f, tween(150, easing = Motion.outro), label = "druck")
    val ground = if (primary) Color.White.copy(alpha = if (pressed) 0.75f else 1f) else Theme.raised.copy(alpha = if (pressed) 0.7f else 1f)
    Box(modifier.fillMaxWidth().height(50.dp).graphicsLayer { scaleX = mass; scaleY = mass }
            .background(ground, RoundedCornerShape(10.dp))
            .clickable(source, null, onClick = action).semantics { role = Role.Button },
        contentAlignment = Alignment.Center) {
        Text(text, style = giftFont(17f, FontWeight.SemiBold), color = if (primary) Color.Black else Theme.font, maxLines = 1)
    }
}

/** The X of a sheet: a 30 circle in a 44 hit area. Raised and quiet in the panel, dark glass on the support sheet. */
@Composable
fun LookCloseButton(modifier: Modifier = Modifier, dark: Boolean = false, action: () -> Unit) {
    val label = translated("Schließen")
    Box(modifier.size(44.dp).tapOn(action).semantics { role = Role.Button; contentDescription = label }, contentAlignment = Alignment.Center) {
        Box(Modifier.size(30.dp).background(if (dark) Color.Black.copy(alpha = 0.4f) else Theme.raised, CircleShape),
            contentAlignment = Alignment.Center) {
            Symbol(Glyph.Cross, if (dark) 12.dp else 13.dp, color = if (dark) Theme.font else Theme.fontQuiet, strength = Strength.Bold)
        }
    }
}

/** Dark glass without a live blur (`glassPill`): white 16 % at 92 %, a 1 px edge. */
fun Modifier.glassPill(): Modifier = this.clip(CircleShape)
    .background(Color(0xFF292929).copy(alpha = 0.92f), CircleShape)
    .border(Dp.Hairline, Color.White.copy(alpha = 0.14f), CircleShape)

/** "Look ausprobieren ›" as a glass pill. */
@Composable
fun LookTryPill(textSize: Float, height: Dp, modifier: Modifier = Modifier) {
    Row(modifier.height(height).glassPill().padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(translated("Look ausprobieren"), style = giftFont(textSize, FontWeight.SemiBold), color = Theme.font, maxLines = 1)
        Symbol(Glyph.AngleRight, 11.dp, color = Theme.font, strength = Strength.Bold)
    }
}

/**
 * **iOS's segmented control, drawn** (`Segments`): `area` with corner 8, the chosen part a lighter
 * surface that slides with `Motion.select`; 32 high in a 44 hit area, 56 per option.
 */
@Composable
fun Segments(options: List<Pair<String, String>>, value: String, choose: (String) -> Unit) {
    val n = options.size
    val width = max(112, n * 56).dp
    val part = (width - 4.dp - 2.dp * (n - 1)) / n
    val index = options.indexOfFirst { it.first == value }.coerceAtLeast(0)
    val x by animateDpAsState(2.dp + (part + 2.dp) * index, Motion.select(), label = "segment")
    Box(Modifier.heightIn(min = 44.dp), contentAlignment = Alignment.Center) {
        Box(Modifier.width(width).height(32.dp).background(Theme.area, RoundedCornerShape(8.dp))) {
            Box(Modifier.offset(x = x, y = 2.dp).size(part, 28.dp).background(Color(0xFF4A4A4A), RoundedCornerShape(6.dp)))
            Row(Modifier.padding(2.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                options.forEach { (id, label) ->
                    val on = id == value
                    Box(Modifier.size(part, 28.dp).clickable(remember { MutableInteractionSource() }, null) { if (!on) choose(id) }
                            .semantics(mergeDescendants = true) { role = Role.RadioButton; selected = on },
                        contentAlignment = Alignment.Center) {
                        Text(label, style = giftFont(13f, FontWeight.SemiBold), color = if (on) Theme.font else Theme.fontQuiet, maxLines = 1)
                    }
                }
            }
        }
    }
}

/** The accent dots (`AccentDots`): 22 each with a ring when chosen, overlapping by 10, 44 to hit. */
@Composable
fun AccentDots(accents: List<Looks.Accent>, chosen: String, choose: (Looks.Accent) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy((-10).dp)) {
        accents.forEach { accent ->
            val on = accent.id == chosen
            val ring by animateFloatAsState(if (on) 1f else 0f, Motion.select(), label = "ring")
            Box(Modifier.size(44.dp).tapOn { choose(accent) }
                    .semantics { role = Role.RadioButton; selected = on; contentDescription = accentName(accent.id) },
                contentAlignment = Alignment.Center) {
                Box(Modifier.size(26.dp).drawBehind {
                    val stroke = 1.5.dp.toPx()
                    drawCircle(accent.main, radius = 11.dp.toPx())
                    if (ring > 0f) drawCircle(Theme.font.copy(alpha = ring), radius = size.minDimension / 2 - stroke / 2, style = Stroke(stroke))
                })
            }
        }
    }
}

private fun accentName(id: String): String = when (id) {
    "violet" -> translated("Violett")
    "coral" -> translated("Koralle")
    "gold" -> translated("Gold")
    "emerald" -> translated("Smaragd")
    else -> translated("Türkis")
}

// MARK: - Motion helpers

/** Bobbing up and down forever after `delay` (`easeInOut`, autoreversing); still when motion is reduced. */
@Composable
private fun bob(distance: Float, seconds: Float, delay: Float): () -> Float {
    if (motionReduced()) return { 0f }
    val value = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        kotlinx.coroutines.delay((delay * 1000).toLong())
        value.animateTo(1f, infiniteRepeatable(tween((seconds * 1000).toInt(), easing = EaseInOut), RepeatMode.Reverse))
    }
    return { value.value * distance }
}

// MARK: - The small phones of the support sheet

/** A home page in miniature in a look's colors (`LookMiniPhone`), 104 × 208, bobbing. */
@Composable
fun LookMiniPhone(palette: Looks.Palette, delay: Float, modifier: Modifier = Modifier) {
    val up = bob(-6f, 2f, delay)
    val accent = palette.accent.main
    val shape = RoundedCornerShape(14.dp)
    Box(modifier.graphicsLayer { translationY = up() * density }
            .shadow(20.dp, shape, ambientColor = Color.Black.copy(alpha = 0.5f), spotColor = Color.Black.copy(alpha = 0.5f))
            .size(104.dp, 208.dp).clip(shape).background(Theme.reason)
            .border(1.dp, Theme.font.copy(alpha = 0.1f), shape)) {
        Box(Modifier.fillMaxWidth().height(64.dp).drawBehind {
            ellipseGradient(Offset(size.width / 2, 0f), size.width * 0.75f, size.height * 0.75f,
                0f to accent.copy(alpha = 0.34f), 1f to accent.copy(alpha = 0f))
        })
        Box(Modifier.offset(9.dp, 16.dp)) {
            Wordmark(height = 11.6.dp, accent = palette.logoGradient.firstOrNull() ?: accent,
                     gradient = palette.logoGradient.takeIf { it.size > 1 })
        }
        Symbol(Glyph.HeartFilled, 10.dp, color = Theme.font, modifier = Modifier.align(Alignment.TopEnd).padding(end = 9.dp).offset(y = 16.dp))
        Text(translated("Weiterschauen"), style = giftFont(7.5f, FontWeight.SemiBold), color = Theme.font, maxLines = 1,
             modifier = Modifier.offset(9.dp, 34.dp))
        MiniPoster(86.dp, 48.dp, 5.dp, Modifier.offset(9.dp, 47.dp), progress = 0.44f, accent = accent)
        MiniPoster(40.dp, 60.dp, 4.dp, Modifier.offset(9.dp, 104.dp))
        MiniPoster(40.dp, 60.dp, 4.dp, Modifier.offset(55.dp, 104.dp))
        // The tab bar: a line, four squares, the first in the accent.
        Row(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(24.dp).drawBehind {
                drawRect(Theme.line, size = androidx.compose.ui.geometry.Size(size.width, 1.dp.toPx()))
            }, horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
            repeat(4) { i ->
                Box(Modifier.size(8.dp).background(if (i == 0) accent else Color(0xFF555555), RoundedCornerShape(2.5.dp)))
            }
        }
    }
}

@Composable
private fun MiniPoster(width: Dp, height: Dp, corner: Dp, modifier: Modifier, progress: Float? = null, accent: Color = Color.Transparent) {
    Box(modifier.size(width, height).clip(RoundedCornerShape(corner))
            .background(Brush.verticalGradient(listOf(Theme.raised, Theme.area)))) {
        if (progress != null) {
            Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(2.5.dp).background(Theme.font.copy(alpha = 0.3f))) {
                Box(Modifier.width(width * progress).height(2.5.dp).background(accent))
            }
        }
    }
}

/**
 * **The support sheet's hero** (`LooksHero`): three small phones in three looks, the middle one in
 * front, fading out above "Look ausprobieren", 252 high.
 */
@Composable
fun LooksHero(app: SwiftlyApplication, modifier: Modifier = Modifier, tryLooks: () -> Unit) {
    val looks = app.looks
    val phones = remember {
        listOf(
            Triple(looks.paletteFor("""{"look":"original","glow":"soft"}"""), floatArrayOf(-104f, 34f, -8f, 0f), 1f),
            Triple(looks.paletteFor("""{"look":"neonNight","accent":"coral"}"""), floatArrayOf(104f, 34f, 8f, 0.8f), 1f),
            Triple(looks.paletteFor("""{"look":"neonNight"}"""), floatArrayOf(0f, 16f, 0f, 0.4f), 2f),
        )
    }
    Box(modifier.fillMaxWidth().height(252.dp)) {
        // The phones end softly above the pill: opaque to 62 %, gone at 90 % of a mask from -40.
        Box(Modifier.fillMaxSize().graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                .drawWithContent {
                    drawContent()
                    val top = -40.dp.toPx()
                    val span = size.height - top
                    drawRect(Brush.verticalGradient(0f to Color.Black, 0.62f to Color.Black, 0.9f to Color.Transparent,
                                                    startY = top, endY = top + span), blendMode = BlendMode.DstIn)
                }) {
            phones.forEach { (palette, at, z) ->
                LookMiniPhone(palette, at[3], Modifier.align(Alignment.TopCenter).zIndex(z)
                    .offset(at[0].dp, at[1].dp).graphicsLayer { rotationZ = at[2] })
            }
        }
        Box(Modifier.align(Alignment.BottomCenter).offset(y = 7.dp).heightIn(min = 44.dp).zIndex(3f).tapOn(tryLooks),
            contentAlignment = Alignment.Center) {
            LookTryPill(13f, 30.dp)
        }
    }
}

// MARK: - Profile

/** The icons of the fan (`IconFan`): name, turn, drop, size, delay. */
private val fanIcons = listOf(
    listOf("LookSunset", -10f, 12f, 60f, 0f),
    listOf("LookNeonNight", -4f, 4f, 60f, 0.3f),
    listOf("Standard", 0f, 0f, 70f, 0.6f),
    listOf("LookAurora", 4f, 4f, 60f, 0.9f),
    listOf("LookGold", 10f, 12f, 60f, 1.2f),
)

@Composable
private fun IconFan() {
    val calm = motionReduced()
    Row(Modifier.fillMaxWidth().padding(top = 22.dp).height(82.dp), horizontalArrangement = Arrangement.spacedBy((-10).dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.Top) {
        fanIcons.forEachIndexed { index, f ->
            val size = (f[3] as Float).dp
            val up = bob(-3f, 1.6f, f[4] as Float)
            val picks = index == 2
            Box(Modifier.zIndex(if (picks) 2f else 0f).offset(y = (f[2] as Float).dp)
                    .graphicsLayer { translationY = up() * density; rotationZ = f[1] as Float }) {
                LookTileView(AppIcons.forAlias(f[0] as String), size, corner = 14.dp,
                             modifier = Modifier.shadow(6.dp, RoundedCornerShape(14.dp), ambientColor = Color.Black.copy(alpha = 0.25f),
                                                         spotColor = Color.Black.copy(alpha = 0.25f)))
                if (picks && !calm) PickRing(size)
            }
        }
    }
}

/** The ring that picks the middle icon: off, on from 70 to 92 % of a 4.8 s cycle. */
@Composable
private fun BoxScope.PickRing(size: Dp) {
    val value = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        value.animateTo(0f, infiniteRepeatable(keyframes {
            durationMillis = 4800
            0f at 0 using LinearEasing
            0f at 2980 using LinearEasing
            1f at 3360 using LinearEasing
            1f at 4420 using LinearEasing
            0f at 4800
        }))
    }
    Box(Modifier.align(Alignment.Center).size(size + 8.dp).graphicsLayer { alpha = value.value }
            .border(2.dp, Theme.font, RoundedCornerShape(18.dp)))
}

/**
 * **"Wähl deinen Look" in the profile** (`SupportLooksCard`): the fan of icons, the line, the pill;
 * dark glass so the home glow shows at the top. Opens the panel on the home page.
 */
@Composable
fun SupportLooksCard(app: SwiftlyApplication) {
    val shape = RoundedCornerShape(Theme.cornerArea)
    Column(Modifier.fillMaxWidth().tapOn { openLooksOnHome(app) }
            .background(Brush.verticalGradient(listOf(Color(0xFF1A1A1A).copy(alpha = 0.62f), Color(0xFF121212).copy(alpha = 0.9f))), shape)
            .border(1.dp, Brush.verticalGradient(listOf(Theme.font.copy(alpha = 0.14f), Theme.font.copy(alpha = 0.04f))), shape)
            .semantics(mergeDescendants = true) { role = Role.Button }) {
        IconFan()
        Column(Modifier.padding(horizontal = 18.dp).padding(top = 10.dp, bottom = 18.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(translated("Wähl deinen Look"), style = giftFont(20f, FontWeight.SemiBold).copy(letterSpacing = (-0.2).sp), color = Theme.font)
            Text(translated("Looks und Icons für alle, die Swiftly am Laufen halten."), style = giftFont(13f).copy(lineHeight = 18.sp),
                 color = Theme.fontQuiet)
            LookTryPill(14f, 34.dp, Modifier.padding(top = 10.dp))
        }
    }
}

/** **The look being worn, with "Ändern"** (`CurrentLookCard`) in the profile. */
@Composable
fun CurrentLookCard(app: SwiftlyApplication) {
    val looks = app.looks
    val look = looks.info(looks.palette.value.look)
    Row(Modifier.fillMaxWidth().heightIn(min = 76.dp).tapOn { openLooksOnHome(app) }
            .background(Theme.groupsArea, RoundedCornerShape(Theme.cornerArea)).padding(horizontal = 16.dp, vertical = 14.dp)
            .semantics(mergeDescendants = true) { role = Role.Button },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        LookTileView(looks.tileIcon(look), 44.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(translated("Dein Look"), style = giftFont(13f), color = Theme.fontQuiet)
            Text(look.name, style = giftFont(17f, FontWeight.SemiBold), color = Theme.font, maxLines = 1)
        }
        Text(translated("Ändern"), style = giftFont(15f, FontWeight.SemiBold), color = Theme.accent)
    }
}

/** **What the support is** (`SupportStatusCard`), supporters only: heart or cup, plan, since when. */
@Composable
fun SupportStatusCard(app: SwiftlyApplication) {
    val support = app.support
    if (!support.isSupporter) return
    val plan = app.store.rememberValue(Support.PLAN).orEmpty()
    val accent = Theme.accent
    val since = support.sinceMillis ?: System.currentTimeMillis()
    val title = when (plan) {
        "monthly" -> translated("Monatlich dabei")
        else -> translated("Unterstützer für immer")
    }
    val locale = java.util.Locale.getDefault()
    fun format(millis: Long, skeleton: String) =
        java.text.SimpleDateFormat(android.text.format.DateFormat.getBestDateTimePattern(locale, skeleton), locale).format(java.util.Date(millis))
    val detail = when (plan) {
        "monthly" -> {
            val c = java.util.Calendar.getInstance().apply { timeInMillis = since; add(java.util.Calendar.MONTH, 1) }
            val price = support.channel.plans.value.firstOrNull { it.plan == "monthly" }?.price.orEmpty()
            translated("Verlängert sich am %@ für %@. Danke, dass du dabeibleibst.", format(c.timeInMillis, "dMMMM"), price)
        }
        else -> translated("Seit %@. Nichts verlängert sich, deine Extras bleiben.", format(since, "dMMMMyyyy"))
    }
    val shape = RoundedCornerShape(Theme.cornerArea)
    Row(Modifier.fillMaxWidth().clip(shape).background(Theme.groupsArea)
            .drawBehind {
                drawRect(Brush.radialGradient(listOf(accent.copy(alpha = 0.16f), accent.copy(alpha = 0f)), center = Offset.Zero,
                                              radius = 220.dp.toPx()))
            }
            .padding(14.dp).semantics(mergeDescendants = true) { },
        horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(44.dp).clip(CircleShape).drawBehind {
                drawRect(Brush.radialGradient(listOf(accent.copy(alpha = 0.28f), accent.copy(alpha = 0.06f)),
                                              center = Offset(size.width * 0.5f, size.height * 0.4f), radius = 26.dp.toPx()))
            }, contentAlignment = Alignment.Center) {
            Symbol(Glyph.HeartFilled, 18.dp, color = accent)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = giftFont(17f, FontWeight.SemiBold), color = Theme.font)
            Text(detail, style = giftFont(13f), color = Theme.fontQuiet)
        }
    }
}

/** **"Looks" in Darstellung: the look worn, with "Ändern"** (`currentLookRow`), 52 high. */
@Composable
fun CurrentLookRow(app: SwiftlyApplication) {
    val looks = app.looks
    val look = looks.info(JSONObjectOrEmpty(looks.saved.value).optString("look", "original"))
    Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).tapOn { openLooksOnHome(app) }.padding(horizontal = 16.dp)
            .semantics(mergeDescendants = true) { role = Role.Button },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        LookTileView(looks.tileIcon(look), 32.dp)
        Text(look.name, style = giftFont(15f, FontWeight.SemiBold), color = Theme.font, maxLines = 1, modifier = Modifier.weight(1f))
        Text(translated("Ändern"), style = giftFont(15f, FontWeight.SemiBold), color = Theme.accent)
    }
}

internal fun JSONObjectOrEmpty(json: String): org.json.JSONObject = runCatching { org.json.JSONObject(json) }.getOrElse { org.json.JSONObject() }

// MARK: - Flow

/**
 * **The panel opens on the home page** (`GiftFlow.openLooksOnHome`): home first, the panel 0.18 s
 * later, so the change is seen where it happens. A look that may not be worn is tried on.
 */
fun openLooksOnHome(app: SwiftlyApplication, tryLook: String? = null) {
    val looks = app.looks
    looks.goHome()
    val wait = if (Motion.reduced(app)) 0L else Motion.PageBeforeSheetMs
    Handler(Looper.getMainLooper()).postDelayed({
        val tryOn = tryLook?.takeIf { !looks.mayWear(org.json.JSONObject(looks.switching(it))) }
        looksPanelShow(app, tryOn)
    }, wait)
}

/**
 * **The accent tones move with `Motion.change`** (phone only): `Looks.run` leaves the tones to
 * this, which carries them over in 0.28 s; with reduced motion the change is a short fade.
 */
@Composable
fun LookToneAnimator(app: SwiftlyApplication) {
    val looks = app.looks
    DisposableEffect(Unit) {
        looks.tonesAnimated = true
        onDispose { looks.tonesAnimated = false; Theme.applyTones(looks.palette.value.accent.tones()) }
    }
    val target = looks.palette.value.accent
    val spec = if (motionReduced()) Motion.fadeReduced<Color>() else Motion.change<Color>()
    val main by animateColorAsState(target.main, spec, label = "akzent")
    val light by animateColorAsState(target.light, spec, label = "akzent2")
    val quiet by animateColorAsState(target.quiet, spec, label = "akzent3")
    val on by animateColorAsState(target.on, spec, label = "akzent4")
    val warning = target.tones().warning
    SideEffect { Theme.applyTones(Theme.Tones(main, light, quiet, on, warning)) }
}
