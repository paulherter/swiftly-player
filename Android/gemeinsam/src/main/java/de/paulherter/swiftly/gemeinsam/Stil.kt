package de.paulherter.swiftly.gemeinsam

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.ui.graphics.Color
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
 * Aendert sich dort ein Wert, aendert er sich hier — dieselben Namen.
 */
/**
 * **Die Bewegungen des Telefons** — Vorlage: die Kurven in `Sources/Shared/Stil.swift`
 * (`einblenden`, `bereichswechsel`, `sprung`, `umschalten`, `blattbewegung`) und das Push von
 * `NavigationStack`. `.smooth` und `.snappy` federn nicht nach: schnell an, weich aus.
 */
object Bewegung {
    val weich = CubicBezierEasing(0.2f, 0f, 0f, 1f)
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
    /** `Stil.umschalten` — `.snappy(duration: 0.1)`. */
    fun <T> umschalten(): FiniteAnimationSpec<T> = tween(100, easing = weich)
    /** `Stil.blattbewegung` — `.spring(response: 0.35, dampingFraction: 0.86)`; Steifigkeit (2π / 0,35)² ≈ 322. */
    fun <T> blatt(): FiniteAnimationSpec<T> = spring(dampingRatio = 0.86f, stiffness = 322f)
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
    /** `druckkurve` beim Loslassen. Das Druecken selbst hat **keine** Dauer. */
    fun <T> loslassen(): FiniteAnimationSpec<T> = tween(120, easing = LinearEasing)
    /** `Stil.bereichsmass` — dreimal nach unten korrigiert: 0,97 und 0,99 sah man an der Oberkante. */
    const val BEREICHSMASS = 0.995f

    // Reduzierte Bewegung: Android setzt bei „Animationen entfernen" die Dauer aller Compose-
    // Animationen selbst auf null. Das ist dort die Erwartung; was sich nicht daran haelt (Lottie),
    // fragt die Einstellung selbst ab.
}

object Stil {
    // Farben — Farben.swift
    val grund = Color(0xFF0B0B0D)
    val flaeche = Color(0xFF161619)
    val erhoeht = Color(0xFF1E1E22)
    val schrift = Color.White
    val schriftLeise = Color.White.copy(alpha = 0.62f)
    val schriftSehrLeise = Color.White.copy(alpha = 0.48f)
    val linie = Color.White.copy(alpha = 0.07f)
    val rand = Color.White.copy(alpha = 0.12f)
    val akzent = Color(0xFF5CD1C2)
    val kuehl = Color(0xFF7E9BFF)
    val scheinMitte = Color(0xFF6EB4E1)
    val warnung = Color(0xFFE8833A)

    // Masse — Stil.swift, „Maße — iPhone"
    val ecke = 10.dp
    val eckeKachel = 10.dp
    val eckeFeld = 12.dp
    val eckeFlaeche = 16.dp
    val randAbstand = 18.dp
    val kachelAbstand = 12.dp
    val reihenAbstand = 28.dp
    val kachelBreite = 112.dp
    val kachelHoehe = 168.dp
    val heldHoehe = 300.dp
    val leisteHoehe = 54.dp
    val formularbreite = 420.dp
    /** Zielbreite einer Rasterkachel — `kachelZiel(breit: false)`. */
    const val kachelZiel = 104f

    /** `Stil.spalten(nutzbar:breit:)` — Kacheln dehnen sich, auf jedem Telefon kommen drei heraus. */
    fun spalten(nutzbar: Float): Int = maxOf(2, ((nutzbar + 12f) / (kachelZiel + 12f)).toInt())

    // Schrift — Stil.swift, „Schrift — iPhone"
    val titelGross = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.Bold)
    val titel = TextStyle(fontSize = 27.sp, fontWeight = FontWeight.Bold)
    val reihe = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
    val koerper = TextStyle(fontSize = 15.sp)
    val kachel = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium)
    val klein = TextStyle(fontSize = 12.sp)
    val listentitel = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    val plakette = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
}

