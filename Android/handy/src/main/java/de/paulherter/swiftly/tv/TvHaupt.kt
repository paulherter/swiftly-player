package de.paulherter.swiftly.tv

import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.findRootCoordinates
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.*
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.Wortmarke
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import android.widget.Toast
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.Lifecycle

/**
 * Vorlage: `Bereich` in `Sources/tvOS/TVBausteine.swift` — **oben, nicht unten**: auf tvOS fuehrt
 * die Navigation oben, eine Leiste am unteren Rand waere unerreichbar weit vom Blick weg. Die
 * Merkliste hat hier einen eigenen Bereich; Downloads gibt es auf dem Fernseher nicht.
 */
enum class TvBereich(val titel: String) { Start("Start"), Filme("Filme"), Serien("Serien"), Merkliste("Merkliste"), Suche("Suche") }

/**
 * Was die Startseite von einem Titel schon weiss, wenn er geoeffnet wird — Vorlage: tvOS reicht
 * dasselbe `Item` an `DetailView` weiter, dort steht der Kopf deshalb im ersten Bild. Hier kommt
 * die Detailseite nur mit der Kennung an; ohne diese Uebergabe begann ihr Kopf leer und fuellte
 * sich erst mit der Antwort von `Kern.titel`/`Kern.serie`. `angaben` ist schon so zugeschnitten,
 * wie die Zielseite die Zeile zeigt (Film: Jahr · Laufzeit, Serie: nur Jahr), damit beim
 * Eintreffen der vollen Daten nichts umspringt.
 */
data class TvVorab(val titel: String, val angaben: String?, val bewertung: Double?, val freigabe: String?,
                   val beschreibung: String?, val kulisse: String?)

/** Prozessweit, klein: je Kennung die letzte Uebergabe. Gelesen nur, bis die vollen Daten da sind. */
object TvUebergabe {
    private val vorab = HashMap<String, TvVorab>()
    fun merken(id: String, v: TvVorab) { vorab[id] = v }
    fun fuer(id: String): TvVorab? = vorab[id]
}

/** Die Meldestelle der gerade gezeichneten Seite — siehe `TvKulisseMelden`. */
val LocalKulisseMelden = compositionLocalOf<(String?) -> Unit> { {} }

/**
 * Eine Seite meldet ihre Kulisse an `TvHaupt`, das sie **unter** dem Seitenstapel zeichnet.
 * `bereit = false`: noch nichts Verlaessliches — `TvHaupt` laesst stehen, was steht.
 */
@Composable
fun TvKulisseMelden(bild: String?, bereit: Boolean = true) {
    val melden = LocalKulisseMelden.current
    LaunchedEffect(bild, bereit, melden) { if (bereit) melden(bild) }
}

/** Unterseiten, die **nicht** die gemeinsame Kulisse tragen — Gegenstueck zu `TvUnterseite`. Person
 *  und Seerr-Titel zeichnen ihre eigene (wechselndes Banner, fremde Adressen) auf deckendem Grund. */
private val ohneGemeinsameKulisse = setOf("Person", "Genre", "BoxSet", "Profil", "WeiteresKonto", "ServerAufnahme",
    "Wiedergabeeinstellungen", "Darstellung", "Einstellungen", "Seerr", "Seerrtitel", "Genrewahl", "Merkliste")

private fun seitenschluessel(b: TvBereich, tiefe: Int, id: String?) = "${b.name}/$tiefe/${id.orEmpty()}"

/** Wie tief die Kopfleiste reicht — darunter beginnen die Seiten. */
val kopfUnten = TvStil.randOben + TvStil.leisteHoehe + 12.dp

