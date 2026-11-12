package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.ServerKind
import de.paulherter.swiftly.rustcore.legacySubtitleFileStyleAdjustable
import de.paulherter.swiftly.rustcore.legacyUserImage
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.crypto.spec.SecretKeySpec

/** Old against new for title, series, episodes, person, trailers: Swift `Kern` answers against `Core.legacyDetail`. */
class LegacyDetailParityTest {
    private val url = System.getenv("SWIFTLY_FIXTURE_URL")
    private val golden = System.getenv("SWIFTLY_GOLDEN_DIR")

    private object Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    @Test fun detailAnswers() = runBlocking {
        assumeTrue("no fixture", url != null && golden != null)
        val core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient())
        val d = core.legacyDetail(AccountRef(url!!, "u1", "fixture-token", ServerKind.JELLYFIN, "golden-device"), "en")
        val failures = ArrayList<String>()
        fun same(name: String, new: String) {
            File("/tmp/andscr-new-$name.json").writeText(new)
            val old = File(golden!!, "$name.json").readText()
            val diff = if (old.trimStart().startsWith("{") || old.trimStart().startsWith("[")) JsonParity.diff(old, new)
                       else if (old == new) null else "text old '$old' new '$new'"
            if (diff != null) failures += "$name: $diff"
        }
        same("title-m0", d.title("m0"))
        same("title-m1", d.title("m1"))
        same("title-series", d.title("s1"))
        same("series-s1", d.series("s1"))
        same("series-from-episode", d.series("e2"))
        same("episodes-season", d.episodes("s1", "se1"))
        same("episodes-all", d.episodes("s1", ""))
        same("title-field-m0", d.titleField("m0"))
        same("trailers-web", d.trailers("m0", true))
        same("trailers-files", d.trailers("m0", false))
        same("person-p1", d.person("p1"))
        same("episode-after-e1", d.episodeAfter("e1", "s1"))
        same("episode-after-e3", d.episodeAfter("e3", "s1"))
        same("remember-ok", d.remember("m0", true))
        same("watched-ok", d.watched("m0", true))
        same("metadata-refresh", d.metadataRefresh("m0"))
        same("plan-m0", d.plan("m0"))
        same("plan-series", d.plan("s1"))
        same("plan-e1", d.plan("e1"))
        same("continue-take", d.fromContinueWatchingTake("m0"))
        same("load-episodes", d.loadSelectionEpisodes("s1", "se1"))
        same("load-episodes-all", d.loadSelectionEpisodes("s1", ""))
        same("user-image-160", legacyUserImage("""{"accessToken":"fixture-token","userID":"u1","userName":"demo","serverURL":"$url"}""", 160))
        same("subtitle-adjustable", legacySubtitleFileStyleAdjustable("jellyfin").toString())
        assertEquals("", legacyUserImage("not a session", 160))
        assertEquals(false, legacySubtitleFileStyleAdjustable("plex"))
        assertEquals(failures.joinToString("\n"), 0, failures.size)
    }

    @Test fun shuffledRunStaysInOrderUntilTheSeriesChanges() = runBlocking {
        assumeTrue("no fixture", url != null)
        val core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient())
        val d = core.legacyDetail(AccountRef(url!!, "u1", "fixture-token", ServerKind.JELLYFIN, "golden-device"), "en")
        val first = d.shuffleStart("s1")
        assertTrue(first, first in listOf("e1", "e2", "e3"))
        val run = d.runIds()
        assertEquals(setOf("e1", "e2", "e3"), run.toSet())
        assertEquals(run[1], d.episodeAfter(run[0], "s1"))
        assertEquals("", d.episodeAfter(run[2], "s1"))
    }
}
