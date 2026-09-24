package de.paulherter.swiftly

import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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

/** Server und Fassung aus `Kern.serverauskunft` — `null`, solange keine Antwort da ist. */
@Composable
private fun rememberServerauskunft(app: SwiftlyAnwendung): State<Pair<String, String>?> {
    val auskunft = remember { mutableStateOf<Pair<String, String>?>(null) }
    LaunchedEffect(Unit) {
        try {
            val o = JSONObject(withContext(Dispatchers.IO) { app.kern.serverauskunft().await() })
            auskunft.value = o.optString("name") to o.optString("version")
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }
    return auskunft
}

/**
 * Vorlage: `ProfilView` in `Sources/Shared/ProfilView.swift`.
 *
 * **Eine eigene Seite statt eines Menues** — ein Menue an einem 34-Punkt-Zeichen wirkte fremd,
 * und alles darin fuehrte ohnehin woanders hin. Abmelden fragt nicht nach, wie auf iOS.
 */
@Composable
fun ProfilSeite(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    val server by rememberServerauskunft(app)
    Einstellungsseite(uebersetzt("Profil"), zurueck) {
        Kontokarten(app, server, oeffnen)
        Spacer(Modifier.height(18.dp))
        Karte {
            Profilzeile(Zeichen.Textsuche, uebersetzt("Quick Connect"), uebersetzt("Code vom Fernseher eingeben"), zeichenAkzent = true) {
                oeffnen(Ziel("quickconnect", "Quick Connect", "QuickConnect"))
            }
        }
        Spacer(Modifier.height(18.dp))
        Karte {
            Profilzeile(Zeichen.Abspielen, uebersetzt("Wiedergabe"), uebersetzt("Sprache, Untertitel, Tempo")) {
                oeffnen(Ziel("wiedergabe", uebersetzt("Wiedergabe"), "Wiedergabeeinstellungen"))
            }
            Trennlinie()
            Profilzeile(Zeichen.Raster, uebersetzt("Darstellung"), uebersetzt("Startseite, Reihen, Genres")) {
                oeffnen(Ziel("darstellung", uebersetzt("Darstellung"), "Darstellung"))
            }
            Trennlinie()
            Profilzeile(Zeichen.Zahnrad, uebersetzt("Einstellungen")) {
                oeffnen(Ziel("einstellungen", uebersetzt("Einstellungen"), "Einstellungen"))
            }
        }
        Spacer(Modifier.height(18.dp))
        Karte {
            Profilzeile(Zeichen.Server, uebersetzt("Server hinzufügen"), uebersetzt("Ein zweiter Jellyfin, eigene Konten")) {
                oeffnen(Ziel("serveraufnahme", uebersetzt("Server hinzufügen"), "ServerAufnahme"))
            }
            Trennlinie()
            // Betrifft nur das geltende Konto; bleiben andere, gilt danach das naechste.
            Profilzeile(Zeichen.Abmelden, uebersetzt("Abmelden")) { app.abmelden() }
        }
        Spacer(Modifier.height(18.dp))
        // **Bewerten, Discord, Fehler melden — ganz unten.** Stand in den
        // Einstellungen und wurde dort kaum gesehen. Die Adressen kommen aus
        // dem Paket. **Play-Eintrag statt In-App-Abfrage:** die kommt von
        // selbst nach dem dritten Titel; eine Zeile, die sie ausloest, zeigte
        // im geschlossenen Test oft gar nichts, weil Google die Abfrage
        // drosselt und nicht meldet, ob sie erschien.
        val kontext = androidx.compose.ui.platform.LocalContext.current
        Karte {
            Profilzeile(Zeichen.Stern, uebersetzt("Swiftly bewerten"), uebersetzt("Im Play Store")) {
                app.adresseOeffnen(kontext, app.gemeinschaftAdresse("play"))
            }
            Trennlinie()
            Profilzeile(Zeichen.Gespraech, uebersetzt("Discord beitreten"), uebersetzt("Fragen stellen und sagen, was fehlt")) {
                app.adresseOeffnen(kontext, app.gemeinschaftAdresse("discord"))
            }
            Trennlinie()
            Profilzeile(Zeichen.Kaefer, uebersetzt("Fehler melden"), uebersetzt("Auf GitHub, deine App-Version ist schon eingetragen")) {
                app.adresseOeffnen(kontext, app.gemeinschaftAdresse("fehler"))
            }
            Trennlinie()
            // Neben „Fehler melden", weil es dazugehoert: wer im Discord einen Fehler meldet, haengt das hier an.
            Profilzeile(Zeichen.Dokument, uebersetzt("Protokoll teilen"), uebersetzt("Die letzte Stunde, ohne Zugangsdaten")) {
                Protokolldatei.teilen(kontext)
            }
        }
        // Weiss auf 30 Prozent ist gerechnet 2,67:1 und fuer Text verboten (BRAND 1).
        Text(SwiftlyAnwendung.FASSUNGSZEILE, style = Stil.klein, color = Stil.schriftSehrLeise,
             modifier = Modifier.padding(horizontal = Stil.randAbstand).padding(top = 26.dp))
    }
}

/** Vorlage: `QuickConnectView` — den Code eines anderen Geraets freigeben. */
@Composable
fun QuickConnectSeite(app: SwiftlyAnwendung, zurueck: () -> Unit) {
    var code by remember { mutableStateOf("") }
    var laeuft by remember { mutableStateOf(false) }
    var meldung by remember { mutableStateOf<String?>(null) }
    var geschafft by remember { mutableStateOf(false) }
    val lauf = rememberCoroutineScope()
    Einstellungsseite(uebersetzt("Quick Connect"), zurueck) {
        Column(Modifier.padding(horizontal = Stil.randAbstand).widthIn(max = Stil.formularbreite)) {
            Text(uebersetzt("Auf dem anderen Gerät steht ein sechsstelliger Code. Gib ihn hier ein, dann meldet es sich mit deinem Konto an."),
                 style = Stil.koerper.copy(lineHeight = 21.sp), color = Stil.schriftLeise, modifier = Modifier.padding(top = 10.dp))
            // 28 statt 34: die Ziffern sind hier der Gegenstand der Seite, also die Titelstufe.
            val ziffern = Stil.titelGross.copy(fontWeight = FontWeight.SemiBold, letterSpacing = 0.sp,
                                               fontFeatureSettings = "tnum", textAlign = TextAlign.Center)
            BasicTextField(value = code, onValueChange = { code = it.filter(Char::isDigit).take(6) }, singleLine = true,
                textStyle = ziffern.copy(color = Stil.schrift), cursorBrush = SolidColor(Stil.akzent),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                modifier = Modifier.fillMaxWidth().padding(top = 26.dp).clip(RoundedCornerShape(Stil.eckeFeld)).background(Stil.flaeche)
                    .padding(vertical = 16.dp),
                decorationBox = { feld ->
                    Box(contentAlignment = Alignment.Center) {
                        if (code.isEmpty()) Text("000000", style = ziffern, color = Stil.schriftSehrLeise, modifier = Modifier.fillMaxWidth())
                        feld()
                    }
                })
            // Geschafft im Akzent, gescheitert in `fehler` — 13 Medium.
            meldung?.let { Text(it, style = Stil.kachel, color = if (geschafft) Stil.akzent else Stil.fehler, modifier = Modifier.padding(top = 12.dp)) }
            // `HauptknopfStil` ohne Zeichen; nach dem Freigeben geht die Seite nach zwei Sekunden von selbst.
            de.paulherter.swiftly.gemeinsam.Hauptknopf(uebersetzt(if (laeuft) "Moment…" else "Freigeben"),
                    freigegeben = !laeuft && code.length >= 4, modifier = Modifier.padding(top = 22.dp)) {
                laeuft = true
                meldung = null
                lauf.launch {
                    val grund = withContext(Dispatchers.IO) { app.kern.quickConnectFreigeben(code).await() }
                    geschafft = grund.isEmpty()
                    meldung = if (geschafft) uebersetzt("Freigegeben. Das andere Gerät ist gleich angemeldet.") else fehlertext(grund)
                    laeuft = false
                    if (geschafft) { kotlinx.coroutines.delay(2000); zurueck() }
                }
            }
        }
    }
}

/** Vorlage: `WiedergabeEinstellungenView` — Qualitaet, Sprache, Verhalten. */
@Composable
fun WiedergabeEinstellungenSeite(app: SwiftlyAnwendung, zurueck: () -> Unit) {
    val e = app.einstellungen
    val bitraten = remember { wahlenLesen(Kern.bitratenstufen()) }
    val puffer = remember { JSONArray(Kern.pufferstufen()).let { a -> (0 until a.length()).map { a.getJSONObject(it).let { o -> Wahl(o.getString("wert"), o.getString("text")) } } } }
    val sekunden = remember { JSONArray(Kern.spannen()).let { a -> (0 until a.length()).map { a.getInt(it) } } }
    val tonwahl = remember { wahlenLesen(Kern.sprachen("")) }
    val untertitelwahl = remember { wahlenLesen(Kern.sprachen(uebersetzt("Aus"))) }
    fun blatt(titel: String, eintraege: List<Wahl>, gewaehlt: String, waehlen: (String) -> Unit) {
        app.blatt.value = Blattwunsch(titel, eintraege, gewaehlt, waehlen = waehlen)
    }
    fun sekundenwahl(): List<Wahl> = sekunden.map { Wahl(it.toString(), uebersetzt("%lld s", it)) }

    Einstellungsseite(uebersetzt("Wiedergabe"), zurueck) {
        // Wandelt der Server nicht um, ist nichts zu wählen: Direct Play steht
        // fest an, die Bitrate ist gesperrt.
        val frei = e.umwandelnErlaubt
        val directPlay = e.immerDirectPlay || !frei

        Einstellungsgruppe(uebersetzt("Qualität")) {
            Wahlzeile(Zeichen.Abspielen, uebersetzt("Immer Direct Play"), uebersetzt("Der Server wandelt nie um, es läuft immer die Originaldatei"),
                      directPlay, gesperrt = !frei) { e.immerDirectPlay = it; app.qualitaetMelden() }
            Trennlinie()
            // Gedimmt, solange Direct Play erzwungen ist — dort griffe sie nicht.
            Wertzeile(Zeichen.Balken, uebersetzt("Höchste Bitrate"),
                      wert = bitraten.firstOrNull { it.wert == e.bitratenGrenze.toString() }?.text, gedimmt = directPlay) {
                blatt(uebersetzt("Höchste Bitrate"), bitraten, e.bitratenGrenze.toString()) { e.bitratenGrenze = it.toInt(); app.qualitaetMelden() }
            }
        }

        Einstellungsgruppe(uebersetzt("Sprache")) {
            Wertzeile(Zeichen.Lautsprecher, uebersetzt("Ton"), wert = tonwahl.firstOrNull { it.wert == e.tonSprache }?.text) {
                blatt(uebersetzt("Ton"), tonwahl, e.tonSprache) { e.tonSprache = it }
            }
            Trennlinie()
            Wertzeile(Zeichen.Untertitel, uebersetzt("Untertitel"), wert = untertitelwahl.firstOrNull { it.wert == e.untertitelSprache }?.text) {
                blatt(uebersetzt("Untertitel"), untertitelwahl, e.untertitelSprache) { e.untertitelSprache = it }
            }
            Trennlinie()
            Wahlzeile(Zeichen.Textblock, uebersetzt("Untertitel automatisch"), uebersetzt("Nur wenn der Ton nicht in der gewählten Sprache läuft"),
                      e.untertitelAutomatisch) { e.untertitelAutomatisch = it }
        }

        Einstellungsgruppe(uebersetzt("Verhalten")) {
            Wahlzeile(Zeichen.Ueberspringen, uebersetzt("Nächste Folge automatisch"), an = e.naechsteAutomatisch) { e.naechsteAutomatisch = it }
            Trennlinie()
            Wahlzeile(Zeichen.Wellensuche, uebersetzt("Technische Daten im Player"), an = e.technikschild) { e.technikschild = it }
            Trennlinie()
            Wertzeile(Zeichen.Zurueckspulen, uebersetzt("Zurückspulen"), wert = uebersetzt("%lld s", e.zurueckSekunden)) {
                blatt(uebersetzt("Zurückspulen"), sekundenwahl(), e.zurueckSekunden.toString()) { e.zurueckSekunden = it.toInt() }
            }
            Trennlinie()
            Wertzeile(Zeichen.Vorspulen, uebersetzt("Vorspulen"), wert = uebersetzt("%lld s", e.vorSekunden)) {
                blatt(uebersetzt("Vorspulen"), sekundenwahl(), e.vorSekunden.toString()) { e.vorSekunden = it.toInt() }
            }
            Trennlinie()
            // Unter Verhalten, nicht Qualitaet: der Puffer aendert die Ausdauer, nicht das Bild.
            Wertzeile(Zeichen.WlanStoerung, uebersetzt("Puffer"), wert = puffer.firstOrNull { it.wert == e.pufferstufe }?.text) {
                blatt(uebersetzt("Puffer"), puffer, e.pufferstufe) { e.pufferstufe = it }
            }
            Trennlinie()
            Wahlzeile(Zeichen.Lautsprecher, uebersetzt("Mehrkanal-Ton (5.1)"),
                      uebersetzt("Schickt 5.1 und 7.1 so raus, wie sie in der Datei stehen. Kommt kein Ton, schalt es wieder aus."),
                      e.mehrkanalTon) { e.mehrkanalTon = it }
        }
    }
}

/**
 * Vorlage: `DarstellungView` — Allgemein, Startseite (umsortierbar, einzeln abschaltbar),
 * Genres. **Eine Genreliste**, keine zweite verborgene: frueher tauschte „Chips" still die Daten.
 */
@Composable
fun DarstellungSeite(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    val e = app.einstellungen
    Einstellungsseite(uebersetzt("Darstellung"), zurueck) {
        Einstellungsgruppe(uebersetzt("Allgemein")) {
            Wahlzeile(Zeichen.Rechtecke, uebersetzt("Querformat im Player sperren"), an = e.querformatFest) { e.querformatFest = it }
            Trennlinie()
            Wahlzeile(Zeichen.BalkenVoll, uebersetzt("Fortschritt auf Kacheln"), an = e.fortschritt) { e.fortschritt = it }
        }

        Einstellungsgruppe(uebersetzt("Startseite")) {
            val reihen = remember(e.startReihen, e.neuzugangGetrennt) {
                wahlenLesen(Kern.startreihen(e.startReihen.toTypedArray(), e.neuzugangGetrennt))
            }
            Umsortierbar(reihen, { it.wert }, verschieben = { r, schritt ->
                e.startReihen = JSONArray(Kern.startreiheVerschoben(r.wert, schritt.toLong(), e.startReihen.toTypedArray(), e.neuzugangGetrennt))
                    .let { a -> (0 until a.length()).map { a.getString(it) } }
            }) { r ->
                // Jede Reihe mit ihrem eigenen Zeichen (`Startreihe.symbol`).
                val zeichen = when (r.wert) {
                    "weiterschauen" -> Zeichen.AbspielenKreis
                    "naechsteFolge" -> Zeichen.UeberspringenUmriss
                    "neueFilme" -> Zeichen.Film
                    "neueSerien" -> Zeichen.Fernseher
                    else -> Zeichen.Funkeln
                }
                Wahlzeile(zeichen, uebersetzt(r.text), an = r.wert !in e.startAus) { an ->
                    e.startAus = if (an) e.startAus - r.wert else e.startAus + r.wert
                }
            }
            Trennlinie()
            Wahlzeile(Zeichen.Geteilt, uebersetzt("Neuzugänge getrennt"), uebersetzt("Neue Filme und neue Serien als eigene Reihen"),
                      e.neuzugangGetrennt) { e.neuzugangGetrennt = it }
        }
        Fusszeile(uebersetzt("Zum Umsortieren an den Griffen rechts ziehen."))

        Einstellungsgruppe(uebersetzt("Genres")) {
            // Eine Liste, zwei Formen.
            Darstellungsform(Zeichen.Zeilen, uebersetzt("Als eigene Reihen"), !e.genreChips) { e.genreChips = false }
            Trennlinie()
            Darstellungsform(Zeichen.Kapsel, uebersetzt("Als Chips über den Reihen"), e.genreChips) { e.genreChips = true }
            if (e.startGenres.isNotEmpty()) Trennlinie()
            Umsortierbar(e.startGenres, { it }, verschieben = { g, schritt ->
                val liste = e.startGenres.toMutableList()
                val von = liste.indexOf(g)
                val nach = (von + schritt).coerceIn(0, liste.lastIndex)
                if (von >= 0 && von != nach) { liste.removeAt(von); liste.add(nach, g); e.startGenres = liste }
            }) { g ->
                Row(Modifier.fillMaxWidth().padding(start = Stil.randAbstand).height(52.dp), verticalAlignment = Alignment.CenterVertically) {
                    // Der Genrename in 15 Regular — er ist ein Eintrag, keine Zeile mit Titel.
                    Text(g, style = Stil.koerper, color = Stil.schrift, modifier = Modifier.weight(1f))
                    Box(Modifier.size(44.dp).antippen { e.startGenres = e.startGenres - g }, contentAlignment = Alignment.Center) {
                        Symbol(Zeichen.KreuzKreis, 17.dp, farbe = Stil.schriftSehrLeise, beschreibung = uebersetzt("Löschen"))
                    }
                }
            }
            if (e.startGenres.isNotEmpty()) Trennlinie()
            Row(Modifier.fillMaxWidth().druckzeile { oeffnen(Ziel("genrewahl", uebersetzt("Genre hinzufügen"), "Genrewahl")) }
                    .padding(horizontal = Stil.randAbstand, vertical = 15.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(Modifier.width(Stil.zeichenSpalte), contentAlignment = Alignment.Center) { Symbol(Zeichen.Plus, 15.dp, farbe = Stil.akzent, staerke = Staerke.Halbfett) }
                Text(uebersetzt("Genre hinzufügen"), style = Stil.listentitel, color = Stil.akzent)
            }
        }
    }
}

@Composable
private fun Darstellungsform(symbol: Zeichen, titel: String, gewaehlt: Boolean, waehlen: () -> Unit) {
    // **Gewaehlt heisst Weiss und Grund, nicht Farbe**: der Haken in Weiss, die Zeile auf `erhoeht`.
    // Der Akzent traegt Zustand, keine Rangfolge unter Geschwistern.
    Zeilenaufbau(symbol, titel, null, Stil.schrift,
                 Modifier.background(if (gewaehlt) Stil.erhoeht else Color.Transparent).antippen(waehlen)) {
        if (gewaehlt) Symbol(Zeichen.Haken, 13.dp, farbe = Stil.schrift, staerke = Staerke.Halbfett)
    }
}

/** Vorlage: `EinstellungenView` ohne Offline und Integration — Server und Verbindung. */
@Composable
fun EinstellungenSeite(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    val server by rememberServerauskunft(app)
    var prueft by remember { mutableStateOf(false) }
    var ergebnis by remember { mutableStateOf<String?>(null) }
    val lauf = rememberCoroutineScope()
    Einstellungsseite(uebersetzt("Einstellungen"), zurueck) {
        // Auf dem Fernseher keine Downloads — dort steckt kein Speicher, den man fuellen will (tvOS).
        if (!app.istFernseher) OfflineGruppe(app)
        // Integration vor Server: ein zweiter Dienst, kein zweiter Server.
        Einstellungsgruppe(uebersetzt("Integration")) {
            Wertzeile(Zeichen.FunkelnSuche, "Seerr", uebersetzt("Anfragen, was noch nicht da ist"),
                      wert = if (app.seerrVerbunden.value) uebersetzt("Verbunden") else null) {
                oeffnen(Ziel("seerr", "Seerr", "Seerr"))
            }
        }
        Einstellungsgruppe(uebersetzt("Server")) {
            Wertzeile(Zeichen.Server, server?.first?.takeIf { it.isNotEmpty() } ?: app.servername.value.orEmpty().ifEmpty { "Jellyfin" },
                      wert = server?.second ?: "?")
            Trennlinie()
            Wertzeile(Zeichen.Wlan, uebersetzt("Verbindung prüfen"), unter = ergebnis,
                      wert = if (prueft) uebersetzt("Moment…") else null,
                      tun = if (prueft) null else { {
                          prueft = true
                          lauf.launch {
                              ergebnis = try {
                                  val o = JSONObject(withContext(Dispatchers.IO) { app.kern.serverauskunft().await() })
                                  uebersetzt("Erreichbar — Jellyfin %@", o.optString("version"))
                              } catch (e: CancellationException) { throw e } catch (e: Exception) { fehlertext(app, e) }
                              prueft = false
                          }
                      } })
            Trennlinie()
            // **Eigene Header, Issue #4.** Nur fuer Server hinter einem Dienst wie Cloudflare Access;
            // alle anderen gehen nie hinein.
            val anzahl = remember(app.kontowechsel.intValue) { org.json.JSONArray(app.eigeneKoepfe(app.aktiverServer())).length() }
            Wertzeile(Zeichen.Schluessel, uebersetzt("Eigene Header"), uebersetzt("Für einen Dienst vor dem Server"),
                      wert = if (anzahl == 0) null else anzahl.toString()) {
                oeffnen(Ziel("eigenkoepfe", uebersetzt("Eigene Header"), "EigeneKoepfe"))
            }
        }
        Text("${SwiftlyAnwendung.FASSUNGSZEILE} · libVLC 3.6.3", style = Stil.klein, color = Stil.schriftSehrLeise,
             modifier = Modifier.padding(horizontal = Stil.randAbstand).padding(top = 26.dp))
    }
}

/** Vorlage: `GenrewahlView` — die Genres des Servers, die noch nicht auf der Startseite stehen. Ein Tipp nimmt eins auf. */
@Composable
fun GenrewahlSeite(app: SwiftlyAnwendung, zurueck: () -> Unit) {
    val e = app.einstellungen
    var alle by remember { mutableStateOf<List<String>?>(null) }
    LaunchedEffect(Unit) {
        alle = try {
            JSONArray(withContext(Dispatchers.IO) { app.kern.gattungen().await() }).let { a -> (0 until a.length()).map { a.getString(it) } }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() }
    }
    Einstellungsseite(uebersetzt("Genre hinzufügen"), zurueck) {
        val liste = alle ?: return@Einstellungsseite
        val frei = liste.filter { it !in e.startGenres }
        if (frei.isEmpty()) {
            // Zwei Faelle, zwei Saetze: der Server hat keine, oder alle stehen schon da.
            Text(uebersetzt(if (liste.isEmpty()) "Auf deinem Server sind keine Genres hinterlegt." else "Alle Genres stehen schon auf der Startseite."),
                 style = Stil.koerper, color = Stil.schriftLeise, modifier = Modifier.padding(horizontal = Stil.randAbstand).padding(top = 8.dp))
        } else {
            Einstellungsgruppe(uebersetzt("Auf deinem Server")) {
                frei.forEachIndexed { i, g ->
                    if (i > 0) Trennlinie()
                    // Die ganze Zeile ist der Knopf, ohne Winkel — sie fuehrt nirgends hin, sie nimmt auf.
                    Box(Modifier.antippen { e.startGenres = e.startGenres + g; zurueck() }) { Wertzeile(Zeichen.Etikett, g) }
                }
            }
        }
    }
}