/**
 * Vorlage: `HauptView` auf tvOS. Je Bereich ein eigener Stapel; **Bereiche wechseln als reine
 * Ueberblendung** — eine fruehere Fassung liess sie aneinander vorbeigleiten, und das sah wie ein
 * Fehler aus. Unterseiten erscheinen ohne Schub. **Zurueck fuehrt eine Stufe zurueck, nicht aus der
 * App:** erst die Tafel, dann der Stapel, dann zum Start.
 *
 * **Der Sprung Start → Unterseite selbst bleibt ohne Animation, mit Absicht.** tvOS schaltet die
 * Push-Animation seines `NavigationStack` fuer genau diesen Wechsel ab (`HauptView.stapel`,
 * `UIView.setAnimationsEnabled(false)`) — hier tut `key(b, tiefe, ziel?.id)` dasselbe, indem es die
 * alte Seite ohne eigenen Uebergang gegen `TvUnterseite` austauscht. Trotzdem sieht der Wechsel
 * weich aus, weil Kulisse und Kopfauskunft auf beiden Seiten **pixelgleich** stehen (`Kopfauskunft`
 * in `TvStart.kt`, `TvDetailkopf` in `TvTitel.kt`) — es gibt nichts, was dabei zuckt. Was dagegen
 * neu ist, blendet **in der Zielseite selbst** ein (`eingeblendet` in `TvDetail`/`TvSerie`), nicht
 * hier im Router: Knopfreihe und Reihen kommen 300 ms nach dem Erscheinen, der Kopf steht sofort.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun TvHaupt(app: SwiftlyAnwendung) {
    var bereich by rememberSaveable { mutableStateOf(TvBereich.Start) }
    val stapel = remember { mutableStateMapOf<TvBereich, List<Ziel>>() }
    // Kontowechsel (Entwurf D): unter dem Standbild springen Stapel und Bereich ohne Animation zurueck.
    val zurueckStand = remember { de.paulherter.swiftly.Kontowechselflug.zurueck }
    LaunchedEffect(de.paulherter.swiftly.Kontowechselflug.zurueck) {
        if (de.paulherter.swiftly.Kontowechselflug.zurueck != zurueckStand && de.paulherter.swiftly.Kontowechselflug.wartet) {
            stapel.clear(); bereich = TvBereich.Start
        }
    }
    val zustaende = rememberSaveableStateHolder()
    val kontext = LocalContext.current

    LaunchedEffect(Unit) {
        app.sitzungPruefen()
        app.seerrLaden()
        app.servernameLaden()
        app.nachDemVerbinden()
        app.kern.fernsteuerungStarten().await()
    }
    // „Hier weiterschauen": vom Telefon uebernommen (`Hauptansicht`, `Uebernahme.kt`) — auf dem
    // Fernseher gab es das Abzeichen bisher gar nicht, dabei fuehrt tvOS es auf jeder Wurzelseite.
    // Alle fuenf Sekunden, solange die App vorn ist; `angeboteHolen()` schweigt selbst, waehrend
    // gespielt wird.
    @Suppress("DEPRECATION")
    val lebenszyklus = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lebenszyklus) {
        lebenszyklus.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) { app.angeboteHolen(); delay(5000) }
        }
    }
    val spiel = app.spiel.value
    // **Der Player blendet ueber, 0,3 s** — wie auf tvOS seit bee033b und am Handy
    // (`player_ein`/`player_aus`, siehe `PlayerAktivitaet.kt`).
    // `spielUebergeben` wie in `Hauptansicht`: ein Wunsch startet den Player genau einmal, auch wenn
    // die Aktivitaet neu gebaut wird.
    LaunchedEffect(spiel) {
        if (spiel == null || spiel === app.spielUebergeben) return@LaunchedEffect
        app.spielUebergeben = spiel
        Fokusmerker.playerStartet()
        // Aus einer Uebergabe ohne eigene Blende: die Karte liegt darueber (`Uebergabe`).
        val ein = if (de.paulherter.swiftly.Uebergabe.empfang != null) de.paulherter.swiftly.R.anim.halten else de.paulherter.swiftly.R.anim.player_ein
        kontext.startActivity(Intent(kontext, PlayerAktivitaet::class.java),
            android.app.ActivityOptions.makeCustomAnimation(kontext, ein, de.paulherter.swiftly.R.anim.halten).toBundle())
    }
    // **Nach dem Player zurueck auf die Kachel, Folge oder den Knopf, von dem aus gestartet wurde**
    // (Vorlage tvOS 57d3219) — derselbe Weg, ob der Player per Zurueck oder von selbst endet.
    LaunchedEffect(spiel == null) {
        if (spiel == null) { delay(TvStil.fokusFrist); Fokusmerker.playerZu() }
    }

    // Gemeldete Kulissen je Seite (`seitenschluessel`) — siehe `TvKulissenebene`.
    val kulissen = remember { mutableStateMapOf<String, String?>() }
    val oeffnen: (Ziel) -> Unit = { z -> stapel[bereich] = stapel[bereich].orEmpty() + z }
    val zurueck: () -> Unit = {
        val alt = stapel[bereich].orEmpty()
        alt.lastOrNull()?.let { kulissen.remove(seitenschluessel(bereich, alt.size, it.id)) }
        stapel[bereich] = alt.dropLast(1)
    }
    val oben = stapel[bereich].orEmpty()

    // **Watch Next** (`TvWeiterschauenRegal`) fuehrt ueber "swiftly://titel/<id>" hierher zurueck —
    // dieselbe Adresse wie tvOS' Top Shelf, nur ueber den Intent statt `onOpenURL`. Dieselbe Regel
    // wie `weiterschauenWunsch` beim Antippen von „Weiterschauen" auf der Startseite
    // (`StartSeite.kt`): ist eine Anschlussstelle da, direkt abspielen, sonst zur Titelseite. Nur
    // fehlen hier Name und Art noch, deshalb ein einziger eigener Abruf statt der Hilfsfunktion.
    LaunchedEffect(app.tiefenlink.value) {
        val adresse = app.tiefenlink.value ?: return@LaunchedEffect
        app.tiefenlink.value = null
        if (adresse.scheme != "swiftly" || adresse.host != "titel") return@LaunchedEffect
        // Nur eine Jellyfin-Kennung, wie `Pfadteil.istKennung` im Paket — kein `..%2F` in die Serveradresse.
        val id = adresse.lastPathSegment?.takeIf { Regex("[A-Za-z0-9-]{1,64}").matches(it) } ?: return@LaunchedEffect
        bereich = TvBereich.Start
        runCatching { titelLesen(withContext(Dispatchers.IO) { app.kern.titel(id).await() }) }.getOrNull()?.let { t ->
            if (t.planDa) app.spiel.value = Abspielwunsch(id, t.fortsetzenAb) else oeffnen(Ziel(id, t.name, t.typ))
        }
    }

    BackHandler(enabled = oben.isEmpty() && bereich != TvBereich.Start) { bereich = TvBereich.Start }
    BackHandler(enabled = oben.isNotEmpty(), onBack = zurueck)

    // **Die Kulisse gehoert keiner Seite, sondern dem Stapel.** Vorlage: auf tvOS steht beim Oeffnen
    // dieselbe Adresse auf beiden Seiten (`HomeView.kulissenURL`), also aendert sich nichts. Hier lag
    // Kulisse + `TvBildgrund` bisher in jeder Seite selbst — beim Oeffnen baute die neue Seite beides
    // frisch auf: Bild kurz weg und neu eingeblendet, Ton neu gerechnet. Jetzt meldet die Seite oben
    // nur ihre Adresse, gezeichnet wird hier, einmal. Start → Detail mit derselben Adresse: kein
    // Neuaufbau, nichts blendet. Hat die Zielseite noch nicht gemeldet, zaehlt die Uebergabe aus der
    // Startseite, sonst bleibt das zuletzt gezeigte Bild stehen. Bereichswechsel auf eine Seite ohne
    // Kulisse blendet weiter aus.
    val obenZiel = oben.lastOrNull()
    val obenSchluessel = seitenschluessel(bereich, oben.size, obenZiel?.id)
    val traegtKulisse = if (obenZiel == null) bereich == TvBereich.Start else obenZiel.typ !in ohneGemeinsameKulisse
    val gezeigt = remember { arrayOfNulls<String>(1) }
    val kulisse = when {
        !traegtKulisse -> null
        kulissen.containsKey(obenSchluessel) -> kulissen[obenSchluessel]
        else -> obenZiel?.let { TvUebergabe.fuer(it.id)?.kulisse } ?: gezeigt[0]
    }
    gezeigt[0] = kulisse
    // Kopfleiste und -verlauf: sichtbar nur an der Wurzel eines Bereichs — siehe die Ebene unten.
    val inhalt = remember { FocusRequester() }
    val fokusVerwalter = LocalFocusManager.current
    val leiste = animateFloatAsState(if (oben.isEmpty()) 1f else 0f,
        tween(TvStil.leisteDauer, easing = TvStil.leisteKurve), label = "kopfleiste")

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        TvKulissenebene(kulisse, schatten = traegtKulisse)
        Crossfade(bereich, animationSpec = tween(250), label = "bereich") { b ->
            val ziel = stapel[b].orEmpty().lastOrNull()
            val tiefe = stapel[b].orEmpty().size
            key(b, tiefe, ziel?.id) {
                val schluessel = seitenschluessel(b, tiefe, ziel?.id)
                val melden = remember(schluessel) { { url: String? -> kulissen[schluessel] = url } }
                // Menue-Taste oder langes OK auf einer Kachel: das Kachelmenue als Tafel (`kachelmenueTafel`).
                CompositionLocalProvider(LocalKulisseMelden provides melden,
                    de.paulherter.swiftly.LocalKachelmenue provides { w -> de.paulherter.swiftly.kachelmenueTafel(app, w, oeffnen) }) {
                zustaende.SaveableStateProvider(schluessel) {
                    if (ziel == null) {
                        Box(Modifier.fillMaxSize().focusRequester(inhalt).focusGroup()) {
                            when (b) {
                                TvBereich.Start -> TvStartSeite(app, oeffnen)
                                TvBereich.Filme -> TvBibliothek(app, "movies", listOf("alle", "angefangen", "merkliste", "ungesehen"), oeffnen)
                                TvBereich.Serien -> TvBibliothek(app, "tvshows", listOf("alle", "angefangen", "merkliste"), oeffnen)
                                TvBereich.Merkliste -> TvMerkliste(app, oeffnen)
                                TvBereich.Suche -> TvSuche(app, oeffnen)
                            }
                            // Vorlage: `Kopfverlauf` in `HauptView` — auf Start nicht, dort scrollt
                            // nichts mehr unter die Leiste (feste Heldenzone), auf den anderen Wurzelseiten
                            // schon (die Chip-/Filterzeile traegt ihren eigenen oberen Abstand als Teil
                            // des scrollenden Inhalts, nicht als `contentPadding`).
                            if (b != TvBereich.Start) TvKopfverlauf(Modifier.align(Alignment.TopStart).graphicsLayer { alpha = leiste.value })
                        }
                    } else {
                        TvUnterseite(app, ziel, oeffnen, zurueck)
                    }
                }
                }
            }
        }
        // **Die Kopfleiste als eigene Ebene ueber dem Stapel, nicht in der Wurzelseite.** Vorlage:
        // `HauptView.leisteDa` auf tvOS (und die Leiste auf dem Mac) — beim Oeffnen einer Unterseite
        // blendet sie aus, beim Zurueck wieder ein, `.easeInOut(duration: 0.26)`. Solange sie in der
        // Wurzelseite stand, verschwand sie mit ihr hart, sobald `key(b, tiefe, …)` die Seite tauschte.
        //
        // Ausgeblendet ist sie **kein Fokusziel** — dieselbe Regel wie `.disabled(!leisteDa)` auf
        // tvOS: `enter = Cancel` laesst keine Richtungstaste mehr hinein, waehrend sie verschwindet
        // oder unsichtbar steht. Bei 0 faellt sie ganz aus der Komposition.
        if (leiste.value > 0.001f || oben.isEmpty()) {
            val leisteDa = oben.isEmpty()
            Box(Modifier.fillMaxWidth().graphicsLayer { alpha = leiste.value }
                    .focusProperties { if (!leisteDa) enter = { FocusRequester.Cancel } }.focusGroup()
                    .onPreviewKeyEvent { e ->
                        // **Runter aus der Leiste findet den Inhalt auch, wenn die Suche nichts
                        // findet.** Raster und Listen der Wurzelseiten reichen bis unter die Leiste
                        // (Inhalt laeuft unter dem Kopf durch); ihre Gruppe beginnt also nicht
                        // *unterhalb* des Reiters, und Compose verwarf sie als Ziel fuer „Runter" —
                        // auf Filme, Serien, Merkliste und Suche passierte nichts. Erst die
                        // geometrische Suche, sonst die erste Stelle der Seite.
                        if (e.type != KeyEventType.KeyDown || e.key != Key.DirectionDown) return@onPreviewKeyEvent false
                        if (!fokusVerwalter.moveFocus(FocusDirection.Down)) runCatching { inhalt.requestFocus() }
                        true
                    }) {
                Kopfleiste(app, bereich, { bereich = it }, app.angebote.value) { oeffnen(Ziel("profil", uebersetzt("Profil"), "Profil")) }
            }
        }
        // „Filmabend verlassen · Wieder beitreten" nach dem Schliessen des Players.
        if (spiel == null) TvRueckwegstreifen(app)
        // Eine Meldung der Gruppe — derselbe Streifen wie auf den Seiten; im Player zeigt der sie.
        if (spiel == null) app.gemeinsamFehler.value?.let {
            TvHinweisstreifen(it, Modifier.align(Alignment.TopCenter).padding(top = 74.dp)) { app.gemeinsamFehler.value = null }
        }
        // Solange der Player laeuft, gehoert die Tafel ihm.
        if (spiel == null) TvTafel(app)
        // „Wo weiterschauen?" — waechst aus dem Abzeichen.
        if (spiel == null) TvUebernahmeauflage(app)
    }
}

/**
 * Vorlage: `TVUebernahmeauswahl` in `Sources/tvOS/TVBausteine.swift` samt Schleier (Schwarz 72 %) und
 * `.transition(.ausDemPunkt(Abzeichenursprung.punkt))` in `Sources/tvOS/HauptView.swift`. **Der Schleier
 * blendet, die Auswahl waechst aus dem Abzeichen** (Masstab ab 12 %, Deckung schneller als der Masstab)
 * und schrumpft beim Schliessen dorthin zurueck — dieselbe Mechanik wie `Uebernahmeauflage` am Telefon,
 * Feder `Stil.feder`. Punkte halbiert. Zurueck schliesst; der Fokus geht zurueck ans Abzeichen.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
private fun TvUebernahmeauflage(app: SwiftlyAnwendung) {
    val offen = app.uebernahmeauswahl.value
    val gemerkt = remember { arrayOfNulls<de.paulherter.swiftly.Uebernahmeauswahl>(1) }
    offen?.let { gemerkt[0] = it }
    val w = gemerkt[0] ?: return
    val ruhig = de.paulherter.swiftly.gemeinsam.bewegungReduziert()
    val auf = remember { androidx.compose.animation.core.Animatable(0f) }
    LaunchedEffect(offen != null) {
        auf.animateTo(if (offen != null) 1f else 0f,
            if (ruhig) de.paulherter.swiftly.gemeinsam.Bewegung.blendeReduziert()
            else androidx.compose.animation.core.spring(dampingRatio = 0.9f, stiffness = 322f))
        if (offen == null) gemerkt[0] = null
    }
    LaunchedEffect(offen == null) { if (offen == null) { delay(TvStil.fokusFrist); Fokusmerker.zurueckfordern() } }
    if (offen == null && auf.value <= 0.001f) return
    val freigabe = remember(w) { booleanArrayOf(false) }
    fun zu() {
        freigabe[0] = true
        Fokusmerker.zurueckgeben()
        if (app.uebernahmeauswahl.value === w) app.uebernahmeauswahl.value = null
    }
    BackHandler(enabled = offen != null) { zu() }
    val erster = remember(w) { FocusRequester() }
    LaunchedEffect(w) { delay(TvStil.fokusFrist); runCatching { erster.requestFocus() } }
    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = auf.value.coerceIn(0f, 1f) }.background(Color.Black.copy(alpha = 0.72f)))
        val rahmen = remember { arrayOf(androidx.compose.ui.geometry.Rect.Zero) }
        CompositionLocalProvider(LocalInnerhalbTafel provides true) {
            Column(Modifier.align(Alignment.Center).padding(24.dp)
                    .onGloballyPositioned { rahmen[0] = it.boundsInRoot() }
                    .graphicsLayer {
                        val a = auf.value
                        if (!ruhig && rahmen[0].width > 0 && w.ursprung != androidx.compose.ui.geometry.Offset.Zero) {
                            val r = rahmen[0]
                            transformOrigin = androidx.compose.ui.graphics.TransformOrigin(
                                ((w.ursprung.x - r.left) / r.width).coerceIn(-2f, 3f), ((w.ursprung.y - r.top) / r.height).coerceIn(-2f, 3f))
                            val m = 0.12f + 0.88f * a
                            scaleX = m; scaleY = m
                        }
                        alpha = (a * 1.6f).coerceIn(0f, 1f)
                    }
                    .focusProperties { exit = { if (freigabe[0]) FocusRequester.Default else FocusRequester.Cancel } }.focusGroup(),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(17.dp)) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(uebersetzt("Wo weiterschauen?"), style = TvStil.unterseitentitel, color = Stil.schrift)
                    Text(uebersetzt("Auf dem anderen Gerät hört die Wiedergabe auf. Hier läuft sie an derselben Stelle weiter."),
                         style = TvStil.klein.copy(textAlign = androidx.compose.ui.text.style.TextAlign.Center), color = Stil.schriftLeise)
                }
                Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    w.angebote.forEachIndexed { i, a ->
                        // Jede Zeile ist ein anderes Geraet — kuehl wie das Abzeichen (`AbzeichenStil(anderesGeraet: true)`).
                        Fokusflaeche(modifier = if (i == 0) Modifier.focusRequester(erster) else Modifier,
                                     lupe = TvStil.fokusLupeBreit, tun = { zu(); w.waehlen(a) }) { fokus ->
                            val vorn = if (fokus) Stil.grund else Stil.akzent
                            Row(Modifier.widthIn(max = 380.dp).fillMaxWidth().height(44.dp).clip(RoundedCornerShape(50))
                                    .background(Stil.grund).background(if (fokus) Color.White else Stil.akzent.copy(alpha = 0.18f))
                                    .padding(horizontal = 14.dp),
                                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                Box(Modifier.width(20.dp), contentAlignment = Alignment.Center) {
                                    Symbol(uebernahmezeichen(a.art), 14.dp, farbe = vorn, staerke = Staerke.Mittel)
                                }
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                                    Text(a.geraet ?: uebersetzt("Gerät"), style = TvStil.knopf, color = vorn, maxLines = 1)
                                    Text(a.titelzeile, style = TvStil.klein, color = vorn.copy(alpha = 0.75f), maxLines = 1,
                                         overflow = TextOverflow.Ellipsis)
                                }
                                Text(a.stelleText, style = TvStil.klein.copy(fontFeatureSettings = "tnum"), color = vorn.copy(alpha = 0.75f))
                            }
                        }
                    }
                }
                // „Abbrechen" bleibt grau (`AbzeichenStil()`).
                Fokusflaeche(lupe = TvStil.fokusLupeBreit, tun = { zu() }) { fokus ->
                    Box(Modifier.height(TvStil.knopfHoehe).clip(RoundedCornerShape(50))
                            .background(if (fokus) Color.White else Stil.erhoeht).padding(horizontal = 18.dp),
                        contentAlignment = Alignment.Center) {
                        Text(uebersetzt("Abbrechen"), style = TvStil.knopf, color = if (fokus) Stil.grund else Stil.schrift)
                    }
                }
            }
        }
    }
}

/**
 * Grund, Kulisse und Kopfschatten fuer Start, Film- und Serienseite — dieselben Ebenen, die vorher
 * jede dieser Seiten selbst trug (Vorlage: `bildgrund`, `Kulisse`, `Kopfschatten` auf tvOS; dort
 * gehoert der Kopfschatten auch auf die Detailseite, „die letzte Ebene, die es nur auf einer der
 * beiden Seiten gab").
 *
 * **Das alte Bild bleibt stehen, bis das neue geladen ist** (tvOS `bildwechseln`, Swiftfins
 * `CinematicBackgroundView`): `steht` wechselt erst, wenn Coil das neue Bild in derselben Groesse
 * im Speicher hat. Dann trifft `Kulisse` den Speicher, Coil blendet selbst nicht noch einmal
 * (Speichertreffer haben keine Coil-Ueberblendung), und nur die 300-ms-Blende der Kulisse laeuft.
 */
