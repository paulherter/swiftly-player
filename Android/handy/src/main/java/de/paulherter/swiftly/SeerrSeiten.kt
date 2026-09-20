package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.AddCircleOutline
import androidx.compose.material.icons.outlined.ArrowCircleDown
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.gemeinsam.Eingabefeld
import de.paulherter.swiftly.gemeinsam.Hauptknopf
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
import java.util.Locale

/** Ein Treffer bei Seerr — `stand` ist Seerrs eigene Zahl, `anfragbar` die Regel aus dem Paket. */
data class Seerrkachel(val id: Int, val art: String, val titel: String, val jahr: Int?, val plakat: String?,
                       val kulisse: String?, val stand: Int, val anfragbar: Boolean) {
    val istSerie: Boolean get() = art == "tv"
    val schluessel: String get() = "$art:$id"
}

fun seerrkachelLesen(o: JSONObject) = Seerrkachel(o.getInt("id"), o.getString("art"), o.getString("titel"),
    if (o.isNull("jahr")) null else o.getInt("jahr"), o.feldText("plakat"), o.feldText("kulisse"), o.getInt("stand"), o.optBoolean("anfragbar"))

fun seerrkachelnLesen(json: String): List<Seerrkachel> =
    JSONArray(json).let { a -> (0 until a.length()).map { seerrkachelLesen(a.getJSONObject(it)) } }

/**
 * Vorlage: `Seerrmarke` — **eine Tabelle** fuer Kachel und Detailseite; es gab sie einmal zweimal,
 * und die beiden liefen auseinander. Zwei Woerter je Stand mit Absicht: auf 112 Punkt passt der
 * lange Satz der Detailseite nicht. „Angefragt" statt „Lädt": die Anfrage ist durch, es fliessen
 * keine Bytes.
 */
object Seerrmarke {
    private val bernstein = Color(0.85f, 0.60f, 0.17f)
    private val blau = Color(0.29f, 0.56f, 0.85f)

    fun farbe(stand: Int): Color = when (stand) { 2 -> bernstein; 3 -> blau; else -> Stil.akzent }

    fun symbol(stand: Int): ImageVector = when (stand) {
        2 -> Icons.Filled.Schedule
        3 -> Icons.Outlined.ArrowCircleDown
        4 -> Icons.Filled.Contrast
        5 -> Icons.Filled.Check
        else -> Icons.Outlined.AddCircleOutline
    }

    fun wort(stand: Int) = uebersetzt(when (stand) {
        2 -> "Wartet auf Freigabe"; 3 -> "Angefragt"; 4 -> "Teilweise vorhanden"; 5 -> "Auf deinem Server"
        else -> "Nicht auf deinem Server"
    })

    fun kurzwort(stand: Int): String? = when (stand) {
        2 -> uebersetzt("wartet"); 3 -> uebersetzt("angefragt"); 4 -> uebersetzt("teilweise"); else -> null
    }

    fun hinweis(stand: Int) = uebersetzt(when (stand) {
        2 -> "Deine Anfrage liegt beim Verwalter des Servers. Du musst nichts weiter tun."
        3 -> "Deine Anfrage ist durch. Der Titel erscheint von selbst in deiner Bibliothek."
        else -> "Dieser Titel liegt bereits auf deinem Server."
    })
}

/**
 * Vorlage: `Seerrkachel` — **blass, und das ist die ganze Auskunft:** wer schnell scrollt, sieht ohne
 * zu lesen, dass hier nichts abzuspielen ist. Die Marke darauf bleibt voll deckend.
 */
@Composable
fun SeerrkachelAnsicht(k: Seerrkachel, modifier: Modifier = Modifier, tun: () -> Unit) {
    Column(modifier.einblenden().antippen(tun), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(Stil.eckeKachel)).background(Stil.flaeche)) {
            AsyncImage(model = k.plakat, contentDescription = k.titel, contentScale = ContentScale.Crop,
                       modifier = Modifier.fillMaxSize().alpha(0.45f))
            if (k.stand != 5) {
                val kurz = Seerrmarke.kurzwort(k.stand)
                Row(Modifier.align(Alignment.BottomStart).padding(6.dp).clip(CircleShape).background(Seerrmarke.farbe(k.stand))
                        .padding(horizontal = if (kurz != null) 7.dp else 5.dp, vertical = 3.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    Icon(Seerrmarke.symbol(k.stand), contentDescription = null, tint = Stil.grund, modifier = Modifier.size(11.dp))
                    kurz?.let { Text(it, style = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.SemiBold), color = Stil.grund) }
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(k.titel, style = Stil.kachel, color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(listOfNotNull(k.jahr?.toString(), uebersetzt(if (k.istSerie) "Serie" else "Film")).joinToString(" · "),
                 style = Stil.klein, color = Stil.schriftSehrLeise, maxLines = 1)
        }
    }
}

/** Ueberschrift eines Trefferblocks mit Anzahl — „Auf deinem Server", „Kann angefragt werden". */
@Composable
fun Blocktitel(titel: String, anzahl: Int, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().padding(top = 16.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(titel.uppercase(), style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.5.sp),
             color = Stil.schriftSehrLeise, modifier = Modifier.weight(1f))
        if (anzahl > 0) Text("$anzahl", style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium, fontFeatureSettings = "tnum"),
                             color = Stil.schriftSehrLeise)
    }
}

