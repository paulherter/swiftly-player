package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.SwiftlyAnwendung
import de.paulherter.swiftly.fehlertext
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.Wortmarke
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

/**
 * Vorlage: `ServerView` und `AnmeldeView` in `Sources/tvOS/RootView.swift`, `QuickConnectView` in
 * `Sources/tvOS/QuickConnectView.swift`. Bisher liehen sich `TvAktivitaet` fuer alle drei Schritte
 * die Telefonseiten (`ServerSeite`, `AnmeldeSeite`, `QuickConnectAnmeldung` aus `KontenSeiten.kt`) —
 * mit `Eingabefeld`/`Hauptknopf`/`Nebenknopf` fuers Antippen, ohne Fokusring und ohne die tvOS-eigene
 * Reihenfolge (Felder zuerst, Quick Connect gleichrangig daneben statt vorweg). Diese Datei ersetzt
 * das durch echte TV-Seiten.
 *
 * **Ohne „Wer schaut?".** Diese Zeile mit den zuletzt angemeldeten Konten steht nur in
 * `Sources/Shared/RootView.swift` (iPhone/iPad) — `Sources/tvOS/RootView.swift` hat sie nicht, die
 * `AnmeldeView` dort ist nur Benutzername, Kennwort, Knopf. Sie hierher zu uebernehmen waere die
 * iPhone-Fassung nachgebaut, nicht die tvOS-Vorlage — deshalb fehlt sie hier bewusst.
 *
 * `TvFeld` (statt eines unsichtbaren `TextField` hinter eigener Zeichnung wie auf tvOS) steht in
 * `TvStil.kt`: Android zwingt einem `BasicTextField` keine eigene weisse Kapsel auf, der Umweg ist
 * dort unnoetig.
 */
@Composable
fun TvServerSeite(app: SwiftlyAnwendung, verbunden: (String, String) -> Unit) {
    var adresse by remember { mutableStateOf(app.ablage.letzterServer ?: "") }
    var laeuft by remember { mutableStateOf(false) }
    // Nach einer widerrufenen Anmeldung steht hier, warum man wieder auf der Serverwahl ist.
    var fehler by remember { mutableStateOf<String?>(app.anmeldehinweis.value.also { app.anmeldehinweis.value = null }) }
    val lauf = rememberCoroutineScope()
    val fokus = ersterFokus()

    fun verbinden() {
        if (adresse.isBlank() || laeuft) return
        laeuft = true; fehler = null
        lauf.launch {
            try {
                val antwort = JSONObject(withContext(Dispatchers.IO) { app.kern.verbinden(adresse).await() })
                app.ablage.letzterServer = adresse
                verbunden(antwort.getString("name"), antwort.getString("version"))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                fehler = fehlertext(app, e)
            } finally { laeuft = false }
        }
    }

    Box(Modifier.fillMaxSize().background(Stil.grund), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.widthIn(max = 480.dp)) {
            Wortmarke(hoehe = 36.dp)
            Text(uebersetzt("Wo steht dein Jellyfin-Server?"), style = TvStil.koerper, color = Stil.schriftLeise,
                 modifier = Modifier.padding(top = 28.dp))
            TvFeld(adresse, { adresse = it }, "tv.beispiel.de",
                   Modifier.padding(top = 16.dp).fillMaxWidth().focusRequester(fokus),
                   imeAction = ImeAction.Go, tastaturAktion = { verbinden() })
            Text(uebersetzt("Ohne https:// — das ergänzen wir."), style = TvStil.klein, color = Stil.schriftSehrLeise,
                 modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
            TvKnopf(uebersetzt(if (laeuft) "Verbinden…" else "Verbinden"), freigegeben = adresse.isNotBlank() && !laeuft,
                    modifier = Modifier.padding(top = 22.dp)) { verbinden() }
            // **Kein Ring, der den Knopf ersetzt** — GESTALTUNG, Abschnitt G, wie auf tvOS: der Knopf
            // behaelt seinen Platz und seine Beschriftung sagt „Verbinden…" statt sich zu verstecken.
            fehler?.let {
                Text(it, style = TvStil.koerper, color = Stil.warnung, textAlign = TextAlign.Center,
                     modifier = Modifier.widthIn(max = 560.dp).padding(top = 18.dp))
            }
        }
    }
}

