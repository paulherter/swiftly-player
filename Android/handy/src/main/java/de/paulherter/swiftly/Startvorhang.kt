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
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.airbnb.lottie.compose.LottieAnimation
import com.airbnb.lottie.compose.LottieCompositionSpec
import com.airbnb.lottie.compose.animateLottieCompositionAsState
import com.airbnb.lottie.compose.rememberLottieComposition
import de.paulherter.swiftly.gemeinsam.Stil
import kotlinx.coroutines.delay
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Vorlage: `Startvorhang` + `Startanimation` in `Sources/Shared/Startanimation.swift` — dieselbe
 * Lottie-Datei, einmal abgespielt, 440 gross.
 *
 * **Ein halber Takt Nachlauf**, bevor der Vorhang faellt: sonst wirkt die Marke nur durchgereicht.
 * Kommt das Ende nie an (die App lag im Hintergrund), faellt er spaetestens nach 3,5 Sekunden.
 * Beide Wege laufen durch einen Riegel — `fertig` wird nie zweimal gerufen.
 */
@Composable
fun Startvorhang(fertig: () -> Unit) {
    val komposition by rememberLottieComposition(LottieCompositionSpec.Asset("startanimation.json"))
    val fortschritt by animateLottieCompositionAsState(komposition, iterations = 1)
    val einmal = remember { AtomicBoolean(false) }
    val rufen = { if (einmal.compareAndSet(false, true)) fertig() }
    val amEnde = komposition != null && fortschritt >= 1f
    LaunchedEffect(amEnde) { if (amEnde) { delay(500); rufen() } }
    // Lottie kennt „Animationen entfernen" nicht — dann faellt der Vorhang sofort.
    val kontext = androidx.compose.ui.platform.LocalContext.current
    LaunchedEffect(Unit) {
        val masstab = android.provider.Settings.Global.getFloat(kontext.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
        if (masstab == 0f) rufen()
    }
    LaunchedEffect(Unit) { delay(3500); rufen() }
    Box(Modifier.fillMaxSize().background(Stil.grund), contentAlignment = Alignment.Center) {
        // Der Vorhang sagt, wer da startet — sonst saesse TalkBack bis zu 3,5 s vor einer stummen Flaeche.
        LottieAnimation(komposition, { fortschritt }, Modifier.size(440.dp).clearAndSetSemantics { contentDescription = "Swiftly" })
    }
}
