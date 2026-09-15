package de.paulherter.swiftly.tv

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.gemeinsam.Stil

/**
 * Vorlage: `Sources/tvOS/Stil.swift`. **Punkte halbiert zu dp** — tvOS rechnet auf 1920 Punkt,
 * ein 1080p-Fernseher hat unter Android 960 dp. Farben kommen unveraendert aus `Stil`.
 *
 * Die eine Regel, die alles traegt: **Fokus ist weiss, Auswahl ist Akzent.**
 */
object TvStil {
    val randSeite = 40.dp
    val randOben = 30.dp
    val leisteHoehe = 34.dp
    val kachelAbstand = 20.dp
    val posterBreite = 104.dp
    val posterHoehe = 156.dp
    val querBreite = 224.dp
    val querHoehe = 126.dp
    val heldenHoehe = 255.dp
    /** 28 Luecke + 10 Luft + 12 Kopfluft — die Luft faengt die Lupe auf. */
    val reihenAbstand = 36.dp
    val reihenLuft = 10.dp
    val titelAbstand = 18.dp
    val knopfHoehe = 38.dp
    val chipHoehe = 24.dp
    val zeilenHoehe = 42.dp
    val ecke = 6.dp
    val eckeKachel = 8.dp
    const val gitterSpalten = 7
    val gitterSpalte = 25.dp
    val gitterZeile = 36.dp

    /** Bewusst wenig: Apples Karte springt weiter und schiebt die Nachbarn optisch weg. */
    const val fokusLupe = 1.08f
    val fokusflaeche = Color.White.copy(alpha = 0.12f)
    /** `.easeOut(duration: 0.14)`. */
    val fokusKurve = CubicBezierEasing(0f, 0f, 0.58f, 1f)
    const val fokusDauer = 140

    val titelGross = TextStyle(fontSize = 28.5.sp, fontWeight = FontWeight.Bold)
    val auskunftTitel = TextStyle(fontSize = 30.sp, fontWeight = FontWeight.Bold)
    val reihe = TextStyle(fontSize = 19.sp, fontWeight = FontWeight.SemiBold)
    val koerper = TextStyle(fontSize = 14.5.sp)
    val kachel = TextStyle(fontSize = 13.5.sp, fontWeight = FontWeight.Medium)
    val klein = TextStyle(fontSize = 12.5.sp)
}

/**
 * Eine fokussierbare Flaeche mit Lupe — `KachelStil`, `KnopfStil`, `ReiterStil` teilen sich das.
 * **Keine Schatten, kein Leuchten, kein Ring:** zwei Anlaeufe damit sahen an einer Einzelkachel
 * sauber aus und in einer Reihe mit sechs Nachbarn matschig.
 */
@Composable
fun Fokusflaeche(modifier: Modifier = Modifier, lupe: Float = TvStil.fokusLupe, fokusGeaendert: (Boolean) -> Unit = {},
                 tun: () -> Unit, inhalt: @Composable BoxScope.(fokus: Boolean) -> Unit) {
    var fokus by remember { mutableStateOf(false) }
    val mass by animateFloatAsState(if (fokus) lupe else 1f, tween(TvStil.fokusDauer, easing = TvStil.fokusKurve), label = "lupe")
    Box(modifier
            .onFocusChanged { if (fokus != it.isFocused) { fokus = it.isFocused; fokusGeaendert(it.isFocused) } }
            .graphicsLayer { scaleX = mass; scaleY = mass }
            .clickable(remember { MutableInteractionSource() }, null, onClick = tun)) {
        inhalt(fokus)
    }
}

/**
 * Vorlage: `KnopfStil` — die fokussierte Fassung ist Zeichen fuer Zeichen der Hauptknopf vom iPhone:
 * weiss mit dunkler Schrift. Ohne Fokus 10 % weiss.
 */
@Composable
fun TvKnopf(text: String?, symbol: ImageVector? = null, modifier: Modifier = Modifier, hoehe: Dp = TvStil.knopfHoehe,
            fokusGeaendert: (Boolean) -> Unit = {}, tun: () -> Unit) {
    Fokusflaeche(modifier, lupe = 1.04f, fokusGeaendert = fokusGeaendert, tun = tun) { fokus ->
        val farbe = if (fokus) Stil.grund else Stil.schrift
        Row(Modifier.height(hoehe).then(if (text == null) Modifier.width(hoehe) else Modifier)
                .clip(RoundedCornerShape(TvStil.ecke))
                .background(if (fokus) Color.White else Color.White.copy(alpha = 0.10f))
                .padding(horizontal = if (text == null) 0.dp else 20.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
            symbol?.let { Icon(it, contentDescription = text, tint = farbe, modifier = Modifier.size(17.dp)) }
            text?.let { Text(it, style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), color = farbe, maxLines = 1) }
        }
    }
}

