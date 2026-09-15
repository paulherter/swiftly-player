package de.paulherter.swiftly.tv

import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.*
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.Wortmarke
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.delay

/**
 * Vorlage: `Bereich` in `Sources/tvOS/TVBausteine.swift` — **oben, nicht unten**: auf tvOS fuehrt
 * die Navigation oben, eine Leiste am unteren Rand waere unerreichbar weit vom Blick weg. Die
 * Merkliste hat hier einen eigenen Bereich; Downloads gibt es auf dem Fernseher nicht.
 */
enum class TvBereich(val titel: String) { Start("Start"), Filme("Filme"), Serien("Serien"), Merkliste("Merkliste"), Suche("Suche") }

/** Wie tief die Kopfleiste reicht — darunter beginnen die Seiten. */
val kopfUnten = TvStil.randOben + TvStil.leisteHoehe + 12.dp

/**
 * Vorlage: `HauptView` auf tvOS. Je Bereich ein eigener Stapel; **Bereiche wechseln als reine
 * Ueberblendung** — eine fruehere Fassung liess sie aneinander vorbeigleiten, und das sah wie ein
 * Fehler aus. Unterseiten erscheinen ohne Schub. **Zurueck fuehrt eine Stufe zurueck, nicht aus der
 * App:** erst die Tafel, dann der Stapel, dann zum Start.
 */
@Composable
fun TvHaupt(app: SwiftlyAnwendung) {
    var bereich by rememberSaveable { mutableStateOf(TvBereich.Start) }
    val stapel = remember { mutableStateMapOf<TvBereich, List<Ziel>>() }
    val zustaende = rememberSaveableStateHolder()
    val kontext = LocalContext.current

    LaunchedEffect(Unit) {
        app.seerrLaden()
        app.servernameLaden()
        app.nachDemVerbinden()
    }
    val spiel = app.spiel.value
    LaunchedEffect(spiel) { if (spiel != null) kontext.startActivity(Intent(kontext, PlayerAktivitaet::class.java),
            android.app.ActivityOptions.makeCustomAnimation(kontext, de.paulherter.swiftly.R.anim.player_hoch, de.paulherter.swiftly.R.anim.halten).toBundle()) }

    val oeffnen: (Ziel) -> Unit = { z -> stapel[bereich] = stapel[bereich].orEmpty() + z }
    val zurueck: () -> Unit = { stapel[bereich] = stapel[bereich].orEmpty().dropLast(1) }
    val oben = stapel[bereich].orEmpty()

    BackHandler(enabled = oben.isEmpty() && bereich != TvBereich.Start) { bereich = TvBereich.Start }
    BackHandler(enabled = oben.isNotEmpty(), onBack = zurueck)

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        Crossfade(bereich, animationSpec = tween(250), label = "bereich") { b ->
            val ziel = stapel[b].orEmpty().lastOrNull()
            val tiefe = stapel[b].orEmpty().size
            key(b, tiefe, ziel?.id) {
                zustaende.SaveableStateProvider("${b.name}/$tiefe/${ziel?.id.orEmpty()}") {
                    if (ziel == null) {
                        Box(Modifier.fillMaxSize()) {
                            when (b) {
                                TvBereich.Start -> TvStartSeite(app, oeffnen)
                                TvBereich.Filme -> TvBibliothek(app, "movies", listOf("alle", "angefangen", "merkliste", "ungesehen"), oeffnen)
                                TvBereich.Serien -> TvBibliothek(app, "tvshows", listOf("alle", "angefangen", "merkliste"), oeffnen)
                                TvBereich.Merkliste -> TvMerkliste(app, oeffnen)
                                TvBereich.Suche -> TvSuche(app, oeffnen)
                            }
                            Kopfleiste(app, b, { bereich = it }) { oeffnen(Ziel("profil", uebersetzt("Profil"), "Profil")) }
                        }
                    } else {
                        TvUnterseite(app, ziel, oeffnen, zurueck)
                    }
                }
            }
        }
        // Solange der Player laeuft, gehoert die Tafel ihm.
        if (spiel == null) TvTafel(app)
    }
}

/** Die Wegeregel aus `zielorte`; was es nur auf dem Telefon als Seite gibt, kommt von dort. */
@Composable
private fun TvUnterseite(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    when (ziel.typ) {
        "Series", "Episode" -> TvSerie(app, ziel, oeffnen)
        "Person" -> TvPerson(app, ziel, oeffnen)
        "Genre" -> TvGenre(app, ziel, oeffnen)
        "Profil" -> TvProfil(app, oeffnen)
        "WeiteresKonto" -> Box(Modifier.fillMaxSize().background(Stil.grund)) {
            AnmeldeSeite(app, app.servername.value.orEmpty(), "", andererServer = zurueck, weiteresKonto = true) { zurueck() }
        }
        "ServerAufnahme" -> ServerAufnahmeSeite(app, ziel.id.takeIf { it != "serveraufnahme" }, zurueck)
        "Wiedergabeeinstellungen" -> WiedergabeEinstellungenSeite(app, zurueck)
        "Darstellung" -> DarstellungSeite(app, oeffnen, zurueck)
        "Einstellungen" -> EinstellungenSeite(app, oeffnen, zurueck)
        "Seerr" -> SeerrEinstellungenSeite(app, zurueck)
        "Seerrtitel" -> SeerrDetailSeite(app, ziel, oeffnen, zurueck)
        "Genrewahl" -> GenrewahlSeite(app, zurueck)
        "Merkliste" -> TvMerkliste(app, oeffnen)
        else -> TvDetail(app, ziel, oeffnen)
    }
}

