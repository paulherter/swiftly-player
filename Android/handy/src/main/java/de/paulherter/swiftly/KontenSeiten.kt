package de.paulherter.swiftly

import androidx.compose.foundation.layout.imePadding
import androidx.compose.ui.draw.alpha
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Eingabefeld
import de.paulherter.swiftly.gemeinsam.Hauptknopf
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.kern.Kern
import android.os.SystemClock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

// MARK: Bausteine

/**
 * Vorlage: `NebenknopfStil` — 48 hoch, **`flaeche`**, gedrueckt `gedruecktFlaeche`, sofort an
 * und 120 ms aus, dazu der Massstab 0,97 wie an jedem anderen Knopf.
 *
 * Er zeichnete Weiss auf 10 bzw. 16 Prozent ueber den Grund. Das ergibt #2A2A2A und #333333 —
 * zwei Toene knapp neben den beiden, die es dafuer gibt, und keiner davon mit Namen. Diese
 * Fassung traegt zusaetzlich ein Zeichen; sonst ist sie der geteilte `Nebenknopf`.
 *
 * `akzent`: Schrift und Zeichen im Akzent — `NebenknopfStil(akzent: true)`, der zweite Weg zum
 * selben Ziel (Quick Connect unter dem Anmeldeknopf). 9 zwischen Zeichen und Wort.
 */
@Composable
fun Nebenknopf(symbol: Zeichen, text: String, akzent: Boolean = true, tun: () -> Unit) {
    val quelle = remember { MutableInteractionSource() }
    val gedrueckt by quelle.collectIsPressedAsState()
    val mass by androidx.compose.animation.core.animateFloatAsState(
        if (gedrueckt) Bewegung.DRUCKMASS else 1f, Bewegung.loslassen(), label = "druck")
    Row(Modifier.fillMaxWidth().heightIn(min = Stil.knopfHoehe)
            .graphicsLayer { scaleX = mass; scaleY = mass }
            .clip(RoundedCornerShape(Stil.ecke))
            .background(if (gedrueckt) Stil.gedruecktFlaeche else Stil.flaeche)
            .clickable(quelle, null, onClick = tun),
        horizontalArrangement = Arrangement.spacedBy(9.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
        // Das Zeichen im Knopf traegt die Schrift des Knopfs: 15 Medium (`NebenknopfStil`).
        val farbe = if (akzent) Stil.akzent else Stil.schrift
        Symbol(symbol, 15.dp, farbe = farbe, staerke = Staerke.Mittel)
        Text(text, style = Stil.knopftext, color = farbe)
    }
}

/** „oder" zwischen zwei Linien — trennt Passwort und Quick Connect. */
@Composable
fun Oder(modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.weight(1f).height(1.dp).background(Stil.linie))
        Text(uebersetzt("oder"), style = Stil.klein, color = Stil.schriftSehrLeise)
        Box(Modifier.weight(1f).height(1.dp).background(Stil.linie))
    }
}

/** Vorlage: `Profilzeichen` — Bild oder Buchstabe; hervorgehoben mit Akzentring. */
@Composable
fun Profilzeichen(name: String, bild: String?, groesse: Dp, hervorgehoben: Boolean = false) {
    Box(Modifier.size(groesse).border(if (hervorgehoben) 1.5.dp else 1.dp, if (hervorgehoben) Stil.akzent else Stil.rand, CircleShape)
            .padding(if (hervorgehoben) 2.dp else 0.dp)) {
        SubcomposeAsyncImage(model = bild, contentDescription = name, contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize().clip(CircleShape),
            error = {
                Box(Modifier.fillMaxSize().background(Stil.erhoeht), contentAlignment = Alignment.Center) {
                    Text(name.take(1).uppercase(), color = Stil.schrift,
                         style = TextStyle(fontSize = (groesse.value * 0.38f).sp, fontWeight = FontWeight.SemiBold))
                }
            })
    }
}

// MARK: Quick Connect

/**
 * Vorlage: `QuickConnectAnmeldung` + `QuickConnectModell` — dieses Geraet zeigt einen Code, ein
 * anderes gibt ihn frei. Frist und Takt kommen aus dem Paket (`Quickconnectfrist`); sie standen
 * einmal dreimal im Code und liefen auseinander. Ein neuer Code beendet die alte Abfrage — ein
 * spaeter Rueckruf der alten ueberschreibt nichts mehr.
 */
