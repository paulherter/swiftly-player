package de.paulherter.swiftly.tv

import de.paulherter.swiftly.Protokoll
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.Kachelplakette
import androidx.compose.ui.platform.LocalContext
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.bewegungReduziert
import de.paulherter.swiftly.gemeinsam.uebersetzt

/**
 * Vorlage: `Sources/tvOS/Stil.swift`. **Punkte halbiert zu dp** — tvOS rechnet auf 1920 Punkt,
 * ein 1080p-Fernseher hat unter Android 960 dp. Farben kommen unveraendert aus `Stil`.
 *
 * **Daraus folgt etwas, das die Arbeit hier klein haelt.** Die Schriftleiter am Fernseher ist
 * Stufe fuer Stufe das **Doppelte** der Telefonleiter (56 / 44 / 40 / 34 / 30 / 30 / 26 / 24 /
 * 22 / 20, `Sources/tvOS/Stil.swift`). Halbiert man sie fuer Android, kommt Zahl fuer Zahl die
 * Telefonleiter heraus: 28 / 22 / 20 / 17 / 15 / 15 / 13 / 12 / 11 / 10. Dasselbe gilt fuer die
 * Sperrungen, weil jede der em-Wert mal der Punktgroesse ist.
 *
 * **`TvStil` fuehrt deshalb keine eigene Schriftleiter mehr**, sondern zeigt auf `Stil`. Wer am
 * Telefon eine Stufe aendert, hat den Fernseher mitgeaendert — und die sieben eigenen Grade, die
 * hier standen (28,5 / 30 / 19 / 19 / 14,5 / 13,5 / 12,5), sind damit weg. Keiner von ihnen lag
 * auf einer Stufe.
 *
 * Die eine Regel, die alles traegt: **Fokus ist weiss, Auswahl ist Akzent.**
 */
object TvStil {
    val randSeite = 40.dp
    val randOben = 30.dp
    val leisteHoehe = 34.dp
    val kachelAbstand = 20.dp
    val posterBreite = 104.dp
    val posterHoehe = 156.dp
    val querBreite = 224.dp
    val querHoehe = 126.dp
    val heldenHoehe = 255.dp
    /** 28 Luecke + 10 Luft + 12 Kopfluft — die Luft faengt die Lupe auf. */
    val reihenAbstand = 36.dp
    val reihenLuft = 10.dp
    val titelAbstand = 18.dp
    val knopfHoehe = 38.dp
    val chipHoehe = 24.dp
    val zeilenHoehe = 42.dp
    /**
     * **Die Eckenleiter — dieselbe Rundung wie am Telefon, nicht dieselbe Zahl.**
     *
     * Der Massstab ist das Verhaeltnis von Radius zu Groesse des Dings, das er rundet: nur das
     * entscheidet, wie rund eine Ecke *wirkt*. Weil die Dinge am Fernseher nicht alle gleich
     * stark wachsen (Plakat 112 → 208 ist 1,86, Knopf 48 → 76 nur 1,58), kann es einen festen
     * Faktor gar nicht geben. Die Rechnung steht als Tabelle an `Stil.ecke` in
     * `Sources/tvOS/Stil.swift`; sie ergibt dort **14 / 16 / 18 / 24**, halbiert also:
     *
     *     eckeKlein   14 → 7      Marken und Plaketten
     *     ecke        16 → 8      Knopf, Feld
     *     eckeKachel  18 → 9      Plakat, Kachel
     *     eckeFlaeche 24 → 12     Tafel, Blatt
     *
     * Hier standen 6 und 8. Die 6 war nicht nur zu klein, sie war auch kleiner als die
     * Kachelecke daneben — am Telefon tragen Knopf und Plakat dieselbe Zahl.
     */
    val ecke = 8.dp
    val eckeKachel = 9.dp
    /** Marken und Plaketten auf einer Kachel. */
    val eckeKlein = 7.dp
    /** Eine eigene Flaeche oder Tafel — Handlungstafel, Blatt. */
    val eckeFlaeche = 12.dp
    /** Keine Stufe der Leiter, sondern ein Platzhalterbalken (`Ladefeld`). */
    val eckeBalken = 2.5.dp
    const val gitterSpalten = 7
    val gitterSpalte = 25.dp
    val gitterZeile = 36.dp

