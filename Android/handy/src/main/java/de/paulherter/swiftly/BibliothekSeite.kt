package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.outlined.SwapVert
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.kern.Kern
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.text.NumberFormat

data class Rasterkachel(val id: String, val titel: String, val unterzeile: String?, val plakat: String?,
                        val fortschritt: Double?, val marke: String?, val markenzahl: Int)
data class Sammlung(val id: String, val name: String)

/** Wie `AppModel.seitengroesse`. */
private const val SEITE = 60L

private fun JSONObject.textOderNull(feld: String): String? = if (isNull(feld)) null else getString(feld)

/** Die Woerter fuer Sortierung und Filter kommen aus dem Paket — dieselben wie auf Apple und Linux. */
object Wahlen {
    private val json by lazy { JSONObject(Kern.beschriftungen()) }
    val sortierungen: List<Wahl> by lazy { lesen("sortierung") }
    val filter: List<Wahl> by lazy { lesen("filter") }
    private fun lesen(feld: String): List<Wahl> = json.getJSONArray(feld).let { a ->
        (0 until a.length()).map { a.getJSONObject(it).let { o -> Wahl(o.getString("wert"), o.getString("text")) } }
    }
    fun text(liste: List<Wahl>, wert: String) = liste.firstOrNull { it.wert == wert }?.text ?: wert
}

/**
 * **Gegenstueck zu `Bibliotheksmodell`** plus der Bibliothekswahl aus `BibliothekView`.
 * Lebt in der App, nicht in der Seite — ein Bereichswechsel leert sonst das Raster.
 *
 * Sortierung und Filter ueberleben den Neustart, **je Ort** (`sortierung.movies`), wie auf iOS.
 */
class Bibliotheksstand(val art: String, private val ablage: Ablage) {
    var items by mutableStateOf<List<Rasterkachel>>(emptyList()); private set
    var gesamt by mutableIntStateOf(0); private set
    var laedt by mutableStateOf(true); private set
    /** Der Server hat nicht geantwortet — im Unterschied zu „hier liegt nichts". */
    var gestoert by mutableStateOf(false); private set
    var sammlungen by mutableStateOf<List<Sammlung>>(emptyList()); private set
    var gewaehlt by mutableStateOf<Sammlung?>(null); private set
    var servername by mutableStateOf<String?>(null); private set
    var sortierung by mutableStateOf(ablage.merkwert("sortierung.$art") ?: "name"); private set
    var filter by mutableStateOf(ablage.merkwert("filter.$art") ?: "alle"); private set
    private var laedtNach = false

    val nochMehrDa: Boolean get() = items.size < gesamt

    fun sortierungSetzen(wert: String) { sortierung = wert; ablage.merken("sortierung.$art", wert) }
    fun filterSetzen(wert: String) { filter = wert; ablage.merken("filter.$art", wert) }
    fun waehlen(s: Sammlung) { gewaehlt = s; ablage.merken("bibliothek-$art", s.id) }

    suspend fun laden(kern: Kern) {
        laedt = items.isEmpty()
        gestoert = false
        var erreicht = sammlungen.isNotEmpty()
        if (!erreicht) {
            try {
                val a = JSONArray(withContext(Dispatchers.IO) { kern.bibliotheken(art).await() })
                sammlungen = (0 until a.length()).map { a.getJSONObject(it).let { o -> Sammlung(o.getString("id"), o.getString("name")) } }
                erreicht = true
            } catch (e: CancellationException) { throw e } catch (_: Exception) {}
        }
        if (servername == null) {
            try { servername = withContext(Dispatchers.IO) { kern.servername().await() }.takeIf { it.isNotEmpty() } }
            catch (e: CancellationException) { throw e } catch (_: Exception) {}
        }
        // Die gemerkte Wahl, sonst die erste — `AppModel.gewaehlteBibliothek(art:)`.
        if (gewaehlt == null || sammlungen.none { it.id == gewaehlt?.id }) {
            val gemerkt = ablage.merkwert("bibliothek-$art")
            gewaehlt = sammlungen.firstOrNull { it.id == gemerkt } ?: sammlungen.firstOrNull()
        }
        val bib = gewaehlt
        if (bib == null) {
            // Kein Server und keine Sammlung dieser Art sehen hier gleich aus — unterschieden
            // daran, ob die Sammlungen ueberhaupt kamen.
            gestoert = !erreicht
            laedt = false
            return
        }
        try {
            val (neu, zahl) = seite(kern, bib.id, 0)
            items = neu
            gesamt = zahl
        } catch (e: CancellationException) {
            // Ein Abbruch ist kein Ausfall: der Nachfolger laedt schon.
            throw e
        } catch (_: Exception) {
            // Was schon dasteht, bleibt stehen.
            gestoert = items.isEmpty()
        }
        laedt = false
    }

