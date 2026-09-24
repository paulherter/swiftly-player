package de.paulherter.swiftly

import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.semantics.clearAndSetSemantics
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import android.content.Intent
import android.net.Uri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.role
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import coil3.compose.SubcomposeAsyncImage
import de.paulherter.swiftly.gemeinsam.Stil
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.ui.draw.drawBehind
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.Locale

data class Mitwirkender(val id: String, val name: String, val rolle: String?, val bild: String?)
data class Datei(val container: String?, val video: String?, val ton: List<String>, val untertitel: String, val hatUntertitel: Boolean)
data class Extra(val id: String, val name: String, val bild: String?, val laufzeit: String?)

/** Antwort von `Kern.titel` — die Zeilen stehen dort schon fertig. */
data class Titel(
    val id: String, val name: String, val typ: String, val nebenzeile: String,
    /** „2026 · 1 Std. 52 Min." ohne Gattung — fuer den Fernseher (`TvDetailkopf`). */
    val jahrLaufzeit: String, val kopfbild: String?,
    val bewertung: Double?, val freigabe: String?,
    /** Es gibt einen Abspielplan — ohne ihn bleiben die Knoepfe gesperrt. */
    val planDa: Boolean, val lossless: Boolean, val methode: String?,
    val fortsetzenAb: Double?, val fortsetzenText: String?,
    val beschreibung: String?, val regie: List<String>, val darsteller: List<Mitwirkender>,
    val gemerkt: Boolean, val gesehen: Boolean, val trailer: String?, val datei: Datei?,
    /** Nur fuer den Fernseher — siehe `Kachel.kulisse`. */
    val kulisse: String? = null,
    /** „Noch 25 Min." unter dem Hauptknopf, und der Anteil fuer den Balken darunter. */
    val restzeit: String? = null,
    val fortschritt: Double? = null,
)

internal fun JSONObject.feldText(feld: String): String? = if (isNull(feld)) null else getString(feld)
internal fun JSONObject.feldZahl(feld: String): Double? = if (isNull(feld)) null else getDouble(feld)
internal fun JSONObject.feldTexte(feld: String): List<String> =
    optJSONArray(feld)?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
internal fun <T> JSONObject.feldListe(feld: String, lesen: (JSONObject) -> T): List<T> =
    optJSONArray(feld)?.let { a -> (0 until a.length()).map { lesen(a.getJSONObject(it)) } } ?: emptyList()

internal fun titelLesen(json: String): Titel = JSONObject(json).let { o ->
    Titel(o.getString("id"), o.getString("name"), o.optString("typ"), o.optString("nebenzeile"),
          o.optString("jahrLaufzeit"), o.feldText("kopfbild"),
          o.feldZahl("bewertung"), o.feldText("freigabe"),
          o.optBoolean("planDa"), o.optBoolean("lossless"), o.feldText("methode"),
          o.feldZahl("fortsetzenAb"), o.feldText("fortsetzenText"),
          o.feldText("beschreibung"), o.feldTexte("regie"),
          o.feldListe("darsteller") { Mitwirkender(it.getString("id"), it.getString("name"), it.feldText("rolle"), it.feldText("bild")) },
          o.optBoolean("gemerkt"), o.optBoolean("gesehen"), o.feldText("trailer"),
          o.optJSONObject("datei")?.let { d ->
              Datei(d.feldText("container"), d.feldText("video"), d.feldTexte("ton"), d.optString("untertitel"), d.optBoolean("hatUntertitel"))
          }, if (o.has("kulisse")) o.feldText("kulisse") else null,
          o.feldText("restzeit"), o.feldZahl("fortschritt"))
}

/** Die Fassade meldet „nicht angemeldet" als Kennung, weil der Wortlaut im App-Katalog steht. */
internal fun fehlertext(grund: String) = if (grund == "nichtAngemeldet") uebersetzt("Nicht angemeldet.") else grund

/**
 * **Der Satz fuer eine gefangene Ausnahme** — nie `e.message` roh (Audit T2-M6).
 *
 * Ohne Netz zuerst „Keine Verbindung.": curl meldet dann nur, der Name sei nicht aufloesbar, und
 * daraus wuerde „kein Server unter dieser Adresse" — falsch, die Adresse stimmt ja. Eine Ausnahme
 * aus dem Kern ist **genau** `java.lang.Exception` (swift-java `throwAsException`), und deren
 * Nachricht hat die Fassade schon ueber `lesbarerFehler` gebildet. Alles andere entsteht in Kotlin
 * (Netz im Download, eine kaputte Antwort) und bekommt einen festen Satz.
 */