    /**
     * **Die Fokusleiter: drei Stufen, nach der Groesse des Gegenstands.**
     *
     * Hier standen sechs Zahlen fuer **eine** Aussage („hier steht die Fernbedienung") — 1,03 ·
     * 1,04 · 1,06 · 1,08 · 1,1 —, und nur eine davon war ein Token. Das Kriterium ist **wie weit
     * der Umriss wandert**, nicht wie viel Prozent es sind: 8 Prozent sind auf einem 30 dp
     * grossen Profilkreis zwei dp, auf einer 380 dp breiten Zeile dreissig.
     *
     * Gemessen wird die **laengste Seite**, und der Zuwachs soll ueberall in derselben
     * Groessenordnung landen (rund 3 bis 13 dp, also die Haelfte der tvOS-Werte):
     *
     *     fokusLupeKlein   1,10   bis 60 dp     Profilkreis 30, Symbolknopf 44
     *     fokusLupe        1,06   60 bis 250    Chip 90, Knopf 125, Plakat 156, Querkachel 224
     *     fokusLupeBreit   1,03   ab 250        Leistenzeile 310, Geraetezeile 380
     *
     * Klein waechst also staerker, gross weniger. Kein Schatten, keine Parallaxe, kein
     * Aufblitzen — Apples Karte springt deutlich weiter und schiebt in einer dichten Reihe die
     * Nachbarn optisch weg.
     */
    const val fokusLupeKlein = 1.10f
    const val fokusLupe = 1.06f
    const val fokusLupeBreit = 1.03f
    val fokusflaeche = Color.White.copy(alpha = 0.12f)
    /** `.easeOut(duration: 0.14)`. */
    val fokusKurve = CubicBezierEasing(0f, 0f, 0.58f, 1f)
    const val fokusDauer = 140
    /** Seitenscroll beim Abschnittswechsel (`TvAbschnitte`) — ruhiger als die Lupe, dieselbe Kurve. */
    const val abschnittDauer = 300

    // MARK: Schrift — **die Leiter des Telefons, halbiert aus der des Fernsehers**
    //
    // Siehe der Kommentar am Kopf dieser Datei: die tvOS-Leiter ist das Doppelte der
    // iPhone-Leiter, und ein Android-Fernseher rechnet in der Haelfte der tvOS-Punkte. Es
    // bleiben also dieselben Zahlen — und damit dieselben Tokens.

    val titelGross = Stil.titelGross
    val unterseitentitel = Stil.unterseitentitel
    /**
     * Vorlage: `Kopfauskunft`-Titel.
     *
     * **Der Titel ueber einem Heldbild *ist* der Seitentitel** (BRAND 2) — dieselbe Stufe wie
     * „Einstellungen". Es gab dafuer eigene Stufen (27 am iPhone, 34 am Mac, 60 am Fernseher,
     * hier 30); alle vier fallen weg.
     */
    val auskunftTitel = Stil.titelGross
    /** Vorlage: `Kopfauskunft`-Zweitzeile (Folgentitel) — die Blattrubrik aus der Leiter. */
    val auskunftZweitzeile = Stil.rubrikGross
    val reihe = Stil.reihe
    val rubrikGross = Stil.rubrikGross
    /** Die Beschriftung eines Knopfs und die Zeile einer Liste. */
    val knopf = Stil.listentitel
    val koerper = Stil.koerper
    val kachel = Stil.kachel
    val klein = Stil.klein
    val plakette = Stil.plakette

    // MARK: Kopfauskunft — gemeinsam fuer Start, Film und Serie

    /** `Stil.beschreibungZeile`/`beschreibungLuft`, halbiert. Nur fuer `beschreibungHoehe`. */
    private const val beschreibungZeile = 18.5f
    private const val beschreibungLuft = 5.5f

    /** Vorlage: `Stil.beschreibungHoehe(_:)` — wie hoch `zeilen` Zeilen Beschreibung stehen. */
    fun beschreibungHoehe(zeilen: Int): Dp = (zeilen * beschreibungZeile + (zeilen - 1) * beschreibungLuft).dp

    /**
     * Vorlage: `Stil.auskunftHoehe(zweitzeile:)` — **gerechnet, nicht gesetzt**, damit
     * `Kopfauskunft` auf Start und Detail immer dieselbe Gesamthoehe hat: 34 (Titel) + 27
     * (Zweitzeile, nur wenn vorhanden) + 7 + 17 (Angabenzeile) + 11 + Beschreibung (drei Zeilen,
     * zwei mit Zweitzeile).
     */
    fun auskunftHoehe(zweitzeile: Boolean): Dp =
        34.dp + (if (zweitzeile) 27.dp else 0.dp) + 7.dp + 17.dp + 11.dp + beschreibungHoehe(if (zweitzeile) 2 else 3)

    /** `.easeOut(duration: 0.3)` — dieselbe Kurve wie `fokusKurve`, hier fuer `eingeblendet`
     *  auf Film- und Serienseite (`TvDetail`, `TvSerie`): der Kopf steht sofort, der Rest blendet. */
    val einblendenKurve = fokusKurve
    const val einblendenDauer = 300