@Composable
fun QuickConnectAnmeldung(app: SwiftlyAnwendung, neuerServer: Boolean, zurueck: () -> Unit, angemeldet: (String) -> Unit) {
    val frist = remember { JSONArray(Kern.quickConnectFrist()) }
    val sekunden = frist.getInt(0)
    var code by remember { mutableStateOf<String?>(null) }
    var fehler by remember { mutableStateOf<String?>(null) }
    var rest by remember { mutableIntStateOf(0) }
    var lauf by remember { mutableIntStateOf(0) }
    val ablage = LocalClipboardManager.current
    BackHandler(onBack = zurueck)

    LaunchedEffect(lauf) {
        code = null
        fehler = null
        try {
            code = withContext(Dispatchers.IO) { app.kern.quickConnectStarten(neuerServer).await() }
            // **Das Warten steht im Paket** (`Quickconnectwarten`, ueber den Kern): Frist an der Uhr,
            // nach der Rueckkehr aus dem Browser sofort nachfragen, ein Netzfehler beendet das Warten
            // nicht (88f7808). Hier nur die Restzeit zeigen und das Ergebnis annehmen.
            val c = code.orEmpty()
            rest = sekunden
            val anzeige = launch { while (true) { delay(1000); rest = app.kern.quickConnectRest().toInt() } }
            try {
                val ergebnis = withContext(Dispatchers.IO) { app.kern.quickConnectWarten(neuerServer).await() }
                anzeige.cancel()
                when {
                    ergebnis == "freigegeben" -> angemeldet(withContext(Dispatchers.IO) { app.kern.quickConnectAnmelden(neuerServer).await() })
                    ergebnis.isNotEmpty() -> { rest = 0; fehler = ergebnis }
                }
            } finally {
                anzeige.cancel()
                // Seite zu oder neuer Code: nicht weiter nachfragen — sonst meldet eine spaete Freigabe an.
                app.kern.quickConnectWartenBeenden(c)
            }
        } catch (e: CancellationException) { throw e } catch (e: Exception) {
            fehler = fehlertext(app, e)
        }
    }

    Column(Modifier.fillMaxSize().background(Stil.grund)) {
        Unterseitenkopf(uebersetzt("Quick Connect"), zurueck)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Stil.randAbstand).widthIn(max = Stil.formularbreite)) {
            Text(uebersetzt("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist."),
                 style = Stil.koerper.copy(lineHeight = 21.sp), color = Stil.schriftLeise, modifier = Modifier.padding(top = 10.dp))
            val c = code
            when {
                // `fehler`, nicht `warnung`: der Code kam nicht — das ist schiefgegangen, nicht
                // etwas, das auf jemanden wartet (BRAND 1, fuenf semantische Farben).
                fehler != null -> Text(fehler.orEmpty(), style = Stil.koerper.copy(textAlign = TextAlign.Center), color = Stil.fehler,
                                       modifier = Modifier.fillMaxWidth().padding(top = 40.dp))
                c == null -> Box(Modifier.fillMaxWidth().padding(top = 40.dp), contentAlignment = Alignment.Center) {
                    Ladefeld(Modifier.size(260.dp, 60.dp), 12.dp)
                }
                else -> {
                    // Ein Feld je Ziffer; bei gerader Laenge eine kleine Luecke in der Mitte. Antippen kopiert.
                    Row(Modifier.fillMaxWidth().padding(top = 34.dp).antippen { ablage.setText(AnnotatedString(c)) },
                        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
                        c.forEachIndexed { i, zeichen ->
                            if (c.length % 2 == 0 && i == c.length / 2) Spacer(Modifier.width(6.dp))
                            // **Kein Rand** (BRAND 4): ein Feld ist eine gefuellte Flaeche.
                            // 28 ist die Stufe des Seitentitels — der Code *ist* hier die Seite.
                            Box(Modifier.size(46.dp, 60.dp).clip(RoundedCornerShape(Stil.eckeFeld)).background(Stil.flaeche),
                                contentAlignment = Alignment.Center) {
                                Text(zeichen.toString(), style = Stil.titelGross.copy(fontWeight = FontWeight.SemiBold, letterSpacing = 0.sp, fontFeatureSettings = "tnum"),
                                     color = Stil.schrift)
                            }
                        }
                    }
                    Row(Modifier.fillMaxWidth().padding(top = 22.dp), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
                        Box(Modifier.size(8.dp).clip(CircleShape).background(Stil.akzent))
                        Text(uebersetzt("Warte auf Freigabe · noch %lld:%@", rest / 60, "%02d".format(rest % 60)),
                             style = Stil.kachel.copy(fontFeatureSettings = "tnum"), color = Stil.schriftLeise)
                    }
                }
            }
            Column(Modifier.padding(top = 38.dp)) {
                Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.linie))
                // Gruppentitel: 20 Semibold in Normalschreibung, `schriftLeise` (BRAND 2).
                Text(uebersetzt("So gehts"), style = Stil.reihe,
                     color = Stil.schriftLeise, modifier = Modifier.padding(top = 16.dp, bottom = 10.dp))
                listOf("Jellyfin im Browser öffnen und anmelden", "Oben rechts aufs Profil, dann Quick Connect",
                       "Code eingeben, dann geht es hier von selbst weiter").forEachIndexed { i, schritt ->
                    Row(Modifier.padding(top = 10.dp)) {
                        Text("${i + 1}", style = Stil.koerper, color = Stil.schriftSehrLeise, modifier = Modifier.width(Stil.zeichenSpalte))
                        Text(uebersetzt(schritt), style = Stil.koerper.copy(lineHeight = 21.sp), color = Stil.schriftLeise)
                    }
                }
            }
        }
        Box(Modifier.padding(horizontal = Stil.randAbstand).navigationBarsPadding().padding(bottom = 24.dp)) {
            // `NebenknopfStil()` ohne Zeichen und ohne Akzent.
            de.paulherter.swiftly.gemeinsam.Nebenknopf(uebersetzt("Neuen Code holen")) { lauf++ }
        }
    }
}

