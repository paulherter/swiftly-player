package de.paulherter.swiftly.tv

import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.runtime.withFrameNanos
import android.os.SystemClock
import android.util.Log
import androidx.activity.compose.BackHandler
import androidx.annotation.DrawableRes
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.zIndex
import de.paulherter.swiftly.Abspielwunsch
import de.paulherter.swiftly.Folge
import de.paulherter.swiftly.R
import de.paulherter.swiftly.Spielplan
import de.paulherter.swiftly.Spielwerk
import de.paulherter.swiftly.Staffel
import de.paulherter.swiftly.SwiftlyAnwendung
import de.paulherter.swiftly.Technikschild
import de.paulherter.swiftly.Wahl
import de.paulherter.swiftly.aktivitaet
import de.paulherter.swiftly.folgenLesen
import de.paulherter.swiftly.folgenVorladen
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.kern.Kern
import de.paulherter.swiftly.serieLesen
import de.paulherter.swiftly.wahlenLesen
import de.paulherter.swiftly.zeitText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Vorlage: `PlayerScreen` und `PlayerEbenen` in `Sources/tvOS/`.
 *
 * Die Wiedergabe-Mechanik (VLC, Takt, Meldungen, Mediensitzung) steckt in `Spielwerk`
 * (`PlayerSeite.kt`) — dieselbe Klasse, die auch der Telefon-Player benutzt. Hier steht nur,
 * was am Fernseher anders ist: kein Finger, sondern die Fernbedienung.
 *
 * **Gestaltung wie tvOS:** flache Abdunklung in reinem Schwarz, oben links Titel und Metazeile,
 * oben rechts nur Symbolknoepfe (Audio & Untertitel, Folgen, Einstellungen), unten die Leiste.
 * Kein Schliessen-Knopf, kein Pausezeichen in der Mitte, keine Sprungknoepfe: bedient wird mit dem
 * Steuerkreuz, Zurueck schliesst.
 *
 * **Fernbedienung:** OK haelt an oder bestaetigt eine gesammelte Sprungmarke; links/rechts sammeln
 * 350 ms lang, bevor **einmal** gesprungen wird — VLC baut bei jedem Sprung den Strom neu auf.
 * Hoch fuehrt zu den Symbolen oben (steht die Ueberspringen-Pille da, zuerst zu ihr).
 * Zurueck: Sprungmarke verwerfen → Ebene zu → Steuerung aus → Einblendung zu → Player zu.
 */
