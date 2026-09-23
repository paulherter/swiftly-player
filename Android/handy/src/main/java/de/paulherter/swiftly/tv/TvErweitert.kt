package de.paulherter.swiftly.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.unit.dp
import androidx.compose.material3.Text
import de.paulherter.swiftly.Kopfzeile
import de.paulherter.swiftly.SwiftlyAnwendung
import de.paulherter.swiftly.alsJson
import de.paulherter.swiftly.bereinigt
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.kern.Kern
import de.paulherter.swiftly.kopfzeilenAus

/**
 * **„Erweitert" auf dem Fernseher** — eigene Header fuer einen Dienst vor dem Server (Issue #4).
 * Vorlage: `Sources/tvOS/TVErweitert.swift`; dieselben Zeilen (`Kopfzeile`) wie auf dem Telefon,
 * mit den Feldern und Knoepfen des Fernsehers: Name und Wert nebeneinander, dahinter das Minus.
 * Zugeklappt und leer, damit sich fuer niemanden sonst etwas aendert. Der Wert ist verdeckt.
 */
@Composable
fun TvErweitert(zeilen: SnapshotStateList<Kopfzeile>, aufgeklappt: Boolean = false, modifier: Modifier = Modifier) {
    var offen by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) { if (zeilen.isNotEmpty()) offen = true }
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        if (!aufgeklappt) {
            TvKnopf(uebersetzt("Erweitert"), if (offen) Zeichen.WinkelRunter else Zeichen.WinkelRechts,
                    symbolNachText = true) { offen = !offen }
        }
        if (offen || aufgeklappt) {
            Text(uebersetzt("Für einen Dienst vor deinem Server, etwa Cloudflare Access, Authelia oder Pangolin. Swiftly schickt die Header nur an diese Adresse."),
                 style = TvStil.klein, color = Stil.schriftSehrLeise)
            zeilen.forEach { zeile ->
                androidx.compose.runtime.key(zeile.id) {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                            TvFeld(zeile.name, { zeile.name = it }, uebersetzt("Header-Name"), Modifier.weight(1f))
                            TvFeld(zeile.wert, { zeile.wert = it }, uebersetzt("Wert"), Modifier.weight(1f), geheim = true)
                            TvKnopf(null, Zeichen.Minus) { zeilen.removeAll { it.id == zeile.id } }
                        }
                        if (zeile.gesperrt) Text(uebersetzt("Den setzt Swiftly selbst."), style = TvStil.klein, color = Stil.warnung)
                    }
                }
            }
            TvKnopf(uebersetzt("Header hinzufügen"), Zeichen.Plus) { zeilen.add(Kopfzeile()) }
        }
    }
}

/** Die eigenen Header des aktiven Servers bearbeiten — aus Profil → Server. Vorlage `TVEigeneKoepfeSeite`. */
@Composable
fun TvEigeneKoepfeSeite(app: SwiftlyAnwendung, schliessen: () -> Unit) {
    val server = app.aktiverServer()
    val zeilen = remember { mutableStateListOf<Kopfzeile>().apply { addAll(kopfzeilenAus(app.eigeneKoepfe(server))) } }
    var gesichert by remember { mutableStateOf(Kern.eigenkoepfeBereinigt(app.eigeneKoepfe(server))) }
    val fokus = ersterFokus()
    val geaendert = zeilen.bereinigt() != gesichert
    Box(Modifier.fillMaxSize().background(Stil.grund).verticalScroll(rememberScrollState()), contentAlignment = Alignment.TopCenter) {
        Column(Modifier.width(900.dp).padding(vertical = 80.dp)) {
            Text(uebersetzt("Eigene Header"), style = TvStil.titelGross, color = Stil.schrift)
            TvErweitert(zeilen, aufgeklappt = true, modifier = Modifier.padding(top = 44.dp))
            Row(Modifier.padding(top = 44.dp), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                if (geaendert && server != null) {
                    TvKnopf(uebersetzt("Sichern")) {
                        app.eigeneKoepfeSichern(zeilen.alsJson(), server)
                        gesichert = Kern.eigenkoepfeBereinigt(app.eigeneKoepfe(server))
                        schliessen()
                    }
                }
                TvKnopf(uebersetzt(if (geaendert) "Abbrechen" else "Fertig"), modifier = Modifier.focusRequester(fokus)) { schliessen() }
            }
        }
    }
}
