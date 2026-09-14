package de.paulherter.swiftly

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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Check
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt

/** Antippen ohne Welle — auf iOS sind die Knoepfe `.plain`. */
fun Modifier.antippen(tun: () -> Unit): Modifier = composed {
    clickable(remember { MutableInteractionSource() }, null, onClick = tun)
}

/**
 * **Kopf und Inhalt in einem Messdurchgang** — das Gegenstueck zu `.safeAreaInset(edge: .top)`.
 *
 * Beide Seiten massen ihren Kopf mit `onSizeChanged` und gaben die Hoehe als oberen Abstand
 * an die Liste. Das braucht ein gezeichnetes Bild: beim Bereichswechsel wird die Seite neu
 * aufgebaut, im ersten Bild war die Hoehe null, der Inhalt stand oben und sprang ein Bild
 * spaeter herunter — das Flackern bei jedem Wechsel. Hier wird der Kopf zuerst gemessen und
 * der Inhalt im selben Durchgang mit seiner Hoehe gebaut. Gezeichnet wird der Kopf zuletzt,
 * also ueber dem Inhalt, der darunter durchlaeuft.
 */
@Composable
fun KopfUndInhalt(kopf: @Composable () -> Unit, inhalt: @Composable (kopfhoehe: Dp) -> Unit) {
    SubcomposeLayout(Modifier.fillMaxSize()) { grenzen ->
        val kopfteile = subcompose("kopf", kopf).map { it.measure(grenzen.copy(minWidth = 0, minHeight = 0)) }
        val hoehe = kopfteile.maxOfOrNull { it.height } ?: 0
        val inhaltsteile = subcompose("inhalt") { inhalt(hoehe.toDp()) }.map { it.measure(grenzen) }
        layout(grenzen.maxWidth, grenzen.maxHeight) {
            inhaltsteile.forEach { it.place(0, 0) }
            kopfteile.forEach { it.place(0, 0) }
        }
    }
}

/** Vorlage: `Kopfziele` in `Stil.swift` — Merkliste und Profil, je 44, auf jeder Hauptseite gleich. */
@Composable
fun Kopfziele(app: SwiftlyAnwendung) {
    Row {
        Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Bookmark, contentDescription = uebersetzt("Merkliste"), tint = Stil.schrift, modifier = Modifier.size(20.dp))
        }
        Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) {
            // Das Bild, sonst der Buchstabe — erst, wenn klar ist, dass keins kommt.
            SubcomposeAsyncImage(
                model = app.kern.benutzerbild(90).orElse(null), contentDescription = app.benutzername(),
                contentScale = ContentScale.Crop,
                modifier = Modifier.size(32.dp).clip(CircleShape),
                error = {
                    Box(Modifier.fillMaxSize().background(Stil.erhoeht), contentAlignment = Alignment.Center) {
                        Text(app.benutzername().take(1).uppercase(), color = Stil.schrift,
                             style = Stil.klein.copy(fontWeight = FontWeight.SemiBold))
                    }
                }
            )
        }
    }
}

/** Der Balken unten im Bild — 4 hoch, Akzent auf 25 % Weiss. */
@Composable
fun Fortschrittsbalken(anteil: Double, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(4.dp).background(Color.White.copy(alpha = 0.25f))) {
        Box(Modifier.fillMaxHeight().fillMaxWidth(anteil.toFloat().coerceIn(0f, 1f)).background(Stil.akzent))
    }
}

/** Vorlage: `Wertpille` in `Stil.swift` — zeigt den **Wert**, nicht die Moeglichkeiten. */
@Composable
fun Wertpille(symbol: ImageVector, text: String, tun: () -> Unit) {
    Row(Modifier.height(30.dp).clip(CircleShape).background(Stil.erhoeht).border(1.dp, Stil.rand, CircleShape)
            .antippen(tun).padding(horizontal = 11.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(symbol, contentDescription = null, tint = Stil.schriftLeise, modifier = Modifier.size(14.dp))
        Text(text, style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium), color = Stil.schrift)
    }
}

