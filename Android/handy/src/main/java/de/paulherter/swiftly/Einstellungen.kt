package de.paulherter.swiftly

import androidx.compose.foundation.layout.RowScope
import androidx.compose.ui.unit.Dp
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import androidx.compose.animation.core.EaseInOut
import de.paulherter.swiftly.kern.Kern
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.foundation.selection.toggleable
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
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
    /** `"1"`/`"0"`, leer: nie umgelegt — dann gilt das Konto (`naechsteAutomatischKonto`). */
    private var naechsteAutomatischWahl by Merkwert(a, "naechsteAuto", a.merkwert("naechsteAuto").orEmpty()) { it }
    /**
     * `EnableNextEpisodeAutoPlay` des geltenden Kontos, `"1"`/`"0"`/leer — nicht gespeichert, kommt je
     * Start und Kontowechsel frisch (`SwiftlyAnwendung.kontovorgabenHolen`).
     */
    var naechsteAutomatischKonto by mutableStateOf("")
    /** Regel im Paket (`Weiterschalten.gilt`): eigene Wahl vor Konto vor „an". Wie `AppModel` auf iOS. */
    var naechsteAutomatisch: Boolean
        get() = Kern.naechsteAutomatischGilt(naechsteAutomatischWahl, naechsteAutomatischKonto)
        set(wert) { naechsteAutomatischWahl = if (wert) "1" else "0" }
    var neuzugangGetrennt by Merkwert(a, "neuGetrennt", bool("neuGetrennt", true), jaNein)
    var startReihen by Merkwert(a, "startReihen", liste("startReihen"), alsListe)
    var startAus by Merkwert(a, "startAus", liste("startAus"), alsListe)
    var startGenres by Merkwert(a, "startGenres", liste("startGenres"), alsListe)
    /** Genres als Chips ueber den Reihen statt als eigene Reihen — nie beides. */
    var genreChips by Merkwert(a, "genreChips", bool("genreChips", false), jaNein)
    /** H1: aus, bis jemand es will. */
    var downloadsAn by Merkwert(a, "downloadsAn", bool("downloadsAn", false), jaNein)
    /**
     * `Policy.EnableContentDownloading` des geltenden Kontos, `"1"`/`"0"`/leer — nicht gespeichert,
     * kommt je Start und Kontowechsel frisch (`SwiftlyAnwendung.kontovorgabenHolen`).
     */
    var downloadrechtKonto by mutableStateOf("")
    /**
     * Ob ein Ladeknopf erscheint: Schalter **und** Recht am Konto. Regel im Paket
     * (`Downloadrecht.anbieten`), wie `AppModel.downloadKnopfZeigen` auf iOS. Der Reiter
     * „Downloads" und diese Zeile in den Einstellungen bleiben an `downloadsAn` — was auf dem
     * Telefon liegt, muss erreichbar bleiben, auch ohne Recht.
     */
    val downloadKnopfZeigen: Boolean
        get() = Kern.downloadKnopfZeigen(downloadrechtKonto, downloadsAn)
    /**
     * `Policy.EnableVideoPlaybackTranscoding` des geltenden Kontos, `"1"`/`"0"`/leer — nicht
     * gespeichert, kommt je Start und Kontowechsel frisch (`SwiftlyAnwendung.kontovorgabenHolen`).
     */
    var umwandelnErlaubtKonto by mutableStateOf("")
    /** Ohne Antwort vom Server: erlaubt — dann bleibt die Qualitätswahl im Player. */
    val umwandelnErlaubt: Boolean
        get() = umwandelnErlaubtKonto != "0"
    /** H5: Originaldateien sind gross — ueber Mobilfunk wird gewartet. */
    var nurUeberWLAN by Merkwert(a, "nurUeberWLAN", bool("nurUeberWLAN", true), jaNein)
    var pufferstufe by Merkwert(a, "pufferstufe", a.merkwert("pufferstufe") ?: "normal") { it }
    var zurueckSekunden by Merkwert(a, "zurueckSek", zahl("zurueckSek", 10)) { it.toString() }
    var vorSekunden by Merkwert(a, "vorSek", zahl("vorSek", 30)) { it.toString() }
    /** Aus, bis ihn jemand sucht — er aendert nichts an der Wiedergabe, er zeigt nur, was sie tut. */
    var technikschild by Merkwert(a, "technikschild", bool("technikschild", false), jaNein)
    /**
     * **Der Messmodus des Technikschilds** — alle Zeilen, ohne Hoechsthoehe. Kein Schalter: Werkzeug fuer die
     * Fehlersuche, nicht fuer Zuschauer (Vorlage `technikschildMessen`, dort ein Startargument). Gesetzt ueber
     * das Startextra `technikschildMessen` (`adb shell am start … --ez technikschildMessen true`).
     */
    var technikschildMessen by Merkwert(a, "technikschildMessen", bool("technikschildMessen", false), jaNein)
}

