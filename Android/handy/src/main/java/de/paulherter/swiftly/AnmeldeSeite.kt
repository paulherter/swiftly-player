package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.gemeinsam.Eingabefeld
import de.paulherter.swiftly.gemeinsam.Hauptknopf
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Vorlage: `LoginView` in `Sources/Shared/RootView.swift` — Name und Passwort, darunter Quick Connect.
 *
 * `weiteresKonto`: dieselbe Seite fuer ein zweites Konto am verbundenen Server. Unten steht dann
 * „Abbrechen" statt „Anderer Server", und die laufende Sitzung bleibt, bis die neue steht.
 */
@Composable
fun AnmeldeSeite(app: SwiftlyAnwendung, servername: String, fassung: String,
                 andererServer: () -> Unit, weiteresKonto: Boolean = false, angemeldet: () -> Unit) {
    var benutzer by remember { mutableStateOf("") }
    var passwort by remember { mutableStateOf("") }
    var laeuft by remember { mutableStateOf(false) }
    var fehler by remember { mutableStateOf<String?>(null) }
    var quick by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    if (quick) {
        QuickConnectAnmeldung(app, neuerServer = false, zurueck = { quick = false }) { sitzung ->
            app.sitzungAufnehmen(sitzung)
            angemeldet()
        }
        return
    }

    fun anmelden() {
        if (benutzer.isBlank() || laeuft) return
        laeuft = true; fehler = null
        scope.launch {
            try {
                val sitzung = withContext(Dispatchers.IO) { app.kern.anmelden(benutzer, passwort).await() }
                app.sitzungAufnehmen(sitzung)
                angemeldet()
            } catch (e: Throwable) {
                fehler = e.message ?: e.toString()
            } finally { laeuft = false }
        }
    }

    Box(Modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Column(Modifier.widthIn(max = Stil.formularbreite).fillMaxWidth()) {
                Column(Modifier.padding(top = 48.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (fassung.isNotEmpty()) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Box(Modifier.size(7.dp).background(Stil.akzent, CircleShape))
                            Text(uebersetzt("Verbunden · Jellyfin %@", fassung), style = Stil.klein.copy(fontSize = 12.sp), color = Stil.schriftSehrLeise)
                        }
                    }
                    Text(servername, style = Stil.titel, color = Stil.schrift)
                }
                Column(Modifier.padding(top = 28.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Eingabefeld(benutzer, { benutzer = it }, Icons.Outlined.Person, uebersetzt("Benutzername"))
                    Eingabefeld(passwort, { passwort = it }, Icons.Outlined.Lock, uebersetzt("Passwort"), geheim = true) { anmelden() }
                    Hauptknopf(if (laeuft) uebersetzt("Anmelden…") else uebersetzt("Anmelden"),
                               freigegeben = benutzer.isNotBlank() && !laeuft,
                               modifier = Modifier.padding(top = 10.dp)) { anmelden() }
                    fehler?.let {
                        Text(it, style = Stil.klein, color = Stil.warnung, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                    }
                    // Immer da — wie auf iOS, das nicht vorher fragt, ob der Server es kann; sagt er nein,
                    // steht das auf der Quick-Connect-Seite.
                    Oder(Modifier.padding(top = 12.dp))
                    Nebenknopf(Icons.Outlined.Tv, uebersetzt("Mit Quick Connect anmelden")) { quick = true }
                }
            }
        }
        Text(uebersetzt(if (weiteresKonto) "Abbrechen" else "Anderer Server"), style = Stil.klein.copy(fontSize = 13.sp),
             color = Stil.schriftSehrLeise,
             modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 22.dp).antippen(andererServer))
    }
}
