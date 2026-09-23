package de.paulherter.swiftly

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
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.gemeinsam.Hauptknopf
import de.paulherter.swiftly.gemeinsam.StillerKnopf
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.bewegungReduziert
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
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.uebersetzt

/**
 * Das Mass des Bereichswechsels — `bereichsinhalt()` liest es. Nur der Inhalt waechst, nicht der
 * Kopf: der liegt fest wie die Leiste unten.
 */
val LocalBereichsmass = staticCompositionLocalOf<Animatable<Float, AnimationVector1D>?> { null }

/**
 * `bereichsinhalt()` — **Anker oben** (`scaleEffect(anchor: .top)`, BAUTEILE 7). Unten verankert
 * wanderte die obere Kante, und dort liegt der Kopfverlauf; darunter klaffte dann fuer zwei
 * Zehntelsekunden der blanke Grund.
 */
fun Modifier.bereichsinhalt(): Modifier = composed {
    val mass = LocalBereichsmass.current
    if (mass == null) Modifier
    else Modifier.graphicsLayer { val m = mass.value; scaleX = m; scaleY = m; transformOrigin = TransformOrigin(0.5f, 0f) }
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

/**
 * Vorlage: `Stil.Druckknopf` — **jeder Knopf gibt nach**: Massstab 0,97 und Deckkraft 0,85, der
 * Druck sofort, das Loslassen 0,12 s `easeOut`. Keine Welle: die ist Material, nicht diese App.
 * Bei reduzierter Bewegung bleibt nur die Deckkraft.
 */
fun Modifier.antippen(tun: () -> Unit): Modifier = composed {
    val quelle = remember { MutableInteractionSource() }
    val gedrueckt by quelle.collectIsPressedAsState()
    val druck = remember { Animatable(0f) }
    LaunchedEffect(gedrueckt) { if (gedrueckt) druck.snapTo(1f) else druck.animateTo(0f, Bewegung.loslassen()) }
    val ruhig = bewegungReduziert()
    graphicsLayer {
        val d = druck.value
        if (!ruhig) { val m = 1f - (1f - Bewegung.DRUCKMASS) * d; scaleX = m; scaleY = m }
        alpha = 1f - 0.15f * d
    }.clickable(quelle, null, onClick = tun)
}

/** Ein Tipp ohne jede Rueckmeldung — fuer Flaechen, die kein Knopf sind (Schleier, Bildflaeche). */
fun Modifier.tippen(tun: () -> Unit): Modifier = composed {
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

/**
 * Vorlage: `Kopfverlauf` in `Stil.swift` — **dunkel, kein Schein.** Oben kraeftig, unten weich, neun
 * Stuetzpunkte, damit der Abfall nirgends knickt; er reicht 17 unter den Kopf hinaus. Einen farbigen
 * Schein gibt es nicht mehr, er ist bewusst gefallen.
 */
fun DrawScope.kopfverlauf(deckung: Float) {
    if (deckung <= 0f) return
    val g = Stil.grund
    drawRect(Brush.verticalGradient(
        0f to g.copy(alpha = 0.98f), 0.30f to g.copy(alpha = 0.94f), 0.48f to g.copy(alpha = 0.85f),
        0.62f to g.copy(alpha = 0.70f), 0.73f to g.copy(alpha = 0.52f), 0.82f to g.copy(alpha = 0.34f),
        0.89f to g.copy(alpha = 0.19f), 0.95f to g.copy(alpha = 0.09f), 1f to g.copy(alpha = 0f),
        startY = 0f, endY = size.height + 17.dp.toPx()),
        size = Size(size.width, size.height + 17.dp.toPx()), alpha = deckung)
}

/**
 * Vorlage: `Unschaerfekopf(versatz:)` in `Stil.swift` — der Kopf einer Wurzelseite. **Der Inhalt
 * laeuft darunter durch**, und der `kopfverlauf` zieht erst auf, wenn wirklich etwas darunter liegt:
 * ueber die ersten 30 Punkt Weg. Im Ruhezustand deckt er nichts ab, er waere reine Zierde. Keine
 * Haarlinie: der Verlauf laeuft gegen den Grund aus und hat keine Kante, die verdeckt werden muesste.
 *
 * Seitenrand 18, unten 12 — der Kopf endet dort, wo die Scrollflaeche anfaengt.
 */
@Composable
fun Wurzelkopf(versatz: () -> Float, modifier: Modifier = Modifier, rand: Boolean = true, inhalt: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth()
            .drawBehind { kopfverlauf((versatz() / 30f).coerceIn(0f, 1f)) }
            .statusBarsPadding()
            .then(if (rand) Modifier.padding(horizontal = Stil.randAbstand) else Modifier)
            .padding(bottom = 12.dp), content = inhalt)
}

/**
 * Vorlage: `Wertreihe` in `Stil.swift` — „Alle" und „A–Z" **gehen beim Scrollen weg, statt
 * mitzuscrollen**, und zwar **nur ueber die Deckkraft, nie ueber die Hoehe.**
 *
 * Auf dem iPhone hat genau dieses Element vier Anlaeufe gekostet: die Reihe sitzt im Kopf, der
 * Kopf bestimmt, wo die Scrollflaeche anfaengt, und eine Hoehenaenderung aendert den Versatz, der
 * sie steuert — eine Rueckkopplung, die Standbilder und Springen erzeugt (BAUTEILE 10). Deshalb
 * behaelt sie ihren Platz und blendet ueber 44 Punkt Weg aus (30 Pillenhoehe + 14 Abstand).
 * Halb zu nimmt sie keinen Tipp mehr an — ein Blatt aus einer verschwindenden Zeile ist eine Falle.
 */
@Composable
fun Wertreihe(versatz: () -> Float, modifier: Modifier = Modifier, inhalt: @Composable RowScope.() -> Unit) {
    val zu by remember { derivedStateOf { versatz() / Stil.wertreihenWeg.value >= 0.5f } }
    Row(modifier.fillMaxWidth().padding(top = 14.dp)
            .graphicsLayer { alpha = 1f - (versatz() / Stil.wertreihenWeg.value).coerceIn(0f, 1f) }
            .then(if (zu) Modifier.clearAndSetSemantics {}.pointerInput(Unit) {
                awaitPointerEventScope { while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() } }
            } else Modifier),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp), content = inhalt)
}