/** Liest eine Wahlliste der Fassade: `[{"wert","text"}]`. */
fun wahlenLesen(json: String): List<Wahl> = JSONArray(json).let { a ->
    (0 until a.length()).map { a.getJSONObject(it).let { o -> Wahl(o.getString("wert"), o.getString("text")) } }
}

/** Ob Kacheln ihren Fortschrittsbalken zeigen — „Fortschritt auf Kacheln". */
val LocalFortschrittZeigen = compositionLocalOf { true }

// MARK: Bausteine der Unterseiten

/**
 * Vorlage: `Unterseitenkopf` — Zurueck 44, Titel 22 halbfett; so steht der Pfeil ueberall gleich weit
 * vom Rand. `rechts` traegt die Zaehlmarke („Bin ich hier durch?"), `unten` ist 18 und 0 dort, wo
 * darunter eine Wertreihe ihre 14 selbst mitbringt. `oben = false` in einem `Wurzelkopf`, der den
 * Statusbereich schon freihaelt.
 */
@Composable
fun Unterseitenkopf(titel: String, zurueck: () -> Unit, unten: Dp = 18.dp, oben: Boolean = true,
                    rechts: @Composable RowScope.() -> Unit = {}) {
    Row(Modifier.fillMaxWidth().then(if (oben) Modifier.statusBarsPadding() else Modifier)
            .padding(start = 8.dp, end = 12.dp, bottom = unten),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(44.dp).antippen(zurueck), contentAlignment = Alignment.Center) {
            Symbol(Zeichen.WinkelLinks, 20.dp, farbe = Stil.schrift, staerke = Staerke.Halbfett, beschreibung = uebersetzt("Zurück"))
        }
        Text(titel, style = Stil.unterseitentitel,
             color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        rechts()
    }
}

/** Eine Unterseite: Kopf, darunter scrollender Inhalt bis an die Gestenleiste. */
@Composable
fun Einstellungsseite(titel: String, zurueck: () -> Unit, inhalt: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().background(Stil.grund)) {
        Unterseitenkopf(titel, zurueck)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 40.dp),
               content = inhalt)
    }
}

/**
 * Vorlage: `Karte` — die eine erlaubte Flaeche auf Einstellungsseiten, **Ecke 14**
 * (`eckeKarte`) und Fläche `gruppenflaeche`.
 *
 * Sie trug `flaeche` #262626 und `eckeFlaeche` 16. `flaeche` traegt **Knoepfe** — kleine
 * Gegenstaende, die sich vom Grund abheben muessen; eine Einstellungskarte ist das
 * Gegenteil, ein grosser ruhiger Block, und derselbe Ton wirkt darauf deutlich heller.
 * Paul am 22.09.: „die Kacheln in den Settings sind ein Stueck zu hell, das ist zu doller
 * Kontrast."
 */
@Composable
fun Karte(inhalt: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = Stil.randAbstand).clip(RoundedCornerShape(Stil.eckeKarte))
               .background(Stil.gruppenflaeche), content = inhalt)
}

/**
 * Vorlage: `Gruppentitel` — **20 Semibold in Normalschreibung**, `sperrungReihe`,
 * `schriftLeise`.
 *
 * Er stand in 11 Punkt Versalien. Die Versalienstufe gibt es weiter (`Stil.gruppe`), sie
 * traegt aber nur noch Plaketten: eine Rubrik in Versalien liest sich auf einer Seite voller
 * ruhiger Zeilen wie ein Alarm. 10 statt 8 darunter — der Grad ist von 11 auf 20 gewachsen,
 * und ein Abstand, der zu einer 11er Zeile passte, klebt unter einer 20er.
 */
