package de.paulherter.swiftly.tv

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.ui.layout.positionInParent
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import kotlinx.coroutines.CoroutineScope
import kotlin.math.roundToInt
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import coil3.compose.AsyncImage
import de.paulherter.swiftly.*
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.kern.Kern
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Vorlage: `Kulisse` und `Kulissenblende` — das Querbild rechts oben, zum Text hin und nach unten
 * in den Grund auslaufend. Startseite, Titel, Serie und Person teilen sich dieselbe.
 *
 * **Eine Alpha-Maske, kein Anstrich in `Stil.grund`.** So stand es hier vorher: zwei Verlaeufe von
 * `Stil.grund` nach durchsichtig, **ueber** das Bild gemalt. Das setzt einen einfarbigen Seitengrund
 * voraus — seit `TvBildgrund` den Grund nach der Kulisse toent, endete das Bild links und unten mit
 * einer harten Kante, wo der Anstrich in der falschen Farbe auf den getoenten Grund traf.
 *
 * tvOS loest das mit `Kulissenblende` (`Sources/tvOS/TVBausteine.swift`) als Maske: **das Bild selbst
 * wird links und unten durchsichtig**, und was dahinter liegt, kommt durch, welche Farbe es auch hat.
 * Nachgebaut mit `graphicsLayer(compositingStrategy = Offscreen)` — `BlendMode.DstIn` braucht eine
 * eigene Ebene, sonst wirkt es auf alles darunter statt nur auf dieses Bild — und zwei `drawRect`-
 * Aufrufen mit `DstIn` statt SwiftUIs zwei `.mask`-Aufrufen. Dieselben Anker wie in der Vorlage.
 */
@Composable
fun Kulisse(bild: String?, modifier: Modifier = Modifier, dauer: Int = 300) {
    Crossfade(bild, animationSpec = tween(dauer), label = "kulisse", modifier = modifier.size(590.dp, 350.dp)) { url ->
        Box(Modifier.fillMaxSize()
                .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
                .drawWithContent {
                    drawContent()
                    // Waagerecht: links durchsichtig, rechts voll da — dieselben Anker wie
                    // `Kulissenblende`s erste Maske (`.leading` → `.trailing`).
                    drawRect(Brush.horizontalGradient(
                        0.00f to Color.White.copy(alpha = 0.00f),
                        0.15f to Color.White.copy(alpha = 0.05f),
                        0.29f to Color.White.copy(alpha = 0.22f),
                        0.45f to Color.White.copy(alpha = 0.50f),
                        0.57f to Color.White.copy(alpha = 0.75f),
                        0.70f to Color.White.copy(alpha = 0.90f),
                        0.85f to Color.White.copy(alpha = 0.98f),
                        1.00f to Color.White.copy(alpha = 1.00f),
                    ), blendMode = BlendMode.DstIn)
                    // Senkrecht: oben voll da, unten durchsichtig — dieselben Anker wie
                    // `Kulissenblende`s zweite Maske (`.top` → `.bottom`).
                    drawRect(Brush.verticalGradient(
                        0.00f to Color.White.copy(alpha = 1.00f),
                        0.50f to Color.White.copy(alpha = 1.00f),
                        0.60f to Color.White.copy(alpha = 0.88f),
                        0.70f to Color.White.copy(alpha = 0.62f),
                        0.80f to Color.White.copy(alpha = 0.34f),
                        0.89f to Color.White.copy(alpha = 0.14f),
                        0.95f to Color.White.copy(alpha = 0.04f),
                        1.00f to Color.White.copy(alpha = 0.00f),
                    ), blendMode = BlendMode.DstIn)
                }) {
            AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
    }
}

/**
 * Vorlage: kein Gegenstueck auf tvOS — SwiftUI kennt kein eingebautes „Bring the focused view into
 * view" fuer eigene Listen. Compose dagegen meldet bei jedem Fokuswechsel eine Anfrage an **jeden**
 * umschliessenden Scroll-Container, senkrecht wie waagerecht; auf einem Fernseher (`leanback`-Merkmal)
 * ist die Systemvorgabe intern ein Pivot-Verhalten, das das fokussierte Element auf 30 % Hoehe haelt,
 * auch wenn es schon vollstaendig sichtbar ist — `PivotBringIntoViewSpec` selbst ist seit Foundation
 * 1.7 `internal` und von hier aus nicht erreichbar, deshalb unten `TvReihenBringIntoView` als eigener,
 * schlanker Nachbau derselben Rechnung.
 *
 * Wandert der Fokus **waagerecht** innerhalb einer `LazyRow` (die Fokuslupe laesst die Kachel dabei
 * waechst), meldet sich die wachsende Kachel bei jedem Zwischenschritt erneut beim **senkrechten**
 * Vorfahren — der `LazyColumn` der Startseite —, und die rueckt sie artig auf ihre 30 % zurecht.
 * Genau das Zucken nach oben und unten bei jedem Links/Rechts innerhalb einer Reihe.
 *
 * Der senkrechte Reihenwechsel hat mit `listenzustand.animateScrollToItem(...)` schon eine eigene,
 * bewusste Bewegung — das eingebaute Bring-into-View braucht es dafuer nicht. Deshalb hier ganz
 * abgeschaltet (immer 0), um die `LazyColumn` gelegt; innerhalb jeder `LazyRow` steht wieder
 * `TvReihenBringIntoView`, damit die naechste Kachel beim Weiterwandern waagerecht mitgescrollt wird.
 */
@OptIn(ExperimentalFoundationApi::class)
object TvKeinSenkrechtesBringIntoView : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float) = 0f
}

