package de.paulherter.swiftly.tv

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
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

/**
 * Dasselbe Werkzeug wie oben, aber fuer Seiten **ohne** eigene Scroll-Steuerung (Serie, Film, Person,
 * Seerr-Detail — `verticalScroll`, keine `LazyColumn`): dort darf die senkrechte Seite nicht ganz
 * taub werden, sonst waere ein Abschnitt unterhalb des Bildes gar nicht mehr erreichbar.
 *
 * Ein Objekt ohne eigene Ueberschreibung erbt `BringIntoViewSpec.calculateScrollDistance`s
 * Standardmethode — dieselbe Rechnung, die auf einem Telefon (ohne `leanback`-Merkmal) automatisch
 * greift: **scrollen nur, wenn das Ziel nicht schon vollstaendig im Bild steht**, dann in einem Zug um
 * genau die noetige Strecke. Kein Pivot-Zurechtruecken, also kein Zappeln bei einem Fokuswechsel, der
 * ohnehin im Bild bleibt — aber ein Wechsel in einen Abschnitt ausserhalb des Bildes scrollt weiterhin.
 */
@OptIn(ExperimentalFoundationApi::class)
object TvAbschnittsweisesBringIntoView : BringIntoViewSpec

/**
 * Vorlage: `Kopfauskunft` — **eine Quelle** fuer Startseite und Detailseiten, sonst laufen sie
 * auseinander. Feste Hoehen: wechselt der Fokus, springt darunter nichts.
 *
 * `schluss` ist das Gegenstueck zu tvOS' `@ViewBuilder var schluss`: auf der Startseite die
 * `TvRestzeitmarke`, auf Detailseiten und bei Seerr leer (Vorgabe) — dieselbe Funktion, kein
 * zweiter Aufbau.
 */
