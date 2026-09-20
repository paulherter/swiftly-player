package de.paulherter.swiftly

import androidx.activity.compose.PredictiveBackHandler
import androidx.compose.animation.core.Animatable
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
import androidx.compose.material.icons.outlined.ArrowCircleDown
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.foundation.selection.selectable
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.future.await
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/** Vorlage: `Bereich` in `Sources/Shared/Stil.swift` — Downloads nur, wenn eingeschaltet. */
enum class Bereich(val titel: String, val symbol: ImageVector) {
    Start("Start", Icons.Outlined.Home),
    Filme("Filme", Icons.Outlined.Movie),
    Serien("Serien", Icons.Outlined.Tv),
    Downloads("Downloads", Icons.Outlined.ArrowCircleDown),
    Suche("Suche", Icons.Outlined.Search),
}

/**
 * Ein Ort im Stapel eines Bereichs — `NavigationLink(value: Item)` auf iOS. `rolle` und
 * `herkunft` traegt nur eine Person: „Woody in Toy Story" steht dort, bevor etwas geladen ist.
 */
data class Ziel(val id: String, val name: String, val typ: String, val rolle: String? = null, val herkunft: String? = null)

/**
 * Vorlage: `HauptView` in `Sources/Shared/HauptView.swift` — ein Stapel je Bereich.
 *
 * **Die Bewegung ist die von `NavigationStack`**, nicht die von Android: die neue Seite faehrt
 * von rechts herein, die alte weicht ein Drittel nach links und dunkelt ab. Die Zurueckgeste
 * zieht die Seite mit dem Finger — `PredictiveBackHandler` ist Androids Gegenstueck zu
 * `WischZurueck`. Gezeichnet werden nur die oberste Seite und, waehrend einer Bewegung, die
 * darunter; beide behalten ueber `key` ihre Identitaet, wenn sie den Platz tauschen.
 *
 * Die Leiste gehoert zur Anfangsseite und faehrt mit ihr — auf iOS haengt `bereichsleiste()`
 * dort, nicht an tieferen Seiten.
 */