/**
 * Vorlage: `SeerrEinstellungenView`. Anmeldung mit Jellyfins eigenem Namen und Passwort; **das
 * Passwort wird nicht gespeichert**, nur die Sitzung, die Seerr ausstellt — verschluesselt, je
 * Jellyfin-Server. „Trennen", nicht „Abmelden": das Konto bei Seerr bleibt unberuehrt.
 */
@Composable
fun SeerrEinstellungenSeite(app: SwiftlyAnwendung, zurueck: () -> Unit) {
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
            } catch (e: CancellationException) { throw e } catch (e: Exception) { fehler = fehlertext(app, e) }
            verbindet = false
        }
    }

    Einstellungsseite("Seerr", zurueck) {
        Text(uebersetzt("Jellyseerr oder Overseerr. Dann zeigt die Suche auch Titel, die noch nicht auf deinem Server sind, und du kannst sie anfragen."),
             style = Stil.koerper.copy(lineHeight = 21.sp), color = Stil.schriftLeise, modifier = Modifier.padding(horizontal = Stil.randAbstand))
        if (verbunden) {
            Einstellungsgruppe(uebersetzt("Verbunden")) {
                Wertzeile(Icons.Filled.Link, app.seerrAdresse().orEmpty(),
                          wert = when (traegt) { true -> uebersetzt("Aktiv"); false -> uebersetzt("Sitzung abgelaufen"); null -> null })
                Trennlinie()
                Wertzeile(Icons.Outlined.Cancel, uebersetzt("Verbindung trennen")) { app.seerrTrennen(); passwort = "" }
            }
        } else {
            Column(Modifier.padding(horizontal = Stil.randAbstand).padding(top = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Eingabefeld(adresse, { adresse = it }, Icons.Filled.Link, "seerr.example.de", adresse = true)
                Eingabefeld(benutzer, { benutzer = it }, Icons.Outlined.Person, uebersetzt("Benutzername"))
                Eingabefeld(passwort, { passwort = it }, Icons.Outlined.Lock, uebersetzt("Passwort"), geheim = true) { verbinden() }
                fehler?.let { Text(it, style = Stil.klein, color = Stil.warnung) }
                // Kein gesperrter Knopf: er erscheint, sobald alles da ist.
                when {
                    verbindet -> Text(uebersetzt("Verbinde…"), style = Stil.koerper, color = Stil.schriftLeise)
                    adresse.isNotBlank() && benutzer.isNotBlank() && passwort.isNotBlank() ->
                        Hauptknopf(uebersetzt("Verbinden"), modifier = Modifier.padding(top = 6.dp)) { verbinden() }
                }
                Text(uebersetzt("Swiftly speichert dein Passwort nicht, nur die Anmeldung bei Seerr."),
                     style = TextStyle(fontSize = 12.sp, lineHeight = 17.sp), color = Stil.schriftSehrLeise, modifier = Modifier.padding(top = 6.dp))
            }
        }
    }
}

/**
 * Vorlage: `SeerrDetailView` — **derselbe Aufbau wie die echte Titelseite**; drei eigene Fassungen
 * liefen vorher je anders auseinander. Anfragen in zwei Schritten: der zweite Tipp ist die Bestellung,
 * die Bestaetigung faellt nach fuenf Sekunden zurueck. Bei einer Serie ist das Staffelblatt der
 * zweite Schritt; nichts ist vorausgewaehlt, und eine leere Auswahl geht nie hinaus — sie hiesse „alle".
 */