/**
 * Eigener Nachbau des Pivot-Verhaltens, mit dem jede `LazyRow` von sich aus schon bedient war, bevor
 * `LocalBringIntoViewSpec` hier ueberschrieben wurde: die fokussierte Kachel wandert auf 30 % der
 * Streifenbreite, nicht ganz an den Rand, damit rechts noch die naechste zu sehen ist. Passt die
 * Kachel dort nicht mehr hinein (sie ist breiter als der Streifen), richtet sich ihr Ende an der
 * Streifenkante aus statt am Pivot-Punkt — dieselbe Randbehandlung wie im Systemverhalten.
 */
@OptIn(ExperimentalFoundationApi::class)
object TvReihenBringIntoView : BringIntoViewSpec {
    private const val pivot = 0.3f
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
        if (containerSize <= 0f) return 0f
        val idealeVorderkante = pivot * containerSize
        val platzDanach = containerSize - idealeVorderkante
        val zielVorderkante = if (size <= containerSize && platzDanach < size) containerSize - size else idealeVorderkante
        return offset - zielVorderkante
    }
}

/** Wie ein Abschnitt beim Fokuseintritt ins Bild kommt — siehe `TvAbschnitte.betreten`. */
enum class TvAbschnittsart {
    /** Kopf mit Knopfreihe: Seite ganz nach oben, voller Kopf sichtbar. */
    Kopf,
    /** Abschnitt oben buendig (mit `TvAbschnitte.rand`), am Seitenende nicht ueber `maxValue` hinaus. */
    Buendig,
    /** Erster Abschnitt einer Seite ohne fokussierbaren Kopf (Person, Seerr ohne Anfrageknopf):
     *  so wenig wie moeglich scrollen, dass seine Unterkante im Bild steht — der Kopf bleibt sichtbar. */
    Kopfnah,
}

/**
 * Vorlage: tvOS-Fokusmotor mit `focusSection` auf `DetailView`/`SerienView`/`PersonView`/
 * `SeerrDetailView` — wechselt der Fokus in einen Abschnitt, steht **der ganze Abschnitt** frei
 * (Reihentitel, Kacheln, Beschriftung samt Lupen-Luft); zurueck in die Knopfreihe steht die Seite
 * wieder ganz oben.
 *
 * Vorher lag hier `TvAbschnittsweisesBringIntoView` (Compose-Standardrechnung „nur so weit wie
 * noetig"). Die rechnet aber mit dem **fokussierten Element**, nicht mit dem Abschnitt: nach unten
 * blieben die Namen unter den Besetzungsbildern abgeschnitten, nach oben kam nur der Play-Knopf ins
 * Bild und Titel/Beschreibung darueber nie wieder. Jetzt ist das senkrechte Bring-into-View auf
 * diesen Seiten ganz aus (`TvKeinSenkrechtesBringIntoView`), jeder Abschnitt meldet seine Lage und
 * scrollt beim **Eintritt** (`hasFocus` wechselt) selbst — Links/Rechts innerhalb bewegt nichts.
 */
class TvAbschnitte internal constructor(val scroll: ScrollState, private val lauf: CoroutineScope, private val randPx: Float) {
    internal var inhalt: LayoutCoordinates? = null
    internal var fenster = 0
    private val lagen = HashMap<String, LayoutCoordinates>()
    private var aktiv: String? = null

    internal fun lage(schluessel: String, c: LayoutCoordinates) { lagen[schluessel] = c }
    internal fun verlassen(schluessel: String) { if (aktiv == schluessel) aktiv = null }

    internal fun betreten(schluessel: String, art: TvAbschnittsart) {
        if (aktiv == schluessel) return
        aktiv = schluessel
        val ziel = if (art == TvAbschnittsart.Kopf) 0f else {
            val c = lagen[schluessel] ?: return
            val i = inhalt ?: return
            if (!c.isAttached || !i.isAttached || fenster <= 0) return
            // Beide Koordinaten liegen im gescrollten Inhalt — der Abstand ist vom Scrollstand frei.
            val oben = i.localPositionOf(c, Offset.Zero).y
            val unten = oben + c.size.height
            if (art == TvAbschnittsart.Buendig) oben - randPx else unten - fenster
        }
        val soll = ziel.roundToInt().coerceIn(0, scroll.maxValue)
        if (soll != scroll.value) lauf.launch { scroll.animateScrollTo(soll, tween(TvStil.abschnittDauer, easing = TvStil.fokusKurve)) }
    }
}

/**
 * Die scrollende Spalte fuer `TvDetail`, `TvSerie`, `TvPerson`, `TvSeerrDetailSeite`. Senkrechtes
 * Bring-into-View aus; `TvStreifen` und der Folgenstreifen setzen innen wieder `TvReihenBringIntoView`.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TvAbschnittsseite(inhalt: @Composable ColumnScope.(TvAbschnitte) -> Unit) {
    val scroll = rememberScrollState()
    val lauf = rememberCoroutineScope()
    val rand = with(LocalDensity.current) { 12.dp.toPx() }
    val abschnitte = remember(scroll) { TvAbschnitte(scroll, lauf, rand) }
    CompositionLocalProvider(LocalBringIntoViewSpec provides TvKeinSenkrechtesBringIntoView) {
        Column(Modifier.fillMaxSize().onSizeChanged { abschnitte.fenster = it.height }
                   .verticalScroll(scroll).onGloballyPositioned { abschnitte.inhalt = it }) {
            inhalt(abschnitte)
        }
    }
}

/** Meldet Lage und Fokuseintritt eines Abschnitts an `TvAbschnitte`. */
fun Modifier.tvAbschnitt(abschnitte: TvAbschnitte, schluessel: String, art: TvAbschnittsart = TvAbschnittsart.Buendig): Modifier =
    this.onGloballyPositioned { abschnitte.lage(schluessel, it) }
        .onFocusChanged { if (it.hasFocus) abschnitte.betreten(schluessel, art) else abschnitte.verlassen(schluessel) }

