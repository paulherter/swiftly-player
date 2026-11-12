package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.LegacyLibrary
import de.paulherter.swiftly.rustcore.ServerKind
import de.paulherter.swiftly.rustcore.legacyCollectionCountText
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.crypto.spec.SecretKeySpec

/**
 * Old against new for the stateful library calls. Each test is one fresh `LegacyLibrary`, answering in the same order
 * as the group of the Swift golden tool that starts on a fresh `Kern`, because both keep state between calls.
 */
class LegacySectionParityTest {
    private val url = System.getenv("SWIFTLY_FIXTURE_URL")
    private val golden = System.getenv("SWIFTLY_GOLDEN_DIR")

    private object Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    private fun group(body: suspend (LegacyLibrary, (String, String) -> Unit) -> Unit) = runBlocking {
        assumeTrue("no SWIFTLY_FIXTURE_URL / SWIFTLY_GOLDEN_DIR", url != null && golden != null)
        val core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient())
        val lib = core.legacyLibrary(AccountRef(url!!, "u1", "fixture-token", ServerKind.JELLYFIN, "golden-device"), "en")
        val failures = ArrayList<String>()
        body(lib) { name, new ->
            File("/tmp/andscr-new-$name.json").writeText(new)
            val old = File(golden!!, "$name.json").readText()
            // plain text answers (an id, a text) are compared as text
            val diff = if (old.trimStart().startsWith("{") || old.trimStart().startsWith("[")) JsonParity.diff(old, new)
                       else if (old == new) null else "text old $old new $new"
            if (diff != null) failures += "$name: $diff"
        }
        assertEquals(failures.joinToString("\n"), 0, failures.size)
    }

    @Test fun offeringBeforeAnythingIsLoaded() = group { l, same ->
        same("section-offering-cold", l.sectionOffering("movies", ""))
    }

    @Test fun collectionsPlaylistsAndCards() = group { l, same ->
        same("collections-movies", l.collections("movies"))
        same("collections-tvshows", l.collections("tvshows"))
        same("section-offering-loaded", l.sectionOffering("movies", "sammlungen"))
        same("section-offering-shows", l.sectionOffering("tvshows", "lib-shows"))
        same("playlists-movies", l.playlists("movies"))
        same("playlists-tvshows", l.playlists("tvshows"))
        same("playlist-page-movies", l.playlistPage("pl1", "movies"))
        same("playlist-page-all", l.playlistPage("pl1", ""))
        same("playlist-start", l.playlistStart("pl1", "movies"))
        same("collection-page-name", l.collectionPage("c1", "movies", "name", "alle", 0, 50))
        same("collection-page-name-next", l.collectionPage("c1", "movies", "name", "alle", 1, 50))
        same("collection-page-year", l.collectionPage("c1", "movies", "erscheinung", "ungesehen", 0, 50))
        same("collection-mosaic", l.collectionMosaic("c1", "movies", 300))
        same("collections-for-title", l.collectionsForTitle("m0"))
        same("collections-for-series", l.collectionsForTitle("s1"))
        same("collection-count-text", legacyCollectionCountText("movies", 3, "en"))
    }

    @Test fun sectionPages() = group { l, same ->
        same("section-page-all-name", l.sectionPage("movies", "alle", "name", "alle", 0, 50))
        same("section-page-all-name-next", l.sectionPage("movies", "alle", "name", "alle", 2, 50))
        same("section-page-all-rating", l.sectionPage("movies", "alle", "bewertung", "alle", 0, 3))
        same("section-page-library-latest", l.sectionPage("movies", "lib-movies", "neueste", "alle", 0, 50))
        same("section-page-shows-year", l.sectionPage("tvshows", "alle", "erscheinung", "ungesehen", 0, 50))
        same("section-page-collections", l.sectionPage("movies", "sammlungen", "name", "alle", 0, 50))
    }
}
