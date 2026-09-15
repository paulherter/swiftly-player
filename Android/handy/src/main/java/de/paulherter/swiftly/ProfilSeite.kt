package de.paulherter.swiftly

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.*
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
 * Weitere Konten und ein zweiter Server folgen mit dem `Kontenbund`.
 */
@Composable
fun ProfilSeite(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    val server by rememberServerauskunft(app)
    Einstellungsseite(uebersetzt("Profil"), zurueck) {
        Karte {
            Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Profilbild(app, 56.dp)
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(app.benutzername(), style = TextStyle(fontSize = 19.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.2).sp),
                         color = Stil.schrift, maxLines = 1)
                    val name = server?.first?.takeIf { it.isNotEmpty() } ?: app.servername.value
                    name?.takeIf { it.isNotEmpty() }?.let { Text(it, style = TextStyle(fontSize = 13.sp), color = Stil.schriftSehrLeise, maxLines = 1) }
                    server?.second?.takeIf { it.isNotEmpty() }?.let {
                        Text(uebersetzt("Jellyfin %@", it), style = TextStyle(fontSize = 12.sp), color = Stil.schriftSehrLeise)
                    }
                }
            }
        }
        Spacer(Modifier.height(20.dp))
        Karte {
            Profilzeile(Icons.Filled.Tv, uebersetzt("Quick Connect"), uebersetzt("Code vom Fernseher eingeben"), akzent = true) {
                oeffnen(Ziel("quickconnect", "Quick Connect", "QuickConnect"))
            }
        }
        Spacer(Modifier.height(18.dp))
        Karte {
            Profilzeile(Icons.Filled.PlayArrow, uebersetzt("Wiedergabe"), uebersetzt("Sprache, Untertitel, Tempo")) {
                oeffnen(Ziel("wiedergabe", uebersetzt("Wiedergabe"), "Wiedergabeeinstellungen"))
            }
            Trennlinie()
            Profilzeile(Icons.Filled.GridView, uebersetzt("Darstellung"), uebersetzt("Startseite, Reihen, Genres")) {
                oeffnen(Ziel("darstellung", uebersetzt("Darstellung"), "Darstellung"))
            }
            Trennlinie()
            Profilzeile(Icons.Filled.Settings, uebersetzt("Einstellungen")) {
                oeffnen(Ziel("einstellungen", uebersetzt("Einstellungen"), "Einstellungen"))
            }
        }
        Spacer(Modifier.height(18.dp))
        Karte {
            // Betrifft nur das angemeldete Konto.
            Profilzeile(Icons.AutoMirrored.Filled.Logout, uebersetzt("Abmelden")) { app.abmelden() }
        }
        Text(SwiftlyAnwendung.FASSUNGSZEILE, style = TextStyle(fontSize = 12.sp), color = Color.White.copy(alpha = 0.3f),
             modifier = Modifier.padding(horizontal = Stil.randAbstand).padding(top = 26.dp))
    }
}