@Composable
fun TvPlayer(app: SwiftlyAnwendung, wunsch: Abspielwunsch, schliessen: () -> Unit) {
    val kontext = LocalContext.current
    val aktivitaet = remember(kontext) { kontext.aktivitaet() }
    val lauf = rememberCoroutineScope()

    // Der Player laeuft in einer eigenen Activity (`PlayerAktivitaet`) — ein `Fokusmerker.letzter`
    // von der vorigen Seite gehoert zu einer fremden Komposition. Den Rueckweg nach dem Player
    // haelt `Fokusmerker.vorDemPlayer` (gesetzt in `TvHaupt`).
    LaunchedEffect(Unit) { Fokusmerker.letzter = null }

    val werk = remember { Spielwerk(app, kontext, lauf) }
    val flaeche = remember { arrayOfNulls<org.videolan.libvlc.util.VLCVideoLayout>(1) }
    @Suppress("DEPRECATION")
    val lebenslauf = androidx.compose.ui.platform.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lebenslauf) {
        val beobachter = androidx.lifecycle.LifecycleEventObserver { _, ereignis ->
            if (ereignis == androidx.lifecycle.Lifecycle.Event.ON_PAUSE) werk.hintergrundMelden()
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
    // Staffeln und laufende Staffel vorladen — die Folgenebene steht beim Oeffnen schon da
    // (Vorlage `FolgenEbene.vorladen` auf tvOS).
    LaunchedEffect(werk.plan?.itemId) {
        val p = werk.plan
        if (p != null && p.episode && p.serieId != null) folgenVorladen(app, p.serieId, p.staffelId)
    }

    // **Bildtakt vor dem ersten Bild anstossen, dann in Ruhe lassen** — siehe `TvBildtakt`.
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
    /** `spuren`, `folgen` oder `einstellungen` — Vorlage `Playerebene`. */
    var offeneEbene by remember { mutableStateOf<String?>(null) }
    val ebeneOffen = offeneEbene != null

    LaunchedEffect(sichtbar) { werk.steuerungGeaendert(sichtbar) }
    LaunchedEffect(sichtbar, werk.laeuft, offeneEbene, beruehrt) {
        if (sichtbar && werk.laeuft && offeneEbene == null) { delay(4000); sichtbar = false }
    }
    LaunchedEffect(werk.hinweis) { if (werk.hinweis != null) { delay(5000); werk.hinweis = null } }

    fun zeigen() { sichtbar = true; beruehrt++ }

    // **Die Wiedergabetaste schaltet gegen den gewollten Stand**, nicht gegen VLCs Meldung (Vorlage
    // `Schaltwerk` auf tvOS). Die Meldung kommt erst nach dem Befehl; wer schnell zweimal drueckte,
    // schaltete sonst gegen den alten Stand, und der zweite Druck ging verloren. VLCs Meldung wird
    // erst eine Sekunde nach dem letzten Befehl zum gewollten Stand — dann ist sie etwas, das VLC
    // von selbst getan hat (Ende, Schlafzeit).
    val gewollt = remember { booleanArrayOf(false) }
    val zuletztBefohlen = remember { longArrayOf(0L) }
    LaunchedEffect(werk.laeuft) {
        if (SystemClock.elapsedRealtime() - zuletztBefohlen[0] > 1000) gewollt[0] = werk.laeuft
    }

    // Spulen: sammeln, **einmal** springen — Vorlage `PlayerScreen.springen` (tvOS).
    var spulziel by remember { mutableStateOf<Double?>(null) }
    val letzterSchritt = remember { longArrayOf(0L) }
    var sammler by remember { mutableStateOf<Job?>(null) }
    fun markeVerwerfen() { sammler?.cancel(); spulziel = null }
    fun spulen(um: Int) {
        if (!sichtbar) { zeigen(); return }
        val jetzt = SystemClock.elapsedRealtime()
        val seitLetztem = jetzt - letzterSchritt[0]
        letzterSchritt[0] = jetzt
        zeigen()
        val ziel = (spulziel ?: werk.position) + um
        if (spulziel == null && seitLetztem > 450) { werk.springe(ziel); return }
        spulziel = ziel
        sammler?.cancel()
        sammler = lauf.launch { delay(350); spulziel?.let { werk.springe(it) }; spulziel = null }
    }

    fun laufenSetzen(soll: Boolean, quelle: String) {
        gewollt[0] = soll
        zuletztBefohlen[0] = SystemClock.elapsedRealtime()
        // Anhalten/Weiter heisst „hier", nicht „dorthin" — eine Marke wird verworfen.
        markeVerwerfen()
        if (soll) werk.spieler.play() else werk.spieler.pause()
        Log.i("Swiftly", "[Taste] $quelle: ${if (soll) "abspielen" else "anhalten"}")
        zeigen()
    }
    fun umschalten(quelle: String) = laufenSetzen(!gewollt[0], quelle)

    val fernbedienung = remember { FocusRequester() }
    val knopfSpuren = remember { FocusRequester() }
    val knopfFolgen = remember { FocusRequester() }
    val knopfEinstellungen = remember { FocusRequester() }
    val angebotFokus = remember { FocusRequester() }
    /** Hoch bei ausgeblendeter Steuerung: der Knopf haengt erst noch ein, er holt sich den Fokus selbst. */
    val obenWunsch = remember { booleanArrayOf(false) }
    /** Gibt den gesperrten Ausgang der Ebene fuer das Zuruecklegen des Fokus frei. */
    val ebenenAusgang = remember { booleanArrayOf(false) }

    val plan = werk.plan
    val hatFolgen = plan?.episode == true && plan.serieId != null
    val titel = plan?.kopfzeile?.takeIf { it.isNotEmpty() } ?: plan?.titel.orEmpty()
    val meta = plan?.let {
        if (it.episode && it.staffelNr != null && it.folgeNr != null) uebersetzt("Staffel %lld · Folge %lld", it.staffelNr, it.folgeNr)
        else if (it.episode) it.untertitel.takeIf { u -> u.isNotEmpty() }
        else it.nebenzeile?.takeIf { n -> n.isNotEmpty() }
    }

    // **Vor dem ersten Bild keine Steuerung, nur der Lader** (`steuerungDa` auf tvOS: `erstesBildDa`).
    val steuerungZiel = sichtbar && werk.bildFrei && !ebeneOffen
    val deckung by animateFloatAsState(
        if (steuerungZiel) 1f else 0f,
        if (steuerungZiel) tween(180, easing = Bewegung.weich) else tween(340, easing = Bewegung.weich),
        label = "steuerung")
    // Unter einer offenen Ebene bleibt die Steuerung eingehaengt (unsichtbar): der Knopf, der die
    // Ebene geoeffnet hat, muss den Fokus beim Schliessen annehmen koennen, **bevor** die Ebene weggeht.
    val werkzeugeDa = deckung > 0.01f || ebeneOffen
    val titelZiel = steuerungZiel || offeneEbene == "folgen"
    val titelDeckung by animateFloatAsState(if (titelZiel) 1f else 0f, tween(200), label = "titel")

    fun nachOben() {
        val schonDa = deckung > 0.01f
        zeigen()
        if (schonDa) runCatching { knopfSpuren.requestFocus() } else obenWunsch[0] = true
    }

    fun ebeneOeffnen(welche: String) {
        Log.i("Swiftly", "[Ebene] auf $welche")
        ebenenAusgang[0] = false
        offeneEbene = welche
        beruehrt++
    }
    // **Zurueck an den Knopf, der die Ebene geoeffnet hat** — erst der Fokus, dann die Ebene weg.
    fun ebeneSchliessen() {
        val war = offeneEbene ?: return
        Log.i("Swiftly", "[Ebene] zu $war")
        ebenenAusgang[0] = true
        val ziel = when (war) { "spuren" -> knopfSpuren; "folgen" -> if (hatFolgen) knopfFolgen else fernbedienung; else -> knopfEinstellungen }
        if (runCatching { ziel.requestFocus() }.isFailure) runCatching { fernbedienung.requestFocus() }
        offeneEbene = null
        zeigen()
        // Solange die Ebene steht, sind die Knoepfe darunter gesperrt — der Wunsch oben greift
        // nicht. Zwei Bilder spaeter, wenn die Steuerung wieder da ist, noch einmal.
        lauf.launch {
            repeat(2) { withFrameNanos { } }
            runCatching { ziel.requestFocus() }
        }
    }

    // **Die Einblendung** ohne Steuerung (Vorlage `karteDa`/`angebotsebene`): solange sie steht,
    // liegt der Fokus auf ihr. Danach an die Fernbedienungsflaeche, nicht an einen Knopf (Plezy #1890).
    val karteDa = werk.einblendung != "nichts" && werk.bildFrei && !steuerungZiel && !ebeneOffen && !werk.wechselt
    LaunchedEffect(karteDa) {
        if (karteDa) {
            runCatching { angebotFokus.requestFocus() }
            delay(80)
            runCatching { angebotFokus.requestFocus() }
            Log.i("Swiftly", "Angebot: ein (${werk.einblendung}), Fokus auf dem Knopf")
        } else if (!steuerungZiel && !ebeneOffen) {
            runCatching { fernbedienung.requestFocus() }
        }
    }
    // **Der Fokus geht mit der Steuerung**, statt mit ihr zu verschwinden (Vorlage `onChange(of: steuerungDa)`):
    // auf einem ausblendenden Knopf oeffnete OK sonst eine unsichtbare Ebene.
    LaunchedEffect(steuerungZiel) {
        if (!steuerungZiel && !ebeneOffen && !karteDa) runCatching { fernbedienung.requestFocus() }
    }

    // Beim Spulen weicht die Pille der Vorschau ueber der Leiste (Vorlage `angebotDa`).
    val angebotDa = werk.angebotArt != "keiner" && werk.angebotText.isNotEmpty() && werk.bildFrei && !ebeneOffen
        && !werk.wechselt && spulziel == null
        && (werk.einblendung != "nichts" || (steuerungZiel && werk.angebotArt == "naechste"))

    // Verschwindet die Pille unter dem Fokus (gedrueckt, Abschnitt vorbei, Spulen), geht er an die
    // Flaeche — sonst stuende er im Nichts.
    var pilleHatFokus by remember { mutableStateOf(false) }
    LaunchedEffect(angebotDa) { if (!angebotDa && pilleHatFokus) runCatching { fernbedienung.requestFocus() } }

    // **Zurueck** — dieselbe Reihenfolge wie `onExitCommand` auf tvOS. Die Staffelwahl in der
    // Folgenebene haengt sich spaeter ein und kommt deshalb zuerst dran.
    BackHandler {
        when {
            spulziel != null -> markeVerwerfen()
            offeneEbene != null -> ebeneSchliessen()
            steuerungZiel -> {
                runCatching { fernbedienung.requestFocus() }
                sichtbar = false
                Log.i("Swiftly", "[Zurück] Steuerung aus")
            }
            karteDa -> { werk.angebotSchliessen(); Log.i("Swiftly", "[Angebot] Zurück schließt") }
            else -> werk.beenden(schliessen)
        }
    }

    // **Nur die Leiste deutet Richtungen.** `onKeyEvent` am aeusseren Kasten bekommt auch, was ein
    // fokussierter Knopf oben rechts nicht verbraucht.
    var leisteFokus by remember { mutableStateOf(false) }
    fun taste(e: KeyEvent): Boolean {
        if (ebeneOffen || !leisteFokus) return false
        if (e.type != KeyEventType.KeyDown) return false
        when (e.key) {
            Key.DirectionCenter, Key.Enter, Key.NumPadEnter, Key.Spacebar -> {
                if (e.nativeKeyEvent.repeatCount > 0) return true
                val ziel = spulziel
                if (ziel != null) { zeigen(); markeVerwerfen(); werk.springe(ziel) } else umschalten("Klick")
            }
            Key.DirectionLeft -> spulen(-werk.zurueckS)
            Key.DirectionRight -> spulen(werk.vorS)
            Key.MediaRewind -> spulen(-werk.zurueckS)
            Key.MediaFastForward -> spulen(werk.vorS)
            Key.MediaNext -> if (werk.plan?.naechste == true) lauf.launch { werk.naechsteFolge() }
            // **Hoch fuehrt direkt zu den Symbolen** — auch beim ersten Druck, wenn die Steuerung
            // noch aus ist (tvOS 5a5f3cd). Steht die Pille ueber der Leiste, liegt sie dazwischen.
            Key.DirectionUp -> if (sichtbar && angebotDa) runCatching { angebotFokus.requestFocus() } else nachOben()
            Key.Menu -> if (werk.bildFrei) ebeneOeffnen("einstellungen")
            Key.DirectionDown -> { sichtbar = !sichtbar; beruehrt++ }
            else -> return false
        }
        return true
    }

    // **Die Wiedergabetaste gilt ueberall im Player** (`onPlayPauseCommand`), auch auf einem Knopf
    // oder in einer Ebene. Gehaltene Tasten wiederholen nicht.
    fun wiedergabetaste(e: KeyEvent): Boolean {
        val k = e.key
        if (k != Key.MediaPlayPause && k != Key.MediaPlay && k != Key.MediaPause) return false
        if (e.type != KeyEventType.KeyDown || e.nativeKeyEvent.repeatCount > 0) return true
        when (k) {
            Key.MediaPlay -> laufenSetzen(true, "Abspieltaste")
            Key.MediaPause -> laufenSetzen(false, "Pausetaste")
            else -> umschalten("Wiedergabetaste")
        }
        return true
    }

    CompositionLocalProvider(LocalInnerhalbTafel provides true) {
    Box(Modifier.fillMaxSize().background(Color.Black).onPreviewKeyEvent { wiedergabetaste(it) }) {
    Box(Modifier.fillMaxSize()
            .focusRequester(fernbedienung).onFocusChanged { leisteFokus = it.isFocused }.focusable().onKeyEvent { taste(it) }) {
        AndroidView(factory = { ctx -> org.videolan.libvlc.util.VLCVideoLayout(ctx).also { flaeche[0] = it; werk.spieler.attachViews(it, null, true, false) } },
                    modifier = Modifier.fillMaxSize())

        if (!werk.bildFrei) {
            Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
                if (werk.hinweis == null) TvLader(groesse = 64.dp)
            }
        }

        // **Nur noch der Ring, kein Pausezeichen** — angehalten zeigt die Leiste (Vorlage tvOS).
        if (werk.bildFrei && (werk.wechselt || (werk.laeuft && werk.puffert))) {
            Box(Modifier.align(Alignment.Center)) { TvLader(groesse = 64.dp) }
        }

        if (werkzeugeDa) {
            // **Reines Schwarz, 42 %** — ohne Verlaeufe (Vorlage `schleier`).
            Box(Modifier.fillMaxSize().graphicsLayer { alpha = deckung }.background(Color.Black.copy(alpha = 0.42f)))
            Box(Modifier.fillMaxSize().graphicsLayer { alpha = deckung }
                    .padding(horizontal = TvStil.randSeite, vertical = TvStil.randOben)) {
                val spult = spulziel != null
                // Links Platz fuer den Titel (den zeichnet `stehender Titel`) und darunter die Metazeile.
                Row(Modifier.fillMaxWidth().align(Alignment.TopStart), verticalAlignment = Alignment.Top) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(TvPlayermass.titelAbstand)) {
                        Text(titel, style = TvPlayermass.titel, maxLines = 1, modifier = Modifier.alpha(0f))
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            meta?.let { Text(it, style = TvPlayermass.meta, color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                            if (plan != null && !plan.lossless && plan.methode.isNotEmpty()) {
                                Icon(painterResource(R.drawable.player_warnung), contentDescription = null, tint = Stil.warnung, modifier = Modifier.size(15.dp))
                                Text(plan.methode, style = TvPlayermass.meta, color = Stil.warnung, maxLines = 1)
                            }
                        }
                    }
                    Spacer(Modifier.width(24.dp))
                    // Audio & Untertitel, Folgen (nur bei Folgen), Einstellungen. Beim Spulen weichen sie.
                    Row(Modifier.alpha(if (spult) 0f else 1f)
                            .onPreviewKeyEvent { e ->
                                if (e.type == KeyEventType.KeyDown) zeigen()
                                when (e.key) {
                                    Key.DirectionDown -> { if (e.type == KeyEventType.KeyDown) runCatching { fernbedienung.requestFocus() }; true }
                                    Key.DirectionUp -> true
                                    else -> false
                                }
                            },
                        horizontalArrangement = Arrangement.spacedBy(TvPlayermass.knopfAbstand)) {
                        TvSymbolknopf(R.drawable.player_untertitel, uebersetzt("Audio & Untertitel"), !spult, knopfSpuren) { ebeneOeffnen("spuren") }
                        if (hatFolgen) TvSymbolknopf(R.drawable.player_folgen, uebersetzt("Folgen"), !spult, knopfFolgen) { ebeneOeffnen("folgen") }
                        TvSymbolknopf(R.drawable.player_regler, uebersetzt("Einstellungen"), !spult, knopfEinstellungen) { ebeneOeffnen("einstellungen") }
                        LaunchedEffect(Unit) {
                            if (obenWunsch[0]) {
                                obenWunsch[0] = false
                                repeat(5) { if (runCatching { knopfSpuren.requestFocus() }.isSuccess) return@LaunchedEffect; delay(30) }
                            }
                        }
                    }
                }
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth()
                        .semantics(mergeDescendants = true) {
                            contentDescription = uebersetzt("Abspielstelle")
                            stateDescription = zeitText(werk.position) + " / " + zeitText(werk.dauer)
                        }) {
                    TvZeitleiste(werk.position, werk.dauer, spulziel, werk.laeuft) { werk.trickplayBild(it) }
                }
            }
        }

        // **Der Angebotsknopf**, rechts direkt ueber der Leiste — mit und ohne Steuerung an derselben Stelle.
        AnimatedVisibility(visible = angebotDa, modifier = Modifier.align(Alignment.BottomEnd),
            enter = fadeIn(tween(180, easing = Bewegung.weich)),
            exit = fadeOut(tween(340, easing = Bewegung.weich))) {
            Box(Modifier.padding(end = TvStil.randSeite, bottom = TvStil.randOben + TvPlayermass.leiste + TvPlayermass.ueberLeiste)
                    .onFocusChanged { pilleHatFokus = it.hasFocus }
                    .onPreviewKeyEvent { e ->
                        val richtung = e.key == Key.DirectionUp || e.key == Key.DirectionDown || e.key == Key.DirectionLeft || e.key == Key.DirectionRight
                        if (!richtung) return@onPreviewKeyEvent false
                        if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent true
                        if (!steuerungZiel) {
                            // Ohne Steuerung holt jede Richtung sie. Eine Karte ist damit abgesagt, ein
                            // Ueberspringen-Knopf bleibt stehen.
                            Log.i("Swiftly", "Angebot: Richtungstaste holt die Steuerung")
                            zeigen()
                        } else when (e.key) {
                            Key.DirectionUp -> runCatching { knopfSpuren.requestFocus() }
                            Key.DirectionDown -> runCatching { fernbedienung.requestFocus() }
                            else -> {}
                        }
                        true
                    }) {
                TvAngebotspille(werk.angebotText,
                    anteil = werk.countdown.takeIf { werk.einblendung == "karte" },
                    sekunden = werk.countdownRest.takeIf { werk.einblendung == "karte" },
                    laeuft = werk.laeuft, laenge = werk.countdownLaenge,
                    modifier = Modifier.focusRequester(angebotFokus)) {
                    Log.i("Swiftly", "Angebot: gedrückt (${werk.angebotArt})")
                    werk.angebotAusfuehren()
                }
            }
        }

        werk.hinweis?.let {
            Text(it, style = TextStyle(fontSize = 15.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center), color = Stil.schrift,
                 modifier = Modifier.align(Alignment.TopCenter).padding(top = 90.dp, start = 96.dp, end = 96.dp))
        }

        // **Das Technikschild** — ueber der Steuerung, unter den Ebenen. Nimmt keinen Fokus.
        if (app.einstellungen.technikschild && werk.technikFest.isNotEmpty()) {
            Technikschild(werk.technikFest, werk.technikLive, werk.position, werk.dauer,
                Modifier.align(Alignment.TopStart).padding(start = TvStil.randSeite, top = TvStil.randOben))
        }

        // **Die drei Ebenen** — Vollbild ueber dem Bild, geschlossene Fokusgruppe: der Fokus bleibt
        // drin, bis Zurueck sie schliesst.
        var zuletztEbene by remember { mutableStateOf("spuren") }
        LaunchedEffect(offeneEbene) { offeneEbene?.let { zuletztEbene = it } }
        AnimatedVisibility(visible = ebeneOffen, enter = fadeIn(tween(200)), exit = fadeOut(tween(200))) {
            @OptIn(ExperimentalComposeUiApi::class)
            Box(Modifier.fillMaxSize()
                    .focusProperties { exit = { if (ebenenAusgang[0]) FocusRequester.Default else FocusRequester.Cancel } }
                    .focusGroup()) {
                // **Kein Weichzeichner:** VLC zeichnet in eine `SurfaceView`, die das System getrennt
                // zusammensetzt — ein `RenderEffect` erreicht sie nicht (dieselbe Lage wie am Handy,
                // `Ebenengrund` in PlayerSeite.kt). Ersatz: reines Schwarz, 80 %.
                Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.8f)))
                when (offeneEbene ?: zuletztEbene) {
                    "spuren" -> TvSpurenEbene(werk)
                    "einstellungen" -> TvEinstellungsEbene(werk, app, ebeneSchliessen = { ebeneSchliessen() })
                    "folgen" -> plan?.takeIf { hatFolgen }?.let { p ->
                        TvFolgenEbene(app, p, titel) { f ->
                            ebeneSchliessen()
                            // Die laufende Folge waehlen heisst: weiterschauen.
                            if (f.id != p.itemId) lauf.launch { werk.wechsleZu(f.id) }
                        }
                    }
                }
            }
        }

        // **Der Titel oben links, eine Ebene ueber allem** — bei offener Folgenebene bleibt er stehen.
        if (titelDeckung > 0.01f) {
            Row(Modifier.fillMaxWidth().graphicsLayer { alpha = titelDeckung }
                    .padding(horizontal = TvStil.randSeite).padding(top = TvStil.randOben)) {
                Text(titel, style = TvPlayermass.titel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis,
                     modifier = Modifier.weight(1f))
                Spacer(Modifier.width(24.dp + TvPlayermass.symbolreihe(if (hatFolgen) 3 else 2)))
            }
        }
    }
    }
    }
}