/**
 * Vorlage: `AnmeldeView` — Benutzername, Kennwort, „Anmelden", darunter gleichrangig „Quick Connect"
 * und „Anderer Server". `weiteresKonto`: dieselbe Seite fuer ein zweites Konto (siehe `TvUnterseite`
 * in `TvHaupt.kt`, Ziel `WeiteresKonto`) — dann steht unten „Abbrechen" statt „Anderer Server", beide
 * rufen denselben `andererServer`, wie schon in der Telefonfassung (`AnmeldeSeite.kt`).
 */
@Composable
fun TvAnmeldeSeite(app: SwiftlyAnwendung, servername: String, fassung: String,
                   weiteresKonto: Boolean = false, andererServer: () -> Unit, angemeldet: () -> Unit) {
    var benutzer by remember { mutableStateOf("") }
    var kennwort by remember { mutableStateOf("") }
    var laeuft by remember { mutableStateOf(false) }
    var fehler by remember { mutableStateOf<String?>(null) }
    var quickConnect by remember { mutableStateOf(false) }
    val lauf = rememberCoroutineScope()
    val fokus = ersterFokus()

    fun anmelden() {
        if (benutzer.isBlank() || laeuft) return
        laeuft = true; fehler = null
        lauf.launch {
            try {
                val sitzung = withContext(Dispatchers.IO) { app.kern.anmelden(benutzer, kennwort).await() }
                app.sitzungAufnehmen(sitzung)
                angemeldet()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                fehler = fehlertext(app, e)
            } finally { laeuft = false }
        }
    }

    Box(Modifier.fillMaxSize().background(Stil.grund), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.widthIn(max = 480.dp)) {
            Wortmarke(hoehe = 30.dp)
            Text(servername, style = TvStil.reihe, color = Stil.schrift, modifier = Modifier.padding(top = 22.dp))
            if (fassung.isNotEmpty()) {
                Text(uebersetzt("Jellyfin %@", fassung), style = TvStil.klein, color = Stil.schriftSehrLeise,
                     modifier = Modifier.padding(top = 3.dp))
            }
            Column(Modifier.padding(top = 22.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                TvFeld(benutzer, { benutzer = it }, uebersetzt("Benutzername"), Modifier.fillMaxWidth().focusRequester(fokus))
                TvFeld(kennwort, { kennwort = it }, uebersetzt("Kennwort"), Modifier.fillMaxWidth(),
                       geheim = true, imeAction = ImeAction.Done, tastaturAktion = { anmelden() })
            }
            TvKnopf(uebersetzt(if (laeuft) "Anmelden…" else "Anmelden"), freigegeben = benutzer.isNotBlank() && !laeuft,
                    modifier = Modifier.padding(top = 20.dp)) { anmelden() }
            fehler?.let {
                Text(it, style = TvStil.koerper, color = Stil.warnung, textAlign = TextAlign.Center,
                     modifier = Modifier.widthIn(max = 560.dp).padding(top = 16.dp))
            }
            // Gleichrangig nebeneinander, kein Untermenue — auf dem Fernseher der bessere Weg als das
            // Kennwortfeld darueber, siehe `AnmeldeView`.
            Row(Modifier.padding(top = 30.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                TvKnopf(uebersetzt("Quick Connect")) { quickConnect = true }
                TvKnopf(uebersetzt(if (weiteresKonto) "Abbrechen" else "Anderer Server"), tun = andererServer)
            }
        }
        if (quickConnect) {
            TvQuickConnectSeite(app, schliessen = { quickConnect = false }) { sitzung ->
                app.sitzungAufnehmen(sitzung)
                quickConnect = false
                angemeldet()
            }
        }
    }
}

/**
 * Vorlage: `QuickConnectView` — der Code steht gross und in einzelnen Feldern, quer durchs Zimmer
 * lesbar; darunter die Anleitung in drei Schritten. Dieselbe Fassade wie in `QuickConnectAnmeldung`
 * (`KontenSeiten.kt`): `Kern.quickConnectFrist/-Starten/-Freigegeben/-Anmelden` — nur die Zeichnung
 * ist tvOS-eigen.
 */
@Composable
fun TvQuickConnectSeite(app: SwiftlyAnwendung, neuerServer: Boolean = false, schliessen: () -> Unit, angemeldet: (String) -> Unit) {
    val frist = remember { JSONArray(Kern.quickConnectFrist()) }
    val sekunden = frist.getInt(0)
    var code by remember { mutableStateOf<String?>(null) }
    var fehler by remember { mutableStateOf<String?>(null) }
    var rest by remember { mutableIntStateOf(0) }
    var lauf by remember { mutableIntStateOf(0) }
    BackHandler(onBack = schliessen)

    LaunchedEffect(lauf) {
        code = null; fehler = null
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
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            fehler = fehlertext(app, e)
        }
    }

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = 64.dp, bottom = 40.dp),
               horizontalAlignment = Alignment.CenterHorizontally) {
            Text(uebersetzt("Quick Connect"), style = TvStil.titelGross, color = Stil.schrift)
            Text(uebersetzt("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist."),
                 style = TvStil.koerper, color = Stil.schriftLeise, textAlign = TextAlign.Center,
                 modifier = Modifier.widthIn(max = 560.dp).padding(top = 12.dp))

            val c = code
            when {
                c != null -> {
                    Row(Modifier.padding(top = 32.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        c.forEach { zeichen ->
                            Box(Modifier.size(58.dp, 78.dp).clip(RoundedCornerShape(TvStil.ecke))
                                    .background(Stil.erhoeht).border(1.dp, Stil.rand, RoundedCornerShape(TvStil.ecke)),
                                contentAlignment = Alignment.Center) {
                                Text(zeichen.toString(), style = TextStyle(fontSize = 34.sp, fontWeight = FontWeight.Bold), color = Stil.schrift)
                            }
                        }
                    }
                    // Kein Ring: die Zeile selbst zaehlt schon herunter, wie auf tvOS.
                    Text(uebersetzt("Läuft ab in %lld:%@", rest / 60, "%02d".format(rest % 60)),
                         style = TvStil.klein, color = Stil.schriftSehrLeise, modifier = Modifier.padding(top = 16.dp))
                }
                fehler != null -> Text(fehler.orEmpty(), style = TvStil.koerper, color = Stil.warnung, textAlign = TextAlign.Center,
                                       modifier = Modifier.widthIn(max = 560.dp).padding(top = 32.dp))
                // Der Code kommt gleich; solange steht seine Form da.
                else -> Box(Modifier.padding(top = 40.dp).size(280.dp, 78.dp).clip(RoundedCornerShape(TvStil.ecke)).background(Stil.flaeche))
            }

            Column(Modifier.padding(top = 32.dp).widthIn(max = 460.dp)) {
                Text(uebersetzt("So gehts").uppercase(), style = TextStyle(fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.2.sp),
                     color = Stil.schriftSehrLeise)
                listOf("Jellyfin im Browser öffnen und anmelden", "Oben rechts aufs Profil, dann Quick Connect",
                       "Code eintippen — hier gehts dann von allein weiter").forEachIndexed { i, schritt ->
                    Row(Modifier.padding(top = 10.dp)) {
                        Text("${i + 1}", style = TvStil.koerper, color = Stil.schriftSehrLeise, modifier = Modifier.width(26.dp))
                        Text(uebersetzt(schritt), style = TvStil.koerper, color = Stil.schriftLeise)
                    }
                }
            }

            Row(Modifier.padding(top = 32.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                TvKnopf(uebersetzt("Neuer Code")) { lauf++ }
                TvKnopf(uebersetzt("Zurück"), tun = schliessen)
            }
        }
    }
}
