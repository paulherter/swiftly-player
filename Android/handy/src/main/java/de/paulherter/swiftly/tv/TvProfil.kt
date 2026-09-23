package de.paulherter.swiftly.tv

import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import androidx.activity.compose.BackHandler
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
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

/** Vorlage: `Bereichswahl` (tvOS) — nur der Name, kein Symbol. Die Ueberschriften rechts
 *  ("PLAYBACK" &c.) sind derselbe Wortlaut, nicht eine zweite Beschriftung. */
private enum class Abteil(val titel: String) {
    Wiedergabe("Wiedergabe"), Sprachen("Sprachen"), Darstellung("Darstellung"),
    Integration("Integration"), Server("Server"), Konto("Konto"), Swiftly("Swiftly"),
}

@Composable
private fun Gruppenkopf(text: String) {
    Text(text, style = TvStil.reihe,
         color = Stil.schriftSehrLeise, modifier = Modifier.padding(start = 13.dp, top = 18.dp, bottom = 6.dp))
}

/**
 * Vorlage: `ProfilView` auf tvOS — **zwei Spalten wie Apples eigene Einstellungen**: links die
 * Abteile, rechts ihre Zeilen, gedimmt, bis man hinuebergeht. Erst schauen, dann springen; und weil
 * Breite da ist, spart jeder Sprung, der wegfaellt. Umsortiert wird mit Pfeilen — mit der
 * Fernbedienung gibt es nichts zu greifen. Keine Offline-Gruppe, kein Querformat, kein Quick-Connect-
 * Freigeben: nichts davon hat auf dem Fernseher einen Sinn.
 *
 * **Aufbau am 15.09.2026 auf tvOS gezogen** — vorher stand hier ein Kopf ueber der ganzen Seite,
 * die Abteile trugen Symbole und die Zeilen "An"/"Aus" als Text. Jetzt: die Kontokarte links oben
 * (Bild, Name, Server, Trennlinie, Kontenstreifen mit gestricheltem Plus), darunter die
 * Abteile nur als Text — gewaehlt in Akzentflaeche und Akzentschrift, wie `BereichsStil`. Rechts
 * eine gruppierte Karte mit Haarlinien statt einer flachen Liste, Zeilen ohne Symbole, gezeichnete
 * Schalter statt Text und ein Pfeil an jeder Auswahlzeile.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun TvProfil(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit) {
    val e = app.einstellungen
    var abteil by rememberSaveable { mutableStateOf(Abteil.Wiedergabe) }
    var linksImFokus by remember { mutableStateOf(true) }
    val links = ersterFokus()
    val rechts = remember { FocusRequester() }
    val lauf = rememberCoroutineScope()
    val kontext = androidx.compose.ui.platform.LocalContext.current
    BackHandler(enabled = !linksImFokus) { runCatching { links.requestFocus() } }

    var bildrateAnpassen by remember { mutableStateOf(app.ablage.merkwert("bildrateAnpassen") != "0") }
    val bitraten = remember { wahlenLesen(Kern.bitratenstufen()) }
    val puffer = remember { JSONArray(Kern.pufferstufen()).let { a -> (0 until a.length()).map { a.getJSONObject(it).let { o -> Wahl(o.getString("wert"), o.getString("text")) } } } }
    val sekunden = remember { JSONArray(Kern.spannen()).let { a -> (0 until a.length()).map { a.getInt(it) } } }
    val tonwahl = remember { wahlenLesen(Kern.sprachen("")) }
    val untertitelwahl = remember { wahlenLesen(Kern.sprachen(uebersetzt("Aus"))) }
    fun blatt(titel: String, eintraege: List<Wahl>, gewaehlt: String, waehlen: (String) -> Unit) {
        app.blatt.value = Blattwunsch(titel, eintraege, gewaehlt, waehlen = waehlen)
    }
    fun sekundenwahl() = sekunden.map { Wahl(it.toString(), uebersetzt("%lld s", it)) }

    var server by remember { mutableStateOf<Pair<String, String>?>(null) }
    LaunchedEffect(Unit) {
        try {
            val o = JSONObject(withContext(Dispatchers.IO) { app.kern.serverauskunft().await() })
            server = o.optString("name") to o.optString("version")
        } catch (x: CancellationException) { throw x } catch (_: Exception) {}
    }
    // Fuer „Genre hinzufuegen" unten — dieselbe Liste wie `GenrewahlSeite` auf dem Telefon.
    var alleGattungen by remember { mutableStateOf<List<String>>(emptyList()) }
    LaunchedEffect(Unit) {
        alleGattungen = try {
            JSONArray(withContext(Dispatchers.IO) { app.kern.gattungen().await() }).let { a -> (0 until a.length()).map { a.getString(it) } }
        } catch (x: CancellationException) { throw x } catch (_: Exception) { emptyList() }
    }
    var pruefung by remember { mutableStateOf<String?>(null) }
    val karten = remember(app.kontowechsel.intValue) {
        app.ablage.konten?.let { b -> runCatching { JSONArray(Kern.bundUebersicht(b)).let { a -> (0 until a.length()).map { a.getJSONObject(it) } } }.getOrNull() }.orEmpty()
    }
    val host = karten.firstOrNull { it.optBoolean("aktiv") }?.optString("host").orEmpty()
    val serverzeile = listOfNotNull(server?.first?.ifEmpty { null } ?: app.servername.value,
                                     server?.second?.let { "Jellyfin $it" }).joinToString(" · ")

    Column(Modifier.fillMaxSize().background(Stil.grund)
            .padding(horizontal = TvStil.randSeite, vertical = TvStil.randOben)) {
        Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(36.dp)) {
            // **Nach links zurueck heisst: auf den gewaehlten Bereich** (tvOS: `.focusSection()` mit
            // `.defaultFocus($links, bereich)`, Zurueck setzt `links = bereich`). Vorher fand die
            // geometrische Suche aus dem rechten Teil den Kontenstreifen oben, und Zurueck sprang
            // immer auf die erste Zeile — `links` haengt deshalb an der gewaehlten Zeile.
            //
            // **Scrollbar**, wie die rechte Spalte: Kontokarte und sieben Bereiche sind hoeher als
            // ein 1080er-Bild. Ohne Scrollen bekam „Swiftly" die Hoehe 0 — der Fokus landete auf
            // einer unsichtbaren Zeile unter dem Bildrand.
            Column(Modifier.width(230.dp).focusProperties { enter = { links } }
                    .verticalScroll(rememberScrollState()).focusGroup()) {
                Kontokarte(app, serverzeile, karten,
                           aufnehmen = { oeffnen(Ziel("weiteresKonto", uebersetzt("Konto hinzufügen"), "WeiteresKonto")) },
                           wechseln = { k -> app.kontoWechseln(k) })
                Spacer(Modifier.height(20.dp))
                Gruppenkopf(uebersetzt("Bereiche"))
                Abteil.entries.forEach { a ->
                    BereichZeile(uebersetzt(a.titel), ausgewaehlt = a == abteil,
                                 modifier = if (a == abteil) Modifier.focusRequester(links) else Modifier,
                                 fokusGeaendert = { if (it) { abteil = a; linksImFokus = true } },
                                 tun = { runCatching { rechts.requestFocus() } })
                }
            }
            Column(Modifier.weight(1f).alpha(if (linksImFokus) 0.5f else 1f)
                    .onFocusChanged { if (it.hasFocus) linksImFokus = false }
                    .verticalScroll(rememberScrollState()).focusGroup()) {
                val erste = Modifier.focusRequester(rechts)
                Gruppenkopf(uebersetzt(abteil.titel))
                Column(Modifier.padding(5.dp).clip(RoundedCornerShape(TvStil.eckeKachel)).background(Stil.flaeche)) {
                    when (abteil) {
                        Abteil.Wiedergabe -> {
                            // Wandelt der Server nicht um, ist nichts zu wählen: Direct Play steht
                            // fest an, die Bitrate ist gesperrt — wie auf den anderen Fassungen.
                            val frei = e.umwandelnErlaubt
                            val directPlay = e.immerDirectPlay || !frei
                            TvSchalterzeile(uebersetzt("Immer Direct Play"), directPlay, modifier = erste) {
                                if (frei) { e.immerDirectPlay = !e.immerDirectPlay; app.qualitaetMelden() }
                            }
                            Trennlinie()
                            // Gedimmt, solange Direct Play erzwungen ist — dort griffe sie nicht.
                            TvHandlung(uebersetzt("Höchste Bitrate"), wert = bitraten.firstOrNull { it.wert == e.bitratenGrenze.toString() }?.text,
                                       modifier = Modifier.alpha(if (directPlay) 0.4f else 1f)) {
                                if (!directPlay) blatt(uebersetzt("Höchste Bitrate"), bitraten, e.bitratenGrenze.toString()) { e.bitratenGrenze = it.toInt(); app.qualitaetMelden() }
                            }
                            Trennlinie()
                            TvHandlung(uebersetzt("Puffer"), wert = puffer.firstOrNull { it.wert == e.pufferstufe }?.text) {
                                blatt(uebersetzt("Puffer"), puffer, e.pufferstufe) { e.pufferstufe = it }
                            }
                            Trennlinie()
                            TvSchalterzeile(uebersetzt("Untertitel automatisch"), e.untertitelAutomatisch) { e.untertitelAutomatisch = !e.untertitelAutomatisch }
                            Trennlinie()
                            // Derselbe Ablageschluessel wie im Player (`TvPlayer`/`TvBildtakt`, Vorgabe an) —
                            // kein eigener in `Einstellungen`, weil es die Bildrateanpassung nur auf tvOS/Android-TV
                            // gibt (`ProfilView.swift` haelt sie ebenfalls per `@AppStorage`, nicht in `AppModel`).
                            TvSchalterzeile(uebersetzt("Bildrate an den Film anpassen"), bildrateAnpassen) {
                                bildrateAnpassen = !bildrateAnpassen
                                app.ablage.merken("bildrateAnpassen", if (bildrateAnpassen) "1" else "0")
                            }
                            Trennlinie()
                            TvSchalterzeile(uebersetzt("Nächste Folge automatisch"), e.naechsteAutomatisch) { e.naechsteAutomatisch = !e.naechsteAutomatisch }
                            Trennlinie()
                            TvHandlung(uebersetzt("Zurückspulen"), wert = uebersetzt("%lld s", e.zurueckSekunden)) {
                                blatt(uebersetzt("Zurückspulen"), sekundenwahl(), e.zurueckSekunden.toString()) { e.zurueckSekunden = it.toInt() }
                            }
                            Trennlinie()
                            TvHandlung(uebersetzt("Vorspulen"), wert = uebersetzt("%lld s", e.vorSekunden)) {
                                blatt(uebersetzt("Vorspulen"), sekundenwahl(), e.vorSekunden.toString()) { e.vorSekunden = it.toInt() }
                            }
                        }
                        Abteil.Sprachen -> {
                            TvHandlung(uebersetzt("Ton"), wert = tonwahl.firstOrNull { it.wert == e.tonSprache }?.text, modifier = erste) {
                                blatt(uebersetzt("Ton"), tonwahl, e.tonSprache) { e.tonSprache = it }
                            }
                            Trennlinie()
                            TvHandlung(uebersetzt("Untertitel"), wert = untertitelwahl.firstOrNull { it.wert == e.untertitelSprache }?.text) {
                                blatt(uebersetzt("Untertitel"), untertitelwahl, e.untertitelSprache) { e.untertitelSprache = it }
                            }
                        }
                        Abteil.Darstellung -> {
                            TvSchalterzeile(uebersetzt("Fortschritt auf Kacheln"), e.fortschritt, modifier = erste) { e.fortschritt = !e.fortschritt }
                            Trennlinie()
                            Gruppenkopf(uebersetzt("Startseite"))
                            val reihen = remember(e.startReihen, e.neuzugangGetrennt) { wahlenLesen(Kern.startreihen(e.startReihen.toTypedArray(), e.neuzugangGetrennt)) }
                            fun verschieben(r: Wahl, schritt: Int) {
                                e.startReihen = JSONArray(Kern.startreiheVerschoben(r.wert, schritt.toLong(), e.startReihen.toTypedArray(), e.neuzugangGetrennt))
                                    .let { a -> (0 until a.length()).map { a.getString(it) } }
                            }
                            reihen.forEachIndexed { idx, r ->
                                TvReihenzeile(uebersetzt(r.text), an = r.wert !in e.startAus,
                                              kannHoch = idx != 0, kannRunter = idx != reihen.lastIndex,
                                              umschalten = { e.startAus = if (r.wert in e.startAus) e.startAus - r.wert else e.startAus + r.wert },
                                              schieben = { schritt -> verschieben(r, schritt) })
                                Trennlinie()
                            }
                            TvSchalterzeile(uebersetzt("Neuzugänge getrennt"), e.neuzugangGetrennt) { e.neuzugangGetrennt = !e.neuzugangGetrennt }
                            Trennlinie()
                            Gruppenkopf(uebersetzt("Genres"))
                            // **Eine Liste, zwei Formen** — dieselbe Wertzeile wie „Puffer" &c., nicht zwei
                            // Zeilen mit Haken: das war die Fassung vor dem Angleich an `ProfilView.swift`.
                            TvHandlung(uebersetzt("Form"), wert = if (e.genreChips) uebersetzt("Als Chips") else uebersetzt("Als Reihen")) {
                                blatt(uebersetzt("Form"),
                                      listOf(Wahl("reihen", uebersetzt("Als eigene Reihen")), Wahl("chips", uebersetzt("Als Chips über den Reihen"))),
                                      if (e.genreChips) "chips" else "reihen") { e.genreChips = it == "chips" }
                            }
                            e.startGenres.forEach { g ->
                                Trennlinie()
                                TvHandlung(name = g, wert = uebersetzt("Entfernen")) { e.startGenres = e.startGenres - g }
                            }
                            Trennlinie()
                            val freieGattungen = alleGattungen.filter { it !in e.startGenres }
                            TvHandlung(uebersetzt("Genre hinzufügen"), wert = if (freieGattungen.isEmpty()) uebersetzt("Keins offen") else "") {
                                if (freieGattungen.isNotEmpty()) blatt(uebersetzt("Genre hinzufügen"), freieGattungen.map { Wahl(it, it) }, "") { g -> e.startGenres = e.startGenres + g }
                            }
                        }
                        Abteil.Integration -> {
                            // **Ein zweiter Dienst, kein zweiter Server** — deshalb eine Angabe darüber, ob
                            // verbunden ist, und darunter die Handlung. Wie auf tvOS ist die Angabe selbst
                            // nicht fokussierbar.
                            TvAnzeige(uebersetzt("Seerr"), uebersetzt(if (app.seerrVerbunden.value) "Verbunden" else "Nicht verbunden"))
                            Trennlinie()
                            TvHandlung(uebersetzt(if (app.seerrVerbunden.value) "Ändern" else "Anbinden"), modifier = erste) {
                                oeffnen(Ziel("seerr", "Seerr", "Seerr"))
                            }
                        }
                        Abteil.Server -> {
                            // Vorlage: `ProfilView.swift:423` `model.serverName` — der Servername, nicht
                            // die gespeicherte Adresse; nur ohne Namen faellt es auf den Host zurueck.
                            TvAnzeige(uebersetzt("Adresse"), server?.first?.ifEmpty { null } ?: app.servername.value ?: host.ifEmpty { "—" })
                            Trennlinie()
                            TvAnzeige(uebersetzt("Fassung"), server?.second?.let { "Jellyfin $it" } ?: "—")
                            TvAnzeige("Swiftly", SwiftlyAnwendung.FASSUNGSZEILE.removePrefix("Swiftly Player "))
                            Trennlinie()
                            // Mehrere Server, seit dem 12.09.2026 — vorher hielt der Bund genau einen.
                            TvHandlung(uebersetzt("Server hinzufügen")) { oeffnen(Ziel("serveraufnahme", uebersetzt("Server hinzufügen"), "ServerAufnahme")) }
                            Trennlinie()
                            // Fuer Server hinter einem Dienst wie Cloudflare Access (Issue #4).
                            TvHandlung(uebersetzt("Eigene Header")) { oeffnen(Ziel("eigenkoepfe", uebersetzt("Eigene Header"), "EigeneKoepfe")) }
                            Trennlinie()
                            // Wie auf tvOS traegt „Verbindung pruefen" den ersten Fokus dieses Abteils,
                            // nicht „Server hinzufuegen" — so steht es in `ProfilView.swift`.
                            TvHandlung(uebersetzt("Verbindung prüfen"), wert = pruefung, pfeil = false, modifier = erste) {
                                pruefung = uebersetzt("Moment…")
                                lauf.launch {
                                    pruefung = try {
                                        val o = JSONObject(withContext(Dispatchers.IO) { app.kern.serverauskunft().await() })
                                        uebersetzt("Erreichbar — Jellyfin %@", o.optString("version"))
                                    } catch (x: CancellationException) { throw x } catch (x: Exception) { fehlertext(app, x) }
                                }
                            }
                        }
                        Abteil.Konto -> {
                            // **„Weiteres Konto hinzufügen" steht als Plus in der Kontokarte**, dort wo die
                            // Konten stehen — wie auf tvOS. An seiner Stelle hier der zweite Server: dieselbe
                            // Handlung wie „Server hinzufügen" im Server-Abteil, derselbe Katalogschlüssel und
                            // dasselbe Ziel (`ServerAufnahme` → `TvServerAufnahme`). Stand hier als tote
                            // Anzeigezeile „Kommt später" — gewünscht: Server hinzufügen können.
                            TvHandlung(uebersetzt("Server hinzufügen"), modifier = erste) {
                                oeffnen(Ziel("serveraufnahme", uebersetzt("Server hinzufügen"), "ServerAufnahme"))
                            }
                            Trennlinie()
                            TvHandlung(uebersetzt("Abmelden")) { app.abmelden() }
                        }
                        Abteil.Swiftly -> {
                            // Vorlage: das Abteil „Swiftly" auf tvOS. Dort QR-Codes; hier die Adressen zum
                            // Abtippen — ein QR-Bild braeuchte eine eigene Bibliothek. Bewerten oeffnet den
                            // Play Store, den es auf Android TV gibt; der Rest braucht einen Browser, den es
                            // meist nicht gibt.
                            TvHandlung(uebersetzt("Swiftly bewerten"), modifier = erste) {
                                app.adresseOeffnen(kontext, app.gemeinschaftAdresse("play"))
                            }
                            Trennlinie()
                            TvAnzeige(uebersetzt("Discord beitreten"), app.gemeinschaftAdresse("discordKurz"))
                            Trennlinie()
                            TvAnzeige(uebersetzt("Fehler melden"), app.gemeinschaftAdresse("fehlerKurz"))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Zeilen

/** Ein Abteil in der linken Spalte. Vorlage: `BereichsStil` — vier Zustaende, kein Symbol:
 *  gewaehlt traegt Akzentflaeche und Akzentschrift, fokussiert die ruhige Flaeche. */
