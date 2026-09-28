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
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.layer.drawLayer
import de.paulherter.swiftly.gemeinsam.Stil

/** Vorlage: `RootView` in `Sources/Shared/RootView.swift` — Server, Anmeldung, dann die App. */
sealed interface Phase {
    data object Server : Phase
    data class Anmeldung(val servername: String, val fassung: String) : Phase
    data object Start : Phase
}

/**
 * Gibt den Start an die passende Einstiegsaktivitaet weiter (Telefon oder Fernseher) und schliesst
 * die aktuelle, bevor sie etwas zeichnet. Aktion, Kategorien, Adresse und Extras reisen mit.
 */
internal fun ComponentActivity.einstiegWechseln(ziel: Class<*>) {
    android.util.Log.i("Swiftly", "Einstieg: ${javaClass.simpleName} -> ${ziel.simpleName}")
    startActivity(android.content.Intent(intent).setClass(this, ziel)
        .addFlags(android.content.Intent.FLAG_ACTIVITY_NO_ANIMATION))
    finish()
    @Suppress("DEPRECATION") overridePendingTransition(0, 0)
}

class MainActivity : ComponentActivity() {
    /** Der eigene Aufruf fuer die Mitteilungsfrage — beim Beenden nur wegnehmen, wenn er noch der aktuelle ist. */
    private var meldungsrechtAufruf: (() -> Unit)? = null

    override fun onDestroy() {
        val app = application as SwiftlyAnwendung
        if (app.meldungsrechtFragen === meldungsrechtAufruf) app.meldungsrechtFragen = null
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // **Auf dem Fernseher gleich weiter in die TV-Oberflaeche.** Der normale Starter-Einstieg
        // (etwa „Oeffnen" nach der Installation im Appstore) landet sonst hier, in der Telefonfassung;
        // erst der Leanback-Starter oeffnete `TvAktivitaet`. Vor dem ersten Bild, ohne Uebergang.
        if ((application as SwiftlyAnwendung).istFernseher) { einstiegWechseln(de.paulherter.swiftly.tv.TvAktivitaet::class.java); return }
        // Messmodus des Technikschilds als Startextra, wie `-technikschildMessen YES` auf Apple.
        if (intent?.hasExtra("technikschildMessen") == true)
            (application as SwiftlyAnwendung).einstellungen.technikschildMessen = intent.getBooleanExtra("technikschildMessen", false)
        // **Immer helle Symbole in der Statusleiste** — die App ist dunkel, egal was im
        // System eingestellt ist. Ohne Vorgabe richtet sich `enableEdgeToEdge` nach dem
        // Systemthema, und auf hellem Thema standen Uhr und Akku schwarz auf Schwarz.
        enableEdgeToEdge(
            statusBarStyle = androidx.activity.SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = androidx.activity.SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
        )
        val app = application as SwiftlyAnwendung
        // Die Frage nach Mitteilungen stellt der erste Download (`SwiftlyAnwendung.meldungsrechtFragen`);
        // die Antwort braucht niemand — abgelehnt laufen die Downloads nur ohne Meldung.
        val meldungsrecht = registerForActivityResult(androidx.activity.result.contract.ActivityResultContracts.RequestPermission()) {}
        val fragen = { if (android.os.Build.VERSION.SDK_INT >= 33) meldungsrecht.launch(android.Manifest.permission.POST_NOTIFICATIONS) }
        app.meldungsrechtFragen = fragen
        meldungsrechtAufruf = fragen
        // **Auf dem Telefon bleibt die App hochkant**, nur der Player ist quer (Vorlage `Orientierung` auf
        // dem iPhone: `.portrait`, der Player erlaubt sich das Querformat selbst). Sonst lag die App nach dem
        // Schliessen quer, wenn das Telefon gerade quer gehalten wurde. Tablets drehen frei, wie das iPad.
        if (resources.configuration.smallestScreenWidthDp < 600 && !app.istFernseher) {
            requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
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
            // Der einmalige Discord-Hinweis — dieselbe Wartezeit, dasselbe „erst nach dem Player".
            androidx.compose.runtime.LaunchedEffect(app.discordHinweisFaellig.value, app.spiel.value == null) {
                if (!app.discordHinweisFaellig.value || app.spiel.value != null) return@LaunchedEffect
                app.discordHinweisFaellig.value = false
                kotlinx.coroutines.delay(1500)
                if (app.spiel.value != null) { app.discordHinweisFaellig.value = true; return@LaunchedEffect }
                discordHinweisZeigen(app, this@MainActivity)
            }
            // Abgemeldet: zurueck zur Serverwahl.
            androidx.compose.runtime.LaunchedEffect(app.abgemeldet.intValue) { if (app.abgemeldet.intValue > 0) phase = Phase.Server }
            // Einmal je Start, nicht je Drehung — deshalb gemerkt.
            var gestartet by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
            // **Der Schirm als aufgezeichnete Ebene** — daraus nimmt der Kontowechsel sein Standbild
            // (`Kontowechselflug`), ohne einen zweiten Zeichendurchgang.
            val schirm = androidx.compose.ui.graphics.rememberGraphicsLayer()
            androidx.compose.runtime.SideEffect { Kontowechselflug.schirm = schirm }
            Box(Modifier.fillMaxSize().background(Stil.grund)) {
                Box(Modifier.fillMaxSize().drawWithContent {
                    schirm.record { this@drawWithContent.drawContent() }
                    drawLayer(schirm)
                }) {
                when (val p = phase) {
                    Phase.Server -> ServerSeite(app) { name, fassung -> phase = Phase.Anmeldung(name, fassung) }
                    is Phase.Anmeldung -> AnmeldeSeite(app, p.servername, p.fassung,
                        andererServer = { phase = Phase.Server }) { phase = Phase.Start }
                    // Nach einem Kontowechsel frisch — Stapel, Bereiche und Seiten gehoeren dem vorigen Konto.
                    Phase.Start -> androidx.compose.runtime.key(app.kontowechsel.intValue) { Hauptansicht(app) }
                }
                }
                // Der Kontowechsel: Standbild, fliegendes Profilbild, Ring — ueber allem.
                Kontowechselebene()
                // „Hier weiterschauen": die Karte waechst aus dem Abzeichen (`Uebergabe.kt`).
                Uebergabeebene(imPlayer = false)
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