@Composable
fun SeerrDetailSeite(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    val k = app.seerrTreffer[ziel.id] ?: run { LaunchedEffect(Unit) { zurueck() }; return }
    var detail by remember(ziel.id) { mutableStateOf<JSONObject?>(null) }
    var stand by remember(ziel.id) { mutableIntStateOf(k.stand) }
    var anfragbar by remember(ziel.id) { mutableStateOf(k.anfragbar) }
    var angefragt by remember(ziel.id) { mutableStateOf(false) }
    var bestaetigt by remember { mutableStateOf(false) }
    var laeuft by remember { mutableStateOf(false) }
    var meldung by remember { mutableStateOf<String?>(null) }
    val lauf = rememberCoroutineScope()
    val ruck = rememberRuck()
    LaunchedEffect(ziel.id) {
        detail = runCatching { JSONObject(withContext(Dispatchers.IO) { app.kern.seerrDetail(k.art, k.id.toLong()).await() }) }.getOrNull()
    }
    LaunchedEffect(bestaetigt) { if (bestaetigt) { delay(5000); bestaetigt = false } }

    fun anfragen(staffeln: List<Int>) {
        if (k.istSerie && staffeln.isEmpty()) return
        laeuft = true
        lauf.launch {
            val grund = withContext(Dispatchers.IO) { app.kern.seerrAnfragen(k.art, k.id.toLong(), staffeln.joinToString(",")).await() }
            if (grund.isEmpty()) { angefragt = true; stand = 2; anfragbar = false } else meldung = fehlertext(grund)
            laeuft = false
            bestaetigt = false
        }
    }
    fun staffelblatt() {
        val roh = detail?.optJSONArray("staffeln") ?: return
        val liste = (0 until roh.length()).map { roh.getJSONObject(it) }
        app.blatt.value = Blattwunsch(uebersetzt("Welche Staffeln?"),
            liste.map { o ->
                val folgen = o.getInt("folgen")
                Wahl(o.getInt("nummer").toString(),
                     uebersetzt("Staffel %lld", o.getInt("nummer")) + if (folgen > 0) " · " + uebersetzt("%lld Folgen", folgen) else "")
            },
            null,
            mehrfach = emptySet(),
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
    val scroll = rememberScrollState()
    val dichte = LocalDensity.current.density

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        Column(Modifier.fillMaxSize().verticalScroll(scroll)) {
            Held(k.kulisse, k.titel, nebenzeile)
            Column(Modifier.padding(horizontal = Stil.randAbstand).padding(top = 14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Row(Modifier.heightIn(min = 26.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    val farbe = Seerrmarke.farbe(stand)
                    Row(Modifier.clip(RoundedCornerShape(8.dp)).background(farbe.copy(alpha = 0.15f)).padding(start = 8.dp, end = 10.dp, top = 4.dp, bottom = 4.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Seerrmarke.symbol(stand), contentDescription = null, tint = farbe, modifier = Modifier.size(12.dp))
                        Text(Seerrmarke.wort(stand), style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium), color = farbe)
                    }
                    // 0 ist bei TMDB „keine Bewertung", nicht null Sterne.
                    d?.feldZahl("bewertung")?.takeIf { it > 0 }?.let { b ->
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            Icon(Icons.Filled.Star, contentDescription = null, tint = Color.White.copy(alpha = 0.8f), modifier = Modifier.size(12.dp))
                            Text(String.format(Locale.getDefault(), "%.1f", b), style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium),
                                 color = Color.White.copy(alpha = 0.8f))
                        }
                    }
                }
                Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
                    when {
                        angefragt -> Hinweisbox(uebersetzt("Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."))
                        // Weiss wie „Fortsetzen", nicht im Akzent — die Marke darueber traegt die Farbe schon.
                        anfragbar -> Spielknopf(if (bestaetigt) Icons.Filled.Check else Icons.Filled.Add,
                            uebersetzt(when { laeuft -> "Wird angefragt…"; bestaetigt -> "Wirklich anfragen?"; else -> "Anfragen" }),
                            an = !laeuft, haupt = true) {
                            ruck(Ruck.Mittel)
                            when {
                                k.istSerie -> staffelblatt()
                                bestaetigt -> anfragen(emptyList())
                                else -> bestaetigt = true
                            }
                        }
                        else -> Hinweisbox(Seerrmarke.hinweis(stand))
                    }
                }
                d?.feldText("beschreibung")?.let { Klapptext(it) }
            }
            val leute = d?.feldListe("besetzung") { Mitwirkender(it.getString("id"), it.getString("name"), it.feldText("rolle"), it.feldText("bild")) }.orEmpty()
            if (leute.isNotEmpty()) Abschnitt(uebersetzt("Besetzung"), 14.dp) {
                items(leute.take(12)) { p -> Besetzungskachel(p) }
            }
            val aehnliche = d?.feldListe("aehnliches") { seerrkachelLesen(it) }.orEmpty()
            if (aehnliche.isNotEmpty()) Abschnitt(uebersetzt("Ähnliche Titel"), Stil.kachelAbstand) {
                items(aehnliche) { t ->
                    SeerrkachelAnsicht(t, Modifier.width(Stil.kachelBreite)) { app.seerrTreffer[t.schluessel] = t; oeffnen(Ziel(t.schluessel, t.titel, "Seerrtitel")) }
                }
            }
            Spacer(Modifier.navigationBarsPadding().height(30.dp))
        }
        Detailkopf(k.titel, { ((scroll.value / dichte - 150f) / 70f).coerceIn(0f, 1f) }, zurueck)
        Hinweisstreifen(meldung, Modifier.align(Alignment.BottomCenter)) { meldung = null }
    }
}

@Composable
private fun Hinweisbox(text: String) {
    Text(text, style = TextStyle(fontSize = 14.sp, lineHeight = 19.sp), color = Stil.schriftLeise,
         modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(Stil.ecke)).background(Stil.flaeche).padding(14.dp))
}
