package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.gemeinsam.Staerke
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.kern.Kern
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

// MARK: Sammlungen — Vorlage `Sources/Shared/Sammlungsseite.swift`

/** Eine Sammlung im Bereich (`Sammlung` im Paket) — `plakat` fehlt ohne eigenes Bild. */
data class Sammlungskachel(val id: String, val name: String, val plakat: String?, val anzahl: Int)

/** Liest einen Eintrag aus `Kern.sammlungen`. */
fun sammlungskachelLesen(o: JSONObject) =
    Sammlungskachel(o.getString("id"), o.getString("name"), o.feldText("plakat"), o.optInt("anzahl"))

/**
 * Der Weg auf die Sammlungsseite — `SammlungRoute`: die Sammlung und ihr Bereich (`movies`,
 * `tvshows`), in `rolle`. Ohne Bereich (aus Suche oder Merkliste): alles, was darin steht.
 */
fun sammlungsziel(id: String, name: String, art: String?) = Ziel(id, name, "BoxSet", rolle = art)

/**
 * „3 Filme" bzw. „3 Serien" unter einer Sammlungskachel — `anzahltext` in `BibliothekView`.
 * Die Regel steht im Paket, nicht hier (``Sammlung.anzahltext(art:anzahl:)``).
 */
fun sammlungsanzahl(art: String?, n: Int): String = Kern.sammlungsanzahltext(art.orEmpty(), n.toLong())

/**
 * Die Plakate der ersten Titel je Sammlung — einmal geholt, dann aus dem Speicher: das Raster
 * komponiert eine Kachel beim Scrollen neu, und jedes Mal dieselbe Abfrage waere Verschwendung.
 */
private object Mosaikspeicher {
    val plakate = mutableMapOf<String, List<String?>>()
}

/**
 * **Ersatzplakat einer Sammlung ohne eigenes Bild** — `Sammlungsmosaik`: ein Mosaik aus den Plakaten
 * ihrer ersten Titel, im selben 2:3-Format und mit denselben Ecken wie jedes andere Plakat. Ohne
 * eigenes Bild stand hier bisher das Filmsymbol — die verworfene Fassung.
 *
 * **Eine Reihe je nach Menge.** Ein Titel fuellt das Feld, zwei stehen nebeneinander, ab drei wird
 * daraus ein 2×2-Mosaik. Fuge 2 auf dem Telefon; auf dem Fernseher die Haelfte von tvOS' 4, also auch 2.
 *
 * `zeichen`: das Filmsymbol im leeren Feld, wie `Bild` am iPhone; auf dem Fernseher bleibt es bei der
 * blossen Flaeche (`Bild` auf tvOS).
 */
