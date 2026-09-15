package de.paulherter.swiftly

import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBackIosNew
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import de.paulherter.swiftly.gemeinsam.Stil
import androidx.compose.animation.core.Animatable
import de.paulherter.swiftly.gemeinsam.Bewegung
import kotlinx.coroutines.launch
import de.paulherter.swiftly.gemeinsam.uebersetzt
import org.json.JSONArray
import kotlin.reflect.KProperty

/** Ein gemerkter Wert — Zustand fuer Compose, geschrieben in die Ablage bei jeder Aenderung. */
private class Merkwert<T>(private val ablage: Ablage, private val schluessel: String, anfang: T, private val schreiben: (T) -> String) {
    private val zustand = mutableStateOf(anfang)
    operator fun getValue(besitzer: Any?, eigenschaft: KProperty<*>): T = zustand.value
    operator fun setValue(besitzer: Any?, eigenschaft: KProperty<*>, wert: T) {
        zustand.value = wert
        ablage.merken(schluessel, schreiben(wert))
    }
}

/**
 * **Die Einstellungen — dieselben Schluessel und Vorgaben wie `AppModel` auf iOS**
 * (`immerDirectPlay`, `bitratenGrenze`, `startReihen`, …). Was welche Werte annehmen darf,
 * steht im Paket (`Bitrate`, `Spanne`, `Pufferstufe`, `Sprachwahl`, `Startreihenfolge`).
 * Downloads, Seerr und Technikschild fehlen, bis es sie auf Android gibt.
 */
class Einstellungen(ablage: Ablage) {
    private val a = ablage
    private fun bool(k: String, vorgabe: Boolean) = a.merkwert(k)?.let { it == "1" } ?: vorgabe
    private fun zahl(k: String, vorgabe: Int) = a.merkwert(k)?.toIntOrNull() ?: vorgabe
    private fun liste(k: String) = a.merkwert(k)?.let { roh ->
        runCatching { JSONArray(roh).let { j -> (0 until j.length()).map { j.getString(it) } } }.getOrNull()
    } ?: emptyList()
    private val jaNein: (Boolean) -> String = { if (it) "1" else "0" }
    private val alsListe: (List<String>) -> String = { JSONArray(it).toString() }

    /** Nie umwandeln lassen. Der Grund fuer diese App — deshalb Vorgabe an. */
    var immerDirectPlay by Merkwert(a, "immerDirectPlay", bool("immerDirectPlay", true), jaNein)
    /** Mbit/s, 0 heisst unbegrenzt. Greift nur ohne erzwungenes Direct Play. */
    var bitratenGrenze by Merkwert(a, "bitratenGrenze", zahl("bitratenGrenze", 0)) { it.toString() }
    var querformatFest by Merkwert(a, "querformatFest", bool("querformatFest", true), jaNein)
    var fortschritt by Merkwert(a, "fortschritt", bool("fortschritt", true), jaNein)
    /** Leer heisst: wie die Datei. */
    var tonSprache by Merkwert(a, "tonSprache", a.merkwert("tonSprache").orEmpty()) { it }
    /** Leer heisst: aus. */
    var untertitelSprache by Merkwert(a, "utSprache", a.merkwert("utSprache").orEmpty()) { it }
    var untertitelAutomatisch by Merkwert(a, "utAuto", bool("utAuto", false), jaNein)
    var naechsteAutomatisch by Merkwert(a, "naechsteAuto", bool("naechsteAuto", true), jaNein)
    var neuzugangGetrennt by Merkwert(a, "neuGetrennt", bool("neuGetrennt", true), jaNein)
    var startReihen by Merkwert(a, "startReihen", liste("startReihen"), alsListe)
    var startAus by Merkwert(a, "startAus", liste("startAus"), alsListe)
    var startGenres by Merkwert(a, "startGenres", liste("startGenres"), alsListe)
    /** Genres als Chips ueber den Reihen statt als eigene Reihen — nie beides. */
    var genreChips by Merkwert(a, "genreChips", bool("genreChips", false), jaNein)
    /** H1: aus, bis jemand es will. */
    var downloadsAn by Merkwert(a, "downloadsAn", bool("downloadsAn", false), jaNein)
    /** H5: Originaldateien sind gross — ueber Mobilfunk wird gewartet. */
    var nurUeberWLAN by Merkwert(a, "nurUeberWLAN", bool("nurUeberWLAN", true), jaNein)
    var pufferstufe by Merkwert(a, "pufferstufe", a.merkwert("pufferstufe") ?: "normal") { it }
    var zurueckSekunden by Merkwert(a, "zurueckSek", zahl("zurueckSek", 10)) { it.toString() }
    var vorSekunden by Merkwert(a, "vorSek", zahl("vorSek", 30)) { it.toString() }
    /** Aus, bis ihn jemand sucht — er aendert nichts an der Wiedergabe, er zeigt nur, was sie tut. */
    var technikschild by Merkwert(a, "technikschild", bool("technikschild", false), jaNein)
}