@Composable
private fun TvKulissenebene(bild: String?, schatten: Boolean) {
    val kontext = LocalContext.current
    val dichte = LocalDensity.current
    var steht by remember { mutableStateOf(bild) }
    LaunchedEffect(bild) {
        if (bild != null && bild != steht) {
            SingletonImageLoader.get(kontext).execute(ImageRequest.Builder(kontext).data(bild)
                .size(with(dichte) { 590.dp.roundToPx() }, with(dichte) { 350.dp.roundToPx() }).build())
        }
        // Ein `null` nur, wenn es bleibt: beim Seitenwechsel kann die Adresse fuer ein, zwei Bilder
        // fehlen, bis die neue Seite gemeldet hat — das darf nichts ausblenden. Kommt vorher eine
        // Adresse, bricht dieser Effekt hier ab.
        if (bild == null && steht != null) delay(150)
        steht = bild
    }
    // **Der Kopfschatten haengt am Seitentyp, nicht am Bild.** Vorher `steht != null`: jede Luecke in
    // der Adresse (Seitenwechsel, Meldung kommt ein Bild spaeter) blendete den Schatten 300 ms aus
    // und wieder ein, waehrend das Bild stand — das Blinken beim Oeffnen der Serienseite. tvOS
    // zeichnet `Kopfschatten()` in `HomeView` wie in `DetailView` bedingungslos: dieselbe Ebene,
    // also sieht man im Uebergang nichts. `schatten` ist auf Start, Film und Serie gleich (`true`).
    val deckung by animateFloatAsState(if (schatten) 1f else 0f, tween(300), label = "kopfschatten")
    Box(Modifier.fillMaxSize()) {
        TvBildgrund(steht)
        Kulisse(steht, Modifier.align(Alignment.TopEnd))
        Box(Modifier.fillMaxWidth().alpha(deckung)) { Kopfschatten() }
    }
}

