package de.paulherter.swiftly.tv

import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import android.graphics.Color as AndroidColor
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridScope
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.*
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.kern.Kern
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray

/** Den ersten Fokus setzen, sobald die Seite steht — ohne Fokus nimmt der Fernseher keine Eingabe an. */
@Composable
fun ersterFokus(bereit: Boolean = true): FocusRequester {
    val f = remember { FocusRequester() }
    LaunchedEffect(bereit) { if (bereit) { delay(60); runCatching { f.requestFocus() } } }
    return f
}

/**
 * Vorlage: das Raster aus `BibliothekView` — **sieben Spalten**, 104 dp breit mit 25 dp Luecke
 * (7 × 208 + 6 × 50 + 2 × 80 = 1916 Punkt auf tvOS). Kopf als ganze Zeile ueber dem Raster.
 *
 * **Nachladen ab der drittletzten Reihe** (`gitterSpalten * 3`), wie tvOS es beschreibt — der
 * Nachschub steht, bevor der Fokus unten ankommt.
 *
 * `laedt`: solange noch nichts da ist, stehen Platzhalterkacheln statt eines leeren Rasters —
 * Gegenstueck zu `Rasterplatzhalter` auf tvOS, das an derselben Stelle ein leeres Gitter vermeidet.
 */
@Composable
fun TvRaster(kacheln: List<Rasterkachel>, nachladen: () -> Unit = {}, fokus: FocusRequester? = null,
             oeffnen: (Ziel) -> Unit, laedt: Boolean = false, platzhalterReihen: Int = 2,
             mitUnterzeile: Boolean = true,
             kopf: @Composable () -> Unit, mehr: LazyGridScope.() -> Unit = {}) {
    val gitter = rememberLazyGridState()
    // **Zurueck heisst dorthin, wo man war** (tvOS: `zuletztAmTitel`). Das Raster behaelt seinen
    // Scrollstand ueber `rememberLazyGridState` (saveable, `TvHaupt` stellt die Seite wieder her) —
    // aber `fokus` hing immer an Kachel 0: nach dem Zurueckkommen war die entweder gar nicht
    // komponiert (Fokus nirgends) oder das Raster fuhr zu ihr nach oben. Jetzt haengt `fokus` beim
    // Wiedererscheinen an der zuletzt fokussierten Kachel, die mit dem Scrollstand im Bild steht.
    // Nur beim Erscheinen gelesen (`rueckkehr`), und verworfen, sobald neu geladen wird (Filter,
    // Bibliothek) — dann gilt wieder die erste Kachel.
    var zuletzt by rememberSaveable { mutableStateOf<String?>(null) }
    var rueckkehr by remember { mutableStateOf(zuletzt) }
    LaunchedEffect(laedt) { if (laedt) rueckkehr = null }
    val fokusIndex = rueckkehr?.let { id -> kacheln.indexOfFirst { it.id == id } }?.takeIf { it >= 0 } ?: 0
    val ende by remember { derivedStateOf { (gitter.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0) >= gitter.layoutInfo.totalItemsCount - TvStil.gitterSpalten * 3 } }
    LaunchedEffect(ende, kacheln.size) { if (ende && kacheln.isNotEmpty()) nachladen() }
    LazyVerticalGrid(GridCells.Fixed(TvStil.gitterSpalten), state = gitter, modifier = Modifier.fillMaxSize(),
                     contentPadding = PaddingValues(start = TvStil.randSeite, end = TvStil.randSeite, bottom = 40.dp),
                     horizontalArrangement = Arrangement.spacedBy(TvStil.gitterSpalte),
                     verticalArrangement = Arrangement.spacedBy(TvStil.gitterZeile - 16.dp)) {
        item(span = { GridItemSpan(maxLineSpan) }) { kopf() }
        if (laedt && kacheln.isEmpty()) {
            items(TvStil.gitterSpalten * platzhalterReihen) { TvKachelplatzhalter() }
        } else {
            items(kacheln.size, key = { kacheln[it].id }) { i ->
                val k = kacheln[i]
                // **Kein Jahr unter dem Titel in Bibliothek/Merkliste** (`mitUnterzeile: false` auf
                // tvOS) — in der Suche bleibt es, dort steht dort „Serie · 2008" statt eines Jahres.
                TvKachel(k.plakat, k.titel, if (mitUnterzeile) k.unterzeile else null,
                         marke = k.marke, markenzahl = k.markenzahl,
                         modifier = if (i == fokusIndex && fokus != null) Modifier.focusRequester(fokus) else Modifier,
                         fokusGeaendert = { if (it) zuletzt = k.id }) {
                    oeffnen(Ziel(k.id, k.titel, k.typ))
                }
            }
        }
        mehr()
    }
}

