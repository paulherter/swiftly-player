package de.paulherter.swiftly

import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
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
import de.paulherter.swiftly.gemeinsam.Bewegung
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

data class Rasterkachel(val id: String, val titel: String, val typ: String, val unterzeile: String?, val plakat: String?,
                        val fortschritt: Double?, val marke: String?, val markenzahl: Int)

/** Wie `AppModel.seitengroesse`. */
private const val SEITE = 60L

private fun JSONObject.textOderNull(feld: String): String? = if (isNull(feld)) null else getString(feld)

/** Liest eine Kachel aus `Kern.bibliothekSeite` und `Kern.titelUmfeld` — dieselbe Form. */
fun rasterkachelLesen(k: JSONObject) = Rasterkachel(
    k.getString("id"), k.getString("titel"), k.optString("typ"), k.textOderNull("unterzeile"), k.textOderNull("plakat"),
    if (k.isNull("fortschritt")) null else k.getDouble("fortschritt"), k.textOderNull("marke"), k.optInt("markenzahl"))

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

/** Ein Eintrag im Titelmenue — `Bereichswahl` samt Beschriftung; `name` nur bei Bibliotheken. */
data class Angebotseintrag(val wert: String, val name: String?, val rubrik: Boolean)

/**
 * **Gegenstueck zu `Bibliotheksmodell`** plus der Bereichswahl aus `BibliothekView`: „Alle",
 * „Sammlungen", dann die Bibliotheken. Die Regeln (`Bereichsangebot`, `Titelsieb`) stehen im Paket
 * und kommen ueber den Kern; hier steht nur, was die Seite zeigt.
 * Lebt in der App, nicht in der Seite — ein Bereichswechsel leert sonst das Raster.
 *
 * Sortierung und Filter ueberleben den Neustart, **je Ort** (`sortierung.movies`), wie auf iOS. Die
 * Wahl liegt unter `bibliothek-<art>` — demselben Namen wie vorher die Bibliothek, damit eine
 * gewaehlte Bibliothek gewaehlt bleibt (`Bereichswahl.merkwert`).
 */
class Bibliotheksstand(val art: String, private val ablage: Ablage) {
    var items by mutableStateOf<List<Rasterkachel>>(emptyList()); private set
    var gesamt by mutableIntStateOf(0); private set
    var laedt by mutableStateOf(true); private set
    /** Der Server hat nicht geantwortet — im Unterschied zu „hier liegt nichts". */
    var gestoert by mutableStateOf(false); private set
    /** Was der Titel zur Wahl anbietet; ein Menue erst ab `istMenue`. */
    var angebot by mutableStateOf<List<Angebotseintrag>>(emptyList()); private set
    var istMenue by mutableStateOf(false); private set
    /** `alle`, `sammlungen` oder die Kennung einer Bibliothek. */
    var wahl by mutableStateOf("alle"); private set
    /** Die Sammlungen dieses Bereichs — stehen im Speicher, sobald das Angebot sie kennt. */
    var sammlungsliste by mutableStateOf<List<Sammlungskachel>>(emptyList()); private set
    var sortierung by mutableStateOf(ablage.merkwert("sortierung.$art") ?: "name"); private set
    var filter by mutableStateOf(ablage.merkwert("filter.$art") ?: "alle"); private set
    private var laedtNach = false
    /** Wofuer `items` geladen wurden — gleich heisst auffrischen, anders ersetzen. */
    private var geladenFuer: String? = null
    /** `BibliothekView.angebotskennung` — aendert sie sich, wird die Wahl neu geprueft. */
    private var kennung: String? = null
    /** Aus mehreren Bibliotheken gesiebt: dann sagt der Kern, ob der Server noch etwas hat. */
    private var siebMehr: Boolean? = null

    val nochMehrDa: Boolean get() = wahl != "sammlungen" && (siebMehr ?: (items.size < gesamt))
    val sammlungenGewaehlt: Boolean get() = wahl == "sammlungen"
    /** Was die Zaehlmarke zeigt. */
    val gezeigt: Int get() = if (sammlungenGewaehlt) sammlungsliste.size else gesamt