/**
 * Vorlage: `Kopfauskunft` in `Sources/tvOS/TVBausteine.swift` — **eine Quelle** fuer Startseite,
 * Filmseite und Serienseite, sonst laufen sie auseinander (`nachladen()`, `Titelangaben` sind auf
 * genau diese Art schon einmal auseinandergelaufen). Titel, optionale Zweitzeile (Folgentitel),
 * dann eine Zeile „Kuerzel · Jahr · Laufzeit" mit Bewertung und Freigabe, dann die Beschreibung —
 * **immer drei Zeilen, zwei mit Zweitzeile**, damit die Knopfreihe (Detail) bzw. die Reihen
 * (Start) auf jeder Seite an derselben Stelle stehen.
 *
 * `schluss` ist das Gegenstueck zu tvOS' `@ViewBuilder var schluss`: `TvRestzeitmarke` auf der
 * Startseite, ein Direct-Play-`TvBelegzeile` auf Film- und Serienseite — dieselbe Funktion, kein
 * zweiter Aufbau. `TvDetailkopf` (`TvTitel.kt`) ruft dieselbe Funktion auf.
 */
@Composable
fun Kopfauskunft(titel: String, zweitzeile: String?, angabenzeile: String?, bewertung: Double?,
                 freigabe: String?, beschreibung: String?, modifier: Modifier = Modifier,
                 schluss: @Composable () -> Unit = {}) {
    Column(modifier.width(500.dp)) {
        Text(titel, style = TvStil.auskunftTitel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.height(34.dp))
        zweitzeile?.let {
            Text(it, style = TvStil.auskunftZweitzeile, color = Stil.schrift.copy(alpha = 0.78f), maxLines = 1,
                 overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 5.dp).height(22.dp))
        }
        // **Feste 17 dp, Inhalt darf hinausragen** — tvOS: `.frame(height: 34)`, die Direct-Play-Marke
        // steht mittig und ragt ueber die Zeile, ohne etwas zu verschieben. Vorher `heightIn(min = 17)`:
        // mit Marke (~26 dp) oder Freigabe-Plakette wuchs die Zeile auf der Detailseite, und Beschreibung
        // und Knopfreihe standen tiefer als auf der Startseite. `wrapContentHeight(unbounded = true)`
        // misst die Reihe ohne Hoehengrenze, meldet aber nur 17 dp und zentriert sie darin; Box und
        // Row clippen nicht, also wird nichts abgeschnitten.
        Box(Modifier.padding(top = 7.dp).height(17.dp)) {
        Row(Modifier.wrapContentHeight(Alignment.CenterVertically, unbounded = true), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            angabenzeile?.takeIf { it.isNotEmpty() }?.let {
                Text(it, style = TvStil.koerper, color = Stil.schrift.copy(alpha = 0.62f), maxLines = 1)
            }
            // Bewertung und Freigabe stehen auf **jeder** Seite, Start wie Detail — nur der
            // Direct-Play-Beleg ist Detail vorbehalten und kommt ueber `schluss`.
            TvBelegzeile(direktplay = false, hinweis = null, bewertung = bewertung, freigabe = freigabe)
            schluss()
        }
        }
        Text(beschreibung.orEmpty(), style = TvStil.koerper, color = Stil.schrift.copy(alpha = 0.62f),
             maxLines = if (zweitzeile != null) 2 else 3, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.padding(top = 11.dp).height(TvStil.beschreibungHoehe(if (zweitzeile != null) 2 else 3)))
    }
}

/** Vorlage: `Restzeitmarke` in `Sources/tvOS/TVBausteine.swift` — „Noch 12 Minuten" mit Uhr,
 *  „Gesehen" mit Haken, sonst nichts. */
@Composable
fun TvRestzeitmarke(restzeit: String?, gesehen: Boolean) {
    val (symbol, text) = when {
        restzeit != null -> Icons.Filled.Schedule to restzeit
        gesehen -> Icons.Filled.Check to uebersetzt("Gesehen")
        else -> return
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(symbol, contentDescription = null, tint = Stil.akzent, modifier = Modifier.size(18.dp))
        Text(text, style = TvStil.koerper, color = Stil.akzent, maxLines = 1)
    }
}

/**
 * Liest, ob kein einziger Abruf durchkam — `Startseitenantwort.gestoert` aus `Kern.startseite`.
 * Eigens hier und nicht in `reihenLesen` (`StartSeite.kt`, Handy-Datei): die Startseite auf dem
 * Telefon zeigt einen schlichten Fehlertext inline, der Fernseher dagegen einen ganzen
 * Leerzustand wie tvOS — das ist ein Unterschied in der Anzeige, keiner in der Fassade, also reicht
 * ein zweiter, kleiner Lesevorgang statt eine Aenderung an einer fremden Datei.
 */
