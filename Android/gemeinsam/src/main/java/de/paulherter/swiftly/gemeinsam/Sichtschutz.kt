package de.paulherter.swiftly.gemeinsam

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.Window
import android.view.WindowManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalContext
import java.util.WeakHashMap

/**
 * **Sichtschutz, solange ein Geheimfeld zu sehen ist** (Passwort, Header-Wert).
 *
 * Setzt `FLAG_SECURE` auf das Fenster der Aktivitaet: das Bild im App-Umschalter bleibt leer,
 * Bildschirmfotos und Aufnahmen zeigen die Maske nicht. Nur solange das Feld eingehaengt ist —
 * der Player liegt in einer eigenen Aktivitaet und bleibt unberuehrt, Bild-im-Bild auch.
 * Mehrere Felder auf einer Seite zaehlen mit; erst das letzte nimmt die Markierung wieder ab.
 * Vorlage: der Sichtschutz der Anmeldung auf iOS.
 */
@Composable
fun Sichtschutz() {
    val fenster = LocalContext.current.aktivitaetsfenster() ?: return
    DisposableEffect(fenster) {
        val n = (sperren[fenster] ?: 0) + 1
        sperren[fenster] = n
        if (n == 1) fenster.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        onDispose {
            val rest = (sperren[fenster] ?: 1) - 1
            if (rest <= 0) {
                sperren.remove(fenster)
                fenster.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            } else sperren[fenster] = rest
        }
    }
}

private val sperren = WeakHashMap<Window, Int>()

private tailrec fun Context.aktivitaetsfenster(): Window? = when (this) {
    is Activity -> window
    is ContextWrapper -> baseContext.aktivitaetsfenster()
    else -> null
}
