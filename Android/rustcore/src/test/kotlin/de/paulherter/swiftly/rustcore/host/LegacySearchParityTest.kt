package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.ServerKind
import de.paulherter.swiftly.rustcore.legacySearchHistoryKey
import de.paulherter.swiftly.rustcore.legacySearchHistoryKeyAccount
import de.paulherter.swiftly.rustcore.legacySearchHistoryList
import de.paulherter.swiftly.rustcore.legacySearchHistoryRemember
import de.paulherter.swiftly.rustcore.legacySearchKeyDelete
import de.paulherter.swiftly.rustcore.legacySearchKeyHardware
import de.paulherter.swiftly.rustcore.legacySearchKeyRows
import de.paulherter.swiftly.rustcore.legacySearchKeySpace
import de.paulherter.swiftly.rustcore.legacySearchKeySpaceFits
import de.paulherter.swiftly.rustcore.legacySearchKeyTyped
import de.paulherter.swiftly.rustcore.legacySearchScreen
import de.paulherter.swiftly.rustcore.legacySearchTermFits
import de.paulherter.swiftly.rustcore.legacySearchTitlesShown
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.crypto.spec.SecretKeySpec

/** Old against new for Search: the Swift answers (Android/golden) against the core's, results and pure rules. */
class LegacySearchParityTest {
    private val url = System.getenv("SWIFTLY_FIXTURE_URL")
    private val golden = System.getenv("SWIFTLY_GOLDEN_DIR")

    private object Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    private fun check(cases: List<Pair<String, String>>) {
        assumeTrue("no SWIFTLY_GOLDEN_DIR", golden != null)
        val failures = cases.mapNotNull { (name, new) ->
            File("/tmp/andscr-new-$name.json").writeText(new)
            val old = File(golden!!, "$name.json").readText()
            val diff = if (old.trimStart().startsWith("{") || old.trimStart().startsWith("[")) JsonParity.diff(old, new)
                       else if (old == new) null else "text old '$old' new '$new'"
            diff?.let { "$name: $it" }
        }
        assertEquals(failures.joinToString("\n"), 0, failures.size)
    }

    @Test fun resultsAreTheFlatListWithTheHitLine() = runBlocking {
        assumeTrue("no SWIFTLY_FIXTURE_URL", url != null)
        val core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient())
        val a = AccountRef(url!!, "u1", "fixture-token", ServerKind.JELLYFIN, "golden-device")
        check(listOf(
            "search-nord" to core.legacySearch(a, "en", "nord"),
            "search-series" to core.legacySearch(a, "en", "Hafen"),
            "search-short" to core.legacySearch(a, "en", "a"),
            "search-padded" to core.legacySearch(a, "en", "  ab  "),
        ))
    }

    @Test fun pureRules() = check(listOf(
        "search-fits-a" to legacySearchTermFits("a").toString(),
        "search-fits-ab" to legacySearchTermFits("ab").toString(),
        "search-fits-spaces" to legacySearchTermFits("  a ").toString(),
        "search-history-key" to legacySearchHistoryKey(),
        "search-history-key-account" to legacySearchHistoryKeyAccount("acc1"),
        "search-history-remember" to legacySearchHistoryRemember("Nordlicht", "Alt\nNordlicht\nAndere"),
        "search-history-remember-short" to legacySearchHistoryRemember("x", "Alt"),
        "search-history-list" to legacySearchHistoryList("Eins\nZwei\n\nDrei"),
        "search-key-rows" to legacySearchKeyRows(false),
        "search-key-rows-speech" to legacySearchKeyRows(true),
        "search-key-typed-start" to legacySearchKeyTyped("T", ""),
        "search-key-typed-mid" to legacySearchKeyTyped("A", "T"),
        "search-key-typed-word" to legacySearchKeyTyped("M", "Tatort "),
        "search-key-typed-hyphen" to legacySearchKeyTyped("B", "Ab-"),
        "search-key-typed-sharp" to legacySearchKeyTyped("ß", ""),
        "search-key-space" to legacySearchKeySpace("Tatort"),
        "search-key-space-twice" to legacySearchKeySpace("Tatort "),
        "search-key-space-fits" to legacySearchKeySpaceFits("Tatort").toString(),
        "search-key-space-fits-empty" to legacySearchKeySpaceFits("").toString(),
        "search-key-delete" to legacySearchKeyDelete("Tatort"),
        "search-key-delete-empty" to legacySearchKeyDelete(""),
        "search-key-hardware" to legacySearchKeyHardware("mÜnster 5!x", "tatort "),
        "search-titles-shown-two" to legacySearchTitlesShown(2, 3, 0).toString(),
        "search-titles-shown-one" to legacySearchTitlesShown(0, 3, 0).toString(),
        "search-screen-history" to legacySearchScreen("", 2, false, false, false, false),
        "search-screen-start" to legacySearchScreen("a", 0, false, false, false, false),
        "search-screen-disrupted" to legacySearchScreen("abc", 0, true, true, true, true),
        "search-screen-hits" to legacySearchScreen("abc", 0, true, false, false, false),
        "search-screen-nothing" to legacySearchScreen("abc", 0, false, true, false, false),
        "search-screen-loading" to legacySearchScreen("abc", 0, false, false, false, true),
        "search-screen-blank" to legacySearchScreen("abc", 0, false, false, false, false),
    ))
}