@Composable
private fun BereichZeile(titel: String, ausgewaehlt: Boolean, modifier: Modifier = Modifier,
                          fokusGeaendert: (Boolean) -> Unit = {}, tun: () -> Unit) {
    Fokusflaeche(modifier.fillMaxWidth(), lupe = 1f, fokusGeaendert = fokusGeaendert, tun = tun) { fokus ->
        val grund = when {
            ausgewaehlt && fokus -> Stil.akzent.copy(alpha = 0.26f)
            ausgewaehlt          -> Stil.akzent.copy(alpha = 0.15f)
            fokus                -> TvStil.fokusflaeche
            else                 -> Color.Transparent
        }
        Row(Modifier.fillMaxWidth().height(TvStil.zeilenHoehe).clip(RoundedCornerShape(TvStil.ecke))
                .background(grund).padding(horizontal = 13.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text(titel, style = TvStil.koerper.copy(
                     fontWeight = if (ausgewaehlt || fokus) FontWeight.SemiBold else FontWeight.Normal),
                 color = if (ausgewaehlt) Stil.akzent else Stil.schrift, maxLines = 1)
        }
    }
}

/** Zeile ohne Handlung — nur Angabe. Vorlage: `Anzeigezeile`. Anders als jede Zeile daneben kein
 *  Knopf: eine Angabe ohne Wirkung, die trotzdem Fokus annimmt, ist auf dem Fernseher eine Falle. */
@Composable
private fun TvAnzeige(titel: String, wert: String, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().height(TvStil.zeilenHoehe).padding(horizontal = 13.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(titel, style = TvStil.koerper, color = Stil.schrift,
             maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(20.dp))
        Text(wert, style = TvStil.kachel, color = Stil.schriftLeise, maxLines = 1)
    }
}

/** Zeile, die etwas ausloest — mit oder ohne Wert und Pfeil rechts. Vorlage: `Handlungszeile`.
 *  `name` ist der Wortlaut vom Server (Genre) und laeuft nicht durch den Katalog. */
@Composable
private fun TvHandlung(titel: String = "", name: String? = null, wert: String? = null,
                        pfeil: Boolean = wert != null, modifier: Modifier = Modifier, tun: () -> Unit) {
    Fokusflaeche(modifier.fillMaxWidth(), lupe = 1f, tun = tun) { fokus ->
        Row(Modifier.fillMaxWidth().height(TvStil.zeilenHoehe).clip(RoundedCornerShape(TvStil.ecke))
                .background(if (fokus) TvStil.fokusflaeche else Color.Transparent).padding(horizontal = 13.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(name ?: titel, style = TvStil.koerper,
                 color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            if (wert != null) {
                Text(wert, style = TvStil.kachel, color = Stil.schriftLeise, maxLines = 1)
                if (pfeil) Symbol(Zeichen.WinkelRunter, 13.dp, farbe = Stil.schriftSehrLeise, staerke = Staerke.Halbfett)
            }
        }
    }
}

/** Der gezeichnete Schalter — Vorlage: `Schalter` (tvOS). Keine Material-`Switch`: eigene Masse,
 *  eigener Radius, eigene Bewegung. Der Fokus liegt auf der Zeile, nicht auf dem Schalter. */
@Composable
private fun TvSchalter(an: Boolean) {
    val breite = 42.dp; val hoehe = 25.dp; val kreis = 20.dp; val einzug = 2.5.dp
    val versatz by animateDpAsState(if (an) breite - kreis - einzug else einzug,
                                     tween(150), label = "schalterVersatz")
    // Aus: Flaeche `rand` (Weiss 12 %), an: `akzent`, Knauf `grund` (BAUTEILE 6).
    val kapsel by animateColorAsState(if (an) Stil.akzent else Stil.rand,
                                       tween(150), label = "schalterKapsel")
    val knopf by animateColorAsState(if (an) Stil.grund else Color.White,
                                      tween(150), label = "schalterKnopf")
    Box(Modifier.width(breite).height(hoehe).clip(CircleShape).background(kapsel)) {
        Box(Modifier.offset(x = versatz, y = einzug).size(kreis).clip(CircleShape).background(knopf))
    }
}

/** Zeile mit Schalter rechts — Vorlage: `Schalterzeile`. Gedrueckt wird die ganze Zeile. */
@Composable
private fun TvSchalterzeile(titel: String, an: Boolean, modifier: Modifier = Modifier, tun: () -> Unit) {
    Fokusflaeche(modifier.fillMaxWidth(), lupe = 1f, tun = tun) { fokus ->
        Row(Modifier.fillMaxWidth().height(TvStil.zeilenHoehe).clip(RoundedCornerShape(TvStil.ecke))
                .background(if (fokus) TvStil.fokusflaeche else Color.Transparent).padding(horizontal = 13.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(titel, style = TvStil.koerper, color = Stil.schrift, maxLines = 1,
                 overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            TvSchalter(an)
        }
    }
}

/** Eine Reihe der Startseite: an oder aus, und wohin sie gehoert. Vorlage: `Reihenzeile` — Pfeile
 *  statt Ziehgriff, weil die Fernbedienung nichts zum Greifen hat. */
@Composable
private fun TvReihenzeile(name: String, an: Boolean, kannHoch: Boolean, kannRunter: Boolean,
                           umschalten: () -> Unit, schieben: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        TvSchalterzeile(name, an, modifier = Modifier.weight(1f), tun = umschalten)
        TvKnopf(null, Zeichen.WinkelHoch, hoehe = 28.dp, freigegeben = kannHoch) { schieben(-1) }
        TvKnopf(null, Zeichen.WinkelRunter, hoehe = 28.dp, freigegeben = kannRunter) { schieben(1) }
    }
}

/** Haarlinie zwischen Zeilen. Vorlage: `Trennlinie`. */
@Composable
private fun Trennlinie() {
    Box(Modifier.fillMaxWidth().padding(horizontal = 13.dp).height(1.dp).background(Stil.linie))
}

// MARK: - Konto

/** Wer angemeldet ist, als Karte ueber den Abteilen. Vorlage: `kontokarte` — Bild, Name, Server,
 *  Trennlinie, darunter die anderen Konten und das Plus. */
@Composable
private fun Kontokarte(app: SwiftlyAnwendung, serverzeile: String, karten: List<JSONObject>,
                        aufnehmen: () -> Unit, wechseln: (String) -> Unit) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(TvStil.eckeKachel)).background(Stil.flaeche).padding(16.dp)) {
        Profilbild(app, 42.dp)
        Text(app.benutzername(), style = TvStil.reihe,
             color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.padding(top = 9.dp))
        // Serverdaten, kein Katalogtext.
        Text(serverzeile, style = TvStil.klein, color = Stil.schriftLeise, maxLines = 1,
             modifier = Modifier.padding(top = 2.dp))
        Spacer(Modifier.height(12.dp))
        Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.linie))
        Spacer(Modifier.height(12.dp))
        Kontenstreifen(karten, aufnehmen, wechseln)
    }
}

