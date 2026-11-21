package de.paulherter.swiftly.shared

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.hypot

class SmoothCornersTest {
    private sealed interface Cmd {
        data class Move(val x: Float, val y: Float) : Cmd
        data class Line(val x: Float, val y: Float) : Cmd
        data class Cubic(val p0x: Float, val p0y: Float, val x1: Float, val y1: Float, val x2: Float, val y2: Float, val x3: Float, val y3: Float) : Cmd
        object Close : Cmd
    }

    private class Recorder : PathSink {
        val cmds = mutableListOf<Cmd>()
        var cx = 0f
        var cy = 0f
        override fun moveTo(x: Float, y: Float) { cmds += Cmd.Move(x, y); cx = x; cy = y }
        override fun lineTo(x: Float, y: Float) { cmds += Cmd.Line(x, y); cx = x; cy = y }
        override fun cubicTo(x1: Float, y1: Float, x2: Float, y2: Float, x3: Float, y3: Float) {
            cmds += Cmd.Cubic(cx, cy, x1, y1, x2, y2, x3, y3); cx = x3; cy = y3
        }
        override fun close() { cmds += Cmd.Close }
    }

    private fun path(w: Float, h: Float, tl: Float, tr: Float, br: Float, bl: Float, s: Float = CornerSmoothing): List<Cmd> {
        val r = Recorder()
        buildSmoothRoundedRect(r, w, h, tl, tr, br, bl, s)
        return r.cmds
    }

    private fun Cmd.Cubic.at(t: Float): Pair<Float, Float> {
        val u = 1 - t
        val x = u * u * u * p0x + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3
        val y = u * u * u * p0y + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3
        return x to y
    }

    private fun near(expected: Float, actual: Float, eps: Float = 1e-3f) =
        assertEquals(expected, actual, eps)

    @Test
    fun cornerNumbersMatchFigmaSquircleFor60PercentAtRadius20() {
        val k = cornerParams(20f, 0.6f, 50f)
        near(32f, k.p)          // (1 + 0.6) * r
        near(8.738f, k.arcSectionLength, 5e-3f)
        near(4.277f, k.c, 5e-3f)
        near(2.179f, k.d, 5e-3f)
        near(5.602f, k.b, 5e-3f)
        near(11.204f, k.a, 1e-2f)
        near(36f, Math.toDegrees(k.arcMeasure).toFloat(), 1e-3f)
    }

    @Test
    fun cornerPointsOfASquareBoxAreTheTangentPointsOnTheEdges() {
        val cmds = path(100f, 100f, 20f, 20f, 20f, 20f)
        val start = cmds[0] as Cmd.Move
        near(68f, start.x); near(0f, start.y)
        val lines = cmds.filterIsInstance<Cmd.Line>()
        assertEquals(3, lines.size)
        listOf(100f to 68f, 32f to 100f, 0f to 32f).zip(lines).forEach { (e, l) -> near(e.first, l.x); near(e.second, l.y) }
        // Every corner ends exactly where the next straight edge starts.
        val cubics = cmds.filterIsInstance<Cmd.Cubic>()
        assertEquals(12, cubics.size)
        val ends = listOf(cubics[2], cubics[5], cubics[8], cubics[11])
        val expected = listOf(100f to 32f, 68f to 100f, 0f to 68f, 32f to 0f)
        ends.zip(expected).forEach { (c, e) -> near(e.first, c.x3); near(e.second, c.y3) }
        assertEquals(Cmd.Close, cmds.last())
    }

