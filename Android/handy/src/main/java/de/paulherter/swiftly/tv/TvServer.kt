package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.*
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Vorlage: `ServerAufnahmeView` auf tvOS — ein weiterer Jellyfin-Server. **Quick Connect zuerst**,
 * Name und Passwort nur als Ausweg — dieselbe Abwaegung wie bei `TvAnmeldeSeite`
 * (`TvAnmeldung.kt`), deren `TvFeld`/`TvKnopf`/`TvQuickConnectSeite`-Bausteine diese Seite auch
 * traegt. Die laufende Sitzung bleibt unberuehrt: `aufnahmeVerbinden`/`aufnahmeAnmelden` arbeiten
 * an einem eigenen Client, genau wie in `ServerAufnahmeSeite` auf dem Telefon — dieselben
 * Kern-Funktionen, keine eigene Logik. `voreingestellt`: von „Konto hinzufügen" an einer fremden
 * Serverkarte im Profil (`TvProfil.kt`, Abteil Konto).
 */
@Composable
fun TvServerAufnahme(app: SwiftlyAnwendung, voreingestellt: String?, zurueck: () -> Unit) {
    var adresse by remember { mutableStateOf(voreingestellt.orEmpty()) }
    var server by remember { mutableStateOf<Pair<String, String>?>(null) }
    var pruefe by remember { mutableStateOf(false) }
    var perCode by remember { mutableStateOf(true) }
    var benutzer by remember { mutableStateOf("") }
    var passwort by remember { mutableStateOf("") }
    var laeuft by remember { mutableStateOf(false) }
    var fehler by remember { mutableStateOf<String?>(null) }
    val lauf = rememberCoroutineScope()

    fun abbrechen() { app.kern.aufnahmeAbbrechen(); zurueck() }
    fun aufnehmen(sitzung: String) { app.kern.aufnahmeAbbrechen(); app.sitzungAufnehmen(sitzung); zurueck() }
    fun pruefen() {
        if (adresse.isBlank() || pruefe) return
        pruefe = true; fehler = null
        lauf.launch {
            try {
                val o = JSONObject(withContext(Dispatchers.IO) { app.kern.aufnahmeVerbinden(adresse).await() })
                server = o.getString("name") to o.getString("version")
            } catch (x: CancellationException) { throw x } catch (x: Exception) { fehler = fehlertext(app, x) }
            pruefe = false
        }
    }
    fun anmelden() {
        if (benutzer.isBlank() || laeuft) return
        laeuft = true; fehler = null
        lauf.launch {
            try { aufnehmen(withContext(Dispatchers.IO) { app.kern.aufnahmeAnmelden(benutzer, passwort).await() }) }
            catch (x: CancellationException) { throw x } catch (x: Exception) { fehler = fehlertext(app, x) }
            laeuft = false
        }
    }
    LaunchedEffect(Unit) { if (voreingestellt != null) pruefen() }

    val s = server
    // Sobald der Server steht, uebernimmt der gemeinsame Code-Bildschirm — Ruecksprung von dort
    // schaltet nur auf das Formular um, nicht aus der ganzen Seite heraus.
    if (s != null && perCode) {
        TvQuickConnectSeite(app, neuerServer = true, schliessen = { perCode = false }) { aufnehmen(it) }
        return
    }
    BackHandler { abbrechen() }
    val feld = ersterFokus()

    Box(Modifier.fillMaxSize().background(Stil.grund), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.widthIn(max = 480.dp)) {
            Text(uebersetzt(if (voreingestellt != null) "Konto hinzufügen" else "Server hinzufügen"), style = TvStil.titelGross, color = Stil.schrift)
            if (s == null) {
                Text(uebersetzt("Ein zweiter Jellyfin mit eigenen Konten. Beide bleiben angemeldet; im Profil wechselst du zwischen ihnen."),
                     style = TvStil.koerper, color = Stil.schriftLeise, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 16.dp))
                TvFeld(adresse, { adresse = it }, "tv.example.de", Modifier.padding(top = 22.dp).fillMaxWidth().focusRequester(feld),
                       imeAction = ImeAction.Go, tastaturAktion = { pruefen() })
                Text(uebersetzt("https:// kannst du weglassen."), style = TvStil.klein, color = Stil.schriftSehrLeise,
                     modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
                TvKnopf(uebersetzt(if (pruefe) "Verbinden…" else "Weiter"), freigegeben = adresse.isNotBlank() && !pruefe,
                        modifier = Modifier.padding(top = 20.dp)) { pruefen() }
            } else {
                Text(uebersetzt("Verbunden · Jellyfin %@", s.second), style = TvStil.klein, color = Stil.schriftSehrLeise, modifier = Modifier.padding(top = 16.dp))
                Text(s.first, style = TvStil.reihe, color = Stil.schrift, modifier = Modifier.padding(top = 4.dp))
                Column(Modifier.padding(top = 22.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    TvFeld(benutzer, { benutzer = it }, uebersetzt("Benutzername"), Modifier.fillMaxWidth().focusRequester(feld))
                    TvFeld(passwort, { passwort = it }, uebersetzt("Passwort"), Modifier.fillMaxWidth(),
                           geheim = true, imeAction = ImeAction.Done, tastaturAktion = { anmelden() })
                }
                TvKnopf(uebersetzt(if (laeuft) "Anmelden…" else "Anmelden"), freigegeben = benutzer.isNotBlank() && !laeuft,
                        modifier = Modifier.padding(top = 20.dp)) { anmelden() }
                TvKnopf(uebersetzt("Lieber Quick Connect"), modifier = Modifier.padding(top = 14.dp)) { perCode = true }
            }
            fehler?.let {
                Text(it, style = TvStil.koerper, color = Stil.warnung, textAlign = TextAlign.Center,
                     modifier = Modifier.widthIn(max = 560.dp).padding(top = 16.dp))
            }
        }
    }
}
