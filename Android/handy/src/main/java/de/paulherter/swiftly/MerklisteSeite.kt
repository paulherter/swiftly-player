package de.paulherter.swiftly

import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.derivedStateOf
import androidx.compose.ui.platform.LocalDensity
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.kern.Kern
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.text.NumberFormat

/**
 * **Gegenstueck zu `Merklistenmodell`** — eine Bibliothek, deren Grenze das Merk-Kennzeichen ist,
 * mit dem Aufbau der Bibliotheksseite statt einer eigenen Grammatik. Gattung und Sortierung
 * ueberleben den Neustart unter denselben Schluesseln wie auf iOS.
 */
class Merklistenstand(private val ablage: Ablage) {
    var items by mutableStateOf<List<Rasterkachel>>(emptyList()); private set
    var gesamt by mutableIntStateOf(0); private set
    var laedt by mutableStateOf(true); private set
    /**
     * **Der Server hat nicht geantwortet — nicht „hier liegt nichts".**
     *
     * Der Fehler wurde hier verschluckt (`catch (_: Exception) {}`), und die leere Liste
     * danach sagte „Noch nichts gemerkt". Bei einer vollen Merkliste ist das schlicht
     * falsch — dieselbe Luege, die auf iOS am 21.09. an fuenfundzwanzig Stellen behoben wurde.
     */
    var gestoert by mutableStateOf(false); private set
    /** Vorgabe „Zuletzt": eine Merkliste ist eine Absicht, kein Regal — A–Z waere Regalordnung. */
    var sortierung by mutableStateOf(ablage.merkwert("sortierung.merkliste") ?: "neueste"); private set
    /** Leer heisst: Filme **und** Serien — kein dritter Fall. */
    var gattung by mutableStateOf(ablage.merkwert("gattung.merkliste").orEmpty()); private set
    private var laedtNach = false

    val nochMehrDa: Boolean get() = items.size < gesamt

    fun sortierungSetzen(wert: String) { sortierung = wert; ablage.merken("sortierung.merkliste", wert) }
    fun gattungSetzen(wert: String) { gattung = wert; ablage.merken("gattung.merkliste", wert) }
    fun vergessen() { items = emptyList(); gesamt = 0; laedt = true }

    suspend fun laden(kern: Kern) {
        laedt = items.isEmpty()
        gestoert = false
        try {
            val (neu, zahl) = seite(kern, 0)
            items = neu
            gesamt = zahl
        } catch (e: CancellationException) {
            // Ein Abbruch ist kein Ausfall: der Nachfolger laedt schon.
            throw e
        } catch (_: Exception) {
            // Was schon dasteht, bleibt stehen — gestoert ist nur, wer nichts zu zeigen hat.
            gestoert = items.isEmpty()
        }
        laedt = false
    }

    suspend fun nachladen(kern: Kern) {
        if (!nochMehrDa || laedtNach || laedt) return
        laedtNach = true
        try {
            val (neu, zahl) = seite(kern, items.size)
            val bekannt = items.mapTo(HashSet()) { it.id }
            items = items + neu.filter { bekannt.add(it.id) }
            gesamt = zahl
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
        } finally { laedtNach = false }
    }

    private suspend fun seite(kern: Kern, ab: Int): Pair<List<Rasterkachel>, Int> {
        val o = JSONObject(withContext(Dispatchers.IO) { kern.merkliste(gattung, sortierung, ab.toLong(), 60L).await() })
        val a = o.getJSONArray("titel")
        return (0 until a.length()).map { rasterkachelLesen(a.getJSONObject(it)) } to o.getInt("gesamt")
    }
}

/**
 * Vorlage: `MerklisteView` in `Sources/Shared/MerklisteView.swift`, schmale Fassung — eine Seite
 * mit Zurueck-Pfeil, erreicht ueber das Zeichen im Kopf.
 *
 * **Das Rasterzeichen, nicht der Trichter:** die Bibliothek traegt an derselben Stelle „Alle" als
 * Zustand; hier waehlt die Pille eine Gattung. Gleiches Wort, gleicher Platz, zwei Bedeutungen
 * waeren eine Falle (E25). Entfernt wird auf der Titelseite, nicht hier.
 */