/**
 * Masse des Players auf dem Fernseher — `Playermass` in `Sources/tvOS/PlayerEbenen.swift`, halbiert
 * (tvOS rechnet in 1920 Punkten Breite, Android TV in 960 dp).
 */
private object TvPlayermass {
    val titel = TextStyle(fontSize = 28.5.sp, fontWeight = FontWeight.Bold)
    val meta = TextStyle(fontSize = 15.5.sp)
    val zeit = 14.sp
    val vorschauZeit = 16.sp
    val leisteGrund = Color.White.copy(alpha = 0.28f)
    val titelAbstand = 3.dp
    val knopf = 44.dp
    val knopfAbstand = 10.dp
    val ueberLeiste = 20.dp
    val leiste = 20.dp
    val spalte = 250.dp
    val spaltenAbstand = 57.dp
    val spaltenOben = 76.dp
    fun symbolreihe(anzahl: Int) = knopf * anzahl + knopfAbstand * (anzahl - 1)
}

/** Ladering fuers Fernsehbild — groesser als am Telefon, auf drei Metern Entfernung gelesen. */
@Composable
private fun TvLader(groesse: androidx.compose.ui.unit.Dp) {
    androidx.compose.material3.CircularProgressIndicator(color = Stil.schrift, strokeWidth = 3.dp, modifier = Modifier.size(groesse))
}