private fun gestoertLesen(json: String): Boolean = JSONObject(json).optBoolean("gestoert", false)

/**
 * Vorlage: `HomeView` auf tvOS — **eine feste Kopfzone, darunter die Reihen.** Die Kopfzone zeigt,
 * was gerade den Fokus hat; das Bild wechselt erst nach 250 ms und blendet 300 ms, der Text sofort.
 * Die Reihen und ihre Reihenfolge kommen aus dem Paket wie auf dem Telefon.
 *
 * **Vier Zustaende, wie auf tvOS:** laedt (zwei Platzhalterreihen, eine quer), gestoert (der Server
 * antwortet nicht, mit „Nochmal versuchen"), leer (gar kein Inhalt) und die Reihen selbst.
 */
@OptIn(ExperimentalComposeUiApi::class, ExperimentalFoundationApi::class)
@Composable
fun TvStartSeite(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit) {
    val e = app.einstellungen
    var reihen by remember { mutableStateOf(app.startReihen) }
    var gestoert by remember { mutableStateOf(false) }
    val lauf = rememberCoroutineScope()

    suspend fun laden() {
        runCatching {
            withContext(Dispatchers.IO) {
                app.kern.startseite(e.neuzugangGetrennt, e.startReihen.toTypedArray(), e.startAus.toTypedArray(),
                                    app.ablage.merkwert("bibliothek-movies").orEmpty(), app.ablage.merkwert("bibliothek-tvshows").orEmpty(),
                                    e.startGenres.toTypedArray(), e.genreChips).await()
            }
        }.onSuccess { json ->
            val liste = reihenLesen(json).also { app.startReihen = it }
            reihen = liste
            gestoert = gestoertLesen(json)
            if (!gestoert) app.startGeladenUm = System.currentTimeMillis()
            // Vorlage: `regalSchreiben()` in `HomeView.swift` — bei jedem Laden der Startseite
            // dieselben Rubriken fuers Watch-Next-Regal ablegen. Abseits des Hauptthreads: der
            // Systemanbieter braucht mehrere Zugriffe (lesen, schreiben, ggf. loeschen).
            if (!gestoert) withContext(Dispatchers.IO) {
                runCatching { TvWeiterschauenRegal.aktualisieren(app, liste) }
            }
        }.onFailure { gestoert = true }
    }
    LaunchedEffect(e.neuzugangGetrennt, e.startReihen, e.startAus, e.startGenres, e.genreChips) { laden() }
    // **D8: der Player macht neu, ohne Frist; der Vordergrund macht neu, mit 30 s Frist.**
    // Derselbe Auslauf wie `StartSeite.kt` auf dem Telefon — der Player liegt auch auf dem
    // Fernseher in einer eigenen Aktivitaet (Bild-im-Bild, Vordergrunddienst), nicht in einer
    // Ueberlagerung wie auf tvOS; „kommt zurueck" ist hier deshalb `Lifecycle.State.STARTED`.
    val spielt = app.spiel.value != null
    var hatGespielt by remember { mutableStateOf(false) }
    LaunchedEffect(spielt) { if (spielt) hatGespielt = true else if (hatGespielt) { hatGespielt = false; laden() } }
    val lebenszyklus = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lebenszyklus) {
        lebenszyklus.repeatOnLifecycle(Lifecycle.State.STARTED) {
            if (Kern.auffrischungFaellig(app.startGeladenUm)) laden()
        }
    }

    // Vorlage: `zuletztAmTitel` in `HomeView.swift` — wo der Fokus wirklich stand, als "reihe|id".
    // **`rememberSaveable`, nicht `remember`:** `TvHaupt` wirft die Startseite beim Oeffnen einer
    // Unterseite und beim Bereichswechsel aus der Komposition und stellt sie ueber den
    // `SaveableStateHolder` wieder her. Mit `remember` begann sie danach bei null — Fokus auf der
    // ersten Kachel, `fokusReihe` 0 und damit `animateScrollToItem(0)`: die Seite fuhr nach oben.
    var zuletztAmTitel by rememberSaveable { mutableStateOf<String?>(null) }
    fun kachelZu(marke: String?, l: List<Reihe>?): Kachel? {
        val teile = marke?.split('|', limit = 2) ?: return null
        return l?.getOrNull(teile[0].toIntOrNull() ?: -1)?.kacheln?.firstOrNull { it.id == teile.getOrNull(1) }
    }
    var aktuell by remember { mutableStateOf(kachelZu(zuletztAmTitel, reihen)) }
    val liste = reihen
    LaunchedEffect(liste) { if (aktuell == null) aktuell = liste?.firstOrNull()?.kacheln?.firstOrNull() }
    // Mit dem wiederhergestellten Titel sofort das passende Bild — sonst blendete die Kulisse nach
    // dem Zurueckkommen erst von leer herein.
    //
    // **`kulisse`, nicht `quer`.** `quer` ist das Kachelbild (600 breit) — die Detailseite zeigte
    // eine andere Adresse, also ein anderes Bild im Speicher, einen eigenen Ton und auf Start eine
    // pixelige Kulisse. `kulisse` ist dieselbe Adresse wie `Titel.kulisse`/`Serie.kulisse`
    // (`Kern.kulisse`, tvOS `kulissenURL`). Die Rueckfaelle gelten nur fuer einen alten Kern.
    fun kulisseVon(k: Kachel?) = k?.let { it.kulisse ?: it.quer ?: it.plakat }
    var bild by remember { mutableStateOf(kulisseVon(aktuell)) }
    LaunchedEffect(aktuell) { delay(250); bild = kulisseVon(aktuell) }

    // Beim Oeffnen mitgeben, was schon bekannt ist — siehe `TvVorab`. Eine Folge fuehrt auf die
    // Serienseite, deren Angaben, Bewertung und Beschreibung die der Serie sind, nicht die der
    // Folge: dort nur Name und Kulisse. Bei einer Serie zeigt die Zielseite nur das Jahr.
    fun oeffnenMitVorab(k: Kachel) {
        val folge = k.typ == "Episode"
        val angaben = when (k.typ) {
            "Episode" -> null
            "Series" -> k.angabenzeile?.substringBefore(" · ")?.takeIf { it.length == 4 && it.all(Char::isDigit) }
            else -> k.angabenzeile
        }
        TvUebergabe.merken(k.id, TvVorab(k.name, angaben, k.bewertung.takeUnless { folge }, k.freigabe.takeUnless { folge },
                                         k.beschreibung.takeUnless { folge }, kulisseVon(k)))
        oeffnen(Ziel(k.id, k.name, k.typ))
    }

    // **Ein Abschnitt passt ins Fenster** — wandert der Fokus in eine andere Reihe, stellt der
    // Fokusmotor auf tvOS Reihentitel und Kacheln gemeinsam frei, statt die vorherige Reihe
    // halb abgeschnitten stehen zu lassen. `listenzustand` ist das Kotlin-Gegenstueck: die
    // Zeile der fokussierten Reihe wandert an den oberen Rand des Fensters.
    //
    // **`Column` + `verticalScroll`, keine `LazyColumn`.** Mit der Lazy-Liste war Hochscrollen
    // manchmal sofort statt weich: stand die Reihe darueber nicht mehr in der Komposition, holte die
    // Fokussuche sie ueber das Beyond-Bounds-Layout selbst herein, und unser Reihenwechsel fand sie
    // nicht in `visibleItemsInfo` — der Rueckfall `animateScrollToItem` sprang dann mit eigener,
    // kurzer Bewegung. Runter traf das nie, weil die naechste Reihe unten schon angeschnitten im
    // Layout stand. Die Startseite hat wenige Reihen (feste plus Genres), also sind jetzt alle
    // komponiert; die waagerechten `LazyRow`s bleiben lazy. `rememberScrollState` ist saveable,
    // die Rueckkehr von einer Unterseite steht damit an derselben Stelle.
    val listenzustand = rememberScrollState()
    var fokusReihe by rememberSaveable { mutableStateOf(0) }
    // Lage jeder Reihe im Inhalt (oben, Hoehe; px) — vom Scrollstand unabhaengig, `positionInParent`.
    val reihenlagen = remember { mutableStateMapOf<Int, Pair<Int, Int>>() }
    var fenster by remember { mutableIntStateOf(0) }

    // **Eintritt in die Reihen — nur auf eine Kachel, die gerade im Bild steht.**
    //
    // Vorher `focusRestorer`: der stellt die zuletzt fokussierte Kachel wieder her, egal wo sie
    // steht. Lag sie ueber dem Fenster (Lazy-Listen halten die fokussierte Kachel als „gepinnt"
    // weiter komponiert, nur ausserhalb des Ausschnitts), stand der Fokus unsichtbar unter der
    // Heldenzone — Rechts fuehrte von dort zum Profilbild, Unten eine Reihe zu tief. Und seit das
    // senkrechte Bring-into-View aus ist, scrollte auch nichts hinterher.
    //
    // Jetzt entscheidet `eintrittsziel` anhand des Layouts: die gemerkte Kachel, wenn sie ganz im
    // Bild steht (tvOS: `defaultFocus(zuletztAmTitel)`), sonst die vorderste sichtbare Kachel der
    // obersten sichtbaren Reihe (tvOS: `vordersteMarke`). Genre-Chips zaehlen nicht — tvOS' Vorwahl
    // zeigt immer auf eine Kachel. Fuer jede Kachel ein eigener `FocusRequester`, damit `enter`
    // genau dorthin umlenken kann; nur Kacheln, die im Layout stehen, sind sicher angebunden.
    val anfragen = remember { HashMap<String, FocusRequester>() }
    val reihenstaende = remember { HashMap<Int, LazyListState>() }
    fun anfrage(marke: String) = anfragen.getOrPut(marke) { FocusRequester() }
    fun eintrittsziel(): FocusRequester? {
        val l = liste ?: return null
        val oben = listenzustand.value
        if (fenster <= 0) return null
        val sichtbareReihen = l.indices.filter { i ->
            val (y, h) = reihenlagen[i] ?: return@filter false
            // Mindestens die untere Haelfte im Bild — waehrend des Reihenwechsels steht die
            // obere Reihe ein paar Pixel ueber der Kante und soll trotzdem zaehlen.
            y - oben + h / 2 >= 0 && y - oben < fenster
        }
        fun ganzSichtbar(i: Int): List<String> {
            val zeile = reihenstaende[i]?.layoutInfo ?: return emptyList()
            return zeile.visibleItemsInfo
                .filter { it.offset >= zeile.viewportStartOffset && it.offset + it.size <= zeile.viewportEndOffset }
                .mapNotNull { it.key as? String }
        }
        zuletztAmTitel?.let { m ->
            val i = m.substringBefore('|').toIntOrNull() ?: -1
            if (i in sichtbareReihen && m.substringAfter('|') in ganzSichtbar(i)) return anfrage(m)
        }
        val oberste = sichtbareReihen.minOrNull() ?: return null
        val id = ganzSichtbar(oberste).firstOrNull() ?: return null
        return anfrage("$oberste|$id")
    }
    // Beim Erscheinen — erster Aufbau, Zurueck von einer Unterseite, Bereichswechsel auf „Start" —
    // derselbe Weg: warten, bis das Layout steht (Listen- und Reihenstand sind dann schon
    // wiederhergestellt), dann direkt auf das Eintrittsziel. Kein fester Zeitverzug, kein Umweg
    // ueber die erste Kachel.
    LaunchedEffect(liste != null) {
        if (liste == null) return@LaunchedEffect
        val ziel = snapshotFlow { eintrittsziel() }.first { it != null }
        runCatching { ziel?.requestFocus() }
    }
    val chipVersatz = if (e.genreChips && e.startGenres.isNotEmpty()) 1 else 0
    // Begruendung beider Werte am Reihenwechsel direkt darunter.
    val reihenwechselDauer = 500
    val reihenwechselKurve = remember { CubicBezierEasing(0.25f, 0.1f, 0.25f, 1f) }
    // Vorlage: wie `eingeblendet` auf den Detailseiten — kommt die Startseite zurueck (Zurueck von
    // einer Unterseite), blenden die Reihen wieder ein, waehrend Kulisse und Kopfauskunft stehen
    // bleiben. Gegenstueck zum Ausblenden der Kopfleiste in `TvHaupt`.
    val reiheneinblendung = rememberTvEinblendung(Unit)
    // **Reihenwechsel: jedes Mal dieselbe Bewegung — feste Dauer, feste Kurve.**
    //
    // Vorher lief hier eine Feder (Daempfung 1, Steifigkeit 260), die beim Unterbrechen die
    // Geschwindigkeit der alten Bewegung uebernahm. Am Emulator wirkte das je nach Tempo anders: wer
    // schneller drueckte, bekam schnellere, kuerzere Bewegungen, weil jede neue mit dem Schwung der
    // vorigen losging. Paul will **immer dieselbe Weichheit**, egal wie schnell gedrueckt wird.
    //
    // Deshalb jetzt pro Reihenwechsel eine Zeitkurve, die bei neuem Ziel **von der aktuellen
    // Position aus** neu startet — mit derselben Dauer, ohne Geschwindigkeitsuebernahme und ohne
    // Sprung. Der neue `LaunchedEffect` bricht den alten ab (`scroll {}` ist ein Mutex, die laufende
    // Bewegung endet dort, wo sie gerade steht), und `weg` wird aus dem Layout dieses Moments
    // gerechnet, also vom tatsaechlichen Stand aus.
    //
    // **500 ms:** eine Reihe ist gut eine Kachelhoehe Weg (~200 dp) — kuerzer wirkt auf drei Metern
    // Abstand hektisch, laenger laesst die Liste dem Fokus sichtbar hinterherhaengen. **Kurve
    // `CubicBezier(0.25, 0.1, 0.25, 1)`** (CSS „ease"): zieht schnell an, damit die Liste dem Druck
    // sofort folgt, und laeuft lang und sanft aus — das weiche Ankommen ist, was „weich" ausmacht.
    // Anders als `easeInOut` beginnt sie nicht zaeh, darum wirkt auch ein Neustart mitten in der
    // Bewegung nicht wie ein Stocken.
    //
    // Links/Rechts in einer Reihe aendert `fokusReihe` nicht, dieser Effekt laeuft dann gar nicht —
    // das senkrechte Zucken bleibt weg (siehe `TvKeinSenkrechtesBringIntoView` unten).
    LaunchedEffect(fokusReihe, liste) {
        if (liste == null) return@LaunchedEffect
        // Auf der ersten Reihe ganz nach oben, damit die Genre-Chips wieder mit ins Bild kommen —
        // nicht nur bis zum Reihentitel, der Chip-Zeile knapp darueber liegen liesse.
        // Die Zeile oben buendig; alle Reihen sind komponiert, ihre Lage steht nach dem ersten Layout
        // fest — kein Rueckfall mit eigener Bewegung mehr (siehe `listenzustand`).
        val ziel = if (fokusReihe == 0) 0 else snapshotFlow { reihenlagen[fokusReihe]?.first }.first { it != null } ?: 0
        val soll = ziel.coerceIn(0, listenzustand.maxValue)
        if (soll == listenzustand.value) return@LaunchedEffect
        // `animateScrollTo` startet vom aktuellen Stand; der neue Effekt bricht den alten ab.
        listenzustand.animateScrollTo(soll, tween(reihenwechselDauer, easing = reihenwechselKurve))
    }

    // Wie auf Apple: „gar nichts geladen" ist etwas anderes als „nichts vorhanden" —
    // Genre-Chips sind ein Einstieg, kein Inhalt, und zaehlen deshalb nicht mit.
    val alleLeer = liste != null && liste.isEmpty() && !gestoert

    // Vorlage: `HomeView` `.bildgrund(url: kulissenURL)` und `querbild` — gezeichnet in `TvHaupt`
    // (`TvKulissenebene`), damit sie beim Oeffnen einer Seite einfach stehen bleiben. Kopfschatten
    // dort ebenso. Fehler- und Leerzustand ohne Kulisse, wie bisher.
    TvKulisseMelden(if (gestoert || alleLeer) null else bild)
    Box(Modifier.fillMaxSize()) {
        when {
            gestoert -> TvStartFehler { lauf.launch { laden() } }
            alleLeer -> TvLeer(uebersetzt("Hier ist noch nichts"), uebersetzt("Sobald auf dem Server etwas liegt, taucht es hier auf."))
            else -> {
                Column(Modifier.fillMaxSize()) {
                    Box(Modifier.fillMaxWidth().height(TvStil.heldenHoehe)) {
                        // Vorlage: `auskunft` in `HomeView.swift` — derselbe Baustein wie die
                        // Detailseite (`Kopfauskunft`), mit dem Folgennamen als Zweitzeile und der
                        // Restzeitmarke hinten dran, statt eines eigenen zweiten Aufbaus.
                        //
                        // **98 dp, nicht `kopfUnten + 34.dp`.** 196 pt aus der Tafel, halbiert —
                        // dieselbe Zahl, mit der `TvDetailkopf` (`TvTitel.kt`) seine Spalte
                        // einrueckt. Die Kopfleiste liegt als eigene Ebene *ueber* dieser Zone
                        // (siehe `TvHaupt.kt`), sie verschiebt den Inhalt nicht — `kopfUnten` war
                        // hier ein Rest aus einer Fassung, die das noch tat, und liess den
                        // Startseiten-Titel 12 dp tiefer stehen als den der Detailseite.
                        //
                        // **Kurz ueberblendet (200 ms), nicht hart umgesprungen** — der Text wechselt
                        // weiter sofort mit dem Fokus (keine Entprellung wie beim Bild), nur weich.
                        Crossfade(aktuell, animationSpec = tween(200), label = "kopfauskunft") { k ->
                            if (k != null) {
                                Kopfauskunft(k.name, k.folgenname, k.angabenzeile, k.bewertung, k.freigabe, k.beschreibung,
                                             Modifier.padding(start = TvStil.randSeite, top = 98.dp)) {
                                    TvRestzeitmarke(k.restzeit, k.gesehen)
                                }
                            }
                        }
                    }
                    // `enter`: jeder Eintritt von aussen (Unten aus der Kopfleiste, programmatisch)
                    // landet auf `eintrittsziel` — siehe dort. Kein Ziel im Layout: Compose sucht
                    // selbst (`Default`).
                    // Senkrecht abgeschaltet, siehe `TvKeinSenkrechtesBringIntoView` — der
                    // Reihenwechsel oben (`animateScrollToItem`) bewegt die Liste schon bewusst, ein
                    // zusaetzliches Bring-into-View liess beim waagerechten Wandern in einer Reihe
                    // alles kurz hoch- und runterzucken. In jeder `LazyRow` unten steht die
                    // Systemvorgabe (`TvReihenBringIntoView`, der Nachbau davon) wieder bereit, damit
                    // die naechste Kachel dort weiter mitgescrollt wird.
                    CompositionLocalProvider(LocalBringIntoViewSpec provides TvKeinSenkrechtesBringIntoView) {
                        Column(Modifier.weight(1f).onSizeChanged { fenster = it.height }
                                   .tvEingeblendet { reiheneinblendung.value }
                                   .focusProperties { enter = { eintrittsziel() ?: FocusRequester.Default } }
                                   .focusGroup().verticalScroll(listenzustand).padding(bottom = 40.dp),
                               verticalArrangement = Arrangement.spacedBy(TvStil.reihenAbstand - TvStil.reihenLuft * 2)) {
                            if (e.genreChips && e.startGenres.isNotEmpty()) key("genres") {
                                CompositionLocalProvider(LocalBringIntoViewSpec provides TvReihenBringIntoView) {
                                    LazyRow(contentPadding = PaddingValues(horizontal = TvStil.randSeite, vertical = TvStil.reihenLuft),
                                            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                        items(e.startGenres) { g -> TvChip(g, false) { oeffnen(Ziel(g, g, "Genre")) } }
                                    }
                                }
                            }
                            // **Zwei Platzhalterreihen, nicht eine** — die erste quer wie
                            // „Weiterschauen", die zweite hochkant wie die uebrigen. So springt beim
                            // Ankommen der Reihen nichts in der Form um.
                            if (liste == null) {
                                key("platzhalter-quer") { TvReihenplatzhalter(quer = true) }
                                key("platzhalter-plakat") { TvReihenplatzhalter(quer = false) }
                            }
                            liste.orEmpty().forEachIndexed { i, r -> key("$i-${r.titel}") {
                                Column(Modifier.onGloballyPositioned { c ->
                                    val lage = c.positionInParent().y.roundToInt() to c.size.height
                                    if (reihenlagen[i] != lage) reihenlagen[i] = lage
                                }) {
                                    TvReihentitel(r.titel)
                                    // Eigener, saveable Reihenstand (derselbe, den `LazyRow` sonst selbst
                                    // anlegt) — `eintrittsziel` liest daraus, welche Kacheln im Bild stehen.
                                    val zeile = rememberLazyListState()
                                    DisposableEffect(zeile, i) {
                                        reihenstaende[i] = zeile
                                        onDispose { if (reihenstaende[i] === zeile) reihenstaende.remove(i) }
                                    }
                                    CompositionLocalProvider(LocalBringIntoViewSpec provides TvReihenBringIntoView) {
                                        LazyRow(state = zeile, contentPadding = PaddingValues(horizontal = TvStil.randSeite, vertical = TvStil.reihenLuft),
                                                horizontalArrangement = Arrangement.spacedBy(TvStil.kachelAbstand)) {
                                            itemsIndexed(r.kacheln, key = { _, k -> k.id }) { _, k ->
                                                TvKachel(if (r.quer) k.quer ?: k.plakat else k.plakat, k.name, k.unterzeile, r.quer,
                                                         if (r.quer) k.fortschritt else null,
                                                         marke = k.marke, markenzahl = k.markenzahl,
                                                         modifier = Modifier.focusRequester(anfrage("$i|${k.id}")),
                                                         fokusGeaendert = { if (it) { aktuell = k; fokusReihe = i; zuletztAmTitel = "$i|${k.id}" } }) {
                                                    // „Weiterschauen" spielt direkt ab, wie auf tvOS.
                                                    if (r.quer) lauf.launch { weiterschauenWunsch(app, k.id)?.let { app.spiel.value = it } ?: oeffnenMitVorab(k) }
                                                    else oeffnenMitVorab(k)
                                                }
                                            }
                                        }
                                    }
                                }
                            } }
                        }
                    }
                }
            }
        }
    }
}

