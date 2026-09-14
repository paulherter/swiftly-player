package de.paulherter.swiftly

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Language
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
import de.paulherter.swiftly.gemeinsam.Eingabefeld
import de.paulherter.swiftly.gemeinsam.Hauptknopf
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.Wortmarke
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** Vorlage: `ConnectView` in `Sources/Shared/RootView.swift`. */
@Composable
fun ServerSeite(app: SwiftlyAnwendung, verbunden: (String, String) -> Unit) {
    var adresse by remember { mutableStateOf(app.ablage.letzterServer ?: "") }
    var laeuft by remember { mutableStateOf(false) }
    var fehler by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    fun verbinden() {
        if (adresse.isBlank() || laeuft) return
        laeuft = true; fehler = null
        scope.launch {
            try {
                val json = withContext(Dispatchers.IO) { app.kern.verbinden(adresse).await() }
                val antwort = JSONObject(json)
                app.ablage.letzterServer = adresse
                verbunden(antwort.getString("name"), antwort.getString("version"))
            } catch (e: Throwable) {
                fehler = e.message ?: e.toString()
            } finally { laeuft = false }
        }
    }

    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Column(Modifier.widthIn(max = Stil.formularbreite), horizontalAlignment = Alignment.CenterHorizontally) {
            Box172 { Wortmarke(hoehe = 40.dp) }
            Text(uebersetzt("Wo steht dein Jellyfin-Server?"), style = Stil.koerper, color = Stil.schriftLeise,
                 modifier = Modifier.padding(top = 44.dp))
            Column(Modifier.padding(top = 18.dp)) {
                Eingabefeld(adresse, { adresse = it }, Icons.Outlined.Language, "tv.beispiel.de", adresse = true) { verbinden() }
            }
            Text(uebersetzt("Ohne https:// — das ergänzen wir."), style = Stil.klein, color = Stil.schriftSehrLeise,
                 modifier = Modifier.fillMaxWidth().padding(top = 9.dp, start = 2.dp))
            Hauptknopf(if (laeuft) uebersetzt("Verbinden…") else uebersetzt("Verbinden"),
                       freigegeben = adresse.isNotBlank() && !laeuft,
                       modifier = Modifier.padding(top = 22.dp)) { verbinden() }
            fehler?.let {
                Text(it, style = Stil.klein, color = Stil.warnung, textAlign = TextAlign.Center,
                     modifier = Modifier.padding(top = 14.dp))
            }
        }
    }
}

@Composable
private fun Box172(inhalt: @Composable () -> Unit) {
    Column(Modifier.padding(top = 172.dp)) { inhalt() }
}
