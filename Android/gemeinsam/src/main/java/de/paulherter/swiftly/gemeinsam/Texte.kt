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
        // Das Skript legt auch den **Schluessel** umgeschrieben ab (`%d offen`), gerufen wird
        // mit Swifts Wortlaut (`%lld offen`) — also beide Fassungen nachschlagen.
        val format = tabelle[schluessel] ?: tabelle[javaFormat(schluessel)] ?: schluessel
        if (argumente.isEmpty()) return format
        // **Fehlt der Eintrag, ist der Schluessel die Vorlage** — und der traegt Swifts
        // Platzhalter. `%lld` kennt Java nicht und warf mitten im Zeichnen einer Kachel:
        // die App stuerzte auf der Serienseite ab. Dieselbe Umschrift wie im Skript.
        return runCatching { String.format(javaFormat(format), *argumente) }.getOrDefault(format)
    }

    private fun javaFormat(text: String): String = text
        .replace(Regex("%(\\d+\\$)?@")) { "%${it.groupValues[1]}s" }
        .replace(Regex("%(\\d+\\$)?l{0,2}[du]")) { "%${it.groupValues[1]}d" }
        .replace(Regex("%(\\d+\\$)?l?f")) { "%${it.groupValues[1]}f" }
}

/** Kurzform wie auf Linux: `uebersetzt("Anmelden")`. */
fun uebersetzt(schluessel: String, vararg argumente: Any): String = Texte.text(schluessel, *argumente)
