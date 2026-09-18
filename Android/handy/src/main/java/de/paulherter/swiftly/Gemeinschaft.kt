package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt

/**
 * Vorlage: `Discordhinweis` in `Sources/Shared` — **einmal je Installation**, nach dem fuenften zu
 * Ende geschauten Titel (`Gemeinschaft.anstoss` im Paket). Ein Blatt von unten, kein Dialog:
 * wegwischen reicht, danach kommt es nie wieder. Die Zeile im Profil bleibt.
 */
fun discordHinweisZeigen(app: SwiftlyAnwendung, context: android.content.Context) {
    app.blatt.value = Blattwunsch(uebersetzt("Swiftly hat einen Discord"), emptyList(), null,
        inhalt = { schliessen ->
            Text(uebersetzt("Da kannst du Fragen stellen und Fehler melden. Neue Builds stehen da auch zuerst."),
                 style = TextStyle(fontSize = 15.sp), color = Stil.schriftLeise,
                 modifier = Modifier.padding(horizontal = Stil.randAbstand).padding(top = 14.dp, bottom = 8.dp))
            Row(Modifier.fillMaxWidth().height(50.dp)
                    .druckzeile { schliessen(); app.adresseOeffnen(context, app.gemeinschaftAdresse("discord")) }
                    .padding(horizontal = Stil.randAbstand),
                verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.AutoMirrored.Filled.Chat, contentDescription = null, tint = Stil.schrift,
                     modifier = Modifier.width(20.dp).height(17.dp))
                Spacer(Modifier.width(14.dp))
                Text(uebersetzt("Discord beitreten"), style = TextStyle(fontSize = 16.sp), color = Stil.schrift)
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.linie))
            Row(Modifier.fillMaxWidth().height(54.dp).druckzeile(schliessen), horizontalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically) {
                Text(uebersetzt("Abbrechen"), style = TextStyle(fontSize = 16.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium),
                     color = Stil.schriftLeise)
            }
        }) { }
}
