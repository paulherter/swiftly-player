package de.paulherter.swiftly.gemeinsam

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
