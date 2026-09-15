package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import coil3.compose.AsyncImage
import de.paulherter.swiftly.*
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/**
 * Vorlage: `Detailkopf` in `Sources/tvOS/DetailView.swift` — **derselbe Kopf fuer Film und Serie**:
 * Kopfauskunft, darunter die Knopfreihe. Die Kulisse liegt in jeder Seite selbst als fester Grund
 * (siehe `TvDetail`/`TvSerie`), weil sie dort ausserhalb der scrollenden Spalte steht. Eine
 * Funktion statt zweier fast gleicher Bloecke — sonst laufen die Seiten auseinander, wie es
 * `nachladen()` auf tvOS/Android schon einmal getan hat (CLAUDE.md).
 *
 * **Eigene `TvKopfauskunft` statt der geteilten `Kopfauskunft` aus `TvStart.kt`.** Die dort traegt
 * auch die Startseite, und die Metazeile (Bewertung, Freigabe, Direct-Play) sowie die feste
 * Beschreibungshoehe gehoeren nur einer Detailseite — die Startseite kennt das eine wie das
 * andere nicht. Zwei fast gleiche Kopfbloecke sind hier also richtig, keine Kopie.
 */
@Composable
fun TvDetailkopf(titel: String, jahrLaufzeit: String, bewertung: Double?, freigabe: String?, beschreibung: String?,
                 direktplay: Boolean, hinweis: String?, knoepfe: @Composable () -> Unit) {
    // **306,5 dp statt 177 — aus `Stil.heldenHoeheDetail` halbiert.** Vorher war die Zone knapp
    // bemessen und die Beschreibung wuchs mit ihrem Inhalt: eine kurze liess die Knopfreihe fast an
    // ihr kleben, tvOS reserviert dafuer immer drei Zeilen (`Stil.auskunftHoehe`).
    Column(Modifier.padding(start = TvStil.randSeite, top = 98.dp).height(306.5.dp)) {
        TvKopfauskunft(titel, jahrLaufzeit, bewertung, freigabe, beschreibung, direktplay, hinweis)
        Row(Modifier.padding(top = 18.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), content = { knoepfe() })
    }
}

/**
 * Vorlage: `Kopfauskunft` auf tvOS, **Fassung fuer die Detailseiten** — Titel, dann „Jahr ·
 * Laufzeit" mit Bewertung, Freigabe und Direct-Play-Beleg in einer Zeile (`Belegzeile`), dann die
 * Beschreibung. **Die Beschreibung reserviert immer drei Zeilen** (`Stil.beschreibungHoehe`,
 * halbiert): nur so steht die Knopfreihe darunter unabhaengig von der Textlaenge immer an
 * derselben Stelle, und eine kurze Beschreibung laesst sichtbar Luft statt die Knoepfe nach oben
 * zu ziehen — genau die fehlende Luft, die der Bildabgleich gegen tvOS zeigte.
 */