@Composable
fun Sammlungsmosaik(app: SwiftlyAnwendung, id: String, art: String?, hoehe: Int, modifier: Modifier = Modifier,
                    ecke: Dp = Stil.eckeKachel, zeichen: Boolean = true) {
    val schluessel = "$id|${art.orEmpty()}"
    var plakate by remember(schluessel) { mutableStateOf(Mosaikspeicher.plakate[schluessel].orEmpty()) }
    LaunchedEffect(schluessel) {
        if (Mosaikspeicher.plakate.containsKey(schluessel)) return@LaunchedEffect
        val liste = try {
            JSONArray(withContext(Dispatchers.IO) { app.kern.sammlungsmosaik(id, art.orEmpty(), hoehe.toLong()).await() })
                .let { a -> (0 until a.length()).map { if (a.isNull(it)) null else a.getString(it) } }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { return@LaunchedEffect }
        Mosaikspeicher.plakate[schluessel] = liste
        plakate = liste
    }
    val reihen: List<List<String?>> = when {
        plakate.isEmpty() -> listOf(listOf(null))
        plakate.size > 2 -> listOf(plakate.take(2), plakate.drop(2).take(2))
        else -> listOf(plakate)
    }
    Column(modifier.clip(RoundedCornerShape(ecke)), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        reihen.forEach { stapel ->
            Row(Modifier.fillMaxWidth().weight(1f), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                stapel.forEach { adresse ->
                    Box(Modifier.weight(1f).fillMaxHeight().background(Stil.flaeche), contentAlignment = Alignment.Center) {
                        var fehlt by remember(adresse) { mutableStateOf(adresse == null) }
                        if (fehlt && zeichen) Symbol(Zeichen.Film, 22.dp, farbe = Stil.schriftSehrLeise)
                        if (adresse != null) AsyncImage(model = adresse, contentDescription = null, contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(), onError = { fehlt = true })
                    }
                }
            }
        }
    }
}

/**
 * Die Kachel einer Sammlung — `PosterTile` mit `mosaikQuelle` und `auskunft`: dieselbe Bauart wie
 * `RasterKachelAnsicht`, unter dem Namen die Anzahl statt des Jahres.
 */
@Composable
fun SammlungKachelAnsicht(app: SwiftlyAnwendung, s: Sammlungskachel, art: String, modifier: Modifier = Modifier, tun: () -> Unit) {
    Column(modifier.einblenden().antippen(tun), verticalArrangement = Arrangement.spacedBy(7.dp)) {
        val feld = Modifier.fillMaxWidth().aspectRatio(2f / 3f)
        if (s.plakat == null) Sammlungsmosaik(app, s.id, art, 260, feld)
        else Box(feld.clip(RoundedCornerShape(Stil.eckeKachel)).background(Stil.flaeche)) {
            var fehlt by remember(s.plakat) { mutableStateOf(false) }
            if (fehlt) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Symbol(Zeichen.Film, 22.dp, farbe = Stil.schriftSehrLeise)
            }
            AsyncImage(model = s.plakat, contentDescription = s.name, contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(), onError = { fehlt = true })
        }
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(s.name, style = Stil.kachel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(sammlungsanzahl(art, s.anzahl), style = Stil.klein, color = Stil.schriftSehrLeise, maxLines = 1)
        }
    }
}

/**
 * Das Raster einer Sammlung — `Bibliotheksmodell` mit `Regalquelle(sammlung: true)`. Sortiert ist
 * voreingestellt nach Jahr, und zwar aufsteigend (die Richtung setzt der Kern), damit eine Reihe in
 * ihrer Folge steht. **Nichts davon wird gemerkt**: eine Sammlung ist ein Blick in eine Reihe, kein
 * Ort, an den man zurueckkehrt.
 */
class Sammlungsstand(val id: String, val art: String?) {
    var items by mutableStateOf<List<Rasterkachel>>(emptyList()); private set
    var gesamt by mutableIntStateOf(0); private set
    var laedt by mutableStateOf(true); private set
    var gestoert by mutableStateOf(false); private set
    var sortierung by mutableStateOf("erscheinung")
    var filter by mutableStateOf("alle")
    private var laedtNach = false
    private var geladenFuer: String? = null

    val nochMehrDa: Boolean get() = items.size < gesamt
    /** Bei Serien derselbe Satz wie auf der Serienbibliothek. */
    val filterwahl: List<String> get() =
        if (art == "tvshows") listOf("alle", "angefangen", "merkliste") else Wahlen.filter.map { it.wert }

    suspend fun laden(kern: Kern) {
        laedt = items.isEmpty()
        gestoert = false
        try {
            val (neu, zahl) = seite(kern, 0)
            val fuer = "$sortierung|$filter"
            items = if (geladenFuer == fuer && zahl == gesamt && items.size > neu.size) {
                val bekannt = neu.mapTo(HashSet()) { it.id }
                neu + items.drop(neu.size).filter { bekannt.add(it.id) }
            } else neu.distinctBy { it.id }
            geladenFuer = fuer
            gesamt = zahl
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
            gestoert = items.isEmpty()
        }
        laedt = false
    }

