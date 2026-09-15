package de.paulherter.swiftly.tv

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.*
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.kern.Kern
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

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
 */
@Composable
fun TvRaster(kacheln: List<Rasterkachel>, nachladen: () -> Unit = {}, fokus: FocusRequester? = null,
             oeffnen: (Ziel) -> Unit, kopf: @Composable () -> Unit, mehr: LazyGridScope.() -> Unit = {}) {
    val gitter = rememberLazyGridState()
    val ende by remember { derivedStateOf { (gitter.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0) >= gitter.layoutInfo.totalItemsCount - 14 } }
    LaunchedEffect(ende, kacheln.size) { if (ende && kacheln.isNotEmpty()) nachladen() }
    LazyVerticalGrid(GridCells.Fixed(TvStil.gitterSpalten), state = gitter, modifier = Modifier.fillMaxSize(),
                     contentPadding = PaddingValues(start = TvStil.randSeite, end = TvStil.randSeite, bottom = 40.dp),
                     horizontalArrangement = Arrangement.spacedBy(TvStil.gitterSpalte),
                     verticalArrangement = Arrangement.spacedBy(TvStil.gitterZeile - 16.dp)) {
        item(span = { GridItemSpan(maxLineSpan) }) { kopf() }
        items(kacheln.size, key = { kacheln[it].id }) { i ->
            val k = kacheln[i]
            TvKachel(k.plakat, k.titel, k.unterzeile, modifier = if (i == 0 && fokus != null) Modifier.focusRequester(fokus) else Modifier) {
                oeffnen(Ziel(k.id, k.titel, k.typ))
            }
        }
        mehr()
    }
}

