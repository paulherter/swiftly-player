package de.paulherter.swiftly.tv

import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.focusGroup
import androidx.compose.ui.focus.focusProperties
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import coil3.compose.AsyncImage
import de.paulherter.swiftly.Abspielwunsch
import de.paulherter.swiftly.Belegzeile
import de.paulherter.swiftly.Folge
import de.paulherter.swiftly.Ladefeld
import de.paulherter.swiftly.Ruck
import de.paulherter.swiftly.Spielwerk
import de.paulherter.swiftly.SwiftlyAnwendung
import de.paulherter.swiftly.Technikschild
import de.paulherter.swiftly.aktivitaet
import de.paulherter.swiftly.folgenLesen
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.rememberRuck
import de.paulherter.swiftly.zeitText
import de.paulherter.swiftly.tempoText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs

/**
 * Vorlage: `PlayerScreen` in `Sources/tvOS/PlayerScreen.swift`.
 *
 * Die Wiedergabe-Mechanik (VLC, Takt, Meldungen, Mediensitzung) steckt in `Spielwerk`
 * (`Sources/PlayerSeite.kt`) — dieselbe Klasse, die auch der Telefon-Player benutzt. Hier steht nur,
 * was am Fernseher anders ist: kein Finger, sondern die Fernbedienung.
 *
 * **Fernbedienung** (schon so auf Android TV eingefuehrt, Stand `Notizen/Android/PLAN.md` Phase 4):
 * OK haelt an oder bestaetigt eine gesammelte Sprungmarke sofort; links/rechts sammeln 350 ms lang,
 * bevor **einmal** gesprungen wird — VLC baut bei jedem Sprung den Strom neu auf, und ein Sprung je
 * Druck liess ihn hoerbar durch die Datei rauschen (dieselbe Begruendung wie tvOS' `springen`).
 * Oben zeigt die Steuerung, oder — wenn sie schon da ist — das Angebot (Vorspann/naechste Folge) oder,
 * wenn kein Angebot ansteht, die Wiedergabeeinstellungen. Zurueck bricht zuerst das Spulen ab, dann
 * die Einstellungstafel, erst dann verlaesst es den Player (`onExitCommand`-Reihenfolge aus der Vorlage).
 *
 * **Bewusst weggelassen:** Bild-im-Bild (tvOS hat es auch nicht, siehe Vorlage-Kommentar dort),
 * das Wischfeld zum Spulen (B2a) — die meisten Android-TV-Fernbedienungen haben keine Wischflaeche,
 * anders als die Siri Remote — und die Folgenliste (`Folgenblatt`, eigene Vorlage-Datei ausserhalb
 * dieser Zuteilung): die Fusszeile bietet weiterhin „naechste Folge"/„Vorspann ueberspringen" direkt an.
 */
