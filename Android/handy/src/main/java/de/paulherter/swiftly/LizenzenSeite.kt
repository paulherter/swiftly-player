package de.paulherter.swiftly

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.gemeinsam.*

/**
 * Profil → Open-Source-Lizenzen (Handy). Vorlage: `LizenzenView` auf iPhone.
 *
 * Oben der Satz zu libVLC und die Quellen, darunter die Bausteine, die in Android stecken, je
 * einer antippbar zum Volltext. Die Daten kommen aus `LICENSES/` (`Lizenzbestand`).
 */
@Composable
fun LizenzenSeite(oeffnen: (Ziel) -> Unit, zurueck: () -> Unit, app: SwiftlyAnwendung) {
    val kontext = LocalContext.current
    val bestand = remember { Lizenzbestand.laden(kontext) }
    Einstellungsseite(uebersetzt("Open-Source-Lizenzen"), zurueck) {
        Text(lizenzEinleitung(), style = Stil.koerper, color = Stil.schrift,
             modifier = Modifier.padding(horizontal = Stil.randAbstand).padding(bottom = 14.dp))
        if (bestand == null) {
            Text(uebersetzt("Die Lizenzliste fehlt in dieser Fassung. Du findest sie auf GitHub in THIRD-PARTY-NOTICES.md."),
                 style = Stil.koerper, color = Stil.schriftLeise, modifier = Modifier.padding(horizontal = Stil.randAbstand))
            return@Einstellungsseite
        }
        Gruppentitel(uebersetzt("Quelle"))
        Karte {
            lizenzQuellen(bestand).forEachIndexed { i, adresse ->
                if (i > 0) Trennlinie()
                Lizenzzeile(adresse, null) { app.adresseOeffnen(kontext, adresse) }
            }
            Trennlinie()
            Lizenzzeile(uebersetzt("Quelltext und schriftliches Angebot"), null) {
                oeffnen(Ziel("angebot", uebersetzt("Quelltext und schriftliches Angebot"), "Lizenzangebot"))
            }
        }
        Spacer(Modifier.height(22.dp))
        for ((titel, liste) in listOf("libVLC" to bestand.gruppe("player"), uebersetzt("Weitere Bausteine") to bestand.gruppe("app"))) {
            if (liste.isEmpty()) continue
            Gruppentitel(titel)
            Karte {
                liste.forEachIndexed { i, b ->
                    if (i > 0) Trennlinie()
                    Lizenzzeile(b.name, "${b.spdx} · ${b.version}") { oeffnen(Ziel(b.id, b.name, "Lizenz")) }
                }
            }
            Spacer(Modifier.height(22.dp))
        }
    }
}

@Composable
private fun Lizenzzeile(titel: String, unter: String?, tun: () -> Unit) {
    Row(Modifier.antippen(tun).fillMaxWidth().padding(horizontal = Stil.randAbstand, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(titel, style = Stil.listentitel, color = Stil.schrift)
            unter?.let { Text(it, style = Stil.klein, color = Stil.schriftSehrLeise) }
        }
        Symbol(Zeichen.WinkelRechts, 13.dp, farbe = Stil.schriftSehrLeise, staerke = Staerke.Halbfett)
    }
}

/** Ein Baustein: Angaben, Quelle zum Antippen und der Volltext der Lizenz. */
@Composable
fun LizenzSeite(ziel: Ziel, zurueck: () -> Unit, app: SwiftlyAnwendung) {
    val kontext = LocalContext.current
    val b = remember { Lizenzbestand.laden(kontext)?.bausteine?.firstOrNull { it.id == ziel.id } }
    Einstellungsseite(ziel.name, zurueck) {
        if (b == null) {
            Text(uebersetzt("Der Text fehlt in dieser Fassung."), style = Stil.koerper, color = Stil.schriftLeise,
                 modifier = Modifier.padding(horizontal = Stil.randAbstand))
            return@Einstellungsseite
        }
        Karte {
            Column(Modifier.fillMaxWidth().padding(horizontal = Stil.randAbstand, vertical = 14.dp),
                   verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Angabe(uebersetzt("Fassung"), b.version)
                Angabe(uebersetzt("Lizenz"), b.spdx)
                Angabe(uebersetzt("Urheber"), b.urheber)
                Angabe(uebersetzt("Quelle"), b.quelle, Modifier.antippen { app.adresseOeffnen(kontext, b.quelle) })
                b.notiz?.let { Text(it, style = Stil.klein, color = Stil.schriftLeise) }
            }
        }
        Spacer(Modifier.height(22.dp))
        if (b.texte.isNotEmpty()) {
            Gruppentitel(uebersetzt("Lizenztext"))
            val text = remember(b.id) {
                b.texte.mapNotNull { Lizenzbestand.text(kontext, it) }.joinToString("\n\n————————\n\n").ifEmpty { null }
            }
            SelectionContainer {
                Text(text ?: uebersetzt("Der Text fehlt in dieser Fassung."), style = Stil.klein.copy(fontFamily = FontFamily.Monospace, lineHeight = 17.sp),
                     color = Stil.schriftLeise, modifier = Modifier.padding(horizontal = Stil.randAbstand))
            }
        }
    }
}

@Composable
private fun Angabe(name: String, wert: String, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(name, style = Stil.klein, color = Stil.schriftSehrLeise)
        Text(wert, style = Stil.koerper, color = Stil.schrift)
    }
}

/** Quelltext und schriftliches Angebot — der Wortlaut aus `bausteine.json`, Englisch belassen. */
@Composable
fun LizenzangebotSeite(zurueck: () -> Unit) {
    val kontext = LocalContext.current
    val bestand = remember { Lizenzbestand.laden(kontext) }
    Einstellungsseite(uebersetzt("Quelltext und schriftliches Angebot"), zurueck) {
        Column(Modifier.padding(horizontal = Stil.randAbstand), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (bestand == null) {
                Text(uebersetzt("Der Text fehlt in dieser Fassung."), style = Stil.koerper, color = Stil.schriftLeise)
            } else {
                Text(bestand.angebotTitel, style = Stil.unterseitentitel, color = Stil.schrift)
                for (s in bestand.angebot) {
                    Spacer(Modifier.height(8.dp))
                    Text(s.titel, style = Stil.reihe, color = Stil.schriftLeise)
                    SelectionContainer {
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            s.absaetze.forEach { Text(it, style = Stil.koerper, color = Stil.schrift) }
                        }
                    }
                }
            }
        }
    }
}