/** Einer der Symbolknoepfe oben rechts: ruhend nur das Zeichen, fokussiert die weisse Flaeche (`SymbolknopfStil`). */
@Composable
private fun TvSymbolknopf(@DrawableRes symbol: Int, beschreibung: String, aktiv: Boolean, fokus: FocusRequester, tun: () -> Unit) {
    Fokusflaeche(Modifier.focusRequester(fokus).focusProperties { canFocus = aktiv }
            .semantics { contentDescription = beschreibung }, lupe = 1.04f, tun = tun) { hat ->
        Box(Modifier.size(TvPlayermass.knopf).clip(RoundedCornerShape(TvStil.ecke))
                .background(if (hat) Color.White else Color.Transparent), contentAlignment = Alignment.Center) {
            // Die Groesse steht im Zeichen selbst (Glyphe bei 19 — tvOS 38 pt, halbiert).
            Icon(painterResource(symbol), contentDescription = null, tint = if (hat) Stil.grund else Stil.schrift)
        }
    }
}

/**
 * **Die Ueberspringen-Pille: weiss, dunkle Schrift** (`PillenStil` auf tvOS). Der Countdown fuellt sie
 * dunkel von links — die Akzentfarbe gehoert im Player allein dem Griff der Leiste.
 */
@Composable
private fun TvAngebotspille(text: String, anteil: Double?, sekunden: Int?, laeuft: Boolean, laenge: Double,
                            modifier: Modifier = Modifier, tun: () -> Unit) {
    val fuellung = de.paulherter.swiftly.durchgehendeFuellung(anteil, laeuft, laenge)
    val form = RoundedCornerShape(TvStil.ecke)
    Fokusflaeche(modifier = modifier.semantics(mergeDescendants = true) {
        if (sekunden != null) stateDescription = uebersetzt("Startet in %lld Sekunden", sekunden)
    }, lupe = 1.08f, tun = tun) { fokus ->
        Row(Modifier.height(36.dp).shadow(if (fokus) 13.dp else 6.dp, form).clip(form).background(Stil.schrift)
                .drawBehind {
                    if (anteil != null) drawRect(Stil.grund.copy(alpha = 0.16f), size = size.copy(width = size.width * fuellung))
                }
                .padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            Icon(painterResource(R.drawable.player_ueberspringen), contentDescription = null, tint = Stil.grund, modifier = Modifier.size(15.dp))
            Text(text, style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Bold), color = Stil.grund, maxLines = 1)
        }
    }
}

