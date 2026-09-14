package de.paulherter.swiftly.gemeinsam

import android.content.Context
import org.json.JSONObject
import java.util.Locale

/**
 * **Deutscher Wortlaut als Schluessel — wie auf Apple und Linux.**
 *
 * Die Tabellen erzeugt `Werkzeuge/texte-nach-android.py` aus
 * `Sources/Shared/Localizable.xcstrings`. Hier wird nichts von Hand gepflegt:
 * ein zweiter Katalog waere eine zweite Wahrheit.
 *
 * Deutsch fuer deutsche Geraete, sonst Englisch — dieselbe Regel wie im Store.
 */
object Texte {
    private var tabelle: Map<String, String> = emptyMap()

    fun laden(context: Context, sprache: String = Locale.getDefault().language) {
        val datei = if (sprache == "de") "de" else "en"
        val json = context.assets.open("texte/$datei.json").bufferedReader().use { it.readText() }
        val obj = JSONObject(json)
        tabelle = obj.keys().asSequence().associateWith { obj.getString(it) }
    }

    fun text(schluessel: String, vararg argumente: Any): String {
        val format = tabelle[schluessel] ?: schluessel
        return if (argumente.isEmpty()) format else String.format(format, *argumente)
    }
}

/** Kurzform wie auf Linux: `uebersetzt("Anmelden")`. */
fun uebersetzt(schluessel: String, vararg argumente: Any): String = Texte.text(schluessel, *argumente)
