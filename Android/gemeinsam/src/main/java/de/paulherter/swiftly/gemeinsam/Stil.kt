package de.paulherter.swiftly.gemeinsam

import android.content.Context
import android.provider.Settings
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * **Die Gestaltung des Telefons — abgeschrieben, nicht erfunden.**
 *
 * Vorlage: `Sources/Shared/Farben.swift` (Farben) und `Sources/Shared/Stil.swift`
 * (Masse, Schrift — Abschnitte „Maße — iPhone" und „Schrift — iPhone").
 * **Nie aus `Sources/macOS/Stil.swift`**: das ist die Mac-Datei mit anderen Zahlen,
 * und genau diese Verwechslung hat auf Linux eine ganze Runde gekostet.
 *
 * Aendert sich dort ein Wert, aendert er sich hier — dieselben Namen. Die Begruendung
 * zu jeder Entscheidung steht in `Notizen/BRAND.md`, die Masstabelle in
 * `Notizen/BAUTEILE.md`.
 *
 * **dp statt pt.** Ein iOS-Punkt und ein Android-dp sind dasselbe Mass (1/160 Zoll
 * gegen 1/163 Zoll bei Apple) — die Zahlen werden deshalb unveraendert
 * uebernommen, Schriftgrade als `sp`, damit die Systemschriftgroesse sie
 * mitzieht (das ist Dynamic Type auf Android, und es kostet hier nichts).
 */
/**
 * **Die Bewegungen des Telefons** — Vorlage: die Kurven in `Sources/Shared/Stil.swift`
 * (`einblenden`, `bereichswechsel`, `sprung`, `umschalten`, `blattbewegung`) und das Push von
 * `NavigationStack`. `.smooth` und `.snappy` federn nicht nach: schnell an, weich aus.
 */
object Bewegung {
    val weich = CubicBezierEasing(0.2f, 0f, 0f, 1f)
    /** `easeOut` — Apples Kurve, dieselbe Zahlen wie `UIView.AnimationCurve.easeOut`. */
    val ausklang = CubicBezierEasing(0f, 0f, 0.58f, 1f)
    /**
     * **Die Navigationskurve von UIKit, nachgemessen** — dieselbe, die compose-cupertino fuer
     * `UINavigationController` nimmt. Mehrere eigene Anlaeufe davor sahen am Pixel falsch aus.
     */
    val cupertino = CubicBezierEasing(0.2833f, 0.99f, 0.31833f, 0.99f)
    /** `Stil.einblenden` — `.smooth(duration: 0.28)`. Kacheln, Bilder, Platzhalter ↔ Inhalt. */
    fun <T> einblenden(): FiniteAnimationSpec<T> = tween(280, easing = weich)
    /** `Stil.bereichswechsel` — `.snappy(duration: 0.20)`. */
    fun <T> bereichswechsel(): FiniteAnimationSpec<T> = tween(200, easing = weich)
    /** `Stil.sprung` — `.snappy(duration: 0.22)`. Aufklappen, Pfeile. */
    fun <T> sprung(): FiniteAnimationSpec<T> = tween(220, easing = weich)
    /** `Stil.umschalten` — `.easeOut(duration: 0.1)`. */
    fun <T> umschalten(): FiniteAnimationSpec<T> = tween(100, easing = ausklang)
    /** `Stil.blattbewegung` — `.spring(response: 0.35, dampingFraction: 0.86)`; Steifigkeit (2π / 0,35)² ≈ 322. */
    fun <T> blatt(): FiniteAnimationSpec<T> = spring(dampingRatio = 0.86f, stiffness = 322f)
    /** `Stil.blendeReduziert` — 0,14 s linear, wenn jemand Bewegung reduziert hat. */
    fun <T> blendeReduziert(): FiniteAnimationSpec<T> = tween(140, easing = LinearEasing)
    /**
     * Das Push von `NavigationStack` — rund 350 ms, rasch an und lange auslaufend. **Nicht die
     * UIKit-Kurve**: fuers Oeffnen war sie am Pixel zu schnell; fuers Zurueck ist sie genau richtig.
     */
    fun <T> seite(): FiniteAnimationSpec<T> = tween(350, easing = CubicBezierEasing(0.25f, 0.8f, 0.25f, 1f))
    /** Zurueck ueber den Knopf — **gleich lang wie das Oeffnen**: ungleiche Dauern lesen sich als falsche Kurve. */
    fun <T> zurueck(): FiniteAnimationSpec<T> = tween(350, easing = cupertino)
    /**
     * **Nach einer Geste weiter mit dem Tempo des Fingers** — ohne Nachfedern, damit ein Wurf
     * nicht erst bremst und dann neu ansetzt. Fuer Zurueckgeste und weggeworfenes Blatt.
     */
    // Wie compose-cupertino beim Loslassen: eine schnelle Feder ohne Nachschwingen (StiffnessMedium).
    fun <T> wurf(): FiniteAnimationSpec<T> = spring(dampingRatio = 1f, stiffness = 1500f)
    /**
     * `druckkurve` beim Loslassen — 0,12 s **`easeOut`**, nicht linear. Das Druecken selbst hat
     * **keine** Dauer: eine Rueckmeldung, die einblendet, kommt zu spaet (BRAND 6).
     */
    fun <T> loslassen(): FiniteAnimationSpec<T> = tween(120, easing = ausklang)
    /** `Stil.bereichsmass` — dreimal nach unten korrigiert: 0,97 und 0,99 sah man an der Oberkante. */
    const val BEREICHSMASS = 0.995f
    /** `Stil`-Druckmass: Massstab 0,97 an **jedem** Knopf (BRAND 5). */
    const val DRUCKMASS = 0.97f

