package de.paulherter.swiftly

import android.os.Bundle
import com.google.android.play.core.ktx.launchReview
import com.google.android.play.core.ktx.requestReview
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import de.paulherter.swiftly.gemeinsam.Stil

/** Vorlage: `RootView` in `Sources/Shared/RootView.swift` — Server, Anmeldung, dann die App. */
sealed interface Phase {
    data object Server : Phase
    data class Anmeldung(val servername: String, val fassung: String) : Phase
    data object Start : Phase
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // **Immer helle Symbole in der Statusleiste** — die App ist dunkel, egal was im
        // System eingestellt ist. Ohne Vorgabe richtet sich `enableEdgeToEdge` nach dem
        // Systemthema, und auf hellem Thema standen Uhr und Akku schwarz auf Schwarz.
        enableEdgeToEdge(
            statusBarStyle = androidx.activity.SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = androidx.activity.SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
        )
        val app = application as SwiftlyAnwendung
        setContent {
            var phase by remember { mutableStateOf<Phase>(if (app.sitzungWiederherstellen()) Phase.Start else Phase.Server) }
            // **Erst nach dem Player, mit einem Atemzug Abstand** — wie `RootView`: die Frage kommt,
            // wenn jemand gerade etwas zu Ende geschaut hat, nicht mitten in der Wiedergabe.
            androidx.compose.runtime.LaunchedEffect(app.bewertungFaellig.value, app.spiel.value == null) {
                if (!app.bewertungFaellig.value || app.spiel.value != null) return@LaunchedEffect
                app.bewertungFaellig.value = false
                kotlinx.coroutines.delay(1500)
                runCatching {
                    val verwalter = com.google.android.play.core.review.ReviewManagerFactory.create(this@MainActivity)
                    val auftrag = verwalter.requestReview()
                    verwalter.launchReview(this@MainActivity, auftrag)
                }
            }
            // Abgemeldet: zurueck zur Serverwahl.
            androidx.compose.runtime.LaunchedEffect(app.abgemeldet.intValue) { if (app.abgemeldet.intValue > 0) phase = Phase.Server }
            // Einmal je Start, nicht je Drehung — deshalb gemerkt.
            var gestartet by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
            Box(Modifier.fillMaxSize().background(Stil.grund)) {
                when (val p = phase) {
                    Phase.Server -> ServerSeite(app) { name, fassung -> phase = Phase.Anmeldung(name, fassung) }
                    is Phase.Anmeldung -> AnmeldeSeite(app, p.servername, p.fassung,
                        andererServer = { phase = Phase.Server }) { phase = Phase.Start }
                    // Nach einem Kontowechsel frisch — Stapel, Bereiche und Seiten gehoeren dem vorigen Konto.
                    Phase.Start -> androidx.compose.runtime.key(app.kontowechsel.intValue) { Hauptansicht(app) }
                }
                if (app.kleinesFenster.value) Bildimbildhinweis {
                    startActivity(android.content.Intent(this@MainActivity, PlayerAktivitaet::class.java))
                }
                // Der Vorhang faellt als reine Ueberblendung, 0,45 s — kein Rutschen, kein Wachsen.
                androidx.compose.animation.AnimatedVisibility(!gestartet,
                    enter = androidx.compose.animation.EnterTransition.None,
                    exit = androidx.compose.animation.fadeOut(androidx.compose.animation.core.tween(450, easing = de.paulherter.swiftly.gemeinsam.Bewegung.weich))) {
                    Startvorhang { gestartet = true }
                }
            }
        }
    }
}