/**
 * Zeit, Leiste, Restzeit — Vorlage `Zeitleiste` in `Sources/tvOS/PlayerScreen.swift`. **Kein eigenes
 * Fokusziel**: die Fernbedienung wird an der Flaeche ausgewertet, die Leiste zeichnet nur den Stand.
 * Angehalten steht das Pausezeichen vor der Zeit. Beim Spulen wird die Leiste dicker, der Griff
 * erscheint in Akzentfarbe, darueber das Trickplay-Bild mit der Zielzeit (ohne Trickplay nur die Zeit).
 */
@Composable
private fun TvZeitleiste(position: Double, dauer: Double, marke: Double?, laeuft: Boolean,
                         vorschau: (Double) -> android.graphics.Bitmap?) {
    val spult = marke != null
    val gezeigt = marke ?: position
    fun anteil(s: Double): Float = if (dauer > 0) (s / dauer).coerceIn(0.0, 1.0).toFloat() else 0f
    val balken by animateDpAsState(if (spult) 6.dp else 4.dp, tween(180), label = "balken")
    val griffSkala by animateFloatAsState(if (spult) 1f else 0.4f, tween(180), label = "griffSkala")
    val griffDeckung by animateFloatAsState(if (spult) 1f else 0f, tween(180), label = "griffDeckung")
    val ziffern = TextStyle(fontSize = TvPlayermass.zeit, fontFeatureSettings = "tnum")

    Row(Modifier.fillMaxWidth().height(TvPlayermass.leiste), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            AnimatedVisibility(visible = !laeuft, enter = fadeIn(tween(180)) + expandHorizontally(tween(180)),
                               exit = fadeOut(tween(180)) + shrinkHorizontally(tween(180))) {
                Icon(painterResource(R.drawable.player_pause), contentDescription = null, tint = Stil.schrift,
                     modifier = Modifier.padding(end = 8.dp).size(10.dp, 12.dp))
            }
            Text(zeitText(position), style = ziffern, color = Stil.schriftLeise)
        }
        BoxWithConstraints(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.CenterStart) {
            val breite = maxWidth
            val stand = anteil(position)
            val ziel = anteil(gezeigt)
            Box(Modifier.fillMaxWidth().height(balken).clip(CircleShape).background(TvPlayermass.leisteGrund))
            // Bis zur wirklichen Stelle: das ist gesehen.
            Box(Modifier.width(breite * minOf(stand, ziel)).height(balken).clip(CircleShape).background(Stil.schrift))
            // Die Strecke zwischen Stand und Ziel — wie weit das Spulen von hier entfernt landet.
            if (spult) Box(Modifier.offset(x = breite * minOf(stand, ziel)).width(breite * abs(ziel - stand)).height(balken)
                    .clip(CircleShape).background(Color.White.copy(alpha = 0.55f)))
            Box(Modifier.offset(x = breite * ziel - 9.dp).size(18.dp)
                    .graphicsLayer { scaleX = griffSkala; scaleY = griffSkala; alpha = griffDeckung }
                    .shadow(5.dp, CircleShape).background(Stil.akzent, CircleShape))
            if (spult) {
                val bild = vorschau(gezeigt)
                // Unterkante knapp ueber der Leiste, waagerecht ueber dem Griff; am Rand bleibt der Kasten
                // ganz auf der Leiste stehen.
                Column(Modifier.align(Alignment.TopStart).layout { messbar, _ ->
                        val p = messbar.measure(Constraints())
                        layout(0, 0) {
                            val gesamt = breite.roundToPx()
                            val halb = p.width / 2
                            val x = (gesamt * ziel).roundToInt().coerceIn(halb, maxOf(gesamt - halb, halb)) - halb
                            p.place(x, -p.height - 4.dp.roundToPx())
                        }
                    },
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    bild?.let {
                        Image(it.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Crop,
                            modifier = Modifier.size(200.dp, 112.5.dp).clip(RoundedCornerShape(TvStil.ecke))
                                .border(1.dp, Color.White.copy(alpha = 0.35f), RoundedCornerShape(TvStil.ecke)))
                    }
                    Text(zeitText(gezeigt), style = TextStyle(fontSize = TvPlayermass.vorschauZeit, fontWeight = FontWeight.Bold,
                         fontFeatureSettings = "tnum"), color = Stil.schrift)
                }
            }
        }
        Text("−" + zeitText((dauer - position).coerceAtLeast(0.0)), style = ziffern, color = Stil.schriftLeise)
    }
}