@Composable
fun TvPlayer(app: SwiftlyAnwendung, wunsch: Abspielwunsch, schliessen: () -> Unit) {
    val kontext = LocalContext.current
    val aktivitaet = remember(kontext) { kontext.aktivitaet() }
    val lauf = rememberCoroutineScope()
    val ruck = rememberRuck()

    // Der Player laeuft in einer eigenen Activity (`PlayerAktivitaet`) — ein `Fokusmerker.letzter`
    // von der vorigen Seite (z. B. die Kachel, die den Player geoeffnet hat) gehoert zu einer
    // fremden Komposition und darf hier keine Tafel treffen wollen.
    LaunchedEffect(Unit) { Fokusmerker.letzter = null }

    val werk = remember { Spielwerk(app, kontext, lauf) }
    val flaeche = remember { arrayOfNulls<org.videolan.libvlc.util.VLCVideoLayout>(1) }
    @Suppress("DEPRECATION")
    val lebenslauf = androidx.compose.ui.platform.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lebenslauf) {
        val beobachter = androidx.lifecycle.LifecycleEventObserver { _, ereignis ->
            if (ereignis == androidx.lifecycle.Lifecycle.Event.ON_START && !werk.spieler.vlcVout.areViewsAttached()) {
                flaeche[0]?.let { werk.spieler.attachViews(it, null, true, false) }
            }
        }
        lebenslauf.addObserver(beobachter)
        onDispose { lebenslauf.removeObserver(beobachter) }
    }

    DisposableEffect(werk) {
        werk.installiereEreignisListener()
        onDispose { werk.aufraeumen() }
    }
    DisposableEffect(werk.sitzung) {
        werk.installiereSitzung()
        onDispose { werk.sitzungAufraeumen() }
    }
    LaunchedEffect(werk.plan, werk.dauer > 0) { werk.metadatenAktualisieren() }
    LaunchedEffect(app.einstellungen.technikschild, werk.plan) { werk.technikschildTakt(app.einstellungen.technikschild) }
    LaunchedEffect(wunsch) { werk.oeffnenUndTakt(wunsch, schliessen) }

    // **Bildtakt vor dem ersten Bild anstossen, dann in Ruhe lassen.** Die Rate wird einmal aus VLCs
    // Videotrack gemessen (`TvBildtakt.rate`) und bleibt ueber einen Folgenwechsel hinweg gemerkt —
    // genau wie `Bildtakt.gemessen` auf tvOS, das `wechsleZu` bewusst nicht zuruecksetzt.
    val bildrateErlaubt = remember { app.ablage.merkwert("bildrateAnpassen") != "0" }
    LaunchedEffect(Unit) {
        while (isActive && TvBildtakt.nochNachzumessen()) {
            aktivitaet?.let { TvBildtakt.anpassen(it, werk.spieler, bildrateErlaubt) }
            delay(300)
        }
    }
    DisposableEffect(aktivitaet) {
        onDispose { aktivitaet?.let { TvBildtakt.loesen(it) } }
    }

    var sichtbar by remember { mutableStateOf(true) }
    var beruehrt by remember { mutableIntStateOf(0) }
    var tafelOffen by remember { mutableStateOf(false) }
    // Vorlage: `Folgenblatt` — die Folgen der laufenden Staffel, aus dem Player heraus.
    var folgenOffen by remember { mutableStateOf(false) }

    LaunchedEffect(sichtbar, werk.laeuft, tafelOffen, folgenOffen, beruehrt) {
        if (sichtbar && werk.laeuft && !tafelOffen && !folgenOffen) { delay(4000); sichtbar = false }
    }
    LaunchedEffect(werk.hinweis) { if (werk.hinweis != null) { delay(5000); werk.hinweis = null } }

    fun zeigen() { sichtbar = true; beruehrt++ }

    // Spulen: sammeln, **einmal** springen — Vorlage `PlayerScreen.springen` (tvOS).
    var spulziel by remember { mutableStateOf<Double?>(null) }
    val letzterSchritt = remember { longArrayOf(0L) }
    var sammler by remember { mutableStateOf<Job?>(null) }
    fun spulen(um: Int) {
        if (!sichtbar) { zeigen(); return }
        val jetzt = android.os.SystemClock.elapsedRealtime()
        val seitLetztem = jetzt - letzterSchritt[0]
        letzterSchritt[0] = jetzt
        zeigen()
        val ziel = (spulziel ?: werk.position) + um
        if (spulziel == null && seitLetztem > 450) { werk.springe(ziel); return }
        spulziel = ziel
        sammler?.cancel()
        sammler = lauf.launch { delay(350); spulziel?.let { werk.springe(it) }; spulziel = null }
    }
    fun angebotAusfuehren(): Boolean {
        if (werk.angebotArt == "keiner" || werk.angebotText.isEmpty()) return false
        val nach = werk.angebotNach
        if (werk.angebotArt == "ueberspringen" && nach != null) werk.springe(nach) else lauf.launch { werk.naechsteFolge() }
        return true
    }

    // **Zurueck bricht zuerst das Spulen ab, dann die Tafel, dann die Folgenliste, dann erst der
    // Player** — dieselbe Reihenfolge wie `onExitCommand` in der Vorlage. `BackHandler`s wirken
    // zuletzt-deklariert-zuerst.
    val fernbedienung = remember { FocusRequester() }
    // **Erst den Fokus in Sicherheit, dann das Blatt entfernen.** Verschwindet die fokussierte Zeile
    // mit dem Blatt, faellt der Fokus auf den ersten fokussierbaren Knoten, und das Zurueckholen
    // danach ist ein sichtbarer Sprung. Das Folgenblatt liegt ueber den Knoepfen — dessen Ausloeser
    // steht noch da und bekommt den Fokus direkt. Die Wiedergabetafel blendet die Knoepfe aus
    // (`steuerungDa`), ihr Ausloeser ist erst nach dem Schliessen wieder da: bis dahin haelt die
    // Fernbedienungsflaeche den Fokus (sie zeichnet keinen), der Effekt unten gibt ihn dann weiter.
    //
    // **Beide Blaetter sind geschlossene Fokusgruppen** (`exit = Cancel`, wie `TvTafel`): Oben aus der
    // ersten Folge suchte Compose vorher im ganzen Player und fand den Einstellungsknopf oben rechts
    // *hinter* dem Blatt — er steht genau dort, wo im Blatt „Fertig" steht. Vorlage: auf tvOS ist das
    // Blatt eine eigene Auflage, dahinter ist nichts fokussierbar. `blattAusgang` gibt den Ausgang nur
    // fuer das programmatische Zurueckgeben frei (Compose fragt `exit` auch bei `requestFocus`).
    val blattAusgang = remember { booleanArrayOf(false) }
    fun tafelZu() { blattAusgang[0] = true; runCatching { fernbedienung.requestFocus() }; tafelOffen = false; zeigen() }
    fun folgenZu() { blattAusgang[0] = true; Fokusmerker.zurueckgeben(fernbedienung); folgenOffen = false; zeigen() }
    BackHandler(enabled = spulziel != null) { sammler?.cancel(); spulziel = null }
    BackHandler(enabled = tafelOffen) { tafelZu() }
    BackHandler(enabled = folgenOffen) { folgenZu() }
    BackHandler { werk.beenden(schliessen) }

    val knopfOben = remember { FocusRequester() }
    // **Nur die Zeitleiste selbst deutet Tasten.** `onKeyEvent` am aeusseren Kasten bekommt auch,
    // was ein fokussierter Knopf oben rechts nicht verbraucht — Links wurde dort zum Spulen, und der
    // Fokus konnte nie vom Einstellungs- zum Folgenknopf wechseln.
    var leisteFokus by remember { mutableStateOf(false) }
    fun taste(e: KeyEvent): Boolean {
        if (tafelOffen || folgenOffen || !leisteFokus) return false
        if (e.type != KeyEventType.KeyDown) return false
        when (e.key) {
            Key.DirectionCenter, Key.Enter, Key.NumPadEnter, Key.MediaPlayPause, Key.Spacebar -> {
                zeigen()
                val ziel = spulziel
                if (ziel != null) { sammler?.cancel(); spulziel = null; werk.springe(ziel) } else werk.umschalten()
            }
            Key.MediaPlay -> if (!werk.spieler.isPlaying) werk.umschalten()
            Key.MediaPause -> if (werk.spieler.isPlaying) werk.umschalten()
            Key.DirectionLeft -> spulen(-werk.zurueckS)
            Key.DirectionRight -> spulen(werk.vorS)
            Key.MediaRewind -> spulen(-werk.zurueckS)
            Key.MediaFastForward -> spulen(werk.vorS)
            Key.MediaNext -> if (werk.plan?.naechste == true) lauf.launch { werk.naechsteFolge() }
            // **Oben fuehrt zu den Knoepfen, nicht in die Einstellungen.** Vorlage: `PlayerScreen`
            // — „der Fokus liegt auf der Zeitleiste … nach oben kommt man zu den Knoepfen". Vorher
            // oeffnete Oben sofort die Tafel, und die beiden Knoepfe oben rechts waren mit der
            // Fernbedienung gar nicht erreichbar. Steht ein Angebot, hat es weiter Vorrang.
            Key.DirectionUp -> if (!sichtbar) zeigen() else if (!angebotAusfuehren()) {
                zeigen(); lauf.launch { delay(30); runCatching { knopfOben.requestFocus() } }
            }
            Key.Menu -> { tafelOffen = true; zeigen() }
            Key.DirectionDown -> { sichtbar = !sichtbar; beruehrt++ }
            else -> return false
        }
        return true
    }

    // Fokus zurueck an den Knopf, der die Tafel/das Blatt geoeffnet hat (siehe `Fokusmerker` in
    // TvStil.kt) — kam die Oeffnung stattdessen von der Fernbedienung (Oben/Menue ohne Knopfklick),
    // ist nichts gemerkt und es bleibt bei der bisherigen Fassung: zurueck auf die Fernbedienungsflaeche.
    //
    // **Ohne Zeitverzug:** der Effekt startet nach dem Anwenden der Komposition, in der die Tafel zu
    // ging — die Knoepfe oben (`steuerungDa`) sind dann schon wieder angebunden.
    LaunchedEffect(tafelOffen, folgenOffen) {
        if (!tafelOffen && !folgenOffen) Fokusmerker.zurueckfordern(fernbedienung)
        else blattAusgang[0] = false
    }

    val deckung by animateFloatAsState(
        if (sichtbar || !werk.bildFrei) 1f else 0f,
        if (sichtbar || !werk.bildFrei) tween(180, easing = Bewegung.weich) else tween(340, easing = Bewegung.weich),
        label = "steuerung")
    val steuerungDa by remember { derivedStateOf { deckung > 0.01f && !tafelOffen } }
    // Verschwinden die Knoepfe mit der Steuerung, darf der Fokus nicht ins Leere fallen.
    LaunchedEffect(steuerungDa) { if (!steuerungDa && !tafelOffen && !folgenOffen) runCatching { fernbedienung.requestFocus() } }

    Box(Modifier.fillMaxSize().background(Color.Black)
            .focusRequester(fernbedienung).onFocusChanged { leisteFokus = it.isFocused }.focusable().onKeyEvent { taste(it) }) {
        AndroidView(factory = { ctx -> org.videolan.libvlc.util.VLCVideoLayout(ctx).also { flaeche[0] = it; werk.spieler.attachViews(it, null, true, false) } },
                    modifier = Modifier.fillMaxSize())

        if (!werk.bildFrei) {
            Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
                if (werk.hinweis == null) TvLader(groesse = 64.dp)
            }
        }

        // **Das Zeichen fuer „steht"/„laedt" gehoert in die Mitte** — auf drei Metern Entfernung
        // sieht man aufs Bild, nicht auf die Leiste, und ein Standbild sieht sonst aus wie eine
        // ruhige Einstellung. Vorlage: `stockt` in `PlayerScreen.swift` — ohne Teller, der Ring
        // bringt seine Form selbst mit.
        if (werk.bildFrei && werk.laeuft && werk.puffert) {
            Box(Modifier.align(Alignment.Center)) { TvLader(groesse = 64.dp) }
        } else if (werk.bildFrei && !werk.laeuft) {
            Box(Modifier.align(Alignment.Center).size(95.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.42f)),
                contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Pause, contentDescription = null, tint = Stil.schrift, modifier = Modifier.size(38.dp))
            }
        }

        if (app.einstellungen.technikschild && werk.technikFest.isNotEmpty()) {
            Technikschild(werk.technikFest, werk.technikLive, werk.position, werk.dauer,
                Modifier.align(Alignment.TopStart).padding(start = TvStil.randSeite, top = TvStil.randOben))
        }

        werk.hinweis?.let {
            Text(it, style = TextStyle(fontSize = 15.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center), color = Stil.schrift,
                 modifier = Modifier.align(Alignment.TopCenter).padding(top = 90.dp, start = 96.dp, end = 96.dp))
        }

        if (steuerungDa) Box(Modifier.fillMaxSize().alpha(deckung)) {
            // Schleier — Abdunkeln plus Verlauf, sonst verschwinden helle Zeichen ueber hellen Szenen.
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.28f)))
            Box(Modifier.fillMaxWidth().height(210.dp).background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.62f), Color.Transparent))))
            Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(260.dp)
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.82f)))))

            // Werkzeuge oben rechts — Folgenliste nur, wenn es eine naechste Folge gibt (Vorlage:
            // `if naechste != nil` in `PlayerScreen.werkzeuge`), dahinter die Einstellungen.
            // Unten fuehrt von den Knoepfen zurueck auf die Zeitleiste; jeder Tastendruck hier haelt
            // die Steuerung wach, sonst verschwaende der fokussierte Knopf unter dem Finger.
            Row(Modifier.align(Alignment.TopEnd).padding(horizontal = TvStil.randSeite, vertical = TvStil.randOben)
                    .onPreviewKeyEvent { e ->
                        if (e.type == KeyEventType.KeyDown) zeigen()
                        if (e.type == KeyEventType.KeyDown && e.key == Key.DirectionDown) { runCatching { fernbedienung.requestFocus() }; true } else false
                    },
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (werk.plan?.naechste == true) {
                    TvKnopf(text = null, symbol = Icons.Filled.PlaylistPlay) { folgenOffen = true; zeigen() }
                }
                TvKnopf(text = null, symbol = Icons.Filled.Tune, modifier = Modifier.focusRequester(knopfOben)) { tafelOffen = true; zeigen() }
            }

            Column(Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(horizontal = TvStil.randSeite, vertical = TvStil.randOben),
                   verticalArrangement = Arrangement.spacedBy(11.dp)) {
                Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(werk.plan?.titel.orEmpty(), style = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.SemiBold),
                             color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        werk.plan?.untertitel?.takeIf { it.isNotEmpty() }?.let {
                            Text(it, style = TvStil.koerper, color = Color.White.copy(alpha = 0.68f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    if (werk.angebotArt != "keiner" && werk.angebotText.isNotEmpty()) {
                        TvPille(werk.angebotText, symbol = if (werk.angebotArt == "naechste") Icons.Filled.SkipNext else Icons.Filled.FastForward) {
                            angebotAusfuehren()
                        }
                    }
                }
                TvZeitleiste(position = werk.position, dauer = werk.dauer, marke = spulziel)
            }
        }

        TvWiedergabeblatt(offen = tafelOffen, schliessen = { tafelZu() }, werk = werk, app = app, ausgang = { blattAusgang[0] })

        if (folgenOffen) {
            TvFolgenblatt(app, schliessen = { folgenZu() }, ausgang = { blattAusgang[0] }) { id ->
                folgenZu()
                lauf.launch { werk.wechsleZu(id) }
            }
        }
    }
}