    /** Vorlage: `HauptView.leisteDa` auf tvOS — `.easeInOut(duration: 0.26)`. Die Kopfleiste weicht
     *  beim Oeffnen einer Unterseite und kommt beim Zurueck wieder, siehe `TvHaupt`. */
    val leisteKurve = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)
    const val leisteDauer = 260
}

/**
 * Die Einblendung beim Erscheinen einer Seite (`eingeblendet` auf tvOS) — 0 → 1 in
 * `einblendenDauer` mit `einblendenKurve`, jedes Mal neu, wenn `schluessel` wechselt.
 *
 * **Warum nicht einfach `animateFloatAsState` + `LaunchedEffect { eingeblendet = true }`** — so
 * stand es vorher, und am Emulator war davon nichts zu sehen, die Knoepfe waren „zack da". Zwei
 * Gruende zusammen: (1) der Wert wurde in der Komposition gelesen (`Modifier.alpha(wert)`), also
 * setzte jedes Animationsbild die **ganze** Detailseite neu zusammen; (2) die Animation startete im
 * Bild direkt nach dem ersten Aufbau, genau in den teuren Bildern, in denen die Seite ihre Reihen,
 * Bilder und den Fokus einrichtet. Die Animation laeuft nach Uhrzeit, also waren die 300 ms vorbei,
 * bevor ein ruhiges Bild kam. Jetzt: erst zwei gezeichnete Bilder abwarten (die Seite steht mit
 * Deckkraft 0), dann animieren — und gelesen wird nur in der Zeichenphase (`graphicsLayer`, siehe
 * `Modifier.tvEingeblendet`), kein Neuaufbau je Bild.
 */
@Composable
fun rememberTvEinblendung(schluessel: Any?): androidx.compose.runtime.State<Float> {
    val wert = remember(schluessel) { androidx.compose.animation.core.Animatable(0f) }
    LaunchedEffect(schluessel) {
        withFrameNanos { }
        withFrameNanos { }
        wert.animateTo(1f, tween(TvStil.einblendenDauer, easing = TvStil.einblendenKurve))
    }
    return wert.asState()
}

/** Deckkraft aus einer Einblendung, gelesen erst beim Zeichnen — siehe `rememberTvEinblendung`. */
fun Modifier.tvEingeblendet(deckkraft: () -> Float): Modifier = this.graphicsLayer { alpha = deckkraft() }

/**
 * Eine fokussierbare Flaeche mit Lupe — `KachelStil`, `KnopfStil`, `ReiterStil` teilen sich das.
 * **Keine Schatten, kein Leuchten, kein Ring:** zwei Anlaeufe damit sahen an einer Einzelkachel
 * sauber aus und in einer Reihe mit sechs Nachbarn matschig.
 *
 * **Traegt einen eigenen `FocusRequester`** und meldet sich beim Ausloesen bei `Fokusmerker` —
 * so kann eine Tafel oder ein Blatt, die diese Flaeche geoeffnet hat, den Fokus beim Schliessen
 * dorthin zurueckgeben. tvOS laesst den Ausloeser stehen, der Fokus bleibt dort von selbst;
 * Compose braucht dafuer diesen Umweg (siehe `Fokusmerker`, `LocalInnerhalbTafel`).
 */
@Composable
fun Fokusflaeche(modifier: Modifier = Modifier, lupe: Float = TvStil.fokusLupe, fokusGeaendert: (Boolean) -> Unit = {},
                 tun: () -> Unit, inhalt: @Composable BoxScope.(fokus: Boolean) -> Unit) {
    var fokus by remember { mutableStateOf(false) }
    // **„Bewegung reduzieren" gilt auch hier** — der Fokus bleibt sichtbar, nur die Kurve wird
    // kurz und gerade, so wie am Telefon (`Stil.fokusAnimation` auf tvOS).
    val ruhig = bewegungReduziert()
    val mass by animateFloatAsState(if (fokus) lupe else 1f,
        if (ruhig) Bewegung.blendeReduziert() else tween(TvStil.fokusDauer, easing = TvStil.fokusKurve), label = "lupe")
    val eigenerFokus = remember { FocusRequester() }
    val innerhalbTafel = LocalInnerhalbTafel.current
    Box(modifier
            .focusRequester(eigenerFokus)
            .onFocusChanged { if (fokus != it.isFocused) { fokus = it.isFocused; fokusGeaendert(it.isFocused) } }
            .graphicsLayer { scaleX = mass; scaleY = mass }
            .clickable(remember { MutableInteractionSource() }, null, onClick = {
                // Nicht innerhalb einer offenen Tafel: sonst ueberschriebe eine Auswahlzeile *in*
                // ihr den Rueckweg zu der Zeile, die sie geoeffnet hat.
                if (!innerhalbTafel) Fokusmerker.letzter = eigenerFokus
                tun()
            })) {
        inhalt(fokus)
    }
}

