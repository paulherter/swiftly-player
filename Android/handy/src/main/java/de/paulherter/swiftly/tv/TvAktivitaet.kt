package de.paulherter.swiftly.tv

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import de.paulherter.swiftly.Phase
import de.paulherter.swiftly.Startvorhang
import de.paulherter.swiftly.SwiftlyAnwendung
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Stil

/**
 * Vorlage: `Sources/tvOS/RootView.swift` — derselbe Ablauf wie auf dem Telefon, nur mit einer
 * Oberflaeche fuer drei Meter Entfernung. Startet ueber `LEANBACK_LAUNCHER`; Kern, Konten,
 * Einstellungen und Player teilt sie mit der Telefonfassung in derselben App.
 */
class TvAktivitaet : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as SwiftlyAnwendung
        setContent {
            var phase by remember { mutableStateOf<Phase>(if (app.sitzungWiederherstellen()) Phase.Start else Phase.Server) }
            LaunchedEffect(app.abgemeldet.intValue) { if (app.abgemeldet.intValue > 0) phase = Phase.Server }
            var gestartet by rememberSaveable { mutableStateOf(false) }
            Box(Modifier.fillMaxSize().background(Stil.grund)) {
                when (val p = phase) {
                    // Vorlage: `RootView` auf tvOS — echte TV-Seiten statt der Telefonseiten, die
                    // hier vorher standen (`ServerSeite`, `AnmeldeSeite`, `QuickConnectAnmeldung`).
                    // Siehe `TvAnmeldung.kt`.
                    Phase.Server -> TvServerSeite(app) { name, fassung -> phase = Phase.Anmeldung(name, fassung) }
                    is Phase.Anmeldung -> TvAnmeldeSeite(app, p.servername, p.fassung,
                        andererServer = { phase = Phase.Server }) { phase = Phase.Start }
                    // Nach einem Kontowechsel frisch — G4: die Stapel gehoeren dem vorigen Konto.
                    Phase.Start -> key(app.kontowechsel.intValue) { TvHaupt(app) }
                }
                AnimatedVisibility(!gestartet, enter = EnterTransition.None, exit = fadeOut(tween(450, easing = Bewegung.weich))) {
                    Startvorhang { gestartet = true }
                }
            }
        }
    }
}