/** Ladering fuers Fernsehbild — groesser als am Telefon, auf drei Metern Entfernung gelesen. */
@Composable
private fun TvLader(groesse: androidx.compose.ui.unit.Dp) {
    androidx.compose.material3.CircularProgressIndicator(color = Stil.schrift, strokeWidth = 3.dp, modifier = Modifier.size(groesse))
}

/** Die Pille fuer „Nächste Folge"/„Vorspann überspringen" — heller Grund, wie am Telefon und auf tvOS. */
@Composable
private fun TvPille(text: String, symbol: ImageVector, tun: () -> Unit) {
    Fokusflaeche(lupe = 1.05f, tun = tun) { fokus ->
        Row(Modifier.height(46.dp).clip(CircleShape)
                .background(if (fokus) Color.White else Color.White.copy(alpha = 0.16f))
                .padding(horizontal = 20.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(symbol, contentDescription = null, tint = if (fokus) Stil.grund else Stil.schrift, modifier = Modifier.size(16.dp))
            Text(text, style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold), color = if (fokus) Stil.grund else Stil.schrift, maxLines = 1)
        }
    }
}

/**
 * Zeiten links und rechts, Leiste mit rundem Kopf dazwischen — Vorlage `Zeitleiste` in
 * `Sources/tvOS/PlayerScreen.swift`. Anders als dort **kein eigenes Fokusziel**: die Fernbedienung
 * wird global ausgewertet (siehe Dateikopf), die Leiste zeichnet nur den Stand.
 */