/** Vorlage: `Leerzustand` — gross, mittig, ohne Knopf, der nichts tut. */
@Composable
fun TvLeer(kopfzeile: String, text: String) {
    Column(Modifier.fillMaxWidth().padding(top = 80.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(kopfzeile, style = TvStil.reihe, color = Stil.schrift)
        Text(text, style = TvStil.koerper, color = Stil.schriftLeise, modifier = Modifier.padding(top = 8.dp).widthIn(max = 480.dp))
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
    TvRaster(stand.items, { lauf.launch { stand.nachladen(app.kern) } }, fokus, oeffnen, kopf = {
        Column(Modifier.padding(top = kopfUnten + 14.dp, bottom = 10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (stand.sammlungen.size > 1) {
                    stand.sammlungen.forEach { s -> TvChip(s.name, stand.gewaehlt?.id == s.id) { stand.waehlen(s) } }
                    Box(Modifier.size(1.dp, 20.dp).background(Stil.rand))
                }
                filter.forEach { f -> TvChip(Wahlen.text(Wahlen.filter, f), stand.filter == f) { stand.filterSetzen(f) } }
                Spacer(Modifier.weight(1f))
                Text(uebersetzt("%lld Titel", stand.gesamt), style = TvStil.klein, color = Stil.schriftLeise)
                TvKnopf(Wahlen.text(Wahlen.sortierungen, stand.sortierung), Icons.Filled.KeyboardArrowDown, hoehe = TvStil.chipHoehe + 6.dp) {
                    app.blatt.value = Blattwunsch(uebersetzt("Sortieren"), Wahlen.sortierungen, stand.sortierung) { stand.sortierungSetzen(it) }
                }
            }
            if (!stand.laedt && stand.items.isEmpty()) {
                if (stand.filter == "alle") TvLeer(uebersetzt("Hier ist noch nichts"), uebersetzt("Sobald in dieser Bibliothek etwas liegt, taucht es hier auf."))
                else TvLeer(uebersetzt("Nichts gefunden"), uebersetzt("Unter diesem Filter liegt gerade nichts."))
            }
        }
    })
}

/** Vorlage: `MerklisteView` auf tvOS — ein eigener Bereich, weil der Fernseher keine Downloads hat. */
@Composable
fun TvMerkliste(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit) {
    val stand = app.merkliste
    val lauf = rememberCoroutineScope()
    val gattungen = remember { wahlenLesen(Kern.merkgattungen()) }
    LaunchedEffect(stand.gattung, stand.sortierung) { stand.laden(app.kern) }
    val fokus = ersterFokus(!stand.laedt)
    TvRaster(stand.items, { lauf.launch { stand.nachladen(app.kern) } }, fokus, oeffnen, kopf = {
        Column(Modifier.padding(top = kopfUnten + 14.dp, bottom = 10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                gattungen.forEach { g -> TvChip(g.text, stand.gattung == g.wert) { stand.gattungSetzen(g.wert) } }
                Spacer(Modifier.weight(1f))
                Text(uebersetzt("%lld Titel", stand.gesamt), style = TvStil.klein, color = Stil.schriftLeise)
                TvKnopf(Wahlen.text(Wahlen.sortierungen, stand.sortierung), Icons.Filled.KeyboardArrowDown, hoehe = TvStil.chipHoehe + 6.dp) {
                    app.blatt.value = Blattwunsch(uebersetzt("Sortieren"), Wahlen.sortierungen, stand.sortierung) { stand.sortierungSetzen(it) }
                }
            }
            if (!stand.laedt && stand.items.isEmpty()) {
                TvLeer(uebersetzt("Merkliste"), uebersetzt("Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort auswählst, sammelt sich hier."))
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

    TvRaster(st.treffer, oeffnen = oeffnen, kopf = {
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
                    TvLeer(uebersetzt("Nichts gefunden"), uebersetzt("Versuch es mit einem anderen Wort."))
            }
        }
    }, mehr = {
        if (st.seerr.isNotEmpty()) {
            item(span = { GridItemSpan(maxLineSpan) }) { Text(uebersetzt("Kann angefragt werden"), style = TvStil.reihe, color = Stil.schrift, modifier = Modifier.padding(top = 20.dp)) }
            items(st.seerr, key = { "seerr-" + it.schluessel }) { t ->
                TvKachel(t.plakat, t.titel, Seerrmarke.kurzwort(t.stand) ?: t.jahr?.toString(), deckkraft = 0.45f) {
                    app.seerrTreffer[t.schluessel] = t
                    oeffnen(Ziel(t.schluessel, t.titel, "Seerrtitel"))
                }
            }
        }
    })
}

/** Ein Streifen mit Titel — `reihenabschnitt` und `streifen` aus `Titelreihen.swift`. */
@Composable
fun TvStreifen(titel: String, inhalt: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    Column(Modifier.padding(top = TvStil.reihenAbstand - TvStil.reihenLuft)) {
        TvReihentitel(titel)
        LazyRow(contentPadding = PaddingValues(horizontal = TvStil.randSeite, vertical = TvStil.reihenLuft),
                horizontalArrangement = Arrangement.spacedBy(TvStil.kachelAbstand), content = inhalt)
    }
}

/** Vorlage: `Besetzungskachel` — rund, 104 dp, Name und Rolle darunter. */
@Composable
fun TvBesetzung(p: Mitwirkender, tun: () -> Unit) {
    Column(Modifier.width(TvStil.posterBreite), horizontalAlignment = Alignment.CenterHorizontally) {
        Fokusflaeche(tun = tun) {
            Box(Modifier.size(TvStil.posterBreite).clip(CircleShape).background(Stil.flaeche), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Person, contentDescription = null, tint = Stil.schriftSehrLeise, modifier = Modifier.size(36.dp))
                AsyncImage(model = p.bild, contentDescription = p.name, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            }
        }
        Text(p.name, style = TvStil.kachel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 7.dp))
        p.rolle?.let { Text(it, style = TvStil.klein, color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis) }
    }
}

/**
 * Vorlage: `DetailView` auf tvOS — **510 hoch, nicht 1080**: Kulisse rechts, Text links, darunter
 * beginnen die Reihen auf derselben Hoehe wie auf der Startseite. Kein Zurueckpfeil: Zurueck macht
 * die Fernbedienung. **Ein Hauptknopf mit Text, dahinter drei quadratische** (Von vorn, Merkliste,
 * Mehr); „Gesehen" steht in der Tafel. Der erste Fokus liegt auf dem Hauptknopf.
 */
@Composable
fun TvDetail(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit) {
    var t by remember(ziel.id) { mutableStateOf(app.titelSpeicher[ziel.id]) }
    var aehnliche by remember(ziel.id) { mutableStateOf<List<Rasterkachel>>(emptyList()) }
    var extras by remember(ziel.id) { mutableStateOf<List<Extra>>(emptyList()) }
    val lauf = rememberCoroutineScope()
    val spielt = app.spiel.value != null
    LaunchedEffect(ziel.id, spielt) {
        if (spielt) return@LaunchedEffect
        try { t = titelLesen(withContext(Dispatchers.IO) { app.kern.titel(ziel.id).await() }).also { app.titelSpeicher[ziel.id] = it } }
        catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }
    LaunchedEffect(ziel.id) {
        try {
            val o = JSONObject(withContext(Dispatchers.IO) { app.kern.titelUmfeld(ziel.id).await() })
            aehnliche = o.feldListe("aehnliche") { rasterkachelLesen(it) }
            extras = o.feldListe("extras") { Extra(it.getString("id"), it.getString("name"), it.feldText("bild"), it.feldText("laufzeit")) }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }
    val haupt = ersterFokus()
    val titel = t
    val name = titel?.name ?: ziel.name

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        Kulisse(titel?.kopfbild, Modifier.align(Alignment.TopEnd))
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Column(Modifier.padding(start = TvStil.randSeite, top = 98.dp).height(TvStil.heldenHoehe + 20.dp - 98.dp)) {
                Kopfauskunft(name, titel?.nebenzeile, titel?.beschreibung)
                Row(Modifier.padding(top = 18.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    TvKnopf(uebersetzt(if (titel?.fortsetzenAb != null) "Fortsetzen" else "Abspielen"), Icons.Filled.PlayArrow, Modifier.focusRequester(haupt)) {
                        if (titel?.planDa == true) app.spiel.value = Abspielwunsch(ziel.id, titel.fortsetzenAb)
                    }
                    if (titel?.fortsetzenAb != null) TvKnopf(null, Icons.Filled.Replay) { app.spiel.value = Abspielwunsch(ziel.id, null) }
                    TvKnopf(null, if (titel?.gemerkt == true) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder) {
                        val an = !(titel?.gemerkt ?: false)
                        titel?.let { t = it.copy(gemerkt = an) }
                        lauf.launch { if (withContext(Dispatchers.IO) { app.kern.merken(ziel.id, an).await() }.isNotEmpty()) titel?.let { t = it } }
                    }
                    TvKnopf(null, Icons.Filled.MoreHoriz) {
                        val gesehen = titel?.gesehen ?: false
                        app.blatt.value = Blattwunsch(name, listOf(
                            Wahl("gesehen", uebersetzt(if (gesehen) "Als ungesehen merken" else "Als gesehen merken")),
                            Wahl("metadaten", uebersetzt("Metadaten neu einlesen"))), null,
                            mapOf("gesehen" to Icons.Filled.CheckCircle, "metadaten" to Icons.Filled.Refresh)) { wahl ->
                            lauf.launch {
                                when (wahl) {
                                    "gesehen" -> if (withContext(Dispatchers.IO) { app.kern.gesehen(ziel.id, !gesehen).await() }.isEmpty()) titel?.let { t = it.copy(gesehen = !gesehen) }
                                    "metadaten" -> withContext(Dispatchers.IO) { app.kern.metadatenAuffrischen(ziel.id).await() }
                                }
                            }
                        }
                    }
                }
            }
            if (aehnliche.isNotEmpty()) TvStreifen(uebersetzt("Ähnliche Filme")) {
                items(aehnliche, key = { it.id }) { k -> TvKachel(k.plakat, k.titel, k.unterzeile) { oeffnen(Ziel(k.id, k.titel, k.typ)) } }
            }
            if (extras.isNotEmpty()) TvStreifen(uebersetzt("Extras")) {
                items(extras, key = { it.id }) { x -> TvKachel(x.bild, x.name, x.laufzeit, quer = true) { app.spiel.value = Abspielwunsch(x.id, null) } }
            }
            val leute = titel?.darsteller.orEmpty()
            if (leute.isNotEmpty()) TvStreifen(uebersetzt("Besetzung")) {
                items(leute, key = { it.id }) { p -> TvBesetzung(p) { oeffnen(Ziel(p.id, p.name, "Person", p.rolle, name)) } }
            }
            Spacer(Modifier.height(40.dp))
        }
    }
}

/**
 * Vorlage: `PersonView` auf tvOS — aufgebaut wie eine Detailseite: rundes Bild, Name, Geburt, Ort,
 * die Rolle im Akzent. Das Banner wechselt alle sechs Sekunden weich zwischen den Querbildern.
 */
@Composable
fun TvPerson(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit) {
    var stand by remember(ziel.id) { mutableStateOf(app.personenSpeicher[ziel.id]) }
    LaunchedEffect(ziel.id) {
        try { stand = personLesen(withContext(Dispatchers.IO) { app.kern.person(ziel.id).await() }).also { app.personenSpeicher[ziel.id] = it } }
        catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }
    val s = stand
    var anfragbar by remember(ziel.id) { mutableStateOf<List<Seerrkachel>>(emptyList()) }
    LaunchedEffect(s?.tmdb, app.seerrVerbunden.value) {
        val tmdb = s?.tmdb ?: return@LaunchedEffect
        if (!app.seerrVerbunden.value) return@LaunchedEffect
        val eigene = s.titel.mapTo(HashSet()) { it.titel.lowercase() }
        anfragbar = seerrkachelnLesen(withContext(Dispatchers.IO) { app.kern.seerrFilmografie(tmdb.toLong()).await() }).filter { it.titel.lowercase() !in eigene }
    }
    val banner = s?.banner.orEmpty()
    var stelle by remember(ziel.id) { mutableIntStateOf(0) }
    LaunchedEffect(banner.size) { if (banner.size > 1) while (true) { delay(6000); stelle++ } }
    val fokus = ersterFokus(s != null)

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        // Weich und langsam: 1,2 s zwischen den Querbildern der Titel.
        Kulisse(banner.getOrNull(if (banner.isEmpty()) 0 else stelle % banner.size), Modifier.align(Alignment.TopEnd), dauer = 1200)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Row(Modifier.padding(start = TvStil.randSeite, top = 98.dp).height(TvStil.heldenHoehe + 20.dp - 98.dp),
                horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                Box(Modifier.size(TvStil.posterBreite).clip(CircleShape).background(Stil.flaeche), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Person, contentDescription = null, tint = Stil.schriftSehrLeise, modifier = Modifier.size(40.dp))
                    AsyncImage(model = s?.bild, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                }
                Column(Modifier.width(480.dp)) {
                    Text(ziel.name, style = TvStil.titelGross, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    val zeile = listOfNotNull(s?.geboren?.let { uebersetzt("Geboren %@", it) }, s?.ort).joinToString(" · ")
                    Text(zeile, style = TvStil.koerper, color = Stil.schriftLeise, maxLines = 1, modifier = Modifier.padding(top = 4.dp))
                    if (!ziel.rolle.isNullOrEmpty() && ziel.herkunft != null) {
                        Text(uebersetzt("%@ in %@", ziel.rolle, ziel.herkunft), style = TvStil.koerper.copy(fontWeight = FontWeight.Medium),
                             color = Stil.akzent, maxLines = 1, modifier = Modifier.padding(top = 6.dp))
                    }
                    s?.beschreibung?.let { Text(it, style = TvStil.koerper, color = Stil.schriftLeise, maxLines = 3, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 10.dp)) }
                }
            }
            if (s != null && s.titel.isNotEmpty()) TvStreifen(uebersetzt("Auf deinem Server")) {
                items(s.titel.size, key = { s.titel[it].id }) { i ->
                    val k = s.titel[i]
                    TvKachel(k.plakat, k.titel, k.unterzeile, modifier = if (i == 0) Modifier.focusRequester(fokus) else Modifier) { oeffnen(Ziel(k.id, k.titel, k.typ)) }
                }
            }
            if (anfragbar.isNotEmpty()) TvStreifen(uebersetzt("Kann angefragt werden")) {
                items(anfragbar, key = { it.schluessel }) { t ->
                    TvKachel(t.plakat, t.titel, Seerrmarke.kurzwort(t.stand) ?: t.jahr?.toString(), deckkraft = 0.45f) {
                        app.seerrTreffer[t.schluessel] = t
                        oeffnen(Ziel(t.schluessel, t.titel, "Seerrtitel"))
                    }
                }
            }
            if (s != null && s.titel.isEmpty() && anfragbar.isEmpty()) {
                Text(uebersetzt("Auf deinem Server gibt es sonst nichts mit %@.", ziel.name), style = TvStil.koerper, color = Stil.schriftLeise,
                     modifier = Modifier.padding(start = TvStil.randSeite, top = 30.dp))
            }
            Spacer(Modifier.height(40.dp))
        }
    }
}

/** Vorlage: `GenreView` — dasselbe Raster, nur der Genrename darueber, neueste zuerst. */
@Composable
fun TvGenre(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit) {
    var titel by remember(ziel.id) { mutableStateOf<List<Rasterkachel>?>(null) }
    LaunchedEffect(ziel.id) {
        titel = try {
            JSONArray(withContext(Dispatchers.IO) { app.kern.genre(ziel.id).await() }).let { a -> (0 until a.length()).map { rasterkachelLesen(a.getJSONObject(it)) } }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() }
    }
    val fokus = ersterFokus(titel != null)
    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        TvRaster(titel.orEmpty(), fokus = fokus, oeffnen = oeffnen, kopf = {
            Text(ziel.name, style = TvStil.titelGross, color = Stil.schrift, modifier = Modifier.padding(top = 50.dp, bottom = 16.dp))
        })
    }
}