@Composable
private fun TvKopfauskunft(titel: String, jahrLaufzeit: String, bewertung: Double?, freigabe: String?,
                           beschreibung: String?, direktplay: Boolean, hinweis: String?) {
    Column(Modifier.width(500.dp)) {
        Text(titel, style = TvStil.auskunftTitel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.height(34.dp))
        Row(Modifier.padding(top = 7.dp).height(17.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (jahrLaufzeit.isNotEmpty()) {
                Text(jahrLaufzeit, style = TvStil.koerper, color = Stil.schrift.copy(alpha = 0.62f), maxLines = 1)
            }
            TvBelegzeile(direktplay, hinweis, bewertung, freigabe)
        }
        Text(beschreibung.orEmpty(), style = TvStil.koerper, color = Stil.schriftLeise, maxLines = 3, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.padding(top = 11.dp).height(63.dp))
    }
}

/**
 * Vorlage: `Belegzeile` in `Sources/tvOS/Stil.swift` — Bewertung mit Stern, Altersfreigabe als
 * umrandete Plakette, Direct-Play (oder der Grund dagegen) als getoente Marke. Masse halbiert.
 * Fehlt alles drei, nimmt die Zeile keinen Platz ein — der Aufrufer legt sie trotzdem an, damit die
 * feste Hoehe der Kopfzone nicht springt.
 */
@Composable
fun TvBelegzeile(direktplay: Boolean, hinweis: String?, bewertung: Double?, freigabe: String?) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        bewertung?.let {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Icon(Icons.Filled.Star, contentDescription = null, tint = Color.White.copy(alpha = 0.8f), modifier = Modifier.size(11.dp))
                Text(String.format(Locale.getDefault(), "%.1f", it), style = TextStyle(fontSize = 13.5.sp), color = Color.White.copy(alpha = 0.8f))
            }
        }
        freigabe?.takeIf { it.isNotBlank() }?.let { TvPlakette(it) }
        if (direktplay || hinweis != null) {
            val farbe = if (direktplay) Stil.akzent else Stil.warnung
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp),
                modifier = Modifier.clip(RoundedCornerShape(3.dp)).background(farbe.copy(alpha = 0.15f))
                    .padding(start = 8.dp, end = 10.dp, top = 4.dp, bottom = 4.dp)) {
                Icon(if (direktplay) Icons.Filled.Check else Icons.Filled.Warning, contentDescription = null,
                     tint = farbe, modifier = Modifier.size(12.dp))
                Text(if (direktplay) "Direct Play" else hinweis.orEmpty(),
                     style = TextStyle(fontSize = 13.5.sp, fontWeight = FontWeight.Medium), color = farbe)
            }
        }
    }
}

/** Vorlage: `Plakette.fern` — Rand statt Fuellung, Rundung 3, dieselbe Ecke wie die Direct-Play-Marke. */
@Composable
private fun TvPlakette(text: String) {
    Text(text, style = TextStyle(fontSize = 10.5.sp, fontWeight = FontWeight.SemiBold), color = Stil.schriftLeise,
         modifier = Modifier.border(1.dp, Stil.schriftLeise.copy(alpha = 0.3f), RoundedCornerShape(3.dp))
             .padding(horizontal = 6.dp, vertical = 2.dp))
}

/**
 * Vorlage: `Mehrknopf` + `Handlungstafel.unterDerKnopfreihe` auf tvOS — das Menue klappt **direkt
 * unter dem Knopf auf, links verankert, ohne Titelzeile**, Symbole links. Anders als `TvTafel`
 * (rechter Bildschirmrand, mit Titelzeile): die passt zur Handy-Vorlage, nicht zu Film- und
 * Serienseite auf tvOS. Deshalb hier ein eigenes, verankertes Menue statt `app.blatt`.
 *
 * Der Fokus bleibt im Menue (`focusGroup` mit gesperrtem Ausgang), bis es zugeht; die
 * Zurueck-Taste schliesst nur das Menue, nicht die Seite.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun TvMehrknopf(eintraege: List<Wahl>, symbole: Map<String, ImageVector> = emptyMap(), waehlen: (String) -> Unit) {
    var offen by remember { mutableStateOf(false) }
    Box {
        TvKnopf(null, Icons.Filled.MoreHoriz) { offen = !offen }
        if (offen) {
            BackHandler(onBack = { offen = false })
            val erste = remember { FocusRequester() }
            LaunchedEffect(Unit) { delay(30); runCatching { erste.requestFocus() } }
            // 44 dp unter dem Knopf — dieselbe Zahl wie die Staffelliste auf dem Telefon
            // (`Staffelkopf` in `SerienSeite.kt`), aus demselben Grund: knapp unter der eigenen Hoehe.
            Popup(offset = IntOffset(0, with(LocalDensity.current) { 44.dp.roundToPx() }),
                  onDismissRequest = { offen = false }, properties = PopupProperties(focusable = false)) {
                Column(Modifier.width(340.dp).clip(RoundedCornerShape(10.dp)).background(Stil.erhoeht)
                        .padding(vertical = 6.dp)
                        .focusProperties { exit = { FocusRequester.Cancel } }.focusGroup()) {
                    eintraege.forEachIndexed { i, e ->
                        TvZeile(e.text, symbole[e.wert], modifier = if (i == 0) Modifier.focusRequester(erste) else Modifier) {
                            offen = false
                            waehlen(e.wert)
                        }
                    }
                }
            }
        }
    }
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
 *
 * **Der Trailer steht vorn in den Extras**, nicht als sechste Pille — derselbe Grund wie auf
 * tvOS: fuenf beschriftete Knoepfe waren zu viel fuer eine Reihe. `Kern.lokalerTrailer` liefert
 * ihn getrennt von `titelUmfeld`, weil nicht jeder Titel einen hat.
 */