/** Vorlage: `Kachelplakette` in `Stil.swift` — Haken, „3 offen" oder „2 Staffeln". Die Regel steht in `Anzeigeregeln.kachelmarke`. */
@Composable
fun Kachelplakette(marke: String, zahl: Int, modifier: Modifier = Modifier) {
    val wortlaut = when (marke) {
        "offen" -> uebersetzt("%lld offen", zahl)
        "staffeln" -> if (zahl == 1) uebersetzt("1 Staffel") else uebersetzt("%lld Staffeln", zahl)
        else -> null
    }
    val form = RoundedCornerShape(9.dp)
    Row(modifier.padding(6.dp).clip(form).background(Stil.grund.copy(alpha = 0.78f)).border(1.dp, Stil.rand, form)
            .padding(horizontal = if (wortlaut == null) 5.dp else 6.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        if (marke == "gesehen") Icon(Icons.Filled.Check, contentDescription = null, tint = Stil.schrift, modifier = Modifier.size(11.dp))
        wortlaut?.let { Text(it, style = Stil.plakette, color = Stil.schrift) }
    }
}

/** Vorlage: `Ladefeld` — atmet zwischen halber und voller Deckung, 0,9 s. */
@Composable
fun Ladefeld(modifier: Modifier, ecke: Dp = Stil.eckeKachel) {
    val hell by rememberInfiniteTransition(label = "laden").animateFloat(
        0.5f, 1f, infiniteRepeatable(tween(900, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "hell")
    Box(modifier.graphicsLayer { alpha = hell }.clip(RoundedCornerShape(ecke)).background(Stil.flaeche))
}

/** Vorlage: `Kachelplatzhalter` — Plakat 2:3, darunter zwei Zeilen. */
@Composable
fun Kachelplatzhalter() {
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Ladefeld(Modifier.fillMaxWidth().aspectRatio(2f / 3f))
        Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Ladefeld(Modifier.fillMaxWidth().height(11.dp), 3.dp)
            Ladefeld(Modifier.size(42.dp, 9.dp), 3.dp)
        }
    }
}

/** Vorlage: `Leerzustand` in `Stil.swift` — Kreis mit Zeichen, Kopfzeile, Text, ein Knopf. */
@Composable
fun Leerzustand(symbol: ImageVector, kopfzeile: String, text: String,
                hauptknopf: Pair<String, () -> Unit>? = null, stillerKnopf: Pair<String, () -> Unit>? = null) {
    Column(Modifier.fillMaxSize().padding(horizontal = Stil.randAbstand),
           horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically)) {
        Box(Modifier.size(78.dp).clip(CircleShape).background(Stil.flaeche).border(1.dp, Color.White.copy(alpha = 0.10f), CircleShape),
            contentAlignment = Alignment.Center) {
            Icon(symbol, contentDescription = null, tint = Stil.schriftLeise, modifier = Modifier.size(32.dp))
        }
        Text(kopfzeile, style = TextStyle(fontSize = 19.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.3).sp), color = Stil.schrift)
        Text(text, style = TextStyle(fontSize = 14.sp, lineHeight = 20.sp, textAlign = TextAlign.Center),
             color = Stil.schriftLeise, modifier = Modifier.widthIn(max = 262.dp))
        // Mittig und nur so breit wie der Text — eine Stoerung ist kein Formular.
        hauptknopf?.let { (titel, tun) ->
            Text(titel, style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), color = Stil.grund,
                 modifier = Modifier.clip(CircleShape).background(Stil.akzent).antippen(tun).padding(horizontal = 22.dp, vertical = 12.dp))
        }
        stillerKnopf?.let { (titel, tun) ->
            Text(titel, style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium), color = Stil.schriftLeise,
                 modifier = Modifier.clip(CircleShape).antippen(tun).padding(horizontal = 16.dp, vertical = 10.dp))
        }
    }
}

// MARK: Blatt

data class Wahl(val wert: String, val text: String)

