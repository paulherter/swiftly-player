package de.paulherter.swiftly.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.*
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

private enum class Abteil(val titel: String, val symbol: ImageVector) {
    Wiedergabe("Wiedergabe", Icons.Filled.PlayArrow), Sprachen("Sprachen", Icons.Filled.Translate),
    Darstellung("Darstellung", Icons.Filled.GridView), Integration("Integration", Icons.Filled.ManageSearch),
    Server("Server", Icons.Filled.Dns), Konto("Konto", Icons.Filled.Person),
}

@Composable
private fun Gruppenkopf(text: String) {
    Text(text.uppercase(), style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.2.sp),
         color = Stil.schriftSehrLeise, modifier = Modifier.padding(start = 16.dp, top = 18.dp, bottom = 6.dp))
}

/**
 * Vorlage: `ProfilView` auf tvOS — **zwei Spalten wie Apples eigene Einstellungen**: links die
 * Abteile, rechts ihre Zeilen, gedimmt, bis man hinuebergeht. Erst schauen, dann springen; und weil
 * Breite da ist, spart jeder Sprung, der wegfaellt. Umsortiert wird mit Pfeilen — mit der
 * Fernbedienung gibt es nichts zu greifen. Keine Offline-Gruppe, kein Querformat, kein Quick-Connect-
 * Freigeben: nichts davon hat auf dem Fernseher einen Sinn.
 */