    suspend fun nachladen(kern: Kern) {
        if (!nochMehrDa || laedtNach || laedt) return
        laedtNach = true
        try {
            val vorher = geladenFuer
            val (neu, zahl) = seite(kern, items.size)
            if (geladenFuer != vorher) return
            val bekannt = items.mapTo(HashSet()) { it.id }
            items = items + neu.filter { bekannt.add(it.id) }
            gesamt = zahl
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
        } finally { laedtNach = false }
    }

    private suspend fun seite(kern: Kern, ab: Int): Pair<List<Rasterkachel>, Int> {
        val o = JSONObject(withContext(Dispatchers.IO) {
            kern.sammlungSeite(id, art.orEmpty(), sortierung, filter, ab.toLong(), 60L).await()
        })
        val a = o.getJSONArray("titel")
        return (0 until a.length()).map { rasterkachelLesen(a.getJSONObject(it)) } to o.getInt("gesamt")
    }
}

/**
 * Vorlage: `SammlungView` in `Sammlungsseite.swift`. **Die Sammlungsseite ist eine Bibliotheksseite**:
 * kein Heldbild, keine eigene Bauart — Pfeil, Name, Filter und Sortierung, Raster; wie `GenreSeite`
 * als Unterseite und wie `BibliothekSeite` in der Steuerzeile.
 */