@Composable
fun TvDetail(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit) {
    var t by remember(ziel.id) { mutableStateOf(app.titelSpeicher[ziel.id]) }
    var aehnliche by remember(ziel.id) { mutableStateOf<List<Rasterkachel>>(emptyList()) }
    var extras by remember(ziel.id) { mutableStateOf<List<Extra>>(emptyList()) }
    val lauf = rememberCoroutineScope()
    val spielt = app.spiel.value != null

    suspend fun neuLaden() {
        try { t = titelLesen(withContext(Dispatchers.IO) { app.kern.titel(ziel.id).await() }).also { app.titelSpeicher[ziel.id] = it } }
        catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }
    LaunchedEffect(ziel.id, spielt) { if (!spielt) neuLaden() }
    LaunchedEffect(ziel.id) {
        try {
            val o = JSONObject(withContext(Dispatchers.IO) { app.kern.titelUmfeld(ziel.id).await() })
            aehnliche = o.feldListe("aehnliche") { rasterkachelLesen(it) }
            val basis = o.feldListe("extras") { Extra(it.getString("id"), it.getString("name"), it.feldText("bild"), it.feldText("laufzeit")) }
            // Der Trailer wohnt hier, nicht als sechste Pille — siehe Doc-Kommentar oben.
            val tr = JSONObject(withContext(Dispatchers.IO) { app.kern.lokalerTrailer(ziel.id).await() })
            val vorschau = if (tr.has("id")) Extra(tr.getString("id"), tr.getString("name"), tr.feldText("bild"), tr.feldText("laufzeit")) else null
            extras = listOfNotNull(vorschau) + basis
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }
    val haupt = ersterFokus()
    val titel = t
    val name = titel?.name ?: ziel.name

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        TvBildgrund(titel?.kopfbild)
        Kulisse(titel?.kopfbild, Modifier.align(Alignment.TopEnd))
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            TvDetailkopf(name, titel?.jahrLaufzeit.orEmpty(), titel?.bewertung, titel?.freigabe, titel?.beschreibung,
                         direktplay = titel?.planDa == true && titel.lossless,
                         hinweis = if (titel?.planDa == true && !titel.lossless) titel.methode else null) {
                TvKnopf(uebersetzt(if (titel?.fortsetzenAb != null) "Fortsetzen" else "Abspielen"), Icons.Filled.PlayArrow, Modifier.focusRequester(haupt)) {
                    if (titel?.planDa == true) app.spiel.value = Abspielwunsch(ziel.id, titel.fortsetzenAb)
                }
                if (titel?.fortsetzenAb != null) TvKnopf(null, Icons.Filled.Replay) { app.spiel.value = Abspielwunsch(ziel.id, null) }
                TvKnopf(null, if (titel?.gemerkt == true) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder) {
                    val an = !(titel?.gemerkt ?: false)
                    titel?.let { t = it.copy(gemerkt = an) }
                    lauf.launch { if (withContext(Dispatchers.IO) { app.kern.merken(ziel.id, an).await() }.isNotEmpty()) titel?.let { t = it } }
                }
                // **`TvMehrknopf` statt `app.blatt`** — auf tvOS klappt das Menue direkt unter dem
                // Knopf auf, nicht als Tafel am rechten Rand. Siehe Doc-Kommentar dort.
                val tt = titel
                if (tt != null) {
                    val gesehenJetzt = tt.gesehen
                    // `Titelhandlungen.fuerFilm`: „Gesehen" vorn (aus der Knopfreihe heraus,
                    // siehe `gesehenHandlung`), „Von vorn"/„Zuruecksetzen" nur mit Fortschritt.
                    val eintraege = buildList {
                        add(Wahl("gesehen", uebersetzt(if (gesehenJetzt) "Als ungesehen merken" else "Als gesehen merken")))
                        if (tt.planDa && tt.fortsetzenAb != null) {
                            add(Wahl("vonvorn", uebersetzt("Von vorn abspielen")))
                            add(Wahl("zuruecksetzen", uebersetzt("Fortschritt zurücksetzen")))
                        }
                        add(Wahl("metadaten", uebersetzt("Metadaten neu einlesen")))
                    }
                    TvMehrknopf(eintraege,
                        mapOf("gesehen" to Icons.Filled.CheckCircle, "vonvorn" to Icons.Filled.Replay,
                              "zuruecksetzen" to Icons.Filled.RestartAlt, "metadaten" to Icons.Filled.Refresh)) { wahl ->
                        lauf.launch {
                            when (wahl) {
                                "gesehen" -> if (withContext(Dispatchers.IO) { app.kern.gesehen(ziel.id, !gesehenJetzt).await() }.isEmpty()) titel.let { t = it.copy(gesehen = !gesehenJetzt) }
                                "vonvorn" -> app.spiel.value = Abspielwunsch(ziel.id, null)
                                "zuruecksetzen" -> if (withContext(Dispatchers.IO) { app.kern.gesehen(ziel.id, false).await() }.isEmpty()) neuLaden()
                                "metadaten" -> withContext(Dispatchers.IO) { app.kern.metadatenAuffrischen(ziel.id).await() }
                            }
                        }
                    }
                } else {
                    TvKnopf(null, Icons.Filled.MoreHoriz) {}
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

/** „24. Juni 1962" in der Sprache des Geraets — dieselbe Umrechnung wie `PersonSeite.langesDatum`. */
private fun tvLangesDatum(iso: String): String? =
    runCatching { LocalDate.parse(iso).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG)) }.getOrNull()

/**
 * Vorlage: `PersonView` auf tvOS — aufgebaut wie eine Detailseite: rundes Bild, Name, Geburt, Ort,
 * die Rolle im Akzent. Das Banner wechselt alle sechs Sekunden weich zwischen den Querbildern.
 * **„Es gibt sonst nichts" wartet auf Seerr** (`seerrFertig`), sonst blitzt die Meldung kurz auf,
 * bevor die Filmografie da ist — derselbe Fehler, den `PersonView.swift` mit `seerrFertig` behebt.
 */
@Composable
fun TvPerson(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit) {
    var stand by remember(ziel.id) { mutableStateOf(app.personenSpeicher[ziel.id]) }
    LaunchedEffect(ziel.id) {
        try { stand = personLesen(withContext(Dispatchers.IO) { app.kern.person(ziel.id).await() }).also { app.personenSpeicher[ziel.id] = it } }
        catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }
    val s = stand
    var anfragbar by remember(ziel.id) { mutableStateOf<List<Seerrkachel>?>(null) }
    val tmdb = s?.tmdb
    val seerrDa = app.seerrVerbunden.value
    LaunchedEffect(tmdb, seerrDa) {
        if (tmdb == null || !seerrDa) return@LaunchedEffect
        val eigene = s?.titel.orEmpty().mapTo(HashSet()) { it.titel.lowercase() }
        anfragbar = seerrkachelnLesen(withContext(Dispatchers.IO) { app.kern.seerrFilmografie(tmdb.toLong()).await() }).filter { it.titel.lowercase() !in eigene }
    }
    val seerrFertig = anfragbar != null || !seerrDa || (s != null && tmdb == null)
    val banner = s?.banner.orEmpty()
    var stelle by remember(ziel.id) { mutableIntStateOf(0) }
    LaunchedEffect(banner.size) { if (banner.size > 1) while (true) { delay(6000); stelle++ } }
    val fokus = ersterFokus(s != null)

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        // Vorlage: `PersonView` `.bildgrund(url: bannerJetzt)` — der Grund folgt dem Querbild.
        TvBildgrund(banner.getOrNull(if (banner.isEmpty()) 0 else stelle % banner.size))
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
                    // **Zwei Zeilen, wie auf tvOS** (`PersonView.block`) — dort stehen Geburtsdatum
                    // und -ort in einer eigenen `VStack`, nicht zusammengefasst mit „·".
                    val geburt = s?.geboren?.let(::tvLangesDatum)?.let { uebersetzt("Geboren %@", it) }
                    Column(Modifier.padding(top = 5.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                        Text(geburt.orEmpty(), style = TvStil.kachel, color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(s?.ort.orEmpty(), style = TvStil.kachel, color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    if (!ziel.rolle.isNullOrEmpty() && ziel.herkunft != null) {
                        Text(uebersetzt("%@ in %@", ziel.rolle, ziel.herkunft), style = TvStil.koerper.copy(fontWeight = FontWeight.Medium),
                             color = Stil.akzent, maxLines = 1, modifier = Modifier.padding(top = 6.dp))
                    }
                    s?.beschreibung?.let { Text(it, style = TvStil.koerper, color = Stil.schriftLeise, maxLines = 3, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 10.dp)) }
                }
            }
            // **Ohne Jahr, dafuer mit Marke** — wie `Titelstreifen` auf tvOS (`mitUnterzeile: false`,
            // `marke: Anzeigeregeln.kachelmarke(...)`). Die Marke steht schon im JSON, dieselbe
            // Regel wie im Bibliotheksraster; nur die Kachel hier zeigte sie bisher nicht an.
            if (s != null && s.titel.isNotEmpty()) TvStreifen(uebersetzt("Auf deinem Server")) {
                items(s.titel.size, key = { s.titel[it].id }) { i ->
                    val k = s.titel[i]
                    TvKachel(k.plakat, k.titel, null, marke = k.marke, markenzahl = k.markenzahl,
                             modifier = if (i == 0) Modifier.focusRequester(fokus) else Modifier) { oeffnen(Ziel(k.id, k.titel, k.typ)) }
                }
            }
            anfragbar?.takeIf { it.isNotEmpty() }?.let { liste ->
                TvStreifen(uebersetzt("Kann angefragt werden")) {
                    items(liste, key = { it.schluessel }) { t ->
                        TvKachel(t.plakat, t.titel, Seerrmarke.kurzwort(t.stand) ?: t.jahr?.toString(), deckkraft = 0.45f) {
                            app.seerrTreffer[t.schluessel] = t
                            oeffnen(Ziel(t.schluessel, t.titel, "Seerrtitel"))
                        }
                    }
                }
            }
            if (s != null && seerrFertig && s.titel.isEmpty() && anfragbar.orEmpty().isEmpty()) {
                Text(uebersetzt("Auf deinem Server gibt es sonst nichts mit %@.", ziel.name), style = TvStil.koerper, color = Stil.schriftLeise,
                     modifier = Modifier.padding(start = TvStil.randSeite, top = 30.dp))
            }
            Spacer(Modifier.height(40.dp))
        }
    }
}

/**
 * Vorlage: `GenreView` — dasselbe Raster wie die Bibliothek, nur der Genrename darueber statt
 * einer Chipreihe, neueste zuerst. Der Name kommt vom Server und wird nicht uebersetzt —
 * `Reihentitel(name:)`, deshalb `TvStil.reihe` und nicht `titelGross`.
 */
@Composable
fun TvGenre(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit) {
    var titel by remember(ziel.id) { mutableStateOf<List<Rasterkachel>?>(null) }
    LaunchedEffect(ziel.id) {
        titel = try {
            JSONArray(withContext(Dispatchers.IO) { app.kern.genre(ziel.id).await() }).let { a -> (0 until a.length()).map { rasterkachelLesen(a.getJSONObject(it)) } }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() }
    }
    val liste = titel
    val fokus = ersterFokus(liste != null)
    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        TvRaster(liste.orEmpty(), fokus = fokus, oeffnen = oeffnen, laedt = liste == null, kopf = {
            Column {
                Text(ziel.name, style = TvStil.reihe, color = Stil.schrift, maxLines = 1,
                     modifier = Modifier.padding(top = 48.dp, bottom = TvStil.titelAbstand))
                if (liste != null && liste.isEmpty()) {
                    TvLeer(uebersetzt("Nichts in diesem Genre"),
                           uebersetzt("Auf deinem Server steht gerade kein Film und keine Serie darin."),
                           symbol = Icons.Filled.Tag)
                }
            }
        })
    }
}