    fun sortierungSetzen(wert: String) { sortierung = wert; ablage.merken("sortierung.$art", wert) }
    fun filterSetzen(wert: String) { filter = wert; ablage.merken("filter.$art", wert) }
    fun waehlen(wert: String) { wahl = wert; ablage.merken("bibliothek-$art", wert) }

    /** `BibliothekView.beschriftung` — „Alle" heisst im Menue „Alle Filme", Bibliotheken wie vom Server. */
    fun beschriftung(wert: String): String = when (wert) {
        "alle" -> uebersetzt(if (art == "tvshows") "Alle Serien" else "Alle Filme")
        "sammlungen" -> uebersetzt("Sammlungen")
        else -> angebot.firstOrNull { it.wert == wert }?.name.orEmpty()
    }

    /** Die Rubrik „Bibliotheken" vor der ersten Bibliothek (`Bereichsangebot.ersteBibliothek`). */
    val rubriken: Map<String, String> get() =
        angebot.firstOrNull { it.rubrik }?.let { mapOf(it.wert to uebersetzt("Bibliotheken")) }.orEmpty()

    /** Das Angebot lesen und die gemerkte Wahl dagegen pruefen. `false`: der Server schwieg. */
    private suspend fun angebotLesen(kern: Kern): Boolean = try {
        val o = JSONObject(withContext(Dispatchers.IO) {
            kern.bereichsangebot(art, ablage.merkwert("bibliothek-$art") ?: "alle").await()
        })
        val a = o.getJSONArray("eintraege")
        angebot = (0 until a.length()).map { a.getJSONObject(it).let { e ->
            Angebotseintrag(e.getString("wert"), e.textOderNull("name"), e.optBoolean("rubrik")) } }
        istMenue = o.optBoolean("istMenue")
        // **Die gemerkte Wahl gehoert einem Konto** — eine Bibliothek, die es nicht mehr gibt, faellt
        // still auf „Alle" zurueck, statt eine fremde Kennung abzufragen.
        wahl = o.getString("wahl")
        kennung = o.getString("kennung")
        true
    } catch (e: CancellationException) { throw e } catch (_: Exception) { false }

    suspend fun laden(kern: Kern) {
        gestoert = false
        if (!angebotLesen(kern)) {
            // Kein Server und kein Bestand sehen hier gleich aus — unterschieden daran, ob das
            // Angebot ueberhaupt kam.
            gestoert = items.isEmpty() && !sammlungenGewaehlt
            laedt = false
            return
        }
        seiteLaden(kern)
        nachsehen(kern)
    }

