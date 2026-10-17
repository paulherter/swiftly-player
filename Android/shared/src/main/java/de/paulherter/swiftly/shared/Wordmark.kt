package de.paulherter.swiftly.shared

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Mirrors `Wordmark` in `Marks.swift`: same paths, same box. */
@Composable
fun Wordmark(height: Dp = 32.dp, font: Color = Theme.font, accent: Color = Color(MarksPaths.accent)) {
    val fontPath = remember { PathParser().parsePathString(MarksPaths.wordmark).toPath() }
    val accentPath = remember { PathParser().parsePathString(MarksPaths.wordmarkAccent).toPath() }
    val width = height * (MarksPaths.frameWidth / MarksPaths.frameHeight)
    Canvas(Modifier.width(width).height(height)) {
        val s = size.height / MarksPaths.frameHeight
        scale(s, s, pivot = androidx.compose.ui.geometry.Offset.Zero) {
            translate(-MarksPaths.frameX, -MarksPaths.frameY) {
                drawPath(fontPath, font)
                drawPath(accentPath, accent)
            }
        }
    }
}
