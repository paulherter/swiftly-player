package de.paulherter.swiftly.tv

import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.ui.draw.alpha
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material.icons.filled.Tablet
import androidx.compose.material.icons.filled.Tv
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
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
private val ohneGemeinsameKulisse = setOf("Person", "Genre", "Profil", "WeiteresKonto", "ServerAufnahme",
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
    LaunchedEffect(spiel) { if (spiel != null) kontext.startActivity(Intent(kontext, PlayerAktivitaet::class.java),
            android.app.ActivityOptions.makeCustomAnimation(kontext, de.paulherter.swiftly.R.anim.player_hoch, de.paulherter.swiftly.R.anim.halten).toBundle()) }

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
        val id = adresse.lastPathSegment ?: return@LaunchedEffect
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

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        TvKulissenebene(kulisse)
        Crossfade(bereich, animationSpec = tween(250), label = "bereich") { b ->
            val ziel = stapel[b].orEmpty().lastOrNull()
            val tiefe = stapel[b].orEmpty().size
            key(b, tiefe, ziel?.id) {
                val schluessel = seitenschluessel(b, tiefe, ziel?.id)
                val melden = remember(schluessel) { { url: String? -> kulissen[schluessel] = url } }
                CompositionLocalProvider(LocalKulisseMelden provides melden) {
                zustaende.SaveableStateProvider(schluessel) {
                    if (ziel == null) {
                        Box(Modifier.fillMaxSize()) {
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
                            if (b != TvBereich.Start) TvKopfverlauf(Modifier.align(Alignment.TopStart))
                            Kopfleiste(app, b, { bereich = it }, app.angebote.value) { oeffnen(Ziel("profil", uebersetzt("Profil"), "Profil")) }
                        }
                    } else {
                        TvUnterseite(app, ziel, oeffnen, zurueck)
                    }
                }
                }
            }
        }
        // Solange der Player laeuft, gehoert die Tafel ihm.
        if (spiel == null) TvTafel(app)
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
private fun TvKulissenebene(bild: String?) {
    val kontext = LocalContext.current
    val dichte = LocalDensity.current
    var steht by remember { mutableStateOf(bild) }
    LaunchedEffect(bild) {
        if (bild != null && bild != steht) {
            SingletonImageLoader.get(kontext).execute(ImageRequest.Builder(kontext).data(bild)
                .size(with(dichte) { 590.dp.roundToPx() }, with(dichte) { 350.dp.roundToPx() }).build())
        }
        steht = bild
    }
    val schatten by animateFloatAsState(if (steht != null) 1f else 0f, tween(300), label = "kopfschatten")
    Box(Modifier.fillMaxSize()) {
        TvBildgrund(steht)
        Kulisse(steht, Modifier.align(Alignment.TopEnd))
        Box(Modifier.fillMaxWidth().alpha(schatten)) { Kopfschatten() }
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
            TvAnmeldeSeite(app, app.servername.value.orEmpty(), "", weiteresKonto = true, andererServer = zurueck) { zurueck() }
        }
        "ServerAufnahme" -> TvServerAufnahme(app, ziel.id.takeIf { it != "serveraufnahme" }, zurueck)
        "Wiedergabeeinstellungen" -> WiedergabeEinstellungenSeite(app, zurueck)
        "Darstellung" -> DarstellungSeite(app, oeffnen, zurueck)
        "Einstellungen" -> EinstellungenSeite(app, oeffnen, zurueck)
        "Seerr" -> TvSeerrSeite(app, zurueck)
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
        if (angebote.isNotEmpty()) {
            TvUebernahmeabzeichen(app, angebote)
            Spacer(Modifier.width(18.dp))
        }
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

private fun uebernahmezeichen(art: String): ImageVector = when (art) {
    "telefon" -> Icons.Filled.Smartphone
    "tablet" -> Icons.Filled.Tablet
    "rechner" -> Icons.Filled.Computer
    "fernseher" -> Icons.Filled.Tv
    else -> Icons.Filled.PlayCircle
}

/**
 * Vorlage: `Uebernahmeabzeichen` in `Sources/tvOS/TVBausteine.swift` — „Laeuft auf dem iPhone — hier
 * weiterschauen", in Ruhe eine Zeile, der Titel kommt im Fokus dazu. Auf dem Telefon steckt dieselbe
 * Handlung in `Uebernahmezeichen` (`Uebernahme.kt`); die Logik (`app.kern.uebernehmen`, `Angebot`) ist
 * dieselbe, nur die Zeichnung ist tvOS-eigen — kuehl statt Akzent, Kapsel statt Kreis.
 *
 * **Mehrere Angebote oeffnen `TvTafel` statt eines eigenen Auswahlblatts** wie auf tvOS
 * (`TVUebernahmeauswahl`): die Tafel kann Symbol, Haken und Auswahl schon, ein zweites Blatt waere
 * eine Kopie derselben Handlung.
 */
@Composable
private fun TvUebernahmeabzeichen(app: SwiftlyAnwendung, angebote: List<Angebot>) {
    val kontext = LocalContext.current
    val lauf = rememberCoroutineScope()
    var uebernimmt by remember { mutableStateOf(false) }
    fun uebernehmen(a: Angebot) {
        if (uebernimmt) return
        uebernimmt = true
        lauf.launch {
            val grund = withContext(Dispatchers.IO) { app.kern.uebernehmen(a.sitzung).await() }
            if (grund.isEmpty()) {
                app.angebote.value = emptyList()
                app.spiel.value = Abspielwunsch(a.itemID, a.stelle)
            } else Toast.makeText(kontext, fehlertext(grund), Toast.LENGTH_LONG).show()
            uebernimmt = false
        }
    }
    val erstes = angebote.first()
    Fokusflaeche(lupe = 1.06f, tun = {
        if (angebote.size == 1) uebernehmen(erstes)
        else app.blatt.value = Blattwunsch(uebersetzt("Wo weiterschauen?"),
            angebote.map { a -> Wahl(a.sitzung, listOfNotNull(a.geraet ?: uebersetzt("Gerät"), a.titelzeile).joinToString(" · ")) },
            null, angebote.associate { it.sitzung to uebernahmezeichen(it.art) }) { s ->
                angebote.firstOrNull { it.sitzung == s }?.let { uebernehmen(it) }
            }
    }) { fokus ->
        Row(Modifier.height(if (fokus) 38.dp else 32.dp).clip(RoundedCornerShape(50))
                .background(Stil.kuehl.copy(alpha = 0.18f)).padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            Icon(uebernahmezeichen(erstes.art), contentDescription = null, tint = Stil.kuehl, modifier = Modifier.size(13.dp))
            Column {
                Text(uebersetzt("Hier weiterschauen"), style = TextStyle(fontSize = 13.5.sp, fontWeight = FontWeight.SemiBold),
                     color = Stil.kuehl, maxLines = 1)
                if (fokus) Text(erstes.titelzeile, style = TextStyle(fontSize = 10.5.sp), color = Stil.kuehl.copy(alpha = 0.75f),
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
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
 *
 * **Fokus zurueck an die Zeile, die die Tafel geoeffnet hat** (Auswahl oder Zurueck) — siehe
 * `Fokusmerker` in TvStil.kt. Ohne das landete der Fokus nach dem Schliessen zufaellig, z. B. auf
 * dem „+"-Knopf im Kontenstreifen der Profilseite, egal welche Zeile die Tafel ausgeloest hatte.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun TvTafel(app: SwiftlyAnwendung) {
    val w = app.blatt.value
    LaunchedEffect(w == null) { if (w == null) { delay(30); Fokusmerker.zurueckfordern() } }
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
    LaunchedEffect(w) { delay(30); runCatching { erster.requestFocus() } }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f))) {
        CompositionLocalProvider(LocalInnerhalbTafel provides true) {
            Column(Modifier.align(Alignment.CenterEnd).padding(end = TvStil.randSeite).width(310.dp)
                    .clip(RoundedCornerShape(10.dp)).background(Stil.erhoeht).padding(10.dp)
                    .focusProperties { exit = { if (freigabe[0]) FocusRequester.Default else FocusRequester.Cancel } }.focusGroup()) {
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