/** Die Wegeregel aus `zielorte`; was es nur auf dem Telefon als Seite gibt, kommt von dort. */
@Composable
private fun TvUnterseite(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    when (ziel.typ) {
        "Series", "Episode" -> TvSerie(app, ziel, oeffnen)
        "Person" -> TvPerson(app, ziel, oeffnen)
        "Genre" -> TvGenre(app, ziel, oeffnen)
        // Eine Sammlung — aus dem Titelmenue mit Bereich, aus Suche oder Merkliste ohne.
        "BoxSet" -> TvSammlung(app, ziel, oeffnen)
        "Profil" -> TvProfil(app, oeffnen)
        "WeiteresKonto" -> Box(Modifier.fillMaxSize().background(Stil.grund)) {
            TvAnmeldeSeite(app, app.servername.value.orEmpty(), "", weiteresKonto = true, andererServer = zurueck) { zurueck() }
        }
        "ServerAufnahme" -> TvServerAufnahme(app, ziel.id.takeIf { it != "serveraufnahme" }, zurueck)
        "Wiedergabeeinstellungen" -> WiedergabeEinstellungenSeite(app, zurueck)
        "Darstellung" -> DarstellungSeite(app, oeffnen, zurueck)
        "Einstellungen" -> EinstellungenSeite(app, oeffnen, zurueck)
        "Seerr" -> TvSeerrSeite(app, zurueck)
        "EigeneKoepfe" -> { androidx.activity.compose.BackHandler(onBack = zurueck); TvEigeneKoepfeSeite(app, zurueck) }
        "Seerrtitel" -> TvSeerrDetailSeite(app, ziel, oeffnen, zurueck)
        "Genrewahl" -> GenrewahlSeite(app, zurueck)
        "Merkliste" -> TvMerkliste(app, oeffnen)
        else -> TvDetail(app, ziel, oeffnen)
    }
}