/** Vorlage: `Kachelplatzhalter` auf tvOS — Plakatmass, darunter zwei atmende Zeilen. */
@Composable
private fun TvKachelplatzhalter() {
    Column(Modifier.width(TvStil.posterBreite)) {
        Ladefeld(Modifier.size(TvStil.posterBreite, TvStil.posterHoehe), TvStil.eckeKachel)
        Ladefeld(Modifier.fillMaxWidth().height(11.dp).padding(top = 9.dp), 3.dp)
        Ladefeld(Modifier.size(42.dp, 9.dp).padding(top = 5.dp), 3.dp)
    }
}

/**
 * Vorlage: `grundton` in `BibliothekView` — Filme in der Komplementaerfarbe (351°), Serien im
 * Akzentton (171°), kraeftiger nahe der rechten oberen Ecke. tvOS rechnet das ueber ein
 * `MeshGradient` mit 25 Stuetzpunkten; Compose kennt kein Gegenstueck dafuer, deshalb ein
 * angenaeherter Radialverlauf von der gleichen Stelle nach durchsichtig, ueber `Stil.grund`.
 */
@Composable
private fun TvGrundton(art: String) {
    val ton = if (art == "movies") 351f else 171f
    val kern = remember(ton) { Color(AndroidColor.HSVToColor(floatArrayOf(ton, 0.42f, 0.16f))) }
    Canvas(Modifier.fillMaxSize()) {
        val mitte = Offset(size.width * 0.97f, size.height * 0.28f)
        drawRect(Brush.radialGradient(listOf(kern, Color.Transparent), center = mitte,
                                       radius = maxOf(size.width, size.height) * 1.05f))
    }
}

/**
 * Vorlage: `Leerzustand` auf tvOS — Zeichen, Titel, Hinweis, **und ein Ausweg**: „Auf der
 * Fernbedienung ist eine Sackgasse unangenehmer als am Finger" (tvOS-Kommentar). Ohne `knopf`
 * bleibt es beim blossen Hinweis, wie in Merkliste und Suche.
 */
