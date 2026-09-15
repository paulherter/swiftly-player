package de.paulherter.swiftly

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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

// MARK: Bausteine

/** Vorlage: `NebenknopfStil` — 48 hoch, Weiss 10 %, gedrueckt 16 %, sofort an und 120 ms aus. */
@Composable
fun Nebenknopf(symbol: ImageVector, text: String, tun: () -> Unit) {
    val quelle = remember { MutableInteractionSource() }
    val gedrueckt by quelle.collectIsPressedAsState()
    val druck = remember { androidx.compose.animation.core.Animatable(0f) }
    LaunchedEffect(gedrueckt) { if (gedrueckt) druck.snapTo(1f) else druck.animateTo(0f, Bewegung.loslassen()) }
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(RoundedCornerShape(Stil.ecke))
            .drawBehind { drawRect(Color.White.copy(alpha = 0.10f + 0.06f * druck.value)) }
            .clickable(quelle, null, onClick = tun),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
        Icon(symbol, contentDescription = null, tint = Stil.schrift, modifier = Modifier.size(18.dp))
        Text(text, style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium), color = Stil.schrift)
    }
}

/** „oder" zwischen zwei Linien — trennt Passwort und Quick Connect. */
@Composable
fun Oder(modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.weight(1f).height(1.dp).background(Stil.linie))
        Text(uebersetzt("oder"), style = TextStyle(fontSize = 12.sp), color = Stil.schriftSehrLeise)
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
    val takt = frist.getInt(1)
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
            rest = sekunden
            while (rest > 0) {
                delay(1000)
                rest--
                if (rest % takt == 0 && withContext(Dispatchers.IO) { app.kern.quickConnectFreigegeben(neuerServer).await() }) {
                    angemeldet(withContext(Dispatchers.IO) { app.kern.quickConnectAnmelden(neuerServer).await() })
                    return@LaunchedEffect
                }
            }
            fehler = uebersetzt("Der Code ist abgelaufen. Hol dir einen neuen.")
        } catch (e: CancellationException) { throw e } catch (e: Exception) {
            fehler = e.message ?: e.toString()
        }
    }

    Column(Modifier.fillMaxSize().background(Stil.grund)) {
        Unterseitenkopf(uebersetzt("Quick Connect"), zurueck)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Stil.randAbstand).widthIn(max = Stil.formularbreite)) {
            Text(uebersetzt("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist."),
                 style = Stil.koerper.copy(lineHeight = 21.sp), color = Stil.schriftLeise, modifier = Modifier.padding(top = 10.dp))
            val c = code
            when {
                fehler != null -> Text(fehler.orEmpty(), style = TextStyle(fontSize = 15.sp, textAlign = TextAlign.Center), color = Stil.warnung,
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
                            Box(Modifier.size(46.dp, 60.dp).clip(RoundedCornerShape(Stil.eckeFeld)).background(Stil.flaeche)
                                    .border(1.dp, Stil.rand, RoundedCornerShape(Stil.eckeFeld)),
                                contentAlignment = Alignment.Center) {
                                Text(zeichen.toString(), style = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum"),
                                     color = Stil.schrift)
                            }
                        }
                    }
                    Row(Modifier.fillMaxWidth().padding(top = 22.dp), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
                        Box(Modifier.size(8.dp).clip(CircleShape).background(Stil.akzent))
                        Text(uebersetzt("Warte auf Freigabe · noch %lld:%@", rest / 60, "%02d".format(rest % 60)),
                             style = TextStyle(fontSize = 14.sp, fontFeatureSettings = "tnum"), color = Stil.schriftLeise)
                    }
                }
            }
            Column(Modifier.padding(top = 38.dp)) {
                Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.linie))
                Text(uebersetzt("So gehts").uppercase(), style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.2.sp),
                     color = Stil.schriftSehrLeise, modifier = Modifier.padding(top = 16.dp, bottom = 8.dp))
                listOf("Jellyfin im Browser öffnen und anmelden", "Oben rechts aufs Profil, dann Quick Connect",
                       "Code eintippen — hier gehts dann von allein weiter").forEachIndexed { i, schritt ->
                    Row(Modifier.padding(top = 10.dp)) {
                        Text("${i + 1}", style = TextStyle(fontSize = 14.sp), color = Stil.schriftSehrLeise, modifier = Modifier.width(20.dp))
                        Text(uebersetzt(schritt), style = TextStyle(fontSize = 14.sp, lineHeight = 19.sp), color = Stil.schriftLeise)
                    }
                }
            }
        }
        Box(Modifier.padding(horizontal = Stil.randAbstand).navigationBarsPadding().padding(bottom = 24.dp)) {
            Nebenknopf(Icons.Filled.Refresh, uebersetzt("Neuen Code holen")) { lauf++ }
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
    val lauf = rememberCoroutineScope()

    fun abbrechen() { app.kern.aufnahmeAbbrechen(); zurueck() }
    fun aufnehmen(sitzung: String) { app.kern.aufnahmeAbbrechen(); app.sitzungAufnehmen(sitzung) }
    fun pruefen() {
        if (adresse.isBlank() || pruefe) return
        pruefe = true; fehler = null
        lauf.launch {
            try {
                val o = JSONObject(withContext(Dispatchers.IO) { app.kern.aufnahmeVerbinden(adresse).await() })
                server = o.getString("name") to o.getString("version")
            } catch (e: CancellationException) { throw e } catch (e: Exception) { fehler = e.message ?: e.toString() }
            pruefe = false
        }
    }
    fun anmelden() {
        if (benutzer.isBlank() || laeuft) return
        laeuft = true; fehler = null
        lauf.launch {
            try { aufnehmen(withContext(Dispatchers.IO) { app.kern.aufnahmeAnmelden(benutzer, passwort).await() }) }
            catch (e: CancellationException) { throw e } catch (e: Exception) { fehler = e.message ?: e.toString() }
            laeuft = false
        }
    }
    LaunchedEffect(Unit) { if (voreingestellt != null) pruefen() }

    if (quick) {
        QuickConnectAnmeldung(app, neuerServer = true, zurueck = { quick = false }) { aufnehmen(it) }
        return
    }
    BackHandler { abbrechen() }

    Column(Modifier.fillMaxSize().background(Stil.grund)) {
        val s = server
        Unterseitenkopf(uebersetzt(if (voreingestellt != null) "Konto hinzufügen" else "Server hinzufügen")) { abbrechen() }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Stil.randAbstand).widthIn(max = Stil.formularbreite),
               verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (s == null) {
                Text(if (voreingestellt == null) uebersetzt("Die Adresse eines weiteren Jellyfin-Servers. Seine Konten kommen neben die, die du schon hast; auf der Profilseite wechselst du zwischen ihnen.")
                     else runCatching { java.net.URI(voreingestellt).host }.getOrNull() ?: voreingestellt,
                     style = Stil.koerper.copy(lineHeight = 21.sp), color = Stil.schriftLeise)
                if (voreingestellt == null || fehler != null) {
                    Box(Modifier.padding(top = 8.dp)) {
                        Eingabefeld(adresse, { adresse = it }, Icons.Outlined.Language, "tv.example.de", adresse = true) { pruefen() }
                    }
                    Hauptknopf(uebersetzt(if (pruefe) "Verbinden…" else "Verbinden"), freigegeben = adresse.isNotBlank() && !pruefe,
                               modifier = Modifier.padding(top = 6.dp)) { pruefen() }
                }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.size(7.dp).clip(CircleShape).background(Stil.akzent))
                    Text(uebersetzt("Verbunden · Jellyfin %@", s.second), style = TextStyle(fontSize = 12.sp), color = Stil.schriftSehrLeise)
                }
                Text(s.first, style = Stil.titel, color = Stil.schrift, modifier = Modifier.padding(bottom = 14.dp))
                Eingabefeld(benutzer, { benutzer = it }, Icons.Outlined.Person, uebersetzt("Benutzername"))
                Eingabefeld(passwort, { passwort = it }, Icons.Outlined.Lock, uebersetzt("Passwort"), geheim = true) { anmelden() }
                Hauptknopf(uebersetzt(if (laeuft) "Anmelden…" else "Anmelden"), freigegeben = benutzer.isNotBlank() && !laeuft,
                           modifier = Modifier.padding(top = 6.dp)) { anmelden() }
                Oder(Modifier.padding(top = 12.dp))
                Nebenknopf(Icons.Outlined.Tv, uebersetzt("Mit Quick Connect anmelden")) { quick = true }
            }
            fehler?.let { Text(it, style = Stil.klein, color = Stil.warnung, modifier = Modifier.padding(top = 6.dp)) }
        }
        Text(uebersetzt("Abbrechen"), style = TextStyle(fontSize = 13.sp, textAlign = TextAlign.Center), color = Stil.schriftSehrLeise,
             modifier = Modifier.fillMaxWidth().navigationBarsPadding().padding(bottom = 22.dp).antippen { abbrechen() })
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
            Text(vorn.name, style = TextStyle(fontSize = 19.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.2).sp), color = Stil.schrift, maxLines = 1)
            if (karte.aktiv) {
                (server?.first?.takeIf { it.isNotEmpty() } ?: app.servername.value)?.takeIf { it.isNotEmpty() }?.let {
                    Text(it, style = TextStyle(fontSize = 13.sp), color = Stil.schriftSehrLeise, maxLines = 1)
                }
                server?.second?.takeIf { it.isNotEmpty() }?.let {
                    Text(uebersetzt("Jellyfin %@", it), style = TextStyle(fontSize = 12.sp), color = Stil.schriftSehrLeise)
                }
            } else {
                Text(karte.host, style = TextStyle(fontSize = 13.sp), color = Stil.schriftSehrLeise, maxLines = 1)
                Text(uebersetzt("Antippen zum Wechseln"), style = TextStyle(fontSize = 12.sp), color = Stil.schriftSehrLeise)
            }
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
            Icon(Icons.Filled.Add, contentDescription = uebersetzt("Konto hinzufügen"), tint = Stil.schriftSehrLeise, modifier = Modifier.size(17.dp))
        }
    }
}