/** Vorlage: `ChipStil` — drei Zustaende: gewaehlt weiss, fokussiert ruhig, sonst erhoeht. */
@Composable
fun TvChip(text: String, an: Boolean, modifier: Modifier = Modifier, tun: () -> Unit) {
    Fokusflaeche(modifier, lupe = 1.06f, tun = tun) { fokus ->
        Box(Modifier.height(TvStil.chipHoehe).clip(CircleShape)
                .background(when { an -> Color.White; fokus -> TvStil.fokusflaeche; else -> Stil.erhoeht })
                .border(1.dp, if (fokus && !an) Color.White.copy(alpha = 0.5f) else Color.Transparent, CircleShape)
                .padding(horizontal = 14.dp),
            contentAlignment = Alignment.Center) {
            Text(text, style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium), color = if (an) Stil.grund else Stil.schrift, maxLines = 1)
        }
    }
}

/** Vorlage: `ZeilenStil` — Auswahllisten und Handlungstafel: keine Lupe, nur eine ruhige Flaeche. */
@Composable
fun TvZeile(text: String, symbol: ImageVector? = null, rechts: String? = null, haken: Boolean = false,
            modifier: Modifier = Modifier, tun: () -> Unit) {
    Fokusflaeche(modifier.fillMaxWidth(), lupe = 1f, tun = tun) { fokus ->
        Row(Modifier.fillMaxWidth().height(TvStil.zeilenHoehe).clip(RoundedCornerShape(TvStil.ecke))
                .background(if (fokus) TvStil.fokusflaeche else Color.Transparent).padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            symbol?.let { Icon(it, contentDescription = null, tint = Stil.schrift, modifier = Modifier.size(18.dp)) }
            Text(text, style = TextStyle(fontSize = 15.5.sp, fontWeight = if (fokus) FontWeight.SemiBold else FontWeight.Normal),
                 color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            rechts?.let { Text(it, style = TextStyle(fontSize = 14.sp), color = Stil.schriftLeise, maxLines = 1) }
            if (haken) Icon(Icons.Filled.Check, contentDescription = null, tint = Stil.akzent, modifier = Modifier.size(18.dp))
        }
    }
}

/**
 * Vorlage: `Kachelinhalt` — Bild, darunter Titel und Unterzeile, **immer da**, nie ueber dem Bild
 * und nie erst mit dem Fokus. Die Lupe ist die einzige Fokusanzeige.
 */
@Composable
fun TvKachel(bild: String?, titel: String, unterzeile: String?, quer: Boolean = false, fortschritt: Double? = null,
             modifier: Modifier = Modifier, deckkraft: Float = 1f, fokusGeaendert: (Boolean) -> Unit = {}, tun: () -> Unit) {
    val breite = if (quer) TvStil.querBreite else TvStil.posterBreite
    Column(modifier.width(breite)) {
        Fokusflaeche(fokusGeaendert = fokusGeaendert, tun = tun) {
            Box(Modifier.size(breite, if (quer) TvStil.querHoehe else TvStil.posterHoehe)
                    .clip(RoundedCornerShape(TvStil.eckeKachel)).background(Stil.flaeche)) {
                AsyncImage(model = bild, contentDescription = titel, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize().alpha(deckkraft))
                fortschritt?.takeIf { it > 0 }?.let { a ->
                    Box(Modifier.align(Alignment.BottomStart).padding(8.dp).fillMaxWidth().height(3.dp).clip(CircleShape)
                            .background(Color.White.copy(alpha = 0.25f))) {
                        Box(Modifier.fillMaxWidth(a.toFloat().coerceIn(0f, 1f)).fillMaxHeight().background(Stil.akzent))
                    }
                }
            }
        }
        Text(titel, style = TvStil.kachel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 7.dp))
        unterzeile?.let { Text(it, style = TvStil.klein, color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 1.dp)) }
    }
}

/** Reihentitel — steht ueber dem Streifen, mit derselben Einrueckung wie die Kacheln. */
@Composable
fun TvReihentitel(text: String, modifier: Modifier = Modifier) {
    Text(text, style = TvStil.reihe, color = Stil.schrift, maxLines = 1,
         modifier = modifier.padding(start = TvStil.randSeite, bottom = TvStil.titelAbstand - TvStil.reihenLuft))
}