/**
 * Vorlage: `Kopfleiste` — Wortmarke links, Reiter daneben, Profil rechts; **links ausgerichtet**,
 * nicht mittig. Gewechselt wird beim Klick, nicht beim Fokus: tvOS sucht geometrisch, und drei
 * Anlaeufe, das umzulenken, haben geflackert.
 */
@Composable
private fun Kopfleiste(app: SwiftlyAnwendung, aktiv: TvBereich, waehlen: (TvBereich) -> Unit, profil: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = TvStil.randSeite).padding(top = TvStil.randOben).height(TvStil.leisteHoehe).focusGroup(),
        verticalAlignment = Alignment.CenterVertically) {
        Wortmarke(hoehe = 18.dp)
        Spacer(Modifier.width(26.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            TvBereich.entries.forEach { b -> Reiter(uebersetzt(b.titel), b == aktiv) { waehlen(b) } }
        }
        Spacer(Modifier.weight(1f))
        Fokusflaeche(lupe = 1.10f, tun = profil) { fokus ->
            Box(Modifier.size(32.dp).border(2.dp, if (fokus) Stil.akzent else Color.Transparent, CircleShape).padding(3.dp)) {
                SubcomposeAsyncImage(model = app.kern.benutzerbild(160).orElse(null), contentDescription = uebersetzt("Profil"),
                    contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize().clip(CircleShape).background(Stil.erhoeht),
                    error = { Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Icon(Icons.Filled.Person, contentDescription = null, tint = Stil.schriftLeise, modifier = Modifier.size(16.dp))
                    } })
            }
        }
    }
}

/** Vorlage: `ReiterStil` — Lupe 1,06, ruhige Flaeche im Fokus, gewaehlt mit Akzentstrich. */
@Composable
private fun Reiter(text: String, gewaehlt: Boolean, tun: () -> Unit) {
    Fokusflaeche(lupe = 1.06f, tun = tun) { fokus ->
        Column(Modifier.clip(RoundedCornerShape(TvStil.ecke)).background(if (fokus) Color.White.copy(alpha = 0.08f) else Color.Transparent)
                .padding(horizontal = 12.dp, vertical = 5.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            Text(text, style = TextStyle(fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold),
                 color = if (fokus || gewaehlt) Stil.schrift else Stil.schriftLeise)
            Box(Modifier.padding(top = 3.dp).size(18.dp, 2.dp).clip(CircleShape).background(if (gewaehlt) Stil.akzent else Color.Transparent))
        }
    }
}

/**
 * Vorlage: `Handlungstafel` — dieselben Wuensche wie das Blatt auf dem Telefon (`app.blatt`), als
 * Tafel am rechten Rand. **Der Fokus bleibt drin**, bis sie zu ist; Zurueck schliesst nur sie.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun TvTafel(app: SwiftlyAnwendung) {
    val w = app.blatt.value ?: return
    val schliessen = { app.blatt.value = null }
    BackHandler(onBack = schliessen)
    var auswahl by remember(w) { mutableStateOf(w.mehrfach) }
    val erster = remember(w) { FocusRequester() }
    LaunchedEffect(w) { delay(30); runCatching { erster.requestFocus() } }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f))) {
        Column(Modifier.align(Alignment.CenterEnd).padding(end = TvStil.randSeite).width(310.dp)
                .clip(RoundedCornerShape(10.dp)).background(Stil.erhoeht).padding(10.dp)
                .focusProperties { exit = { FocusRequester.Cancel } }.focusGroup()) {
            Text(w.titel, style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold), color = Stil.schrift, maxLines = 2,
                 modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp))
            Column(Modifier.heightIn(max = 380.dp).verticalScroll(rememberScrollState())) {
                w.eintraege.forEachIndexed { i, e ->
                    val menge = auswahl
                    TvZeile(e.text, w.symbole[e.wert], rechts = w.gesperrt[e.wert],
                            haken = if (menge != null) e.wert in menge else e.wert == w.gewaehlt,
                            modifier = if (i == 0) Modifier.focusRequester(erster) else Modifier) {
                        if (w.gesperrt[e.wert] != null) return@TvZeile
                        if (menge != null) auswahl = if (e.wert in menge) menge - e.wert else menge + e.wert
                        else { schliessen(); w.waehlen(e.wert) }
                    }
                }
            }
            w.abschluss?.let { abschluss ->
                val menge = auswahl.orEmpty()
                TvZeile(w.abschlussText(menge.size)) { if (menge.isNotEmpty()) { schliessen(); abschluss(menge) } }
            }
        }
    }
}