@Composable
fun Kopfauskunft(titel: String, zweitzeile: String?, text: String?, modifier: Modifier = Modifier,
                 schluss: @Composable () -> Unit = {}) {
    Column(modifier.width(500.dp)) {
        Text(titel, style = TvStil.auskunftTitel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.height(34.dp))
        Text(zweitzeile.orEmpty(), style = TvStil.koerper, color = Stil.schrift.copy(alpha = 0.68f), maxLines = 1,
             overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 7.dp).height(20.dp))
        Row(Modifier.padding(top = 11.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            text?.let {
                Text(it, style = TvStil.koerper, color = Stil.schriftLeise, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
            schluss()
        }
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

    var aktuell by remember { mutableStateOf<Kachel?>(null) }
    val liste = reihen
    LaunchedEffect(liste) { if (aktuell == null) aktuell = liste?.firstOrNull()?.kacheln?.firstOrNull() }
    var bild by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(aktuell) { delay(250); bild = aktuell?.let { it.quer ?: it.plakat } }
    val erster = remember { FocusRequester() }
    LaunchedEffect(liste != null) { if (liste != null) { delay(60); runCatching { erster.requestFocus() } } }

    // **Ein Abschnitt passt ins Fenster** — wandert der Fokus in eine andere Reihe, stellt der
    // Fokusmotor auf tvOS Reihentitel und Kacheln gemeinsam frei, statt die vorherige Reihe
    // halb abgeschnitten stehen zu lassen. `listenzustand` ist das Kotlin-Gegenstueck: die
    // Zeile der fokussierten Reihe wandert an den oberen Rand des Fensters.
    val listenzustand = rememberLazyListState()
    var fokusReihe by remember { mutableStateOf(0) }
    val chipVersatz = if (e.genreChips && e.startGenres.isNotEmpty()) 1 else 0
    LaunchedEffect(fokusReihe, liste) {
        if (liste == null) return@LaunchedEffect
        // Auf der ersten Reihe ganz nach oben, damit die Genre-Chips wieder mit ins Bild kommen —
        // nicht nur bis zum Reihentitel, der Chip-Zeile knapp darueber liegen liesse.
        listenzustand.animateScrollToItem(if (fokusReihe == 0) 0 else fokusReihe + chipVersatz)
    }

    // Wie auf Apple: „gar nichts geladen" ist etwas anderes als „nichts vorhanden" —
    // Genre-Chips sind ein Einstieg, kein Inhalt, und zaehlen deshalb nicht mit.
    val alleLeer = liste != null && liste.isEmpty() && !gestoert

    Box(Modifier.fillMaxSize()) {
        // Vorlage: `HomeView` `.bildgrund(url: kulissenURL)` — ganz hinten, unter Fehler-,
        // Leer- und Reihenzustand, mit demselben Bild wie `Kulisse` unten.
        TvBildgrund(bild)
        when {
            gestoert -> TvStartFehler { lauf.launch { laden() } }
            alleLeer -> TvLeer(uebersetzt("Hier ist noch nichts"), uebersetzt("Sobald auf dem Server etwas liegt, taucht es hier auf."))
            else -> {
                Kulisse(bild, Modifier.align(Alignment.TopEnd))
                Column(Modifier.fillMaxSize()) {
                    Box(Modifier.fillMaxWidth().height(TvStil.heldenHoehe)) {
                        Kopfschatten()
                        // Vorlage: `auskunft` in `HomeView.swift` — derselbe Baustein wie die
                        // Detailseite (`Kopfauskunft`), mit dem Folgennamen als Zweitzeile und der
                        // Restzeitmarke hinten dran, statt eines eigenen zweiten Aufbaus.
                        aktuell?.let { k ->
                            Kopfauskunft(k.name, k.folgenname, k.angabenzeile,
                                         Modifier.padding(start = TvStil.randSeite, top = kopfUnten + 34.dp)) {
                                TvRestzeitmarke(k.restzeit, k.gesehen)
                            }
                        }
                    }
                    // `focusRestorer`: kommt der Fokus von einer Detailseite zurueck, steht er
                    // wieder auf der zuletzt fokussierten Kachel, nicht auf der ersten — wie
                    // `zuletztAmTitel`/`defaultFocus` auf tvOS. Vor dem ersten Fokus greift
                    // `erster` als Rueckfall.
                    // Senkrecht abgeschaltet, siehe `TvKeinSenkrechtesBringIntoView` — der
                    // Reihenwechsel oben (`animateScrollToItem`) bewegt die Liste schon bewusst, ein
                    // zusaetzliches Bring-into-View liess beim waagerechten Wandern in einer Reihe
                    // alles kurz hoch- und runterzucken. In jeder `LazyRow` unten steht die
                    // Systemvorgabe (`TvReihenBringIntoView`, der Nachbau davon) wieder bereit, damit
                    // die naechste Kachel dort weiter mitgescrollt wird.
                    CompositionLocalProvider(LocalBringIntoViewSpec provides TvKeinSenkrechtesBringIntoView) {
                        LazyColumn(Modifier.weight(1f).focusRestorer { erster }, state = listenzustand,
                                   contentPadding = PaddingValues(bottom = 40.dp),
                                   verticalArrangement = Arrangement.spacedBy(TvStil.reihenAbstand - TvStil.reihenLuft * 2)) {
                            if (e.genreChips && e.startGenres.isNotEmpty()) item(key = "genres") {
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
                                item(key = "platzhalter-quer") { TvReihenplatzhalter(quer = true) }
                                item(key = "platzhalter-plakat") { TvReihenplatzhalter(quer = false) }
                            }
                            itemsIndexed(liste.orEmpty(), key = { i, r -> "$i-${r.titel}" }) { i, r ->
                                Column {
                                    TvReihentitel(r.titel)
                                    CompositionLocalProvider(LocalBringIntoViewSpec provides TvReihenBringIntoView) {
                                        LazyRow(contentPadding = PaddingValues(horizontal = TvStil.randSeite, vertical = TvStil.reihenLuft),
                                                horizontalArrangement = Arrangement.spacedBy(TvStil.kachelAbstand)) {
                                            itemsIndexed(r.kacheln, key = { _, k -> k.id }) { j, k ->
                                                TvKachel(if (r.quer) k.quer ?: k.plakat else k.plakat, k.name, k.unterzeile, r.quer,
                                                         if (r.quer) k.fortschritt else null,
                                                         marke = k.marke, markenzahl = k.markenzahl,
                                                         modifier = if (i == 0 && j == 0) Modifier.focusRequester(erster) else Modifier,
                                                         fokusGeaendert = { if (it) { aktuell = k; fokusReihe = i } }) {
                                                    // „Weiterschauen" spielt direkt ab, wie auf tvOS.
                                                    if (r.quer) lauf.launch { weiterschauenWunsch(app, k.id)?.let { app.spiel.value = it } ?: oeffnen(Ziel(k.id, k.name, k.typ)) }
                                                    else oeffnen(Ziel(k.id, k.name, k.typ))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
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
private fun Kopfschatten() {
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