/** Vorlage: `Zaehlmarke` — 13 Medium, tabellarische Ziffern, `schriftSehrLeise`. */
@Composable
fun Zaehlmarke(anzahl: Int) {
    Text(java.text.NumberFormat.getInstance().format(anzahl), style = Stil.kachel.copy(fontFeatureSettings = "tnum"),
         color = Stil.schriftSehrLeise, modifier = Modifier.semantics { contentDescription = uebersetzt("%lld Titel", anzahl) })
}

/** Vorlage: `Kopfziele` in `Stil.swift` — Merkliste und Profil, je 44, auf jeder Hauptseite gleich. */
@Composable
fun Kopfziele(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit, vorn: @Composable () -> Unit = {}) {
    // `vorn`: was nur eine Seite hat (Bearbeiten auf Downloads) — links vom Rest, weil es kommt und geht.
    Row(verticalAlignment = Alignment.CenterVertically) {
        Uebernahmezeichen(app)
        vorn()
        // Gefuellt, aber kein Zustand: hier ist das Lesezeichen ein Ziel, keine Markierung.
        Box(Modifier.size(44.dp).antippen { oeffnen(Ziel("merkliste", uebersetzt("Merkliste"), "Merkliste")) },
            contentAlignment = Alignment.Center) {
            Symbol(Zeichen.LesezeichenVoll, 20.dp, farbe = Stil.schrift, beschreibung = uebersetzt("Merkliste"))
        }
        // `Profilziel`: das Zeichen 34 in 44 Trefferflaeche, um 7 nach aussen gerueckt, damit der Kreis
        // buendig an der Kante steht und nicht die Trefferflaeche.
        Box(Modifier.offset(x = 7.dp).size(44.dp).antippen { oeffnen(Ziel("profil", uebersetzt("Profil"), "Profil")) }, contentAlignment = Alignment.Center) {
            Profilbild(app, 34.dp)
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
                // Buchstabe = Groesse × 0,38 Semibold (BAUTEILE 6, `Profilzeichen`).
                Text(app.benutzername().take(1).uppercase(), color = Stil.schrift,
                     style = TextStyle(fontSize = (groesse.value * 0.38f).sp, fontWeight = FontWeight.SemiBold))
            }
        }
    )
}