    /**
     * **„Animationen entfernen" / „Bewegung reduzieren".**
     *
     * Android setzt bei ausgeschalteten Animationen die Dauer aller Compose-Animationen selbst
     * auf null — fuer einmalige Bewegungen ist damit nichts zu tun. **Dauerbewegung faellt
     * darunter nicht:** eine Endlosschleife mit Dauer 0 laeuft weiter, nur hart. Wer pulst
     * (Laderaster, atmendes Zeichen), fragt das hier ab, so wie `Stil.bewegungReduziert` auf
     * Apple abgefragt wird.
     */
    fun reduziert(context: Context): Boolean =
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
}

/**
 * Dasselbe, **einmal je Ansicht gelesen statt einmal je Bild.**
 *
 * `Bewegung.reduziert` fragt den Systemspeicher; in `Fokusflaeche` steht dieser Aufruf hinter
 * jeder Kachel einer Reihe und liefe bei jedem Neuaufbau erneut. Die Einstellung aendert sich
 * waehrend einer Ansicht nicht.
 */
@Composable
fun bewegungReduziert(): Boolean {
    val kontext = LocalContext.current
    return remember(kontext) { Bewegung.reduziert(kontext) }
}

object Stil {
    // MARK: Farben — Farben.swift, woertlich
    //
    // **Alle neutralen Toene sind echt neutral: R = G = B, Chroma 0,000.** Das ist die Regel,
    // die am teuersten gelernt wurde: sie standen nacheinander auf Hue 285,9 Grad (las sich
    // roetlich), auf der Hue des Akzents (gruenstichig) und auf Apples Spur Blau. Wer hier
    // wieder dreht, liest erst BRAND 1.
    //
    // Grund und Flaechen sind aus Plex ausgezaehlt, Bildpunkt fuer Bildpunkt — gemessen, nicht
    // gewaehlt. Reines Schwarz gibt es an genau einer Stelle: hinter dem Bild im Player.

    /** Der Grund **jeder** Seite. */
    val grund = Color(0xFF101010)
    /** Die Karte auf einer Einstellungsseite — ein grosser, ruhiger Block. */
    val gruppenflaeche = Color(0xFF1E1E1E)
    /** **Alles, was man anfassen kann:** Knoepfe, Felder, Pillen, Blaetter. Ein Ton, nicht zwei. */
    val flaeche = Color(0xFF262626)
    /** Was auf einer `flaeche` liegt: gewaehlter Chip, gewaehlte Zeile. */
    val erhoeht = Color(0xFF303030)
    /**
     * Die Flaeche eines **gedrueckten** Sekundaerknopfs. Eigener Wert, kein
     * `erhoeht.copy(alpha = 1.6f)` — Deckkraft ueber 1 klemmt auf 1,0, und der Druck war
     * unsichtbar. **Nur volle Schrift darauf** (`schriftSehrLeise` traegt hier 3,94:1).
     */
    val gedruecktFlaeche = Color(0xFF3A3A3A)

    /**
     * **Volle Werte, keine Deckkraft.** Deckkraft aendert ihre Wirkung, sobald etwas anderes
     * darunter liegt — ueber einem Plakat wurde aus „leise" „unlesbar". Gerechnet auf `grund`:
     * 19,03 / 11,85 / 6,60; auf `flaeche` 15,13 / 9,42 / 5,25; auf `erhoeht` 13,20 / 8,22 / 4,58.
     */
    val schrift = Color(0xFFFFFFFF)
    val schriftLeise = Color(0xFFCCCCCC)
    val schriftSehrLeise = Color(0xFF989898)