// MARK: Ebenen — Vorlage `PlayerEbenen.swift` (tvOS).

/** Fokus in eine Ebene legen: die erste Anforderung faellt oft in den Durchlauf, der das Ziel erst einhaengt. */
private suspend fun fokusLegen(ziel: FocusRequester) {
    repeat(6) { if (runCatching { ziel.requestFocus() }.isSuccess) return; delay(30) }
}

/** Spalten nebeneinander, mittig; unten enden sie am Bildrand, was darueber hinausgeht, scrollt. */
@Composable
private fun Spaltenreihe(inhalt: @Composable RowScope.() -> Unit) {
    Row(Modifier.fillMaxSize().padding(top = TvPlayermass.spaltenOben),
        horizontalArrangement = Arrangement.spacedBy(TvPlayermass.spaltenAbstand, Alignment.CenterHorizontally), content = inhalt)
}

/** Feste Ueberschrift, nur die Zeilen darunter scrollen — per Fokus, jede Spalte fuer sich. */
@Composable
private fun Wahlspalte(titel: String, liste: LazyListState, inhalt: LazyListScope.() -> Unit) {
    Column(Modifier.width(TvPlayermass.spalte).fillMaxHeight()) {
        Text(titel, style = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.Bold), color = Stil.schrift, maxLines = 1,
             modifier = Modifier.padding(start = 13.dp, bottom = 11.dp).semantics { heading() })
        LazyColumn(Modifier.weight(1f).focusGroup(), state = liste, verticalArrangement = Arrangement.spacedBy(2.dp),
                   contentPadding = PaddingValues(bottom = TvStil.randOben), content = inhalt)
    }
}

