package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.ServerKind
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.crypto.spec.SecretKeySpec

/**
 * Old against new for a **Plex account**: the Swift `Kern` answers (Android/golden, `plex-*`) against the core's calls, over the
 * Plex side of `cargo xtask fixture-server`. Every difference is listed, not only the first.
 */
class LegacyPlexParityTest {
    private val url = System.getenv("SWIFTLY_FIXTURE_URL")
    private val golden = System.getenv("SWIFTLY_GOLDEN_DIR")

    private object Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    @Test fun plexAnswersAreTheOldOnes() = runBlocking {
        assumeTrue("no fixture", url != null && golden != null)
        val core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient())
        val a = AccountRef(url!!, "pu1", "plex-token", ServerKind.PLEX, "golden-device")
        val failures = ArrayList<String>()
        suspend fun same(name: String, call: suspend () -> String) {
            val new = runCatching { call() }.getOrElse { "ERROR: ${it.message}" }
            File("/tmp/andscr-new-$name.json").writeText(new)
            val old = File(golden!!, "$name.json").readText()
            val diff = if (old.trimStart().startsWith("{") || old.trimStart().startsWith("[")) {
                if (new.trimStart().startsWith("{") || new.trimStart().startsWith("[")) JsonParity.diff(old, new) else "new is not JSON: ${new.take(120)}"
            } else if (old == new) null else "text old '${old.take(80)}' new '${new.take(80)}'"
            if (diff != null) failures += "$name: $diff"
        }
        same("plex-home-default") { core.legacyHome(a, "en", false, listOf(), listOf(), "", "", listOf(), false, "") }
        same("plex-home-genres") { core.legacyHome(a, "en", false, listOf(), listOf(), "", "", listOf("Drama"), false,
            """[{"id":"1","name":"Filme","sammlung":false},{"id":"2","name":"Serien","sammlung":false}]""") }
        same("plex-library-movies") { core.legacyLibraryPage(a, "en", "1", "movies", "name", "alle", 0, 50) }
        same("plex-library-shows") { core.legacyLibraryPage(a, "en", "2", "tvshows", "name", "alle", 0, 50) }
        same("plex-library-unwatched") { core.legacyLibraryPage(a, "en", "1", "movies", "erscheinung", "ungesehen", 0, 50) }
        same("plex-genres") { core.legacyGenres(a, "en") }
        same("plex-genre-drama") { core.legacyGenre(a, "en", "Drama") }
        same("plex-watchlist") { core.legacyWatchlist(a, "en", "", "neueste", 0, 20) }
        same("plex-search") { core.legacySearch(a, "en", "Plex") }
        assertEquals(failures.joinToString("\n"), 0, failures.size)
    }

    /** Title, series, episodes, similar titles, trailers and the small writes of a Plex account: `Core.legacyPlexDetail` against the golden answers. */
    @Test fun plexDetailAnswersAreTheOldOnes() = runBlocking {
        assumeTrue("no fixture", url != null && golden != null)
        val core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient())
        val d = core.legacyPlexDetail(AccountRef(url!!, "pu1", "plex-token", ServerKind.PLEX, "golden-device"), "en")
        val failures = ArrayList<String>()
        suspend fun same(name: String, call: suspend () -> String) {
            val new = runCatching { call() }.getOrElse { "ERROR: ${it.message}" }
            File("/tmp/andscr-new-$name.json").writeText(new)
            val old = File(golden!!, "$name.json").readText()
            val diff = if (old.trimStart().startsWith("{") || old.trimStart().startsWith("[")) {
                if (new.trimStart().startsWith("{") || new.trimStart().startsWith("[")) JsonParity.diff(old, new) else "new is not JSON: ${new.take(120)}"
            } else if (old == new) null else "text old '${old.take(80)}' new '${new.take(80)}'"
            if (diff != null) failures += "$name: $diff"
        }
        same("plex-title-movie") { d.title("10") }
        same("plex-title-resume") { d.title("11") }
        same("plex-series") { d.series("20") }
        same("plex-series-from-episode") { d.series("32") }
        same("plex-episodes-season") { d.episodes("20", "21") }
        same("plex-episodes-all") { d.episodes("20", "") }
        same("plex-title-field") { d.titleField("10") }
        same("plex-trailers-files") { d.trailers("10", false) }
        same("plex-trailers-web") { d.trailers("10", true) }
        same("plex-episode-after") { d.episodeAfter("31", "20") }
        same("plex-remember-ok") { d.remember("10", true) }
        same("plex-watched-ok") { d.watched("10", true) }
        same("plex-metadata-refresh") { d.metadataRefresh("10") }
        val first = d.shuffleStart("20")
        val run = d.runIds()
        if (first.isEmpty() || first !in run) failures += "plex-shuffle: first '$first' run $run"
        if (run.size > 1 && d.episodeAfter(run[0], "20") != run[1]) failures += "plex-shuffle: episodeAfter does not follow the run"
        assertEquals(failures.joinToString("\n"), 0, failures.size)
    }
}