@Composable
private fun TvZeitleiste(position: Double, dauer: Double, marke: Double?) {
    val spult = marke != null
    val gezeigt = marke ?: position
    fun anteil(s: Double): Float = if (dauer > 0) (s / dauer).coerceIn(0.0, 1.0).toFloat() else 0f
    val balkenHoehe by animateDpAsState(if (spult) 8.dp else 4.dp, label = "balken")
    val kopf by animateDpAsState(if (spult) 19.dp else 13.dp, label = "kopf")
    val farbe = if (spult) Stil.akzent else Color.White.copy(alpha = 0.9f)
    val ziffern = TextStyle(fontSize = 13.sp, fontFeatureSettings = "tnum")

    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(13.dp)) {
        Text(zeitText(gezeigt), style = ziffern, color = farbe)
        BoxWithConstraints(Modifier.weight(1f).height(20.dp)) {
            val breite = maxWidth
            val stand = anteil(position)
            val ziel = anteil(gezeigt)
            Box(Modifier.align(Alignment.CenterStart).fillMaxWidth().height(balkenHoehe).clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.24f)))
            Box(Modifier.align(Alignment.CenterStart).width(breite * minOf(stand, ziel)).height(balkenHoehe).clip(CircleShape)
                    .background(Stil.akzent))
            // Die Strecke zwischen Stand und Ziel — wie weit das Spulen von hier entfernt landet.
            if (spult) Box(Modifier.align(Alignment.CenterStart)
                    .offset(x = breite * minOf(stand, ziel)).width(breite * abs(ziel - stand)).height(balkenHoehe)
                    .clip(CircleShape).background(Color.White.copy(alpha = 0.55f)))
            Box(Modifier.align(Alignment.CenterStart).offset(x = breite * ziel - kopf / 2).size(kopf).clip(CircleShape)
                    .background(if (spult) Stil.akzent else Color.White))
        }
        Text("−" + zeitText((dauer - gezeigt).coerceAtLeast(0.0)), style = ziffern, color = farbe)
    }
}

