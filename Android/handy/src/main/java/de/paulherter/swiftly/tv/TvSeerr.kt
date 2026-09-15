package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Star
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
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
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
                        Icon(Seerrmarke.symbol(treffer.stand), contentDescription = null, tint = Stil.grund, modifier = Modifier.size(12.dp))
                        kurz?.let { Text(it, style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold), color = Stil.grund) }
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
                app.seerrMerken(withContext(Dispatchers.IO) { app.kern.seerrVerbinden(adresse, benutzer, passwort).await() })
                passwort = ""
            } catch (x: CancellationException) { throw x } catch (x: Exception) { fehler = x.message ?: x.toString() }
            verbindet = false
        }
    }
    BackHandler(onBack = zurueck)
    val feld = ersterFokus()

    Box(Modifier.fillMaxSize().background(Stil.grund), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.widthIn(max = 480.dp)) {
            Text("Seerr", style = TvStil.titelGross, color = Stil.schrift)
            Text(uebersetzt("Jellyseerr oder Overseerr. Damit findest du in der Suche auch, was noch nicht auf deinem Server liegt — und kannst es anfragen."),
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
                }
                if (adresse.isNotBlank() && benutzer.isNotBlank() && passwort.isNotBlank()) {
                    TvKnopf(uebersetzt(if (verbindet) "Verbinde…" else "Verbinden"), modifier = Modifier.padding(top = 18.dp)) { verbinden() }
                }
                fehler?.let {
                    Text(it, style = TvStil.klein, color = Stil.warnung, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 12.dp))
                }
                Text(uebersetzt("Dein Passwort wird nicht gespeichert — nur die Sitzung, die Seerr dafür ausstellt."),
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
@Composable
fun TvSeerrDetailSeite(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    val k = app.seerrTreffer[ziel.id] ?: run { LaunchedEffect(Unit) { zurueck() }; return }
    var detail by remember(ziel.id) { mutableStateOf<JSONObject?>(null) }
    var stand by remember(ziel.id) { mutableIntStateOf(k.stand) }
    var anfragbar by remember(ziel.id) { mutableStateOf(k.anfragbar) }
    var angefragt by remember(ziel.id) { mutableStateOf(false) }
    var bestaetigt by remember { mutableStateOf(false) }
    var laeuft by remember { mutableStateOf(false) }
    val lauf = rememberCoroutineScope()
    LaunchedEffect(ziel.id) {
        detail = runCatching { JSONObject(withContext(Dispatchers.IO) { app.kern.seerrDetail(k.art, k.id.toLong()).await() }) }.getOrNull()
    }
    LaunchedEffect(bestaetigt) { if (bestaetigt) { delay(5000); bestaetigt = false } }

    fun anfragen(staffeln: List<Int>) {
        if (k.istSerie && staffeln.isEmpty()) return
        laeuft = true
        lauf.launch {
            val grund = withContext(Dispatchers.IO) { app.kern.seerrAnfragen(k.art, k.id.toLong(), staffeln.joinToString(",")).await() }
            if (grund.isEmpty()) { angefragt = true; stand = 2; anfragbar = false }
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
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Column(Modifier.padding(start = TvStil.randSeite, top = 98.dp).height(TvStil.heldenHoehe + 20.dp - 98.dp)) {
                Kopfauskunft(k.titel, nebenzeile, d?.feldText("beschreibung"))
                Row(Modifier.padding(top = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    val farbe = Seerrmarke.farbe(stand)
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Seerrmarke.symbol(stand), contentDescription = null, tint = farbe, modifier = Modifier.size(15.dp))
                        Text(Seerrmarke.wort(stand), style = TvStil.koerper.copy(fontWeight = FontWeight.Medium), color = farbe)
                    }
                    // 0 heisst bei TMDB „keine Bewertung", nicht null Sterne.
                    d?.feldZahl("bewertung")?.takeIf { it > 0 }?.let { b ->
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            Icon(Icons.Filled.Star, contentDescription = null, tint = Stil.schrift.copy(alpha = 0.8f), modifier = Modifier.size(14.dp))
                            Text(String.format(Locale.getDefault(), "%.1f", b), style = TvStil.koerper, color = Stil.schrift.copy(alpha = 0.8f))
                        }
                    }
                }
                Row(Modifier.padding(top = 18.dp)) {
                    when {
                        angefragt -> Text(uebersetzt("Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."), style = TvStil.koerper, color = Stil.schriftLeise)
                        anfragbar -> TvKnopf(uebersetzt(when { laeuft -> "Wird angefragt…"; bestaetigt -> "Wirklich anfragen?"; else -> "Anfragen" }),
                                Icons.Filled.Add, Modifier.focusRequester(haupt)) {
                            when { k.istSerie -> staffelblatt(); bestaetigt -> anfragen(emptyList()); else -> bestaetigt = true }
                        }
                        else -> Text(Seerrmarke.hinweis(stand), style = TvStil.koerper, color = Stil.schriftLeise)
                    }
                }
            }
            if (leute.isNotEmpty()) TvStreifen(uebersetzt("Besetzung")) {
                items(leute, key = { it.id }) { p -> TvBesetzung(p) {} }
            }
            if (aehnliche.isNotEmpty()) TvStreifen(uebersetzt("Ähnliche Titel")) {
                items(aehnliche, key = { it.schluessel }) { t ->
                    Seerrkachel(t) { app.seerrTreffer[t.schluessel] = t; oeffnen(Ziel(t.schluessel, t.titel, "Seerrtitel")) }
                }
            }
            Spacer(Modifier.height(40.dp))
        }
    }
}
