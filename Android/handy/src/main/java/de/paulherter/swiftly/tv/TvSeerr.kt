package de.paulherter.swiftly.tv

import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.*
import de.paulherter.swiftly.Seerrkachel as SeerrTreffer
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.alsJson
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.Locale

/**
 * Vorlage: `Seerrkachel` in `Sources/tvOS/SeerrView.swift` — **blass, und das ist die ganze
 * Auskunft**: wer ueber das Raster fokussiert, sieht ohne ein Wort zu lesen, dass hier nichts
 * abzuspielen ist. Oeffentlich, weil `TvSuche` (`TvSeiten.kt`, BEREICHE) dieselbe Kachel fuer
 * ihre Seerr-Treffer braucht wie die „Ähnliche Titel"-Reihe hier — eine Form statt zweier, die
 * auseinanderlaufen.
 */
@Composable
fun Seerrkachel(treffer: SeerrTreffer, modifier: Modifier = Modifier, tun: () -> Unit) {
    Column(modifier.width(TvStil.posterBreite)) {
        Fokusflaeche(tun = tun) {
            Box(Modifier.size(TvStil.posterBreite, TvStil.posterHoehe).clip(RoundedCornerShape(TvStil.eckeKachel)).background(Stil.flaeche)) {
                AsyncImage(model = treffer.plakat, contentDescription = treffer.titel, contentScale = ContentScale.Crop,
                           modifier = Modifier.fillMaxSize().alpha(0.45f))
                if (treffer.stand != 5) {
                    val kurz = Seerrmarke.kurzwort(treffer.stand)
                    Row(Modifier.align(Alignment.BottomStart).padding(6.dp).clip(CircleShape).background(Seerrmarke.farbe(treffer.stand))
                            .padding(horizontal = if (kurz != null) 8.dp else 6.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Symbol(Seerrmarke.symbol(treffer.stand), 10.dp, farbe = Stil.grund, staerke = Staerke.Halbfett)
                        kurz?.let { Text(it, style = TvStil.plakette.copy(letterSpacing = 0.sp), color = Stil.grund) }
                    }
                }
            }
        }
        Text(treffer.titel, style = TvStil.kachel, color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 7.dp))
        Text(listOfNotNull(treffer.jahr?.toString(), uebersetzt(if (treffer.istSerie) "Serie" else "Film")).joinToString(" · "),
             style = TvStil.klein, color = Stil.schriftSehrLeise, maxLines = 1, modifier = Modifier.padding(top = 1.dp))
    }
}

/**
 * Vorlage: `SeerrAnbindenView` auf tvOS — Adresse, Benutzername, Passwort; Seerr fragt Jellyfin
 * selbst, ob es stimmt. Als eigene Seite statt einer Zeile, weil drei Felder mehr Platz brauchen,
 * als eine Einstellungszeile hat — genauso auf tvOS begruendet. Dieselben Kern-Funktionen wie
 * `SeerrEinstellungenSeite` auf dem Telefon (`seerrVerbinden`, `seerrGilt`), keine eigene Logik.
 */