/**
 * Vorlage: `Folgenblatt` in `Sources/tvOS/Folgenblatt.swift` — die Folgen der laufenden Staffel,
 * aus dem Player heraus. Serie und Staffel muss Kotlin nicht mitbringen: `Kern.wiedergabeFolgen()`
 * liest sie am geladenen Titel selbst (derselbe Grundsatz wie beim Rest der Fassade — fertige
 * Antworten statt Einzelteile). Datenform und Zeile sind die der Serienseite (`Folge`,
 * `folgenLesen` aus `SerienSeite.kt`), keine zweite Auffassung von „eine Folge".
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
private fun TvFolgenblatt(app: SwiftlyAnwendung, schliessen: () -> Unit, ausgang: () -> Boolean, waehlen: (String) -> Unit) {
    var folgen by remember { mutableStateOf<List<Folge>>(emptyList()) }
    var laedt by remember { mutableStateOf(true) }
    LaunchedEffect(Unit) {
        folgen = try {
            folgenLesen(withContext(Dispatchers.IO) { app.kern.wiedergabeFolgen().await() })
        } catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() }
        laedt = false
    }
    val erste = remember { FocusRequester() }
    LaunchedEffect(laedt) { if (!laedt) { delay(30); runCatching { erste.requestFocus() } } }

    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.9f))) {
        // Innerhalb des Blatts: eine gewaehlte Folge zaehlt nicht als eigener Ausloeser fuer
        // `Fokusmerker`, sonst ginge der Fokus beim naechsten Oeffnen nicht mehr zum Knopf zurueck,
        // der dieses Blatt aufgemacht hat (siehe `LocalInnerhalbTafel` in TvStil.kt).
        CompositionLocalProvider(LocalInnerhalbTafel provides true) {
            // Geschlossene Fokusgruppe — siehe `blattAusgang` in `TvPlayer`. Oben aus der ersten Folge
            // erreicht so „Fertig" statt der Knoepfe dahinter.
            Column(Modifier.fillMaxSize().padding(horizontal = TvStil.randSeite, vertical = TvStil.randOben)
                       .focusProperties { exit = { if (ausgang()) FocusRequester.Default else FocusRequester.Cancel } }.focusGroup()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(uebersetzt("Folgen"), style = TextStyle(fontSize = 26.sp, fontWeight = FontWeight.SemiBold), color = Stil.schrift, modifier = Modifier.weight(1f))
                    TvKnopf(uebersetzt("Fertig")) { schliessen() }
                }
                Spacer(Modifier.height(28.dp))
                when {
                    // Vorlage: `Folgenblatt.swift:38-41` — drei `Ladefeld`-Zeilen in Form der
                    // Folgenzeile (Vorschaubild, Titel, Laenge) statt eines Rings.
                    laedt -> Column(Modifier.fillMaxWidth().weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        repeat(4) {
                            Row(Modifier.fillMaxWidth().padding(12.dp), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                                Ladefeld(Modifier.size(TvStil.querBreite, TvStil.querHoehe), TvStil.eckeKachel)
                                Column(Modifier.weight(1f).padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Ladefeld(Modifier.fillMaxWidth(0.5f).height(17.dp), 4.dp)
                                    Ladefeld(Modifier.width(80.dp).height(13.dp), 4.dp)
                                }
                            }
                        }
                    }
                    else -> LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        itemsIndexed(folgen, key = { _, f -> f.id }) { i, f ->
                            TvFolgenzeile(f, modifier = if (i == 0) Modifier.focusRequester(erste) else Modifier) { waehlen(f.id) }
                        }
                    }
                }
            }
        }
    }
    BackHandler(onBack = schliessen)
}

/** Eine Zeile im Folgenblatt — Vorlage `Folgenzeile` in `Sources/tvOS/SerienView.swift`: Vorschaubild
 *  links, Titel und Laenge rechts, ein leiser Haken bei gesehenen Folgen. */
