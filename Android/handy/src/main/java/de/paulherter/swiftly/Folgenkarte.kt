package de.paulherter.swiftly

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitTouchSlopOrCancellation
import androidx.compose.foundation.gestures.drag
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Staerke
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.bewegungReduziert
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.kern.Kern
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject
import kotlin.math.ceil
import kotlin.math.roundToInt

// **Die naechste Folge als Karte unten rechts** — Variante C (Paul, 26.09.2026). Vorlage
// `Sources/iOS/Folgenkartenansicht.swift` (Handy) und `Sources/tvOS/TVFolgenkarte.swift` (Fernseher), die
// geteilten Teile aus `Sources/Shared/Folgenkartenteile.swift`. Zeiten, Federn, Masse und die Wischregeln
// kommen aus dem Kern (`Folgenkarte` im Paket); wann sie steht, wartet oder zaehlt, sagt `Angebotsebene`.

/** Die naechste Folge, wie die Karte sie zeigt — aus dem Spielplan (`Kern.spielplanantwort`). */
data class Kartenfolge(val id: String, val name: String, val kuerzel: String, val bild: String?)

/**
 * **Die Karte zoomt ins Bild** — beim Start festgehalten (`Kartenwechsel` auf Apple). `beginn` und `bildSeit`
 * in Millisekunden (`SystemClock.elapsedRealtime`), `bildSeit` ab `beginn`.
 */
data class Kartenwechsel(val folge: Kartenfolge, val beginn: Long, val bildSeit: Long? = null, val gescheitert: Boolean = false)

/**
 * Masse und Zeiten aus `Kern.folgenkarte` — Laengen in dp. **Der Fernseher halbiert** (tvOS rechnet in 1920
 * Punkten Breite, Android TV in 960 dp).
 */
data class Kartenmasse(
    val breite: Float, val ecke: Float, val ring: Float, val abstand: Float, val klein: Float, val titel: Float,
    val erscheinenOmega: Double, val erscheinenVerzug: Double, val wegOmega: Double, val zoomOmega: Double,
    val angabenAus: Double, val tausch: Double, val bildBlende: Double, val versatz: Float, val startmass: Float,
    val fokusmass: Float, val klickDruck: Float, val untenAbstand: Float, val fernseher: Boolean,
) {
    /** Kritisch gedaempft aus dem jetzigen Stand: `spring(dampingRatio = 1, stiffness = ω²)` (`Folgenkarte.feder`). */
    fun <T> feder(omega: Double): FiniteAnimationSpec<T> = spring(dampingRatio = 1f, stiffness = (omega * omega).toFloat())

    /** Hoehe der zwei Zeilen unter der Karte samt Abstand (`zeilen` auf Apple). */
    val zeilen: Float get() = if (fernseher) abstand + klein * 1.3f + 3f + titel * 1.25f
                             else abstand + ceil(klein * 1.2f) + 3f + ceil(titel * 1.2f)

    companion object {
        fun lesen(json: String, tv: Boolean): Kartenmasse = JSONObject(json).let { o ->
            val m = if (tv) 0.5f else 1f
            fun l(k: String) = (o.getDouble(k) * m).toFloat()
            Kartenmasse(l("breite"), l("ecke"), l("ring"), l("abstand"), l("klein"), l("titel"),
                o.getDouble("erscheinenOmega"), o.getDouble("erscheinenVerzug"), o.getDouble("wegOmega"), o.getDouble("zoomOmega"),
                o.getDouble("angabenAus"), o.getDouble("tausch"), o.getDouble("bildBlende"), l("versatz"),
                o.getDouble("startmass").toFloat(), o.getDouble("fokusmass").toFloat(), o.getDouble("klickDruck").toFloat(),
                l("untenAbstand"), tv)
        }
    }
}

/**
 * **Die Karte samt Zeilen, Ring, Verlauf und Zoom** — Handy und Fernseher. `karte` ist ihr Rahmen in px,
 * gerechnet aus der Flaeche (`BoxWithConstraints`). Auf dem Fernseher traegt `fokus` die Karte, ein Klick
 * startet; am Telefon startet ein Tipp, das X und ein Wisch sagen ab.
 */