@Composable
fun Hauptansicht(app: SwiftlyAnwendung) {
    var bereich by rememberSaveable { mutableStateOf(Bereich.Start) }
    // Jeder Bereich behaelt seinen Zustand (Scrollposition) beim Wechsel.
    val zustaende = rememberSaveableStateHolder()
    // Sofort beim Ankommen, nicht erst in der Bibliothek — dort liess er den Kopf nachwachsen.
    LaunchedEffect(Unit) {
        app.sitzungPruefen()
        app.seerrLaden()
        app.downloads.kontoSetzen(app.kontoKennung())
        app.servernameLaden()
        app.nachDemVerbinden()
        // Fernsteuerung: Knoepfe im Dashboard, und andere Geraete sehen diese Sitzung zum Uebernehmen.
        app.kern.fernsteuerungStarten().await()
    }
    // „Hier weiterschauen": alle fuenf Sekunden, solange die App vorn ist — gesucht wird eine Sitzung,
    // die es vorher nicht gab, und die soll nicht zehn Sekunden auf sich warten lassen.
    @Suppress("DEPRECATION")
    val lebenszyklus = androidx.compose.ui.platform.LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lebenszyklus) {
        lebenszyklus.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.STARTED) {
            while (true) { app.angeboteHolen(); kotlinx.coroutines.delay(5000) }
        }
    }
    // Je Bereich ein eigener Stapel — `pfade[b.rawValue]` in `HauptView`.
    val stapel = remember { mutableStateMapOf<Bereich, List<Ziel>>() }
    val oben = stapel[bereich].orEmpty()
    val lauf = rememberCoroutineScope()
    /** Wie weit die oberste Seite nach rechts hinaus ist: 0 steht, 1 ist draussen. */
    val schub = remember { Animatable(0f) }
    /** `bereichsmass` — der Inhalt waechst beim Bereichswechsel von 0,995 auf 1. */
    val bereichsmass = remember { Animatable(1f) }
    val bewegt by remember { derivedStateOf { schub.value > 0f } }

    // Die Wegeregel aus `zielorte` steht in `Unterseite`.
    //
    // **Ein neuer Auftrag verwirft keinen Tipp.** Laeuft noch eine Bewegung, wird sie an ihr Ziel
    // gesetzt und ihr Abschluss abgewartet — ein zweiter Tipp oder Zurueck mitten im Wechsel wirkt,
    // statt still unterzugehen.
    val laufend = remember { arrayOfNulls<Job>(1) }
    fun auftrag(block: suspend () -> Unit) {
        val vorher = laufend[0]
        laufend[0] = lauf.launch {
            if (vorher?.isActive == true) { schub.snapTo(schub.targetValue); vorher.join() }
            block()
        }
    }
    fun wegnehmen() { stapel[bereich] = stapel[bereich].orEmpty().dropLast(1) }
    val oeffnen: (Ziel) -> Unit = { z ->
        auftrag {
            // Erst hinausschieben, dann einsetzen — im selben Bild, sonst blitzt die Seite auf.
            schub.snapTo(1f)
            stapel[bereich] = stapel[bereich].orEmpty() + z
            schub.animateTo(0f, Bewegung.seite())
        }
    }
    val zurueck: () -> Unit = {
        if (stapel[bereich].orEmpty().isNotEmpty()) auftrag {
            // Auch abgebrochen gilt der Rueckweg — der Abschluss steht deshalb im finally.
            try {
                // **Die Seite darunter zuerst aufbauen, dann bewegen** — wie beim Oeffnen. Sonst entstand
                // sie im ersten Bild der Bewegung, und das Schliessen stockte gleich am Anfang.
                schub.snapTo(0.0001f)
                androidx.compose.runtime.withFrameNanos { }
                androidx.compose.runtime.withFrameNanos { }
                schub.animateTo(1f, Bewegung.zurueck())
            }
            finally { withContext(NonCancellable) { wegnehmen(); schub.snapTo(0f) } }
        }
    }
    PredictiveBackHandler(enabled = oben.isNotEmpty()) { ereignisse ->
        laufend[0]?.let { if (it.isActive) { schub.snapTo(schub.targetValue); it.join() } }
        // Das Tempo des Fingers — damit das Loslassen weiterfliegt, statt neu anzusetzen.
        var tempo = 0f
        var zuletzt = 0L
        var wert = schub.value
        try {
            ereignisse.collect { e ->
                val jetzt = System.nanoTime()
                if (zuletzt > 0) { val dt = (jetzt - zuletzt) / 1e9f; if (dt > 0f) tempo = (e.progress - wert) / dt }
                zuletzt = jetzt
                wert = e.progress
                schub.snapTo(e.progress)
            }
            // Etwas Nachfedern darf sein; ein sehr schneller Wurf schoss aber weit darueber hinaus.
            schub.animateTo(1f, Bewegung.wurf(), initialVelocity = tempo.coerceIn(0f, 6f))
            wegnehmen()
            schub.snapTo(0f)
        } catch (e: CancellationException) {
            // Losgelassen, bevor es reichte: die Seite gleitet mit ihrem Tempo zurueck.
            val zurueckTempo = tempo.coerceIn(-6f, 0f)
            lauf.launch { schub.animateTo(0f, Bewegung.wurf(), initialVelocity = zurueckTempo) }
            throw e
        }
    }
    // Der Player hat eine eigene Aktivitaet (Bild-im-Bild) — ein Wunsch startet sie.
    val kontext = androidx.compose.ui.platform.LocalContext.current
    val spiel = app.spiel.value
    // **Jeder Wunsch startet den Player genau einmal.** Ohne `spielUebergeben` startete eine neu
    // gebaute Hauptaktivitaet ihn noch einmal mit demselben Wunsch — beim Schliessen ging die Folge
    // wieder auf. Siehe `SwiftlyAnwendung.spielUebergeben`.
    LaunchedEffect(spiel) {
        if (spiel == null || spiel === app.spielUebergeben) return@LaunchedEffect
        app.spielUebergeben = spiel
        kontext.startActivity(android.content.Intent(kontext, PlayerAktivitaet::class.java),
            android.app.ActivityOptions.makeCustomAnimation(kontext, de.paulherter.swiftly.R.anim.player_ein, de.paulherter.swiftly.R.anim.halten).toBundle())
    }

    val waehlen: (Bereich) -> Unit = { b ->
        if (b == bereich) {
            stapel[b] = emptyList()
            // Der zweite Tipp auf die Suche oeffnet die Tastatur.
            if (b == Bereich.Suche) app.suche.nochmal++
        }
        else {
            bereich = b
            lauf.launch {
                schub.snapTo(0f)
                // **Harter Schnitt, dann ein Hauch Wachsen.** Eine Ueberblendung liess den Grund
                // durch beide Seiten scheinen (iOS, `bereichswechsel`).
                bereichsmass.snapTo(Bewegung.BEREICHSMASS)
                bereichsmass.animateTo(1f, Bewegung.bereichswechsel())
            }
        }
    }

    // Ausgeschaltet, waehrend man im Bereich steht: zurueck zum Start.
    val downloadsAn = app.einstellungen.downloadsAn
    LaunchedEffect(downloadsAn) { if (!downloadsAn && bereich == Bereich.Downloads) waehlen(Bereich.Start) }

    CompositionLocalProvider(LocalBereichsmass provides bereichsmass, LocalFortschrittZeigen provides app.einstellungen.fortschritt,
                              LocalLadepuls provides Ladepuls()) {
        Box(Modifier.fillMaxSize().background(Stil.grund)) {
            val ab = if (bewegt && oben.isNotEmpty()) oben.size - 1 else oben.size
            for (tiefe in ab..oben.size) {
                val ziel = oben.getOrNull(tiefe - 1)
                key(bereich, tiefe, ziel?.id) {
                    val istOben = tiefe == oben.size
                    Box(Modifier.fillMaxSize()
                        .graphicsLayer {
                            translationX = if (istOben) schub.value * size.width
                                           else -0.25f * (1f - schub.value) * size.width
                        }
                        .background(Stil.grund)) {
                        zustaende.SaveableStateProvider("${bereich.name}/$tiefe/${ziel?.id.orEmpty()}") {
                            if (ziel == null) Anfangsseite(app, bereich, oeffnen, waehlen)
                            else Unterseite(app, ziel, oeffnen, zurueck)
                        }
                        // Die Seite darunter dunkelt ab, solange die obere sie verdeckt.
                        if (!istOben) Box(Modifier.matchParentSize().graphicsLayer { alpha = 1f - schub.value }
                            .background(Color.Black.copy(alpha = 0.15f)))
                    }
                }
            }
            // Ueber allem, auch ueber der Leiste: das Blatt haengt auf iOS hinter `.bereichsleiste()`.
            // Solange der Player laeuft, gehoert das Blatt ihm.
            if (spiel == null) Blattauflage(app)
        }
    }
}

