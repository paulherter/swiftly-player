package de.paulherter.swiftly

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.foundation.layout.heightIn
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated

/**
 * Mirrors `Discordhinweis` in `Sources/Shared`: **once per installation**, after the fifth title
 * watched to the end (`Community.kickoff` in the package). A sheet from below, not a dialog:
 * swiping it away is enough, and it never comes back. The row in the profile stays.
 */
fun discordHintShow(app: SwiftlyApplication, context: android.content.Context) {
    app.sheet.value = SheetRequest(translated("Swiftly hat einen Discord"), emptyList(), null,
        content = { close ->
            Text(translated("Da kannst du Fragen stellen und Fehler melden. Neue Builds stehen da auch zuerst."),
                 style = Theme.body, color = Theme.fontQuiet,
                 modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 14.dp, bottom = 8.dp))
            // Row in the sheet: 17 at >= 52, like every other.
            Row(Modifier.fillMaxWidth().heightIn(min = 52.dp)
                    .pressRow { close(); app.addressOpen(context, app.communityAddress("discord")) }
                    .padding(horizontal = Theme.edgeSpacing),
                verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.width(Theme.characterColumn), contentAlignment = Alignment.Center) { Symbol(Glyph.Conversation, 17.dp, color = Theme.font) }
                Spacer(Modifier.width(14.dp))
                Text(translated("Discord beitreten"), style = Theme.categoryLarge.copy(fontWeight = FontWeight.Normal), color = Theme.font)
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))
            Row(Modifier.fillMaxWidth().heightIn(min = 54.dp).pressRow(close), horizontalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically) {
                Text(translated("Abbrechen"), style = Theme.categoryLarge.copy(fontWeight = FontWeight.Normal),
                     color = Theme.fontQuiet)
            }
        }) { }
}