@Composable
private fun TvFolgenzeile(folge: Folge, modifier: Modifier = Modifier, tun: () -> Unit) {
    Fokusflaeche(modifier.fillMaxWidth(), lupe = 1f, tun = tun) { fokus ->
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(TvStil.eckeKachel))
                .background(if (fokus) TvStil.fokusflaeche else Color.Transparent)
                .padding(12.dp),
            verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(20.dp)) {
            Box(Modifier.size(TvStil.querBreite, TvStil.querHoehe).clip(RoundedCornerShape(TvStil.eckeKachel)).background(Stil.flaeche)) {
                AsyncImage(model = folge.bild, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                folge.fortschritt?.takeIf { it > 0 }?.let { a ->
                    Box(Modifier.align(Alignment.BottomStart).padding(8.dp).fillMaxWidth().height(3.dp).clip(CircleShape)
                            .background(Color.White.copy(alpha = 0.25f))) {
                        Box(Modifier.fillMaxWidth(a.toFloat().coerceIn(0f, 1f)).fillMaxHeight().background(Stil.akzent))
                    }
                }
            }
            Column(Modifier.weight(1f).padding(top = 4.dp)) {
                Text(folge.titel, style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold), color = Stil.schrift,
                     maxLines = 1, overflow = TextOverflow.Ellipsis)
                folge.unterzeile?.let { Text(it, style = TvStil.klein, color = Stil.schriftSehrLeise, modifier = Modifier.padding(top = 5.dp)) }
            }
            if (folge.gesehen) Icon(Icons.Filled.Check, contentDescription = null, tint = Stil.schriftSehrLeise,
                                    modifier = Modifier.padding(top = 6.dp).size(18.dp))
        }
    }
}

