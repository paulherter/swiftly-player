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
import de.paulherter.swiftly.shared.*

/**
 * Profile -> Open-source licenses (phone). Mirrors iPhone `LicensesView`.
 *
 * Top: the libVLC notice and the source links. Below: the components bundled in the Android
 * app, each tappable for the full text. Data comes from `LICENSES/` (`LicenseState`).
 */
@Composable
fun LicensesPage(open: (Destination) -> Unit, back: () -> Unit, app: SwiftlyApplication) {
    val context = LocalContext.current
    val inventory = remember { LicenseState.load(context) }
    SettingPage(translated("Open-Source-Lizenzen"), back) {
        Text(licenseInLine(), style = Theme.body, color = Theme.font,
             modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(bottom = 14.dp))
        if (inventory == null) {
            Text(translated("Die Lizenzliste fehlt in dieser Fassung. Du findest sie auf GitHub in THIRD-PARTY-NOTICES.md."),
                 style = Theme.body, color = Theme.fontQuiet, modifier = Modifier.padding(horizontal = Theme.edgeSpacing))
            return@SettingPage
        }
        GroupsTitle(translated("Quelle"))
        CardView {
            licenseSources(inventory).forEachIndexed { i, address ->
                if (i > 0) SeparatorLine()
                LicenseRow(address, null) { app.addressOpen(context, address) }
            }
            SeparatorLine()
            LicenseRow(translated("Quelltext und schriftliches Angebot"), null) {
                open(Destination("angebot", translated("Quelltext und schriftliches Angebot"), "Lizenzangebot"))
            }
        }
        Spacer(Modifier.height(22.dp))
        for ((title, list) in listOf("libVLC" to inventory.group("player"), translated("Weitere Bausteine") to inventory.group("app"))) {
            if (list.isEmpty()) continue
            GroupsTitle(title)
            CardView {
                list.forEachIndexed { i, b ->
                    if (i > 0) SeparatorLine()
                    LicenseRow(b.name, "${b.spdx} · ${b.version}") { open(Destination(b.id, b.name, "Lizenz")) }
                }
            }
            Spacer(Modifier.height(22.dp))
        }
    }
}

@Composable
private fun LicenseRow(title: String, under: String?, perform: () -> Unit) {
    Row(Modifier.tapOn(perform).fillMaxWidth().padding(horizontal = Theme.edgeSpacing, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Theme.listTitle, color = Theme.font)
            under?.let { Text(it, style = Theme.small, color = Theme.fontVeryQuiet) }
        }
        Symbol(Glyph.AngleRight, 13.dp, color = Theme.fontVeryQuiet, strength = Strength.Semibold)
    }
}

/** One component: details, a tappable source link and the full license text. */
@Composable
fun LicenseScreen(target: Destination, back: () -> Unit, app: SwiftlyApplication) {
    val context = LocalContext.current
    val b = remember { LicenseState.load(context)?.components?.firstOrNull { it.id == target.id } }
    SettingPage(target.name, back) {
        if (b == null) {
            Text(translated("Der Text fehlt in dieser Fassung."), style = Theme.body, color = Theme.fontQuiet,
                 modifier = Modifier.padding(horizontal = Theme.edgeSpacing))
            return@SettingPage
        }
        CardView {
            Column(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing, vertical = 14.dp),
                   verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Detail(translated("Fassung"), b.version)
                Detail(translated("Lizenz"), b.spdx)
                Detail(translated("Urheber"), b.author)
                Detail(translated("Quelle"), b.source, Modifier.tapOn { app.addressOpen(context, b.source) })
                b.note?.let { Text(it, style = Theme.small, color = Theme.fontQuiet) }
            }
        }
        Spacer(Modifier.height(22.dp))
        if (b.texts.isNotEmpty()) {
            GroupsTitle(translated("Lizenztext"))
            val text = remember(b.id) {
                b.texts.mapNotNull { LicenseState.text(context, it) }.joinToString("\n\n————————\n\n").ifEmpty { null }
            }
            SelectionContainer {
                Text(text ?: translated("Der Text fehlt in dieser Fassung."), style = Theme.small.copy(fontFamily = FontFamily.Monospace, lineHeight = 17.sp),
                     color = Theme.fontQuiet, modifier = Modifier.padding(horizontal = Theme.edgeSpacing))
            }
        }
    }
}

@Composable
private fun Detail(name: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(name, style = Theme.small, color = Theme.fontVeryQuiet)
        Text(value, style = Theme.body, color = Theme.font)
    }
}

/** Source code and written offer: wording from `components.json`, kept in English. */
@Composable
fun LicenseOfferingPage(back: () -> Unit) {
    val context = LocalContext.current
    val inventory = remember { LicenseState.load(context) }
    SettingPage(translated("Quelltext und schriftliches Angebot"), back) {
        Column(Modifier.padding(horizontal = Theme.edgeSpacing), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (inventory == null) {
                Text(translated("Der Text fehlt in dieser Fassung."), style = Theme.body, color = Theme.fontQuiet)
            } else {
                Text(inventory.offeringTitle, style = Theme.subpageTitle, color = Theme.font)
                for (s in inventory.offering) {
                    Spacer(Modifier.height(8.dp))
                    Text(s.title, style = Theme.rail, color = Theme.fontQuiet)
                    SelectionContainer {
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            s.paragraphs.forEach { Text(it, style = Theme.body, color = Theme.font) }
                        }
                    }
                }
            }
        }
    }
}