/**
 * Wer eine Tafel oder ein Blatt ausgeloest hat — damit `TvTafel`/`TvWiedergabeblatt`/
 * `TvFolgenblatt` den Fokus beim Schliessen (Auswahl **oder** Zurueck) dorthin zurueckgeben,
 * statt ihn der zufaelligen Fokussuche von Compose zu ueberlassen (die sonst z. B. beim ersten
 * fokussierbaren Element der Seite landet).
 */
object Fokusmerker {
    var letzter: FocusRequester? = null
        set(wert) { field = wert; gesetztUm = android.os.SystemClock.elapsedRealtime() }
    private var gesetztUm = 0L

    /**
     * **Der Ausloeser des Players** — Kachel, Folge oder Knopf, von dem aus gestartet wurde (Vorlage
     * tvOS 57d3219). Der Player laeuft in einer eigenen Aktivitaet und raeumt `letzter` dort weg;
     * `TvHaupt` merkt ihn deshalb hier, bevor er startet, und legt den Fokus nach dem Schliessen
     * zurueck. Nur ein frischer Klick zaehlt — ein Start ohne Klick (Watch Next, Fernsteuerung)
     * haette sonst einen alten Knopf einer anderen Seite getroffen.
     */
    var vorDemPlayer: FocusRequester? = null

    fun playerStartet() {
        vorDemPlayer = letzter.takeIf { android.os.SystemClock.elapsedRealtime() - gesetztUm < 3000 }
    }

    fun playerZu() {
        val ziel = vorDemPlayer ?: return
        vorDemPlayer = null
        val traf = runCatching { ziel.requestFocus() }.isSuccess
        Protokoll.schreib("[Fokus] nach dem Player ${if (traf) "zurück am Auslöser" else "Auslöser nicht mehr da"}")
    }

    /** Fordert den gemerkten Ausloeser zurueck, sonst `ersatz` (falls angegeben) — danach
     *  vergessen, damit ein spaeteres Schliessen ohne neuen Ausloeser nicht denselben Knopf trifft. */
    fun zurueckfordern(ersatz: FocusRequester? = null) {
        val ziel = letzter
        letzter = null
        val traf = ziel != null && runCatching { ziel.requestFocus() }.isSuccess
        if (!traf) ersatz?.let { runCatching { it.requestFocus() } }
    }

    /**
     * **Vor** dem Schliessen aufrufen, solange die Tafel noch steht. Entfernt Compose einen
     * fokussierten Knoten, faellt der Fokus sofort auf den ersten fokussierbaren Knoten des Fensters
     * (auf der Profilseite das „+" im Kontenstreifen) — ein spaeteres `zurueckfordern` holt ihn erst
     * danach, und genau dieser Zwischenhalt blitzte. Steht der Fokus schon am Ausloeser, wenn die
     * Tafel verschwindet, gibt es nichts zu fallen.
     *
     * Der Merker bleibt stehen: waehlt eine Tafelzeile gleich die naechste Tafel, gilt derselbe
     * Ausloeser weiter. Die Tafel muss ihren Ausgang dafuer freigeben (`exit`), siehe `TvTafel`.
     */
    fun zurueckgeben(ersatz: FocusRequester? = null): Boolean {
        val ziel = letzter
        if (ziel != null && runCatching { ziel.requestFocus() }.isSuccess) return true
        return ersatz != null && runCatching { ersatz.requestFocus() }.isSuccess
    }
}

/** True innerhalb einer offenen Tafel/eines Blatts (`TvTafel`, `TvWiedergabeblatt`,
 *  `TvFolgenblatt`) — dort zaehlt eine angeklickte `Fokusflaeche` nicht als Ausloeser fuer
 *  `Fokusmerker`, sonst waere immer die zuletzt gewaehlte Zeile der „Ausloeser". */
val LocalInnerhalbTafel = compositionLocalOf { false }

/**
 * Vorlage: `KnopfStil` — die fokussierte Fassung ist Zeichen fuer Zeichen der Hauptknopf vom iPhone:
 * weiss mit dunkler Schrift. Ohne Fokus 10 % weiss.
 *
 * **`freigegeben` — gedaempft, nicht durchscheinend** (`KnopfStil.vordergrund`/`hintergrund` bei
 * `!freigegeben`): dieselbe Begruendung wie auf tvOS, weiss auf 40 Prozent saehe aus wie ein Knopf,
 * der noch wartet. Vorgabe `true`, also bricht kein bestehender Aufruf.
 */