@Composable
fun TvLeer(kopfzeile: String, text: String, symbol: Zeichen? = null, knopf: Pair<String, () -> Unit>? = null) {
    Column(Modifier.fillMaxWidth().padding(top = 80.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        symbol?.let {
            // **44, nicht 38** — tvOS setzt 88, hier gilt die Haelfte. Der Grad stand als
            // einzige Zahl in der Datei neben der Leiter. Kein Kreis darum: den traegt der
            // Leerzustand am Telefon, tvOS laesst ihn weg, und das bleibt so.
            Symbol(it, 44.dp, Modifier.padding(bottom = 10.dp), farbe = Stil.schriftSehrLeise)
        }
        Text(kopfzeile, style = TvStil.reihe, color = Stil.schrift)
        Text(text, style = TvStil.koerper, color = Stil.schriftLeise, textAlign = TextAlign.Center,
             modifier = Modifier.padding(top = 8.dp).widthIn(max = 480.dp))
        knopf?.let { (titel, tun) ->
            TvKnopf(titel, modifier = Modifier.padding(top = 16.dp), tun = tun)
        }
    }
}

/**
 * **Ein Wortlaut fuer „der Server hat nicht geantwortet", nicht dreizehn.** Vorlage:
 * `Stoerzustand` in `Sources/tvOS/Stil.swift`.
 *
 * Genau derselbe `TvLeer`, den Bibliothek, Startseite und Suche schon zeigen — mit der
 * **Serverformel**: „Server ist abgetaucht" / „‹Adresse› antwortet nicht. Laeuft er noch, oder
 * haengt das WLAN?" / „Erneut versuchen". Auf Android TV stand dafuer ein eigener Baustein mit
 * eigenem Wortlaut („Der Server antwortet nicht" / „Prueaf die Verbindung…"), und in Bibliothek,
 * Merkliste, Suche und Genre stand gar keiner: ein Netzfehler las sich dort als „hier liegt
 * nichts".
 *
 * `adresse` ist wahlweise: auf einer Seerr-Seite hat Jellyseerr geschwiegen, nicht der eigene
 * Server, und die falsche Adresse im Satz waere die falsche Fehlersuche.
 *
 * Das Zeichen ist `CloudOff` statt Apples `externaldrive.badge.xmark` — Android hat kein Symbol
 * fuer ein externes Laufwerk.
 */
@Composable
fun TvStoerung(app: SwiftlyAnwendung, adresse: String? = null, erneut: (() -> Unit)? = null) {
    TvLeer(uebersetzt("Server ist abgetaucht"),
           uebersetzt("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", adresse ?: app.serveradresse()),
           symbol = Zeichen.ServerWeg,
           knopf = erneut?.let { uebersetzt("Erneut versuchen") to it })
}

/**
 * Vorlage: `BibliothekView` auf tvOS. **Eine Reihe Kapseln**: vorn die Wahl — seit dem 23.09.2026
 * das Titelmenue des iPhones: „Alle", „Sammlungen", Strich und Rubrik „Bibliotheken", dann die
 * Bibliotheken (`Bereichsangebot`, nur ab `istMenue`) —, dann Filter und Sortierung als je eine
 * Kapsel mit Zeichen, rechts nur die Anzahl. Die Kapsel nennt den Wert: „Alle Filme", nicht wie am
 * iPhone nur „Filme" — die Kopfleiste sagt schon, wo man ist.
 *
 * **Keine Filterchips mehr** („Alle · Angefangen · Merkliste · Ungesehen") und kein „5 · sortiert
 * nach" rechts: am iPhone ist der Filter seit je ein Knopf, der den Wert nennt und eine Wahl
 * oeffnet, und tvOS hat das am 22.09. uebernommen (d82e0bd9). Jede Tafel klappt unter ihrer Kapsel
 * auf (`TvKapselMitTafel`), nicht am rechten Rand.
 *
 * **Bei „Sammlungen" nur die Anzahl**: die Liste muss man weder filtern noch umsortieren. Das Gitter
 * zeigt dann die Sammlungen mit „3 Filme" und, ohne eigenes Bild, dem Mosaik.
 */
@Composable
fun TvBibliothek(app: SwiftlyAnwendung, art: String, filter: List<String>, oeffnen: (Ziel) -> Unit) {
    val stand = remember { app.bibliotheken.getOrPut(art) { Bibliotheksstand(art, app.ablage) } }
    val lauf = rememberCoroutineScope()
    LaunchedEffect(stand.sortierung, stand.filter) { stand.laden(app.kern) }
    val sammlungen = stand.sammlungenGewaehlt
    val fokus = ersterFokus(!stand.laedt || sammlungen)
    Box(Modifier.fillMaxSize()) {
        // Je Bereich ein eigener Grundton — Serien im Akzent, Filme in der Komplementaerfarbe.
        // Man sieht am Grund, wo man ist, bevor man die Leiste liest.
        TvGrundton(art)
        TvRaster(if (sammlungen) emptyList() else stand.items, { lauf.launch { stand.nachladen(app.kern) } }, fokus, oeffnen,
                 laedt = stand.laedt && !sammlungen, mitUnterzeile = false, kopf = {
            Column(Modifier.padding(top = kopfUnten + 14.dp, bottom = 10.dp)) {
                // **Eine feste Hoehe mit und ohne Kapseln** (tvOS: `.frame(height: chipHoehe)`) — bei
                // „Sammlungen" fehlen Filter und Sortierung, sonst rutschte die Reihe beim Wechsel.
                Row(Modifier.height(TvStil.chipHoehe), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    // **Die Wahl als Kapsel, nur wenn es etwas zu waehlen gibt** — die Namen der
                    // Bibliotheken kommen vom Server und stehen wie sie sind.
                    if (stand.istMenue) {
                        TvKapselMitTafel(stand.beschriftung(stand.wahl), null,
                                         stand.angebot.map { Wahl(it.wert, stand.beschriftung(it.wert)) },
                                         stand.wahl, rubriken = stand.rubriken) { neu ->
                            if (neu != stand.wahl) {
                                stand.waehlen(neu)
                                lauf.launch { stand.laden(app.kern) }
                            }
                        }
                        // Senkrechter Strich, 2 × 60 % der Chiphoehe auf tvOS. Ohne Filter
                        // („Sammlungen") trennt er nichts und faellt weg.
                        if (!sammlungen) Box(Modifier.size(1.dp, TvStil.chipHoehe * 0.6f).background(Stil.rand))
                    }
                    // **Filter und Sortierung als je eine Kapsel mit Zeichen — wie die zwei
                    // `Wertpille`n am iPhone**, keine Chipreihe mehr (tvOS d82e0bd9). Jede nennt den
                    // Wert und klappt die Wahl unter sich auf; die gewaehlte Zeile traegt den Akzent.
                    if (!sammlungen) {
                        val filterwahl = filter.map { Wahl(it, Wahlen.text(Wahlen.filter, it)) }
                        TvKapselMitTafel(Wahlen.text(Wahlen.filter, stand.filter), Zeichen.Filter,
                                         filterwahl, stand.filter) { stand.filterSetzen(it) }
                        TvKapselMitTafel(Wahlen.text(Wahlen.sortierungen, stand.sortierung), Zeichen.Sortieren,
                                         Wahlen.sortierungen, stand.sortierung) { stand.sortierungSetzen(it) }
                    }
                    Spacer(Modifier.weight(1f).widthIn(min = 20.dp))
                    // Rechts nur die Anzahl, wie am iPhone.
                    if (sammlungen) {
                        if (stand.sammlungsliste.isNotEmpty())
                            Text(uebersetzt("%lld Sammlungen", stand.sammlungsliste.size), style = TvStil.klein, color = Stil.schriftSehrLeise)
                    } else if (stand.gesamt > 0) {
                        Text(uebersetzt("%lld Titel", stand.gesamt), style = TvStil.klein, color = Stil.schriftSehrLeise)
                    }
                }
                if (sammlungen) {
                    // Die Liste steht schon im Speicher: „Sammlungen" gibt es in der Tafel nur, wenn es welche gibt.
                } else if (stand.gestoert) TvStoerung(app, erneut = { lauf.launch { stand.laden(app.kern) } })
                else if (!stand.laedt && stand.items.isEmpty()) {
                    if (stand.filter == "alle") TvLeer(uebersetzt("Hier ist noch nichts"), uebersetzt("Sobald in dieser Bibliothek etwas liegt, taucht es hier auf."),
                        symbol = Zeichen.Ablage, knopf = uebersetzt("Aktualisieren") to { lauf.launch { stand.laden(app.kern) } })
                    else TvLeer(uebersetzt("Nichts gefunden"), uebersetzt("Unter diesem Filter liegt gerade nichts."),
                        symbol = Zeichen.Filter, knopf = uebersetzt("Filter zurücksetzen") to { stand.filterSetzen("alle") })
                }
            }
        }, mehr = {
            if (sammlungen) items(stand.sammlungsliste.size, key = { "sammlung" + stand.sammlungsliste[it].id }) { i ->
                val s = stand.sammlungsliste[i]
                TvSammlungKachel(app, s, art, if (i == 0) Modifier.focusRequester(fokus) else Modifier) {
                    oeffnen(sammlungsziel(s.id, s.name, art))
                }
            }
        })
    }
}

/**
 * Vorlage: eine Kapsel mit `KapselStil` plus `.tafel(unter:)` und `Handlungstafel(gewaehlt:)` aus
 * `BibliothekView` auf tvOS — **die Tafel haengt unter ihrem Ausloeser**, an seiner linken Kante,
 * 8 dp darunter (`Handlungstafel.luft` 16 → 8), 310 breit (620 → 310). Laeuft sie rechts hinaus,
 * richtet sie sich an seiner rechten Kante aus (`Handlungstafel.links`).
 *
 * Zeilen wie in der Handlungstafel: vorn der leere Kreis, bei der gewaehlten der gefuellte Haken —
 * **im Akzent**. Eine Formstufe allein ueberlebt drei Meter nicht (tvOS-Kommentar an `gewaehlt`).
 * Grund `erhoeht`, ohne Luft um die Zeilen, ohne Kopfzeile, ohne Abdunkeln der Seite.
 *
 * **Fokus**: beim Oeffnen auf die erste Zeile, nach Auswahl oder Zurueck wieder auf die Kapsel.
 * Solange sie offen ist, bleibt er drin — dasselbe Mittel wie `TvMehrknopf`.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun TvKapselMitTafel(text: String, symbol: Zeichen?, eintraege: List<Wahl>, gewaehlt: String,
                             rubriken: Map<String, String> = emptyMap(), waehlen: (String) -> Unit) {
    var offen by remember { mutableStateOf(false) }
    val kapsel = remember { FocusRequester() }
    // `exit = Cancel` sperrt auch das programmatische `requestFocus` nach draussen — `freigabe`
    // oeffnet den Ausgang genau fuer den Rueckweg auf die Kapsel.
    val freigabe = remember { booleanArrayOf(false) }
    fun schliessen() {
        freigabe[0] = true
        runCatching { kapsel.requestFocus() }
        offen = false
    }
    val rand = with(LocalDensity.current) { TvStil.randSeite.roundToPx() }
    val luft = with(LocalDensity.current) { 8.dp.roundToPx() }
    Box {
        TvKapsel(text, Modifier.focusRequester(kapsel), symbol = symbol) {
            if (offen) schliessen() else { freigabe[0] = false; offen = true }
        }
        if (offen) {
            BackHandler(onBack = { schliessen() })
            val erste = remember { FocusRequester() }
            LaunchedEffect(Unit) { delay(30); runCatching { erste.requestFocus() } }
            val lage = remember(rand, luft) {
                object : PopupPositionProvider {
                    override fun calculatePosition(anchorBounds: IntRect, windowSize: IntSize,
                                                   layoutDirection: LayoutDirection, popupContentSize: IntSize): IntOffset {
                        val breite = popupContentSize.width
                        val links = if (anchorBounds.left + breite <= windowSize.width - rand) anchorBounds.left
                                    else anchorBounds.right - breite
                        return IntOffset(links.coerceIn(rand, maxOf(rand, windowSize.width - rand - breite)),
                                         anchorBounds.bottom + luft)
                    }
                }
            }
            // **`focusable = true`: die Tafel ist ein eigenes Fenster** und bekommt nur so die Tasten.
            // Mit `false` stand der Fokus zwar auf ihrer ersten Zeile, aber jede Richtungstaste ging an
            // das Fenster darunter — der Fokus sprang ins Raster, in der Tafel war nichts waehlbar.
            // Zurueck schliesst sie ueber `onDismissRequest`.
            Popup(popupPositionProvider = lage, onDismissRequest = { schliessen() },
                  properties = PopupProperties(focusable = true)) {
                CompositionLocalProvider(LocalInnerhalbTafel provides true) {
                    Column(Modifier.width(310.dp).clip(RoundedCornerShape(TvStil.eckeFlaeche)).background(Stil.erhoeht)
                            .heightIn(max = 420.dp).verticalScroll(rememberScrollState())
                            .focusProperties { exit = { if (freigabe[0]) FocusRequester.Default else FocusRequester.Cancel } }
                            .focusGroup()) {
                        eintraege.forEachIndexed { i, e ->
                            rubriken[e.wert]?.let { ueber ->
                                // Die Rubrik der `Handlungstafel` — Trennlinie, darunter die
                                // Ueberschrift in Versalien, eingerueckt wie der Text der Zeilen.
                                Box(Modifier.padding(horizontal = 16.dp).fillMaxWidth().height(1.dp).background(Stil.linie))
                                Text(ueber.uppercase(), style = Stil.gruppe, color = Stil.schriftSehrLeise,
                                     modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 4.dp))
                            }
                            val an = e.wert == gewaehlt
                            TvZeile(e.text, if (an) Zeichen.HakenKreisVoll else Zeichen.Kreis,
                                    symbolFarbe = if (an) Stil.akzent else Stil.schrift,
                                    modifier = (if (i == 0) Modifier.focusRequester(erste) else Modifier)
                                        .semantics { selected = an }) {
                                schliessen()
                                waehlen(e.wert)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Vorlage: `MerklisteView` auf tvOS — ein eigener Bereich, weil der Fernseher keine Downloads hat. */
@Composable
fun TvMerkliste(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit) {
    val stand = app.merkliste
    val lauf = rememberCoroutineScope()
    val gattungen = remember { wahlenLesen(Kern.merkgattungen()) }
    LaunchedEffect(stand.gattung, stand.sortierung) { stand.laden(app.kern) }
    val fokus = ersterFokus(!stand.laedt)
    TvRaster(stand.items, { lauf.launch { stand.nachladen(app.kern) } }, fokus, oeffnen, laedt = stand.laedt, mitUnterzeile = false, kopf = {
        Column(Modifier.padding(top = kopfUnten + 14.dp, bottom = 10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                gattungen.forEach { g -> TvChip(g.text, stand.gattung == g.wert) { stand.gattungSetzen(g.wert) } }
                Spacer(Modifier.weight(1f))
                if (stand.gesamt > 0) Text(uebersetzt("%lld · sortiert nach", stand.gesamt), style = TvStil.klein, color = Stil.schriftLeise)
                TvKnopf(Wahlen.text(Wahlen.sortierungen, stand.sortierung), Zeichen.WinkelRunter, hoehe = TvStil.chipHoehe + 6.dp, symbolNachText = true) {
                    app.blatt.value = Blattwunsch(uebersetzt("Sortieren"), Wahlen.sortierungen, stand.sortierung) { stand.sortierungSetzen(it) }
                }
            }
            // Kein Ausweg-Knopf hier — anders als in der Bibliothek, tvOS' `MerklisteView.leer`
            // hat keinen: es gibt nichts zu aktualisieren oder zurueckzusetzen, nur den Hinweis,
            // wo man Titel hinzufuegt.
            if (stand.gestoert) TvStoerung(app, erneut = { lauf.launch { stand.laden(app.kern) } })
            else if (!stand.laedt && stand.items.isEmpty()) {
                TvLeer(uebersetzt("Noch nichts gemerkt"),
                    uebersetzt("Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort auswählst, sammelt sich hier."),
                    symbol = Zeichen.LesezeichenVoll)
            }
        }
    })
}

/**
 * Vorlage: `SucheView` auf tvOS — **kein Systemsuchfeld**: ein eigenes Feld im Kopf, gesucht wird
 * beim Tippen ab zwei Zeichen. Mit der Fernbedienung ist jedes getippte Wort teuer, deshalb steht
 * der Verlauf vorn. Treffer vom eigenen Server, darunter, was Seerr kennt.
 */
@Composable
fun TvSuche(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit) {
    val st = app.suche
    var verlaufRoh by remember { mutableStateOf(app.ablage.merkwert(Kern.suchverlaufSchluessel()).orEmpty()) }
    val verlauf = remember(verlaufRoh) { runCatching { JSONArray(Kern.suchverlaufListe(verlaufRoh)).let { a -> (0 until a.length()).map { a.getString(it) } } }.getOrDefault(emptyList()) }
    LaunchedEffect(st.begriff) { st.suchen(app, st.begriff.trim()) }
    val feld = ersterFokus()
    val fokusVerwalter = LocalFocusManager.current
    fun merken() { verlaufRoh = Kern.suchverlaufMerken(st.begriff, verlaufRoh); app.ablage.merken(Kern.suchverlaufSchluessel(), verlaufRoh) }

    TvRaster(st.treffer, oeffnen = oeffnen, laedt = st.sucht && st.treffer.isEmpty(), platzhalterReihen = 1, kopf = {
        Column(Modifier.padding(top = kopfUnten + 14.dp, bottom = 10.dp)) {
            var imFeld by remember { mutableStateOf(false) }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                BasicTextField(st.begriff, { st.begriff = it }, singleLine = true,
                    textStyle = TvStil.koerper.copy(color = Stil.schrift), cursorBrush = SolidColor(Stil.akzent),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { merken() }),
                    // **Hoch und Runter verlassen das Feld.** Das Textfeld nahm beide Tasten selbst
                    // (Schreibmarke an Anfang/Ende der Zeile) und meldete sie als erledigt: aus der
                    // Suche kam man weder in die Reiterleiste noch an Verlauf oder Treffer.
                    modifier = Modifier.width(460.dp).focusRequester(feld).onFocusChanged { imFeld = it.isFocused }
                        .onPreviewKeyEvent { e ->
                            val richtung = when (e.key) {
                                Key.DirectionUp -> FocusDirection.Up
                                Key.DirectionDown -> FocusDirection.Down
                                else -> return@onPreviewKeyEvent false
                            }
                            if (e.type == KeyEventType.KeyDown) fokusVerwalter.moveFocus(richtung)
                            true
                        },
                    decorationBox = { innen ->
                        // **Kein Rand, auch nicht im Fokus** — ein Suchfeld ist eine
                        // gefuellte Kapsel, kein gezeichneter Rahmen, und der Fokus hat mit
                        // der hellen Flaeche schon seine Anzeige. `flaeche` statt `erhoeht`.
                        Row(Modifier.height(44.dp).clip(RoundedCornerShape(TvStil.ecke))
                                .background(if (imFeld) TvStil.fokusflaeche else Stil.flaeche)
                                .padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                            Symbol(Zeichen.Lupe, 15.dp, farbe = Stil.schriftLeise, staerke = Staerke.Mittel)
                            Spacer(Modifier.width(10.dp))
                            Box(Modifier.weight(1f)) {
                                if (st.begriff.isEmpty()) Text(uebersetzt("Titel, Serie, Person"), style = TvStil.koerper, color = Stil.schriftSehrLeise)
                                innen()
                            }
                        }
                    })
                if (st.gesucht.isNotEmpty() && st.treffer.isNotEmpty()) Text(uebersetzt("%lld Treffer", st.treffer.size), style = TvStil.klein, color = Stil.schriftLeise)
            }
            when {
                st.begriff.isBlank() && verlauf.isNotEmpty() -> Column(Modifier.padding(top = 20.dp).width(460.dp).clip(RoundedCornerShape(TvStil.eckeFlaeche)).background(Stil.flaeche).padding(6.dp)) {
                    Text(uebersetzt("Zuletzt gesucht"), style = TvStil.reihe,
                         color = Stil.schriftLeise, modifier = Modifier.padding(12.dp))
                    verlauf.forEach { w -> TvZeile(w, Zeichen.Verlauf) { st.begriff = w } }
                    // Als letzte Zeile in der Karte, nicht als Knopf daneben — sonst eine Fokusfalle.
                    TvZeile(uebersetzt("Verlauf löschen"), Zeichen.Papierkorb) { verlaufRoh = ""; app.ablage.merken(Kern.suchverlaufSchluessel(), "") }
                }
                !Kern.suchbegriffTaugt(st.begriff.trim()) -> Text(uebersetzt("Titel, Serie oder Name. Ab zwei Zeichen wird gesucht."),
                                                               style = TvStil.koerper, color = Stil.schriftLeise, modifier = Modifier.padding(top = 20.dp))
                // **Gestoert ist nicht leer** — sonst sagt die Suche „Nichts gefunden", wenn
                // in Wahrheit niemand geantwortet hat.
                st.gestoert -> TvStoerung(app, erneut = { st.begriff = st.begriff + " "; st.begriff = st.begriff.trim() })
                !st.sucht && st.gesucht.isNotEmpty() && st.treffer.isEmpty() && st.seerr.isEmpty() ->
                    TvLeer(uebersetzt("Nichts gefunden"), uebersetzt("Versuch es mit einem anderen Wort."), symbol = Zeichen.Lupe)
            }
        }
    }, mehr = {
        if (st.seerr.isNotEmpty()) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Row(Modifier.padding(top = 20.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(uebersetzt("Kann angefragt werden"), style = TvStil.reihe, color = Stil.schrift)
                    // Wie `Zaehlmarke` auf tvOS — eine nackte Zahl, keine Plakette.
                    Text("${st.seerr.size}", style = TvStil.klein, color = Stil.schriftSehrLeise)
                }
            }
            items(st.seerr, key = { "seerr-" + it.schluessel }) { t ->
                TvKachel(t.plakat, t.titel, Seerrmarke.kurzwort(t.stand) ?: t.jahr?.toString(), deckkraft = 0.45f) {
                    app.seerrTreffer[t.schluessel] = t
                    oeffnen(Ziel(t.schluessel, t.titel, "Seerrtitel"))
                }
            }
        }
    })
}

// TvStreifen, TvBesetzung, TvDetail, TvPerson und TvGenre stehen seit heute in `TvTitel.kt` —
// das ist die Datei des TITEL-Agenten, hierher gehoeren sie nicht mehr.
