package de.paulherter.swiftly.support

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * "Support Swiftly" texts and the line between the two builds, checked on the sources.
 * `Werkzeuge/store-guard-android.py` checks the built Play binary on top of this.
 */
class SupportTextsTest {
    private val phone = File(".")
    private val shared = File("../shared/src/main/assets/texts")

    private fun table(file: File): Set<String> =
        Regex("""^ "((?:[^"\\]|\\.)*)": """, RegexOption.MULTILINE).findAll(file.readText()).map {
            it.groupValues[1].replace("\\\"", "\"")
        }.toSet()

    /** Keys of `translated("…")` in the given sources, rewritten the way `Texts` looks them up. */
    private fun keys(vararg dirs: String): Set<String> = dirs.flatMap { d ->
        File(phone, d).walkTopDown().filter { it.extension == "kt" }.flatMap { f ->
            Regex("""translated\("((?:[^"\\]|\\.)*)"""").findAll(f.readText()).map { it.groupValues[1] }
        }.toList()
    }.map { it.replace("%lld", "%d").replace("%@", "%s") }.toSet()

    @Test fun everySupportTextIsTranslated() {
        val main = keys("src/main/java/de/paulherter/swiftly/support", "src/main/java/de/paulherter/swiftly/tv/TvSupport.kt",
                        "src/play/java")
        val direct = keys("src/direct/java")
        for (language in listOf("de", "en")) {
            val shared = table(File(shared, "$language.json"))
            val own = table(File(phone, "src/direct/assets/texts/$language.direct.json"))
            val missing = main.filter { it !in shared } + direct.filter { it !in shared && it !in own }
            assertTrue("$language: missing $missing", missing.isEmpty())
        }
    }

    /** What only the direct build may say, as text and as code. */
    private val forbidden = listOf("pay.paulherter", "swiftlyplayer.com/supporter", "Stripe", "supporter key", "SupporterKey",
                                   "Unterstützer-Schlüssel")

    @Test fun thePlayBuildSourcesCarryNoDirectText() {
        val files = listOf(File(phone, "src/main"), File(phone, "src/play"), File("../shared/src/main"))
            .flatMap { it.walkTopDown().filter { f -> f.isFile && f.extension in setOf("kt", "json", "xml") }.toList() }
        val hits = files.flatMap { f ->
            val text = f.readText()
            forbidden.filter { word ->
                if (word == "supporter key") text.contains(word, ignoreCase = true) else text.contains(word)
            }.map { "${f.path}: $it" }
        }
        assertTrue("found $hits", hits.isEmpty())
    }
}
