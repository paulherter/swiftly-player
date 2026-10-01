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
import de.paulherter.swiftly.SwiftlyAnwendung
import de.paulherter.swiftly.gemeinsam.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Profil → Swiftly → Open-Source-Lizenzen (Fernseher). Vorlage: `LizenzenView` auf iPhone, mit
 * den Wegen von tvOS: Liste, ein Baustein mit Volltext, das schriftliche Angebot.
 *
 * Alles steht in **einer** Seite mit eigener Rueckwaertsregel: Zurueck fuehrt vom Text zur
 * Liste und dort auf die Zeile, von der man kam. Lange Texte liegen in einer fokussierbaren
 * Flaeche; Hoch und Runter blaettern dort seitenweise, am Ende gibt der Fokus nach.
 */
private sealed interface Lizenzseite {
    data object Liste : Lizenzseite
    data class Baustein(val id: String) : Lizenzseite
    data object Angebot : Lizenzseite
}

@Composable
fun TvLizenzen(app: SwiftlyAnwendung, schliessen: () -> Unit) {
    val kontext = LocalContext.current
    val bestand = remember { Lizenzbestand.laden(kontext) }
    var seite by remember { mutableStateOf<Lizenzseite>(Lizenzseite.Liste) }
    // Die Zeile, von der man kam: dorthin kehrt der Fokus zurueck.
    var letzte by rememberSaveable { mutableStateOf("angebot") }
    BackHandler { if (seite == Lizenzseite.Liste) schliessen() else seite = Lizenzseite.Liste }
    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        when (val s = seite) {
            Lizenzseite.Liste -> TvLizenzliste(bestand, app, letzte) { kennung, ziel -> letzte = kennung; seite = ziel }
            is Lizenzseite.Baustein -> {
                val b = bestand?.bausteine?.firstOrNull { it.id == s.id }
                if (b == null) TvLeseflaeche(uebersetzt("Open-Source-Lizenzen")) { Text(uebersetzt("Der Text fehlt in dieser Fassung."), style = TvStil.koerper, color = Stil.schriftLeise) }
                else TvLeseflaeche(b.name) {
                    Angabe(uebersetzt("Fassung"), b.version)
                    Angabe(uebersetzt("Lizenz"), b.spdx)
                    Angabe(uebersetzt("Urheber"), b.urheber)
                    Angabe(uebersetzt("Quelle"), b.quelle)
                    b.notiz?.let { Text(it, style = TvStil.klein, color = Stil.schriftLeise) }
                    if (b.texte.isNotEmpty()) {
                        Spacer(Modifier.height(10.dp))
                        Text(uebersetzt("Lizenztext"), style = TvStil.reihe, color = Stil.schriftLeise)
                        val text = remember(b.id) {
                            b.texte.mapNotNull { Lizenzbestand.text(kontext, it) }.joinToString("\n\n————————\n\n").ifEmpty { null }
                        }
                        Text(text ?: uebersetzt("Der Text fehlt in dieser Fassung."),
                             style = TvStil.klein.copy(fontFamily = FontFamily.Monospace, lineHeight = 17.sp), color = Stil.schriftLeise)
                    }
                }
            }
            Lizenzseite.Angebot -> TvLeseflaeche(uebersetzt("Quelltext und schriftliches Angebot")) {
                if (bestand == null) {
                    Text(uebersetzt("Der Text fehlt in dieser Fassung."), style = TvStil.koerper, color = Stil.schriftLeise)
                } else {
                    Text(bestand.angebotTitel, style = TvStil.reihe, color = Stil.schrift)
                    for (a in bestand.angebot) {
                        Spacer(Modifier.height(6.dp))
                        Text(a.titel, style = TvStil.reihe, color = Stil.schriftLeise)
                        a.absaetze.forEach { Text(it, style = TvStil.koerper, color = Stil.schrift) }
                    }
                }
            }
        }
    }
}

@Composable
private fun Angabe(name: String, wert: String) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(name, style = TvStil.klein, color = Stil.schriftSehrLeise)
        Text(wert, style = TvStil.koerper, color = Stil.schrift)
    }
}