/**
 * Vorlage: `Kopfleiste` — Wortmarke links, Reiter daneben, Profil rechts; **links ausgerichtet**,
 * nicht mittig. Gewechselt wird beim Klick, nicht beim Fokus: tvOS sucht geometrisch, und drei
 * Anlaeufe, das umzulenken, haben geflackert.
 *
 * `angebote`: „Hier weiterschauen" (`Uebernahmeabzeichen`) — links vom Profilbild, nur wenn etwas
 * auf einem anderen Geraet laeuft.
 */
@Composable
private fun Kopfleiste(app: SwiftlyAnwendung, aktiv: TvBereich, waehlen: (TvBereich) -> Unit,
                       angebote: List<Angebot>, profil: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = TvStil.randSeite).padding(top = TvStil.randOben).height(TvStil.leisteHoehe).focusGroup(),
        verticalAlignment = Alignment.CenterVertically) {
        Wortmarke(hoehe = 18.dp)
        Spacer(Modifier.width(26.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            TvBereich.entries.forEach { b -> Reiter(uebersetzt(b.titel), b == aktiv) { waehlen(b) } }
        }
        Spacer(Modifier.weight(1f))
        // Entwurf A: ein Abzeichen fuer „Hier weiterschauen" und offene Gruppen zusammen.
        val gruppen = app.gemeinsam.value.offeneGruppen
        if (angebote.isNotEmpty() || gruppen.isNotEmpty()) {
            TvUebernahmeabzeichen(app, angebote, gruppen)
            Spacer(Modifier.width(18.dp))
        }
        // Ein Profilkreis von 32 — die kleine Stufe der Fokusleiter. Der Ring ist **weiss**:
        // ein Bild kann nicht heller werden wie eine Kachel, und der Akzent traegt Zustand,
        // nicht „hier steht die Fernbedienung" (BRAND 1, `ProfilStil` auf tvOS).
        // Der Kontowechsel fliegt hierher; solange das neue Bild unterwegs ist, steht hier noch keins.
        val flug = de.paulherter.swiftly.Kontowechselflug.flug
        Fokusflaeche(lupe = TvStil.fokusLupeKlein, tun = profil) { fokus ->
            Box(Modifier.size(32.dp).border(2.dp, if (fokus) Stil.schrift else Color.Transparent, CircleShape).padding(3.dp)
                    .onGloballyPositioned { de.paulherter.swiftly.Kontowechselflug.zielMelden(it.boundsInRoot(), it.findRootCoordinates().size.width.toFloat()) }
                    .graphicsLayer { alpha = if (flug != null && !flug.ersetzt) 0f else 1f }) {
                SubcomposeAsyncImage(model = app.kern.benutzerbild(160).orElse(null), contentDescription = uebersetzt("Profil"),
                    contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize().clip(CircleShape).background(Stil.erhoeht),
                    error = { Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Symbol(Zeichen.PersonVoll, 13.dp, farbe = Stil.schriftLeise)
                    } })
            }
        }
    }
}