    /**
     * **Sammlungen und gemischte Bibliotheken kommen nebenher** (`angebotLaden`): die Seite wartet
     * nicht auf sie. Aendert sich damit, was „Alle" liest oder was gewaehlt sein darf, wird neu
     * geladen — `onChange(of: angebotskennung)` auf iOS.
     */
    private suspend fun nachsehen(kern: Kern) {
        try { withContext(Dispatchers.IO) { kern.angebotLaden().await() } }
        catch (e: CancellationException) { throw e } catch (_: Exception) { return }
        try {
            val a = JSONArray(withContext(Dispatchers.IO) { kern.sammlungen(art).await() })
            sammlungsliste = (0 until a.length()).map { sammlungskachelLesen(a.getJSONObject(it)) }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
        val vorher = kennung
        val alteWahl = wahl
        if (!angebotLesen(kern)) return
        if (kennung != vorher || wahl != alteWahl) seiteLaden(kern)
    }

    private suspend fun seiteLaden(kern: Kern) {
        // Die Liste steht schon im Speicher: „Sammlungen" gibt es im Menue nur, wenn es welche gibt.
        if (sammlungenGewaehlt) { laedt = false; return }
        laedt = items.isEmpty()
        try {
            val (neu, zahl) = seite(kern, 0)
            // **Beim Zurueckkommen nicht auf die erste Seite kuerzen** — `Listenregeln.auffrischen`.
            // `laden` laeuft bei jedem Wiedererscheinen der Seite; ersetzte die erste Seite alles,
            // war der geoeffnete Titel hinter Nummer 60 weg, der Fokus fiel auf Kachel 0, und ein
            // gleichzeitig laufendes Nachladen haengte an der alten Stelle an (Luecke).
            val fuer = "$wahl|$kennung|$sortierung|$filter"
            items = if (geladenFuer == fuer && zahl == gesamt && items.size > neu.size) {
                val bekannt = neu.mapTo(HashSet()) { it.id }
                neu + items.drop(neu.size).filter { bekannt.add(it.id) }
            } else neu.distinctBy { it.id }
            geladenFuer = fuer
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
        if (!nochMehrDa || laedtNach || laedt) return
        laedtNach = true
        try {
            val vorher = geladenFuer
            val (neu, zahl) = seite(kern, items.size)
            // Inzwischen umsortiert, gefiltert oder umgewaehlt: die Seite gehoert zu einer anderen Liste.
            if (geladenFuer != vorher) return
            // Der Server kann zwischen zwei Seiten etwas hinzufuegen — nichts doppelt.
            val bekannt = items.mapTo(HashSet()) { it.id }
            items = items + neu.filter { bekannt.add(it.id) }
            gesamt = zahl
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
        } finally { laedtNach = false }
    }

    private suspend fun seite(kern: Kern, ab: Int): Pair<List<Rasterkachel>, Int> {
        val o = JSONObject(withContext(Dispatchers.IO) {
            kern.bereichSeite(art, wahl, sortierung, filter, ab.toLong(), SEITE).await()
        })
        siebMehr = if (o.optBoolean("gesiebt")) o.optBoolean("nochMehr") else null
        val a = o.getJSONArray("titel")
        return (0 until a.length()).map { i ->
            rasterkachelLesen(a.getJSONObject(i))
        } to o.getInt("gesamt")
    }
}

/** Vorlage: `BibliothekView` in `Sources/Shared/HauptView.swift` (schmale Fassung). */
@Composable
fun BibliothekSeite(app: SwiftlyAnwendung, art: String, titel: String, filterwahl: List<String>, oeffnen: (Ziel) -> Unit) {
    val stand = remember(art) { app.bibliotheken.getOrPut(art) { Bibliotheksstand(art, app.ablage) } }
    val bereich = rememberCoroutineScope()
    LaunchedEffect(stand.sortierung, stand.filter) { stand.laden(app.kern) }
    val raster = rememberLazyGridState()
    val dichte = LocalDensity.current
    // Daran haengt die Haarlinie unter dem Kopf.
    val versatz by remember {
        derivedStateOf { if (raster.firstVisibleItemIndex > 0) 100f else raster.firstVisibleItemScrollOffset / dichte.density }
    }

    KopfUndInhalt(kopf = { BibliothekKopf(app, stand, titel, filterwahl, oeffnen) { versatz } }) { kopfDp ->
    BoxWithConstraints(Modifier.fillMaxSize().background(Stil.grund)) {
        // `Stil.spalten(nutzbar:)` — auf jedem Telefon drei.
        val anzahl = Stil.spalten((maxWidth - Stil.randAbstand * 2).value)
        // Nachladen, sobald die drittletzte Reihe auftaucht — `Listenregeln.imNachladebereich`.
        LaunchedEffect(raster, anzahl) {
            snapshotFlow { (raster.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1) to stand.items.size }
                .collect { (letzter, geladen) ->
                    if (geladen > 0 && letzter >= geladen - anzahl * 3) stand.nachladen(app.kern)
                }
        }
        val sammlungen = stand.sammlungenGewaehlt

        LazyVerticalGrid(
            columns = GridCells.Fixed(anzahl), state = raster,
            contentPadding = PaddingValues(start = Stil.randAbstand, end = Stil.randAbstand, top = kopfDp + 8.dp, bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(Stil.kachelAbstand),
            verticalArrangement = Arrangement.spacedBy(20.dp),
            modifier = Modifier.fillMaxSize().bereichsinhalt()
        ) {
            if (sammlungen) {
                // **Sammlungen im selben Raster, mit derselben Kachel.** Unter dem Namen steht statt
                // des Jahres, wie viele Filme bzw. Serien darin sind.
                items(stand.sammlungsliste, key = { "sammlung" + it.id }) { s ->
                    SammlungKachelAnsicht(app, s, art) { oeffnen(sammlungsziel(s.id, s.name, art)) }
                }
            } else {
                // Platzhalter statt Ring: das Raster steht schon in seiner Form.
                if (stand.items.isEmpty() && stand.laedt) items(anzahl * 3, key = { "platzhalter$it" }) {
                    Box(Modifier.animateItem(fadeInSpec = null, placementSpec = null, fadeOutSpec = Bewegung.einblenden())) { Kachelplatzhalter() }
                }
                items(stand.items, key = { it.id }) { RasterKachelAnsicht(it) { oeffnen(Ziel(it.id, it.titel, it.typ)) } }
                // Kein Ring beim Nachladen — eine Reihe Platzhalter.
                if (stand.items.isNotEmpty() && stand.nochMehrDa) items(anzahl, key = { "nachschub$it" }) { Kachelplatzhalter() }
            }
        }

        if (sammlungen) {
            // Die Liste steht schon im Speicher: „Sammlungen" gibt es im Menue nur, wenn es welche gibt.
        } else if (stand.gestoert) {
            // **Die Serverformel, woertlich wie auf jeder anderen Plattform** (BAUTEILE 6):
            // derselbe Wortlaut, derselbe Aufbau, dieselbe Adresse. Hier stand eine zweite
            // Fassung („Kein Kontakt zum Server" / „…bist du im selben Netz?") — zwei
            // Antworten auf dieselbe Frage.
            //
            // Das Zeichen ist `CloudOff` und nicht Apples `externaldrive.badge.xmark`:
            // Android hat kein Symbol fuer ein externes Laufwerk, und ein selbst gezeichnetes
            // waere ein eigener Vektor fuer eine Nebensache. Dieselbe Aussage, das Zeichen der
            // Plattform.
            Leerzustand(Zeichen.ServerWeg, uebersetzt("Server ist abgetaucht"),
                uebersetzt("%@ antwortet nicht. Läuft er noch, oder hängt das WLAN?", app.serveradresse()),
                hauptknopf = uebersetzt("Erneut versuchen") to { bereich.launch { stand.laden(app.kern) } })
        } else if (stand.items.isEmpty() && !stand.laedt) {
            val alle = stand.filter == "alle"
            Leerzustand(if (alle) Zeichen.Ablage else Zeichen.Filter,
                uebersetzt(if (alle) "Hier ist noch nichts" else "Nichts gefunden"),
                if (alle) uebersetzt("Sobald in dieser Bibliothek etwas liegt, taucht es hier auf.")
                else uebersetzt("Unter „%@“ liegt gerade nichts. Nimm einen anderen Filter.", Wahlen.text(Wahlen.filter, stand.filter)),
                stillerKnopf = if (alle) uebersetzt("Aktualisieren") to { bereich.launch { stand.laden(app.kern) } }
                               else uebersetzt("Filter zurücksetzen") to { stand.filterSetzen("alle") })
        }

    }
    }
}

/** Kopf der Bibliothek: Titel oder Titelmenue, Kopfziele, Pillen, Anzahl. */
@Composable
private fun BibliothekKopf(app: SwiftlyAnwendung, stand: Bibliotheksstand, titel: String,
                           filterwahl: List<String>, oeffnen: (Ziel) -> Unit, versatz: () -> Float) {
    val bereich = rememberCoroutineScope()
    Wurzelkopf(versatz) {
        // **Mittig, nicht oben**: ohne Servernamen darunter ist der Titel eine Zeile, und die Zeichen
        // rechts sollen auf seiner Linie stehen.
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) {
                val gross = Stil.titelGross
                // **Ein Menue erst, wenn es darin mehr als eine Sache zu waehlen gibt**
                // (`Bereichsangebot.istMenue`): wer eine Film- und eine Serienbibliothek ohne
                // Sammlungen hat, sieht genau das Gleiche wie vorher. Kein Servername unter dem Titel.
                if (stand.istMenue) {
                    Row(Modifier.antippen {
                            // Dasselbe Blatt wie bei der Sortierung, mit dem Seitentitel als Kopf; die
                            // Rubrik „Bibliotheken" trennt die Bibliotheken von „Alle" und „Sammlungen".
                            app.blatt.value = Blattwunsch(titel, stand.angebot.map { Wahl(it.wert, stand.beschriftung(it.wert)) },
                                                          stand.wahl, rubriken = stand.rubriken) { neu ->
                                if (neu != stand.wahl) {
                                    stand.waehlen(neu)
                                    bereich.launch { stand.laden(app.kern) }
                                }
                            }
                        },
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        // **„Alle" heisst einfach „Filme".** Der Titel sagt, wo man ist; „Alle Filme"
                        // steht nur im Menue.
                        Text(if (stand.wahl == "alle") titel else stand.beschriftung(stand.wahl), style = gross, color = Stil.schrift,
                             maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                        Symbol(Zeichen.WinkelRunter, 15.dp, farbe = Stil.schriftLeise, staerke = Staerke.Halbfett)
                    }
                } else {
                    Text(titel, style = gross, color = Stil.schrift)
                }
            }
            Kopfziele(app, oeffnen)
        }
        Wertreihe(versatz) {
            if (stand.sammlungenGewaehlt) {
                // **Bei „Sammlungen" nur die Anzahl** (`Regalsteuerung.nurAnzahl`) — die Liste muss man
                // weder filtern noch umsortieren. Die Reihe behaelt die Hoehe einer Pille, sonst
                // springt sie beim Wechsel nach oben.
                Box(Modifier.heightIn(min = Stil.pillenHoehe))
                Spacer(Modifier.weight(1f))
                Zaehlmarke(stand.gezeigt)
            } else {
                Wertpille(Zeichen.Filter, Wahlen.text(Wahlen.filter, stand.filter)) {
                    app.blatt.value = Blattwunsch(uebersetzt("Filtern"), Wahlen.filter.filter { it.wert in filterwahl }, stand.filter) {
                        stand.filterSetzen(it)
                    }
                }
                Wertpille(Zeichen.Sortieren, Wahlen.text(Wahlen.sortierungen, stand.sortierung)) {
                    app.blatt.value = Blattwunsch(uebersetzt("Sortieren"), Wahlen.sortierungen, stand.sortierung) {
                        stand.sortierungSetzen(it)
                    }
                }
                Spacer(Modifier.weight(1f))
                // Erst wenn wir sie kennen — eine Null, die noch keine ist, waere falsch.
                if (stand.gesamt > 0) Zaehlmarke(stand.gesamt)
            }
        }
    }
}

/** Vorlage: `PosterTile` in `BrowseViews.swift` — fuellt die Spalte, 2:3, Titel zweizeilig. */
@Composable
fun RasterKachelAnsicht(k: Rasterkachel, modifier: Modifier = Modifier, tun: () -> Unit) {
    Column(modifier.einblenden().antippen(tun), verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(Stil.eckeKachel)).background(Stil.flaeche)) {
            // Kein `SubcomposeAsyncImage` im Raster — siehe `KachelAnsicht` auf der Startseite.
            var fehlt by remember(k.plakat) { mutableStateOf(k.plakat == null) }
            if (fehlt) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Symbol(Zeichen.Film, 22.dp, farbe = Stil.schriftSehrLeise)
            }
            coil3.compose.AsyncImage(model = k.plakat, contentDescription = k.titel, contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(), onError = { fehlt = true })
            k.fortschritt?.takeIf { it > 0 && LocalFortschrittZeigen.current }?.let { Fortschrittsbalken(it, Modifier.align(Alignment.BottomStart)) }
            k.marke?.let { Kachelplakette(it, k.markenzahl, Modifier.align(Alignment.TopEnd)) }
        }
        // **Eine Bauart, ueberall dieselbe** (BAUTEILE 6): Titel 13 Medium **einzeilig**, darunter
        // 1 Abstand, Angabe 12 `schriftSehrLeise`. Zweizeilig stand er nur hier, und eine Kachel,
        // die mit ihrem Titel waechst, macht aus einer Rasterzeile zwei verschieden hohe.
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(k.titel, style = Stil.kachel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis)
            k.unterzeile?.let { Text(it, style = Stil.klein, color = Stil.schriftSehrLeise, maxLines = 1) }
        }
    }
}