// MARK: Server hinzufuegen

/**
 * Vorlage: `ServerAufnahmeView` — ein weiterer Jellyfin-Server. **Die laufende Sitzung bleibt
 * unberuehrt**, bis die neue steht: die Fassade prueft und meldet an einem eigenen Client an.
 * `voreingestellt`: vom Plus einer fremden Serverkarte — dann ohne Adressfeld, solange es klappt.
 */
@Composable
fun ServerAufnahmeSeite(app: SwiftlyAnwendung, voreingestellt: String?, zurueck: () -> Unit) {
    var adresse by remember { mutableStateOf(voreingestellt.orEmpty()) }
    var server by remember { mutableStateOf<Pair<String, String>?>(null) }
    var pruefe by remember { mutableStateOf(false) }
    var benutzer by remember { mutableStateOf("") }
    var passwort by remember { mutableStateOf("") }
    var laeuft by remember { mutableStateOf(false) }
    var fehler by remember { mutableStateOf<String?>(null) }
    var quick by remember { mutableStateOf(false) }
    /** „Erweitert" — eigene Header fuer einen Dienst vor dem Server. */
    val koepfe = rememberKopfzeilen()
    val lauf = rememberCoroutineScope()

    fun abbrechen() { app.kern.aufnahmeAbbrechen(); zurueck() }
    fun aufnehmen(sitzung: String) { app.kern.aufnahmeAbbrechen(); app.sitzungAufnehmen(sitzung) }
    fun pruefen() {
        if (adresse.isBlank() || pruefe) return
        pruefe = true; fehler = null
        lauf.launch {
            try {
                val o = JSONObject(withContext(Dispatchers.IO) { app.kern.aufnahmeVerbinden(adresse, koepfe.alsJson()).await() })
                // Erst jetzt ablegen: fuer eine Adresse, unter der nichts antwortet, bleibt nichts liegen.
                if (koepfe.isNotEmpty()) app.eigeneKoepfeAblegen()
                server = o.getString("name") to o.getString("version")
            } catch (e: CancellationException) { throw e } catch (e: Exception) { fehler = fehlertext(app, e) }
            pruefe = false
        }
    }
    fun anmelden() {
        if (benutzer.isBlank() || laeuft) return
        laeuft = true; fehler = null
        lauf.launch {
            try { aufnehmen(withContext(Dispatchers.IO) { app.kern.aufnahmeAnmelden(benutzer, passwort).await() }) }
            catch (e: CancellationException) { throw e } catch (e: Exception) { fehler = fehlertext(app, e) }
            laeuft = false
        }
    }
    LaunchedEffect(Unit) { if (voreingestellt != null) pruefen() }

    if (quick) {
        QuickConnectAnmeldung(app, neuerServer = true, zurueck = { quick = false }) { aufnehmen(it) }
        return
    }
    BackHandler { abbrechen() }

    val s = server
    // Der Titel ist der Servername, sobald er feststeht.
    val seitentitel = s?.first ?: uebersetzt(if (voreingestellt != null) "Konto hinzufügen" else "Server hinzufügen")
    // **Oben der Rueckweg, unten nichts.** Als geschobene Seite hat sie oben denselben Pfeil wie jede
    // andere Unterseite; ein zweites „Abbrechen" unten waere ein zweiter Weg zurueck.
    Column(Modifier.fillMaxSize().background(Stil.grund)) {
        Unterseitenkopf(seitentitel, { abbrechen() })
        Box(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = Stil.formularbreite).fillMaxWidth().padding(horizontal = 28.dp).padding(bottom = 40.dp)
                       .navigationBarsPadding().imePadding()) {
                // `kopf`: verbunden, die voreingestellte Adresse, oder was die Seite tut — oben 8.
                Box(Modifier.padding(top = 8.dp)) {
                    when {
                        s != null -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Box(Modifier.size(7.dp).clip(CircleShape).background(Stil.akzent))
                            Text(uebersetzt("Verbunden · Jellyfin %@", s.second), style = Stil.klein, color = Stil.schriftSehrLeise)
                        }
                        voreingestellt != null -> Text(runCatching { java.net.URI(voreingestellt).host }.getOrNull() ?: voreingestellt,
                                                       style = Stil.koerper, color = Stil.schriftLeise)
                        else -> Text(uebersetzt("Die Adresse eines weiteren Jellyfin-Servers. Du bleibst bei beiden angemeldet und wechselst auf der Profilseite zwischen ihnen."),
                                     style = Stil.koerper.copy(lineHeight = 21.sp), color = Stil.schriftLeise)
                    }
                }
                if (s != null) {
                    Column(Modifier.padding(top = 28.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Eingabefeld(benutzer, { benutzer = it }, Zeichen.Person, uebersetzt("Benutzername"))
                        Eingabefeld(passwort, { passwort = it }, Zeichen.Schloss, uebersetzt("Passwort"), geheim = true) { anmelden() }
                        Hauptknopf(uebersetzt(if (laeuft) "Anmelden…" else "Anmelden"), freigegeben = benutzer.isNotBlank() && !laeuft,
                                   modifier = Modifier.padding(top = 10.dp).alpha(if (benutzer.isBlank()) 0.4f else 1f)) { anmelden() }
                        Oder(Modifier.padding(top = 16.dp))
                        Box(Modifier.padding(top = 10.dp)) {
                            Nebenknopf(Zeichen.Fernseher, uebersetzt("Mit Quick Connect anmelden")) { quick = true }
                        }
                    }
                } else if (voreingestellt == null || fehler != null) {
                    Column(Modifier.padding(top = 28.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Eingabefeld(adresse, { adresse = it }, Zeichen.Server, "tv.example.de", adresse = true) { pruefen() }
                        Erweitertbereich(koepfe)
                        Hauptknopf(uebersetzt(if (pruefe) "Verbinden…" else "Verbinden"), freigegeben = adresse.isNotBlank() && !pruefe,
                                   modifier = Modifier.padding(top = 10.dp).alpha(if (adresse.isBlank()) 0.4f else 1f)) { pruefen() }
                    }
                }
                // `fehler`, nicht `warnung`: eine abgelehnte Anmeldung ist schiefgegangen.
                fehler?.let { Text(it, style = Stil.klein.copy(textAlign = TextAlign.Center), color = Stil.fehler,
                                   modifier = Modifier.fillMaxWidth().padding(top = 12.dp)) }
            }
        }
    }
}

