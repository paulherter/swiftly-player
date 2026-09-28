package de.paulherter.swiftly.tv

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.Angebot
import de.paulherter.swiftly.Blattwunsch
import de.paulherter.swiftly.Gemeinsamgruppe
import de.paulherter.swiftly.SwiftlyAnwendung
import de.paulherter.swiftly.Wahl
import de.paulherter.swiftly.uebernahmesymbol
import de.paulherter.swiftly.werSchaut
import de.paulherter.swiftly.zustandText
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// **Gemeinsam schauen am Fernseher** — Verhalten wie iOS (`Gemeinsamansichten`), Bedienung wie die
// uebrigen Tafeln: die Blaetter sind `TvTafel`n am rechten Rand, was das Blatt am Telefon als Text
// zeigt, steht als Absatz unter der Ueberschrift (`Blattwunsch.unterzeile`).
//
// **Kein Namensfeld** (VERHALTEN F, Eingabeart): mit der Fernbedienung tippt niemand einen Namen, die
// Gruppe heisst wie die Vorgabe am Telefon, „Filmabend" (leer → Paket).

/** Die Tafeln leben laenger als die Seite, die sie oeffnet — ihre Aufrufe auch. */
private val tafellauf = MainScope()

/** Vorlage: das Blatt „Gemeinsam schauen" — Titelzeile und der Satz dazu, darunter „Gruppe öffnen". */
fun tvAnlegenOeffnen(app: SwiftlyAnwendung, titelId: String, titelzeile: String) {
    app.blatt.value = Blattwunsch(uebersetzt("Gemeinsam schauen"), listOf(Wahl("oeffnen", uebersetzt("Gruppe öffnen"))), null,
        mapOf("oeffnen" to Zeichen.GruppeVoll),
        unterzeile = titelzeile + "\n\n" +
            uebersetzt("Alle auf deinem Server sehen die Gruppe und können mit einsteigen. Pause und Springen gelten dann für alle.")) {
        tafellauf.launch { withContext(Dispatchers.IO) { app.kern.syncPlayAnlegen("", titelId).await() } }
    }
}

/** Vorlage: das Blatt „Beitreten" — Name der Gruppe, wer schaut, der Zustand, was gilt. */
fun tvBeitretenOeffnen(app: SwiftlyAnwendung, g: Gemeinsamgruppe) {
    val zeilen = listOfNotNull(werSchaut(g), zustandText(g.zustand), uebersetzt("Pause und Springen gelten für alle."))
    app.blatt.value = Blattwunsch(g.name, listOf(Wahl("beitreten", uebersetzt("Beitreten"))), null,
        mapOf("beitreten" to Zeichen.GruppeVoll), unterzeile = zeilen.joinToString("\n")) {
        tafellauf.launch { withContext(Dispatchers.IO) { app.kern.syncPlayBeitreten(g.id).await() } }
    }
}

/** Vorlage: die Auswahl „Läuft gerade" — erst die anderen Geraete, dann die Gruppen. */
fun tvAuswahlOeffnen(app: SwiftlyAnwendung, weiterschauen: (Angebot) -> Unit) {
    val angebote = app.angebote.value
    val gruppen = app.gemeinsam.value.offeneGruppen
    val eintraege = angebote.map { Wahl("u:" + it.sitzung, listOf(it.geraet ?: uebersetzt("Gerät"), it.titelzeile).joinToString(" · ")) } +
        gruppen.map { Wahl("g:" + it.id, it.name + " · " + werSchaut(it)) }
    val symbole = angebote.associate { "u:" + it.sitzung to uebernahmesymbol(it.art) } + gruppen.associate { "g:" + it.id to Zeichen.GruppeVoll }
    app.blatt.value = Blattwunsch(uebersetzt("Läuft gerade"), eintraege, null, symbole) { wert ->
        when {
            wert.startsWith("u:") -> angebote.firstOrNull { it.sitzung == wert.drop(2) }?.let(weiterschauen)
            wert.startsWith("g:") -> gruppen.firstOrNull { it.id == wert.drop(2) }?.let { g ->
                tafellauf.launch { withContext(Dispatchers.IO) { app.kern.syncPlayBeitreten(g.id).await() } }
            }
        }
    }
}

/**
 * Vorlage: `Rueckwegstreifen` — „Filmabend verlassen · Wieder beitreten", acht Sekunden lang.
 *
 * **Am Fernseher mit Fokus**: der Streifen kommt nach dem Schliessen des Players, also genau dann,
 * wenn der Fokus gerade zurueck an den Ausloeser gegangen ist. Er nimmt ihn sich — OK tritt wieder
 * bei — und gibt ihn beim Verschwinden dorthin zurueck (`Fokusmerker.nachDemPlayer`). Ohne Fokus
 * waere der Knopf mit der Fernbedienung nicht zu erreichen.
 */
@Composable
fun TvRueckwegstreifen(app: SwiftlyAnwendung) {
    val name = app.gemeinsam.value.zuletztVerlassen
    val gemerkt = remember { arrayOfNulls<String>(1) }
    if (name != null) gemerkt[0] = name
    val knopf = remember { FocusRequester() }
    var hatFokus by remember { mutableStateOf(false) }
    val lauf = rememberCoroutineScope()
    LaunchedEffect(name != null) {
        if (name != null) {
            // Nach `Fokusmerker.playerZu` — sonst holte der sich den Fokus gleich wieder.
            delay(TvStil.fokusFrist * 3)
            repeat(4) { if (runCatching { knopf.requestFocus() }.isSuccess) return@LaunchedEffect; delay(TvStil.fokusFrist) }
        } else if (hatFokus) {
            Fokusmerker.nachDemPlayer?.let { runCatching { it.requestFocus() } }
        }
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        AnimatedVisibility(name != null, enter = fadeIn(tween(220)), exit = fadeOut(tween(220))) {
            Row(Modifier.padding(bottom = TvStil.randOben).clip(RoundedCornerShape(50)).background(Stil.flaeche)
                    .padding(start = 22.dp, end = 8.dp, top = 6.dp, bottom = 6.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(uebersetzt("%@ verlassen", gemerkt[0].orEmpty()), style = TvStil.koerper, color = Stil.schrift,
                     maxLines = 1, overflow = TextOverflow.Ellipsis)
                Fokusflaeche(Modifier.focusRequester(knopf).onFocusChanged { hatFokus = it.hasFocus }, lupe = TvStil.fokusLupeKlein,
                    tun = { lauf.launch { withContext(Dispatchers.IO) { app.kern.syncPlayWiederBeitreten().await() } } }) { fokus ->
                    Text(uebersetzt("Wieder beitreten"), style = TvStil.knopf, color = if (fokus) Stil.grund else Stil.akzent,
                         modifier = Modifier.clip(RoundedCornerShape(50)).background(if (fokus) Color.White else Color.Transparent)
                             .padding(horizontal = 14.dp, vertical = 6.dp))
                }
            }
        }
    }
}
