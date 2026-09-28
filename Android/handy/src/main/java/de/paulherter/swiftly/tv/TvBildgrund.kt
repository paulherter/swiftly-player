package de.paulherter.swiftly.tv

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import de.paulherter.swiftly.Bildfarbflaeche
import de.paulherter.swiftly.Bildton
import de.paulherter.swiftly.Rauschen
import de.paulherter.swiftly.gemeinsam.Stil

/**
 * Vorlage: `Bildgrund` in `Sources/tvOS/TVBildgrund.swift` — faerbt den Grund einer ganzen Seite nach ihrer
 * Kulisse. Ganz hinten in der Seite einsetzen (siehe `TvHaupt.kt`: `Stil.grund` liegt schon hinter der
 * ganzen App, `TvBildgrund` gehoert darueber, unter allem Inhalt der Seite).
 *
 * **Die Rechnung steht im Paket** (`Bildtonrechnung`, ueber `Bildton` in `Bildfarbe.kt`): Toene aus dem
 * Bild und die Farbe an jeder Stelle, oben rechts an der Kulisse am hellsten. Bis 27.09.2026 stand hier
 * eine Kotlin-Abschrift der Toenerechnung und statt des Netzes ein Verlauf mit drei Flecken; jetzt tastet
 * der Kern dieselbe Farbe ab, die tvOS als `MeshGradient` zeichnet, und das Bild wird bilinear aufgezogen.
 *
 * `bild` ist dieselbe Adresse, die `Kulisse(bild, …)` zeichnet.
 */
@Composable
fun TvBildgrund(bild: String?, modifier: Modifier = Modifier) {
    val kontext = LocalContext.current

    // Anfangswert aus dem Gedaechtnis, nicht aus dem Nichts — damit diese Seite im ersten Bild
    // schon den Ton zeigt, wenn ein anderer Aufruf (etwa die Startseite) ihn bereits kennt.
    var jetzt by remember { mutableStateOf(bild?.let { Bildton.gemerkt(it) } ?: emptyList()) }
    var vorher by remember { mutableStateOf<List<Double>?>(null) }
    val deckung = remember { Animatable(1f) }

    // **Nur wirklich Neues blendet** — wie `Bildgrund.body` (`.task(id: url)`): ist der Ton schon gemerkt,
    // wird er ohne Animation gesetzt, berechnet wird mit 400 ms `easeInOut`.
    LaunchedEffect(bild) {
        val gemerkt = bild?.let { Bildton.gemerkt(it) }
        val neu = when {
            bild == null -> emptyList()
            gemerkt != null -> gemerkt
            else -> Bildton.toene(kontext, bild)
        }
        if (neu == jetzt && vorher == null) return@LaunchedEffect
        if (gemerkt != null) {
            vorher = null; jetzt = neu; deckung.snapTo(1f)
            return@LaunchedEffect
        }
        vorher = jetzt; jetzt = neu
        deckung.snapTo(0f)
        deckung.animateTo(1f, tween(400, easing = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)))
        vorher = null
    }

    Box(modifier.fillMaxSize()) {
        vorher?.let { Grundflaeche(it) }
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = deckung.value }) { Grundflaeche(jetzt) }
    }
}

/**
 * Der Grund einer Seite: `Bildtonrechnung.punkte` ueber die ganze Flaeche, ohne Auslauf (`ab` jenseits
 * des Randes) — 16 × 9 Punkte, bilinear aufgezogen. Ohne Toene der reine `Stil.grund`.
 */
@Composable
private fun Grundflaeche(stand: List<Double>) {
    val flaeche = remember(stand) { Bildfarbflaeche.aus(stand, 16, 9, 1.0, 1.0, 2.0, 0.0) }
    Canvas(Modifier.fillMaxSize()) {
        if (flaeche == null) { drawRect(Stil.grund); return@Canvas }
        flaeche.zeichnen(this, size.width, size.height)
        // Der letzte Rest gegen Baender — siehe `Rauschen`/`Bildton.rauschen`.
        Rauschen.zeichnen(this, size.width, size.height)
    }
}