/**
 * Der Balken unten im Bild — buendig an der Unterkante, 4 hoch, eckig.
 *
 * **Die Spur ist weiss 30 %, nicht 25** (BRAND 7): gelesen heisst eine dunkle Spur „hier
 * fehlt etwas", eine helle „so lang ist das Ganze, und so weit bist du". 30 ist als
 * *Flaeche* erlaubt und gewollt; als Schriftfarbe waere derselbe Wert verboten (2,67:1).
 */
@Composable
fun Fortschrittsbalken(anteil: Double, modifier: Modifier = Modifier,
                       /**
                        * **Kapsel, wo er frei in einer Zeile steht** — in der Downloadliste. Auf einer
                        * Kachel bleibt er eckig: dort bildet er die Kante des Bildes. Der gefuellte Teil
                        * ist selbst eine Kapsel, sonst endet er innen gerade.
                        */
                       rund: Boolean = false) {
    val form = if (rund) CircleShape else RectangleShape
    Box(modifier.fillMaxWidth().height(4.dp).clip(form).background(Color.White.copy(alpha = 0.30f))) {
        Box(Modifier.fillMaxHeight().fillMaxWidth(anteil.toFloat().coerceIn(0f, 1f)).clip(form).background(Stil.akzent))
    }
}

/** Vorlage: `Wertpille` in `Stil.swift` — zeigt den **Wert**, nicht die Moeglichkeiten. */
@Composable
fun Wertpille(symbol: Zeichen, text: String, tun: () -> Unit) {
    // **Fuellung ohne Rand, und `flaeche` statt `erhoeht`.** Sie trugen als einzige Knoepfe
    // der App eine Umrandung und sahen deshalb aus wie eine fremde Sorte — Rückmeldung vom 21.09. zu
    // „Alle" und „A–Z": „die sehen optisch so anders aus, die haben so eine Umrandung, die
    // sonst nichts hat." `erhoeht` ist das, was **auf** einer Flaeche liegt; die Pille liegt
    // auf der Seite. `minHeight`, damit wachsende Systemschrift den Text nicht abschneidet.
    Row(Modifier.heightIn(min = Stil.pillenHoehe).clip(CircleShape).background(Stil.flaeche)
            .antippen(tun).padding(horizontal = 11.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Symbol(symbol, 12.dp, farbe = Stil.schriftLeise, staerke = Staerke.Mittel)
        Text(text, style = Stil.kachel, color = Stil.schrift)
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
        if (marke == "gesehen") Symbol(Zeichen.Haken, 10.dp, farbe = Stil.schrift, staerke = Staerke.Halbfett)
        wortlaut?.let { Text(it, style = Stil.plakette, color = Stil.schrift) }
    }
}

/**
 * **Ein Puls fuer alle Platzhalter** — eine Uhr, nicht dreissig. Mit eigener Uhr je Feld atmeten
 * nachgeladene Platzhalter gegen die schon stehenden (iOS hat das aus demselben Grund verworfen).
 */
val LocalLadepuls = compositionLocalOf<State<Float>?> { null }

@Composable
fun Ladepuls(): State<Float> {
    // **„Bewegung reduzieren" haelt eine Endlosschleife nicht an.** Android setzt bei
    // ausgeschalteten Animationen die Dauer aller Compose-Animationen auf null — fuer eine
    // einmalige Bewegung ist das richtig, eine Schleife mit Dauer 0 pulst danach nur hart
    // weiter. Also wird hier gefragt, wie `Stil.bewegungReduziert` auf Apple gefragt wird, und
    // der Platzhalter steht still bei voller Deckung.
    if (bewegungReduziert()) return remember { mutableFloatStateOf(1f) }
    return rememberInfiniteTransition(label = "laden").animateFloat(
        0.5f, 1f, infiniteRepeatable(tween(900, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "hell")
}

/** Vorlage: `Ladefeld` — atmet zwischen halber und voller Deckung, 0,9 s, im gemeinsamen Takt. */
@Composable
fun Ladefeld(modifier: Modifier, ecke: Dp = Stil.eckeKachel) {
    val puls = LocalLadepuls.current
    Box(modifier.graphicsLayer { alpha = puls?.value ?: 0.75f }.clip(RoundedCornerShape(ecke)).background(Stil.flaeche))
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

/**
 * Vorlage: `Leerzustand` in `Sources/Shared/Stil.swift`.
 *
 * **Die Abstaende stehen in der Vorlage, nicht im Gefuehl:** Zeichen 44 im Kreis von 78 ·
 * 22 · Kopfzeile 20 Semibold mit `sperrungReihe` · 7 · Text 15 `schriftLeise`, hoechstens
 * 262 breit · 24 · Hauptknopf · 16 · stiller Knopf. Knoepfe **untereinander**.
 *
 * Vier Dinge standen hier anders und sind nachgezogen (BRAND 5/7):
 * - Der Kreis trug einen Rand. Keine gezeichneten Kanten.
 * - Das Zeichen war 32 statt 44 — „eine Groesse fuer beide, sonst sind es zwei Leerzustaende".
 * - Kopfzeile 19 und Text 14 stehen in **keiner** Leiter; es sind 20 und 15.
 * - Der Hauptknopf war eine **Akzentkapsel**. Der Akzent traegt nie eine Flaeche, und die
 *   eine gefuellte Flaeche der Seite ist weiss mit dunkler Schrift. Er ist jetzt der
 *   geteilte `Hauptknopf`, nur so breit wie sein Text: eine Stoerung ist kein Formular.
 *
 * `laedt` laesst das Zeichen atmen — fuer „wird gerade versucht". Kein Ring: das Zeichen
 * sagt weiter, worum es geht. **Bei reduzierter Bewegung faellt das Atmen weg**; Android
 * setzt nur *einmalige* Animationen auf null, eine Endlosschleife laeuft sonst weiter.
 *
 * **Ein Leerzustand bekommt nur dann einen Knopf, wenn es etwas zu tun gibt.**
 */
@Composable
fun Leerzustand(symbol: Zeichen, kopfzeile: String, text: String, laedt: Boolean = false,
                hauptknopf: Pair<String, () -> Unit>? = null, stillerKnopf: Pair<String, () -> Unit>? = null) {
    // Erscheint mit Deckkraft und aus 0,97 — `.opacity.combined(with: .scale(0.97))`.
    val ein = remember { Animatable(0f) }
    LaunchedEffect(Unit) { ein.animateTo(1f, Bewegung.einblenden()) }
    val ruhig = bewegungReduziert()
    val atem = if (laedt && !ruhig) LocalLadepuls.current?.value ?: 1f else 1f
    Column(Modifier.fillMaxSize().graphicsLayer { alpha = ein.value; val m = 0.97f + 0.03f * ein.value; scaleX = m; scaleY = m }
               .padding(horizontal = 34.dp),
           horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.Center) {
        Box(Modifier.size(Stil.kreisLeer).clip(CircleShape).background(Stil.flaeche),
            contentAlignment = Alignment.Center) {
            Symbol(symbol, 44.dp, Modifier.graphicsLayer { alpha = atem }, farbe = Stil.schriftLeise)
        }
        Text(kopfzeile, style = Stil.reihe, color = Stil.schrift, modifier = Modifier.padding(top = 22.dp, bottom = 7.dp))
        Text(text, style = Stil.koerper.copy(lineHeight = 21.sp, textAlign = TextAlign.Center),
             color = Stil.schriftLeise, modifier = Modifier.widthIn(max = 262.dp))
        hauptknopf?.let { (titel, tun) ->
            Hauptknopf(titel, dehnt = false, modifier = Modifier.padding(top = 24.dp), aktion = tun)
        }
        stillerKnopf?.let { (titel, tun) ->
            StillerKnopf(titel, modifier = Modifier.padding(top = if (hauptknopf == null) 24.dp else 16.dp), aktion = tun)
        }
    }
}

/**
 * **Ein gestoerter Abschnitt *innerhalb* einer Seite.** Vorlage: `Stoerhinweis` in
 * `Sources/Shared/Stil.swift`.
 *
 * Das Gegenstueck zum ganzseitigen `Leerzustand`: dort steht „hier liegt nichts", hier
 * steht „ich weiss es nicht, der Server hat nicht geantwortet". Ein Serverfehler darf
 * nicht als „hier ist nichts" erscheinen — und wo nur die Folgenliste oder die
 * Aehnlichen-Reihe nicht geantwortet hat, steht der Rest der Seite ja da.
 *
 * **Der Wortlaut ist derselbe wie im Leerzustand** — dieselben zwei Katalogschluessel, nur
 * kleiner gesetzt, weil hier der Seitenkopf schon steht. Ein zweiter Wortlaut fuer dieselbe
 * Lage waere eine zweite Antwort auf dieselbe Frage.
 *
 * `adresse`: wer nicht geantwortet hat. Ohne Angabe der eigene Jellyfin; auf einer
 * Seerr-Seite steht dort Seerr — die falsche Adresse waere eine falsche Fehlersuche.
 *
 * `erneut`: **nur, wo es etwas zu wiederholen gibt.** Laedt der Abschnitt mit der ganzen
 * Seite neu, fehlt der Knopf — einer, der die Seite zweimal laedt, ist schlechter als keiner.
 *
 * `abstandOben` ist 40 unter einem Leerhinweis und **0 unter einer Reihenueberschrift**,
 * die ihren Abstand schon mitbringt.
 */
@Composable
fun Stoerhinweis(adresse: String?, modifier: Modifier = Modifier, abstandOben: Dp = 40.dp,
                 erneut: (() -> Unit)? = null) {
    Column(modifier.fillMaxWidth().padding(top = abstandOben, start = 34.dp, end = 34.dp),
           horizontalAlignment = Alignment.CenterHorizontally) {
        // Das einzige Zeichen der App in 30 — der Grad steht in keiner Leiter und ist aus
        // der Vorlage uebernommen, damit derselbe Hinweis auf allen Plattformen gleich
        // aussieht (BAUTEILE 9, Punkt 3: gemeldet, nicht hier entschieden).
        Symbol(Zeichen.ServerWeg, 30.dp, farbe = Stil.schriftLeise)
        Text(uebersetzt("Server ist abgetaucht"), style = Stil.rubrikGross, color = Stil.schrift,
             modifier = Modifier.padding(top = 14.dp, bottom = 6.dp))
        Text(uebersetzt("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                        adresse ?: uebersetzt("Der Server")),
             style = Stil.klein.copy(fontSize = 14.sp, lineHeight = 16.sp, textAlign = TextAlign.Center),
             color = Stil.schriftSehrLeise, modifier = Modifier.widthIn(max = 262.dp))
        erneut?.let { StillerKnopf(uebersetzt("Erneut versuchen"), Modifier.padding(top = 10.dp), it) }
    }
}

/**
 * Vorlage: `Wischzeile` in `Stil.swift` — nach links ziehen zeigt eine Handlung, 96 breit.
 * **Offen oder zu, nie dazwischen.** Ueber 168 gezogen loest sie selbst aus und schnappt zu —
 * die Zeile aendert im selben Augenblick ihren Haken, das verdeckt das Zuschnappen.
 * Die Farbe dahinter erscheint erst beim Ziehen, sonst blitzt sie beim Aufbau der Liste.
 */
@Composable
fun Wischzeile(symbol: Zeichen, text: String, farbe: Color = Stil.akzent, tun: () -> Unit, inhalt: @Composable () -> Unit) {
    val dichte = LocalDensity.current
    val feld = with(dichte) { 96.dp.toPx() }
    val schwelle = with(dichte) { 168.dp.toPx() }
    val weg = remember { Animatable(0f) }
    val lauf = rememberCoroutineScope()
    Box(Modifier.fillMaxWidth()) {
        Box(Modifier.matchParentSize().graphicsLayer { alpha = if (weg.value < -0.5f) 1f else 0f }.background(farbe)) {
            Column(Modifier.align(Alignment.CenterEnd).width(96.dp).fillMaxHeight()
                    .tippen { lauf.launch { weg.snapTo(0f) }; tun() },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Symbol(symbol, 17.dp, farbe = Stil.grund, staerke = Staerke.Halbfett)
                Text(text, style = Stil.klein.copy(fontSize = 11.sp, fontWeight = FontWeight.Medium), color = Stil.grund)
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

/** `neben`: die Angabe hinter dem Text in 12 — „· 10 Folgen" im Staffelblatt von Seerr. */
data class Wahl(val wert: String, val text: String, val neben: String? = null)

/** Was ein `Auswahlblatt` zeigt. `waehlen` bekommt den `wert` des Eintrags. */
class Blattwunsch(val titel: String, val eintraege: List<Wahl>, val gewaehlt: String?,
                  /** Zeichen je `wert` — das `Handlungsblatt` auf iOS; ohne sie das `Auswahlblatt`. */
                  val symbole: Map<String, Zeichen> = emptyMap(),
                  /** Mehrfachauswahl mit Anfangsmenge — dann schliesst ein Tipp nicht, der Fuss bestaetigt. */
                  val mehrfach: Set<String>? = null,
                  /** Zeilen, die nicht waehlbar sind, mit ihrem Grund („vorhanden"). Ein toter Haken waere schlimmer als keiner. */
                  val gesperrt: Map<String, String> = emptyMap(),
                  /** Handlungen in `warnung` — `Titelhandlung.warnend` („Entfernen", „Alles entfernen"). */
                  val warnend: Set<String> = emptySet(),
                  val abschlussText: (Int) -> String = { "" },
                  val abschluss: ((Set<String>) -> Unit)? = null,
                  /** Eigener Inhalt statt der Zeilen — das Ladeblatt hat Werte und Knoepfe, keine Wahl. */
                  val inhalt: (@Composable ColumnScope.(schliessen: () -> Unit) -> Unit)? = null,
                  /**
                   * **Eine Rubrik vor einem Eintrag** (`wert` → Ueberschrift) — Trennstrich, darunter die
                   * Ueberschrift. Im Titelmenue von Filme und Serien steht so „Bibliotheken" ueber den
                   * Bibliotheken, abgesetzt von „Alle" und „Sammlungen", die keine sind (`Auswahlblatt.rubrik`).
                   */
                  val rubriken: Map<String, String> = emptyMap(),
                  val waehlen: (String) -> Unit)

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
    val schleierDa by remember { derivedStateOf { schleier > 0.001f } }
    Box(Modifier.fillMaxSize()) {
        // Deckkraft in der Grafikebene — neu komponiert wird nur, wenn der Schleier kommt oder geht.
        if (schleierDa) Box(Modifier.fillMaxSize()
            .graphicsLayer { alpha = schleier * (1f - (zug.value / hoehe).coerceIn(0f, 1f)) }
            .background(Color.Black).tippen(schliessen))
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
    var auswahl by remember(w) { mutableStateOf(w.mehrfach) }
    // **Ecke 28 (`eckeBlatt`), nicht 16.** Ein Blatt von unten ist die groesste Rundung der
    // Leiter; `eckeFlaeche` gehoert der Tafel im Bild.
    val oben = RoundedCornerShape(topStart = Stil.eckeBlatt, topEnd = Stil.eckeBlatt)
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
                // Geworfen fliegt die Karte mit ihrem Tempo hinaus, statt kurz zu stocken.
                if (zug.value > hoehe * 0.25f || tempo > 700 * dichte) {
                    zug.animateTo(hoehe.toFloat(), Bewegung.wurf(), initialVelocity = tempo.coerceAtLeast(0f))
                    schliessen()
                }
                else { roh[0] = 0f; zug.animateTo(0f, spring(dampingRatio = 0.956f, stiffness = 280f), initialVelocity = tempo) }
            })
        .navigationBarsPadding()) {
        Box(Modifier.align(Alignment.CenterHorizontally).padding(top = 8.dp).size(36.dp, 5.dp)
            .clip(CircleShape).background(Color.White.copy(alpha = 0.18f)))
        // **Rubrik 17 Semibold, oben 5 / unten 14, und ohne Linie darunter** (BAUTEILE 6).
        // Der Strich stand da und trennte die Rubrik von ihren eigenen Zeilen.
        Text(w.titel, style = Stil.rubrikGross,
             color = Stil.schrift, maxLines = 1,
             modifier = Modifier.padding(horizontal = Stil.randAbstand).padding(top = 5.dp, bottom = 14.dp))
        val eigen = w.inhalt
        when {
            eigen != null -> eigen(schliessen)
            w.mehrfach != null -> Staffelwahl(w, auswahl.orEmpty(), { auswahl = it }, schliessen)
            w.symbole.isNotEmpty() -> Handlungen(w, schliessen)
            else -> Auswahlzeilen(w, schliessen)
        }
    }
}

/** Die Abbrechen-Zeile am Fuss eines Blatts — `Blattabbruch`: 15 Medium `schriftLeise`, ≥ 54. */
@Composable
private fun Blattabbruch(schliessen: () -> Unit) {
    Box(Modifier.fillMaxWidth().heightIn(min = 54.dp).druckzeile(schliessen), contentAlignment = Alignment.Center) {
        Text(uebersetzt("Abbrechen"), style = Stil.knopftext, color = Stil.schriftLeise)
    }
}

/** `Blattlinie` — **durchgehend**, von Kartenrand zu Kartenrand. */
@Composable
internal fun Blattlinie() = Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.linie))

/**
 * Vorlage: `Auswahlblatt` in `Stil.swift`. **Der Haken steht links und ist immer da** — als Platz,
 * auch wenn er nichts zeigt, sonst ruecken die Beschriftungen, sobald sich die Wahl aendert.
 * Gewaehlt heisst volles Weiss und Semifett, nicht Akzent: „das hier ist es" ist Rangfolge, kein
 * Zustand. 17 auf ≥ 52, **ohne Linien zwischen den Zeilen**, hoechstens 340 hoch, dann Abbrechen.
 */
@Composable
private fun Auswahlzeilen(w: Blattwunsch, schliessen: () -> Unit) {
    Column(Modifier.heightIn(max = 340.dp).verticalScroll(rememberScrollState())) {
        w.eintraege.forEach { e ->
            w.rubriken[e.wert]?.let { ueber ->
                // `Trennlinie` (ab dem Rand eingerueckt), darunter die Rubrik: 11 Semibold gesperrt in
                // Versalien, `schriftSehrLeise`, oben `kachelAbstand`, unten 4.
                Box(Modifier.padding(start = Stil.randAbstand).fillMaxWidth().height(1.dp).background(Stil.linie))
                Text(ueber.uppercase(), style = Stil.gruppe, color = Stil.schriftSehrLeise,
                     modifier = Modifier.fillMaxWidth().padding(horizontal = Stil.randAbstand)
                         .padding(top = Stil.kachelAbstand, bottom = 4.dp).semantics { heading() })
            }
            val an = e.wert == w.gewaehlt
            Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).druckzeile { schliessen(); w.waehlen(e.wert) }
                    .padding(horizontal = Stil.randAbstand),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(Modifier.width(18.dp), contentAlignment = Alignment.Center) {
                    if (an) Symbol(Zeichen.Haken, 17.dp, farbe = Stil.schrift, staerke = Staerke.Halbfett)
                }
                Text(e.text, style = Stil.rubrikGross.copy(fontWeight = if (an) FontWeight.SemiBold else FontWeight.Normal, letterSpacing = 0.sp),
                     color = if (an) Stil.schrift else Stil.schriftLeise, modifier = Modifier.weight(1f))
            }
        }
    }
    Blattabbruch(schliessen)
}

/**
 * Vorlage: `Handlungsblatt` in `Stil.swift` — jede Zeile loest etwas aus und das Blatt schliesst.
 * Zeichen 17 in 20 Breite, 14 zum Text, Text 17, `warnung` fuer warnende Handlungen. Linien
 * **zwischen** den Zeilen und eine ueber Abbrechen.
 */
@Composable
private fun Handlungen(w: Blattwunsch, schliessen: () -> Unit) {
    w.eintraege.forEachIndexed { i, e ->
        if (i > 0) Blattlinie()
        val farbe = if (e.wert in w.warnend) Stil.warnung else Stil.schrift
        Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).druckzeile { schliessen(); w.waehlen(e.wert) }
                .padding(horizontal = Stil.randAbstand),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(Modifier.width(Stil.zeichenSpalte), contentAlignment = Alignment.Center) {
                w.symbole[e.wert]?.let { Symbol(it, 17.dp, farbe = farbe) }
            }
            Text(e.text, style = Stil.rubrikGross.copy(fontWeight = FontWeight.Normal, letterSpacing = 0.sp), color = farbe,
                 modifier = Modifier.weight(1f))
        }
    }
    Blattlinie()
    Blattabbruch(schliessen)
}