/**
 * Vorlage: die Platzhalterreihe in `HomeView` (`Reihenplatzhalter` auf dem Telefon, gleiche Form).
 * Ein leerer Titelbalken, darunter Kacheln in der Form, die kommt — kein Ladering, damit auf drei
 * Meter Entfernung nicht nur ein Punkt steht.
 */
@Composable
private fun TvReihenplatzhalter(quer: Boolean) {
    Column {
        TvReihentitel(" ")
        Row(Modifier.padding(horizontal = TvStil.randSeite, vertical = TvStil.reihenLuft),
            horizontalArrangement = Arrangement.spacedBy(TvStil.kachelAbstand)) {
            val breite = if (quer) TvStil.querBreite else TvStil.posterBreite
            val hoehe = if (quer) TvStil.querHoehe else TvStil.posterHoehe
            repeat(if (quer) 4 else 7) { Ladefeld(Modifier.size(breite, hoehe), TvStil.eckeKachel) }
        }
    }
}

/**
 * Vorlage: `Leerzustand(symbol: "wifi.exclamationmark", ...)` in `HomeView` fuer `stand.gestoert`.
 * **Eigens hier, nicht in `TvLeer`** (`TvSeiten.kt`): `TvLeer` kennt keinen Knopf, und diese Datei
 * darf `TvSeiten.kt` nicht aendern — sechs Agenten arbeiten gleichzeitig an eigenen Dateien.
 */
