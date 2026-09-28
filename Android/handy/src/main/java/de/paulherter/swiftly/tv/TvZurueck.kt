package de.paulherter.swiftly.tv

import android.view.KeyEvent
import androidx.activity.ComponentActivity

/**
 * **Die Zurueck-Taste geht auf dem Fernseher direkt an den `OnBackPressedDispatcher`**, an Compose vorbei.
 *
 * Compose deutet ein unverbrauchtes Zurueck als Fokusrichtung „Exit". In einer Fokusgruppe mit
 * `exit = Cancel` (Player-Ebenen, Staffelwahl, Tafeln) gilt das Druecken damit als verbraucht — vor
 * Android 13 (Fire OS 7/8, aeltere Android-TV-Geraete) erreicht es dann nie `onKeyDown`, die Aktivitaet
 * verfolgt die Taste nicht, und kein `BackHandler` feuert: die Ebene liess sich nicht schliessen.
 * Ab Android 13 ruft das System die Rueckruf-Kette selbst auf; hier bekommen alle Fassungen denselben Weg.
 * Die Bildschirmtastatur sieht die Taste vorher (Pre-IME) und schliesst sich weiter selbst.
 *
 * `null`: keine Zurueck-Taste, normal weiterreichen.
 */
internal fun ComponentActivity.zurueckTaste(e: KeyEvent): Boolean? {
    if (e.keyCode != KeyEvent.KEYCODE_BACK) return null
    if (e.action == KeyEvent.ACTION_UP && !e.isCanceled) onBackPressedDispatcher.onBackPressed()
    return true
}

/**
 * **Nach einem langen Druck gehoert der Rest dieses Drucks niemandem mehr.** Langes OK oeffnet das
 * Kachelmenue, der Fokus springt in die Tafel — aber die Fernbedienung schickt weiter: Wiederholungen
 * (KeyDown mit `repeatCount > 0`) und am Ende das KeyUp. Die kamen bei der ersten Zeile der Tafel an,
 * die sie als Klick nahm („Als gesehen markieren"); die Tafel ging zu, der Fokus zurueck auf die
 * Kachel, und die naechsten Wiederholungen loesten dort und im Player weiter aus — im Player sprang
 * es so von selbst durch die Ebenen. Jetzt verbraucht die Aktivitaet alles von einer Taste, die beim
 * langen Druck gehalten war, bis sie losgelassen ist.
 *
 * `pruefen` laeuft in `dispatchKeyEvent` vor Compose; `nachLangemDruck` ruft `Fokusflaeche`.
 */
internal object Tastensperre {
    private val unten = HashSet<Int>()
    private val gesperrt = HashSet<Int>()

    fun nachLangemDruck() { gesperrt.addAll(unten) }

    /** `true`: verbraucht, nicht weiterreichen. */
    fun pruefen(e: KeyEvent): Boolean {
        val code = e.keyCode
        return when (e.action) {
            KeyEvent.ACTION_DOWN -> {
                if (e.repeatCount == 0) { unten.add(code); gesperrt.remove(code); false }
                else code in gesperrt
            }
            KeyEvent.ACTION_UP -> { unten.remove(code); gesperrt.remove(code) }
            else -> false
        }
    }
}