// MARK: Kontokarten

private data class Kontoeintrag(val kennung: String, val name: String, val aktiv: Boolean, val bild: String?)
private data class Serverkarte(val adresse: String, val host: String, val aktiv: Boolean, val konten: List<Kontoeintrag>)

/**
 * Vorlage: `Kontokarte` in `ProfilView.swift` — eine Karte je Server. Vorn das Konto, das gerade
 * gilt; darunter die anderen und ein gestricheltes Plus. **Randbuendig, kein Anschnitt:** mit
 * einem Server deutet nichts ein Wischen an; ab zwei blaettert man die Karten, Punkte darunter.
 * Beim Wechsel wird nicht abgemeldet — das verlassene Konto bleibt gueltig fuer den Weg zurueck.
 */
@Composable
fun Kontokarten(app: SwiftlyAnwendung, server: Pair<String, String>?, oeffnen: (Ziel) -> Unit) {
    val bund = app.ablage.konten.orEmpty()
    val karten = remember(bund) {
        JSONArray(Kern.bundUebersicht(bund)).let { a ->
            (0 until a.length()).map { i ->
                a.getJSONObject(i).let { o ->
                    Serverkarte(o.getString("adresse"), o.getString("host"), o.getBoolean("aktiv"),
                        o.getJSONArray("konten").let { k -> (0 until k.length()).map { j -> k.getJSONObject(j).let { e ->
                            Kontoeintrag(e.getString("kennung"), e.getString("name"), e.getBoolean("aktiv"), if (e.isNull("bild")) null else e.getString("bild"))
                        } } })
                }
            }
        }
    }
    if (karten.size <= 1) {
        karten.firstOrNull()?.let { Karte { KarteInhalt(app, it, mehrere = false, server, oeffnen) } }
        return
    }
    val blaetter = rememberPagerState(initialPage = karten.indexOfFirst { it.aktiv }.coerceAtLeast(0)) { karten.size }
    Column {
        HorizontalPager(blaetter, verticalAlignment = Alignment.Top) { i -> Karte { KarteInhalt(app, karten[i], mehrere = true, server, oeffnen) } }
        Row(Modifier.fillMaxWidth().padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(7.dp, Alignment.CenterHorizontally)) {
            karten.indices.forEach { i ->
                Box(Modifier.size(6.dp).clip(CircleShape).background(if (i == blaetter.currentPage) Stil.schrift else Stil.schriftSehrLeise))
            }
        }
    }
}