internal fun fehlertext(kontext: android.content.Context, fehler: Throwable): String {
    val netz = kontext.getSystemService(android.net.ConnectivityManager::class.java)
    val online = runCatching {
        netz?.activeNetwork?.let { netz.getNetworkCapabilities(it) }
            ?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
    }.getOrDefault(true)
    if (!online) return uebersetzt("Keine Verbindung.")
    if (fehler.javaClass == Exception::class.java) fehler.message?.takeIf { it.isNotBlank() }?.let { return it }
    if (fehler is java.io.IOException) return uebersetzt("Der Server hat nicht geantwortet.")
    return uebersetzt("Fehlgeschlagen")
}

/**
 * Vorlage: `ItemDetailView` in `Sources/Shared/BrowseViews.swift`, schmale Fassung.
 *
 * **Kein Ring, keine Fehlerseite** — wie auf iOS: die Seite steht sofort mit dem, was der
 * Tipp mitbrachte, und wird still vervollstaendigt. Gemerkt wird der letzte Stand in der App,
 * damit das Zurueckkehren aus einer tieferen Seite nicht erneut aufbaut.
 */
@Composable
fun TitelSeite(app: SwiftlyAnwendung, ziel: Ziel, oeffnen: (Ziel) -> Unit, zurueck: () -> Unit) {
    var titel by remember(ziel.id) { mutableStateOf(app.titelSpeicher[ziel.id]) }
    var aehnliche by remember(ziel.id) { mutableStateOf<List<Rasterkachel>>(emptyList()) }
    var extras by remember(ziel.id) { mutableStateOf<List<Extra>>(emptyList()) }
    var aehnlicheGestoert by remember(ziel.id) { mutableStateOf(false) }
    var umfeldVersuch by remember(ziel.id) { mutableIntStateOf(0) }
    var gemerkt by remember(ziel.id) { mutableStateOf(titel?.gemerkt ?: false) }
    var gesehen by remember(ziel.id) { mutableStateOf(titel?.gesehen ?: false) }
    var meldung by remember { mutableStateOf<String?>(null) }
    val bereich = rememberCoroutineScope()
    val kontext = LocalContext.current
    val ruck = rememberRuck()

    suspend fun auffrischen() {
        try {
            val neu = titelLesen(withContext(Dispatchers.IO) { app.kern.titel(ziel.id).await() })
            titel = neu
            app.titelSpeicher[ziel.id] = neu
            gemerkt = neu.gemerkt
            gesehen = neu.gesehen
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }

    LaunchedEffect(ziel.id) { auffrischen() }
    LaunchedEffect(ziel.id, umfeldVersuch) {
        try {
            val o = JSONObject(withContext(Dispatchers.IO) { app.kern.titelUmfeld(ziel.id).await() })
            aehnliche = o.feldListe("aehnliche") { rasterkachelLesen(it) }
            extras = o.feldListe("extras") { Extra(it.getString("id"), it.getString("name"), it.feldText("bild"), it.feldText("laufzeit")) }
            aehnlicheGestoert = false
        } catch (e: CancellationException) { throw e } catch (_: Exception) { aehnlicheGestoert = aehnliche.isEmpty() }
    }

    // Nach dem Schauen neu laden: Fortschritt, Gesehen und Plan haben sich geaendert.
    val spielt = app.spiel.value != null
    var hatGespielt by remember { mutableStateOf(false) }
    LaunchedEffect(spielt) { if (spielt) hatGespielt = true else if (hatGespielt) { hatGespielt = false; auffrischen() } }
    // Und noch einmal, wenn die Endmeldung durch ist — erst dann kennt der Server die Stelle.
    val beendet = app.wiedergabeBeendet.intValue
    val beendetAnfangs = remember { beendet }
    LaunchedEffect(beendet) { if (beendet != beendetAnfangs) auffrischen() }

    /** Erst umschalten, dann fragen; sagt der Server nein, zurueck und melden — wie auf iOS. */
    fun umschalten(an: Boolean, setzen: (Boolean) -> Unit, frage: suspend (Boolean) -> String, merken: (Titel, Boolean) -> Titel) {
        ruck(Ruck.Leicht)
        setzen(an)
        bereich.launch {
            val grund = withContext(Dispatchers.IO) { frage(an) }
            if (grund.isNotEmpty()) { setzen(!an); meldung = fehlertext(grund) }
            else app.titelSpeicher[ziel.id]?.let { app.titelSpeicher[ziel.id] = merken(it, an) }
        }
    }

    val scroll = rememberScrollState()
    val dichte = LocalDensity.current.density
    val t = titel
    val name = t?.name ?: ziel.name

    Box(Modifier.fillMaxSize().background(Stil.grund)) {
        Column(Modifier.fillMaxSize().verticalScroll(scroll)) {
            Held(t?.kopfbild, name, t?.nebenzeile.orEmpty())

            Column(Modifier.padding(horizontal = Stil.randAbstand).padding(top = 14.dp),
                   verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Belegzeile(t)
                // **Knopf und Aktionsreihe als ein Block**: 8 zwischen ihnen, 14 zu allem anderen.
                Column(Modifier.padding(bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Spielknoepfe(t) { ab -> ruck(Ruck.Mittel); app.spiel.value = Abspielwunsch(ziel.id, ab) }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Aktionsknopf(if (gemerkt) Zeichen.LesezeichenVoll else Zeichen.Lesezeichen, uebersetzt("Merkliste"), gemerkt) {
                        umschalten(!gemerkt, { gemerkt = it }, { app.kern.merken(ziel.id, it).await() }) { alt, an -> alt.copy(gemerkt = an) }
                    }
                    // Das fuenfte Feld, nur wenn die Funktion an ist — neben der Merkliste: das Paar „fuer spaeter".
                    if (app.einstellungen.downloadKnopfZeigen && t?.typ != "Series") Downloadfeld(app, ziel.id, name)
                    // Der Trailer vom Server laeuft auf iOS im eigenen Player — der folgt; bis dahin der fremde.
                    Aktionsknopf(Zeichen.Film, uebersetzt("Trailer"), false) {
                        val adresse = t?.trailer
                        val ging = adresse != null && runCatching {
                            kontext.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(adresse)))
                        }.isSuccess
                        if (!ging) meldung = uebersetzt("Für diesen Titel liegt kein Trailer vor.")
                    }
                    Aktionsknopf(if (gesehen) Zeichen.HakenKreisVoll else Zeichen.HakenKreis, uebersetzt("Gesehen"), gesehen) {
                        umschalten(!gesehen, { gesehen = it }, { app.kern.gesehen(ziel.id, it).await() }) { alt, an -> alt.copy(gesehen = an) }
                    }
                    Aktionsknopf(Zeichen.Mehr, uebersetzt("Mehr"), false) {
                        // `Titelhandlungen.fuerFilm`.
                        val eintraege = buildList {
                            if (t != null && t.planDa && t.fortsetzenAb != null) {
                                add(Wahl("vonvorn", uebersetzt("Von vorn abspielen")))
                                add(Wahl("zuruecksetzen", uebersetzt("Fortschritt zurücksetzen")))
                            }
                            add(Wahl("metadaten", uebersetzt("Metadaten neu einlesen")))
                        }
                        app.blatt.value = Blattwunsch(name, eintraege, null,
                            mapOf("vonvorn" to Zeichen.Zurueckspulen, "zuruecksetzen" to Zeichen.RuecksetzenKreis, "metadaten" to Zeichen.Neuladen)) { wahl ->
                            bereich.launch {
                                when (wahl) {
                                    "vonvorn" -> app.spiel.value = Abspielwunsch(ziel.id, null)
                                    "zuruecksetzen" -> {
                                        val grund = withContext(Dispatchers.IO) { app.kern.gesehen(ziel.id, false).await() }
                                        if (grund.isNotEmpty()) meldung = fehlertext(grund)
                                        else { meldung = uebersetzt("Der Fortschritt ist zurückgesetzt."); auffrischen() }
                                    }
                                    "metadaten" -> {
                                        val grund = withContext(Dispatchers.IO) { app.kern.metadatenAuffrischen(ziel.id).await() }
                                        meldung = if (grund.isEmpty()) uebersetzt("Der Server liest die Metadaten neu ein.") else fehlertext(grund)
                                    }
                                }
                            }
                        }
                    }
                }
                }
                // `beschreibung`: Klapptext, 8 darunter „Regie" in 12, 5 dazwischen.
                t?.beschreibung?.let { text ->
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Klapptext(text)
                        if (t.regie.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                            Text(uebersetzt("Regie"), style = Stil.klein, color = Stil.schriftLeise)
                            Text(t.regie.joinToString(", "), style = Stil.klein, color = Stil.schrift)
                        }
                    }
                }
            }

            if (t != null && t.darsteller.isNotEmpty()) Abschnitt(uebersetzt("Besetzung"), 14.dp) {
                // Ohne Schluessel: dieselbe Person kann zweimal mitspielen.
                items(t.darsteller) { p -> Besetzungskachel(p) { oeffnen(Ziel(p.id, p.name, "Person", p.rolle, name)) } }
            }
            if (extras.isNotEmpty()) Abschnitt(uebersetzt("Extras"), 12.dp) {
                items(extras) { e -> Extrakachel(e) }
            }
            // Ueber „Aehnliche Titel": die Sammlung ist die naehere Verwandtschaft. Nur bei Titeln,
            // die in einer stehen (`Sammlungsreihe`).
            Sammlungsreihe(app, ziel.id, oeffnen)
            if (aehnliche.isNotEmpty()) Abschnitt(uebersetzt("Ähnliche Titel"), Stil.kachelAbstand) {
                items(aehnliche) { k -> RasterKachelAnsicht(k, Modifier.width(Stil.kachelBreite)) { oeffnen(Ziel(k.id, k.titel, k.typ)) } }
            } else if (aehnlicheGestoert) {
                // Nur dieser Abschnitt hat nicht geantwortet — die Serverformel fuer ihn allein.
                Column(Modifier.padding(top = Stil.reihenAbstand), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(uebersetzt("Ähnliche Titel"), style = Stil.reihe, color = Stil.schrift, modifier = Modifier.padding(horizontal = Stil.randAbstand))
                    Stoerhinweis(app.serveradresse(), abstandOben = 0.dp, erneut = { umfeldVersuch++ })
                }
            }
            t?.datei?.let { Dateiauszug(it) }
            Spacer(Modifier.navigationBarsPadding().height(24.dp))
        }

        Detailkopf(name, { ((scroll.value / dichte - 150f) / 70f).coerceIn(0f, 1f) }, zurueck)
        Hinweisstreifen(meldung, Modifier.align(Alignment.BottomCenter)) { meldung = null }
    }
}

