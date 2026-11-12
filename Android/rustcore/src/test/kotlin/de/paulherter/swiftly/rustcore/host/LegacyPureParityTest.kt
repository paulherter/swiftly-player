package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.ServerKind
import de.paulherter.swiftly.rustcore.legacyEpisodeCard
import de.paulherter.swiftly.rustcore.legacyEpisodeCardDragged
import de.paulherter.swiftly.rustcore.legacyEpisodeCardFadeFrom
import de.paulherter.swiftly.rustcore.legacyEpisodeCardSwipedAway
import de.paulherter.swiftly.rustcore.legacyEpisodeCardWidth
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.crypto.spec.SecretKeySpec

/** Old against new for `can`, `serverName`, `accountDefaults` and the episode card: recorded Swift answers in `src/test/resources/golden`. */
class LegacyPureParityTest {
    private val url = System.getenv("SWIFTLY_FIXTURE_URL")
    private fun old(name: String) = javaClass.getResource("/golden/$name.json")!!.readText()

    private object Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    private fun core() = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
        AndroidKeyValueStore(Mem), AndroidHttpClient())

    private val caps = listOf("quickConnect", "publicUsers", "syncPlay", "remoteControl", "playOnOtherDevice", "settingsSync", "trickplay",
        "introSegments", "chapters", "collections", "playlists", "favorites", "markWatched", "similar", "extras", "genres", "seerr", "downloads", "bogus")

    @Test fun can() {
        val core = core()
        for ((name, kind) in listOf("jellyfin" to ServerKind.JELLYFIN, "emby" to ServerKind.EMBY, "plex" to ServerKind.PLEX, "none" to ServerKind.JELLYFIN)) {
            assertEquals(name, old("can-$name"), caps.filter { core.legacyCan(kind, it) }.joinToString(","))
        }
    }

    @Test fun episodeCard() {
        assertNull(JsonParity.diff(old("episode-card-phone"), legacyEpisodeCard(false)))
        assertNull(JsonParity.diff(old("episode-card-tv"), legacyEpisodeCard(true)))
        for ((n, a) in listOf("a" to Triple(320.0, false, false), "b" to Triple(400.0, true, false), "c" to Triple(900.0, false, true), "d" to Triple(1920.0, true, true))) {
            assertEquals(n, old("episode-card-width-$n").toDouble(), legacyEpisodeCardWidth(a.first, a.second, a.third), 0.0)
        }
        fun list(name: String) = old(name).split(",")
        assertEquals(list("episode-card-dragged").map { it.toDouble() }, listOf(-50.0, -1.0, 0.0, 30.0, 400.0).map { legacyEpisodeCardDragged(it) })
        assertEquals(list("episode-card-swiped"), listOf(listOf(0.0, 0.0, 0.0, 0.0), listOf(200.0, 0.0, 0.0, 0.0), listOf(10.0, 10.0, 900.0, 0.0),
            listOf(0.0, 300.0, 0.0, 500.0), listOf(-100.0, 0.0, -900.0, 0.0)).map { legacyEpisodeCardSwipedAway(it[0], it[1], it[2], it[3]).toString() })
        assertEquals(list("episode-card-fade").map { it.toDouble() }, listOf(-1.0, 0.0, 0.5, 2.0).map { legacyEpisodeCardFadeFrom(it) })
    }

    @Test fun serverNameAndDefaults() = runBlocking {
        assumeTrue("no fixture", url != null)
        val core = core()
        val account = AccountRef(url!!, "u1", "fixture-token", ServerKind.JELLYFIN, "golden-device")
        assertEquals(old("server-name"), core.legacyServerName(account))
        assertEquals(old("account-defaults"), core.legacyAccountDefaults(account))
    }
}