    @Test
    fun theCornerCrossesTheDiagonalAndAllFourCornersAreAlike() {
        val cubics = path(100f, 100f, 20f, 20f, 20f, 20f).filterIsInstance<Cmd.Cubic>()
        // The middle cubic of each corner is the circular part; its midpoint lies on the box diagonal.
        val mids = listOf(1, 4, 7, 10).map { cubics[it].at(0.5f) }
        near(100f, mids[0].first + mids[0].second, 1e-2f)  // top right: x + y = 100
        near(0f, mids[1].first - mids[1].second, 1e-2f)    // bottom right: x = y
        near(100f, mids[2].first + mids[2].second, 1e-2f)  // bottom left: x + y = 100
        near(0f, mids[3].first - mids[3].second, 1e-2f)    // top left: x = y
        val cornerPoints = listOf(100f to 0f, 100f to 100f, 0f to 100f, 0f to 0f)
        val depth = mids.zip(cornerPoints).map { (m, c) -> hypot(m.first - c.first, m.second - c.second) }
        depth.forEach { near(depth[0], it, 1e-2f) }
        // A continuous corner cuts the diagonal a little deeper than the circular one (20 * (sqrt 2 - 1) = 8.28).
        assertTrue("diagonal cut ${depth[0]}", depth[0] > 8.28f && depth[0] < 10f)
    }

    @Test
    fun capsuleFallsBackToPlainCircularArcs() {
        // 100 x 40 with radius 20 on every corner: no room to smooth, the end caps are half circles.
        val cmds = path(100f, 40f, 20f, 20f, 20f, 20f)
        val cubics = cmds.filterIsInstance<Cmd.Cubic>()
        // Right cap is centred on (80, 20): points of its arc cubic stay 20 away (cubic arc error is tiny).
        val arcs = cubics.filterIndexed { i, _ -> i % 3 == 1 }
        for ((i, c) in arcs.withIndex()) {
            val cx = if (i < 2) 80f else 20f
            for (t in listOf(0f, 0.25f, 0.5f, 0.75f, 1f)) {
                val (x, y) = c.at(t)
                assertEquals("corner $i t=$t", 20f, hypot(x - cx, y - 20f), 0.06f)
            }
        }
        // The two Bézier legs of a capsule corner have no length.
        val flat = cubics.filterIndexed { i, _ -> i % 3 != 1 }
        flat.forEach { c -> near(0f, hypot(c.x3 - c.p0x, c.y3 - c.p0y)) }
    }

    @Test
    fun smoothingShrinksWhenTheEdgeHasNoRoomForIt() {
        // Radius 40 on a 100 box: the corner may use 50 px of each edge, so p is capped at 50 and smoothing at 0.25.
        val k = cornerParams(40f, 0.6f, 50f)
        near(50f, k.p)
        near(67.5f, Math.toDegrees(k.arcMeasure).toFloat(), 1e-2f)   // smoothing 0.25 -> arc of 90 * 0.75 degrees
        // Exactly half the side: smoothing is gone.
        val half = cornerParams(50f, 0.6f, 50f)
        near(50f, half.p)
        near(0f, half.a)
        near(0f, half.d)
        near(90f, Math.toDegrees(half.arcMeasure).toFloat(), 1e-3f)
    }

    @Test
    fun cornersWithoutRadiusStaySharpAndThePathStaysInsideTheBox() {
        // A sheet that is round on top only.
        val cmds = path(200f, 120f, 28f, 28f, 0f, 0f)
        val lines = cmds.filterIsInstance<Cmd.Line>()
        assertEquals(3, lines.size)
        listOf(200f to 120f, 0f to 120f, 0f to 44.8f).zip(lines).forEach { (e, l) -> near(e.first, l.x); near(e.second, l.y) }
        for (c in cmds.filterIsInstance<Cmd.Cubic>()) {
            for (i in 0..20) {
                val (x, y) = c.at(i / 20f)
                assertTrue("($x, $y)", x in -1e-3f..200.001f && y in -1e-3f..120.001f)
            }
        }
    }

    @Test
    fun smoothingZeroIsTheCircularRoundedRectangle() {
        val cmds = path(100f, 100f, 20f, 20f, 20f, 20f, s = 0f)
        near(80f, (cmds[0] as Cmd.Move).x)
        val c = cmds.filterIsInstance<Cmd.Cubic>()[1]
        for (t in listOf(0f, 0.3f, 0.5f, 0.8f, 1f)) {
            val (x, y) = c.at(t)
            assertEquals(20f, hypot(x - 80f, y - 20f), 0.06f)
        }
        assertTrue(abs(c.x3 - 100f) < 1e-3f && abs(c.y3 - 20f) < 1e-3f)
    }
}
