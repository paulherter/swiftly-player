package de.paulherter.swiftly.tv

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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Warning
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.Kachelplakette
import de.paulherter.swiftly.gemeinsam.Stil

/**
 * Vorlage: `Sources/tvOS/Stil.swift`. **Punkte halbiert zu dp** — tvOS rechnet auf 1920 Punkt,
 * ein 1080p-Fernseher hat unter Android 960 dp. Farben kommen unveraendert aus `Stil`.
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
    val ecke = 6.dp
    val eckeKachel = 8.dp
    const val gitterSpalten = 7
    val gitterSpalte = 25.dp
    val gitterZeile = 36.dp

    /** Bewusst wenig: Apples Karte springt weiter und schiebt die Nachbarn optisch weg. */
    const val fokusLupe = 1.08f
    val fokusflaeche = Color.White.copy(alpha = 0.12f)
    /** `.easeOut(duration: 0.14)`. */
    val fokusKurve = CubicBezierEasing(0f, 0f, 0.58f, 1f)
    const val fokusDauer = 140
    /** Seitenscroll beim Abschnittswechsel (`TvAbschnitte`) — ruhiger als die Lupe, dieselbe Kurve. */
    const val abschnittDauer = 300

    val titelGross = TextStyle(fontSize = 28.5.sp, fontWeight = FontWeight.Bold)
    /** Vorlage: `Kopfauskunft`-Titel — 60 pt, `tracking(-1.4)`, halbiert. */
    val auskunftTitel = TextStyle(fontSize = 30.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.7).sp)
    /** Vorlage: `Kopfauskunft`-Zweitzeile (Folgentitel) — 38 pt semibold, `tracking(-0.3)`, halbiert. */
    val auskunftZweitzeile = TextStyle(fontSize = 19.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.15).sp)
    val reihe = TextStyle(fontSize = 19.sp, fontWeight = FontWeight.SemiBold)
    val koerper = TextStyle(fontSize = 14.5.sp)
    val kachel = TextStyle(fontSize = 13.5.sp, fontWeight = FontWeight.Medium)
    val klein = TextStyle(fontSize = 12.5.sp)

    // MARK: Kopfauskunft — gemeinsam fuer Start, Film und Serie

    /** `Stil.beschreibungZeile`/`beschreibungLuft`, halbiert. Nur fuer `beschreibungHoehe`. */
    private const val beschreibungZeile = 17.5f
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
    val mass by animateFloatAsState(if (fokus) lupe else 1f, tween(TvStil.fokusDauer, easing = TvStil.fokusKurve), label = "lupe")
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
fun TvKnopf(text: String?, symbol: ImageVector? = null, modifier: Modifier = Modifier, hoehe: Dp = TvStil.knopfHoehe,
            freigegeben: Boolean = true, symbolNachText: Boolean = false, fokusGeaendert: (Boolean) -> Unit = {}, tun: () -> Unit) {
    Fokusflaeche(modifier, lupe = 1.04f, fokusGeaendert = fokusGeaendert, tun = { if (freigegeben) tun() }) { fokus ->
        val farbe = if (!freigegeben) Stil.schriftSehrLeise else if (fokus) Stil.grund else Stil.schrift
        Row(Modifier.height(hoehe).then(if (text == null) Modifier.width(hoehe) else Modifier)
                .clip(RoundedCornerShape(TvStil.ecke))
                .background(if (!freigegeben) Stil.flaeche else if (fokus) Color.White else Color.White.copy(alpha = 0.10f))
                .padding(horizontal = if (text == null) 0.dp else 20.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
            val symbolInhalt: @Composable () -> Unit = { symbol?.let { Icon(it, contentDescription = text, tint = farbe, modifier = Modifier.size(17.dp)) } }
            val textInhalt: @Composable () -> Unit = { text?.let { Text(it, style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), color = farbe, maxLines = 1) } }
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
        textStyle = TextStyle(fontSize = 14.5.sp, color = farbe),
        cursorBrush = SolidColor(farbe),
        visualTransformation = if (geheim) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(imeAction = imeAction, keyboardType = tastaturTyp),
        keyboardActions = KeyboardActions(onDone = { tastaturAktion() }, onGo = { tastaturAktion() }, onSearch = { tastaturAktion() }),
        modifier = modifier.height(TvStil.knopfHoehe).onFocusChanged { fokus = it.isFocused },
        decorationBox = { innen ->
            Box(Modifier.fillMaxSize().clip(RoundedCornerShape(TvStil.ecke))
                    .background(if (fokus) Color.White else Stil.erhoeht)
                    .border(2.dp, if (fokus) Color.Transparent else Stil.rand, RoundedCornerShape(TvStil.ecke))
                    .padding(horizontal = 15.dp), contentAlignment = Alignment.CenterStart) {
                if (wert.isEmpty()) Text(platzhalter, style = TextStyle(fontSize = 14.5.sp),
                                        color = if (fokus) Stil.grund.copy(alpha = 0.45f) else Stil.schriftSehrLeise)
                innen()
            }
        })
}

/**
 * Vorlage: `ChipStil` — drei Zustaende: gewaehlt weiss, fokussiert ruhig, sonst erhoeht. **Immer
 * ein feiner Rand** (1 dp, halbiert aus tvOS' 2 pt) — nicht nur, solange der Fokus draufsteht.
 */
@Composable
fun TvChip(text: String, an: Boolean, modifier: Modifier = Modifier, tun: () -> Unit) {
    Fokusflaeche(modifier, lupe = 1.06f, tun = tun) { fokus ->
        Box(Modifier.height(TvStil.chipHoehe).clip(CircleShape)
                .background(when { an -> Color.White; fokus -> TvStil.fokusflaeche; else -> Stil.erhoeht })
                .border(1.dp, if (an) Color.White else Stil.rand, CircleShape)
                .padding(horizontal = 11.dp),
            contentAlignment = Alignment.Center) {
            Text(text, style = TextStyle(fontSize = 11.5.sp, fontWeight = FontWeight.Medium), color = if (an) Stil.grund else Stil.schrift, maxLines = 1)
        }
    }
}

/**
 * Vorlage: `KapselStil` — eine Kapsel, die etwas aufklappt (Bibliothek, Sortierung). Form und Hoehe
 * wie `TvChip`, damit die Reihe eine Form hat; halbfett und mit Pfeil dahinter. Fokus ist die ruhige
 * Flaeche, der Pfeil folgt der Schriftfarbe.
 */
@Composable
fun TvKapsel(text: String, modifier: Modifier = Modifier, tun: () -> Unit) {
    Fokusflaeche(modifier, lupe = 1.06f, tun = tun) { fokus ->
        Row(Modifier.height(TvStil.chipHoehe).clip(CircleShape)
                .background(if (fokus) TvStil.fokusflaeche else Stil.erhoeht)
                .border(1.dp, Stil.rand, CircleShape)
                .padding(horizontal = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(text, style = TextStyle(fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold), color = Stil.schrift, maxLines = 1)
            Icon(Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = Stil.schrift.copy(alpha = 0.6f), modifier = Modifier.size(12.dp))
        }
    }
}

/** Vorlage: `ZeilenStil` — Auswahllisten und Handlungstafel: keine Lupe, nur eine ruhige Flaeche. */
@Composable
fun TvZeile(text: String, symbol: ImageVector? = null, rechts: String? = null, haken: Boolean = false,
            modifier: Modifier = Modifier, tun: () -> Unit) {
    Fokusflaeche(modifier.fillMaxWidth(), lupe = 1f, tun = tun) { fokus ->
        Row(Modifier.fillMaxWidth().height(TvStil.zeilenHoehe).clip(RoundedCornerShape(TvStil.ecke))
                .background(if (fokus) TvStil.fokusflaeche else Color.Transparent).padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            symbol?.let { Icon(it, contentDescription = null, tint = Stil.schrift, modifier = Modifier.size(18.dp)) }
            Text(text, style = TextStyle(fontSize = 15.5.sp, fontWeight = if (fokus) FontWeight.SemiBold else FontWeight.Normal),
                 color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            rechts?.let { Text(it, style = TextStyle(fontSize = 14.sp), color = Stil.schriftLeise, maxLines = 1) }
            if (haken) Icon(Icons.Filled.Check, contentDescription = null, tint = Stil.akzent, modifier = Modifier.size(18.dp))
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
             modifier: Modifier = Modifier, deckkraft: Float = 1f, fokusGeaendert: (Boolean) -> Unit = {}, tun: () -> Unit) {
    val breite = if (quer) TvStil.querBreite else TvStil.posterBreite
    Column(modifier.width(breite)) {
        Fokusflaeche(fokusGeaendert = fokusGeaendert, tun = tun) {
            Box(Modifier.size(breite, if (quer) TvStil.querHoehe else TvStil.posterHoehe)
                    .clip(RoundedCornerShape(TvStil.eckeKachel)).background(Stil.flaeche)) {
                // Kein eigener Platzhalter-Zeichentrick: fehlt das Bild oder laedt es noch,
                // bleibt `Stil.flaeche` sichtbar — genau das Verhalten von `Bild` in
                // `Sources/tvOS/Stil.swift` (dort auch nur eine Flaeche, kein Symbol).
                AsyncImage(model = bild, contentDescription = titel, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize().alpha(deckkraft))
                // Vorlage: `Fortschrittsbalken` in `Sources/tvOS/Stil.swift` — **buendig an der
                // Unterkante, volle Breite, eckig**; die Rundung kommt allein vom Beschnitt der Kachel.
                // Vorher schwebte hier eine eingerueckte Pille ueber dem Bild.
                fortschritt?.takeIf { it > 0 }?.let { a ->
                    Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp)
                            .background(Color.White.copy(alpha = 0.22f))) {
                        Box(Modifier.fillMaxWidth(a.toFloat().coerceIn(0f, 1f)).fillMaxHeight().background(Stil.akzent))
                    }
                }
                // Vorlage: `Kachelplakette` in `Sources/tvOS/TVBausteine.swift` — Haken, „N offen"
                // oder „N Staffeln". Steht auch ueber einem fehlenden Plakat, wie auf tvOS.
                marke?.let { Kachelplakette(it, markenzahl, Modifier.align(Alignment.TopEnd)) }
            }
        }
        Text(titel, style = TvStil.kachel, color = Stil.schrift, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 7.dp))
        unterzeile?.let { Text(it, style = TvStil.klein, color = Stil.schriftLeise, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 1.dp)) }
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
        Icon(Icons.Filled.Warning, contentDescription = null, tint = Stil.warnung, modifier = Modifier.size(13.dp))
        Text(text, style = TvStil.kachel, color = Stil.warnung, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}