/** Vorlage: `Heldbild` + `Heldauslauf` — 300 hoch, Verlauf 190, Titel und Nebenzeile unten links. */
@Composable
internal fun Held(bild: String?, name: String, nebenzeile: String) {
    Box(Modifier.fillMaxWidth().height(Stil.heldHoehe)) {
        AsyncImage(model = bild, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        Heldauslauf(Modifier.align(Alignment.BottomStart))
        Column(Modifier.align(Alignment.BottomStart).padding(horizontal = Stil.randAbstand).padding(bottom = 16.dp),
               verticalArrangement = Arrangement.spacedBy(4.dp)) {
            // **Der Titel ueber einem Heldbild *ist* der Seitentitel** — dieselbe Stufe wie
            // „Einstellungen" (BRAND 2). Die Sperrung bringt die Stufe schon mit.
            Text(name, style = Stil.titel, color = Stil.schrift)
            // **Die Nebenzeile haelt ihren Platz, auch solange sie leer ist.** Der Titel steht sofort
            // da (aus dem Ziel), die Nebenzeile erst nach dem Laden — und die Spalte haengt unten.
            // Kam die Zeile nachtraeglich dazu, rutschte der Titel um eine Zeilenhoehe nach oben.
            Text(nebenzeile.ifEmpty { " " }, style = Stil.klein, color = Stil.schriftLeise,
                 maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** Vorlage: `Heldauslauf` — 190 hoch, damit der Titel auch auf hellen Plakaten nicht blank steht (war 130). */
@Composable
internal fun Heldauslauf(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(190.dp).background(Brush.verticalGradient(
        0f to Stil.grund.copy(alpha = 0f), 0.32f to Stil.grund.copy(alpha = 0.28f), 0.56f to Stil.grund.copy(alpha = 0.58f),
        0.78f to Stil.grund.copy(alpha = 0.85f), 1f to Stil.grund)))
}

/**
 * Vorlage: `Belegzeile` — Direct Play oder der Grund, Bewertung, Freigabe. **Mindesthoehe 26 und
 * als Ganzes eingeblendet**, damit der Knopf darunter nicht nachrutscht.
 */
@Composable
private fun Belegzeile(t: Titel?) =
    Belegzeile(t != null, t?.planDa == true, t?.lossless == true, t?.methode, t?.bewertung, t?.freigabe)

@Composable
internal fun Belegzeile(geladen: Boolean, planDa: Boolean, lossless: Boolean, methode: String?, bewertung: Double?, freigabe: String?,
                        /** Ein freier Beleg statt des Wiedergabeplans — auf der Seerr-Seite der Stand. */
                        eigen: Triple<Zeichen, String, Color>? = null) {
    val sichtbar by animateFloatAsState(if (geladen) 1f else 0f, Bewegung.einblenden(), label = "beleg")
    // 8 zwischen den Huellen wie auf iOS — 14 galt, solange die Bewertung ohne Huelle stand.
    Row(Modifier.heightIn(min = 26.dp).alpha(sichtbar), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (eigen != null) {
            val (zeichen, wort, farbe) = eigen
            Belegmarke(zeichen, wort, farbe, Staerke.Halbfett)
        } else if (planDa) {
            // Direct Play traegt den Haken halbfett, der Hinweis das Dreieck regular.
            val farbe = if (lossless) Stil.akzent else Stil.warnung
            Belegmarke(if (lossless) Zeichen.Haken else Zeichen.Warnung, if (lossless) "Direct Play" else methode.orEmpty(),
                       farbe, if (lossless) Staerke.Halbfett else Staerke.Normal)
        }
        // **In derselben Huelle wie Direct Play** (Vorlage 7d55a810): vorher stand die Bewertung als einzige
        // Angabe der Zeile nackt da. Stern halbfett in `schriftLeise`.
        bewertung?.let { b ->
            Belegmarke(Zeichen.SternVoll, String.format(Locale.ROOT, "%.1f", b).replace('.', ','), Stil.schriftLeise, Staerke.Halbfett)
        }
        freigabe?.takeIf { it.isNotBlank() }?.let {
            // `Plakette`: 13 Medium `schriftLeise` auf 15 % derselben Farbe, 10/4 innen, Ecke 8.
            Text(it, style = Stil.kachel, color = Stil.schriftLeise,
                 modifier = Modifier.clip(RoundedCornerShape(Stil.eckeKlein)).background(Stil.schriftLeise.copy(alpha = 0.15f))
                     .padding(horizontal = 10.dp, vertical = 4.dp))
        }
    }
}

/**
 * Vorlage: `hauptknopf` — **ein Knopf, nicht zwei**: „Fortsetzen ab …" oder „Abspielen". „Von vorn"
 * steht im Mehr-Blatt; ein zweiter Knopf darunter war doppelt. Darunter, 9 Abstand, die Restzeit in
 * 12 und der Fortschritt. Ohne Plan gesperrt.
 */
@Composable
private fun Spielknoepfe(t: Titel?, spielen: (Double?) -> Unit) {
    val bereit = t?.planDa == true
    Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
        val ab = t?.fortsetzenText
        if (ab != null) Spielknopf(Zeichen.Abspielen, uebersetzt("Fortsetzen ab %@", ab), bereit, haupt = true) { spielen(t.fortsetzenAb) }
        else Spielknopf(Zeichen.Abspielen, uebersetzt("Abspielen"), bereit, haupt = true) { spielen(null) }
        t?.restzeit?.let { Text(it, style = Stil.klein, color = Stil.schriftLeise) }
        t?.fortschritt?.takeIf { it > 0 }?.let { Fortschrittsbalken(it, Modifier.clip(RoundedCornerShape(2.dp))) }
    }
}

/**
 * Vorlage: `HauptknopfStil` / `NebenknopfStil` — 48 hoch, Ecke 10. **Weiss, nie Akzent**: der
 * Akzent traegt Zustand (E2), keine Knopffarbe.
 */
@Composable
internal fun Spielknopf(symbol: Zeichen, text: String, an: Boolean, haupt: Boolean,
                        /** Gesperrt auf einem Blatt in `flaeche` braucht der Knopf `erhoeht` — sonst bleibt nur leise Schrift. */
                        gesperrtFlaeche: Color = Stil.flaeche, tun: () -> Unit) {
    val quelle = remember { MutableInteractionSource() }
    val gedrueckt by quelle.collectIsPressedAsState()
    // `HauptknopfStil`: weiss, gedrueckt 75 %; `NebenknopfStil`: 10 %, gedrueckt 16 %. Sofort an, 120 ms aus.
    val druck = remember { Animatable(0f) }
    LaunchedEffect(gedrueckt) { if (gedrueckt) druck.snapTo(1f) else druck.animateTo(0f, Bewegung.loslassen()) }
    val farbe = when { !an -> Stil.schriftSehrLeise; haupt -> Stil.grund; else -> Stil.schrift }
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(RoundedCornerShape(Stil.ecke))
            .drawBehind {
                drawRect(when {
                    !an -> gesperrtFlaeche
                    // Haupt: Weiss, gedrueckt auf 75 Prozent. Neben: `flaeche`, gedrueckt
                    // `gedruecktFlaeche` — zwei benannte Toene statt zweier gerechneter.
                    haupt -> Color.White.copy(alpha = 1f - 0.25f * druck.value)
                    else -> androidx.compose.ui.graphics.lerp(Stil.flaeche, Stil.gedruecktFlaeche, druck.value)
                })
            }
            .then(if (an) Modifier.clickable(quelle, null, onClick = tun) else Modifier),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically) {
        // Das Zeichen traegt die Schrift des Knopfs: 17 Semibold am Hauptknopf, 15 Medium am Nebenknopf.
        Symbol(symbol, if (haupt) 17.dp else 15.dp, farbe = farbe, staerke = if (haupt) Staerke.Halbfett else Staerke.Mittel)
        // Hauptknopf 17 Semibold, Nebenknopf 15 Medium (BAUTEILE 6) — 16 stand in keiner Leiter.
        Text(text, style = if (haupt) Stil.rubrikGross else Stil.knopftext, color = farbe)
    }
}

/** Vorlage: `Aktionsknopf` — 44 hoch, Flaeche, Ecke 10, aktiv im Akzent. */
@Composable
internal fun RowScope.Aktionsknopf(symbol: Zeichen, beschreibung: String, aktiv: Boolean, tun: () -> Unit) {
    // **Alle Felder einer Reihe tragen dieselben Masse: 48 × 48** (BRAND 7). Sie standen auf 44.
    Box(Modifier.weight(1f).height(Stil.knopfHoehe).clip(RoundedCornerShape(Stil.ecke)).background(Stil.flaeche).antippen(tun)
            .semantics { selected = aktiv; role = androidx.compose.ui.semantics.Role.Button },
        contentAlignment = Alignment.Center) {
        // `Stil.rubrikGross`: 17 Semibold.
        Symbol(symbol, 17.dp, farbe = if (aktiv) Stil.akzent else Stil.schrift, staerke = Staerke.Halbfett, beschreibung = beschreibung)
    }
}

/** Vorlage: `Klapptext` — eine Zeile mit Pfeil, aufgeklappt ganz. Der volle Text war zu schwer fuer die Seite. */
@Composable
internal fun Klapptext(text: String) {
    var offen by remember { mutableStateOf(false) }
    val drehung by animateFloatAsState(if (offen) 180f else 0f, Bewegung.sprung(), label = "pfeil")
    // `Druckzeile`, nicht Druckknopf: ein Absatz schrumpft nicht. Text in voller Schrift, 15 mit 3 Luft.
    Row(Modifier.fillMaxWidth().animateContentSize(Bewegung.sprung()).druckzeile { offen = !offen },
        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(text, style = Stil.koerper.copy(lineHeight = 21.sp), color = Stil.schrift,
             maxLines = if (offen) Int.MAX_VALUE else 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Symbol(Zeichen.WinkelRunter, 12.dp, Modifier.padding(top = 4.dp).graphicsLayer { rotationZ = drehung },
               farbe = Stil.schriftSehrLeise, staerke = Staerke.Halbfett)
    }
}

/** Vorlage: `Abschnitt` — 26 Abstand oben, Reihentitel, waagerechte Reihe. */
@Composable
internal fun Abschnitt(titel: String, abstand: Dp, inhalt: LazyListScope.() -> Unit) {
    // `Abschnitt`: oben `reihenAbstand` (28), Reihentitel in der Sperrung seiner Stufe, 12 zur Reihe.
    Column(Modifier.padding(top = Stil.reihenAbstand), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(titel, style = Stil.reihe, color = Stil.schrift,
             modifier = Modifier.padding(horizontal = Stil.randAbstand))
        LazyRow(contentPadding = PaddingValues(horizontal = Stil.randAbstand),
                horizontalArrangement = Arrangement.spacedBy(abstand), content = inhalt)
    }
}

/** Vorlage: `Besetzungskachel` — Kreis 76, Name zweizeilig, Rolle, 84 breit. */
@Composable
internal fun Besetzungskachel(p: Mitwirkender, tun: () -> Unit = {}) {
    // Ohne Bild bleibt der Kreis leer — `Bild` traegt dort kein Zeichen.
    Column(Modifier.width(84.dp).antippen(tun), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(7.dp)) {
        AsyncImage(model = p.bild, contentDescription = null, contentScale = ContentScale.Crop,
            modifier = Modifier.size(76.dp).clip(CircleShape).background(Stil.flaeche))
        // Name 12 Medium — `Besetzungskachel`, nicht die 13 unter einem Plakat.
        Text(p.name, style = Stil.kachel.copy(fontSize = 12.sp, textAlign = TextAlign.Center),
             color = Stil.schrift, maxLines = 2, overflow = TextOverflow.Ellipsis)
        p.rolle?.let {
            Text(it, style = Stil.klein.copy(textAlign = TextAlign.Center), color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** Vorlage: `extrasreihe` — 210 × 118, Titel, Laufzeit nur wenn bekannt. */
@Composable
private fun Extrakachel(e: Extra) {
    Column(Modifier.width(210.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
        AsyncImage(model = e.bild, contentDescription = null, contentScale = ContentScale.Crop,
                   modifier = Modifier.size(210.dp, 118.dp).clip(RoundedCornerShape(Stil.eckeKachel)).background(Stil.flaeche))
        Text(e.name, style = Stil.kachel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis)
        e.laufzeit?.let { Text(it, style = Stil.klein, color = Stil.schriftSehrLeise, maxLines = 1) }
    }
}

/** Vorlage: `dateiauszug` — Container, Video, bis zu zwei Tonspuren, Untertitel; Ton im Akzent. */
@Composable
private fun Dateiauszug(d: Datei) {
    // Gruppentitel oben 22, dann eine Linie ueber und unter jeder Zeile; Werte in voller Schrift,
    // rechtsbuendig mit gleich breiten Ziffern (`Dateizeile`), senkrecht 8.
    Column(Modifier.padding(horizontal = Stil.randAbstand).padding(top = 22.dp)) {
        // `Gruppentitel` bringt seinen Seitenrand mit — am iPhone steht er dadurch eine Stufe
        // eingerueckt ueber den Zeilen; so auch hier.
        Text(uebersetzt("Datei"), style = Stil.reihe,
             color = Stil.schriftLeise, modifier = Modifier.padding(start = Stil.randAbstand, bottom = 10.dp))
        val zeilen = buildList {
            d.container?.let { add(uebersetzt("Container") to it) }
            d.video?.let { add(uebersetzt("Video") to it) }
            // Die zweite Tonzeile wiederholt die Beschriftung nicht.
            d.ton.forEachIndexed { i, ton -> add((if (i == 0) uebersetzt("Ton") else " ") to ton) }
            add(uebersetzt("Untertitel") to d.untertitel)
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.linie))
        zeilen.forEach { (name, wert) ->
            Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Text(name, style = Stil.klein, color = Stil.schriftLeise)
                Spacer(Modifier.weight(1f))
                Text(wert, style = Stil.klein.copy(textAlign = TextAlign.End, fontFeatureSettings = "tnum"), color = Stil.schrift)
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.linie))
        }
    }
}

/**
 * Vorlage: `Detailkopf` — Zurueck links, Titel blendet ab 150 ueber 70 Punkt ein, der Verlauf
 * ueber dem Bild geht dabei in den Grund ueber, die Haarlinie kommt mit. Die Staerke wird nur
 * in der Zeichenphase gelesen: so zeichnet Scrollen die Seite nicht neu.
 */
@Composable
internal fun Detailkopf(titel: String, staerke: () -> Float, zurueck: () -> Unit,
                        /** Ein Knopf rechts, etwa Bearbeiten — ohne ihn haelt ein leeres Feld von 44 den Titel mittig. */
                        rechts: (@Composable () -> Unit)? = null) {
    Box(Modifier.fillMaxWidth()
            // Ueber dem Heldbild der Kopfverlauf mit 70 %, der mit der Leiste weicht.
            .drawBehind { kopfverlauf(0.7f * (1f - staerke())) }) {
        // **Glas am iPhone, deckender Grund hier** — Plattform: Compose kann nicht weichzeichnen, was
        // hinter einer Ansicht liegt (`RenderEffect` wirkt nur auf die eigene Ebene). Ein Grund, der
        // mit der Leiste aufzieht, traegt den Titel ebenso.
        Box(Modifier.matchParentSize().graphicsLayer { alpha = staerke() }.background(Stil.grund))
        Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(1.dp).graphicsLayer { alpha = staerke() }.background(Stil.linie))
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(start = 8.dp, end = Stil.randAbstand, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(44.dp).antippen(zurueck), contentAlignment = Alignment.Center) {
                Symbol(Zeichen.WinkelLinks, 20.dp, farbe = Stil.schrift, staerke = Staerke.Halbfett, beschreibung = uebersetzt("Zurück"))
            }
            Text(titel, style = Stil.rubrikGross, color = Stil.schrift,
                 maxLines = 1, overflow = TextOverflow.Ellipsis,
                 modifier = Modifier.weight(1f).padding(horizontal = 4.dp).graphicsLayer { alpha = staerke() }.clearAndSetSemantics {})
            // Rechts derselbe Platz wie der Pfeil links — so steht der Titel nicht schief.
            if (rechts != null) rechts() else Spacer(Modifier.width(44.dp))
        }
    }
}

/** Vorlage: `Hinweisstreifen` — Kapsel unten, geht nach drei Sekunden von selbst. */
@Composable
internal fun Hinweisstreifen(text: String?, modifier: Modifier, schliessen: () -> Unit) {
    LaunchedEffect(text) { if (text != null) { delay(3000); schliessen() } }
    val gemerkt = remember { arrayOfNulls<String>(1) }
    if (text != null) gemerkt[0] = text
    // Mit einem Viertel der eigenen Hoehe Weg — eine reine Ueberblendung tauchte aus dem Nichts auf.
    AnimatedVisibility(text != null, modifier,
        enter = fadeIn(tween(200, easing = Bewegung.weich)) + slideInVertically(tween(200, easing = Bewegung.weich)) { it / 4 },
        exit = fadeOut(tween(150, easing = Bewegung.weich)) + slideOutVertically(tween(150, easing = Bewegung.weich)) { it / 4 }) {
        // Ein Streifen aus `flaeche`, **ohne Rand** — die Flaeche ist schon der Gegenstand.
        Text(gemerkt[0].orEmpty(), style = Stil.koerper.copy(textAlign = TextAlign.Center), color = Stil.schrift,
             modifier = Modifier.navigationBarsPadding().padding(start = 24.dp, end = 24.dp, bottom = 34.dp).clip(CircleShape).background(Stil.flaeche)
                 .padding(horizontal = 18.dp, vertical = 12.dp))
    }
}

/**
 * **Die Huelle, in der alle Belege stecken** — Vorlage `marke(...)` in `Belegzeile`: Zeichen 11, Wort 13 Medium,
 * 6 dazwischen, links 8, rechts 10, oben/unten 4, Flaeche 15 % der Farbe, Ecke `eckeKlein`. Eine Huelle, nicht
 * drei — genau daran ist diese Zeile schon einmal auseinandergelaufen.
 */
@Composable
private fun Belegmarke(zeichen: Zeichen, wort: String, farbe: Color, staerke: Staerke) {
    Row(Modifier.clip(RoundedCornerShape(Stil.eckeKlein)).background(farbe.copy(alpha = 0.15f))
            .padding(start = 8.dp, end = 10.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Symbol(zeichen, 11.dp, farbe = farbe, staerke = staerke)
        Text(wort, style = Stil.kachel, color = farbe)
    }
}
