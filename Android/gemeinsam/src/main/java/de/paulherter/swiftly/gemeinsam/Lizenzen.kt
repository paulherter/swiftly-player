package de.paulherter.swiftly.gemeinsam

import android.content.Context
import org.json.JSONObject

/**
 * **Open-Source-Lizenzen — Handy und Fernseher lesen dieselben Dateien.**
 *
 * `LICENSES/bausteine.json` und den Volltexten in `LICENSES/` liegen einmal im Repo; der Bau kopiert sie
 * unter `assets/lizenzen/` (`handy/build.gradle.kts`). Hier steht nichts von Hand: eine zweite
 * Kopie liefe auseinander. Gezeigt werden nur die Bausteine, die in Android stecken.
 */
data class Lizenzbaustein(val id: String, val name: String, val version: String, val spdx: String,
                          val urheber: String, val quelle: String, val texte: List<String>,
                          val gruppe: String, val notiz: String?)

data class Angebotsabschnitt(val titel: String, val absaetze: List<String>)

data class Lizenzbestand(val bausteine: List<Lizenzbaustein>, val angebotTitel: String,
                         val angebot: List<Angebotsabschnitt>, val quelleSwiftly: String) {
    /** Zuerst der Player (libVLC), dann der Rest. */
    fun gruppe(name: String) = bausteine.filter { it.gruppe == name }

    companion object {
        /** `null`, wenn die Datei im Bau fehlt — die Seite sagt es dann, statt leer zu stehen. */
        fun laden(context: Context): Lizenzbestand? = runCatching {
            val o = JSONObject(context.assets.open("lizenzen/bausteine.json").bufferedReader().use { it.readText() })
            val liste = o.getJSONArray("bausteine")
            val bausteine = (0 until liste.length()).map { liste.getJSONObject(it) }.filter { b ->
                val p = b.getJSONArray("plattformen")
                (0 until p.length()).any { p.getString(it).let { s -> s == "android" || s == "androidtv" } }
            }.map { b ->
                val t = b.getJSONArray("texte")
                Lizenzbaustein(b.getString("id"), b.getString("name"), b.getString("version"), b.getString("spdx"),
                    b.getString("urheber"), b.getString("quelle"), (0 until t.length()).map { t.getString(it) },
                    b.optString("gruppe", "app"), b.optString("notiz").ifEmpty { null })
            }
            val a = o.getJSONObject("angebot")
            val abschnitte = a.getJSONArray("abschnitte")
            Lizenzbestand(bausteine, a.getString("titel"),
                (0 until abschnitte.length()).map { abschnitte.getJSONObject(it) }.map { s ->
                    val ab = s.getJSONArray("absaetze")
                    Angebotsabschnitt(s.getString("titel"), (0 until ab.length()).map { ab.getString(it) })
                }, a.getString("quelle_swiftly"))
        }.getOrNull()

        /** Volltext einer Lizenz; `null`, wenn die Datei fehlt. */
        fun text(context: Context, datei: String): String? = runCatching {
            context.assets.open("lizenzen/$datei").bufferedReader().use { it.readText() }
        }.getOrNull()
    }
}

/** Der Einleitungssatz oben auf der Seite — am Wortlaut hängt die Pflicht, er steht in beiden Fassungen gleich vorn. */
fun lizenzEinleitung(): String = uebersetzt("Swiftly Player nutzt libVLC von VideoLAN unter der LGPL 2.1 oder später")

/** Die Quellen, die oben stehen: Swiftlys eigenes Repo und das Upstream von libVLC. */
fun lizenzQuellen(bestand: Lizenzbestand): List<String> =
    listOf(bestand.quelleSwiftly, "https://code.videolan.org/videolan/vlc-android", "https://www.videolan.org/vlc/")
