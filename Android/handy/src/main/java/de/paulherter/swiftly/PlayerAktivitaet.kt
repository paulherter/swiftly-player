package de.paulherter.swiftly

import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.view.WindowManager
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import android.content.res.Configuration
import android.os.Bundle
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.Lifecycle

/**
 * **Der Player in einer eigenen Aktivitaet** — in der Aufgabe der App, damit er oben drauf liegt.
 *
 * Auf iOS laeuft das kleine Fenster weiter, waehrend man in der App stoebert. Auf Android ist
 * Bild-im-Bild eine ganze Aktivitaet: laege der Player in der Hauptaktivitaet, schrumpfte die
 * ganze App mit ins Fenster. Mit eigener Aufgabe bleibt die App daneben bedienbar.
 *
 * Nebenbei dreht nur noch diese Aktivitaet ins Querformat, und sie wird dabei nicht neu gebaut
 * (`configChanges`) — vorher baute die Drehung die Hauptaktivitaet neu und oeffnete den Titel zweimal.
 *
 * **Beim Verlassen geht sie ins kleine Fenster**, statt nur einen Knopf dafuer anzubieten wie iOS:
 * Android spielt ohne Vordergrunddienst nicht verlaesslich im Hintergrund weiter. Wird das Fenster
 * weggewischt, endet die Wiedergabe — der Player meldet dabei „gestoppt".
 */
class PlayerAktivitaet : ComponentActivity() {
    private val kleinesFenster = mutableStateOf(false)
    private val wunsch = mutableStateOf<Abspielwunsch?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = androidx.activity.SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = androidx.activity.SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
        )
        val app = application as SwiftlyAnwendung
        // **Der Player blendet ueber, er faehrt nicht** (Vorlage `Playerrahmen` auf iOS: `.crossDissolve`,
        // 0,3 s). Geschoben kam er quer „von unten" und hochkant von der Seite — eine Blende hat keine
        // Richtung. Die App darunter bewegt sich nicht.
        // Auf dem Fernseher dieselbe Blende (tvOS bee033b).
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            overrideActivityTransition(OVERRIDE_TRANSITION_OPEN, R.anim.player_ein, R.anim.halten)
            overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, R.anim.halten, R.anim.player_aus)
        }
        if (!app.istFernseher) {
            // **Quer vor dem ersten Bild, und nur der Player.** Die Lage steht im Manifest
            // (`sensorLandscape`), damit das System sie schon beim Start kennt und die App dahinter
            // hochkant bleibt; vorher setzte `PlayerSeite` sie erst im ersten Durchgang, der Player ging
            // hochkant auf und drehte nach — und beim Schliessen stellte er die alte Lage wieder her und
            // drehte noch einmal. Nur wer die Sperre abgeschaltet hat, darf auch hochkant.
            if (!app.einstellungen.querformatFest) requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_USER
            // Ohne Systemleisten und mit wachem Bildschirm, solange diese Aktivitaet lebt — beim Schliessen
            // nichts zurueckstellen: das Fenster geht mit ihr, ein Einblenden der Leisten blitzte nur auf.
            WindowCompat.getInsetsController(window, window.decorView).apply {
                systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                hide(WindowInsetsCompat.Type.systemBars())
            }
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        wunsch.value = app.spiel.value ?: run { finish(); return }
        // **Mit der Geste ins kleine Fenster, nicht danach.** Nach oben gewischt ging die Aktivitaet
        // zuerst in den Hintergrund; Android baute dabei die Videoflaeche ab, und das kleine Fenster
        // blieb schwarz — auch nach dem Zurueckholen. Ab Android 12 verkleinert das System selbst.
        if (android.os.Build.VERSION.SDK_INT >= 31 && packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
            runCatching { setPictureInPictureParams(PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).setAutoEnterEnabled(true).build()) }
        }
        setContent {
            Box(Modifier.fillMaxSize().background(Color.Black)) {
                wunsch.value?.let { w ->
                    // Ein neuer Wunsch (aus der App, waehrend das kleine Fenster laeuft) baut den Player neu.
                    // **Der Fernseher bekommt einen eigenen Player** (`tv/TvPlayer.kt`, Vorlage
                    // `Sources/tvOS/PlayerScreen.swift`) statt des Telefon-Players: kein Bild-im-Bild,
                    // dafuer Fernbedienung statt Finger. Beide teilen sich die Mechanik in `Spielwerk`.
                    key(w) {
                        if (app.istFernseher) de.paulherter.swiftly.tv.TvPlayer(app, w) { finish() }
                        else PlayerSeite(app, w, kleinesFenster.value, ::bildImBild) { finish() }
                    }
                }
                if (!kleinesFenster.value) if (app.istFernseher) de.paulherter.swiftly.tv.TvTafel(app) else Blattauflage(app)
            }
        }
    }

    override fun finish() {
        super.finish()
        if (android.os.Build.VERSION.SDK_INT < 34) {
            @Suppress("DEPRECATION")
            overridePendingTransition(R.anim.halten, R.anim.player_aus)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        (application as SwiftlyAnwendung).spiel.value?.let { wunsch.value = it }
    }

    /** `false`, wenn das Geraet kein Bild-im-Bild kann. */
    fun bildImBild(): Boolean {
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) return false
        return runCatching { enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build()) }
            .getOrDefault(false)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Vor Android 12 gibt es kein automatisches Verkleinern — dort bleibt der Hinweis beim Verlassen.
        if (!isFinishing && android.os.Build.VERSION.SDK_INT < 31) bildImBild()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        kleinesFenster.value = isInPictureInPictureMode
        (application as SwiftlyAnwendung).kleinesFenster.value = isInPictureInPictureMode
        // Aus dem kleinen Fenster heraus, ohne dass die Aktivitaet wieder vorn steht: weggewischt.
        if (!isInPictureInPictureMode && !lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) finish()
    }

    override fun onDestroy() {
        super.onDestroy()
        if (isFinishing) (application as SwiftlyAnwendung).let { it.spiel.value = null; it.spielUebergeben = null }
        (application as SwiftlyAnwendung).kleinesFenster.value = false
    }
}

/**
 * **Wie iOS:** laeuft der Film im kleinen Fenster, zeigt die App darunter nicht sich selbst, sondern
 * wo er gerade ist. Vorher stand dort die ganze App zum Bedienen — der Film schien verschwunden.
 * Ein Tipp holt ihn gross zurueck.
 */
@androidx.compose.runtime.Composable
fun Bildimbildhinweis(zurueckholen: () -> Unit) {
    Box(Modifier.fillMaxSize().background(de.paulherter.swiftly.gemeinsam.Stil.grund).tippen(zurueckholen),
        contentAlignment = androidx.compose.ui.Alignment.Center) {
        androidx.compose.foundation.layout.Column(horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally,
            verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(14.dp)) {
            Symbol(Zeichen.BildImBild, 30.dp, farbe = de.paulherter.swiftly.gemeinsam.Stil.schriftSehrLeise, staerke = Staerke.Mittel)
            androidx.compose.material3.Text(de.paulherter.swiftly.gemeinsam.uebersetzt("Dieses Video wird im Bild-im-Bild wiedergegeben."),
                style = de.paulherter.swiftly.gemeinsam.Stil.koerper, color = de.paulherter.swiftly.gemeinsam.Stil.schriftLeise,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.padding(horizontal = 40.dp))
        }
    }
}