@Composable
fun Folgenkarte(werk: Spielwerk, da: Boolean, karte: (breite: Float, hoehe: Float, dichte: Float) -> Rect,
                fokus: FocusRequester? = null, abbrechen: () -> Unit) {
    val m = werk.kartenmasse
    val wechsel = werk.kartenwechsel
    val folge = wechsel?.folge ?: werk.plan?.naechsteFolge ?: return
    val ruhig = bewegungReduziert()
    val angabenDa = da && wechsel == null
    val lauf = androidx.compose.runtime.rememberCoroutineScope()

    val einblend = remember { Animatable(0f) }
    val zoom = remember { Animatable(0f) }
    val bild = remember { Animatable(1f) }
    var ziehen by remember { mutableStateOf(Offset.Zero) }

    // Herein mit Verzug (nicht beim Zoom), hinaus sofort — Federn aus dem jetzigen Stand.
    LaunchedEffect(da) {
        if (da) {
            if (werk.kartenwechsel == null && !ruhig) delay((m.erscheinenVerzug * 1000).toLong())
            einblend.animateTo(1f, if (ruhig) Bewegung.blendeReduziert() else m.feder(m.erscheinenOmega))
        } else {
            einblend.animateTo(0f, if (ruhig) Bewegung.blendeReduziert() else m.feder(m.wegOmega))
            // Weg ist weg: den Wisch vergessen, wenn die Karte gegangen ist.
            ziehen = Offset.Zero
        }
    }
    // Der Zoom aufs ganze Bild; scheitert der Wechsel, zurueck in die Ecke und hinaus.
    LaunchedEffect(wechsel != null, wechsel?.gescheitert) {
        val w = werk.kartenwechsel ?: return@LaunchedEffect
        if (w.gescheitert) {
            Protokoll.schreib("[Karte] Wechsel gescheitert, zurück")
            zoom.animateTo(0f, if (ruhig) Bewegung.blendeReduziert() else m.feder(m.wegOmega))
            einblend.snapTo(0f); bild.snapTo(1f)
            werk.karteAufraeumen()
        } else {
            ziehen = Offset.Zero
            zoom.animateTo(1f, if (ruhig) Bewegung.blendeReduziert() else m.feder(m.zoomOmega))
        }
    }
    // Das erste Bild der neuen Folge steht: das Vorschaubild blendet aus, fruehestens ab dem Tausch.
    LaunchedEffect(wechsel?.bildSeit) {
        val w = werk.kartenwechsel ?: return@LaunchedEffect
        val bildSeit = w.bildSeit ?: return@LaunchedEffect
        val warten = Kern.folgenkarteBlendeAb(bildSeit / 1000.0) * 1000 - (android.os.SystemClock.elapsedRealtime() - w.beginn)
        if (warten > 0) delay(warten.toLong())
        bild.animateTo(0f, if (ruhig) Bewegung.blendeReduziert() else tween((m.bildBlende * 1000).toInt(), easing = EaseInOut))
        Protokoll.schreib("[Karte] Ende nach ${android.os.SystemClock.elapsedRealtime() - w.beginn} ms")
        // Ohne Bewegung zurueck, wie `withTransaction(still)` auf Apple — sonst blitzte die Karte in der Ecke.
        einblend.snapTo(0f); zoom.snapTo(0f); bild.snapTo(1f)
        werk.karteAufraeumen()
    }

    val angaben by animateFloatAsState(if (angabenDa) 1f else 0f,
        if (ruhig) Bewegung.blendeReduziert() else tween((m.angabenAus * 1000).toInt(), easing = EaseOut), label = "angaben")
    val schleier by animateFloatAsState(if (angabenDa && da) 1f else 0f,
        if (ruhig) Bewegung.blendeReduziert() else tween((m.angabenAus * 1000).toInt(), easing = EaseOut), label = "kartenschleier")
    val fuellung = kartenfuellung(werk, angabenDa)

    /** Das Ende eines Wischs: weit genug oder mit Schwung ist die Karte weg, sonst federt sie zurueck. */
    fun wischEnde(weg: Offset, schwung: Offset, dichte: Float) {
        // Wie weit der Schwung sie truege (`predictedEndTranslation`): ein Viertel der Geschwindigkeit.
        val sx = (weg.x + schwung.x * 0.25f) / dichte
        val sy = (weg.y + schwung.y * 0.25f) / dichte
        if (Kern.folgenkarteWeggewischt((weg.x / dichte).toDouble(), (weg.y / dichte).toDouble(), sx.toDouble(), sy.toDouble())) {
            Protokoll.schreib("[Karte] weggewischt")
            abbrechen()
        } else lauf.launch {
            val start = ziehen
            val zurueck = Animatable(1f)
            zurueck.animateTo(0f, if (ruhig) Bewegung.blendeReduziert() else m.feder(m.wegOmega)) { ziehen = start * value }
        }
    }

    val dichteJetzt = LocalDensity.current.density
    val rahmen = remember { arrayOf(Rect.Zero) }
    BoxWithConstraints(Modifier.fillMaxSize().then(if (fokus == null && angabenDa) Modifier.pointerInput(Unit) {
        // **Wegwischen** nach rechts oder unten — nur an der Karte, und am ruhenden Kasten gemessen, nicht an
        // der Karte, die dem Finger folgt (`Folgenkarte.gezogen/weggewischt`).
        val tempo = VelocityTracker()
        awaitEachGesture {
            val runter = awaitFirstDown(requireUnconsumed = false)
            if (!rahmen[0].contains(runter.position)) return@awaitEachGesture
            var weg = Offset.Zero
            tempo.resetTracking()
            tempo.addPosition(runter.uptimeMillis, runter.position)
            fun setzen() {
                ziehen = Offset((Kern.folgenkarteGezogen((weg.x / density).toDouble()) * density).toFloat(),
                                (Kern.folgenkarteGezogen((weg.y / density).toDouble()) * density).toFloat())
            }
            val start = awaitTouchSlopOrCancellation(runter.id) { c, ueber -> c.consume(); weg += ueber } ?: return@awaitEachGesture
            setzen()
            val fertig = drag(start.id) { c ->
                weg += c.positionChange()
                c.consume()
                tempo.addPosition(c.uptimeMillis, c.position)
                setzen()
            }
            if (fertig) { val v = tempo.calculateVelocity(); wischEnde(weg, Offset(v.x, v.y), dichteJetzt) }
            else ziehen = Offset.Zero
        }
    } else Modifier)) {
        val dichte = LocalDensity.current.density
        val w = constraints.maxWidth.toFloat()
        val h = constraints.maxHeight.toFloat()
        val k = karte(w, h, dichte)
        rahmen[0] = k
        // **Der Verlauf unten rechts** — damit die Schrift auf jedem Abspann lesbar bleibt. Er blendet nur.
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = schleier }.drawBehind {
            withTransform({ scale(size.width, size.height, pivot = Offset.Zero) }) {
                drawRect(Brush.radialGradient(0f to Color.Black.copy(alpha = 0.78f), 0.7f to Color.Transparent,
                    center = Offset(0.88f, 0.92f), radius = 0.75f), size = Size(1f, 1f))
            }
        })

        // **Herein und hinaus bewegt sich nur die Karte** — von rechts, aus 94 % Groesse, mit Deckkraft.
        Box(Modifier.fillMaxSize().graphicsLayer {
            val e = einblend.value
            val z = zoom.value
            alpha = e
            val s = if (z > 0f) 1f else m.startmass + (1f - m.startmass) * e
            scaleX = s; scaleY = s
            transformOrigin = TransformOrigin(k.center.x / w.coerceAtLeast(1f), k.center.y / h.coerceAtLeast(1f))
            val weg = if (ruhig) 0f else (1f - e) * m.versatz * (if (m.fernseher) 2f else 1f) * density
            translationX = weg + (if (z > 0f) 0f else ziehen.x)
            translationY = if (z > 0f) 0f else ziehen.y
        }) {
            val z = zoom.value
            val r = Rect(k.left * (1 - z), k.top * (1 - z), k.right + (w - k.right) * z, k.bottom + (h - k.bottom) * z)
            Kartenbild(werk, folge, m, r, 1f - z, angaben, bild.value, fuellung, wechsel == null && da, fokus)
            val d = LocalDensity.current
            // Zwei Zeilen unter der Karte: „S6 · F11 … in 5 s", darunter der Titel.
            Column(Modifier.offset { IntOffset(k.left.roundToInt(), (k.bottom + m.abstand * density + (1f - angaben) * (if (ruhig) 0f else (if (m.fernseher) 12f else 6f)) * density).roundToInt()) }
                    .width(with(d) { k.width.toDp() }).graphicsLayer { alpha = angaben },
                verticalArrangement = Arrangement.spacedBy(if (m.fernseher) 6.dp else 3.dp)) {
                val klein = TextStyle(fontSize = m.klein.sp, fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum")
                Row(horizontalArrangement = Arrangement.spacedBy(if (m.fernseher) 24.dp else 12.dp)) {
                    Text(folge.kuerzel, style = klein, color = Stil.schriftSehrLeise, maxLines = 1)
                    Spacer(Modifier.weight(1f))
                    Text(uebersetzt("in %lld s", werk.countdownRest), style = klein, color = Stil.schriftSehrLeise, maxLines = 1)
                }
                Text(folge.name, style = TextStyle(fontSize = m.titel.sp, fontWeight = FontWeight.SemiBold), color = Stil.schrift,
                     maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            // **Das runde X an der Kartenecke** (Muster Max): Karte weg, Countdown aus, der Abspann laeuft.
            if (fokus == null) {
                Box(Modifier.offset { IntOffset((k.right - 18.dp.toPx() - 22.dp.toPx()).roundToInt(), (k.top + 18.dp.toPx() - 22.dp.toPx()).roundToInt()) }
                        .size(44.dp).graphicsLayer { alpha = angaben }
                        .then(if (angabenDa) Modifier.clickable(remember { MutableInteractionSource() }, null) {
                            Protokoll.schreib("[Karte] × gedrückt"); abbrechen()
                        }.semantics { contentDescription = uebersetzt("Karte schließen") } else Modifier),
                    contentAlignment = Alignment.Center) {
                    Box(Modifier.size(24.dp).clip(CircleShape).background(Stil.flaeche.copy(alpha = 0.85f)), contentAlignment = Alignment.Center) {
                        Symbol(Zeichen.Kreuz, 11.dp, farbe = Stil.schrift, staerke = Staerke.Halbfett)
                    }
                }
            }
        }
    }
}

/** Die Karte selbst: Vorschaubild auf Schwarz, Ring, Ecke und Schatten schwinden mit dem Zoom (`Kartenform`). */
@Composable
private fun Kartenbild(werk: Spielwerk, folge: Kartenfolge, m: Kartenmasse, r: Rect, rest: Float, angaben: Float,
                       bild: Float, fuellung: Float, bedienbar: Boolean, fokus: FocusRequester?) {
    val d = LocalDensity.current
    val quelle = remember { MutableInteractionSource() }
    val gedrueckt by quelle.collectIsPressedAsState()
    val fokussiert by quelle.collectIsFocusedAsState()
    val ruhig = bewegungReduziert()
    // Fernseher: die Karte mit Fokus hebt sich um 6 %, ein Klick drueckt sie ein — nicht beim Zoom.
    val heben = if (fokus != null && fokussiert && rest >= 1f) m.fokusmass else 1f
    val druck = if (gedrueckt) 1f - m.klickDruck else 1f
    val mass by animateFloatAsState(if (ruhig) 1f else heben * druck,
        if (fokus != null) m.feder(m.erscheinenOmega) else Bewegung.umschalten(), label = "kartenmass")
    val ecke = (m.ecke * rest).dp
    Box(Modifier.offset { IntOffset(r.left.roundToInt(), r.top.roundToInt()) }
            .size(with(d) { r.width.toDp() }, with(d) { r.height.toDp() })
            .graphicsLayer { scaleX = mass; scaleY = mass; alpha = if (fokus == null && gedrueckt) 0.85f else 1f }
            .shadow((17f * rest).dp, RoundedCornerShape(ecke), ambientColor = Color.Black, spotColor = Color.Black.copy(alpha = 0.6f * rest))
            .clip(RoundedCornerShape(ecke)).background(Color.Black)
            .then(if (fokus != null && bedienbar) Modifier.focusRequester(fokus) else Modifier)
            .semantics {
                contentDescription = uebersetzt("Nächste Folge abspielen: %@", folge.kuerzel)
                stateDescription = uebersetzt("Startet in %lld Sekunden", werk.countdownRest)
                if (fokus == null) customActions = listOf(CustomAccessibilityAction(uebersetzt("Karte schließen")) { werk.angebotSchliessen(); true })
            }
            .clickable(quelle, null, enabled = bedienbar) { werk.karteStarten() },
        contentAlignment = Alignment.Center) {
        AsyncImage(model = folge.bild, contentDescription = null, contentScale = ContentScale.Crop,
                   modifier = Modifier.fillMaxSize().graphicsLayer { alpha = bild })
        Countdownring(fuellung, m.ring.dp, Modifier.graphicsLayer { alpha = angaben })
    }
}

/**
 * **Der Countdown-Ring** (`Countdownring`): Scheibe schwarz 50 %, Spur weiss 18 %, der Anteil im Akzent,
 * darin das Spielzeichen. Masse im Verhaeltnis des Entwurfs (56er Raster).
 */
@Composable
fun Countdownring(anteil: Float, durchmesser: Dp, modifier: Modifier = Modifier) {
    Box(modifier.size(durchmesser), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val strich = size.minDimension * 3f / 56f
            val radius = size.minDimension / 2f - strich
            drawCircle(Color.Black.copy(alpha = 0.5f))
            drawCircle(Color.White.copy(alpha = 0.18f), radius = radius, style = Stroke(strich))
            drawArc(Stil.akzent, -90f, 360f * anteil.coerceIn(0f, 1f), useCenter = false,
                    topLeft = Offset(center.x - radius, center.y - radius), size = Size(radius * 2, radius * 2),
                    style = Stroke(strich, cap = StrokeCap.Round))
        }
        Symbol(Zeichen.Abspielen, durchmesser * 0.3f, Modifier.offset(x = durchmesser * 0.03f), farbe = Stil.schrift)
    }
}

/**
 * Die Fuellung der Karte als durchgehende Bewegung (`Fuellungsuhr`), und **nach einem Sprung von vorn**
 * (`fuellungNeu`). Beim Zoom bleibt sie stehen, wo sie war.
 */
@Composable
fun kartenfuellung(werk: Spielwerk, zaehlt: Boolean): Float {
    val anteil = werk.countdown.takeIf { werk.einblendung == "karte" }
    val wert = remember { Animatable(0f) }
    LaunchedEffect(anteil != null, werk.laeuft, werk.amDateiende, zaehlt, werk.fuellungNeu) {
        if (!zaehlt) { wert.stop(); return@LaunchedEffect }
        if (anteil == null) { wert.snapTo(0f); return@LaunchedEffect }
        val ab = if (werk.fuellungNeu > 0 && anteil < wert.value) anteil.toFloat() else maxOf(wert.value, anteil.toFloat())
        wert.snapTo(ab)
        if (!werk.laeuft && !werk.amDateiende) return@LaunchedEffect
        val rest = ((1f - ab) * werk.countdownLaenge * 1000).toInt().coerceAtLeast(1)
        wert.animateTo(1f, tween(rest, easing = androidx.compose.animation.core.LinearEasing))
    }
    return wert.value
}
