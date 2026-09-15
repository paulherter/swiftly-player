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
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.uebersetzt

/**
 * Das Mass des Bereichswechsels — `bereichsinhalt()` liest es. Nur der Inhalt waechst, nicht der
 * Kopf: der liegt fest wie die Leiste unten.
 */
val LocalBereichsmass = staticCompositionLocalOf<Animatable<Float, AnimationVector1D>?> { null }

/** `bereichsinhalt()` — waechst von unten, damit die sichtbare Unterkante stehen bleibt. */
fun Modifier.bereichsinhalt(): Modifier = composed {
    val mass = LocalBereichsmass.current
    if (mass == null) Modifier
    else Modifier.graphicsLayer { val m = mass.value; scaleX = m; scaleY = m; transformOrigin = TransformOrigin(0.5f, 1f) }
}

/**
 * **Einmal einblenden**, wenn es zum ersten Mal erscheint — `PosterTile.da`. Gemerkt ueber den
 * Bereichswechsel hinweg: auf iOS bleibt der Bereich stehen und blendet dann nicht erneut ein.
 */
fun Modifier.einblenden(): Modifier = composed {
    var da by rememberSaveable { mutableStateOf(false) }
    val deckung = remember { Animatable(if (da) 1f else 0f) }
    LaunchedEffect(Unit) { if (!da) { deckung.animateTo(1f, Bewegung.einblenden()); da = true } }
    Modifier.graphicsLayer { alpha = deckung.value }
}

/**
 * `Druckzeile` — **Zeilen dunkeln ab, Knoepfe schrumpfen.** Der Druck kommt sofort; das
 * Loslassen klingt 120 ms nach. Eine Dauer auf dem Finger fuehlt sich wie Verzoegerung an.
 */
fun Modifier.druckzeile(tun: () -> Unit): Modifier = composed {
    val quelle = remember { MutableInteractionSource() }
    val gedrueckt by quelle.collectIsPressedAsState()
    val schleier = remember { Animatable(0f) }
    LaunchedEffect(gedrueckt) { if (gedrueckt) schleier.snapTo(1f) else schleier.animateTo(0f, Bewegung.loslassen()) }
    Modifier.drawBehind { drawRect(Color.White.copy(alpha = 0.06f * schleier.value)) }.clickable(quelle, null, onClick = tun)
}

enum class Ruck { Leicht, Mittel, Erfolg }

/** `Stil.ruck` — beim Druecken, nie erst auf die Antwort des Servers: ein spaeter Ruck gehoert zu nichts. */
@Composable
fun rememberRuck(): (Ruck) -> Unit {
    val ansicht = LocalView.current
    return remember(ansicht) {
        { r ->
            ansicht.performHapticFeedback(when (r) {
                Ruck.Leicht -> HapticFeedbackConstants.CLOCK_TICK
                Ruck.Mittel -> HapticFeedbackConstants.CONTEXT_CLICK
                Ruck.Erfolg -> if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.CONTEXT_CLICK
            })
        }
    }
}

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
fun Kopfziele(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit) {
    Row {
        Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Bookmark, contentDescription = uebersetzt("Merkliste"), tint = Stil.schrift, modifier = Modifier.size(20.dp))
        }
        Box(Modifier.size(44.dp).antippen { oeffnen(Ziel("profil", uebersetzt("Profil"), "Profil")) }, contentAlignment = Alignment.Center) {
            Profilbild(app, 32.dp)
        }
    }
}