/** Die anderen Konten und das Plus — unten in der Kontokarte. Vorlage: `Kontenstreifen`.
 *  **Das angemeldete Konto steht nicht mehr darin** — es steht groesser darueber. Zaehlt alle
 *  Konten aus allen Servern des Buendels, nicht nur die des aktiven — dieselbe Reichweite wie
 *  `model.konten` auf tvOS (`Kontenbund.konten` ueber alle Server hinweg). */
@Composable
private fun Kontenstreifen(karten: List<JSONObject>, aufnehmen: () -> Unit, wechseln: (String) -> Unit) {
    val groesse = 30.dp
    val andere = karten.flatMap { k ->
        val konten = k.optJSONArray("konten") ?: JSONArray()
        (0 until konten.length()).map { konten.getJSONObject(it) }
    }.filter { !it.optBoolean("aktiv") }

    Row(Modifier.fillMaxWidth().focusGroup(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        andere.forEach { konto ->
            Fokusflaeche(lupe = TvStil.fokusLupeKlein, tun = { wechseln(konto.optString("kennung")) }) { fokus ->
                Box(Modifier.size(groesse).clip(CircleShape)
                        .then(if (fokus) Modifier.border(2.dp, Color.White, CircleShape) else Modifier)) {
                    Kontokreis(konto.optString("name"), konto.optString("bild").ifEmpty { null }, groesse)
                }
            }
        }
        Fokusflaeche(lupe = TvStil.fokusLupeKlein, tun = aufnehmen) { fokus ->
            Box(Modifier.size(groesse)
                    .drawBehind {
                        drawCircle(color = Stil.schriftSehrLeise,
                                   style = Stroke(width = 1.5.dp.toPx(),
                                       pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 2.5.dp.toPx()))))
                    }
                    .then(if (fokus) Modifier.border(2.dp, Color.White, CircleShape) else Modifier),
                contentAlignment = Alignment.Center) {
                Symbol(Zeichen.Plus, 12.dp, farbe = Stil.schriftLeise, staerke = Staerke.Halbfett, beschreibung = uebersetzt("Weiteres Konto hinzufügen"))
            }
        }
    }
}

/** Das Bild eines fremden Kontos, sonst sein Anfangsbuchstabe — dasselbe Muster wie `Profilbild`,
 *  nur fuer ein Konto, das gerade nicht das eigene ist (eigene Adresse statt `app.kern`). */
@Composable
private fun Kontokreis(name: String, bild: String?, groesse: Dp) {
    SubcomposeAsyncImage(model = bild, contentDescription = name, contentScale = ContentScale.Crop,
        modifier = Modifier.size(groesse).clip(CircleShape),
        error = {
            Box(Modifier.fillMaxSize().background(Stil.erhoeht), contentAlignment = Alignment.Center) {
                Text(name.take(1).uppercase(), color = Stil.schrift,
                     style = TextStyle(fontSize = (groesse.value * 0.38f).sp, fontWeight = FontWeight.SemiBold))
            }
        })
}