@Composable
fun Gruppentitel(text: String, modifier: Modifier = Modifier) {
    Text(text, style = Stil.reihe,
         color = Stil.schriftLeise, modifier = modifier.fillMaxWidth().padding(horizontal = Stil.randAbstand).padding(bottom = 10.dp))
}

/** Vorlage: `Einstellungsgruppe` — Gruppentitel, darunter die Karte. */
@Composable
fun Einstellungsgruppe(titel: String, inhalt: @Composable ColumnScope.() -> Unit) {
    Column {
        // 26 oben, 10 + 2 unten.
        Gruppentitel(titel, Modifier.padding(top = 26.dp, bottom = 2.dp))
        Karte(inhalt)
    }
}

/**
 * Die Linie zwischen den Zeilen einer Karte — **`Blattlinie`, durchgehend**, von Kartenrand zu
 * Kartenrand. Sie begann hier bei 34, hinter dem Zeichen; am iPhone tragen Einstellungskarten die
 * durchgehende Linie, weil die gerundete Karte selbst schon die Gruppe ist.
 */
@Composable
fun Trennlinie() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(Stil.linie))
}

/** Vorlage: `Fusszeile` unter einer Gruppe — 12 (`klein`), sehr leise. 13 Regular steht nicht in der Leiter. */
@Composable
fun Fusszeile(text: String) {
    Text(text, style = Stil.klein.copy(lineHeight = 17.sp), color = Stil.schriftSehrLeise,
         modifier = Modifier.padding(horizontal = Stil.randAbstand * 2).padding(top = 8.dp))
}

/**
 * Vorlage: `Schalter` — eigener statt `Switch`: Apples bringt eigene Masse und Bewegung mit und
 * wirkt neben flachen Flaechen fremd. 46 × 28, der Knopf stanzt im Akzent ein Loch in den Grund.
 */
@Composable
fun Schalter(an: Boolean, aendern: (Boolean) -> Unit) {
    val lage by animateFloatAsState(if (an) 1f else 0f, tween(150, easing = EaseInOut), label = "schalter")
    // Aus: Flaeche `rand` (Weiss 12 %), an: `akzent`, Knauf `grund` (BAUTEILE 6). Hier stand
    // Weiss 16 % — ein Ton neben dem, den es dafuer gibt.
    Box(Modifier.size(46.dp, 28.dp).clip(CircleShape).background(lerp(Stil.rand, Stil.akzent, lage))
            // Fuer TalkBack ein Schalter mit Zustand, nicht eine namenlose Flaeche.
            .toggleable(an, remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, null,
                role = androidx.compose.ui.semantics.Role.Switch) { aendern(it) }.padding(3.dp)) {
        Box(Modifier.offset(x = 18.dp * lage).size(22.dp).clip(CircleShape).background(lerp(Color.White, Stil.grund, lage)))
    }
}

/**
 * Vorlage: `Zeilenaufbau` — Zeichen 17 in einer 20 breiten Spalte, **Titel 15 Semibold**,
 * Unterzeile 12 `schriftSehrLeise`, 14 Abstand, 14 senkrecht (BAUTEILE 6).
 *
 * Titel 16 und Unterzeile 13 stehen in keiner Leiter, und die Unterzeile trug Weiss auf
 * 45 Prozent — als voller Wert ist das `schriftSehrLeise`, das ueber einem Plakat nicht
 * kippt und gerechnet 5,78:1 auf der Gruppenflaeche traegt.
 */
