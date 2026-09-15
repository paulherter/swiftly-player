package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
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
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
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
 * **Ruft die geteilte `Kopfauskunft` aus `TvStart.kt` auf, statt einer eigenen Fassung.** Hier
 * stand einmal eine zweite, fast gleiche Kopie — mit eigener Zeilenfarbe fuer die Beschreibung
 * (`schriftLeise` statt `schrift.copy(alpha=0.62)`) und ohne Bewertung/Freigabe auf der Startseite.
 * Genau die Art Abweichung, an der `nachladen()` und `Titelangaben` schon einmal auseinandergelaufen
 * sind — deshalb jetzt eine Quelle: Bewertung und Freigabe stehen in `Kopfauskunft` selbst, nur der
 * Direct-Play-Beleg kommt hier ueber `schluss`.
 *
 * `knopfAlpha` blendet die Knopfreihe ein, waehrend Titel/Angaben/Beschreibung/Kulisse sofort
 * stehen — siehe `eingeblendet` in `TvDetail`/`TvSerie`, dieselbe Regel wie tvOS' `DetailView`:
 * „Instant bleibt, was schon auf der Startseite stand […]. Ueberblendet wird nur, was neu
 * dazukommt."
 */
@Composable
fun TvDetailkopf(titel: String, jahrLaufzeit: String, bewertung: Double?, freigabe: String?, beschreibung: String?,
                 direktplay: Boolean, hinweis: String?, knopfAlpha: Float = 1f, knoepfe: @Composable () -> Unit) {
    // **306,5 dp statt 177 — aus `Stil.heldenHoeheDetail` halbiert.** Vorher war die Zone knapp
    // bemessen und die Beschreibung wuchs mit ihrem Inhalt: eine kurze liess die Knopfreihe fast an
    // ihr kleben, tvOS reserviert dafuer immer drei Zeilen (`Stil.auskunftHoehe`).
    //
    // **Die 306,5 dp sind die ganze Zone, nicht zusaetzlich zum oberen Abstand.** Auf tvOS traegt
    // `.frame(height: heldenHoeheDetail)` den ganzen `rumpf`-Stapel, und `block` liegt darin mit
    // `.padding(.top, 196)` — der Abstand steht **innerhalb** der festen Hoehe. Hier lagen Innenabstand
    // und Hoehe bisher auf demselben `Column`: `padding(top = 98.dp)` schob die Spalte 98 dp nach
    // unten, `height(306.5.dp)` gab ihr danach nochmal 306,5 dp — macht 404,5 dp fuer eine Zone, die
    // nur 306,5 dp gross sein soll. Der Rest zwischen Knopfreihe und „Episodes" war genau dieser
    // verdoppelte Abstand. Jetzt traegt eine `Box` die feste Gesamthoehe, der Innenabstand liegt am
    // `Column` darin — wie auf tvOS am `block`, nicht am `rumpf`.
    //
    // **`zweitzeile = null`** — die Detailseiten sehen sie nie: eine Folge bekommt keine eigene
    // Seite, jeder Weg zu ihr fuehrt auf die Serienseite (A8). Siehe `Kopfauskunft`.
    Box(Modifier.fillMaxWidth().height(306.5.dp)) {
        Column(Modifier.padding(start = TvStil.randSeite, top = 98.dp)) {
            Kopfauskunft(titel, null, jahrLaufzeit, bewertung, freigabe, beschreibung) {
                TvBelegzeile(direktplay, hinweis, bewertung = null, freigabe = null)
            }
            Row(Modifier.padding(top = 18.dp).alpha(knopfAlpha), horizontalArrangement = Arrangement.spacedBy(12.dp), content = { knoepfe() })
        }
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
 *
 * **Fokus zurueck an den „…"-Knopf beim Schliessen** — Auswahl wie Zurueck, dasselbe Mittel wie
 * `TvTafel` in `TvHaupt.kt`: `Fokusmerker`/`LocalInnerhalbTafel` aus `TvStil.kt`. Ohne das landete
 * der Fokus nach dem Schliessen zufaellig irgendwo auf der Seite. `warOffen` haelt fest, ob das Menue
 * wirklich offen **war** — ohne die Wache liefe der Ruecknahme-Aufruf schon beim ersten Aufbau der
 * Seite (`offen` startet `false`) und koennte den `Fokusmerker` eines ganz anderen, gerade erst
 * geoeffneten Ausloesers auf dieser Seite verwerfen.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun TvMehrknopf(eintraege: List<Wahl>, symbole: Map<String, ImageVector> = emptyMap(), waehlen: (String) -> Unit) {
    var offen by remember { mutableStateOf(false) }
    // **Erst den Fokus zurueck an den „…"-Knopf, dann das Menue schliessen** — umgekehrt fiele der
    // Fokus beim Entfernen der fokussierten Zeile kurz auf den ersten fokussierbaren Knoten, und ein
    // spaeteres Zurueckholen waere als Sprung zu sehen. Der Knopf traegt dafuer einen eigenen
    // `FocusRequester`, kein globaler Merker noetig. `freigabe` oeffnet den gesperrten Ausgang
    // (`exit = Cancel` sperrt sonst auch das programmatische `requestFocus`).
    val knopf = remember { FocusRequester() }
    val freigabe = remember { booleanArrayOf(false) }
    fun schliessen() {
        freigabe[0] = true
        runCatching { knopf.requestFocus() }
        offen = false
    }
    Box {
        TvKnopf(null, Icons.Filled.MoreHoriz, modifier = Modifier.focusRequester(knopf)) {
            if (offen) schliessen() else { freigabe[0] = false; offen = true }
        }
        if (offen) {
            BackHandler(onBack = { schliessen() })
            val erste = remember { FocusRequester() }
            LaunchedEffect(Unit) { delay(30); runCatching { erste.requestFocus() } }
            // 44 dp unter dem Knopf — dieselbe Zahl wie die Staffelliste auf dem Telefon
            // (`Staffelkopf` in `SerienSeite.kt`), aus demselben Grund: knapp unter der eigenen Hoehe.
            Popup(offset = IntOffset(0, with(LocalDensity.current) { 44.dp.roundToPx() }),
                  onDismissRequest = { schliessen() }, properties = PopupProperties(focusable = false)) {
                // Innerhalb der Tafel: eine angeklickte Zeile darf sich nicht selbst als „Ausloeser"
                // bei `Fokusmerker` eintragen, sonst zeigte das naechste Schliessen auf die zuletzt
                // gewaehlte Zeile statt zurueck auf den „…"-Knopf.
                CompositionLocalProvider(LocalInnerhalbTafel provides true) {
                    Column(Modifier.width(340.dp).clip(RoundedCornerShape(10.dp)).background(Stil.erhoeht)
                            .padding(vertical = 6.dp)
                            .focusProperties { exit = { if (freigabe[0]) FocusRequester.Default else FocusRequester.Cancel } }.focusGroup()) {
                        eintraege.forEachIndexed { i, e ->
                            TvZeile(e.text, symbole[e.wert], modifier = if (i == 0) Modifier.focusRequester(erste) else Modifier) {
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

/**
 * Ein Streifen mit Titel — `reihenabschnitt` und `streifen` aus `Titelreihen.swift`.
 *
 * **`TvReihenBringIntoView` ausdruecklich wieder eingesetzt**, siehe `TvKeinSenkrechtesBringIntoView`
 * in `TvStart.kt`: die Seiten, die diesen Streifen einbetten (`TvDetail`, `TvSerie`, `TvPerson`,
 * `TvSeerrDetailSeite`), schalten das Bring-into-View ihres `verticalScroll` auf
 * `TvAbschnittsweisesBringIntoView` um, damit ein sichtbarer Fokuswechsel die Seite nicht mehr
 * zappelig zurechtrueckt. Ohne diese Zeile wuerde die `LazyRow` dieselbe gedaempfte Spec erben und
 * beim Wandern nicht mehr zur naechsten Kachel scrollen.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TvStreifen(titel: String, modifier: Modifier = Modifier, inhalt: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    Column(modifier.padding(top = TvStil.reihenAbstand - TvStil.reihenLuft)) {
        TvReihentitel(titel)
        CompositionLocalProvider(LocalBringIntoViewSpec provides TvReihenBringIntoView) {
            LazyRow(contentPadding = PaddingValues(horizontal = TvStil.randSeite, vertical = TvStil.reihenLuft),
                    horizontalArrangement = Arrangement.spacedBy(TvStil.kachelAbstand), content = inhalt)
        }
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
@OptIn(ExperimentalFoundationApi::class)
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

    // Vorlage: `DetailView.eingeblendet` auf tvOS — **beim Erscheinen blendet ein, nicht beim
    // Laden**, und zwar jedes Mal, ob die Daten (Zwischenspeicher) schon dastehen oder nicht.
    // Kulisse, Titel, Angabenzeile und Beschreibung stehen sofort (`TvDetailkopf`/`Kopfauskunft`
    // sehen `eingeblendet` gar nicht) — nur die Knopfreihe und die Reihen darunter sind neu
    // gegenueber der Startseite und blenden ein. Ohne das sprang beim Oeffnen einer Serie/eines
    // Films alles auf einmal hart hin, statt dass nur der Zusatz kommt.
    var eingeblendet by remember(ziel.id) { mutableStateOf(false) }
    val einblendAlpha by animateFloatAsState(if (eingeblendet) 1f else 0f,
        tween(TvStil.einblendenDauer, easing = TvStil.einblendenKurve), label = "eingeblendet")
    LaunchedEffect(ziel.id) { eingeblendet = true }

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        TvBildgrund(titel?.kopfbild)
        Kulisse(titel?.kopfbild, Modifier.align(Alignment.TopEnd))
        CompositionLocalProvider(LocalBringIntoViewSpec provides TvAbschnittsweisesBringIntoView) {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                TvDetailkopf(name, titel?.jahrLaufzeit.orEmpty(), titel?.bewertung, titel?.freigabe, titel?.beschreibung,
                             direktplay = titel?.planDa == true && titel.lossless,
                             hinweis = if (titel?.planDa == true && !titel.lossless) titel.methode else null,
                             knopfAlpha = einblendAlpha) {
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
                if (aehnliche.isNotEmpty()) TvStreifen(uebersetzt("Ähnliche Filme"), Modifier.alpha(einblendAlpha)) {
                    items(aehnliche, key = { it.id }) { k -> TvKachel(k.plakat, k.titel, k.unterzeile) { oeffnen(Ziel(k.id, k.titel, k.typ)) } }
                }
                if (extras.isNotEmpty()) TvStreifen(uebersetzt("Extras"), Modifier.alpha(einblendAlpha)) {
                    items(extras, key = { it.id }) { x -> TvKachel(x.bild, x.name, x.laufzeit, quer = true) { app.spiel.value = Abspielwunsch(x.id, null) } }
                }
                val leute = titel?.darsteller.orEmpty()
                if (leute.isNotEmpty()) TvStreifen(uebersetzt("Besetzung"), Modifier.alpha(einblendAlpha)) {
                    items(leute, key = { it.id }) { p -> TvBesetzung(p) { oeffnen(Ziel(p.id, p.name, "Person", p.rolle, name)) } }
                }
                Spacer(Modifier.height(40.dp))
            }
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
@OptIn(ExperimentalFoundationApi::class)
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
        CompositionLocalProvider(LocalBringIntoViewSpec provides TvAbschnittsweisesBringIntoView) {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                // **306,5 dp, dieselbe Gesamthoehe wie `TvDetailkopf`** (`Stil.heldenHoeheDetail`
                // halbiert) — tvOS baut den Kopf der Personenseite genau wie den von Film und Serie:
                // `.padding(.top, 140 + kopfversatzDetail)` **innerhalb** von `.frame(height:
                // heldenHoeheDetail)` (siehe `PersonView.swift`). Vorher trug dieselbe `Row` sowohl den
                // oberen Abstand (98 dp) als auch eine eigene Hoehe (`heldenHoehe + 20 - 98` = 177 dp) —
                // macht zusammen 275 dp statt der 306,5 dp, die tvOS fuer diesen Kopf vorsieht, und der
                // Abstand lag ausserhalb der festen Zone statt darin. Jetzt traegt die `Box` die
                // Gesamthoehe, der Innenabstand liegt an der `Row` darin.
                Box(Modifier.fillMaxWidth().height(306.5.dp)) {
                    Row(Modifier.padding(start = TvStil.randSeite, top = 98.dp),
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