/** Das Bild des Kontos, sonst der Buchstabe — erst, wenn klar ist, dass keins kommt (`Profilzeichen`). */
@Composable
fun Profilbild(app: SwiftlyAnwendung, groesse: Dp) {
    SubcomposeAsyncImage(
        model = app.kern.benutzerbild((groesse.value * 3).toLong()).orElse(null), contentDescription = app.benutzername(),
        contentScale = ContentScale.Crop,
        modifier = Modifier.size(groesse).clip(CircleShape),
        error = {
            Box(Modifier.fillMaxSize().background(Stil.erhoeht), contentAlignment = Alignment.Center) {
                Text(app.benutzername().take(1).uppercase(), color = Stil.schrift,
                     style = TextStyle(fontSize = (groesse.value * 0.38f).sp, fontWeight = FontWeight.SemiBold))
            }
        }
    )
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
    // Erscheint mit Deckkraft und aus 0,97 — `.opacity.combined(with: .scale(0.97))`.
    val ein = remember { Animatable(0f) }
    LaunchedEffect(Unit) { ein.animateTo(1f, Bewegung.einblenden()) }
    Column(Modifier.fillMaxSize().graphicsLayer { alpha = ein.value; val m = 0.97f + 0.03f * ein.value; scaleX = m; scaleY = m }
               .padding(horizontal = Stil.randAbstand),
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

/**
 * Vorlage: `Wischzeile` in `Stil.swift` — nach links ziehen zeigt eine Handlung, 96 breit.
 * **Offen oder zu, nie dazwischen.** Ueber 168 gezogen loest sie selbst aus und schnappt zu —
 * die Zeile aendert im selben Augenblick ihren Haken, das verdeckt das Zuschnappen.
 * Die Farbe dahinter erscheint erst beim Ziehen, sonst blitzt sie beim Aufbau der Liste.
 */
@Composable
fun Wischzeile(symbol: ImageVector, text: String, farbe: Color = Stil.akzent, tun: () -> Unit, inhalt: @Composable () -> Unit) {
    val dichte = LocalDensity.current
    val feld = with(dichte) { 96.dp.toPx() }
    val schwelle = with(dichte) { 168.dp.toPx() }
    val weg = remember { Animatable(0f) }
    val lauf = rememberCoroutineScope()
    Box(Modifier.fillMaxWidth()) {
        Box(Modifier.matchParentSize().graphicsLayer { alpha = if (weg.value < -0.5f) 1f else 0f }.background(farbe)) {
            Column(Modifier.align(Alignment.CenterEnd).width(96.dp).fillMaxHeight()
                    .antippen { lauf.launch { weg.snapTo(0f) }; tun() },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Icon(symbol, contentDescription = null, tint = Stil.grund, modifier = Modifier.size(20.dp))
                Text(text, style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium), color = Stil.grund)
            }
        }
        Box(Modifier.graphicsLayer { translationX = weg.value }.background(Stil.grund)
            .draggable(rememberDraggableState { d -> lauf.launch { weg.snapTo((weg.value + d).coerceAtMost(0f)) } },
                Orientation.Horizontal,
                onDragStopped = { tempo ->
                    when {
                        -weg.value > schwelle -> { tun(); weg.snapTo(0f) }
                        -weg.value > feld / 2 || tempo < -700 * dichte.density -> weg.animateTo(-feld, Bewegung.sprung())
                        else -> weg.animateTo(0f, Bewegung.sprung())
                    }
                })) {
            inhalt()
        }
    }
}

// MARK: Blatt

data class Wahl(val wert: String, val text: String)

/** Was ein `Auswahlblatt` zeigt. `waehlen` bekommt den `wert` des Eintrags. */
class Blattwunsch(val titel: String, val eintraege: List<Wahl>, val gewaehlt: String?,
                  /** Zeichen je `wert` — das `Handlungsblatt` auf iOS; ohne sie das `Auswahlblatt`. */
                  val symbole: Map<String, ImageVector> = emptyMap(), val waehlen: (String) -> Unit)

/**
 * Vorlage: `Auswahlblatt` + `Blattmodifikator` in `Stil.swift`. **Liegt ueber der Leiste** —
 * auf iOS haengt das Blatt hinter `.bereichsleiste()`. Deshalb haelt es die Hauptansicht
 * (`app.blatt`), nicht die Seite, die es oeffnet.
 *
 * Die Karte federt wie Apples Blatt (`blattbewegung`), folgt dem Finger 1:1 nach unten und
 * nach oben nur gegen die Gummikante; der Schleier hellt beim Ziehen mit auf.
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
    val zug = remember { Animatable(0f) }
    var hoehe by remember { mutableIntStateOf(1) }
    LaunchedEffect(wunsch) { if (wunsch != null) zug.snapTo(0f) }
    val schleier by animateFloatAsState(if (offen) 0.55f else 0f, Bewegung.blatt(), label = "schleier")
    Box(Modifier.fillMaxSize()) {
        if (schleier > 0.001f) Box(Modifier.fillMaxSize()
            .graphicsLayer { alpha = 1f - (zug.value / hoehe).coerceIn(0f, 1f) }
            .background(Color.Black.copy(alpha = schleier)).antippen(schliessen))
        AnimatedVisibility(offen, Modifier.align(Alignment.BottomCenter),
            enter = slideInVertically(Bewegung.blatt()) { it },
            exit = slideOutVertically(Bewegung.blatt()) { it }) {
            gemerkt[0]?.let { w -> Blattkarte(w, zug, { h -> hoehe = h }, schliessen) }
        }
    }
}

/** Die Gummikante von `UIScrollView` — Apples Beiwert c = 0,55. */
private fun gummi(weg: Float, d: Float): Float = (1f - 1f / (weg * 0.55f / d + 1f)) * d

@Composable
private fun Blattkarte(w: Blattwunsch, zug: Animatable<Float, AnimationVector1D>, hoeheMelden: (Int) -> Unit, schliessen: () -> Unit) {
    val dichte = LocalDensity.current.density
    val lauf = rememberCoroutineScope()
    var hoehe by remember { mutableIntStateOf(1) }
    val roh = remember { floatArrayOf(0f) }
    val oben = RoundedCornerShape(topStart = Stil.eckeFlaeche, topEnd = Stil.eckeFlaeche)
    Column(Modifier.fillMaxWidth()
        .onSizeChanged { hoehe = it.height; hoeheMelden(it.height) }
        .graphicsLayer { translationY = zug.value }
        // Die Flaeche reicht unter die Karte: federt sie ueber ihr Ziel, sieht man nichts darunter.
        .drawBehind { drawRect(Stil.flaeche, topLeft = Offset(0f, size.height - 1f), size = Size(size.width, 400.dp.toPx())) }
        .clip(oben).background(Stil.flaeche)
        .draggable(rememberDraggableState { d ->
                roh[0] += d
                val ziel = if (roh[0] >= 0f) roh[0] else -gummi(-roh[0], hoehe.toFloat())
                lauf.launch { zug.snapTo(ziel) }
            }, Orientation.Vertical,
            onDragStarted = { roh[0] = zug.value },
            onDragStopped = { tempo ->
                // Ein Viertel der Hoehe oder ein schneller Wurf schliesst; sonst mit Schwung zurueck.
                if (zug.value > hoehe * 0.25f || tempo > 700 * dichte) schliessen()
                else { roh[0] = 0f; zug.animateTo(0f, spring(dampingRatio = 0.956f, stiffness = 280f), initialVelocity = tempo) }
            })
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
                Row(Modifier.fillMaxWidth().height(50.dp).druckzeile { schliessen(); w.waehlen(e.wert) }
                        .padding(horizontal = Stil.randAbstand),
                    verticalAlignment = Alignment.CenterVertically) {
                    w.symbole[e.wert]?.let {
                        Icon(it, contentDescription = null, tint = Stil.schrift, modifier = Modifier.width(20.dp).height(17.dp))
                        Spacer(Modifier.width(14.dp))
                    }
                    Text(e.text, style = TextStyle(fontSize = 16.sp), color = Stil.schrift, modifier = Modifier.weight(1f))
                    if (e.wert == w.gewaehlt) Icon(Icons.Filled.Check, contentDescription = null, tint = Stil.akzent, modifier = Modifier.size(16.dp))
                }
                // Mit Zeichen beginnt die Linie hinter ihnen — `trennEinzug`.
                Box(Modifier.padding(start = if (w.symbole.isEmpty()) 0.dp else Stil.randAbstand + 34.dp)
                    .fillMaxWidth().height(1.dp).background(Stil.linie))
            }
        }
        Text(uebersetzt("Abbrechen"), style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center),
             color = Stil.schriftLeise, modifier = Modifier.fillMaxWidth().druckzeile(schliessen).padding(vertical = 17.dp))
    }
}