    /** Haarlinie zwischen Zeilen. Als Deckkraft, weil sie auch ueber Plakaten liegt. */
    val linie = Color.White.copy(alpha = 0.07f)
    /** Die wenigen Stellen, die eine Kante brauchen. **Knoepfe, Felder und Pillen nicht.** */
    val rand = Color.White.copy(alpha = 0.12f)
    /** Die Flaeche einer gewaehlten oder laufenden Zeile. */
    val gewaehlt = Color.White.copy(alpha = 0.08f)

    /**
     * **Traegt Zustand — nie Rangfolge, nie eine Flaeche, nie eine blosse Angabe** (BRAND 1).
     * Fortschritt, Auswahl, Direct-Play-Beleg.
     */
    val akzent = Color(0xFF50D5DA)
    /** Der Akzent aufgehellt — **nur der gewaehlte Filterchip im Fokus am Fernseher.** */
    val akzentHell = Color(0xFF7AE6EA)
    /** Die Flaeche unter Akzentschrift (Plaketten tragen 15 %, dies ist der Ton ausgerechnet). */
    val akzentLeise = Color(0xFF113435)
    /** Schrift auf einer Akzentflaeche. */
    val aufAkzent = Color(0xFF061212)

    /** Etwas wartet auf jemanden. */
    val warnung = Color(0xFFE8833A)
    /** Etwas ist schiefgegangen — **nicht dasselbe wie „wartet".** Traegt keinen Text auf `erhoeht` (4,23). */
    val fehler = Color(0xFFEF6567)

    /**
     * **Die acht Toene der Profilzeichen** — acht Hues im Abstand von 45 Grad, der erste ist der
     * des Akzents, alle mit derselben Helligkeit und Saettigung (OKLCH L 0,52 / C 0,105 oben,
     * L 0,36 / C 0,085 unten). Die Farbe wird aus dem Namen gerechnet, dieselbe Person bekommt
     * immer dieselbe. Sie sagen nichts ueber einen Zustand, sie unterscheiden nur Personen.
     */
    val profiltoene: List<Pair<Color, Color>> = listOf(
        Color(0xFF007A7F) to Color(0xFF004A4E),
        Color(0xFF286EA1) to Color(0xFF054166),
        Color(0xFF675EA1) to Color(0xFF3C3467),
        Color(0xFF8D5082) to Color(0xFF572A50),
        Color(0xFF9C4D51) to Color(0xFF62282B),
        Color(0xFF925A1B) to Color(0xFF5B3100),
        Color(0xFF6E6D14) to Color(0xFF414000),
        Color(0xFF2E7A4C) to Color(0xFF0A4A27),
    )

    // MARK: Ecken — Stil.swift
    //
    // Verschachtelt gilt: aussen = innen + Innenabstand. **Keine Schatten, keine gezeichneten
    // Raender** — eine Flaeche sagt „hier kann man druecken", ein Rand sagt es ein zweites Mal.
    //
    // Compose rundet von sich aus wie Apples `.circular`; Apples `.continuous` faellt flacher an
    // und laeuft laenger aus. Der Unterschied ist bei 8 bis 16 dp gerade an der Wahrnehmungs-
    // schwelle und liesse sich nur mit einem eigenen `Shape` nachbauen — das waere eine eigene
    // Bezier-Rechnung an jedem Bauteil. Bewusst nicht gemacht; steht als offener Punkt.

    /** Knopf, Plakat, Kachel — unter 48 dp Hoehe. */
    val ecke = 10.dp
    val eckeKachel = 10.dp
    /** Such- und Eingabefeld. */
    val eckeFeld = 12.dp
    /** Unter 34 dp Hoehe: Staffelfeld, Plaketten. */
    val eckeKlein = 8.dp
    /** Einstellungskarte, Gruppe. */
    val eckeKarte = 14.dp
    /** Eigene Flaeche, Tafel, Auskunftskasten. */
    val eckeFlaeche = 16.dp
    /** Blatt von unten — nur oben. */
    val eckeBlatt = 28.dp

    // MARK: Raum — Stil.swift, „Maße — iPhone"

