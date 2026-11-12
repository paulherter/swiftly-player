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

/** Old against new for the libraries and collections offered as own home rows (`Kern.startSelection`). */
class LegacyStartSelectionTest {
    private val url = System.getenv("SWIFTLY_FIXTURE_URL")
    private val golden = System.getenv("SWIFTLY_GOLDEN_DIR")

    private object Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    @Test fun offeredLibrariesAndCollections() = runBlocking {
        assumeTrue("no fixture", url != null && golden != null)
        val core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient())
        val lib = core.legacyLibrary(AccountRef(url!!, "u1", "fixture-token", ServerKind.JELLYFIN, "golden-device"), "en")
        for ((name, selected) in listOf(
            "start-selection-all" to "",
            "start-selection-some" to """[{"id":"lib-movies","name":"Filme","sammlung":false}]""",
        )) {
            val new = lib.startSelection(selected)
            File("/tmp/andscr-new-$name.json").writeText(new)
            assertNull(name, JsonParity.diff(File(golden!!, "$name.json").readText(), new))
        }
    }
}