/** Was ein `Auswahlblatt` zeigt. `waehlen` bekommt den `wert` des Eintrags. */
class Blattwunsch(val titel: String, val eintraege: List<Wahl>, val gewaehlt: String?, val waehlen: (String) -> Unit)

/**
 * Vorlage: `Auswahlblatt` + `Blattmodifikator` in `Stil.swift`. **Liegt ueber der Leiste** —
 * auf iOS haengt das Blatt hinter `.bereichsleiste()`. Deshalb haelt es die Hauptansicht
 * (`app.blatt`), nicht die Seite, die es oeffnet.
 */
@Composable
fun Blattauflage(app: SwiftlyAnwendung) {
    val wunsch = app.blatt.value
    // Der letzte Wunsch bleibt, damit die Karte beim Schliessen mit Inhalt hinausfaehrt.
    val gemerkt = remember { arrayOfNulls<Blattwunsch>(1) }
    if (wunsch != null) gemerkt[0] = wunsch
    val offen = wunsch != null
    val schliessen = { app.blatt.value = null }
    BackHandler(enabled = offen, onBack = schliessen)
    val schleier by animateFloatAsState(if (offen) 0.55f else 0f, tween(300), label = "schleier")
    Box(Modifier.fillMaxSize()) {
        if (schleier > 0f) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = schleier)).antippen(schliessen))
        AnimatedVisibility(offen, Modifier.align(Alignment.BottomCenter),
            enter = slideInVertically(tween(300, easing = FastOutSlowInEasing)) { it },
            exit = slideOutVertically(tween(260, easing = FastOutSlowInEasing)) { it }) {
            gemerkt[0]?.let { Blattkarte(it, schliessen) }
        }
    }
}

@Composable
private fun Blattkarte(w: Blattwunsch, schliessen: () -> Unit) {
    val dichte = LocalDensity.current.density
    var zug by remember { mutableFloatStateOf(0f) }
    var hoehe by remember { mutableIntStateOf(1) }
    val oben = RoundedCornerShape(topStart = Stil.eckeFlaeche, topEnd = Stil.eckeFlaeche)
    Column(Modifier.fillMaxWidth()
        .onSizeChanged { hoehe = it.height }
        .graphicsLayer { translationY = zug }
        .clip(oben).background(Stil.flaeche)
        // Nach unten ziehen schliesst ab einem Viertel oder schnell — wie `ziehen` auf iOS.
        .draggable(rememberDraggableState { zug = (zug + it).coerceAtLeast(0f) }, Orientation.Vertical,
            onDragStopped = { tempo -> if (zug > hoehe * 0.25f || tempo > 700 * dichte) schliessen() else zug = 0f })
        .navigationBarsPadding()) {
        Box(Modifier.align(Alignment.CenterHorizontally).padding(top = 8.dp).size(36.dp, 5.dp)
            .clip(CircleShape).background(Color.White.copy(alpha = 0.25f)))
        Text(w.titel, style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.2).sp),
             color = Stil.schrift, maxLines = 1,
             modifier = Modifier.padding(horizontal = Stil.randAbstand).padding(top = 5.dp, bottom = 14.dp))
        Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.linie))
        // So hoch wie die Eintraege, hoechstens 340.
        Column(Modifier.heightIn(max = 340.dp).verticalScroll(rememberScrollState())) {
            w.eintraege.forEach { e ->
                Row(Modifier.fillMaxWidth().height(50.dp).antippen { w.waehlen(e.wert); schliessen() }
                        .padding(horizontal = Stil.randAbstand),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(e.text, style = TextStyle(fontSize = 16.sp), color = Stil.schrift, modifier = Modifier.weight(1f))
                    if (e.wert == w.gewaehlt) Icon(Icons.Filled.Check, contentDescription = null, tint = Stil.akzent, modifier = Modifier.size(16.dp))
                }
                Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.linie))
            }
        }
        Text(uebersetzt("Abbrechen"), style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center),
             color = Stil.schriftLeise, modifier = Modifier.fillMaxWidth().antippen(schliessen).padding(vertical = 17.dp))
    }
}