/** Liest eine Wahlliste der Fassade: `[{"wert","text"}]`. */
fun wahlenLesen(json: String): List<Wahl> = JSONArray(json).let { a ->
    (0 until a.length()).map { a.getJSONObject(it).let { o -> Wahl(o.getString("wert"), o.getString("text")) } }
}

/** Ob Kacheln ihren Fortschrittsbalken zeigen — „Fortschritt auf Kacheln". */
val LocalFortschrittZeigen = compositionLocalOf { true }

// MARK: Bausteine der Unterseiten

/** Vorlage: `Unterseitenkopf` — Zurueck 44, Titel 22 halbfett; so steht der Pfeil ueberall gleich weit vom Rand. */
@Composable
fun Unterseitenkopf(titel: String, zurueck: () -> Unit) {
    Row(Modifier.fillMaxWidth().statusBarsPadding().padding(start = 8.dp, end = 12.dp, bottom = 18.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(44.dp).antippen(zurueck), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.ArrowBackIosNew, contentDescription = uebersetzt("Zurück"), tint = Stil.schrift, modifier = Modifier.size(22.dp))
        }
        Text(titel, style = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.3).sp),
             color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Eine Unterseite: Kopf, darunter scrollender Inhalt bis an die Gestenleiste. */
@Composable
fun Einstellungsseite(titel: String, zurueck: () -> Unit, inhalt: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().background(Stil.grund)) {
        Unterseitenkopf(titel, zurueck)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 30.dp),
               content = inhalt)
    }
}

/** Vorlage: `Karte` — die eine erlaubte Flaeche auf Einstellungsseiten, Ecke 16. */
@Composable
fun Karte(inhalt: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = Stil.randAbstand).clip(RoundedCornerShape(Stil.eckeFlaeche))
               .background(Stil.flaeche), content = inhalt)
}

/** Vorlage: `Gruppentitel` — Grossbuchstaben, 11 halbfett, gesperrt. */
@Composable
fun Gruppentitel(text: String, modifier: Modifier = Modifier) {
    Text(text.uppercase(), style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.2.sp),
         color = Stil.schriftSehrLeise, modifier = modifier.fillMaxWidth().padding(horizontal = Stil.randAbstand).padding(bottom = 8.dp))
}

/** Vorlage: `Einstellungsgruppe` — Gruppentitel, darunter die Karte. */
@Composable
fun Einstellungsgruppe(titel: String, inhalt: @Composable ColumnScope.() -> Unit) {
    Column {
        Gruppentitel(titel, Modifier.padding(top = 26.dp))
        Karte(inhalt)
    }
}

/** Vorlage: `Trennlinie` in der Karte — Einzug 34, sie beginnt hinter dem Zeichen. */
@Composable
fun Trennlinie() {
    Box(Modifier.padding(start = 34.dp).fillMaxWidth().height(1.dp).background(Stil.linie))
}

