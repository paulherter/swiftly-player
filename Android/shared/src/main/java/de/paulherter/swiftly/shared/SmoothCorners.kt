package de.paulherter.swiftly.shared

import androidx.compose.foundation.shape.CornerBasedShape
import androidx.compose.foundation.shape.CornerSize
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.toRect
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tan

/*
 * Corner smoothing after figma-squircle (https://github.com/phamfoo/figma-squircle, MIT License,
 * Copyright (c) 2021 Tien Pham), itself based on Figma's article
 * "Desperately seeking squircles". Ported to Kotlin; the maths (budget, a/b/c/d, arc section) is kept
 * one to one, the path is emitted as cubic Béziers (the arc as one cubic) instead of SVG commands.
 * The licence text is listed in THIRD-PARTY-NOTICES.md / LICENSES/MIT-figma-squircle.txt.
 */

/** Design decision: every rounded rectangle has 60 % corner smoothing (Figma "iOS"). */
const val CornerSmoothing = 0.6f

/** Where [buildSmoothRoundedRect] writes its path; the shape uses a Compose [Path], the tests a recorder. */
internal interface PathSink {
    fun moveTo(x: Float, y: Float)
    fun lineTo(x: Float, y: Float)
    fun cubicTo(x1: Float, y1: Float, x2: Float, y2: Float, x3: Float, y3: Float)
    fun close()
}

/** One corner's numbers (figure 11.1 / 12.2 of the Figma article), in pixels. */
internal class CornerParams(
    val radius: Float,
    /** Distance along the edge where the curve starts (the corner's reach). */
    val p: Float,
    val a: Float,
    val b: Float,
    val c: Float,
    val d: Float,
    val arcSectionLength: Float,
    /** Angle (radians) of the join between the Bézier part and the circular arc. */
    val beta: Double,
    /** Sweep of the circular arc in radians. */
    val arcMeasure: Double,
)

/**
 * The corner's parameters for [radius] with at most [budget] pixels along each edge. When the budget is
 * tight (a pill, a small circle) the smoothing shrinks until the corner is a plain circular arc, so
 * capsules and circles stay round without a special case.
 */
internal fun cornerParams(radius: Float, smoothing: Float, budget: Float): CornerParams {
    if (radius <= 0f) {
        return CornerParams(0f, 0f, 0f, 0f, 0f, 0f, 0f, 0.0, 0.0)
    }
    val r = radius.toDouble()
    val budgetD = budget.toDouble()
    val s = min(smoothing.toDouble(), budgetD / r - 1.0).coerceAtLeast(0.0)
    val p = min((1.0 + s) * r, budgetD)
    // In a plain rounded rectangle the arc is 90 degrees; the more smoothing, the shorter the arc.
    val arcMeasure = Math.toRadians(90.0 * (1.0 - s))
    val arcSectionLength = sin(arcMeasure / 2.0) * r * sqrt(2.0)
    val angleAlpha = (Math.toRadians(90.0) - arcMeasure) / 2.0
    val p3ToP4 = r * tan(angleAlpha / 2.0)
    val beta = Math.toRadians(45.0 * s)
    val c = p3ToP4 * cos(beta)
    val d = c * tan(beta)
    val b = (p - arcSectionLength - c - d) / 3.0
    val a = 2.0 * b
    return CornerParams(
        radius = radius,
        p = p.toFloat(),
        a = a.toFloat(),
        b = b.toFloat(),
        c = c.toFloat(),
        d = d.toFloat(),
        arcSectionLength = arcSectionLength.toFloat(),
        beta = beta,
        arcMeasure = arcMeasure,
    )
}

/** figma-squircle's per-corner budget: the share of each adjacent side that corner may use. */
private fun budgetFor(
    radius: Float,
    adjacentA: Float,
    sideA: Float,
    adjacentB: Float,
    sideB: Float,
): Float {
    fun share(adjacent: Float, side: Float): Float =
        if (radius == 0f && adjacent == 0f) 0f else radius / (radius + adjacent) * side
    return min(share(adjacentA, sideA), share(adjacentB, sideB))
}

