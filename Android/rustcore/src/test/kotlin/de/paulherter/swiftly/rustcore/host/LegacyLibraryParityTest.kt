package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.ServerKind
import de.paulherter.swiftly.rustcore.legacyLabels
import de.paulherter.swiftly.rustcore.legacySavedGenres
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.crypto.spec.SecretKeySpec

/** Old against new for the Library group: Swift `Kern` answers (Android/golden) against the core's, same fixture server. */
class LegacyLibraryParityTest {
    private val url = System.getenv("SWIFTLY_FIXTURE_URL")
    private val golden = System.getenv("SWIFTLY_GOLDEN_DIR")

    private object Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    private fun same(name: String, call: suspend (Core, AccountRef) -> String) = runBlocking {
        assumeTrue("no SWIFTLY_FIXTURE_URL / SWIFTLY_GOLDEN_DIR", url != null && golden != null)
        val core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient())
        val account = AccountRef(url!!, "u1", "fixture-token", ServerKind.JELLYFIN, "golden-device")
        val new = call(core, account)
        File("/tmp/andscr-new-$name.json").writeText(new)
        assertNull(name, JsonParity.diff(File(golden!!, "$name.json").readText(), new))
    }

    @Test fun moviesByName() = same("library-movies-name") { c, a -> c.legacyLibraryPage(a, "en", "lib-movies", "movies", "name", "alle", 0, 50) }
    @Test fun moviesByRatingSecondPage() = same("library-movies-rating-page2") { c, a -> c.legacyLibraryPage(a, "en", "lib-movies", "movies", "bewertung", "ungesehen", 2, 3) }
    @Test fun unknownSortingFallsBackToName() = same("library-shows-unknown-sorting") { c, a -> c.legacyLibraryPage(a, "en", "lib-shows", "tvshows", "gibtsnicht", "angefangen", 0, 50) }
    @Test fun noArtMeansNoTypeRestriction() = same("library-noart") { c, a -> c.legacyLibraryPage(a, "en", "lib-movies", "", "erscheinung", "alle", 0, 4) }
    @Test fun watchlistAll() = same("watchlist-all") { c, a -> c.legacyWatchlist(a, "en", "", "neueste", 0, 20) }
    @Test fun watchlistMoviesSecondPage() = same("watchlist-movies-page2") { c, a -> c.legacyWatchlist(a, "en", "movies", "name", 1, 20) }
    @Test fun genreTitles() = same("genre-drama") { c, a -> c.legacyGenre(a, "en", "Drama") }
    @Test fun genreNames() = same("genres") { c, a -> c.legacyGenres(a, "en") }
    @Test fun labels() = same("labels") { _, _ -> legacyLabels("en") }
    @Test fun savedGenres() = same("saved-genres") { _, _ -> legacySavedGenres("en") }
}