    suspend fun nachladen(kern: Kern) {
        val bib = gewaehlt ?: return
        if (!nochMehrDa || laedtNach || laedt) return
        laedtNach = true
        try {
            val (neu, zahl) = seite(kern, bib.id, items.size)
            // Der Server kann zwischen zwei Seiten etwas hinzufuegen — nichts doppelt.
            val bekannt = items.mapTo(HashSet()) { it.id }
            items = items + neu.filter { bekannt.add(it.id) }
            gesamt = zahl
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
        } finally { laedtNach = false }
    }

    private suspend fun seite(kern: Kern, bibliothek: String, ab: Int): Pair<List<Rasterkachel>, Int> {
        val o = JSONObject(withContext(Dispatchers.IO) {
            kern.bibliothekSeite(bibliothek, art, sortierung, filter, ab.toLong(), SEITE).await()
        })
        val a = o.getJSONArray("titel")
        return (0 until a.length()).map { i ->
            a.getJSONObject(i).let { k ->
                Rasterkachel(k.getString("id"), k.getString("titel"), k.textOderNull("unterzeile"), k.textOderNull("plakat"),
                             if (k.isNull("fortschritt")) null else k.getDouble("fortschritt"),
                             k.textOderNull("marke"), k.optInt("markenzahl"))
            }
        } to o.getInt("gesamt")
    }
}