@Composable
fun TvSeerrSeite(app: SwiftlyAnwendung, zurueck: () -> Unit) {
    var adresse by remember { mutableStateOf("") }
    var benutzer by remember { mutableStateOf(app.benutzername().takeIf { it != "?" }.orEmpty()) }
    var passwort by remember { mutableStateOf("") }
    var verbindet by remember { mutableStateOf(false) }
    var fehler by remember { mutableStateOf<String?>(null) }
    var traegt by remember { mutableStateOf<Boolean?>(null) }
    /** „Erweitert" — eigene Header fuer einen Dienst vor Seerr; sie liegen danach im Zugang. */
    val koepfe = de.paulherter.swiftly.rememberKopfzeilen()
    val lauf = rememberCoroutineScope()
    val verbunden = app.seerrVerbunden.value
    LaunchedEffect(verbunden) {
        traegt = if (verbunden) withContext(Dispatchers.IO) { app.kern.seerrGilt().await() } else null
    }
    fun verbinden() {
        if (verbindet || adresse.isBlank() || benutzer.isBlank() || passwort.isBlank()) return
        verbindet = true; fehler = null
        lauf.launch {
            try {
                app.seerrMerken(withContext(Dispatchers.IO) { app.kern.seerrVerbinden(adresse, benutzer, passwort, koepfe.alsJson()).await() })
                passwort = ""
            } catch (x: CancellationException) { throw x } catch (x: Exception) { fehler = fehlertext(app, x) }
            verbindet = false
        }
    }
    BackHandler(onBack = zurueck)
    val feld = ersterFokus()

    Box(Modifier.fillMaxSize().background(Stil.grund), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.widthIn(max = 480.dp)) {
            Text("Seerr", style = TvStil.titelGross, color = Stil.schrift)
            Text(uebersetzt("Jellyseerr oder Overseerr. Dann zeigt die Suche auch Titel, die noch nicht auf deinem Server sind, und du kannst sie anfragen."),
                 style = TvStil.koerper, color = Stil.schriftLeise, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 14.dp))
            if (verbunden) {
                Text(app.seerrAdresse().orEmpty(), style = TvStil.koerper, color = Stil.schrift, modifier = Modifier.padding(top = 26.dp))
                Text(uebersetzt(if (traegt == true) "Sitzung aktiv" else "Sitzung abgelaufen"),
                     style = TvStil.klein, color = if (traegt == true) Stil.akzent else Stil.warnung, modifier = Modifier.padding(top = 6.dp))
                TvKnopf(uebersetzt("Verbindung trennen"), modifier = Modifier.padding(top = 20.dp).focusRequester(feld)) { app.seerrTrennen(); passwort = "" }
            } else {
                Column(Modifier.padding(top = 26.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    TvFeld(adresse, { adresse = it }, "seerr.example.de", Modifier.fillMaxWidth().focusRequester(feld))
                    TvFeld(benutzer, { benutzer = it }, uebersetzt("Benutzername"), Modifier.fillMaxWidth())
                    TvFeld(passwort, { passwort = it }, uebersetzt("Passwort"), Modifier.fillMaxWidth(),
                           geheim = true, imeAction = ImeAction.Done, tastaturAktion = { verbinden() })
                    TvErweitert(koepfe)
                }
                if (adresse.isNotBlank() && benutzer.isNotBlank() && passwort.isNotBlank()) {
                    TvKnopf(uebersetzt(if (verbindet) "Verbinde…" else "Verbinden"), modifier = Modifier.padding(top = 18.dp)) { verbinden() }
                }
                fehler?.let {
                    Text(it, style = TvStil.klein, color = Stil.warnung, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 12.dp))
                }
                Text(uebersetzt("Swiftly speichert dein Passwort nicht, nur die Anmeldung bei Seerr."),
                     style = TvStil.klein, color = Stil.schriftSehrLeise, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 14.dp))
            }
        }
    }
}

