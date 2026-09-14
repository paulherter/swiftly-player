package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.activity.compose.BackHandler
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt

/** Vorlage: `Bereich` in `Sources/Shared/Stil.swift` — Downloads nur, wenn eingeschaltet. */
enum class Bereich(val titel: String, val symbol: ImageVector) {
    Start("Start", Icons.Outlined.Home),
    Filme("Filme", Icons.Outlined.Movie),
    Serien("Serien", Icons.Outlined.Tv),
    Suche("Suche", Icons.Outlined.Search),
}

/** Ein Ort im Stapel eines Bereichs — `NavigationLink(value: Item)` auf iOS. */
data class Ziel(val id: String, val name: String, val typ: String)

/** Vorlage: `HauptView` in `Sources/Shared/HauptView.swift` — Inhalt oben, Leiste unten. */
@Composable
fun Hauptansicht(app: SwiftlyAnwendung) {
    var bereich by rememberSaveable { mutableStateOf(Bereich.Start) }
    // Jeder Bereich behaelt seinen Zustand (Scrollposition) beim Wechsel.
    val zustaende = androidx.compose.runtime.saveable.rememberSaveableStateHolder()
    // Sofort beim Ankommen, nicht erst in der Bibliothek — dort liess er den Kopf nachwachsen.
    androidx.compose.runtime.LaunchedEffect(Unit) { app.servernameLaden() }
    // Je Bereich ein eigener Stapel — `pfade[b.rawValue]` in `HauptView`.
    val stapel = remember { mutableStateMapOf<Bereich, List<Ziel>>() }
    val oben = stapel[bereich].orEmpty()
    // Die Wegeregel aus `zielorte`: Serie → Serienseite, Folge → ihre Staffel, sonst Titelseite.
    // Serien- und Folgenseite folgen; bis dahin oeffnen sie nichts.
    val oeffnen: (Ziel) -> Unit = { z ->
        if (z.typ != "Series" && z.typ != "Episode") stapel[bereich] = stapel[bereich].orEmpty() + z
    }
    val zurueck = { stapel[bereich] = stapel[bereich].orEmpty().dropLast(1) }
    BackHandler(enabled = oben.isNotEmpty(), onBack = zurueck)
    Box(Modifier.fillMaxSize()) {
    Column(Modifier.fillMaxSize().background(Stil.grund)) {
        Box(Modifier.weight(1f)) {
            val ziel = oben.lastOrNull()
            // Der Schluessel traegt Tiefe und Titel: jede Seite behaelt ihre Scrollstelle.
            zustaende.SaveableStateProvider("${bereich.name}/${oben.size}/${ziel?.id.orEmpty()}") {
            if (ziel != null) TitelSeite(app, ziel, oeffnen, zurueck)
            else when (bereich) {
                Bereich.Start -> StartSeite(app, oeffnen)
                Bereich.Filme -> BibliothekSeite(app, "movies", uebersetzt("Filme"),
                                                 listOf("alle", "angefangen", "merkliste", "ungesehen"), oeffnen)
                // Bei Serien hilft „ungesehen" wenig — dieselbe Liste wie auf iOS.
                Bereich.Serien -> BibliothekSeite(app, "tvshows", uebersetzt("Serien"),
                                                  listOf("alle", "angefangen", "merkliste"), oeffnen)
                // Die Suche folgt als eigene Seite.
                else -> Box(Modifier.fillMaxSize().statusBarsPadding().padding(Stil.randAbstand)) {
                    Text(uebersetzt(bereich.titel), style = Stil.titel, color = Stil.schrift)
                }
            }
            }
        }
        // Ein zweiter Tipp auf den Bereich, in dem man steht, fuehrt an seinen Anfang.
        // Nur auf den Anfangsseiten — auf iOS haengt `bereichsleiste()` an ihnen, nicht an tieferen.
        if (oben.isEmpty()) Leiste(bereich) { b -> if (b == bereich) stapel[b] = emptyList() else bereich = b }
    }
    // Ueber der Leiste, wie auf iOS: das Blatt haengt dort hinter `.bereichsleiste()`.
    Blattauflage(app)
    }
}

/** Vorlage: `Bereichsleiste` in `Stil.swift` — 54 hoch, Grund, Haarlinie, 10 pt, aktiv im Akzent. */
@Composable
private fun Leiste(aktiv: Bereich, waehlen: (Bereich) -> Unit) {
    Column(Modifier.fillMaxWidth().background(Stil.grund).navigationBarsPadding()) {
        Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.linie))
        Row(Modifier.fillMaxWidth().height(Stil.leisteHoehe).padding(top = 9.dp)) {
            Bereich.entries.forEach { b ->
                val an = b == aktiv
                val farbe = if (an) Stil.akzent else Color.White.copy(alpha = 0.42f)
                Column(
                    Modifier.weight(1f).clickable(remember { MutableInteractionSource() }, null) { waehlen(b) },
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(2.dp)
                ) {
                    Icon(b.symbol, contentDescription = null, tint = farbe, modifier = Modifier.size(26.dp))
                    Text(uebersetzt(b.titel), color = farbe,
                         style = TextStyle(fontSize = 10.sp, fontWeight = if (an) FontWeight.SemiBold else FontWeight.Medium))
                }
            }
        }
    }
}
