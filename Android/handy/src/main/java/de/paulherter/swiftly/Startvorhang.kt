package de.paulherter.swiftly

import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.withFrameNanos
import kotlinx.coroutines.launch
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.airbnb.lottie.compose.LottieAnimation
import com.airbnb.lottie.compose.LottieCompositionSpec
import com.airbnb.lottie.compose.rememberLottieComposition
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.bewegungReduziert
import kotlinx.coroutines.delay
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Vorlage: `Startvorhang` + `Startanimation` in `Sources/Shared/Startanimation.swift` — dieselbe
 * Lottie-Datei, einmal abgespielt, 440 gross.
 *
 * **Ein halber Takt Nachlauf**, bevor der Vorhang faellt: sonst wirkt die Marke nur durchgereicht.
 * Kommt das Ende nie an (die App lag im Hintergrund), faellt er spaetestens nach 3,5 Sekunden.
 * Beide Wege laufen durch einen Riegel — `fertig` wird nie zweimal gerufen.
 *
 * **Bild fuer Bild statt nach der Uhr.** `animateLottieCompositionAsState` rechnet den Fortschritt aus
 * der verstrichenen Zeit. Unter dem Vorhang baut sich aber gleichzeitig die ganze App auf (Kern laden,
 * Sitzung, erste Seite) — jedes lange Bild darin sprang ein Stueck der 1,3 Sekunden ueber: das Dreieck
 * ruckte, die Buchstaben standen schon halb, oder man sah nur noch das Ende. Jetzt zaehlt je Bild
 * hoechstens ein Dreissigstel: ein Haenger verlangsamt die Animation kurz, statt sie zu zerschneiden.
 * Die Frist von 3,5 Sekunden laeuft erst ab dem ersten Bild der Animation (vorher schnitt ein langsames
 * Laden der Datei sie ab); liegt die Datei gar nicht vor, faellt der Vorhang nach derselben Frist.
 */
@Composable
fun Startvorhang(fertig: () -> Unit) {
    val komposition by rememberLottieComposition(LottieCompositionSpec.Asset("startanimation.json"))
    var fortschritt by remember { mutableFloatStateOf(0f) }
    val einmal = remember { AtomicBoolean(false) }
    val rufen = { if (einmal.compareAndSet(false, true)) fertig() }
    // Lottie kennt „Animationen entfernen" nicht — dann faellt der Vorhang sofort.
    val ruhig = bewegungReduziert()
    LaunchedEffect(ruhig) { if (ruhig) rufen() }
    LaunchedEffect(komposition) {
        val k = komposition
        if (k == null) { delay(3500); if (komposition == null) rufen(); return@LaunchedEffect }
        val dauer = k.duration.coerceAtLeast(1f)
        launch { delay(3500); rufen() }
        var zuletzt = withFrameNanos { it }
        while (fortschritt < 1f) {
            val jetzt = withFrameNanos { it }
            val schritt = ((jetzt - zuletzt) / 1_000_000f).coerceIn(0f, 1000f / 30f)
            zuletzt = jetzt
            fortschritt = (fortschritt + schritt / dauer).coerceAtMost(1f)
        }
        delay(500)
        rufen()
    }
    Box(Modifier.fillMaxSize().background(Stil.grund), contentAlignment = Alignment.Center) {
        // Der Vorhang sagt, wer da startet — sonst saesse TalkBack bis zu 3,5 s vor einer stummen Flaeche.
        LottieAnimation(komposition, { fortschritt }, Modifier.size(440.dp).clearAndSetSemantics { contentDescription = "Swiftly" })
    }
}
