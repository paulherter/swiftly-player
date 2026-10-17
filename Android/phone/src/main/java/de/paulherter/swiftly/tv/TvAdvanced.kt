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
import de.paulherter.swiftly.HeaderRow
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.asJson
import de.paulherter.swiftly.cleaned
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import de.paulherter.swiftly.headerRowOut

/**
 * Advanced settings on TV: custom headers for a service in front of the server.
 * Mirrors tvOS `TVAdvanced`; same rows (`Kopfzeile`) as on the phone with TV-sized fields and
 * buttons: name and value side by side, remove button behind them. Collapsed and empty by
 * default so nothing changes for anyone else. The value is masked.
 */
@Composable
fun TvAdvanced(rows: SnapshotStateList<HeaderRow>, expanded: Boolean = false, modifier: Modifier = Modifier) {
    var opened by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) { if (rows.isNotEmpty()) opened = true }
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        if (!expanded) {
            TvButton(translated("Erweitert"), if (opened) Glyph.AngleDown else Glyph.AngleRight,
                    symbolToText = true) { opened = !opened }
        }
        if (opened || expanded) {
            Text(translated("Für einen Dienst vor deinem Server, etwa Cloudflare Access, Authelia oder Pangolin. Swiftly schickt die Header nur an diese Adresse."),
                 style = TvTheme.small, color = Theme.fontVeryQuiet)
            rows.forEach { row ->
                androidx.compose.runtime.key(row.id) {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                            TvField(row.name, { row.name = it }, translated("Header-Name"), Modifier.weight(1f))
                            TvField(row.value, { row.value = it }, translated("Wert"), Modifier.weight(1f), secret = true)
                            TvButton(null, Glyph.Minus, description = translated("Entfernen")) { rows.removeAll { it.id == row.id } }
                        }
                        if (row.locked) Text(translated("Den setzt Swiftly selbst."), style = TvTheme.small, color = Theme.warning)
                    }
                }
            }
            TvButton(translated("Header hinzufügen"), Glyph.Plus) { rows.add(HeaderRow()) }
        }
    }
}

/** Edits the active server's custom headers (Profile -> Server). Mirrors `TVOwnHeadersPage`. */
@Composable
fun TvOwnHeadersPage(app: SwiftlyApplication, close: () -> Unit) {
    val server = app.activeServer()
    val rows = remember { mutableStateListOf<HeaderRow>().apply { addAll(headerRowOut(app.ownHeaders(server))) } }
    var secured by remember { mutableStateOf(Kern.ownHeadersCleaned(app.ownHeaders(server))) }
    val focus = firstFocus()
    val changed = rows.cleaned() != secured
    Box(Modifier.fillMaxSize().background(Theme.reason).verticalScroll(rememberScrollState()), contentAlignment = Alignment.TopCenter) {
        Column(Modifier.width(900.dp).padding(vertical = 80.dp)) {
            Text(translated("Eigene Header"), style = TvTheme.titleLarge, color = Theme.font)
            TvAdvanced(rows, expanded = true, modifier = Modifier.padding(top = 44.dp))
            Row(Modifier.padding(top = 44.dp), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                if (changed && server != null) {
                    TvButton(translated("Sichern")) {
                        app.ownHeadersSafe(rows.asJson(), server)
                        secured = Kern.ownHeadersCleaned(app.ownHeaders(server))
                        close()
                    }
                }
                TvButton(translated(if (changed) "Abbrechen" else "Fertig"), modifier = Modifier.focusRequester(focus)) { close() }
            }
        }
    }
}