/**
 * Vorlage: `Wiedergabeblatt` in `Sources/tvOS/Wiedergabeblatt.swift` — eine Achse statt zwei: links
 * die Kategorien (senkrecht), rechts die Karten dazu. Anders als das Telefon-Blatt (`Wiedergabetafel`
 * in `PlayerSeite.kt`, eine verschachtelte Ebene) stehen hier beide Spalten gleichzeitig da — genauso,
 * wie es die Vorlage begruendet: „Apples eigener Abspieler macht es so."
 *
 * Nicht uebernommen: der Technik-Auszug mit Bitrate/Bildflaeche/Ausgangzeile (`Wertfeld`,
 * `flaechenzeile` etc.) — das ist die Fehlersuche-Auskunft fuer Apples AVDisplayManager-Eigenheiten
 * und hat auf Android keine Entsprechung; das Technikschild deckt dieselbe Absicht ab.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
private fun TvWiedergabeblatt(offen: Boolean, schliessen: () -> Unit, werk: Spielwerk, app: SwiftlyAnwendung, ausgang: () -> Boolean) {
    if (!offen) return
    var kategorie by remember(offen) { mutableStateOf(Kategorie.UNTERTITEL) }
    val erste = remember { FocusRequester() }
    LaunchedEffect(offen) { delay(30); runCatching { erste.requestFocus() } }

    val tonspuren = remember(offen) { werk.spieler.audioTracks?.filter { it.id >= 0 }.orEmpty() }
    val untertitelspuren = remember(offen) { werk.spieler.spuTracks?.filter { it.id >= 0 }.orEmpty() }

    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)))
        // 560 pt auf tvOS, halbiert — vorher 420 dp, das schob den ganzen Inhalt zu weit nach oben.
        Box(Modifier.fillMaxWidth().height(280.dp).align(Alignment.BottomCenter)
                .background(Brush.verticalGradient(listOf(Stil.grund.copy(alpha = 0f), Stil.grund.copy(alpha = 0.9f), Stil.grund))))

        // Innerhalb der Tafel: eine gewaehlte Kategorie oder ein gewaehlter Wert zaehlt nicht als
        // eigener Ausloeser fuer `Fokusmerker`, sonst ginge der Fokus beim Schliessen nicht mehr
        // zum „Einstellungen"-Knopf zurueck, der diese Tafel geoeffnet hat (siehe `LocalInnerhalbTafel`
        // in TvStil.kt).
        CompositionLocalProvider(LocalInnerhalbTafel provides true) {
        // Dasselbe Muster wie das Folgenblatt: geschlossene Fokusgruppe, Ausgang nur programmatisch.
        Column(Modifier.align(Alignment.BottomStart).fillMaxWidth()
                   .padding(horizontal = TvStil.randSeite).padding(bottom = TvStil.randOben)
                   .focusProperties { exit = { if (ausgang()) FocusRequester.Default else FocusRequester.Cancel } }.focusGroup()) {
            // Vorlage: der Beleg steht neben dem Titel, nicht als Fusszeile unter allem —
            // derselbe Baustein wie auf der Titelseite (`Belegzeile`), keine zweite Fassung.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(werk.plan?.titel.orEmpty(), style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
                     color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.weight(1f))
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Belegzeile(werk.plan != null, werk.plan != null, werk.plan?.lossless == true, werk.plan?.methode, null, null)
                    werk.plan?.dateizeile?.let {
                        Text("· $it", style = TextStyle(fontSize = 14.5.sp), color = Stil.schriftSehrLeise, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            Spacer(Modifier.height(18.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(30.dp)) {
                Column(Modifier.width(230.dp)) {
                    // Derselbe Wortlaut wie tvOS' `spaltenmarke("Einstellungen")` — nicht „Wiedergabe".
                    Spaltenmarke(uebersetzt("Einstellungen"))
                    Kategorie.entries.forEachIndexed { i, k ->
                        Leistenzeile(k, k == kategorie, werk, app,
                            modifier = if (i == 0) Modifier.focusRequester(erste) else Modifier) { kategorie = k }
                    }
                }
                Column(Modifier.weight(1f)) {
                    Spaltenmarke(uebersetzt(kategorie.beschriftung))
                    Column(Modifier.heightIn(max = 200.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Karten(kategorie, werk, app, tonspuren, untertitelspuren)
                    }
                }
            }
        }
        }
    }
    BackHandler(onBack = schliessen)
}

private enum class Kategorie(val beschriftung: String, val symbol: ImageVector) {
    UNTERTITEL("Untertitel", Icons.Filled.ClosedCaption),
    TON("Ton", Icons.AutoMirrored.Filled.VolumeUp),
    BILD("Bild", Icons.Filled.AspectRatio),
    TEMPO("Tempo", Icons.Filled.Speed),
    SCHLAFZEIT("Schlafzeit", Icons.Filled.Bedtime),
    TECHNIK("Technikschild", Icons.Filled.BarChart),
}

@Composable
private fun Spaltenmarke(text: String) {
    Text(text.uppercase(), style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium, letterSpacing = 1.2.sp),
         color = Stil.schriftSehrLeise, modifier = Modifier.padding(bottom = 6.dp))
}

/** Die Zeile traegt Namen und Stand zugleich — ein Blick sagt, was eingestellt ist. */
@Composable
private fun Leistenzeile(k: Kategorie, an: Boolean, werk: Spielwerk, app: SwiftlyAnwendung, modifier: Modifier = Modifier, tun: () -> Unit) {
    val ton = remember { werk.spieler.audioTracks?.filter { it.id >= 0 }.orEmpty() }
    val spuren = remember { werk.spieler.spuTracks?.filter { it.id >= 0 }.orEmpty() }
    val wert = when (k) {
        Kategorie.UNTERTITEL -> spuren.firstOrNull { it.id == werk.spieler.spuTrack }?.name ?: uebersetzt("Aus")
        Kategorie.TON -> ton.firstOrNull { it.id == werk.spieler.audioTrack }?.name ?: uebersetzt("Keine")
        Kategorie.BILD -> uebersetzt(if (werk.bildfuellend) "Formatfüllend" else "Ganzes Bild")
        Kategorie.TEMPO -> tempoText(werk.tempo)
        Kategorie.SCHLAFZEIT -> if (werk.schlafzeit == 0) uebersetzt("Aus") else "${werk.schlafzeit}"
        Kategorie.TECHNIK -> uebersetzt(if (app.einstellungen.technikschild) "An" else "Aus")
    }
    // Vorlage: `LeistenStil` — die **gewaehlte** Kategorie traegt Weiss/dunkle Schrift, unabhaengig
    // vom Fokus; nur der Fokus einer *nicht* gewaehlten Zeile bekommt die ruhige Flaeche. Vorher
    // stand hier nur `fokus`, und die gewaehlte Kategorie sah aus wie jede andere Zeile mit
    // fluechtigem Fokus — grau statt weiss.
    Fokusflaeche(modifier.fillMaxWidth(), lupe = 1f, tun = tun) { fokus ->
        val farbe = if (an) Stil.grund else Stil.schrift
        // Halbiert aus tvOS' 62 pt Zeilenhoehe — 50 dp liess das ganze Blatt zu hoch wirken.
        Row(Modifier.fillMaxWidth().height(31.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(TvStil.ecke))
                .background(when { an -> Color.White; fokus -> TvStil.fokusflaeche; else -> Color.Transparent })
                .padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Icon(k.symbol, contentDescription = null, tint = farbe, modifier = Modifier.size(19.dp))
            Text(uebersetzt(k.beschriftung), style = TextStyle(fontSize = 15.5.sp, fontWeight = if (an) FontWeight.SemiBold else FontWeight.Normal),
                 color = farbe, modifier = Modifier.weight(1f))
            Text(wert, style = TextStyle(fontSize = 13.5.sp), color = if (an) farbe.copy(alpha = 0.6f) else Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun Karten(kategorie: Kategorie, werk: Spielwerk, app: SwiftlyAnwendung,
                    tonspuren: List<org.videolan.libvlc.MediaPlayer.TrackDescription>,
                    untertitelspuren: List<org.videolan.libvlc.MediaPlayer.TrackDescription>) {
    when (kategorie) {
        Kategorie.UNTERTITEL -> {
            Wahlkarte(uebersetzt("Aus"), werk.spieler.spuTrack == -1) { werk.spieler.spuTrack = -1 }
            untertitelspuren.forEach { s -> Wahlkarte(s.name, werk.spieler.spuTrack == s.id) { werk.spieler.spuTrack = s.id } }
        }
        Kategorie.TON -> tonspuren.forEach { s -> Wahlkarte(s.name, werk.spieler.audioTrack == s.id) { werk.spieler.audioTrack = s.id } }
        Kategorie.TEMPO -> listOf(0.75f, 1f, 1.25f, 1.5f, 2f).forEach { stufe ->
            Wahlkarte(tempoText(stufe), abs(werk.tempo - stufe) < 0.01f) { werk.tempoSetzen(stufe) }
        }
        Kategorie.SCHLAFZEIT -> {
            Wahlkarte(uebersetzt("Aus"), werk.schlafzeit == 0) { werk.schlafzeitSetzen(0) }
            listOf(15, 30, 45, 60, 90).forEach { m -> Wahlkarte(uebersetzt("%lld Minuten", m), werk.schlafzeit == m) { werk.schlafzeitSetzen(m) } }
        }
        Kategorie.BILD -> {
            Wahlkarte(uebersetzt("Ganzes Bild"), !werk.bildfuellend) { werk.bildfuellendSetzen(false) }
            Wahlkarte(uebersetzt("Formatfüllend"), werk.bildfuellend) { werk.bildfuellendSetzen(true) }
        }
        // Nur an/aus — der Auszug selbst steht oben links ueber dem laufenden Film (`Technikschild`).
        Kategorie.TECHNIK -> {
            Wahlkarte(uebersetzt("An"), app.einstellungen.technikschild) { app.einstellungen.technikschild = true }
            Wahlkarte(uebersetzt("Aus"), !app.einstellungen.technikschild) { app.einstellungen.technikschild = false }
        }
    }
}

/** Eine Karte in der Werte-Reihe — Vorlage `Wahlkarte` in `Sources/tvOS/Wiedergabeblatt.swift`. */
@Composable
private fun Wahlkarte(name: String, an: Boolean, tun: () -> Unit) {
    Fokusflaeche(Modifier.fillMaxWidth(), lupe = 1.02f, tun = tun) { fokus ->
        Row(Modifier.fillMaxWidth().heightIn(min = 52.dp)
                .clip(androidx.compose.foundation.shape.RoundedCornerShape(TvStil.ecke))
                .background(if (fokus) TvStil.fokusflaeche else Stil.flaeche)
                .padding(horizontal = 18.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text(name, style = TextStyle(fontSize = 15.sp, fontWeight = if (an) FontWeight.SemiBold else FontWeight.Medium),
                 color = if (an) Stil.akzent else Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            if (an) Icon(Icons.Filled.Check, contentDescription = null, tint = Stil.akzent, modifier = Modifier.size(17.dp))
        }
    }
}
