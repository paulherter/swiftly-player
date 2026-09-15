package de.paulherter.swiftly

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
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
import androidx.compose.material.icons.filled.PictureInPictureAlt
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
        // **Der Player liegt oben drauf** (`fullScreenCover`): er faehrt von unten herein und wieder
        // hinunter, die App darunter bewegt sich nicht. Ohne eigene Uebergaenge spielte Android die
        // Animation fuer einen Aufgabenwechsel, und die App kam von oben herein.
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            overrideActivityTransition(OVERRIDE_TRANSITION_OPEN, R.anim.player_hoch, R.anim.halten)
            overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, R.anim.halten, R.anim.player_runter)
        }
        val app = application as SwiftlyAnwendung
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
            @Suppress("DEPRECATION") overridePendingTransition(R.anim.halten, R.anim.player_runter)
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
        if (isFinishing) (application as SwiftlyAnwendung).spiel.value = null
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
    Box(Modifier.fillMaxSize().background(de.paulherter.swiftly.gemeinsam.Stil.grund).antippen(zurueckholen),
        contentAlignment = androidx.compose.ui.Alignment.Center) {
        androidx.compose.foundation.layout.Column(horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally,
            verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(14.dp)) {
            androidx.compose.material3.Icon(androidx.compose.material.icons.Icons.Filled.PictureInPictureAlt, contentDescription = null,
                tint = de.paulherter.swiftly.gemeinsam.Stil.schriftSehrLeise, modifier = Modifier.size(44.dp))
            androidx.compose.material3.Text(de.paulherter.swiftly.gemeinsam.uebersetzt("Dieses Video wird im Bild-im-Bild wiedergegeben."),
                style = de.paulherter.swiftly.gemeinsam.Stil.koerper, color = de.paulherter.swiftly.gemeinsam.Stil.schriftLeise,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.padding(horizontal = 40.dp))
        }
    }
}