/**
 * Vorlage: `staffelblatt` in `SeerrDetailView.swift` — Kaestchen rechts, Zeilen 15 auf ≥ 50 ohne
 * Linien, hoechstens 320 hoch; darunter eine durchgehende Linie und der Bestaetigungsknopf,
 * 15 Semibold auf ≥ 54, im Akzent, sobald etwas gewaehlt ist.
 */
@Composable
private fun Staffelwahl(w: Blattwunsch, menge: Set<String>, setzen: (Set<String>) -> Unit, schliessen: () -> Unit) {
    Column(Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState())) {
        w.eintraege.forEach { e ->
            val grund = w.gesperrt[e.wert]
            val an = e.wert in menge
            Row(Modifier.fillMaxWidth().heightIn(min = 50.dp)
                    .then(if (grund != null) Modifier else Modifier.druckzeile { setzen(if (an) menge - e.wert else menge + e.wert) })
                    .padding(horizontal = Stil.randAbstand),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(e.text, style = Stil.koerper, color = if (grund == null) Stil.schrift else Stil.schriftSehrLeise)
                e.neben?.let { Text(it, style = Stil.klein, color = Stil.schriftSehrLeise) }
                Spacer(Modifier.weight(1f).widthIn(min = 8.dp))
                if (grund != null) Text(grund, style = Stil.klein, color = Stil.schriftSehrLeise)
                else Symbol(if (an) Zeichen.KaestchenVoll else Zeichen.Kaestchen, 17.dp, farbe = if (an) Stil.akzent else Stil.schriftSehrLeise)
            }
        }
    }
    Blattlinie()
    val abschluss = w.abschluss
    Box(Modifier.fillMaxWidth().heightIn(min = 54.dp)
            .then(if (menge.isEmpty() || abschluss == null) Modifier else Modifier.druckzeile { schliessen(); abschluss(menge) }),
        contentAlignment = Alignment.Center) {
        Text(w.abschlussText(menge.size), style = Stil.listentitel, color = if (menge.isEmpty()) Stil.schriftSehrLeise else Stil.akzent)
    }
}