@Composable
private fun TvLizenzliste(bestand: Lizenzbestand?, app: SwiftlyAnwendung, letzte: String,
                          waehlen: (String, Lizenzseite) -> Unit) {
    val anker = remember { mutableMapOf<String, FocusRequester>() }
    fun fokus(k: String) = anker.getOrPut(k) { FocusRequester() }
    // Zurueck aus dem Text: der Fokus kehrt auf die Zeile zurueck, von der man kam; beim ersten Mal auf die erste.
    LaunchedEffect(Unit) { delay(2 * TvStil.fokusFrist); runCatching { fokus(letzte).requestFocus() } }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())
            .padding(horizontal = TvStil.randSeite, vertical = TvStil.randOben).widthIn(max = 1000.dp)) {
        Text(uebersetzt("Open-Source-Lizenzen"), style = TvStil.titelGross, color = Stil.schrift)
        Spacer(Modifier.height(14.dp))
        Text(lizenzEinleitung(), style = TvStil.koerper, color = Stil.schrift)
        if (bestand == null) {
            Spacer(Modifier.height(14.dp))
            Text(uebersetzt("Die Lizenzliste fehlt in dieser Fassung. Du findest sie auf GitHub in THIRD-PARTY-NOTICES.md."),
                 style = TvStil.koerper, color = Stil.schriftLeise)
            return@Column
        }
        // Adressen zum Abtippen: einen Browser gibt es auf dem Fernseher meist nicht.
        Spacer(Modifier.height(10.dp))
        lizenzQuellen(bestand).forEach { Text(it, style = TvStil.kachel, color = Stil.schriftLeise) }
        Spacer(Modifier.height(18.dp))
        Column(Modifier.clip(RoundedCornerShape(TvStil.eckeKachel)).background(Stil.flaeche).padding(5.dp)) {
            Lizenzzeile(uebersetzt("Quelltext und schriftliches Angebot"), null, Modifier.focusRequester(fokus("angebot"))) {
                waehlen("angebot", Lizenzseite.Angebot)
            }
            for (b in bestand.gruppe("player") + bestand.gruppe("app")) {
                Lizenzzeile(b.name, "${b.spdx} · ${b.version}", Modifier.focusRequester(fokus(b.id))) {
                    waehlen(b.id, Lizenzseite.Baustein(b.id))
                }
            }
        }
    }
}

@Composable
private fun Lizenzzeile(titel: String, unter: String?, modifier: Modifier, tun: () -> Unit) {
    Fokusflaeche(modifier.fillMaxWidth(), lupe = 1f, tun = tun) { fokus ->
        Row(Modifier.fillMaxWidth().heightIn(min = TvStil.zeilenHoehe).clip(RoundedCornerShape(TvStil.ecke))
                .background(if (fokus) TvStil.fokusflaeche else androidx.compose.ui.graphics.Color.Transparent)
                .padding(horizontal = 13.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(titel, style = TvStil.koerper, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis,
                 modifier = Modifier.weight(1f))
            unter?.let { Text(it, style = TvStil.kachel, color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis,
                              modifier = Modifier.widthIn(max = 460.dp)) }
        }
    }
}

/**
 * Eine Seite zum Lesen: Titel fest, darunter der Text in einer **fokussierbaren** Flaeche.
 * Runter und Hoch blaettern um 80 Prozent der Hoehe; erst am Ende (oder am Anfang) wird die
 * Taste nicht mehr verbraucht. Der Fokusrand zeigt, dass die Flaeche die Tasten nimmt.
 */
@Composable
private fun TvLeseflaeche(titel: String, inhalt: @Composable ColumnScope.() -> Unit) {
    val rolle = rememberScrollState()
    val lauf = rememberCoroutineScope()
    val fokus = remember { FocusRequester() }
    var hat by remember { mutableStateOf(false) }
    var hoehe by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { delay(2 * TvStil.fokusFrist); runCatching { fokus.requestFocus() } }
    Column(Modifier.fillMaxSize().padding(horizontal = TvStil.randSeite, vertical = TvStil.randOben).widthIn(max = 1000.dp)) {
        Text(titel, style = TvStil.titelGross, color = Stil.schrift, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(16.dp))
        Box(Modifier.weight(1f).fillMaxWidth().onSizeChanged { hoehe = it.height }
                .clip(RoundedCornerShape(TvStil.eckeKachel))
                .border(2.dp, if (hat) Stil.akzent else androidx.compose.ui.graphics.Color.Transparent, RoundedCornerShape(TvStil.eckeKachel))
                .focusRequester(fokus).onFocusChanged { hat = it.isFocused }
                .onPreviewKeyEvent { e ->
                    val runter = e.key == Key.DirectionDown || e.key == Key.PageDown
                    val hoch = e.key == Key.DirectionUp || e.key == Key.PageUp
                    val frei = (runter && rolle.value < rolle.maxValue) || (hoch && rolle.value > 0)
                    if (!frei) return@onPreviewKeyEvent false
                    if (e.type == KeyEventType.KeyDown) lauf.launch { rolle.animateScrollBy((if (runter) 1 else -1) * hoehe * 0.8f) }
                    true
                }
                .focusable()
                .verticalScroll(rolle, enabled = false)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp), content = inhalt)
        }
    }
}