/**
 * Vorlage: `SeerrDetailView` auf tvOS — **derselbe Aufbau wie `TvDetail`** (`TvSeiten.kt`), nur
 * dass der Hauptknopf anfragt statt abspielt. Die Staffelwahl laeuft ueber `app.blatt` mit
 * Mehrfachauswahl, genau wie `staffelblatt()` in `SeerrDetailSeite` auf dem Telefon — derselbe
 * Baustein wie jede andere Tafel auf dem Fernseher, keine eigene Staffeltafel wie auf tvOS.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TvSeerrDetailSeite(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    val k = app.seerrTreffer[ziel.id] ?: run { LaunchedEffect(Unit) { zurueck() }; return }
    var detail by remember(ziel.id) { mutableStateOf<JSONObject?>(null) }
    var stand by remember(ziel.id) { mutableIntStateOf(k.stand) }
    var anfragbar by remember(ziel.id) { mutableStateOf(k.anfragbar) }
    var angefragt by remember(ziel.id) { mutableStateOf(false) }
    var bestaetigt by remember { mutableStateOf(false) }
    var laeuft by remember { mutableStateOf(false) }
    // Vorlage: `SeerrDetailView.fehler` auf tvOS — dort steht der Grund neben dem Knopf, hier ueber
    // `TvHinweisstreifen` wie am Handy; vorher verschluckte `anfragen()` den Grund ganz.
    var meldung by remember { mutableStateOf<String?>(null) }
    val lauf = rememberCoroutineScope()
    LaunchedEffect(ziel.id) {
        detail = runCatching { JSONObject(withContext(Dispatchers.IO) { app.kern.seerrDetail(k.art, k.id.toLong()).await() }) }.getOrNull()
    }
    // Vorlage: `SeerrView` — kein 5-Sekunden-Zeitgeber. Zurueckgesetzt wird nur ueber Knopfdruck,
    // Erfolg (`anfragen`) oder das Verlassen der Seite (eigener `remember`, faellt beim Verlassen weg).

    fun anfragen(staffeln: List<Int>) {
        if (k.istSerie && staffeln.isEmpty()) return
        laeuft = true
        lauf.launch {
            val grund = withContext(Dispatchers.IO) { app.kern.seerrAnfragen(k.art, k.id.toLong(), staffeln.joinToString(",")).await() }
            if (grund.isEmpty()) { angefragt = true; stand = 2; anfragbar = false } else meldung = fehlertext(grund)
            laeuft = false; bestaetigt = false
        }
    }
    fun staffelblatt() {
        val roh = detail?.optJSONArray("staffeln") ?: return
        val liste = (0 until roh.length()).map { roh.getJSONObject(it) }
        app.blatt.value = Blattwunsch(uebersetzt("Welche Staffeln?"),
            liste.map { o ->
                val folgen = o.getInt("folgen")
                Wahl(o.getInt("nummer").toString(), uebersetzt("Staffel %lld", o.getInt("nummer")) + if (folgen > 0) " · " + uebersetzt("%lld Folgen", folgen) else "")
            }, null, mehrfach = emptySet(),
            gesperrt = liste.filter { !it.optBoolean("anfragbar") }
                .associate { it.getInt("nummer").toString() to uebersetzt(if (it.getInt("stand") == 5) "vorhanden" else "unterwegs") },
            abschlussText = { n -> if (n == 0) uebersetzt("Staffel wählen") else uebersetzt("%lld anfragen", n) },
            abschluss = { menge -> anfragen(menge.map { it.toInt() }.sorted()) }) {}
    }

    val d = detail
    val nebenzeile = listOfNotNull(
        k.jahr?.toString(),
        if (k.istSerie) d?.optJSONArray("staffeln")?.length()?.takeIf { it > 0 }?.let { n -> if (n == 1) uebersetzt("1 Staffel") else uebersetzt("%lld Staffeln", n) }
        else d?.feldZahl("laufzeit")?.toInt()?.takeIf { it > 0 }?.let { uebersetzt("%lld Min.", it) },
        d?.feldTexte("genres")?.takeIf { it.isNotEmpty() }?.joinToString(", "),
    ).joinToString(" · ").ifEmpty { uebersetzt(if (k.istSerie) "Serie" else "Film") }
    val leute = d?.feldListe("besetzung") { Mitwirkender(it.getString("id"), it.getString("name"), it.feldText("rolle"), it.feldText("bild")) }.orEmpty()
    val aehnliche = d?.feldListe("aehnliches") { seerrkachelLesen(it) }.orEmpty()
    val haupt = ersterFokus()

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        TvBildgrund(k.kulisse)
        Kulisse(k.kulisse, Modifier.align(Alignment.TopEnd))
        // Abschnittsweises Scrollen wie `TvDetail`, siehe `TvAbschnittsseite` in `TvStart.kt`.
        // Ohne Anfrageknopf ist der Kopf nicht fokussierbar — dann haelt der erste Abschnitt ihn
        // so weit wie moeglich im Bild (`Kopfnah`).
        val ersteArt = if (anfragbar && !angefragt) TvAbschnittsart.Buendig else TvAbschnittsart.Kopfnah
        TvAbschnittsseite { a ->
                // **Derselbe Kopf wie `TvDetailkopf`: feste Zone 306,5 dp, Block innen ab 98 dp.**
                // Vorlage: `SeerrDetailView.kopf` — `.frame(height: heldenHoeheDetail)`, Block bei
                // 140 + kopfversatzDetail. Und: „Der Stand steht in der Angabenzeile statt in einer
                // eigenen darunter; so bleibt der Knopf auf der Hoehe, auf der er auf jeder anderen
                // Seite steht." Vorher stand er in einer eigenen Zeile unter einer 177-dp-Spalte:
                // 132,5 Kopfauskunft + 32 Standzeile + 56 Knopfreihe = 220,5 dp — die Knopfreihe
                // ragte gut 40 dp in den Besetzungsstreifen.
                Box(Modifier.tvAbschnitt(a, "kopf", TvAbschnittsart.Kopf).fillMaxWidth().height(306.5.dp)) {
                Column(Modifier.padding(start = TvStil.randSeite, top = 98.dp)) {
                    Kopfauskunft(k.titel, null, nebenzeile, null, null, d?.feldText("beschreibung")) {
                        // Stand und Bewertung in derselben Huelle wie Direct Play (Vorlage 2a24f67a).
                        // 0 heisst bei TMDB „keine Bewertung", nicht null Sterne.
                        TvBelegzeile(direktplay = false, hinweis = null,
                                     bewertung = d?.feldZahl("bewertung")?.takeIf { it > 0 }, freigabe = null,
                                     eigen = Triple(Seerrmarke.symbol(stand), Seerrmarke.wort(stand), Seerrmarke.farbe(stand)))
                    }
                    Row(Modifier.padding(top = 18.dp)) {
                        when {
                            angefragt -> Text(uebersetzt("Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."), style = TvStil.koerper, color = Stil.schriftLeise)
                            anfragbar -> TvKnopf(uebersetzt(when { laeuft -> "Wird angefragt…"; bestaetigt -> "Wirklich anfragen?"; else -> "Anfragen" }),
                                    Zeichen.Plus, Modifier.focusRequester(haupt)) {
                                when { k.istSerie -> staffelblatt(); bestaetigt -> anfragen(emptyList()); else -> bestaetigt = true }
                            }
                            else -> Text(Seerrmarke.hinweis(stand), style = TvStil.koerper, color = Stil.schriftLeise)
                        }
                    }
                }
                }
                if (leute.isNotEmpty()) TvStreifen(uebersetzt("Besetzung"), Modifier.tvAbschnitt(a, "besetzung", ersteArt)) {
                    items(leute, key = { it.id }) { p -> TvBesetzung(p) {} }
                }
                if (aehnliche.isNotEmpty()) TvStreifen(uebersetzt("Ähnliche Titel"),
                        Modifier.tvAbschnitt(a, "aehnliche", if (leute.isEmpty()) ersteArt else TvAbschnittsart.Buendig)) {
                    items(aehnliche, key = { it.schluessel }) { t ->
                        Seerrkachel(t) { app.seerrTreffer[t.schluessel] = t; oeffnen(Ziel(t.schluessel, t.titel, "Seerrtitel")) }
                    }
                }
                Spacer(Modifier.height(40.dp))
        }
        meldung?.let { text ->
            TvHinweisstreifen(text, Modifier.align(Alignment.TopCenter).padding(top = 74.dp)) { meldung = null }
        }
    }
}