@Composable
private fun TvStartFehler(nochmal: () -> Unit) {
    val fokus = ersterFokus()
    Column(Modifier.fillMaxWidth().padding(top = 140.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(Icons.Filled.WifiOff, contentDescription = null, tint = Stil.schriftLeise, modifier = Modifier.size(36.dp))
        Text(uebersetzt("Der Server antwortet nicht"), style = TvStil.reihe, color = Stil.schrift,
             modifier = Modifier.padding(top = 16.dp))
        Text(uebersetzt("Prüf die Verbindung und versuch es noch einmal."), style = TvStil.koerper, color = Stil.schriftLeise,
             modifier = Modifier.padding(top = 8.dp).widthIn(max = 480.dp))
        TvKnopf(uebersetzt("Nochmal versuchen"), modifier = Modifier.padding(top = 22.dp).focusRequester(fokus)) { nochmal() }
    }
}

/**
 * Vorlage: `Kopfschatten` in `Sources/tvOS/TVBausteine.swift` — ein leiser Schatten unter der
 * Kopfleiste, kein langer Kopfverlauf: die Leiste soll lesbar bleiben, ohne dass die Startseite
 * dadurch anders aussieht als eine Detailseite. Vereinfacht auf einen abgetasteten senkrechten
 * Verlauf plus einen weichen Fleck rechts oben, hinter dem Profilzeichen der Kopfleiste — dort ist
 * die Kulisse am hellsten und der gleichmaessige Verlauf allein reicht nicht.
 */
@Composable
internal fun Kopfschatten() {
    val hoehe = kopfUnten + 45.dp
    Box(Modifier.fillMaxWidth().height(hoehe)
            .background(Brush.verticalGradient(
                0f to Stil.grund.copy(alpha = 0.46f), 0.35f to Stil.grund.copy(alpha = 0.30f),
                0.65f to Stil.grund.copy(alpha = 0.12f), 1f to Color.Transparent)))
    // Der Fleck sitzt rechts oben, hinter dem Profilzeichen der Kopfleiste — dort ist die Kulisse
    // am hellsten und der gleichmaessige Verlauf allein reicht nicht. Als `Canvas`, weil der
    // Mittelpunkt in Bildschirmpixeln gebraucht wird, nicht in Bruchteilen.
    androidx.compose.foundation.Canvas(Modifier.fillMaxWidth().height(hoehe + 40.dp)) {
        val zentrum = androidx.compose.ui.geometry.Offset(size.width * 0.945f, size.height * 0.06f)
        val radius = 260.dp.toPx()
        drawCircle(
            brush = Brush.radialGradient(
                listOf(Stil.grund.copy(alpha = 0.52f), Stil.grund.copy(alpha = 0.20f), Color.Transparent),
                center = zentrum, radius = radius),
            radius = radius, center = zentrum)
    }
}