@Composable
fun TvKnopf(text: String?, symbol: Zeichen? = null, modifier: Modifier = Modifier, hoehe: Dp = TvStil.knopfHoehe,
            freigegeben: Boolean = true, symbolNachText: Boolean = false, fokusGeaendert: (Boolean) -> Unit = {}, tun: () -> Unit) {
    Fokusflaeche(modifier, lupe = TvStil.fokusLupe, fokusGeaendert = fokusGeaendert, tun = { if (freigegeben) tun() }) { fokus ->
        val farbe = if (!freigegeben) Stil.schriftSehrLeise else if (fokus) Stil.grund else Stil.schrift
        Row(Modifier.height(hoehe).then(if (text == null) Modifier.width(hoehe) else Modifier)
                .clip(RoundedCornerShape(TvStil.ecke))
                .background(if (!freigegeben) Stil.flaeche else if (fokus) Color.White else Color.White.copy(alpha = 0.10f))
                .padding(horizontal = if (text == null) 0.dp else 20.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
            val symbolInhalt: @Composable () -> Unit = { symbol?.let { Symbol(it, 15.dp, farbe = farbe, staerke = Staerke.Halbfett, beschreibung = text) } }
            val textInhalt: @Composable () -> Unit = { text?.let { Text(it, style = TvStil.knopf, color = farbe, maxLines = 1) } }
            // **Sortierknoepfe zeigen den Pfeil hinter dem Wort** — „A–Z ⌄" auf tvOS, kein
            // fuehrendes Symbol wie bei jedem anderen `TvKnopf`.
            if (symbolNachText) { textInhalt(); symbolInhalt() } else { symbolInhalt(); textInhalt() }
        }
    }
}

/**
 * Vorlage: `Eingabefeld` in `Sources/tvOS/RootView.swift`. Dort liegt ein fast unsichtbares
 * `TextField` hinter der eigenen Zeichnung, weil tvOS jedem Textfeld eine weisse Kapsel mit Schein
 * und Schatten aufzwingt, die sich nicht abschalten laesst. Diesen Umweg braucht Compose nicht:
 * `BasicTextField` zeichnet von sich aus nichts, `decorationBox` uebernimmt die ganze Flaeche —
 * derselbe Griff wie schon beim Suchfeld in `TvSuche`.
 */
@Composable
fun TvFeld(wert: String, aendern: (String) -> Unit, platzhalter: String, modifier: Modifier = Modifier,
          geheim: Boolean = false, imeAction: ImeAction = ImeAction.Done,
          tastaturTyp: KeyboardType = KeyboardType.Text, tastaturAktion: () -> Unit = {}) {
    var fokus by remember { mutableStateOf(false) }
    val farbe = if (fokus) Stil.grund else Stil.schrift
    BasicTextField(wert, aendern, singleLine = true,
        textStyle = TvStil.koerper.copy(color = farbe),
        cursorBrush = SolidColor(farbe),
        visualTransformation = if (geheim) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(imeAction = imeAction, keyboardType = tastaturTyp),
        keyboardActions = KeyboardActions(onDone = { tastaturAktion() }, onGo = { tastaturAktion() }, onSearch = { tastaturAktion() }),
        modifier = modifier.height(TvStil.knopfHoehe).onFocusChanged { fokus = it.isFocused },
        decorationBox = { innen ->
            // **Kein Rand** (BRAND 4): ein Feld ist eine gefuellte Kapsel, kein gezeichneter
            // Rahmen — auch am Fernseher. Ruhend `flaeche`, nicht `erhoeht`: `erhoeht` ist,
            // was **auf** einer Flaeche liegt.
            Box(Modifier.fillMaxSize().clip(RoundedCornerShape(TvStil.ecke))
                    .background(if (fokus) Color.White else Stil.flaeche)
                    .padding(horizontal = 15.dp), contentAlignment = Alignment.CenterStart) {
                if (wert.isEmpty()) Text(platzhalter, style = TvStil.koerper,
                                        color = if (fokus) Stil.grund.copy(alpha = 0.45f) else Stil.schriftSehrLeise)
                innen()
            }
        })
}

/**
 * Vorlage: `ChipStil`.
 *
 * **Der gewaehlte Chip traegt den Akzent als Flaeche — und das ist eine begruendete Ausnahme**
 * (BRAND 1). `erhoeht` gegen `flaeche` ist #303030 gegen #262626: am Schreibtisch erkennbar, auf
 * drei Meter nicht. „Ich koennte dir nicht sagen, dass das an ist." Eine Helligkeitsstufe
 * ueberlebt die Entfernung nicht, ein Farbwechsel schon — und Entfernung ist der Grund, aus dem
 * der Fernseher abweichen darf. `grund` auf `akzent` traegt 10,8:1.
 *
 * Er war hier **weiss gefuellt mit dunkler Schrift**, Zeichen fuer Zeichen der Hauptknopf, und
 * auf der Bibliotheksseite stehen mehrere davon — BRAND 5 laesst genau eine gefuellte Flaeche je
 * Seite zu.
 *
 * Dem Fokus nimmt das nichts: auf dem gewaehlten Chip tritt an die Stelle des Schleiers der
 * **helle** Akzent, damit auch er aufhellt statt stehen zu bleiben. Der Rand faellt weg —
 * eine Flaeche sagt „hier kann man druecken", der Fokus sagt den Rest. **Ein Gewicht**: 13
 * Medium, gewaehlt wie ruhend.
 */
@Composable
fun TvChip(text: String, an: Boolean, modifier: Modifier = Modifier, tun: () -> Unit) {
    Fokusflaeche(modifier, lupe = TvStil.fokusLupe, tun = tun) { fokus ->
        Box(Modifier.heightIn(min = TvStil.chipHoehe).clip(CircleShape)
                .background(when {
                    an -> if (fokus) Stil.akzentHell else Stil.akzent
                    fokus -> TvStil.fokusflaeche
                    else -> Stil.flaeche
                })
                .padding(horizontal = 11.dp),
            contentAlignment = Alignment.Center) {
            Text(text, style = TvStil.kachel, color = if (an) Stil.grund else Stil.schriftLeise, maxLines = 1)
        }
    }
}

/**
 * Vorlage: `KapselStil` — eine Kapsel, die etwas aufklappt (Bibliothek, Filter, Sortierung). Form und
 * Hoehe wie `TvChip`, damit die Reihe eine Form hat. Grund `erhoeht`, im Fokus die ruhige Flaeche;
 * Schrift `kachel` (13 Medium) in `schrift`.
 *
 * **Mit `symbol` ein Zeichen vorn statt des Pfeils hinten — wie die `Wertpille` am iPhone** (tvOS
 * d82e0bd9). Filter und Sortierung stehen dort als Pille mit Zeichen und Wert, ohne Pfeil. Zeichen
 * und Pfeil tragen Deckkraft 0,6 statt eigener Farbe, damit sie der Schrift folgen. Masse halbiert:
 * Zeichen 22 → 11, Pfeil 18 → 9, Abstand 10 → 5, Einzug 22 → 11.
 */
@Composable
fun TvKapsel(text: String, modifier: Modifier = Modifier,
             /** `KapselStil(symbol:)` — `null` heisst: der Pfeil hinten. */
             symbol: Zeichen? = null,
             /** `KapselStil(pfeil:)` — nach unten, wenn sie etwas aufklappt; nach rechts, wenn sie weiterfuehrt. */
             pfeil: Zeichen = Zeichen.WinkelRunter, tun: () -> Unit) {
    Fokusflaeche(modifier, lupe = TvStil.fokusLupe, tun = tun) { fokus ->
        Row(Modifier.height(TvStil.chipHoehe).clip(CircleShape)
                .background(if (fokus) TvStil.fokusflaeche else Stil.erhoeht)
                .padding(horizontal = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            val leise = Stil.schrift.copy(alpha = 0.6f)
            symbol?.let { Symbol(it, 11.dp, farbe = leise, staerke = Staerke.Mittel) }
            Text(text, style = TvStil.kachel, color = Stil.schrift, maxLines = 1)
            if (symbol == null) Symbol(pfeil, 9.dp, farbe = leise, staerke = Staerke.Halbfett)
        }
    }
}

/** Vorlage: `ZeilenStil` — Auswahllisten und Handlungstafel: keine Lupe, nur eine ruhige Flaeche. */
@Composable
fun TvZeile(text: String, symbol: Zeichen? = null, rechts: String? = null, haken: Boolean = false,
            modifier: Modifier = Modifier,
            /** Die gewaehlte Zeile einer Auswahltafel traegt ihr Zeichen im Akzent (`Handlungstafel.gewaehlt`). */
            symbolFarbe: Color = Stil.schrift, tun: () -> Unit) {
    Fokusflaeche(modifier.fillMaxWidth(), lupe = 1f, tun = tun) { fokus ->
        Row(Modifier.fillMaxWidth().height(TvStil.zeilenHoehe).clip(RoundedCornerShape(TvStil.ecke))
                .background(if (fokus) TvStil.fokusflaeche else Color.Transparent).padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            symbol?.let { Symbol(it, 13.dp, farbe = symbolFarbe, staerke = Staerke.Mittel) }
            // 15, und im Fokus halbfett — eine **senkrechte** Liste, also verschiebt der
            // Gewichtswechsel keine Nachbarn (Vorlage `ZeilenStil`).
            Text(text, style = if (fokus) TvStil.knopf else TvStil.koerper.copy(fontWeight = FontWeight.Medium),
                 color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            rechts?.let { Text(it, style = TvStil.kachel, color = Stil.schriftLeise, maxLines = 1) }
            if (haken) Symbol(Zeichen.Haken, 13.dp, farbe = Stil.akzent, staerke = Staerke.Halbfett)
        }
    }
}

/**
 * Vorlage: `Kachelinhalt` — Bild, darunter Titel und Unterzeile, **immer da**, nie ueber dem Bild
 * und nie erst mit dem Fokus. Die Lupe ist die einzige Fokusanzeige.
 */
@Composable
fun TvKachel(bild: String?, titel: String, unterzeile: String?, quer: Boolean = false, fortschritt: Double? = null,
             marke: String? = null, markenzahl: Int = 0,
             modifier: Modifier = Modifier, deckkraft: Float = 1f, titelLeise: Boolean = false,
             fokusGeaendert: (Boolean) -> Unit = {},
             /**
              * **Ein Ersatz fuer das Bild** (`Kachelinhalt.ersatz`) — nur an einer Sammlung ohne eigenes
              * Plakat (`Sammlungsmosaik`). Ueberall sonst `null`, und hier steht das Bild wie vorher.
              */
             ersatz: (@Composable () -> Unit)? = null, tun: () -> Unit) {
    val breite = if (quer) TvStil.querBreite else TvStil.posterBreite
    Column(modifier.width(breite)) {
        Fokusflaeche(fokusGeaendert = fokusGeaendert, tun = tun) {
            Box(Modifier.size(breite, if (quer) TvStil.querHoehe else TvStil.posterHoehe)
                    .clip(RoundedCornerShape(TvStil.eckeKachel)).background(Stil.flaeche)) {
                // Kein eigener Platzhalter-Zeichentrick: fehlt das Bild oder laedt es noch,
                // bleibt `Stil.flaeche` sichtbar — genau das Verhalten von `Bild` in
                // `Sources/tvOS/Stil.swift` (dort auch nur eine Flaeche, kein Symbol).
                if (ersatz != null) Box(Modifier.fillMaxSize().alpha(deckkraft)) { ersatz() }
                else AsyncImage(model = bild, contentDescription = titel, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize().alpha(deckkraft))
                // Vorlage: `Fortschrittsbalken` in `Sources/tvOS/Stil.swift` — **buendig an der
                // Unterkante, volle Breite, eckig**; die Rundung kommt allein vom Beschnitt der Kachel.
                // Vorher schwebte hier eine eingerueckte Pille ueber dem Bild.
                fortschritt?.takeIf { it > 0 }?.let { a ->
                    // 4 hoch (tvOS 8, halbiert), Spur **weiss 30 %** wie ueberall sonst.
                    Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(4.dp)
                            .background(Color.White.copy(alpha = 0.30f))) {
                        Box(Modifier.fillMaxWidth(a.toFloat().coerceIn(0f, 1f)).fillMaxHeight().background(Stil.akzent))
                    }
                }
                // Vorlage: `Kachelplakette` in `Sources/tvOS/TVBausteine.swift` — Haken, „N offen"
                // oder „N Staffeln". Steht auch ueber einem fehlenden Plakat, wie auf tvOS.
                marke?.let { Kachelplakette(it, markenzahl, Modifier.align(Alignment.TopEnd)) }
            }
        }
        Text(titel, style = TvStil.kachel, color = if (titelLeise) Stil.schriftLeise else Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 7.dp))
        // Angabe unter dem Plakat: 12 `schriftSehrLeise` — dieselbe Bauart wie am Telefon.
        unterzeile?.let { Text(it, style = TvStil.klein, color = Stil.schriftSehrLeise, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 1.dp)) }
    }
}

