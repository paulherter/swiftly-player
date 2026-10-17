package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.*
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.shared.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Profile → Swiftly → Open-source licences (TV). Mirrors iPhone `LicensesView`, with the paths
 * of tvOS: list, one component with full text, the written offer.
 * Everything is **one** page with its own back rule: Back leads from the text to the list, and
 * there to the row it came from. Long texts sit in a focusable surface; Up and Down page through
 * it, and at the end focus passes on.
 */
private sealed interface LicensePage {
    data object ListKind : LicensePage
    data class Component(val id: String) : LicensePage
    data object Offering : LicensePage
}

@Composable
fun TvLicenses(app: SwiftlyApplication, close: () -> Unit) {
    val context = LocalContext.current
    val inventory = remember { LicenseState.load(context) }
    var page by remember { mutableStateOf<LicensePage>(LicensePage.ListKind) }
    // The row it came from; focus returns there.
    var last by rememberSaveable { mutableStateOf("angebot") }
    BackHandler { if (page == LicensePage.ListKind) close() else page = LicensePage.ListKind }
    Box(Modifier.fillMaxSize().background(Theme.reason)) {
        when (val s = page) {
            LicensePage.ListKind -> TvLicenseList(inventory, app, last) { identifier, target -> last = identifier; page = target }
            is LicensePage.Component -> {
                val b = inventory?.components?.firstOrNull { it.id == s.id }
                if (b == null) TvReadArea(translated("Open-Source-Lizenzen")) { Text(translated("Der Text fehlt in dieser Fassung."), style = TvTheme.body, color = Theme.fontQuiet) }
                else TvReadArea(b.name) {
                    Detail(translated("Fassung"), b.version)
                    Detail(translated("Lizenz"), b.spdx)
                    Detail(translated("Urheber"), b.author)
                    Detail(translated("Quelle"), b.source)
                    b.note?.let { Text(it, style = TvTheme.small, color = Theme.fontQuiet) }
                    if (b.texts.isNotEmpty()) {
                        Spacer(Modifier.height(10.dp))
                        Text(translated("Lizenztext"), style = TvTheme.rail, color = Theme.fontQuiet)
                        val text = remember(b.id) {
                            b.texts.mapNotNull { LicenseState.text(context, it) }.joinToString("\n\n————————\n\n").ifEmpty { null }
                        }
                        Text(text ?: translated("Der Text fehlt in dieser Fassung."),
                             style = TvTheme.small.copy(fontFamily = FontFamily.Monospace, lineHeight = 17.sp), color = Theme.fontQuiet)
                    }
                }
            }
            LicensePage.Offering -> TvReadArea(translated("Quelltext und schriftliches Angebot")) {
                if (inventory == null) {
                    Text(translated("Der Text fehlt in dieser Fassung."), style = TvTheme.body, color = Theme.fontQuiet)
                } else {
                    Text(inventory.offeringTitle, style = TvTheme.rail, color = Theme.font)
                    for (a in inventory.offering) {
                        Spacer(Modifier.height(6.dp))
                        Text(a.title, style = TvTheme.rail, color = Theme.fontQuiet)
                        a.paragraphs.forEach { Text(it, style = TvTheme.body, color = Theme.font) }
                    }
                }
            }
        }
    }
}

@Composable
private fun Detail(name: String, value: String) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(name, style = TvTheme.small, color = Theme.fontVeryQuiet)
        Text(value, style = TvTheme.body, color = Theme.font)
    }
}

