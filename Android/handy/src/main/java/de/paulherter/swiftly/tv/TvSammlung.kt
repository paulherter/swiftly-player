package de.paulherter.swiftly.tv

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.*
import de.paulherter.swiftly.gemeinsam.Staerke
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.launch

// MARK: Sammlungen auf dem Fernseher — Vorlage `Sources/tvOS/BibliothekView.swift`, `Titelreihen.swift`

/**
 * Die Kachel einer Sammlung im Gitter — `Kachelinhalt` mit `unterzeile` („3 Filme") und `ersatz`:
 * ohne eigenes Bild das Mosaik aus den ersten Plakaten (`Sammlungsmosaik`, Plakate in halber
 * Kachelgroesse wie auf tvOS).
 */
@Composable
fun TvSammlungKachel(app: SwiftlyAnwendung, s: Sammlungskachel, art: String, modifier: Modifier = Modifier, tun: () -> Unit) {
    TvKachel(s.plakat, s.name, sammlungsanzahl(art, s.anzahl), modifier = modifier,
             ersatz = if (s.plakat == null) ({
                 Sammlungsmosaik(app, s.id, art, 300, Modifier.fillMaxSize(), ecke = TvStil.eckeKachel, zeichen = false)
             }) else null, tun = tun)
}

/**
 * Vorlage: `BibliothekView(sammlung:)` auf tvOS. **Die Sammlungsseite ist eine Bibliotheksseite** —
 * wie am Telefon: Name, Filter und Sortierung, Raster; sortiert nach Jahr, aufsteigend, nichts davon
 * gemerkt. Der Name steht darueber, deshalb beginnt die Seite wie die Genreseite.
 */
@Composable
fun TvSammlung(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit) {
    val stand = remember(ziel.id, ziel.rolle) { Sammlungsstand(ziel.id, ziel.rolle) }
    val lauf = rememberCoroutineScope()
    LaunchedEffect(stand, stand.sortierung, stand.filter) { stand.laden(app.kern) }
    val fokus = ersterFokus(!stand.laedt)
    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        TvRaster(stand.items, { lauf.launch { stand.nachladen(app.kern) } }, fokus, oeffnen, laedt = stand.laedt, mitUnterzeile = false, kopf = {
            Column(Modifier.padding(bottom = 10.dp)) {
                // Der Name kommt vom Server und wird nicht uebersetzt — wie der Titel der Genreseite.
                Text(ziel.name, style = TvStil.reihe, color = Stil.schrift, maxLines = 1,
                     modifier = Modifier.padding(top = 48.dp, bottom = TvStil.titelAbstand))
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    stand.filterwahl.forEach { f -> TvChip(Wahlen.text(Wahlen.filter, f), stand.filter == f) { stand.filter = f } }
                    Spacer(Modifier.weight(1f))
                    if (stand.gesamt > 0) Text(uebersetzt("%lld · sortiert nach", stand.gesamt), style = TvStil.klein, color = Stil.schriftLeise)
                    TvKapsel(Wahlen.text(Wahlen.sortierungen, stand.sortierung)) {
                        app.blatt.value = Blattwunsch(uebersetzt("Sortieren"), Wahlen.sortierungen, stand.sortierung) { stand.sortierung = it }
                    }
                }
                if (stand.gestoert) TvStoerung(app, erneut = { lauf.launch { stand.laden(app.kern) } })
                else if (!stand.laedt && stand.items.isEmpty()) {
                    if (stand.filter == "alle") TvLeer(uebersetzt("Hier ist noch nichts"), uebersetzt("Sobald in dieser Sammlung etwas liegt, taucht es hier auf."),
                        symbol = Zeichen.Ablage, knopf = uebersetzt("Aktualisieren") to { lauf.launch { stand.laden(app.kern) } })
                    else TvLeer(uebersetzt("Nichts gefunden"), uebersetzt("Unter diesem Filter liegt gerade nichts."),
                        symbol = Zeichen.Filter, knopf = uebersetzt("Filter zurücksetzen") to { stand.filter = "alle" })
                }
            }
        })
    }
}

/**
 * Vorlage: `Sammlungsreihe` in `Titelreihen.swift` — „Teil der Sammlung" auf der Filmseite, ueber
 * „Aehnliche Filme". **Der Weg auf die Sammlungsseite ist eine Kapsel neben der Ueberschrift**: auf
 * dem Fernseher ist eine Ueberschrift kein Fokusziel, und ein Weg, den der Fokus nicht erreicht, ist
 * keiner. Die Kapsel traegt den Namen der Sammlung und den Pfeil nach rechts (`KapselStil(pfeil:)`).
 * Hoechstens zwei Reihen, ohne den offenen Titel; fehlt die Sammlung, fehlt die Reihe.
 *
 * `abschnitt`: der Modifier je Reihe aus der Seite (Einblenden, abschnittsweises Scrollen).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TvSammlungsreihe(app: SwiftlyAnwendung, titelId: String, oeffnen: (Ziel) -> Unit, abschnitt: (Int) -> Modifier = { Modifier }) {
    var reihen by remember(titelId) { mutableStateOf<List<Sammlungsreihendaten>>(emptyList()) }
    LaunchedEffect(titelId) { reihen = sammlungsreihenLaden(app.kern, titelId) }
    reihen.forEachIndexed { i, reihe ->
        Column(abschnitt(i).padding(top = TvStil.reihenAbstand - TvStil.reihenLuft)) {
            Row(Modifier.padding(start = TvStil.randSeite, bottom = TvStil.titelAbstand - TvStil.reihenLuft),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(uebersetzt("Teil der Sammlung"), style = TvStil.reihe, color = Stil.schrift, maxLines = 1)
                TvKapsel(reihe.name, pfeil = Zeichen.WinkelRechts) { oeffnen(sammlungsziel(reihe.id, reihe.name, reihe.art)) }
            }
            CompositionLocalProvider(LocalBringIntoViewSpec provides TvReihenBringIntoView) {
                LazyRow(contentPadding = PaddingValues(horizontal = TvStil.randSeite, vertical = TvStil.reihenLuft),
                        horizontalArrangement = Arrangement.spacedBy(TvStil.kachelAbstand)) {
                    items(reihe.titel, key = { it.id }) { k -> TvKachel(k.plakat, k.titel, k.unterzeile) { oeffnen(Ziel(k.id, k.titel, k.typ)) } }
                }
            }
        }
    }
}