@Composable
fun Zeilenaufbau(symbol: Zeichen, titel: String, unter: String?, farbe: Color, modifier: Modifier,
                         senkrecht: Int = 14, zeichenfarbe: Color = Stil.schrift, rechts: @Composable RowScope.() -> Unit) {
    Row(modifier.fillMaxWidth().padding(horizontal = Stil.randAbstand, vertical = senkrecht.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        // Das Zeichen bleibt weiss, auch wenn der Titel gedaempft ist — wie `Zeilenaufbau` am iPhone.
        Box(Modifier.width(Stil.zeichenSpalte), contentAlignment = Alignment.Center) { Symbol(symbol, 17.dp, farbe = zeichenfarbe) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(titel, style = Stil.listentitel, color = farbe)
            unter?.let { Text(it, style = Stil.klein, color = Stil.schriftSehrLeise) }
        }
        rechts()
    }
}

/**
 * Der Winkel rechts in einer Zeile — `schriftSehrLeise`, wie auf Apple.
 *
 * Er trug Weiss auf 28 Prozent, und das sind gerechnet **2,47:1**: verboten, auch fuer ein
 * Bedienzeichen (3:1). Die Groesse bleibt bei 20: Apples Winkel ist ein 13-Punkt-Glyphe,
 * Materials `KeyboardArrowRight` bringt seinen Rand im Bild mit und zeichnet bei 20 dp
 * einen Haken derselben Hoehe.
 */
@Composable
private fun Pfeil() {
    Symbol(Zeichen.WinkelRechts, 13.dp, farbe = Stil.schriftSehrLeise, staerke = Staerke.Halbfett)
}

/**
 * Vorlage: `Wahlzeile` — schaltet etwas um; die ganze Zeile nimmt den Tipp.
 * `gesperrt`: der Server entscheidet, nicht der Schalter — wie „Immer Direct
 * Play", wenn der Server nicht umwandelt.
 */
@Composable
fun Wahlzeile(symbol: Zeichen, titel: String, unter: String? = null, an: Boolean, gesperrt: Boolean = false, aendern: (Boolean) -> Unit) {
    // **Gesperrt heisst gedaempfte Schrift, nicht durchscheinend** (BRAND 5): Weiss auf
    // 40 Prozent ueber unserem Grund ergibt ein kraeftiges Grau — das sieht nach einem Knopf
    // aus, der nicht reagiert, statt nach einem, der noch wartet.
    val farbe = if (gesperrt) Stil.schriftSehrLeise else Stil.schrift
    Zeilenaufbau(symbol, titel, unter, farbe, if (gesperrt) Modifier else Modifier.druckzeile { aendern(!an) }) {
        Schalter(an, if (gesperrt) { _: Boolean -> } else aendern)
    }
}

/** Vorlage: `Wertzeile` — zeigt einen Wert und fuehrt, wenn antippbar, zu seiner Auswahl. Gedimmt, wenn er nicht greift. */
@Composable
fun Wertzeile(symbol: Zeichen, titel: String, unter: String? = null, wert: String? = null, gedimmt: Boolean = false, tun: (() -> Unit)? = null) {
    val farbe = if (gedimmt) Stil.schriftSehrLeise else Stil.schrift
    // Ein Knopf gibt nach (`Stil.Druckknopf`); gedimmt ist er keiner und traegt keinen Winkel.
    val aktiv = tun != null && !gedimmt
    Zeilenaufbau(symbol, titel, unter, farbe, if (aktiv) Modifier.antippen(tun!!) else Modifier) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            wert?.let { Text(it, style = Stil.koerper, color = Stil.schriftLeise, maxLines = 1) }
            if (aktiv) Pfeil()
        }
    }
}

/**
 * Vorlage: `Profilzeile` — fuehrt woanders hin, senkrecht 14 wie jede Listenzeile. `zeichenAkzent`:
 * **nur das Zeichen** im Akzent, der Titel bleibt weiss (Quick Connect — eine Profilseite ohne einen
 * farbigen Punkt liest sich leblos).
 */
@Composable
fun Profilzeile(symbol: Zeichen, titel: String, unter: String? = null, zeichenAkzent: Boolean = false, tun: () -> Unit) {
    Zeilenaufbau(symbol, titel, unter, Stil.schrift, Modifier.antippen(tun),
                 zeichenfarbe = if (zeichenAkzent) Stil.akzent else Stil.schrift) { Pfeil() }
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
                        Symbol(Zeichen.Griff, 17.dp, farbe = Stil.schriftSehrLeise)
                    }
                }
            }
        }
    }
}