/** The four corners' [CornerParams] for a [width] x [height] box (top-left, top-right, bottom-right, bottom-left). */
internal fun cornersFor(
    width: Float,
    height: Float,
    topLeft: Float,
    topRight: Float,
    bottomRight: Float,
    bottomLeft: Float,
    smoothing: Float,
): List<CornerParams> {
    val radii = floatArrayOf(topLeft, topRight, bottomRight, bottomLeft)
    val out = arrayOfNulls<CornerParams>(4)
    // Same order and in-place clamping as figma-squircle.
    val order = listOf(0, 1, 3, 2) // topLeft, topRight, bottomLeft, bottomRight
    for (i in order) {
        val budget = when (i) {
            0 -> budgetFor(radii[0], radii[1], width, radii[3], height)
            1 -> budgetFor(radii[1], radii[0], width, radii[2], height)
            2 -> budgetFor(radii[2], radii[1], height, radii[3], width)
            else -> budgetFor(radii[3], radii[0], height, radii[2], width)
        }
        radii[i] = min(radii[i], budget)
        out[i] = cornerParams(radii[i], smoothing, budget)
    }
    return out.map { it!! }
}

/**
 * Writes a rounded rectangle with smoothed corners: start at the top edge, clockwise. Corners with radius 0
 * are sharp. [smoothing] 0 gives the plain circular rounded rectangle.
 */
internal fun buildSmoothRoundedRect(
    sink: PathSink,
    width: Float,
    height: Float,
    topLeft: Float,
    topRight: Float,
    bottomRight: Float,
    bottomLeft: Float,
    smoothing: Float = CornerSmoothing,
) {
    val (tl, tr, br, bl) = cornersFor(width, height, topLeft, topRight, bottomRight, bottomLeft, smoothing)
    sink.moveTo(width - tr.p, 0f)
    smoothCorner(sink, tr, width - tr.p, 0f, 1f, 0f, 0f, 1f)
    sink.lineTo(width, height - br.p)
    smoothCorner(sink, br, width, height - br.p, 0f, 1f, -1f, 0f)
    sink.lineTo(bl.p, height)
    smoothCorner(sink, bl, bl.p, height, -1f, 0f, 0f, -1f)
    sink.lineTo(0f, tl.p)
    smoothCorner(sink, tl, 0f, tl.p, 0f, -1f, 1f, 0f)
    sink.close()
}

/**
 * One corner in its own frame: x runs along the incoming edge (direction e1), y along the outgoing edge (e2),
 * origin at the corner's start point (sx, sy). The same shape serves all four corners, only the frame turns.
 */
private fun smoothCorner(
    sink: PathSink,
    k: CornerParams,
    sx: Float,
    sy: Float,
    e1x: Float,
    e1y: Float,
    e2x: Float,
    e2y: Float,
) {
    if (k.radius <= 0f) return
    fun px(x: Float, y: Float) = sx + x * e1x + y * e2x
    fun py(x: Float, y: Float) = sy + x * e1y + y * e2y
    val a = k.a
    val b = k.b
    val c = k.c
    val d = k.d
    val l = k.arcSectionLength
    // First Bézier: from the straight edge into the arc.
    sink.cubicTo(px(a, 0f), py(a, 0f), px(a + b, 0f), py(a + b, 0f), px(a + b + c, d), py(a + b + c, d))
    // The circular part, one cubic: tangent angle beta at its start, 90 degrees - beta at its end.
    val reach = 4.0 / 3.0 * tan(k.arcMeasure / 4.0) * k.radius
    val tx0 = (cos(k.beta) * reach).toFloat()
    val ty0 = (sin(k.beta) * reach).toFloat()
    val tx1 = (sin(k.beta) * reach).toFloat()
    val ty1 = (cos(k.beta) * reach).toFloat()
    val ax = a + b + c
    val ay = d
    val bx = ax + l
    val by = ay + l
    sink.cubicTo(
        px(ax + tx0, ay + ty0), py(ax + tx0, ay + ty0),
        px(bx - tx1, by - ty1), py(bx - tx1, by - ty1),
        px(bx, by), py(bx, by),
    )
    // Second Bézier: out of the arc onto the next edge (the first one, mirrored).
    sink.cubicTo(
        px(bx + d, by + c), py(bx + d, by + c),
        px(bx + d, by + b + c), py(bx + d, by + b + c),
        px(bx + d, by + a + b + c), py(bx + d, by + a + b + c),
    )
}

private class ComposePathSink(val path: Path) : PathSink {
    override fun moveTo(x: Float, y: Float) = path.moveTo(x, y)
    override fun lineTo(x: Float, y: Float) = path.lineTo(x, y)
    override fun cubicTo(x1: Float, y1: Float, x2: Float, y2: Float, x3: Float, y3: Float) =
        path.cubicTo(x1, y1, x2, y2, x3, y3)
    override fun close() = path.close()
}