private fun uebernahmezeichen(art: String): Zeichen = when (art) {
    "telefon" -> Zeichen.Telefon
    "tablet" -> Zeichen.Tablet
    "rechner" -> Zeichen.Laptop
    "fernseher" -> Zeichen.Fernseher
    else -> Zeichen.AbspielenFernseher
}

/**
 * Vorlage: `Uebernahmeabzeichen` in `Sources/tvOS/TVBausteine.swift` — „Laeuft auf dem iPhone — hier
 * weiterschauen", in Ruhe eine Zeile, der Titel kommt im Fokus dazu. Auf dem Telefon steckt dieselbe
 * Handlung in `Uebernahmezeichen` (`Uebernahme.kt`); die Logik (`app.kern.uebernehmen`, `Angebot`) ist
 * dieselbe, nur die Zeichnung ist tvOS-eigen — Kapsel statt Kreis.
 *
 * **Mehrere Angebote oeffnen `TvTafel` statt eines eigenen Auswahlblatts** wie auf tvOS
 * (`TVUebernahmeauswahl`): die Tafel kann Symbol, Haken und Auswahl schon, ein zweites Blatt waere
 * eine Kopie derselben Handlung.
 */
@Composable
private fun TvUebernahmeabzeichen(app: SwiftlyAnwendung, angebote: List<Angebot>, gruppen: List<Gemeinsamgruppe>) {
    val kontext = LocalContext.current
    val lauf = rememberCoroutineScope()
    var uebernimmt by remember { mutableStateOf(false) }
    // Wo das Abzeichen steht (Wurzelpixel) — Auswahl und Karte wachsen von dort (`Abzeichenursprung`).
    val mitte = remember { arrayOf(androidx.compose.ui.geometry.Offset.Zero) }
    val dichte = androidx.compose.ui.platform.LocalDensity.current.density
    val ruhig = de.paulherter.swiftly.gemeinsam.bewegungReduziert()
    fun uebernehmen(a: Angebot) {
        if (uebernimmt) return
        uebernimmt = true
        lauf.launch { de.paulherter.swiftly.hierWeiterschauen(app, kontext, a, mitte[0], dichte, ruhig); uebernimmt = false }
    }
    val erstes = angebote.firstOrNull()
    val anzahl = angebote.size + gruppen.size
    // Vorlage `Angebotsabzeichen.antippen` (iOS, Entwurf A): nur Uebernahme wie bisher; nur eine Gruppe:
    // „Beitreten"; sonst die Auswahl mit beidem.
    Fokusflaeche(lupe = TvStil.fokusLupeBreit, tun = {
        if (gruppen.isNotEmpty()) {
            if (angebote.isEmpty() && gruppen.size == 1) tvBeitretenOeffnen(app, gruppen.first())
            else tvAuswahlOeffnen(app, ::uebernehmen)
        }
        else if (angebote.size == 1 && erstes != null) uebernehmen(erstes)
        // Mehrere Geraete: die Auswahl waechst aus dem Abzeichen (`TVUebernahmeauswahl`, `TvUebernahmeauflage`).
        else app.uebernahmeauswahl.value = de.paulherter.swiftly.Uebernahmeauswahl(angebote, mitte[0]) { uebernehmen(it) }
    }) { fokus ->
        // Vorlage: `AbzeichenStil(anderesGeraet: true)` in `Sources/tvOS/TVBausteine.swift` — **nicht
        // durchsichtig**: in Ruhe der Akzent auf 18 Prozent ueber dem Seitengrund (deckend), im Fokus eine
        // volle weisse Flaeche mit dunkler Schrift/Symbol statt der blauen, durchscheinenden Flaeche
        // von vorher.
        val vordergrund = if (fokus) Stil.grund else Stil.akzent
        Row(Modifier.onGloballyPositioned { mitte[0] = it.boundsInRoot().center }
                .height(if (fokus) 38.dp else 32.dp).clip(RoundedCornerShape(50))
                .background(Stil.grund).background(if (fokus) Color.White else Stil.akzent.copy(alpha = 0.18f))
                .padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            Symbol(erstes?.let { uebernahmezeichen(it.art) } ?: Zeichen.GruppeVoll, 13.dp, farbe = vordergrund, staerke = Staerke.Mittel)
            Column {
                Text(uebersetzt(when {
                        anzahl > 1 -> "Läuft gerade"
                        angebote.isEmpty() -> "Gemeinsam schauen"
                        else -> "Hier weiterschauen"
                     }), style = TvStil.knopf, color = vordergrund, maxLines = 1)
                if (fokus) Text(erstes?.titelzeile ?: gruppen.first().name, style = TvStil.klein, color = vordergrund.copy(alpha = 0.75f),
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            // Der Zaehler, wenn es mehr als eins ist — derselbe wie am Telefon.
            if (anzahl > 1) Box(Modifier.defaultMinSize(18.dp, 18.dp).clip(CircleShape).background(vordergrund).padding(horizontal = 5.dp),
                                contentAlignment = Alignment.Center) {
                Text("$anzahl", style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum"),
                     color = if (fokus) Color.White else Stil.aufAkzent)
            }
        }
    }
}

/** Vorlage: `ReiterStil` — Lupe 1,06, ruhige Flaeche im Fokus, gewaehlt mit Akzentstrich. */
@Composable
private fun Reiter(text: String, gewaehlt: Boolean, tun: () -> Unit) {
    Fokusflaeche(lupe = TvStil.fokusLupe, tun = tun) { fokus ->
        // Die ruhige Fokusflaeche, dieselbe wie ueberall — nicht ein eigener Weisswert.
        Column(Modifier.clip(RoundedCornerShape(TvStil.ecke)).background(if (fokus) TvStil.fokusflaeche else Color.Transparent)
                .padding(horizontal = 12.dp, vertical = 5.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            Text(text, style = TvStil.knopf,
                 color = if (fokus || gewaehlt) Stil.schrift else Stil.schriftLeise)
            Box(Modifier.padding(top = 3.dp).size(18.dp, 2.dp).clip(CircleShape).background(if (gewaehlt) Stil.akzent else Color.Transparent))
        }
    }
}

/**
 * Vorlage: `Handlungstafel` — dieselben Wuensche wie das Blatt auf dem Telefon (`app.blatt`), als
 * Tafel am rechten Rand. **Der Fokus bleibt drin**, bis sie zu ist; Zurueck schliesst nur sie.
 *
 * **Fokus zurueck an die Zeile, die die Tafel geoeffnet hat** (Auswahl oder Zurueck) — siehe
 * `Fokusmerker` in TvStil.kt. Ohne das landete der Fokus nach dem Schliessen zufaellig, z. B. auf
 * dem „+"-Knopf im Kontenstreifen der Profilseite, egal welche Zeile die Tafel ausgeloest hatte.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun TvTafel(app: SwiftlyAnwendung) {
    val w = app.blatt.value
    LaunchedEffect(w == null) { if (w == null) { delay(TvStil.fokusFrist); Fokusmerker.zurueckfordern() } }
    if (w == null) return
    // `exit = Cancel` haelt die Fokussuche in der Tafel — sperrt aber auch ein programmatisches
    // `requestFocus` nach draussen (Compose fragt beim Verlassen jeder Gruppe `exit`). Deshalb
    // gibt `freigabe` den Ausgang genau fuer das Zurueckgeben frei.
    val freigabe = remember(w) { booleanArrayOf(false) }
    // **Erst den Fokus zurueck an den Ausloeser, dann die Tafel entfernen** — umgekehrt fiele der
    // Fokus fuer ein paar Bilder auf den ersten fokussierbaren Knoten (siehe `Fokusmerker.zurueckgeben`).
    val schliessen = {
        freigabe[0] = true
        Fokusmerker.zurueckgeben()
        if (app.blatt.value === w) app.blatt.value = null
    }
    // Eine Zeile kann gleich die naechste Tafel oeffnen (`waehlen` setzt `app.blatt` neu) — dann
    // bleibt der Fokus in der Tafel und nichts wird geschlossen.
    val waehlenUndSchliessen = { tun: () -> Unit ->
        tun()
        if (app.blatt.value === w) schliessen()
    }
    BackHandler(onBack = schliessen)
    var auswahl by remember(w) { mutableStateOf(w.mehrfach) }
    val erster = remember(w) { FocusRequester() }
    LaunchedEffect(w) { delay(TvStil.fokusFrist); runCatching { erster.requestFocus() } }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f))) {
        CompositionLocalProvider(LocalInnerhalbTafel provides true) {
            Column(Modifier.align(Alignment.CenterEnd).padding(end = TvStil.randSeite).width(310.dp)
                    .clip(RoundedCornerShape(TvStil.eckeFlaeche)).background(Stil.flaeche).padding(10.dp)
                    .focusProperties { exit = { if (freigabe[0]) FocusRequester.Default else FocusRequester.Cancel } }.focusGroup()) {
                // Ohne Titel keine Kopfzeile — das Titelmenue von Filme und Serien hat auf tvOS keine.
                if (w.titel.isNotEmpty()) Text(w.titel, style = TvStil.rubrikGross, color = Stil.schrift, maxLines = 2,
                     modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp))
                w.unterzeile?.let { Text(it, style = TvStil.koerper, color = Stil.schriftLeise,
                     modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp)) }
                Column(Modifier.heightIn(max = 380.dp).verticalScroll(rememberScrollState())) {
                    w.eintraege.forEachIndexed { i, e ->
                        w.rubriken[e.wert]?.let { ueber ->
                            // Vorlage: die Rubrik der `Handlungstafel` — Trennlinie, darunter die
                            // Ueberschrift in Versalien, `schriftSehrLeise`, oben `reihenKopfLuft` (24 → 12),
                            // unten 8 → 4; eingerueckt wie der Text der Zeilen, alles an einer Kante.
                            Box(Modifier.padding(horizontal = 16.dp).fillMaxWidth().height(1.dp).background(Stil.linie))
                            Text(ueber.uppercase(), style = Stil.gruppe, color = Stil.schriftSehrLeise,
                                 modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 4.dp))
                        }
                        val menge = auswahl
                        TvZeile(e.text, w.symbole[e.wert], rechts = w.gesperrt[e.wert],
                                haken = if (menge != null) e.wert in menge else e.wert == w.gewaehlt,
                                modifier = if (i == 0) Modifier.focusRequester(erster) else Modifier) {
                            if (w.gesperrt[e.wert] != null) return@TvZeile
                            if (menge != null) auswahl = if (e.wert in menge) menge - e.wert else menge + e.wert
                            else waehlenUndSchliessen { w.waehlen(e.wert) }
                        }
                    }
                }
                w.abschluss?.let { abschluss ->
                    val menge = auswahl.orEmpty()
                    TvZeile(w.abschlussText(menge.size)) { if (menge.isNotEmpty()) waehlenUndSchliessen { abschluss(menge) } }
                }
            }
        }
    }
}
