package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.ServerKind
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.crypto.spec.SecretKeySpec

/**
 * Old against new for the Home group: the answers of the Swift `Kern.home` (written by `Android/golden`, `swift run
 * golden <fixture> <folder>`) against `Core.legacyHome`, same fixture server, same arguments. Needs
 * `SWIFTLY_FIXTURE_URL` (cargo xtask fixture-server --port 8099) and `SWIFTLY_GOLDEN_DIR`; skipped without them.
 */
class LegacyHomeParityTest {
    private val url = System.getenv("SWIFTLY_FIXTURE_URL")
    private val golden = System.getenv("SWIFTLY_GOLDEN_DIR")

    private object Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    private val libraries = """[{"id":"lib-movies","name":"Filme","sammlung":false},{"id":"lib-shows","name":"Serien","sammlung":false}]"""

    private fun check(name: String, stored: List<String> = emptyList(), hidden: List<String> = emptyList(), disconnected: Boolean = false,
                      film: String = "", series: String = "", genres: List<String> = emptyList(), chips: Boolean = false, libs: String = "") = runBlocking {
        assumeTrue("no SWIFTLY_FIXTURE_URL / SWIFTLY_GOLDEN_DIR", url != null && golden != null)
        val core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient())
        val account = AccountRef(url!!, "u1", "fixture-token", ServerKind.JELLYFIN, "golden-device")
        val new = core.legacyHome(account, "en", disconnected, stored, hidden, film, series, genres, chips, libs)
        File("/tmp/andscr-new-$name.json").writeText(new)
        assertNull(name, JsonParity.diff(File(golden!!, "$name.json").readText(), new))
    }

    @Test fun homeDefault() = check("home-default")
    @Test fun homeDisconnectedWithOrderAndHidden() =
        check("home-disconnected", stored = listOf("neueFilme", "weiterschauen"), hidden = listOf("naechsteFolge"), disconnected = true, film = "lib-movies", series = "lib-shows")
    @Test fun homeGenreRowsAndOwnLibraries() = check("home-genres-libraries", genres = listOf("Drama"), libs = libraries)
    @Test fun homeGenreChipsGiveNoRows() = check("home-chips", genres = listOf("Drama"), chips = true)
}