/** Vorlage: `BibliothekView` in `Sources/Shared/HauptView.swift` (schmale Fassung). */
@Composable
fun BibliothekSeite(app: SwiftlyAnwendung, art: String, titel: String, filterwahl: List<String>) {
    val stand = remember(art) { app.bibliotheken.getOrPut(art) { Bibliotheksstand(art, app.ablage) } }
    val bereich = rememberCoroutineScope()
    LaunchedEffect(stand.sortierung, stand.filter) { stand.laden(app.kern) }
    val raster = rememberLazyGridState()
    val dichte = LocalDensity.current
    // Daran haengt die Haarlinie unter dem Kopf.
    val versatz by remember {
        derivedStateOf { if (raster.firstVisibleItemIndex > 0) 100f else raster.firstVisibleItemScrollOffset / dichte.density }
    }

    KopfUndInhalt(kopf = { BibliothekKopf(app, stand, titel, filterwahl) { versatz } }) { kopfDp ->
    BoxWithConstraints(Modifier.fillMaxSize().background(Stil.grund)) {
        // `Stil.spalten(nutzbar:)` — auf jedem Telefon drei.
        val anzahl = Stil.spalten((maxWidth - Stil.randAbstand * 2).value)
        // Nachladen, sobald die drittletzte Reihe auftaucht — `Listenregeln.nachladenAb`.
        LaunchedEffect(raster, anzahl) {
            snapshotFlow { (raster.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1) to stand.items.size }
                .collect { (letzter, geladen) ->
                    if (geladen > 0 && letzter >= geladen - anzahl * 3) stand.nachladen(app.kern)
                }
        }

        LazyVerticalGrid(
            columns = GridCells.Fixed(anzahl), state = raster,
            contentPadding = PaddingValues(start = Stil.randAbstand, end = Stil.randAbstand, top = kopfDp + 8.dp, bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(Stil.kachelAbstand),
            verticalArrangement = Arrangement.spacedBy(20.dp),
            modifier = Modifier.fillMaxSize()
        ) {
            // Platzhalter statt Ring: das Raster steht schon in seiner Form.
            if (stand.items.isEmpty() && stand.laedt) items(anzahl * 3) { Kachelplatzhalter() }
            items(stand.items, key = { it.id }) { RasterKachelAnsicht(it) }
            // Kein Ring beim Nachladen — eine Reihe Platzhalter.
            if (stand.items.isNotEmpty() && stand.nochMehrDa) items(anzahl) { Kachelplatzhalter() }
        }

        if (stand.gestoert) {
            val server = app.ablage.letzterServer?.let { runCatching { java.net.URI(it).host }.getOrNull() }
                ?: uebersetzt("Der Server")
            Leerzustand(Icons.Outlined.CloudOff, uebersetzt("Kein Kontakt zum Server"),
                uebersetzt("%@ hat nicht geantwortet. Läuft der Server, und bist du im selben Netz?", server),
                hauptknopf = uebersetzt("Erneut versuchen") to { bereich.launch { stand.laden(app.kern) } })
        } else if (stand.items.isEmpty() && !stand.laedt) {
            val alle = stand.filter == "alle"
            Leerzustand(if (alle) Icons.Outlined.Inbox else Icons.Outlined.FilterList,
                uebersetzt(if (alle) "Hier ist noch nichts" else "Nichts gefunden"),
                if (alle) uebersetzt("Sobald in dieser Bibliothek etwas liegt, taucht es hier auf.")
                else uebersetzt("Unter „%@“ liegt gerade nichts. Nimm einen anderen Filter.", Wahlen.text(Wahlen.filter, stand.filter)),
                stillerKnopf = if (alle) uebersetzt("Aktualisieren") to { bereich.launch { stand.laden(app.kern) } }
                               else uebersetzt("Filter zurücksetzen") to { stand.filterSetzen("alle") })
        }

    }
    }
}

/** Kopf der Bibliothek: Titel oder Bibliothekswahl, Servername, Kopfziele, Pillen, Anzahl. */
@Composable
private fun BibliothekKopf(app: SwiftlyAnwendung, stand: Bibliotheksstand, titel: String,
                           filterwahl: List<String>, versatz: () -> Float) {
    val bereich = rememberCoroutineScope()
    // Der Kopf deckt, was darunter durchlaeuft — `Unschaerfekopf(versatz:)` mit Grund.
    Column(Modifier.fillMaxWidth()
            // Die Haarlinie, sobald gescrollt ist — unten im Kopf, wie bei `Unschaerfekopf`.
            .drawWithContent {
                drawContent()
                val staerke = 1.dp.toPx()
                drawRect(Stil.linie, topLeft = Offset(0f, size.height - staerke), size = Size(size.width, staerke),
                         alpha = (versatz() / 30f).coerceIn(0f, 1f))
            }
            .background(Stil.grund)
            .statusBarsPadding().padding(horizontal = Stil.randAbstand).padding(bottom = 12.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                val gross = Stil.titelGross.copy(letterSpacing = (-0.6).sp)
                // Nur ab zwei Bibliotheken ein Menue.
                if (stand.sammlungen.size > 1) {
                    Row(Modifier.antippen {
                            app.blatt.value = Blattwunsch(uebersetzt("Bibliothek"), stand.sammlungen.map { Wahl(it.id, it.name) },
                                                          stand.gewaehlt?.id) { id ->
                                val s = stand.sammlungen.firstOrNull { it.id == id }
                                if (s != null && s.id != stand.gewaehlt?.id) {
                                    stand.waehlen(s)
                                    bereich.launch { stand.laden(app.kern) }
                                }
                            }
                        },
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(stand.gewaehlt?.name.orEmpty(), style = gross, color = Stil.schrift)
                        Icon(Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = Stil.schriftLeise, modifier = Modifier.size(22.dp))
                    }
                } else {
                    Text(titel, style = gross, color = Stil.schrift)
                }
                // Wo bin ich hier eigentlich? Der Servername.
                stand.servername?.let {
                    Text(it, style = TextStyle(fontSize = 13.sp), color = Stil.schriftSehrLeise, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            Kopfziele(app)
        }
        Spacer(Modifier.height(14.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Wertpille(Icons.Outlined.FilterList, Wahlen.text(Wahlen.filter, stand.filter)) {
                app.blatt.value = Blattwunsch(uebersetzt("Filtern"), Wahlen.filter.filter { it.wert in filterwahl }, stand.filter) {
                    stand.filterSetzen(it)
                }
            }
            Wertpille(Icons.Outlined.SwapVert, Wahlen.text(Wahlen.sortierungen, stand.sortierung)) {
                app.blatt.value = Blattwunsch(uebersetzt("Sortieren"), Wahlen.sortierungen, stand.sortierung) {
                    stand.sortierungSetzen(it)
                }
            }
            Spacer(Modifier.weight(1f))
            // Erst wenn wir sie kennen — eine Null, die noch keine ist, waere falsch.
            if (stand.gesamt > 0) {
                Text(NumberFormat.getInstance().format(stand.gesamt),
                     style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium, fontFeatureSettings = "tnum"),
                     color = Stil.schriftSehrLeise)
            }
        }
    }
}

/** Vorlage: `PosterTile` in `BrowseViews.swift` — fuellt die Spalte, 2:3, Titel zweizeilig. */
@Composable
private fun RasterKachelAnsicht(k: Rasterkachel) {
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(Stil.eckeKachel)).background(Stil.flaeche)) {
            SubcomposeAsyncImage(
                model = k.plakat, contentDescription = k.titel, contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
                error = {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Icon(Icons.Outlined.Movie, contentDescription = null, tint = Stil.schriftSehrLeise, modifier = Modifier.size(22.dp))
                    }
                }
            )
            k.fortschritt?.takeIf { it > 0 }?.let { Fortschrittsbalken(it, Modifier.align(Alignment.BottomStart)) }
            k.marke?.let { Kachelplakette(it, k.markenzahl, Modifier.align(Alignment.TopEnd)) }
        }
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(k.titel, style = Stil.kachel, color = Stil.schrift, maxLines = 2, overflow = TextOverflow.Ellipsis)
            k.unterzeile?.let { Text(it, style = Stil.klein, color = Stil.schriftLeise, maxLines = 1) }
        }
    }
}