@Composable
fun SammlungSeite(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    val stand = remember(ziel.id, ziel.rolle) { Sammlungsstand(ziel.id, ziel.rolle) }
    val bereich = rememberCoroutineScope()
    LaunchedEffect(stand, stand.sortierung, stand.filter) { stand.laden(app.kern) }
    val raster = rememberLazyGridState()
    val dichte = LocalDensity.current
    val versatz by remember {
        derivedStateOf { if (raster.firstVisibleItemIndex > 0) 100f else raster.firstVisibleItemScrollOffset / dichte.density }
    }
    KopfUndInhalt(kopf = {
        Wurzelkopf({ versatz }, rand = false) {
            Unterseitenkopf(ziel.name, zurueck, unten = 0.dp, oben = false)
            // `Regalsteuerung` — dieselbe Zeile wie auf der Bibliotheksseite.
            Wertreihe({ versatz }, Modifier.padding(horizontal = Stil.randAbstand)) {
                Wertpille(Zeichen.Filter, Wahlen.text(Wahlen.filter, stand.filter)) {
                    app.blatt.value = Blattwunsch(uebersetzt("Filtern"), Wahlen.filter.filter { it.wert in stand.filterwahl }, stand.filter) {
                        stand.filter = it
                    }
                }
                Wertpille(Zeichen.Sortieren, Wahlen.text(Wahlen.sortierungen, stand.sortierung)) {
                    app.blatt.value = Blattwunsch(uebersetzt("Sortieren"), Wahlen.sortierungen, stand.sortierung) {
                        stand.sortierung = it
                    }
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
                    .collect { (letzter, geladen) ->
                        if (geladen > 0 && letzter >= geladen - anzahl * 3) stand.nachladen(app.kern)
                    }
            }
            LazyVerticalGrid(GridCells.Fixed(anzahl), state = raster,
                contentPadding = PaddingValues(start = Stil.randAbstand, end = Stil.randAbstand, top = kopfDp + 8.dp, bottom = 40.dp),
                horizontalArrangement = Arrangement.spacedBy(Stil.kachelAbstand),
                verticalArrangement = Arrangement.spacedBy(20.dp),
                modifier = Modifier.fillMaxSize().navigationBarsPadding()) {
                if (stand.items.isEmpty() && stand.laedt) items(anzahl * 3, key = { "platzhalter$it" }) { Kachelplatzhalter() }
                items(stand.items, key = { it.id }) { k -> RasterKachelAnsicht(k) { oeffnen(Ziel(k.id, k.titel, k.typ)) } }
                if (stand.items.isNotEmpty() && stand.nochMehrDa) items(anzahl, key = { "nachschub$it" }) { Kachelplatzhalter() }
            }
            if (stand.gestoert) {
                Leerzustand(Zeichen.ServerWeg, uebersetzt("Server ist abgetaucht"),
                    uebersetzt("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", app.serveradresse()),
                    hauptknopf = uebersetzt("Erneut versuchen") to { bereich.launch { stand.laden(app.kern) } })
            } else if (stand.items.isEmpty() && !stand.laedt) {
                val alle = stand.filter == "alle"
                Leerzustand(if (alle) Zeichen.Ablage else Zeichen.Filter,
                    uebersetzt(if (alle) "Hier ist noch nichts" else "Nichts gefunden"),
                    if (alle) uebersetzt("Sobald in dieser Sammlung etwas liegt, taucht es hier auf.")
                    else uebersetzt("Unter „%@“ liegt gerade nichts. Nimm einen anderen Filter.", Wahlen.text(Wahlen.filter, stand.filter)),
                    stillerKnopf = if (alle) uebersetzt("Aktualisieren") to { bereich.launch { stand.laden(app.kern) } }
                                   else uebersetzt("Filter zurücksetzen") to { stand.filter = "alle" })
            }
        }
    }
}

/** Eine Reihe „Teil der Sammlung" — die Sammlung und die anderen Titel darin, in ihrer Folge. */
data class Sammlungsreihendaten(val id: String, val name: String, val art: String, val titel: List<Rasterkachel>)

/** Liest `Kern.sammlungenFuerTitel` — still: ohne Sammlung oder bei einem Fehler leer. */
suspend fun sammlungsreihenLaden(kern: Kern, titelId: String): List<Sammlungsreihendaten> = try {
    val a = JSONArray(withContext(Dispatchers.IO) { kern.sammlungenFuerTitel(titelId).await() })
    (0 until a.length()).map { a.getJSONObject(it).let { o ->
        Sammlungsreihendaten(o.getString("id"), o.getString("name"), o.getString("art"),
                             o.feldListe("titel") { k -> rasterkachelLesen(k) })
    } }
} catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() }

/**
 * Vorlage: `Sammlungsreihe` in `Sammlungsseite.swift` — **die Reihe „Teil der Sammlung" auf der
 * Filmseite**, ueber „Aehnliche Titel": die Sammlung ist die naehere Verwandtschaft. Ihr Kopf oeffnet
 * die Sammlungsseite: „Teil der Sammlung" mit Pfeil, darunter der Name in 15 `schriftLeise`.
 *
 * Fehlt die Sammlung, fehlt die Reihe — wie bei den Extras. Hoechstens zwei Reihen (der Kern).
 */
@Composable
fun Sammlungsreihe(app: SwiftlyAnwendung, titelId: String, oeffnen: (Ziel) -> Unit) {
    var reihen by remember(titelId) { mutableStateOf<List<Sammlungsreihendaten>>(emptyList()) }
    LaunchedEffect(titelId) { reihen = sammlungsreihenLaden(app.kern, titelId) }
    reihen.forEach { reihe ->
        Column(Modifier.padding(top = Stil.reihenAbstand).einblenden(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Column(Modifier.padding(horizontal = Stil.randAbstand).antippen { oeffnen(sammlungsziel(reihe.id, reihe.name, reihe.art)) },
                   verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(uebersetzt("Teil der Sammlung"), style = Stil.reihe, color = Stil.schrift)
                    Symbol(Zeichen.WinkelRechts, 13.dp, farbe = Stil.schriftSehrLeise, staerke = Staerke.Halbfett)
                }
                Text(reihe.name, style = Stil.koerper, color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            LazyRow(contentPadding = PaddingValues(horizontal = Stil.randAbstand),
                    horizontalArrangement = Arrangement.spacedBy(Stil.kachelAbstand)) {
                items(reihe.titel, key = { it.id }) { k ->
                    RasterKachelAnsicht(k, Modifier.width(Stil.kachelBreite)) { oeffnen(Ziel(k.id, k.titel, k.typ)) }
                }
            }
        }
    }
}