@Composable
fun MerklisteSeite(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    val stand = app.merkliste
    // Bei jedem Ankommen neu — was auf einer Titelseite entfernt wurde, ist dann weg.
    LaunchedEffect(stand.sortierung, stand.gattung) { stand.laden(app.kern) }
    val gattungen = remember { wahlenLesen(Kern.merkgattungen()) }
    val raster = rememberLazyGridState()
    val bereich = rememberCoroutineScope()

    val dichte = LocalDensity.current
    val versatz by remember {
        derivedStateOf { if (raster.firstVisibleItemIndex > 0) 100f else raster.firstVisibleItemScrollOffset / dichte.density }
    }

    // **Der Inhalt laeuft unter dem Kopf durch** — `safeAreaInset(edge: .top) { kopf }` auf dem iPhone.
    KopfUndInhalt(kopf = {
        // Der Pfeil sitzt am Rand wie auf jeder Unterseite, die Wertreihe darunter im Seitenrand.
        Wurzelkopf({ versatz }, rand = false) {
            Unterseitenkopf(uebersetzt("Merkliste"), zurueck, unten = 0.dp, oben = false)
            Wertreihe({ versatz }, Modifier.padding(horizontal = Stil.randAbstand)) {
                Wertpille(Zeichen.Raster, Wahlen.text(gattungen, stand.gattung)) {
                    app.blatt.value = Blattwunsch(uebersetzt("Merkliste"), gattungen, stand.gattung) { stand.gattungSetzen(it) }
                }
                Wertpille(Zeichen.Sortieren, Wahlen.text(Wahlen.sortierungen, stand.sortierung)) {
                    app.blatt.value = Blattwunsch(uebersetzt("Sortieren"), Wahlen.sortierungen, stand.sortierung) { stand.sortierungSetzen(it) }
                }
                Spacer(Modifier.weight(1f))
                if (stand.gesamt > 0) Zaehlmarke(stand.gesamt)
            }
        }
    }) { kopfDp ->
        BoxWithConstraints(Modifier.fillMaxSize().background(Stil.grund)) {
            val anzahl = Stil.spalten((maxWidth - Stil.randAbstand * 2).value)
            LaunchedEffect(raster, anzahl) {
                snapshotFlow { (raster.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1) to stand.items.size }
                    .collect { (letzter, geladen) -> if (geladen > 0 && letzter >= geladen - anzahl * 3) stand.nachladen(app.kern) }
            }
            LazyVerticalGrid(GridCells.Fixed(anzahl), state = raster,
                contentPadding = PaddingValues(start = Stil.randAbstand, end = Stil.randAbstand, top = kopfDp + 8.dp, bottom = 24.dp),
                horizontalArrangement = Arrangement.spacedBy(Stil.kachelAbstand),
                verticalArrangement = Arrangement.spacedBy(20.dp),
                modifier = Modifier.fillMaxSize().navigationBarsPadding()) {
                if (stand.items.isEmpty() && stand.laedt) items(anzahl * 3, key = { "platzhalter$it" }) {
                    Box(Modifier.animateItem(fadeInSpec = null, placementSpec = null, fadeOutSpec = Bewegung.einblenden())) { Kachelplatzhalter() }
                }
                items(stand.items, key = { it.id }) { k -> RasterKachelAnsicht(k) { oeffnen(Ziel(k.id, k.titel, k.typ)) } }
                if (stand.items.isNotEmpty() && stand.nochMehrDa) items(anzahl, key = { "nachschub$it" }) { Kachelplatzhalter() }
            }
            // **Gestoert und leer sind zwei Zustaende.** Vorlage: `MerklisteView`.
            if (stand.gestoert && stand.items.isEmpty() && !stand.laedt) {
                Leerzustand(Zeichen.ServerWeg, uebersetzt("Server ist abgetaucht"),
                    uebersetzt("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", app.serveradresse()),
                    hauptknopf = uebersetzt("Erneut versuchen") to { bereich.launch { stand.laden(app.kern) } })
            } else if (stand.items.isEmpty() && !stand.laedt) {
                Leerzustand(Zeichen.Lesezeichen, uebersetzt("Noch nichts gemerkt"),
                    uebersetzt("Tippe irgendwo auf das Lesezeichen. Dein Zukunfts-Ich freut sich."))
            }
        }
    }
}