@Composable
private fun TvLicenseList(inventory: LicenseState?, app: SwiftlyApplication, last: String,
                          select: (String, LicensePage) -> Unit) {
    val anchor = remember { mutableMapOf<String, FocusRequester>() }
    fun focus(k: String) = anchor.getOrPut(k) { FocusRequester() }
    // Back from the text: focus returns to the row it came from, the first one on first entry.
    LaunchedEffect(Unit) { delay(2 * TvTheme.focusDeadline); runCatching { focus(last).requestFocus() } }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())
            .padding(horizontal = TvTheme.edgePage, vertical = TvTheme.edgeTop).widthIn(max = 1000.dp)) {
        Text(translated("Open-Source-Lizenzen"), style = TvTheme.titleLarge, color = Theme.font)
        Spacer(Modifier.height(14.dp))
        Text(licenseInLine(), style = TvTheme.body, color = Theme.font)
        if (inventory == null) {
            Spacer(Modifier.height(14.dp))
            Text(translated("Die Lizenzliste fehlt in dieser Fassung. Du findest sie auf GitHub in THIRD-PARTY-NOTICES.md."),
                 style = TvTheme.body, color = Theme.fontQuiet)
            return@Column
        }
        // URLs to type in: a TV usually has no browser.
        Spacer(Modifier.height(10.dp))
        licenseSources(inventory).forEach { Text(it, style = TvTheme.tile, color = Theme.fontQuiet) }
        Spacer(Modifier.height(18.dp))
        Column(Modifier.clip(RoundedCornerShape(TvTheme.cornerTile)).background(Theme.area).padding(5.dp)) {
            LicenseRow(translated("Quelltext und schriftliches Angebot"), null, Modifier.focusRequester(focus("angebot"))) {
                select("angebot", LicensePage.Offering)
            }
            for (b in inventory.group("player") + inventory.group("app")) {
                LicenseRow(b.name, "${b.spdx} · ${b.version}", Modifier.focusRequester(focus(b.id))) {
                    select(b.id, LicensePage.Component(b.id))
                }
            }
        }
    }
}

@Composable
private fun LicenseRow(title: String, under: String?, modifier: Modifier, perform: () -> Unit) {
    FocusArea(modifier.fillMaxWidth(), magnifier = 1f, perform = perform) { focus ->
        Row(Modifier.fillMaxWidth().heightIn(min = TvTheme.rowsHeight).clip(RoundedCornerShape(TvTheme.corner))
                .background(if (focus) TvTheme.focusArea else androidx.compose.ui.graphics.Color.Transparent)
                .padding(horizontal = 13.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(title, style = TvTheme.body, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis,
                 modifier = Modifier.weight(1f))
            under?.let { Text(it, style = TvTheme.tile, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis,
                              modifier = Modifier.widthIn(max = 460.dp)) }
        }
    }
}

/**
 * A page to read: title fixed, the text below in a **focusable** surface. Down and Up page by 80
 * percent of the height; only at the end (or start) is the key no longer consumed. The focus
 * border shows that the surface takes the keys.
 */
@Composable
private fun TvReadArea(title: String, content: @Composable ColumnScope.() -> Unit) {
    val role = rememberScrollState()
    val run = rememberCoroutineScope()
    val focus = remember { FocusRequester() }
    var has by remember { mutableStateOf(false) }
    var height by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { delay(2 * TvTheme.focusDeadline); runCatching { focus.requestFocus() } }
    Column(Modifier.fillMaxSize().padding(horizontal = TvTheme.edgePage, vertical = TvTheme.edgeTop).widthIn(max = 1000.dp)) {
        Text(title, style = TvTheme.titleLarge, color = Theme.font, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(16.dp))
        Box(Modifier.weight(1f).fillMaxWidth().onSizeChanged { height = it.height }
                .clip(RoundedCornerShape(TvTheme.cornerTile))
                .border(2.dp, if (has) Theme.accent else androidx.compose.ui.graphics.Color.Transparent, RoundedCornerShape(TvTheme.cornerTile))
                .focusRequester(focus).onFocusChanged { has = it.isFocused }
                .onPreviewKeyEvent { e ->
                    val down = e.key == Key.DirectionDown || e.key == Key.PageDown
                    val up = e.key == Key.DirectionUp || e.key == Key.PageUp
                    val free = (down && role.value < role.maxValue) || (up && role.value > 0)
                    if (!free) return@onPreviewKeyEvent false
                    if (e.type == KeyEventType.KeyDown) run.launch { role.animateScrollBy((if (down) 1 else -1) * height * 0.8f) }
                    true
                }
                .focusable()
                .verticalScroll(role, enabled = false)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
        }
    }
}