@Composable
fun TvProfil(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit) {
    val e = app.einstellungen
    var abteil by rememberSaveable { mutableStateOf(Abteil.Wiedergabe) }
    var linksImFokus by remember { mutableStateOf(true) }
    val links = ersterFokus()
    val rechts = remember { FocusRequester() }
    val lauf = rememberCoroutineScope()
    BackHandler(enabled = !linksImFokus) { runCatching { links.requestFocus() } }

    val bitraten = remember { wahlenLesen(Kern.bitratenstufen()) }
    val puffer = remember { JSONArray(Kern.pufferstufen()).let { a -> (0 until a.length()).map { a.getJSONObject(it).let { o -> Wahl(o.getString("wert"), o.getString("text")) } } } }
    val sekunden = remember { JSONArray(Kern.spannen()).let { a -> (0 until a.length()).map { a.getInt(it) } } }
    val tonwahl = remember { wahlenLesen(Kern.sprachen("")) }
    val untertitelwahl = remember { wahlenLesen(Kern.sprachen(uebersetzt("Aus"))) }
    fun blatt(titel: String, eintraege: List<Wahl>, gewaehlt: String, waehlen: (String) -> Unit) {
        app.blatt.value = Blattwunsch(titel, eintraege, gewaehlt, waehlen = waehlen)
    }
    fun sekundenwahl() = sekunden.map { Wahl(it.toString(), uebersetzt("%lld s", it)) }
    val anAus: (Boolean) -> String = { uebersetzt(if (it) "An" else "Aus") }

    var server by remember { mutableStateOf<Pair<String, String>?>(null) }
    LaunchedEffect(Unit) {
        try {
            val o = JSONObject(withContext(Dispatchers.IO) { app.kern.serverauskunft().await() })
            server = o.optString("name") to o.optString("version")
        } catch (x: CancellationException) { throw x } catch (_: Exception) {}
    }
    var pruefung by remember { mutableStateOf<String?>(null) }
    val karten = remember(app.kontowechsel.intValue) {
        app.ablage.konten?.let { b -> runCatching { JSONArray(Kern.bundUebersicht(b)).let { a -> (0 until a.length()).map { a.getJSONObject(it) } } }.getOrNull() }.orEmpty()
    }
    val host = karten.firstOrNull { it.optBoolean("aktiv") }?.optString("host").orEmpty()

    Column(Modifier.fillMaxSize().background(Stil.grund).padding(horizontal = TvStil.randSeite).padding(top = 40.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            SubcomposeAsyncImage(model = app.kern.benutzerbild(200).orElse(null), contentDescription = null, contentScale = ContentScale.Crop,
                modifier = Modifier.size(56.dp).clip(CircleShape).background(Stil.erhoeht),
                error = { Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Person, contentDescription = null, tint = Stil.schriftLeise, modifier = Modifier.size(26.dp))
                } })
            Column {
                Text(app.benutzername(), style = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.Bold), color = Stil.schrift)
                Text(listOfNotNull(server?.first?.ifEmpty { null } ?: app.servername.value, server?.second?.let { "Jellyfin $it" }).joinToString(" · "),
                     style = TvStil.klein, color = Stil.schriftLeise)
            }
        }

        Row(Modifier.padding(top = 24.dp).fillMaxWidth().weight(1f)) {
            Column(Modifier.width(230.dp).focusGroup()) {
                Abteil.entries.forEachIndexed { i, a ->
                    Fokusflaeche(if (i == 0) Modifier.fillMaxWidth().focusRequester(links) else Modifier.fillMaxWidth(), lupe = 1f,
                                 fokusGeaendert = { if (it) { abteil = a; linksImFokus = true } },
                                 tun = { runCatching { rechts.requestFocus() } }) { fokus ->
                        Row(Modifier.fillMaxWidth().height(TvStil.zeilenHoehe).clip(RoundedCornerShape(TvStil.ecke))
                                .background(when { fokus -> TvStil.fokusflaeche; a == abteil -> Color.White.copy(alpha = 0.05f); else -> Color.Transparent })
                                .padding(horizontal = 16.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Icon(a.symbol, contentDescription = null, tint = if (a == abteil) Stil.schrift else Stil.schriftLeise, modifier = Modifier.size(18.dp))
                            Text(uebersetzt(a.titel), style = TextStyle(fontSize = 15.5.sp, fontWeight = if (a == abteil) FontWeight.SemiBold else FontWeight.Normal),
                                 color = if (a == abteil) Stil.schrift else Stil.schriftLeise)
                        }
                    }
                }
            }
            Spacer(Modifier.width(36.dp))
            Column(Modifier.weight(1f).alpha(if (linksImFokus) 0.5f else 1f)
                    .onFocusChanged { if (it.hasFocus) linksImFokus = false }
                    .verticalScroll(rememberScrollState()).focusGroup()) {
                val erste = Modifier.focusRequester(rechts)
                when (abteil) {
                    Abteil.Wiedergabe -> {
                        TvZeile(uebersetzt("Immer Direct Play"), Icons.Filled.PlayArrow, anAus(e.immerDirectPlay), modifier = erste) {
                            e.immerDirectPlay = !e.immerDirectPlay; app.qualitaetMelden()
                        }
                        // Gedimmt, solange Direct Play erzwungen ist — dort griffe sie nicht.
                        TvZeile(uebersetzt("Höchste Bitrate"), Icons.Filled.BarChart, bitraten.firstOrNull { it.wert == e.bitratenGrenze.toString() }?.text,
                                modifier = Modifier.alpha(if (e.immerDirectPlay) 0.4f else 1f)) {
                            if (!e.immerDirectPlay) blatt(uebersetzt("Höchste Bitrate"), bitraten, e.bitratenGrenze.toString()) { e.bitratenGrenze = it.toInt(); app.qualitaetMelden() }
                        }
                        TvZeile(uebersetzt("Puffer"), Icons.Filled.Wifi, puffer.firstOrNull { it.wert == e.pufferstufe }?.text) {
                            blatt(uebersetzt("Puffer"), puffer, e.pufferstufe) { e.pufferstufe = it }
                        }
                        TvZeile(uebersetzt("Untertitel automatisch"), Icons.Filled.Subtitles, anAus(e.untertitelAutomatisch)) { e.untertitelAutomatisch = !e.untertitelAutomatisch }
                        TvZeile(uebersetzt("Nächste Folge automatisch"), Icons.Filled.SkipNext, anAus(e.naechsteAutomatisch)) { e.naechsteAutomatisch = !e.naechsteAutomatisch }
                        TvZeile(uebersetzt("Zurückspulen"), Icons.Filled.Replay, uebersetzt("%lld s", e.zurueckSekunden)) {
                            blatt(uebersetzt("Zurückspulen"), sekundenwahl(), e.zurueckSekunden.toString()) { e.zurueckSekunden = it.toInt() }
                        }
                        TvZeile(uebersetzt("Vorspulen"), Icons.Filled.FastForward, uebersetzt("%lld s", e.vorSekunden)) {
                            blatt(uebersetzt("Vorspulen"), sekundenwahl(), e.vorSekunden.toString()) { e.vorSekunden = it.toInt() }
                        }
                    }
                    Abteil.Sprachen -> {
                        TvZeile(uebersetzt("Ton"), Icons.Filled.VolumeUp, tonwahl.firstOrNull { it.wert == e.tonSprache }?.text, modifier = erste) {
                            blatt(uebersetzt("Ton"), tonwahl, e.tonSprache) { e.tonSprache = it }
                        }
                        TvZeile(uebersetzt("Untertitel"), Icons.Filled.ClosedCaption, untertitelwahl.firstOrNull { it.wert == e.untertitelSprache }?.text) {
                            blatt(uebersetzt("Untertitel"), untertitelwahl, e.untertitelSprache) { e.untertitelSprache = it }
                        }
                    }
                    Abteil.Darstellung -> {
                        TvZeile(uebersetzt("Fortschritt auf Kacheln"), Icons.Filled.BarChart, anAus(e.fortschritt), modifier = erste) { e.fortschritt = !e.fortschritt }
                        Gruppenkopf(uebersetzt("Startseite"))
                        val reihen = remember(e.startReihen, e.neuzugangGetrennt) { wahlenLesen(Kern.startreihen(e.startReihen.toTypedArray(), e.neuzugangGetrennt)) }
                        fun verschieben(r: Wahl, schritt: Int) {
                            e.startReihen = JSONArray(Kern.startreiheVerschoben(r.wert, schritt.toLong(), e.startReihen.toTypedArray(), e.neuzugangGetrennt))
                                .let { a -> (0 until a.length()).map { a.getString(it) } }
                        }
                        reihen.forEach { r ->
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                TvZeile(uebersetzt(r.text), Icons.Filled.ViewAgenda, anAus(r.wert !in e.startAus), modifier = Modifier.weight(1f)) {
                                    e.startAus = if (r.wert in e.startAus) e.startAus - r.wert else e.startAus + r.wert
                                }
                                TvKnopf(null, Icons.Filled.KeyboardArrowUp, hoehe = 34.dp) { verschieben(r, -1) }
                                TvKnopf(null, Icons.Filled.KeyboardArrowDown, hoehe = 34.dp) { verschieben(r, 1) }
                            }
                        }
                        TvZeile(uebersetzt("Neuzugänge getrennt"), Icons.Filled.VerticalSplit, anAus(e.neuzugangGetrennt)) { e.neuzugangGetrennt = !e.neuzugangGetrennt }
                        Gruppenkopf(uebersetzt("Genres"))
                        TvZeile(uebersetzt("Als eigene Reihen"), haken = !e.genreChips) { e.genreChips = false }
                        TvZeile(uebersetzt("Als Chips über den Reihen"), haken = e.genreChips) { e.genreChips = true }
                        e.startGenres.forEach { g -> TvZeile(g, Icons.Filled.Label, uebersetzt("Löschen")) { e.startGenres = e.startGenres - g } }
                        TvZeile(uebersetzt("Genre hinzufügen"), Icons.Filled.Add) { oeffnen(Ziel("genrewahl", uebersetzt("Genre hinzufügen"), "Genrewahl")) }
                    }
                    Abteil.Integration -> {
                        TvZeile("Seerr", Icons.Filled.ManageSearch, uebersetzt(if (app.seerrVerbunden.value) "Verbunden" else "Nicht verbunden"), modifier = erste) {
                            oeffnen(Ziel("seerr", "Seerr", "Seerr"))
                        }
                    }
                    Abteil.Server -> {
                        TvZeile(uebersetzt("Adresse"), Icons.Filled.Link, host, modifier = erste) {}
                        TvZeile(uebersetzt("Fassung"), Icons.Filled.Info, server?.second?.let { "Jellyfin $it" }) {}
                        // Ein Fehlerbericht haengt daran, welche Fassung laeuft.
                        TvZeile("Swiftly", Icons.Filled.Tv, SwiftlyAnwendung.FASSUNGSZEILE.removePrefix("Swiftly Player ")) {}
                        TvZeile(uebersetzt("Server hinzufügen"), Icons.Filled.Dns) { oeffnen(Ziel("serveraufnahme", uebersetzt("Server hinzufügen"), "ServerAufnahme")) }
                        TvZeile(uebersetzt("Verbindung prüfen"), Icons.Filled.NetworkCheck, pruefung) {
                            pruefung = uebersetzt("Moment…")
                            lauf.launch {
                                pruefung = try {
                                    val o = JSONObject(withContext(Dispatchers.IO) { app.kern.serverauskunft().await() })
                                    uebersetzt("Erreichbar — Jellyfin %@", o.optString("version"))
                                } catch (x: CancellationException) { throw x } catch (x: Exception) { x.message ?: x.toString() }
                            }
                        }
                    }
                    Abteil.Konto -> {
                        var zuerst = true
                        karten.forEach { k ->
                            val konten = k.optJSONArray("konten") ?: JSONArray()
                            (0 until konten.length()).map { konten.getJSONObject(it) }.forEach { konto ->
                                val aktiv = konto.optBoolean("aktiv") && k.optBoolean("aktiv")
                                TvZeile(konto.optString("name"), Icons.Filled.Person, k.optString("host"), haken = aktiv,
                                        modifier = if (zuerst) erste else Modifier) {
                                    if (!aktiv) app.kontoWechseln(konto.getString("kennung"))
                                }
                                zuerst = false
                            }
                        }
                        TvZeile(uebersetzt("Abmelden"), Icons.AutoMirrored.Filled.Logout, modifier = if (zuerst) erste else Modifier) { app.abmelden() }
                    }
                }
            }
        }
    }
}