/** Haken und Name. Gewaehlt weiss und halbfett, sonst leise; Fokus ist die ruhige Flaeche von `FolgenStil`. */
@Composable
private fun Ebenenzeile(text: String, gewaehlt: Boolean, modifier: Modifier = Modifier, tun: () -> Unit) {
    Fokusflaeche(modifier.fillMaxWidth().semantics { selected = gewaehlt }, lupe = 1f, tun = tun) { fokus ->
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(TvStil.eckeKachel))
                .background(if (fokus) TvStil.fokusflaeche else Color.Transparent)
                .padding(horizontal = 13.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(11.dp)) {
            val farbe = if (gewaehlt || fokus) Stil.schrift else Stil.schriftLeise
            Box(Modifier.width(21.dp), contentAlignment = Alignment.Center) {
                if (gewaehlt) Icon(painterResource(R.drawable.player_haken), contentDescription = null, tint = farbe, modifier = Modifier.size(15.dp))
            }
            // Spurnamen kommen aus der Datei — woertlich.
            Text(text, style = TextStyle(fontSize = 18.sp, fontWeight = if (gewaehlt) FontWeight.SemiBold else FontWeight.Normal),
                 color = farbe, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/**
 * Audio & Untertitel — zwei Spalten, jede scrollt fuer sich. Die eigene Wahl steht sofort, unabhaengig
 * von VLC, das die Auswahl erst einen Takt spaeter nachzieht. Beim Oeffnen auf der gewaehlten Tonspur.
 */
@Composable
private fun TvSpurenEbene(werk: Spielwerk) {
    val ton = remember { werk.spurliste(ton = true) }
    val untertitel = remember { werk.spurliste(ton = false) }
    var tonWahl by remember { mutableIntStateOf(werk.spieler.audioTrack) }
    var utWahl by remember { mutableIntStateOf(werk.spieler.spuTrack) }
    val tonStart = remember { ton.indexOfFirst { it.first == tonWahl } }
    // Zeile 0 ist „Aus".
    val utStart = remember { untertitel.indexOfFirst { it.first == utWahl } + 1 }
    val start = remember { FocusRequester() }
    val tonListe = rememberLazyListState((tonStart - 2).coerceAtLeast(0))
    val utListe = rememberLazyListState((utStart - 2).coerceAtLeast(0))
    LaunchedEffect(Unit) { fokusLegen(start) }

    Spaltenreihe {
        Wahlspalte(uebersetzt("Audio"), tonListe) {
            itemsIndexed(ton, key = { _, s -> "t${s.first}" }) { i, (id, name) ->
                Ebenenzeile(name, tonWahl == id, if (i == tonStart) Modifier.focusRequester(start) else Modifier) {
                    tonWahl = id; werk.tonVonHand(id)
                }
            }
        }
        Wahlspalte(uebersetzt("Untertitel"), utListe) {
            item(key = "aus") {
                Ebenenzeile(uebersetzt("Aus"), utWahl == -1, if (tonStart < 0 && utStart == 0) Modifier.focusRequester(start) else Modifier) {
                    utWahl = -1; werk.untertitelVonHand(-1)
                }
            }
            itemsIndexed(untertitel, key = { _, s -> "u${s.first}" }) { i, (id, name) ->
                Ebenenzeile(name, utWahl == id, if (tonStart < 0 && utStart == i + 1) Modifier.focusRequester(start) else Modifier) {
                    utWahl = id; werk.untertitelVonHand(id)
                }
            }
        }
    }
}

/** Einstellungen — Bild, Schlafzeit, Technikschild, Qualität (Vorlage `EinstellungsEbene`). Fokus auf dem gewaehlten Bild. */
@Composable
private fun TvEinstellungsEbene(werk: Spielwerk, app: SwiftlyAnwendung, ebeneSchliessen: () -> Unit) {
    val e = app.einstellungen
    val start = remember { FocusRequester() }
    val fuellendAmStart = remember { werk.bildfuellend }
    LaunchedEffect(Unit) { fokusLegen(start) }
    // Nur bei Wiedergabe vom Server, und nur, wenn das Konto umwandeln darf.
    val qualitaetZeigen = e.umwandelnErlaubt && werk.plan?.url?.startsWith("file") != true
    val lauf = rememberCoroutineScope()
    Spaltenreihe {
        // Zwei Bildformate wie auf dem iPhone: das ganze Bild und formatfuellend.
        Wahlspalte(uebersetzt("Bild"), rememberLazyListState()) {
            item(key = "b0") {
                Ebenenzeile(uebersetzt("Original"), !werk.bildfuellend, if (!fuellendAmStart) Modifier.focusRequester(start) else Modifier) {
                    werk.bildfuellendSetzen(false)
                }
            }
            item(key = "b1") {
                Ebenenzeile(uebersetzt("Füllen"), werk.bildfuellend, if (fuellendAmStart) Modifier.focusRequester(start) else Modifier) {
                    werk.bildfuellendSetzen(true)
                }
            }
        }
        Wahlspalte(uebersetzt("Schlafzeit"), rememberLazyListState()) {
            item(key = "aus") { Ebenenzeile(uebersetzt("Aus"), werk.schlafzeit == 0) { werk.schlafzeitSetzen(0) } }
            // `Schlafzeiten.werte` im Paket.
            listOf(15, 30, 45, 60, 90).forEach { m ->
                item(key = "m$m") { Ebenenzeile(uebersetzt("%lld Min.", m), werk.schlafzeit == m) { werk.schlafzeitSetzen(m) } }
            }
        }
        Wahlspalte(uebersetzt("Technikschild"), rememberLazyListState()) {
            item(key = "aus") { Ebenenzeile(uebersetzt("Aus"), !app.einstellungen.technikschild) { app.einstellungen.technikschild = false } }
            item(key = "an") { Ebenenzeile(uebersetzt("An"), app.einstellungen.technikschild) { app.einstellungen.technikschild = true } }
        }
        // **Qualität: Direct Play oder eine Obergrenze.** Eine Obergrenze heißt,
        // der Server darf umwandeln — Direct Play ist dann aus. Gilt wie die
        // Einstellung in der App und lädt den Film an derselben Stelle neu.
        if (qualitaetZeigen) {
            val bitraten = remember { wahlenLesen(Kern.bitratenstufen()) }
            // `-1`: Direct Play. Sonst eine Bitratengrenze, `0` heißt unbegrenzt.
            fun waehlen(megabit: Int) {
                val vorher = e.immerDirectPlay to e.bitratenGrenze
                if (megabit < 0) e.immerDirectPlay = true
                else { e.immerDirectPlay = false; e.bitratenGrenze = megabit }
                if (vorher == (e.immerDirectPlay to e.bitratenGrenze)) return
                app.qualitaetMelden()
                ebeneSchliessen()
                lauf.launch { werk.qualitaetWechseln() }
            }
            Wahlspalte(uebersetzt("Qualität"), rememberLazyListState()) {
                item(key = "direct") { Ebenenzeile(uebersetzt("Direct Play"), e.immerDirectPlay) { waehlen(-1) } }
                bitraten.forEach { b ->
                    val wert = b.wert.toIntOrNull() ?: 0
                    item(key = "b$wert") {
                        Ebenenzeile(b.text, !e.immerDirectPlay && e.bitratenGrenze == wert) { waehlen(wert) }
                    }
                }
            }
        }
    }
}

/**
 * Die Folgen der Serie — dieselbe Kachelreihe wie auf der Serienseite (`TvFolgenkachel`). Der Titel
 * steht genau dort, wo er im Bild stand (hier nur Platzhalter, den Titel zeichnet der Player); an
 * Stelle der Metazeile die Staffelpille, darunter mit deutlichem Abstand die Kacheln. **Beim Oeffnen
 * steht die Reihe schon da** (vorgeladen) und der Fokus liegt auf der laufenden Folge.
 */
@OptIn(ExperimentalFoundationApi::class, ExperimentalComposeUiApi::class)
@Composable
private fun TvFolgenEbene(app: SwiftlyAnwendung, plan: Spielplan, titel: String, starten: (Folge) -> Unit) {
    val serieId = plan.serieId ?: return
    val laufendeId = plan.itemId
    // Vorlage `passendeStaffel(zu:)`: die Staffel der laufenden Folge.
    fun passend(liste: List<Staffel>, gemerkt: String?) =
        liste.firstOrNull { it.id == plan.staffelId }?.id ?: liste.firstOrNull { it.id == gemerkt }?.id ?: liste.firstOrNull()?.id
    val vorgeladen = remember(serieId) { app.serienSpeicher[serieId] }
    var staffeln by remember(serieId) { mutableStateOf(vorgeladen?.staffeln.orEmpty()) }
    var gewaehlt by remember(serieId) { mutableStateOf(vorgeladen?.let { passend(it.staffeln, it.gewaehlt) }) }
    var folgen by remember(serieId) { mutableStateOf(gewaehlt?.let { app.folgenSpeicher[it] }.orEmpty()) }
    val lauf = rememberCoroutineScope()
    val einblenden = remember { Animatable(1f) }
    val streifen = rememberLazyListState(folgen.indexOfFirst { it.id == laufendeId }.coerceAtLeast(0))
    val laufende = remember { FocusRequester() }
    val pille = remember { FocusRequester() }
    // **Beim Oeffnen ohne Rutschen.** Die Reihe stand bei der laufenden Folge am linken Rand;
    // der erste Fokus schob sie animiert auf den Drehpunkt (30 %) — sie rutschte von links herein.
    // Bis der erste Fokus liegt, springt die Reihe deshalb ohne Bewegung dorthin.
    var sofort by remember { mutableStateOf(true) }
    val fokusGelegt = remember { booleanArrayOf(false) }
    val pilleFokus = remember { booleanArrayOf(false) }

    // **Die Staffelwahl, Eintraege einmal beim Oeffnen gebaut** — aus dem Takt heraus neu gebaut,
    // wurden die Zeilen ersetzt und der Fokus sprang (tvOS 78a81e0).
    var wahl by remember { mutableStateOf<List<Staffel>?>(null) }
    val wahlAusgang = remember { booleanArrayOf(false) }
    fun wahlZu() { wahlAusgang[0] = true; runCatching { pille.requestFocus() }; wahl = null }
    BackHandler(enabled = wahl != null) { wahlZu() }

    LaunchedEffect(serieId) {
        try {
            val s = serieLesen(withContext(Dispatchers.IO) { app.kern.serie(serieId).await() })
            app.serienSpeicher[serieId] = s
            staffeln = s.staffeln
            if (gewaehlt == null || staffeln.none { it.id == gewaehlt }) gewaehlt = passend(staffeln, s.gewaehlt)
            val g = gewaehlt ?: return@LaunchedEffect
            if (folgen.isEmpty()) app.folgenSpeicher[g]?.let { folgen = it }
            val f = folgenLesen(withContext(Dispatchers.IO) { app.kern.folgen(serieId, g).await() })
            // Wer inzwischen eine andere Staffel gewaehlt hat, bekommt deren Folgen.
            if (gewaehlt == g) { folgen = f; app.folgenSpeicher[g] = f }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }

    // Fokus auf die laufende Folge, sobald die Reihe steht — einmal, und nicht, wenn er schon auf der Pille liegt.
    LaunchedEffect(folgen.isNotEmpty()) {
        if (folgen.isEmpty() || fokusGelegt[0] || pilleFokus[0]) return@LaunchedEffect
        fokusGelegt[0] = true
        val i = folgen.indexOfFirst { it.id == laufendeId }
        if (i >= 0 && streifen.layoutInfo.visibleItemsInfo.none { it.index == i }) streifen.scrollToItem(i)
        fokusLegen(laufende)
        // Erst nach dem ersten Fokus wieder mit Bewegung nachfuehren.
        repeat(2) { withFrameNanos { } }
        sofort = false
    }
    // Ohne Folgen haelt die Pille den Fokus — sonst bliebe er auf dem unsichtbaren Knopf dahinter.
    LaunchedEffect(Unit) {
        delay(300)
        if (!fokusGelegt[0] && !pilleFokus[0]) runCatching { pille.requestFocus() }
    }

    fun staffelWaehlen(s: Staffel) {
        wahlZu()
        if (s.id == gewaehlt) return
        gewaehlt = s.id
        lauf.launch {
            einblenden.snapTo(0f)
            val gemerkt = app.folgenSpeicher[s.id]
            if (gemerkt != null) folgen = gemerkt
            try {
                val f = if (gemerkt != null) gemerkt else folgenLesen(withContext(Dispatchers.IO) { app.kern.folgen(serieId, s.id).await() })
                if (gewaehlt == s.id) { folgen = f; app.folgenSpeicher[s.id] = f }
            } catch (e: CancellationException) { throw e } catch (_: Exception) {}
            streifen.scrollToItem(folgen.indexOfFirst { it.id == laufendeId }.coerceAtLeast(0))
            einblenden.animateTo(1f, tween(250, easing = EaseOut))
            // Frisch vom Server, falls der Speicher alt war.
            if (gemerkt != null) try {
                val f = folgenLesen(withContext(Dispatchers.IO) { app.kern.folgen(serieId, s.id).await() })
                if (gewaehlt == s.id) { folgen = f; app.folgenSpeicher[s.id] = f }
            } catch (e: CancellationException) { throw e } catch (_: Exception) {}
        }
    }

    Column(Modifier.fillMaxSize().padding(top = TvStil.randOben)) {
        Column(Modifier.padding(horizontal = TvStil.randSeite).zIndex(1f), verticalArrangement = Arrangement.spacedBy(TvPlayermass.titelAbstand)) {
            // Platzhalter: der Titel selbst steht im Player und blendet nicht mit.
            Text(titel, style = TvPlayermass.titel, maxLines = 1, modifier = Modifier.alpha(0f))
            if (staffeln.isNotEmpty()) Box {
                TvKnopf(staffeln.firstOrNull { it.id == gewaehlt }?.name ?: uebersetzt("Staffel"), Icons.Filled.KeyboardArrowDown,
                        Modifier.focusRequester(pille), hoehe = 30.dp, fokusGeaendert = { pilleFokus[0] = it }) {
                    if (wahl != null) wahlZu() else { wahlAusgang[0] = false; wahl = staffeln }
                }
                wahl?.let { eintraege ->
                    val erste = remember { FocusRequester() }
                    LaunchedEffect(Unit) { fokusLegen(erste) }
                    // Unter der Pille, ohne die Reihe darunter zu verschieben.
                    Column(Modifier.layout { m, c ->
                                val p = m.measure(c.copy(minWidth = 0, minHeight = 0, maxHeight = Constraints.Infinity, maxWidth = Constraints.Infinity))
                                layout(0, 0) { p.place(0, 36.dp.roundToPx()) }
                            }
                            .width(260.dp).heightIn(max = 330.dp).clip(RoundedCornerShape(10.dp)).background(Stil.erhoeht)
                            .verticalScroll(rememberScrollState()).padding(vertical = 6.dp)
                            .focusProperties { exit = { if (wahlAusgang[0]) FocusRequester.Default else FocusRequester.Cancel } }
                            .focusGroup()) {
                        val start = eintraege.indexOfFirst { it.id == gewaehlt }.coerceAtLeast(0)
                        eintraege.forEachIndexed { i, s ->
                            TvZeile(s.name, if (s.id == gewaehlt) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                                    modifier = if (i == start) Modifier.focusRequester(erste) else Modifier) { staffelWaehlen(s) }
                        }
                    }
                }
            }
        }
        // Deutlich Luft zur Staffelpille — sonst klebte die Reihe daran.
        if (folgen.isNotEmpty()) CompositionLocalProvider(LocalBringIntoViewSpec provides if (sofort) TvReiheOhneBewegung else TvReihenBringIntoView) {
            val start = folgen.indexOfFirst { it.id == laufendeId }.coerceAtLeast(0)
            LazyRow(Modifier.padding(top = 22.dp).graphicsLayer { alpha = einblenden.value }, state = streifen,
                    contentPadding = PaddingValues(horizontal = TvStil.randSeite, vertical = TvStil.reihenLuft),
                    horizontalArrangement = Arrangement.spacedBy(TvStil.kachelAbstand)) {
                itemsIndexed(folgen, key = { _, f -> f.id }) { i, f ->
                    TvFolgenkachel(f, if (i == start) Modifier.focusRequester(laufende) else Modifier) { starten(f) }
                }
            }
        }
    }
}

/** Wie `TvReihenBringIntoView`, nur ohne Bewegung — fuer den ersten Fokus beim Oeffnen. */
@OptIn(ExperimentalFoundationApi::class)
@Suppress("DEPRECATION")
private object TvReiheOhneBewegung : BringIntoViewSpec {
    override val scrollAnimationSpec: AnimationSpec<Float> = snap()
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float =
        TvReihenBringIntoView.calculateScrollDistance(offset, size, containerSize)
}