    /** Der Seitenrand und damit der haeufigste Abstand der App. */
    val randAbstand = 18.dp
    /** Der Seitenrand in der breiten Fassung (Tablet, aufgeklapptes Faltgeraet). */
    val randSeiteBreit = 28.dp
    val kachelAbstand = 12.dp
    /** Reihe zu Reihe auf der Startseite. */
    val reihenAbstand = 28.dp
    /** Zeilenabstand im Raster — Bibliothek, Merkliste, Genre, Suche. */
    val rasterZeile = 20.dp
    val kopfOben = 26.dp
    val kachelBreite = 112.dp
    val kachelHoehe = 168.dp
    val heldHoehe = 300.dp
    val heldHoeheBreit = 420.dp
    val leisteHoehe = 54.dp
    val seitenleisteBreite = 88.dp
    /** 30 Pillenhoehe + 14 Abstand — so weit klappt die Wertreihe beim Scrollen zu. */
    val wertreihenWeg = 44.dp
    val lesebreite = 700.dp
    val formularbreite = 420.dp

    /** Hoehe jedes Knopfs und jedes Eingabefelds. */
    val knopfHoehe = 48.dp
    /** Hoehe von Wertpille und Wahlchip (als Mindesthoehe). */
    val pillenHoehe = 30.dp
    /** Trefferflaeche eines stillen Knopfs. */
    val stillHoehe = 44.dp

    /** Zielbreite einer Rasterkachel — `kachelZiel(breit: false)`. */
    const val kachelZiel = 104f

    /** `Stil.rand(breit:)` — 18 schmal, 28 breit. */
    fun rand(breit: Boolean) = if (breit) randSeiteBreit else randAbstand

    /** `Stil.spalten(nutzbar:breit:)` — Kacheln dehnen sich, auf jedem Telefon kommen drei heraus. */
    fun spalten(nutzbar: Float): Int = maxOf(2, ((nutzbar + 12f) / (kachelZiel + 12f)).toInt())

    // MARK: Schrift — Stil.swift, „Schrift — iPhone"
    //
    // **Zehn Stufen, neun Grade, drei Schnitte.** Regular, Medium, Semibold — dazu Bold genau
    // einmal am Seitentitel. `.light` und `.heavy` gibt es nicht, ohne Ausnahme.
    //
    // Die **Sperrung haengt an der Stufe, nicht an der Fundstelle**; jeder Wert ist der em-Wert
    // aus BRAND 2 mal der Punktgroesse. In Compose ist `letterSpacing` in `sp` dasselbe Mass wie
    // SwiftUIs `tracking` in Punkt.
    //
    // **Gesperrt wird nur, was in Versalien steht** — die Kachelmarke traegt „3 offen", also
    // gewoehnliche Woerter, und nimmt die Sperrung ihrer Stufe nicht.

    /** 28 Bold — der Titel einer Wurzelseite, auch ueber einem Heldbild. */
    val titelGross = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.6).sp)
    /** Dieselbe Stufe. `titel` und `titelGross` sind am iPhone derselbe Wert. */
    val titel = titelGross
    /** 22 Semibold — eine Unterseite, also eine mit Rueckweg. */
    val unterseitentitel = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.308).sp)
    /** 20 Semibold — Reihenueberschrift, Gruppentitel, Kopfzeile eines Leerzustands. */
    val reihe = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.24).sp)
    /** 17 Semibold — Blattrubrik, Detailleiste, Hauptknopf. */
    val rubrikGross = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.136).sp)
    /** 15 Semibold — die Listenzeile. */
    val listentitel = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    /** 15 Regular — Fliesstext. */
    val koerper = TextStyle(fontSize = 15.sp)
    /** 15 Medium — Sekundaerknopf und stiller Knopf. */
    val knopftext = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium)
    /** 13 Medium — Titel unter einem Plakat, Wertpille, Zaehlmarke, Wahlchip. */
    val kachel = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium)
    /** 13 Semibold — der Winkel rechts in einer Zeile. */
    val winkel = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    /** 12 Regular — Angabe: Jahr, Rolle, Laufzeit, Unterzeile. */
    val klein = TextStyle(fontSize = 12.sp)
    /** 11 Semibold, gesperrt — Gruppentitel in Versalien. */
    val gruppe = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.54.sp)
    /** 10 Semibold, gesperrt — Plakette und Kachelmarke. */
    val plakette = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.0.sp)

    // MARK: Zeichen
    //
    // Bedienzeichen stehen in derselben Groesse wie der Text, neben dem sie stehen — 17 in einer
    // 20 breiten Spalte in der Zeile, 17 im Feld, 20 in der Navileiste (BAUTEILE 6/7).
    val zeichen = 17.dp
    val zeichenSpalte = 20.dp
    val zeichenLeiste = 20.dp
    /** Das Zeichen in einem Leerzustand, im Kreis von 78. */
    val zeichenLeer = 44.dp
    val kreisLeer = 78.dp
}
