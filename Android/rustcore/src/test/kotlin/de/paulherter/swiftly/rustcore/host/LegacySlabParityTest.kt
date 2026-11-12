package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.LegacyStopped
import de.paulherter.swiftly.rustcore.ServerKind
import de.paulherter.swiftly.rustcore.legacyStopsProcess
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.crypto.spec.SecretKeySpec

/** Old against new for stored-file playback and the stops: `slab-*` and `stops-*` of `Android/golden` against the core's. */
class LegacySlabParityTest {
    private val url = System.getenv("SWIFTLY_FIXTURE_URL")
    /** Recorded answers of the old Swift core, kept in `src/test/resources/golden`. */
    private val golden = File(javaClass.getResource("/golden/stops-auto.json")!!.toURI()).parentFile.path

    private object Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    private fun item(id: String, n: Int, done: Boolean) =
        """{"id":"$id","konto":"u1","art":"folge","titel":"Folge $n","serie":"Hafenlichter","serienId":"s1","staffel":1,"folge":$n,"bytes":8,"geladen":8,"stand":"${if (done) "fertig" else "wartet"}","gesehen":false,"angelegt":$n,"nochAufDemServer":true,"container":"mkv","laufzeitTicks":1000}"""

    @Test fun slabAndStops() = runBlocking {
        assumeTrue("no fixture", url != null)
        val core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient())
        val account = AccountRef(url!!, "u1", "fixture-token", ServerKind.JELLYFIN, "golden-device")
        val failures = ArrayList<String>()
        fun same(name: String, new: String) {
            File("/tmp/slab-new-$name.json").writeText(new)
            val old = File(golden, "$name.json").readText()
            val diff = if (old.trimStart().startsWith("{") || old.trimStart().startsWith("[")) JsonParity.diff(old, new) else if (old == new) null else "text old '$old' new '$new'"
            if (diff != null) failures += "$name: $diff"
        }
        val list = "[${item("e1", 1, true)},${item("e2", 2, true)},${item("e3", 3, false)}]"
        val p = core.legacyPlayback(account, "en")
        p.setDownloads(list, true)
        same("slab-open-e1", p.openSlab(item("e1", 1, true), "/tmp/golden-dl/e1.mkv", ""))
        same("slab-open-e2-image", p.openSlab(item("e2", 2, true), "/tmp/golden-dl/e2.mkv", "file:///tmp/golden-dl/e2.jpg"))
        same("slab-lookup-offline", p.lookUp())
        fun stop(id: String, ticks: Long, sent: Boolean) = LegacyStopped(id, "u1", ticks, 50.0, sent)
        same("stops-auto", legacyStopsProcess("[]", list, true, listOf(stop("e1", 950, false), stop("e2", 500, true), stop("zz", 1, true))))
        same("stops-plain", legacyStopsProcess("[]", list, false, listOf(stop("e1", 950, true))))
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }
}