/** Reihentitel — steht ueber dem Streifen, mit derselben Einrueckung wie die Kacheln. */
@Composable
fun TvReihentitel(text: String, modifier: Modifier = Modifier) {
    Text(text, style = TvStil.reihe, color = Stil.schrift, maxLines = 1,
         modifier = modifier.padding(start = TvStil.randSeite, bottom = TvStil.titelAbstand - TvStil.reihenLuft))
}

/**
 * Vorlage: `Kopfverlauf` — dunkelt den oberen Rand ab, damit die Kopfleiste ueber durchlaufendem
 * Bildmaterial lesbar bleibt. **Nur auf Unterseiten der Bereiche**, nicht auf Start: dort steht eine
 * feste Heldenzone ueber der scrollenden Liste, darunter kommt nichts mehr unter die Leiste — genau
 * die Begruendung, mit der tvOS den Verlauf dort wegliess.
 *
 * Punktwerte aus tvOS **halbiert zu dp**, dieselben Stuetzpunkte wie dort (drei waeren eine
 * sichtbare Kante an der Stelle, an der die Steigung umspringt).
 */
@Composable
fun TvKopfverlauf(modifier: Modifier = Modifier, kopfhoehe: Dp = 64.dp, ausklang: Dp = 110.dp) {
    val gesamt = kopfhoehe + ausklang
    fun punkt(y: Dp, deckung: Float) = (y.value / gesamt.value).coerceIn(0f, 1f) to Stil.grund.copy(alpha = deckung)
    val stufen = listOf(
        punkt(0.dp, 0.92f),
        punkt(kopfhoehe, 0.90f),
        punkt(kopfhoehe + 9.dp, 0.72f),
        punkt(kopfhoehe + 18.dp, 0.52f),
        punkt(kopfhoehe + 27.dp, 0.34f),
        punkt(kopfhoehe + 36.dp, 0.18f),
        punkt(kopfhoehe + 43.dp, 0.09f),
        punkt(kopfhoehe + 52.dp, 0.04f),
        punkt(kopfhoehe + 66.dp, 0.015f),
        punkt(gesamt, 0f),
    )
    Box(modifier.fillMaxWidth().height(gesamt)
            .background(Brush.verticalGradient(colorStops = stufen.toTypedArray())))
}