/** Vorlage: `Fusszeile` unter einer Gruppe — 13, sehr leise. */
@Composable
fun Fusszeile(text: String) {
    Text(text, style = TextStyle(fontSize = 13.sp, lineHeight = 18.sp), color = Stil.schriftSehrLeise,
         modifier = Modifier.padding(horizontal = Stil.randAbstand * 2).padding(top = 8.dp))
}

/**
 * Vorlage: `Schalter` — eigener statt `Switch`: Apples bringt eigene Masse und Bewegung mit und
 * wirkt neben flachen Flaechen fremd. 46 × 28, der Knopf stanzt im Akzent ein Loch in den Grund.
 */
@Composable
fun Schalter(an: Boolean, aendern: (Boolean) -> Unit) {
    val lage by animateFloatAsState(if (an) 1f else 0f, tween(150, easing = EaseInOut), label = "schalter")
    Box(Modifier.size(46.dp, 28.dp).clip(CircleShape).background(lerp(Color.White.copy(alpha = 0.16f), Stil.akzent, lage))
            .antippen { aendern(!an) }.padding(3.dp)) {
        Box(Modifier.offset(x = 18.dp * lage).size(22.dp).clip(CircleShape).background(lerp(Color.White, Stil.grund, lage)))
    }
}

/** Vorlage: `Zeilenaufbau` — Zeichen 17 in 20, Titel 16, Unterzeile 13 bei 45 %, 14 Abstand. */
@Composable
private fun Zeilenaufbau(symbol: ImageVector, titel: String, unter: String?, farbe: Color, modifier: Modifier,
                         senkrecht: Int = 14, rechts: @Composable RowScope.() -> Unit) {
    Row(modifier.fillMaxWidth().padding(horizontal = Stil.randAbstand, vertical = senkrecht.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Icon(symbol, contentDescription = null, tint = farbe, modifier = Modifier.width(20.dp).height(19.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(titel, style = TextStyle(fontSize = 16.sp), color = farbe)
            unter?.let { Text(it, style = TextStyle(fontSize = 13.sp), color = Color.White.copy(alpha = 0.45f)) }
        }
        rechts()
    }
}

@Composable
private fun Pfeil() {
    Icon(Icons.Filled.KeyboardArrowRight, contentDescription = null, tint = Color.White.copy(alpha = 0.28f), modifier = Modifier.size(20.dp))
}

/** Vorlage: `Wahlzeile` — schaltet etwas um; die ganze Zeile nimmt den Tipp. */
@Composable
fun Wahlzeile(symbol: ImageVector, titel: String, unter: String? = null, an: Boolean, aendern: (Boolean) -> Unit) {
    Zeilenaufbau(symbol, titel, unter, Stil.schrift, Modifier.druckzeile { aendern(!an) }) { Schalter(an, aendern) }
}

/** Vorlage: `Wertzeile` — zeigt einen Wert und fuehrt, wenn antippbar, zu seiner Auswahl. Gedimmt, wenn er nicht greift. */
@Composable
fun Wertzeile(symbol: ImageVector, titel: String, unter: String? = null, wert: String? = null, gedimmt: Boolean = false, tun: (() -> Unit)? = null) {
    val farbe = if (gedimmt) Stil.schrift.copy(alpha = 0.4f) else Stil.schrift
    Zeilenaufbau(symbol, titel, unter, farbe, if (tun != null && !gedimmt) Modifier.druckzeile(tun) else Modifier) {
        wert?.let { Text(it, style = TextStyle(fontSize = 15.sp), color = if (gedimmt) Stil.schriftLeise.copy(alpha = 0.4f) else Stil.schriftLeise, maxLines = 1) }
        if (tun != null) Pfeil()
    }
}

/** Vorlage: `Profilzeile` — fuehrt woanders hin; Quick Connect steht im Akzent. */
@Composable
fun Profilzeile(symbol: ImageVector, titel: String, unter: String? = null, akzent: Boolean = false, tun: () -> Unit) {
    Zeilenaufbau(symbol, titel, unter, if (akzent) Stil.akzent else Stil.schrift, Modifier.druckzeile(tun), senkrecht = 15) { Pfeil() }
}

/**
 * **Umsortieren an einem Griff rechts** — das Gegenstueck zur Liste im Bearbeitungsmodus auf iOS.
 * Die Zeile folgt dem Finger; ueberquert sie die halbe Hoehe der Nachbarin, tauschen beide.
 */
@Composable
fun <T> Umsortierbar(eintraege: List<T>, schluessel: (T) -> String, verschieben: (T, Int) -> Unit,
                     zeile: @Composable (T) -> Unit) {
    val aktuell by rememberUpdatedState(eintraege)
    var gezogen by remember { mutableStateOf<String?>(null) }
    var zug by remember { mutableFloatStateOf(0f) }
    val ruck = rememberRuck()
    val lauf = rememberCoroutineScope()
    Column {
        eintraege.forEachIndexed { i, eintrag ->
            val kennung = schluessel(eintrag)
            if (i > 0) Trennlinie()
            key(kennung) {
                var hoehe by remember { mutableIntStateOf(1) }
                // Wer den Platz tauscht, ohne gezogen zu werden, gleitet an den neuen — der Tausch
                // ist die Rueckmeldung dieser Geste, ein Sprung saehe wie ein Fehler aus.
                val versatz = remember { Animatable(0f) }
                var vorher by remember { mutableIntStateOf(i) }
                LaunchedEffect(i) {
                    if (i != vorher && gezogen != kennung) {
                        versatz.snapTo((vorher - i) * hoehe.toFloat())
                        vorher = i
                        versatz.animateTo(0f, tween(150, easing = Bewegung.weich))
                    } else vorher = i
                }
                Row(Modifier.fillMaxWidth().onSizeChanged { hoehe = it.height }
                        .zIndex(if (gezogen == kennung) 1f else 0f)
                        .graphicsLayer { translationY = if (gezogen == kennung) zug else versatz.value }
                        .background(if (gezogen == kennung) Stil.erhoeht else Color.Transparent),
                    verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) { zeile(eintrag) }
                    Box(Modifier.size(44.dp).padding(end = 6.dp)
                            .pointerInput(kennung) {
                                fun loslassen() {
                                    val rest = zug
                                    gezogen = null
                                    zug = 0f
                                    // Auch das Loslassen gleitet an den Platz, statt zu springen.
                                    lauf.launch { versatz.snapTo(rest); versatz.animateTo(0f, tween(150, easing = Bewegung.weich)) }
                                }
                                detectVerticalDragGestures(
                                    onDragStart = { gezogen = kennung; zug = 0f },
                                    onDragEnd = { loslassen() },
                                    onDragCancel = { loslassen() },
                                    onVerticalDrag = { aenderung, d ->
                                        aenderung.consume()
                                        zug += d
                                        val liste = aktuell
                                        val stelle = liste.indexOfFirst { schluessel(it) == kennung }
                                        if (zug > hoehe / 2f && stelle in 0 until liste.lastIndex) {
                                            verschieben(liste[stelle], 1); zug -= hoehe; ruck(Ruck.Leicht)
                                        } else if (zug < -hoehe / 2f && stelle > 0) {
                                            verschieben(liste[stelle], -1); zug += hoehe; ruck(Ruck.Leicht)
                                        }
                                    })
                            },
                        contentAlignment = Alignment.Center) {
                        Icon(Icons.Filled.DragHandle, contentDescription = null, tint = Color.White.copy(alpha = 0.28f), modifier = Modifier.size(20.dp))
                    }
                }
            }
        }
    }
}
