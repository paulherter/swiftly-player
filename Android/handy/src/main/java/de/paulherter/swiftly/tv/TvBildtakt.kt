package de.paulherter.swiftly.tv

import android.app.Activity
import android.view.Display
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.interfaces.IMedia
import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * Vorlage: `Bildtakt` in `Sources/tvOS/Bildtakt.swift` — die Bildwiederholrate des Fernsehers an die
 * Datei anpassen, damit 23,976/24-Filme nicht im 3:2-Pulldown ruckeln (24 geht in 60 nicht auf; jedes
 * Bild steht abwechselnd zu kurz und zu lang). Die Begruendung dort gilt unveraendert: kein Zaehler
 * meldet etwas, weil kein Bild verlorengeht — nur die Anzeigedauer der Bilder ist ungleich.
 *
 * **Android hat kein `AVDisplayManager`.** Das Gegenstueck ist `Display.Mode` mit
 * `WindowManager.LayoutParams.preferredDisplayModeId`: derselbe physische Ausgangswechsel wie
 * `preferredDisplayCriteria` auf tvOS, nur ueber die Fensterparameter statt einen eigenen Verwalter.
 *
 * **Gemessen wird aus VLCs eigenem Videotrack** (`MediaPlayer.getCurrentVideoTrack()`), nicht aus
 * Server-Angaben vor dem Oeffnen: die Kern-Fassade liefert bisher keine strukturierten
 * Bildraten-/Codec-Daten an Kotlin (nur formatierten Text fuers Technikschild). Der fruehe Weg auf
 * tvOS ist eine Optimierung gegen ein sichtbares Aufblitzen hinter dem Ladeschirm; hier bleibt es
 * beim spaeten, sicheren Weg — **einmal gemessen, dann gemerkt**, wie dort.
 */
object TvBildtakt {
    private var gemessen: Double? = null
    private var versuche = 0

    /** Modus, den wir gesetzt haben — fuer `loesen()`. `null` heisst: nichts gesetzt. */
    private var gesetzterModus: Int? = null

    /** Die Rate, auf die wir den Ausgang gestellt haben — `null`, wenn nicht geschaltet wurde. */
    var angefordert: Double? = null
        private set

    /** Die einmal gemessene Bildrate der laufenden Datei, aus VLCs Videotrack. Einmal reicht — die
     * Bildrate einer Datei aendert sich nicht, und `getCurrentVideoTrack()` baut bei jedem Aufruf ein
     * frisches Objekt auf. Bis zu 40 Versuche, dann wird aufgegeben (siehe `Bildtakt.rate(von:)`). */
    fun rate(spur: IMedia.VideoTrack?): Double? {
        gemessen?.let { return it }
        if (versuche >= 40) return null
        versuche++
        val s = spur ?: return null
        if (s.frameRateDen <= 0) return null
        val rate = s.frameRateNum.toDouble() / s.frameRateDen.toDouble()
        if (rate <= 1 || rate >= 250) return null
        gemessen = rate
        return rate
    }

    /** Ob noch etwas nachzumessen ist — dann darf der Takt VLC in Ruhe lassen (dieselbe Warnung wie
     * `Bildtakt.nochNachzumessen` auf tvOS: der Videotrack wird bei jedem Zugriff neu aufgebaut). */
    fun nochNachzumessen(): Boolean = gemessen == null && versuche < 40

    /**
     * Die Bildrate der laufenden Datei uebernehmen, sobald VLC den Videotrack kennt. `erlaubt`
     * kommt von aussen (Einstellung „Bildrate anpassen") — dieselbe Fallunterscheidung wie
     * `Bildtakt.vomNutzerErlaubt`.
     */
    fun anpassen(activity: Activity, spieler: MediaPlayer, erlaubt: Boolean) {
        if (!nochNachzumessen()) return
        val rate = rate(spieler.currentVideoTrack) ?: return
        setzen(activity, rate, erlaubt)
    }

    /** Ob die Bildrate im gerade laufenden Anzeigemodus glatt aufgeht — `Bildtakt.passt`. */
    private fun passt(activity: Activity, rate: Double): Boolean {
        @Suppress("DEPRECATION")
        val takt = activity.windowManager.defaultDisplay.refreshRate.toDouble()
        if (takt < 1) return false
        val faktor = takt / rate
        // 23,976 ist nicht 24: eine knappe Toleranz, sonst faellt der haeufigste Kinowert durchs Raster.
        return abs(faktor - faktor.roundToLong()) < 0.01
    }

    private fun setzen(activity: Activity, rate: Double, erlaubt: Boolean) {
        // Nicht umschalten, wenn es nichts bringt — jeder Wechsel kostet ein paar Sekunden Schwarzbild.
        if (passt(activity, rate)) { angefordert = null; return }
        if (!erlaubt) return

        @Suppress("DEPRECATION")
        val anzeige = activity.windowManager.defaultDisplay
        @Suppress("DEPRECATION")
        val aktuell = anzeige.mode
        // Derselbe physische Modus (Aufloesung), nur mit der Bildwiederholrate, die am naechsten an
        // der Datei liegt — kein Hochskalieren auf eine andere Aufloesung nebenbei.
        @Suppress("DEPRECATION")
        val ziel = anzeige.supportedModes
            .filter { it.physicalWidth == aktuell.physicalWidth && it.physicalHeight == aktuell.physicalHeight }
            .minByOrNull { abs(it.refreshRate - rate) }
            ?: return
        // Kein brauchbarer Modus in der Naehe — lieber nichts anfordern als eine Rate, die selbst nicht aufgeht.
        if (abs(ziel.refreshRate - rate) > 0.6) return
        if (gesetzterModus == ziel.modeId) { angefordert = rate; return }

        val fenster = activity.window
        val parameter = fenster.attributes
        parameter.preferredDisplayModeId = ziel.modeId
        fenster.attributes = parameter
        gesetzterModus = ziel.modeId
        angefordert = rate
    }

    /** Zurueck auf den Modus fuer die Oberflaeche — nur, wenn wir wirklich etwas gesetzt haben. */
    fun loesen(activity: Activity) {
        gemessen = null
        versuche = 0
        angefordert = null
        if (gesetzterModus == null) return
        gesetzterModus = null
        val fenster = activity.window
        val parameter = fenster.attributes
        parameter.preferredDisplayModeId = 0
        fenster.attributes = parameter
    }
}