/**
 * Vorlage: `Hinweisstreifen` in `Sources/tvOS/Stil.swift` — Warnband mit Dreieck und Text, geht nach
 * sechs Sekunden von selbst. Masse gegenueber tvOS halbiert, wie ueberall sonst in `TvStil`.
 * Angebunden wie am Handy (`TitelSeite.Hinweisstreifen`): eigener `meldung`-Zustand je Seite, kein
 * geteilter Ort wie `AppModel.errorMessage` auf tvOS — Android hat keine solche Quelle.
 */
@Composable
fun TvHinweisstreifen(text: String, modifier: Modifier = Modifier, schliessen: () -> Unit) {
    LaunchedEffect(text) {
        kotlinx.coroutines.delay(6000)
        schliessen()
    }
    Row(modifier.widthIn(max = 550.dp)
            .clip(RoundedCornerShape(TvStil.ecke))
            .background(Stil.erhoeht)
            .border(1.dp, Stil.warnung.copy(alpha = 0.3f), RoundedCornerShape(TvStil.ecke))
            .padding(horizontal = 15.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Symbol(Zeichen.Warnung, 13.dp, farbe = Stil.warnung)
        Text(text, style = TvStil.kachel, color = Stil.warnung, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

/**
 * Vorlage: der Discord-Hinweis auf tvOS (`Codeblatt(ziel: .discord)`) — **einmal je Installation**,
 * nach dem fuenften zu Ende geschauten Titel (`Gemeinschaft.anstoss`). Statt des QR-Codes die
 * Einladung zum Abtippen: ein QR-Bild braeuchte hier eine eigene Bibliothek. Zurueck schliesst.
 */
@Composable
fun TvDiscordhinweis(einladung: String, schliessen: () -> Unit) {
    androidx.activity.compose.BackHandler(onBack = schliessen)
    val fokus = remember { androidx.compose.ui.focus.FocusRequester() }
    LaunchedEffect(Unit) { runCatching { fokus.requestFocus() } }
    Box(Modifier.fillMaxSize().background(Stil.grund), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(uebersetzt("Swiftly hat einen Discord"), style = TvStil.titelGross, color = Stil.schrift)
            Text(uebersetzt("Da kannst du Fragen stellen und Fehler melden. Neue Builds stehen da auch zuerst."),
                 style = TvStil.koerper.copy(textAlign = TextAlign.Center), color = Stil.schriftLeise,
                 modifier = Modifier.widthIn(max = 550.dp).padding(top = 8.dp))
            Text(einladung, style = TvStil.titelGross, color = Stil.schrift, modifier = Modifier.padding(top = 36.dp))
            TvKnopf(uebersetzt("Zurück"), modifier = Modifier.padding(top = 36.dp).focusRequester(fokus), tun = schliessen)
        }
    }
}
