package de.paulherter.swiftly.tv

import android.graphics.Color as AndroidColor
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
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
                         modifier = if (i == 0 && fokus != null) Modifier.focusRequester(fokus) else Modifier) {
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
fun TvLeer(kopfzeile: String, text: String, symbol: ImageVector? = null, knopf: Pair<String, () -> Unit>? = null) {
    Column(Modifier.fillMaxWidth().padding(top = 80.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        symbol?.let {
            Icon(it, contentDescription = null, tint = Stil.schriftSehrLeise, modifier = Modifier.size(38.dp).padding(bottom = 10.dp))
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
 * Vorlage: `BibliothekView` auf tvOS. **Eine Chipreihe**: Bibliotheken (nur wenn es mehrere gibt),
 * dann die Filter; die Sortierung ist ein einzelner Knopf mit Tafel — vier Chips, von denen immer
 * genau einer an ist, sind eine Auswahl, kein Filter. Kein Kopfblock: eine Bibliothek beschreibt
 * keinen einzelnen Titel.
 */
@Composable
fun TvBibliothek(app: SwiftlyAnwendung, art: String, filter: List<String>, oeffnen: (Ziel) -> Unit) {
    val stand = remember { app.bibliotheken.getOrPut(art) { Bibliotheksstand(art, app.ablage) } }
    val lauf = rememberCoroutineScope()
    LaunchedEffect(stand.gewaehlt?.id, stand.sortierung, stand.filter) { stand.laden(app.kern) }
    val fokus = ersterFokus(!stand.laedt)
    Box(Modifier.fillMaxSize()) {
        // Je Bereich ein eigener Grundton — Serien im Akzent, Filme in der Komplementaerfarbe.
        // Man sieht am Grund, wo man ist, bevor man die Leiste liest.
        TvGrundton(art)
        TvRaster(stand.items, { lauf.launch { stand.nachladen(app.kern) } }, fokus, oeffnen, laedt = stand.laedt, mitUnterzeile = false, kopf = {
            Column(Modifier.padding(top = kopfUnten + 14.dp, bottom = 10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (stand.sammlungen.size > 1) {
                        stand.sammlungen.forEach { s -> TvChip(s.name, stand.gewaehlt?.id == s.id) { stand.waehlen(s) } }
                        Box(Modifier.size(1.dp, 20.dp).background(Stil.rand))
                    }
                    filter.forEach { f -> TvChip(Wahlen.text(Wahlen.filter, f), stand.filter == f) { stand.filterSetzen(f) } }
                    Spacer(Modifier.weight(1f))
                    if (stand.gesamt > 0) Text(uebersetzt("%lld · sortiert nach", stand.gesamt), style = TvStil.klein, color = Stil.schriftLeise)
                    TvKnopf(Wahlen.text(Wahlen.sortierungen, stand.sortierung), Icons.Filled.KeyboardArrowDown, hoehe = TvStil.chipHoehe + 6.dp, symbolNachText = true) {
                        app.blatt.value = Blattwunsch(uebersetzt("Sortieren"), Wahlen.sortierungen, stand.sortierung) { stand.sortierungSetzen(it) }
                    }
                }
                if (!stand.laedt && stand.items.isEmpty()) {
                    if (stand.filter == "alle") TvLeer(uebersetzt("Hier ist noch nichts"), uebersetzt("Sobald in dieser Bibliothek etwas liegt, taucht es hier auf."),
                        symbol = Icons.Filled.Inbox, knopf = uebersetzt("Aktualisieren") to { lauf.launch { stand.laden(app.kern) } })
                    else TvLeer(uebersetzt("Nichts gefunden"), uebersetzt("Unter diesem Filter liegt gerade nichts."),
                        symbol = Icons.Filled.FilterList, knopf = uebersetzt("Filter zurücksetzen") to { stand.filterSetzen("alle") })
                }
            }
        })
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
                TvKnopf(Wahlen.text(Wahlen.sortierungen, stand.sortierung), Icons.Filled.KeyboardArrowDown, hoehe = TvStil.chipHoehe + 6.dp, symbolNachText = true) {
                    app.blatt.value = Blattwunsch(uebersetzt("Sortieren"), Wahlen.sortierungen, stand.sortierung) { stand.sortierungSetzen(it) }
                }
            }
            // Kein Ausweg-Knopf hier — anders als in der Bibliothek, tvOS' `MerklisteView.leer`
            // hat keinen: es gibt nichts zu aktualisieren oder zurueckzusetzen, nur den Hinweis,
            // wo man Titel hinzufuegt.
            if (!stand.laedt && stand.items.isEmpty()) {
                TvLeer(uebersetzt("Noch nichts gemerkt"),
                    uebersetzt("Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort auswählst, sammelt sich hier."),
                    symbol = Icons.Filled.Bookmark)
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
    fun merken() { verlaufRoh = Kern.suchverlaufMerken(st.begriff, verlaufRoh); app.ablage.merken(Kern.suchverlaufSchluessel(), verlaufRoh) }

    TvRaster(st.treffer, oeffnen = oeffnen, laedt = st.sucht && st.treffer.isEmpty(), platzhalterReihen = 1, kopf = {
        Column(Modifier.padding(top = kopfUnten + 14.dp, bottom = 10.dp)) {
            var imFeld by remember { mutableStateOf(false) }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                BasicTextField(st.begriff, { st.begriff = it }, singleLine = true,
                    textStyle = TextStyle(fontSize = 17.sp, color = Stil.schrift), cursorBrush = SolidColor(Stil.akzent),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { merken() }),
                    modifier = Modifier.width(460.dp).focusRequester(feld).onFocusChanged { imFeld = it.isFocused },
                    decorationBox = { innen ->
                        Row(Modifier.height(44.dp).clip(RoundedCornerShape(TvStil.ecke))
                                .background(if (imFeld) TvStil.fokusflaeche else Stil.erhoeht)
                                .border(1.dp, if (imFeld) Color.White.copy(alpha = 0.5f) else Color.Transparent, RoundedCornerShape(TvStil.ecke))
                                .padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Outlined.Search, contentDescription = null, tint = Stil.schriftLeise, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(10.dp))
                            Box(Modifier.weight(1f)) {
                                if (st.begriff.isEmpty()) Text(uebersetzt("Titel, Serie, Person"), style = TextStyle(fontSize = 17.sp), color = Stil.schriftSehrLeise)
                                innen()
                            }
                        }
                    })
                if (st.gesucht.isNotEmpty() && st.treffer.isNotEmpty()) Text(uebersetzt("%lld Treffer", st.treffer.size), style = TvStil.klein, color = Stil.schriftLeise)
            }
            when {
                st.begriff.isBlank() && verlauf.isNotEmpty() -> Column(Modifier.padding(top = 20.dp).width(460.dp).clip(RoundedCornerShape(10.dp)).background(Stil.flaeche).padding(6.dp)) {
                    Text(uebersetzt("Zuletzt gesucht").uppercase(), style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.2.sp),
                         color = Stil.schriftSehrLeise, modifier = Modifier.padding(12.dp))
                    verlauf.forEach { w -> TvZeile(w, Icons.Filled.History) { st.begriff = w } }
                    // Als letzte Zeile in der Karte, nicht als Knopf daneben — sonst eine Fokusfalle.
                    TvZeile(uebersetzt("Verlauf löschen"), Icons.Filled.Delete) { verlaufRoh = ""; app.ablage.merken(Kern.suchverlaufSchluessel(), "") }
                }
                !Kern.suchbegriffTaugt(st.begriff.trim()) -> Text(uebersetzt("Titel, Serie oder Name. Ab zwei Zeichen wird gesucht."),
                                                               style = TvStil.koerper, color = Stil.schriftLeise, modifier = Modifier.padding(top = 20.dp))
                !st.sucht && st.gesucht.isNotEmpty() && st.treffer.isEmpty() && st.seerr.isEmpty() ->
                    TvLeer(uebersetzt("Nichts gefunden"), uebersetzt("Versuch es mit einem anderen Wort."), symbol = Icons.Outlined.Search)
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
