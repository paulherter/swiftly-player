package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.material.icons.outlined.SwapVert
import androidx.compose.material3.Text
import androidx.compose.runtime.*
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
        try {
            val (neu, zahl) = seite(kern, 0)
            items = neu
            gesamt = zahl
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
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

    Column(Modifier.fillMaxSize().background(Stil.grund)) {
        Unterseitenkopf(uebersetzt("Merkliste"), zurueck)
        Row(Modifier.fillMaxWidth().padding(horizontal = Stil.randAbstand).padding(bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Wertpille(Icons.Filled.GridView, Wahlen.text(gattungen, stand.gattung)) {
                app.blatt.value = Blattwunsch(uebersetzt("Merkliste"), gattungen, stand.gattung) { stand.gattungSetzen(it) }
            }
            Wertpille(Icons.Outlined.SwapVert, Wahlen.text(Wahlen.sortierungen, stand.sortierung)) {
                app.blatt.value = Blattwunsch(uebersetzt("Sortieren"), Wahlen.sortierungen, stand.sortierung) { stand.sortierungSetzen(it) }
            }
            Spacer(Modifier.weight(1f))
            if (stand.gesamt > 0) {
                Text(NumberFormat.getInstance().format(stand.gesamt),
                     style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium, fontFeatureSettings = "tnum"),
                     color = Stil.schriftSehrLeise)
            }
        }

        BoxWithConstraints(Modifier.fillMaxSize()) {
            val anzahl = Stil.spalten((maxWidth - Stil.randAbstand * 2).value)
            LaunchedEffect(raster, anzahl) {
                snapshotFlow { (raster.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1) to stand.items.size }
                    .collect { (letzter, geladen) -> if (geladen > 0 && letzter >= geladen - anzahl * 3) stand.nachladen(app.kern) }
            }
            LazyVerticalGrid(GridCells.Fixed(anzahl), state = raster,
                contentPadding = PaddingValues(start = Stil.randAbstand, end = Stil.randAbstand, top = 8.dp, bottom = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(Stil.kachelAbstand),
                verticalArrangement = Arrangement.spacedBy(20.dp),
                modifier = Modifier.fillMaxSize().navigationBarsPadding()) {
                if (stand.items.isEmpty() && stand.laedt) items(anzahl * 3, key = { "platzhalter$it" }) {
                    Box(Modifier.animateItem(fadeInSpec = null, placementSpec = null, fadeOutSpec = Bewegung.einblenden())) { Kachelplatzhalter() }
                }
                items(stand.items, key = { it.id }) { k -> RasterKachelAnsicht(k) { oeffnen(Ziel(k.id, k.titel, k.typ)) } }
                if (stand.items.isNotEmpty() && stand.nochMehrDa) items(anzahl, key = { "nachschub$it" }) { Kachelplatzhalter() }
            }
            // Sagt, woher der Inhalt kommt — ein blosses „hier ist nichts" waere eine Sackgasse.
            if (stand.items.isEmpty() && !stand.laedt) {
                Leerzustand(Icons.Outlined.BookmarkBorder, uebersetzt("Noch nichts gemerkt"),
                    uebersetzt("Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort antippst, sammelt sich hier."))
            }
        }
    }
}