/** Vorlage: `QuickConnectView` — den Code eines anderen Geraets freigeben. */
@Composable
fun QuickConnectSeite(app: SwiftlyAnwendung, zurueck: () -> Unit) {
    var code by remember { mutableStateOf("") }
    var laeuft by remember { mutableStateOf(false) }
    var meldung by remember { mutableStateOf<String?>(null) }
    val lauf = rememberCoroutineScope()
    Einstellungsseite(uebersetzt("Quick Connect"), zurueck) {
        Column(Modifier.padding(horizontal = Stil.randAbstand).widthIn(max = Stil.formularbreite)) {
            Text(uebersetzt("Auf dem anderen Gerät steht ein sechsstelliger Code. Gib ihn hier ein, dann meldet es sich mit deinem Konto an."),
                 style = Stil.koerper.copy(lineHeight = 21.sp), color = Stil.schriftLeise, modifier = Modifier.padding(top = 10.dp))
            val ziffern = TextStyle(fontSize = 34.sp, fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum", textAlign = TextAlign.Center)
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
            meldung?.let { Text(it, style = TextStyle(fontSize = 13.sp), color = Stil.schriftLeise, modifier = Modifier.padding(top = 12.dp)) }
            Box(Modifier.padding(top = 22.dp)) {
                Spielknopf(Icons.Filled.Check, uebersetzt(if (laeuft) "Moment…" else "Freigeben"), an = !laeuft && code.length >= 4, haupt = true) {
                    laeuft = true
                    meldung = null
                    lauf.launch {
                        val grund = withContext(Dispatchers.IO) { app.kern.quickConnectFreigeben(code).await() }
                        meldung = if (grund.isEmpty()) uebersetzt("Freigegeben. Das andere Gerät ist gleich angemeldet.") else fehlertext(grund)
                        laeuft = false
                    }
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
        Text(uebersetzt("Gilt für alles, was neu startet. Im Player lässt sich jederzeit abweichen."),
             style = Stil.koerper.copy(lineHeight = 21.sp), color = Stil.schriftLeise, modifier = Modifier.padding(horizontal = Stil.randAbstand))

        Einstellungsgruppe(uebersetzt("Qualität")) {
            Wahlzeile(Icons.Filled.PlayArrow, uebersetzt("Immer Direct Play"), uebersetzt("Nie umwandeln lassen — der Grund für diese App"),
                      e.immerDirectPlay) { e.immerDirectPlay = it; app.qualitaetMelden() }
            Trennlinie()
            // Gedimmt, solange Direct Play erzwungen ist — dort griffe sie nicht.
            Wertzeile(Icons.Filled.BarChart, uebersetzt("Höchste Bitrate"),
                      wert = bitraten.firstOrNull { it.wert == e.bitratenGrenze.toString() }?.text, gedimmt = e.immerDirectPlay) {
                blatt(uebersetzt("Höchste Bitrate"), bitraten, e.bitratenGrenze.toString()) { e.bitratenGrenze = it.toInt(); app.qualitaetMelden() }
            }
        }

        Einstellungsgruppe(uebersetzt("Sprache")) {
            Wertzeile(Icons.Filled.VolumeUp, uebersetzt("Ton"), wert = tonwahl.firstOrNull { it.wert == e.tonSprache }?.text) {
                blatt(uebersetzt("Ton"), tonwahl, e.tonSprache) { e.tonSprache = it }
            }
            Trennlinie()
            Wertzeile(Icons.Filled.ClosedCaption, uebersetzt("Untertitel"), wert = untertitelwahl.firstOrNull { it.wert == e.untertitelSprache }?.text) {
                blatt(uebersetzt("Untertitel"), untertitelwahl, e.untertitelSprache) { e.untertitelSprache = it }
            }
            Trennlinie()
            Wahlzeile(Icons.Filled.Subtitles, uebersetzt("Untertitel automatisch"), uebersetzt("Nur wenn der Ton nicht in der gewählten Sprache läuft"),
                      e.untertitelAutomatisch) { e.untertitelAutomatisch = it }
        }

        Einstellungsgruppe(uebersetzt("Verhalten")) {
            Wahlzeile(Icons.Filled.SkipNext, uebersetzt("Nächste Folge automatisch"), an = e.naechsteAutomatisch) { e.naechsteAutomatisch = it }
            Trennlinie()
            Wertzeile(Icons.Filled.Replay, uebersetzt("Zurückspulen"), wert = uebersetzt("%lld s", e.zurueckSekunden)) {
                blatt(uebersetzt("Zurückspulen"), sekundenwahl(), e.zurueckSekunden.toString()) { e.zurueckSekunden = it.toInt() }
            }
            Trennlinie()
            Wertzeile(Icons.Filled.FastForward, uebersetzt("Vorspulen"), wert = uebersetzt("%lld s", e.vorSekunden)) {
                blatt(uebersetzt("Vorspulen"), sekundenwahl(), e.vorSekunden.toString()) { e.vorSekunden = it.toInt() }
            }
            Trennlinie()
            // Unter Verhalten, nicht Qualitaet: der Puffer aendert die Ausdauer, nicht das Bild.
            Wertzeile(Icons.Filled.Wifi, uebersetzt("Puffer"), wert = puffer.firstOrNull { it.wert == e.pufferstufe }?.text) {
                blatt(uebersetzt("Puffer"), puffer, e.pufferstufe) { e.pufferstufe = it }
            }
        }
        Fusszeile(uebersetzt("Die Bitrate greift nur, wenn Direct Play nicht erzwungen wird — sonst bliebe sie wirkungslos und stünde trotzdem da."))
    }
}

/**
 * Vorlage: `DarstellungView` — Allgemein, Startseite (umsortierbar, einzeln abschaltbar),
 * Genres. **Eine Genreliste**, keine zweite verborgene: frueher tauschte „Chips" still die Daten.
 * Die Chip-Darstellung auf der Startseite folgt; bis dahin stehen Genres als eigene Reihen.
 */
@Composable
fun DarstellungSeite(app: SwiftlyAnwendung, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    val e = app.einstellungen
    Einstellungsseite(uebersetzt("Darstellung"), zurueck) {
        Einstellungsgruppe(uebersetzt("Allgemein")) {
            Wahlzeile(Icons.Filled.ScreenRotation, uebersetzt("Querformat im Player sperren"), an = e.querformatFest) { e.querformatFest = it }
            Trennlinie()
            Wahlzeile(Icons.Filled.BarChart, uebersetzt("Fortschritt auf Kacheln"), an = e.fortschritt) { e.fortschritt = it }
        }

        Einstellungsgruppe(uebersetzt("Startseite")) {
            val reihen = remember(e.startReihen, e.neuzugangGetrennt) {
                wahlenLesen(Kern.startreihen(e.startReihen.toTypedArray(), e.neuzugangGetrennt))
            }
            Umsortierbar(reihen, { it.wert }, verschieben = { r, schritt ->
                e.startReihen = JSONArray(Kern.startreiheVerschoben(r.wert, schritt.toLong(), e.startReihen.toTypedArray(), e.neuzugangGetrennt))
                    .let { a -> (0 until a.length()).map { a.getString(it) } }
            }) { r ->
                Wahlzeile(Icons.Filled.ViewAgenda, uebersetzt(r.text), an = r.wert !in e.startAus) { an ->
                    e.startAus = if (an) e.startAus - r.wert else e.startAus + r.wert
                }
            }
            Trennlinie()
            Wahlzeile(Icons.Filled.VerticalSplit, uebersetzt("Neuzugänge getrennt"), uebersetzt("Neue Filme und neue Serien als eigene Reihen"),
                      e.neuzugangGetrennt) { e.neuzugangGetrennt = it }
        }
        Fusszeile(uebersetzt("Zum Umsortieren an den Griffen rechts ziehen."))

        Einstellungsgruppe(uebersetzt("Genres")) {
            Umsortierbar(e.startGenres, { it }, verschieben = { g, schritt ->
                val liste = e.startGenres.toMutableList()
                val von = liste.indexOf(g)
                val nach = (von + schritt).coerceIn(0, liste.lastIndex)
                if (von >= 0 && von != nach) { liste.removeAt(von); liste.add(nach, g); e.startGenres = liste }
            }) { g ->
                Row(Modifier.fillMaxWidth().padding(start = Stil.randAbstand).height(52.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(g, style = TextStyle(fontSize = 15.sp), color = Stil.schrift, modifier = Modifier.weight(1f))
                    Box(Modifier.size(44.dp).antippen { e.startGenres = e.startGenres - g }, contentAlignment = Alignment.Center) {
                        Icon(Icons.Filled.RemoveCircleOutline, contentDescription = uebersetzt("Löschen"), tint = Stil.schriftSehrLeise, modifier = Modifier.size(20.dp))
                    }
                }
            }
            if (e.startGenres.isNotEmpty()) Trennlinie()
            Row(Modifier.fillMaxWidth().druckzeile { oeffnen(Ziel("genrewahl", uebersetzt("Genre hinzufügen"), "Genrewahl")) }
                    .padding(horizontal = Stil.randAbstand, vertical = 15.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Icon(Icons.Filled.Add, contentDescription = null, tint = Stil.akzent, modifier = Modifier.width(20.dp))
                Text(uebersetzt("Genre hinzufügen"), style = TextStyle(fontSize = 15.sp), color = Stil.akzent)
            }
        }
    }
}

/** Vorlage: `EinstellungenView` ohne Offline und Integration — Server und Verbindung. */
@Composable
fun EinstellungenSeite(app: SwiftlyAnwendung, zurueck: () -> Unit) {
    val server by rememberServerauskunft(app)
    var prueft by remember { mutableStateOf(false) }
    var ergebnis by remember { mutableStateOf<String?>(null) }
    val lauf = rememberCoroutineScope()
    Einstellungsseite(uebersetzt("Einstellungen"), zurueck) {
        Einstellungsgruppe(uebersetzt("Server")) {
            Wertzeile(Icons.Filled.Storage, server?.first?.takeIf { it.isNotEmpty() } ?: app.servername.value.orEmpty().ifEmpty { "Jellyfin" },
                      wert = server?.second ?: "?")
            Trennlinie()
            Wertzeile(Icons.Filled.Wifi, uebersetzt("Verbindung prüfen"), unter = ergebnis,
                      wert = if (prueft) uebersetzt("Moment…") else null,
                      tun = if (prueft) null else { {
                          prueft = true
                          lauf.launch {
                              ergebnis = try {
                                  val o = JSONObject(withContext(Dispatchers.IO) { app.kern.serverauskunft().await() })
                                  uebersetzt("Erreichbar — Jellyfin %@", o.optString("version"))
                              } catch (e: CancellationException) { throw e } catch (e: Exception) { e.message ?: e.toString() }
                              prueft = false
                          }
                      } })
        }
        Text("${SwiftlyAnwendung.FASSUNGSZEILE} · libVLC 3.6.3", style = TextStyle(fontSize = 12.sp), color = Color.White.copy(alpha = 0.3f),
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
                 style = Stil.koerper, color = Stil.schriftLeise, modifier = Modifier.padding(horizontal = Stil.randAbstand).padding(top = 20.dp))
        } else {
            Karte {
                frei.forEachIndexed { i, g ->
                    if (i > 0) Trennlinie()
                    Wertzeile(Icons.Filled.Tag, g, tun = { e.startGenres = e.startGenres + g; zurueck() })
                }
            }
        }
    }
}
