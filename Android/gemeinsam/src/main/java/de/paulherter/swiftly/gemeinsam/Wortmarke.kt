package de.paulherter.swiftly.gemeinsam

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

/** Vorlage: `Wortmarke` in `Sources/Shared/Marken.swift` — dieselben Pfade, dieselbe Box. */
@Composable
fun Wortmarke(hoehe: Dp = 32.dp, schrift: Color = Stil.schrift, akzent: Color = Color(Markenpfade.akzent)) {
    val schriftPfad = remember { PathParser().parsePathString(Markenpfade.wortmarke).toPath() }
    val akzentPfad = remember { PathParser().parsePathString(Markenpfade.wortmarkeAkzent).toPath() }
    val breite = hoehe * (Markenpfade.rahmenBreite / Markenpfade.rahmenHoehe)
    Canvas(Modifier.width(breite).height(hoehe)) {
        val s = size.height / Markenpfade.rahmenHoehe
        scale(s, s, pivot = androidx.compose.ui.geometry.Offset.Zero) {
            translate(-Markenpfade.rahmenX, -Markenpfade.rahmenY) {
                drawPath(schriftPfad, schrift)
                drawPath(akzentPfad, akzent)
            }
        }
    }
}