@Composable
private fun Anfangsseite(app: SwiftlyAnwendung, bereich: Bereich, oeffnen: (Ziel) -> Unit, waehlen: (Bereich) -> Unit) {
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f)) {
            when (bereich) {
                Bereich.Start -> StartSeite(app, oeffnen)
                Bereich.Filme -> BibliothekSeite(app, "movies", uebersetzt("Filme"),
                                                 listOf("alle", "angefangen", "merkliste", "ungesehen"), oeffnen)
                // Bei Serien hilft „ungesehen" wenig — dieselbe Liste wie auf iOS.
                Bereich.Serien -> BibliothekSeite(app, "tvshows", uebersetzt("Serien"),
                                                  listOf("alle", "angefangen", "merkliste"), oeffnen)
                Bereich.Downloads -> DownloadsSeite(app, oeffnen)
                Bereich.Suche -> SuchSeite(app, oeffnen)
            }
        }
        Leiste(bereich, app.einstellungen.downloadsAn, waehlen)
    }
}

/** Die Wegeregel aus `zielorte`: Serie → Serienseite, Folge → ihre Staffel, Person → Personenseite, sonst Titelseite. */
@Composable
private fun Unterseite(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    when (ziel.typ) {
        "Series", "Episode" -> SerienSeite(app, ziel, oeffnen, zurueck)
        "Person" -> PersonSeite(app, ziel, oeffnen, zurueck)
        "Profil" -> ProfilSeite(app, oeffnen, zurueck)
        "Merkliste" -> MerklisteSeite(app, oeffnen, zurueck)
        "WeiteresKonto" -> Box(Modifier.fillMaxSize().background(Stil.grund)) {
            AnmeldeSeite(app, app.servername.value.orEmpty(), "", andererServer = zurueck, weiteresKonto = true) { zurueck() }
        }
        "ServerAufnahme" -> ServerAufnahmeSeite(app, ziel.id.takeIf { it != "serveraufnahme" }, zurueck)
        "Genre" -> GenreSeite(app, ziel, oeffnen, zurueck)
        "QuickConnect" -> QuickConnectSeite(app, zurueck)
        "Wiedergabeeinstellungen" -> WiedergabeEinstellungenSeite(app, zurueck)
        "Darstellung" -> DarstellungSeite(app, oeffnen, zurueck)
        "Einstellungen" -> EinstellungenSeite(app, oeffnen, zurueck)
        "Seerr" -> SeerrEinstellungenSeite(app, zurueck)
        "Seerrtitel" -> SeerrDetailSeite(app, ziel, oeffnen, zurueck)
        "Genrewahl" -> GenrewahlSeite(app, zurueck)
        "Downloadserie" -> DownloadserieSeite(app, ziel, zurueck)
        else -> TitelSeite(app, ziel, oeffnen, zurueck)
    }
}

/** Vorlage: `Bereichsleiste` in `Stil.swift` — 54 hoch, Grund, Haarlinie, 10 pt, aktiv im Akzent. */
@Composable
private fun Leiste(aktiv: Bereich, downloads: Boolean, waehlen: (Bereich) -> Unit) {
    Column(Modifier.fillMaxWidth().background(Stil.grund).navigationBarsPadding()) {
        Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.linie))
        Row(Modifier.fillMaxWidth().height(Stil.leisteHoehe).padding(top = 9.dp)) {
            // Downloads nur, wenn die Funktion an ist (H1) — links neben der Suche, die ganz rechts bleibt.
            Bereich.entries.filter { it != Bereich.Downloads || downloads }.forEach { b ->
                val an = b == aktiv
                val farbe = if (an) Stil.akzent else Color.White.copy(alpha = 0.42f)
                Column(
                    Modifier.weight(1f).selectable(an, remember { MutableInteractionSource() }, null,
                        role = androidx.compose.ui.semantics.Role.Tab) { waehlen(b) },
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