@Composable
private fun KarteInhalt(app: SwiftlyAnwendung, karte: Serverkarte, mehrere: Boolean, server: Pair<String, String>?, oeffnen: (Ziel) -> Unit) {
    val vorn = karte.konten.firstOrNull { it.aktiv } ?: karte.konten.firstOrNull() ?: return
    val andere = karte.konten.filter { it.kennung != vorn.kennung }
    // Die eigene Kopfzeile wechselt nichts; die eines fremden Servers wechselt dorthin.
    Row(Modifier.fillMaxWidth().then(if (!karte.aktiv) Modifier.druckzeile { app.kontoWechseln(vorn.kennung) } else Modifier).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Profilzeichen(vorn.name, vorn.bild, 56.dp, hervorgehoben = karte.aktiv && mehrere)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            // 17 Semibold, die Blattrubrik — der Name ist der Gegenstand der Karte, nicht eine Zeile.
            Text(vorn.name, style = Stil.rubrikGross, color = Stil.schrift, maxLines = 1)
            // **Beide Zeilen halten ihren Platz, auch solange sie leer sind.** Name und Serverauskunft
            // kommen nacheinander: der Name steht sofort, `serverauskunft` erst nach der Antwort.
            // Wuchs die Kopfzeile dabei ueber die 56 des Zeichens hinaus, rutschte alles darunter —
            // Trennlinie und die Reihe der anderen Konten — nach, und die wirkten „nachgeladen".
            val (zeile, unterzeile) = if (karte.aktiv)
                (server?.first?.takeIf { it.isNotEmpty() } ?: app.servername.value.orEmpty()) to
                    (server?.second?.takeIf { it.isNotEmpty() }?.let { uebersetzt("Jellyfin %@", it) } ?: "")
            else karte.host to uebersetzt("Antippen zum Wechseln")
            Text(zeile.ifEmpty { " " }, style = Stil.klein, color = Stil.schriftSehrLeise, maxLines = 1)
            Text(unterzeile.ifEmpty { " " }, style = Stil.klein, color = Stil.schriftSehrLeise, maxLines = 1)
        }
    }
    Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.linie))
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(16.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        andere.forEach { k ->
            Box(Modifier.size(40.dp).antippen { app.kontoWechseln(k.kennung) }) { Profilzeichen(k.name, k.bild, 40.dp) }
        }
        // Das Plus: am eigenen Server ein weiteres Konto, an einem fremden die Aufnahme mit seiner Adresse.
        Box(Modifier.size(40.dp)
                .drawBehind {
                    val strich = 1.5.dp.toPx()
                    drawCircle(Stil.rand, radius = size.minDimension / 2 - strich / 2,
                               style = Stroke(width = strich, pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx()))))
                }
                .antippen {
                    if (karte.aktiv) oeffnen(Ziel("weiteresKonto", uebersetzt("Konto hinzufügen"), "WeiteresKonto"))
                    else oeffnen(Ziel(karte.adresse, uebersetzt("Konto hinzufügen"), "ServerAufnahme"))
                },
            contentAlignment = Alignment.Center) {
            Symbol(Zeichen.Plus, 15.dp, farbe = Stil.schriftSehrLeise, staerke = Staerke.Halbfett, beschreibung = uebersetzt("Konto hinzufügen"))
        }
    }
}
