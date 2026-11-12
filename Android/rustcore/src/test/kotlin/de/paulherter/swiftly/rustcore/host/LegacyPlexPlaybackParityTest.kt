package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.LegacyPlayback
import de.paulherter.swiftly.rustcore.ServerKind
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.net.URL
import javax.crypto.spec.SecretKeySpec

/**
 * Old against new for the playback of a **Plex account**: the scripted calls of `Android/golden` (`plpx-*`) on the fixture's small
 * Plex, answers and the order of the timeline reports (`/fixture/reports`) compared.
 */
class LegacyPlexPlaybackParityTest {
    private val url = System.getenv("SWIFTLY_FIXTURE_URL")
    private val golden = System.getenv("SWIFTLY_GOLDEN_DIR")

    private object Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    private fun reportsNow(): List<String> {
        val a = JSONArray(URL("$url/fixture/reports").readText())
        return (0 until a.length()).map { a.getString(it) }
    }

    @Test fun plexPlayback() = runBlocking {
        assumeTrue("no fixture", url != null && golden != null)
        val core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient())
        val account = AccountRef(url!!, "pu1", "plex-token", ServerKind.PLEX, "golden-device")
        val failures = ArrayList<String>()
        fun same(name: String, new: String) {
            File("/tmp/andplex-new-$name.json").writeText(new)
            val old = File(golden!!, "$name.json").readText()
                .replace("\"ergebnis\":\"switched\"", "\"ergebnis\":\"gewechselt\"")
                .replace("\"ergebnis\":\"failed\"", "\"ergebnis\":\"gescheitert\"")
                .replace("\"ergebnis\":\"locked\"", "\"ergebnis\":\"gesperrt\"")
                .replace("\"ergebnis\":\"cancelled\"", "\"ergebnis\":\"abgebrochen\"")
            fun expand(text: String): String = runCatching {
                org.json.JSONObject(text).also { o -> o.optString("spielplan").takeIf { it.startsWith("{") }?.let { o.put("spielplan", org.json.JSONObject(it)) } }.toString()
            }.getOrDefault(text)
            val t = old.trimStart()
            val diff = when {
                name.contains("switch") || name.contains("quality") -> JsonParity.diff(expand(old), expand(new))
                t.startsWith("{") || t.startsWith("[") -> JsonParity.diff(old, new)
                old == new -> null
                old.toDoubleOrNull() != null && new.toDoubleOrNull() != null && Math.abs(old.toDouble() - new.toDouble()) < 1e-6 -> null
                else -> "text old '$old' new '$new'"
            }
            if (diff != null) failures += "$name: $diff"
        }
        // The queue coalesces progress reports, so repeats of one state count once; the order of the states is the contract.
        fun shape(name: String, newList: List<String>) {
            fun squash(l: List<String>) = l.map { it.replace("\\/", "/") }.fold(ArrayList<String>()) { acc, s -> if (acc.lastOrNull() != s) acc += s; acc }
            val old = JSONArray(File(golden!!, "$name.json").readText()).let { a -> squash((0 until a.length()).map { a.getString(it) }) }
            val new = squash(newList)
            File("/tmp/andplex-new-$name.json").writeText(JSONArray(new).toString())
            if (old != new) failures += "$name: old $old new $new"
        }
        fun fresh(): LegacyPlayback = core.legacyPlayback(account, "en").also { it.playbackSelection(true, 0) }
        fun tick(p: LegacyPlayback, name: String, d: Double, pos: Double, image: Boolean = true, audio: Boolean = true) =
            same("plpx-$name", p.playbackTick(d, pos, image, true, audio, false, false))

        run {
            val p = fresh()
            val before = reportsNow().size
            same("plpx-open", p.open("31", ""))
            p.nextAutomaticSet(true)
            tick(p, "t01-loading", 12.0, 0.0, image = false, audio = false)
            tick(p, "t02-first", 12.0, 0.5)
            tick(p, "t03-start", 12.0, 1.0)
            same("plpx-select", p.tracksSelect("[]", "[]", -1, "", "", false, "{}", "{}"))
            tick(p, "t04", 12.0, 5.0)
            same("plpx-controls-open", p.controlsChanged(true))
            same("plpx-jump", p.jumpReported(9.5))
            tick(p, "t05-after-jump", 12.0, 9.6)
            tick(p, "t06-card", 12.0, 10.5)
            same("plpx-display", p.displayTime(10.7, false).toString())
            same("plpx-prebuffer", p.prebufferDue(9.0, 12.0, true).toString())
            p.runStateReported(false, 10.7)
            p.runStateReported(true, 10.7)
            tick(p, "t07-end", 12.0, 11.95)
            same("plpx-end", p.playbackEnd(11.5))
            same("plpx-end-twice", p.playbackEnd(11.5))
            Thread.sleep(1500)
            shape("plpx-reports", reportsNow().drop(before))
        }
        run {
            val p = fresh()
            val before = reportsNow().size
            p.open("31", "")
            tick(p, "s01-first", 12.0, 0.5)
            tick(p, "s02-start", 12.0, 1.0)
            same("plpx-switch", p.episodeSwitch("", 5.0))
            tick(p, "s03-new-first", 12.0, 0.2)
            same("plpx-quality", p.qualitySwitch(3.0))
            same("plpx-end2", p.playbackEnd(4.0))
            Thread.sleep(1500)
            shape("plpx-reports2", reportsNow().drop(before))
        }
        run {
            val p = fresh()
            same("plpx-open-movie", p.open("10", ""))
            tick(p, "g01-first", 12.0, 0.5)
            same("plpx-tech", p.techFixed(false))
            p.playbackEnd(2.0)
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }
}