/**
 * A rounded rectangle with smoothed (continuous) corners, [smoothing] 0.6 by default = Figma "iOS".
 * Radii work like `RoundedCornerShape` (also as percent: 50 % is a capsule). A corner that fills its whole
 * side (capsule, circle, radius of half the side or more) has no room to smooth and stays a circular arc, so
 * capsules and circles are exactly as round as before.
 */
class SmoothCornerShape(
    topStart: CornerSize,
    topEnd: CornerSize,
    bottomEnd: CornerSize,
    bottomStart: CornerSize,
    val smoothing: Float = CornerSmoothing,
) : CornerBasedShape(topStart, topEnd, bottomEnd, bottomStart) {

    override fun copy(
        topStart: CornerSize,
        topEnd: CornerSize,
        bottomEnd: CornerSize,
        bottomStart: CornerSize,
    ): SmoothCornerShape = SmoothCornerShape(topStart, topEnd, bottomEnd, bottomStart, smoothing)

    override fun createOutline(
        size: Size,
        topStart: Float,
        topEnd: Float,
        bottomEnd: Float,
        bottomStart: Float,
        layoutDirection: LayoutDirection,
    ): Outline {
        if (topStart + topEnd + bottomEnd + bottomStart == 0f) return Outline.Rectangle(size.toRect())
        val ltr = layoutDirection == LayoutDirection.Ltr
        val tl = if (ltr) topStart else topEnd
        val tr = if (ltr) topEnd else topStart
        val br = if (ltr) bottomEnd else bottomStart
        val bl = if (ltr) bottomStart else bottomEnd
        val corners = cornersFor(size.width, size.height, tl, tr, br, bl, smoothing)
        // Nothing left to smooth (capsule, circle): hand over to the platform's own rounded rectangle.
        if (corners.all { it.radius == 0f || it.arcMeasure >= Math.PI / 2 - 1e-4 }) {
            return Outline.Rounded(
                RoundRect(size.toRect(), CornerRadius(tl), CornerRadius(tr), CornerRadius(br), CornerRadius(bl)),
            )
        }
        val path = Path()
        buildSmoothRoundedRect(ComposePathSink(path), size.width, size.height, tl, tr, br, bl, smoothing)
        return Outline.Generic(path)
    }

    override fun toString(): String =
        "SmoothCornerShape(topStart = $topStart, topEnd = $topEnd, bottomEnd = $bottomEnd, " +
            "bottomStart = $bottomStart, smoothing = $smoothing)"

    override fun equals(other: Any?): Boolean =
        other is SmoothCornerShape && smoothing == other.smoothing && topStart == other.topStart &&
            topEnd == other.topEnd && bottomEnd == other.bottomEnd && bottomStart == other.bottomStart

    override fun hashCode(): Int {
        var result = topStart.hashCode()
        result = 31 * result + topEnd.hashCode()
        result = 31 * result + bottomEnd.hashCode()
        result = 31 * result + bottomStart.hashCode()
        return 31 * result + smoothing.hashCode()
    }
}

/**
 * **The allowed rounded rectangle** (token lint): the same radius on all four corners, smoothed at 60 %.
 * Pass the token's radius unchanged; capsules and circles keep `RoundedCornerShape(50)` / `CircleShape`.
 */
fun smoothRoundedShape(radius: Dp): SmoothCornerShape = SmoothCornerShape(
    CornerSize(radius), CornerSize(radius), CornerSize(radius), CornerSize(radius),
)

/** Per-corner radii (a sheet that is round on top only: `topStart`, `topEnd`), smoothed at 60 %. */
fun smoothRoundedShape(
    topStart: Dp = 0.dp,
    topEnd: Dp = 0.dp,
    bottomEnd: Dp = 0.dp,
    bottomStart: Dp = 0.dp,
): SmoothCornerShape = SmoothCornerShape(
    CornerSize(topStart), CornerSize(topEnd), CornerSize(bottomEnd), CornerSize(bottomStart),
)

/**
 * The same smoothed rounded rectangle as a [Path] at [topLeft] (pixels), for icon glyphs drawn on a canvas
 * (`drawPath`, or `Path.addPath`). One radius on all four corners, smoothed at 60 %.
 */
fun smoothRoundRectPath(topLeft: Offset, size: Size, radius: Float): Path {
    val shape = Path()
    buildSmoothRoundedRect(ComposePathSink(shape), size.width, size.height, radius, radius, radius, radius)
    return Path().apply { addPath(shape, topLeft) }
}
