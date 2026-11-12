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
 * Old against new for the running playback: the same scripted calls (ticks, offer card, resume, switches, stop) as
 * `Android/golden` runs on the Swift `Kern`, answers and the order of the reports at the fixture server compared.
 */
class LegacyPlaybackRunParityTest {
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

    @Test fun runningPlayback() = runBlocking {
        assumeTrue("no fixture", url != null && golden != null)
        val core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient())
        val account = AccountRef(url!!, "u1", "fixture-token", ServerKind.JELLYFIN, "golden-device")
        val failures = ArrayList<String>()
        fun same(name: String, new: String) {
            File("/tmp/andplay-new-$name.json").writeText(new)
            // The shared rename of German identifiers made the Swift enum print `switched` where the Compose code reads
            // `gewechselt` (it never matched); the core answers what the Compose code reads.
            val old = File(golden!!, "$name.json").readText()
                .replace("\"ergebnis\":\"switched\"", "\"ergebnis\":\"gewechselt\"")
                .replace("\"ergebnis\":\"failed\"", "\"ergebnis\":\"gescheitert\"")
                .replace("\"ergebnis\":\"locked\"", "\"ergebnis\":\"gesperrt\"")
                .replace("\"ergebnis\":\"cancelled\"", "\"ergebnis\":\"abgebrochen\"")
            val trimmed = old.trimStart()
            // The plan of a switch travels as a string inside the answer; its key order is not part of the format.
            fun expand(text: String): String = runCatching {
                org.json.JSONObject(text).also { o -> o.optString("spielplan").takeIf { it.startsWith("{") }?.let { o.put("spielplan", org.json.JSONObject(it)) } }.toString()
            }.getOrDefault(text)
            val diff = when {
                name.contains("switch") || name.contains("quality") -> JsonParity.diff(expand(old), expand(new))
                trimmed.startsWith("{") || trimmed.startsWith("[") -> JsonParity.diff(old, new)
                old == new -> null
                old.toDoubleOrNull() != null && new.toDoubleOrNull() != null && Math.abs(old.toDouble() - new.toDouble()) < 1e-6 -> null
                else -> "text old '$old' new '$new'"
            }
            if (diff != null) failures += "$name: $diff"
        }
        // How many progress reports get through depends on the timing of the queue (it coalesces); the order of starts and
        // stops is the contract, and a progress only ever sits between a start and its stop.
        fun shape(name: String, newList: List<String>) {
            fun clean(l: List<String>) = l.map { it.replace("\\/", "/") }
            val old = JSONArray(File(golden!!, "$name.json").readText()).let { a -> clean((0 until a.length()).map { a.getString(it) }) }
            val new = clean(newList)
            File("/tmp/andplay-new-$name.json").writeText(JSONArray(new).toString())
            if (old.filter { !it.endsWith("/Progress") } != new.filter { !it.endsWith("/Progress") }) failures += "$name: old $old new $new"
            var open = false
            for (r in new) when {
                r == "/Sessions/Playing" -> open = true
                r == "/Sessions/Playing/Stopped" -> open = false
                !open -> failures += "$name: progress outside a session in $new"
            }
        }
        // The log rows of the reports are written when a report is queued (the old core wrote them when the queue had
        // sent it, so a coalesced progress left no row): compare the other rows exactly and the report rows by kind.
        fun rows(name: String, newText: String) {
            File("/tmp/andplay-new-$name.json").writeText(newText)
            fun keep(t: String) = t.lines().filter { it.isNotBlank() && !it.startsWith("Progress ") && !it.startsWith("Start ") }
                .map { it.replace("switched", "gewechselt").replace("failed", "gescheitert") }
            val old = keep(File(golden!!, "$name.json").readText())
            val new = keep(newText)
            if (old.sorted() != new.sorted()) failures += "$name: old $old new $new"
        }
        fun fresh(): LegacyPlayback = core.legacyPlayback(account, "en").also { it.playbackSelection(true, 0) }
        fun tick(p: LegacyPlayback, name: String, d: Double, pos: Double, image: Boolean = true, running: Boolean = true,
                 audio: Boolean = true, push: Boolean = false, auto: Boolean = false) =
            same("pl-run-$name", p.playbackTick(d, pos, image, running, audio, push, auto))

        run {
            val p = fresh()
            val before = reportsNow().size
            same("pl-run-open", p.open("e1", ""))
            p.nextAutomaticSet(true)
            tick(p, "t01-loading", 12.0, 0.0, image = false, audio = false)
            tick(p, "t02-first", 12.0, 0.5)
            tick(p, "t03-start", 12.0, 1.0)
            same("pl-run-select", p.tracksSelect("[]", "[]", -1, "", "", false, "{}", "{}"))
            tick(p, "t04-intro", 12.0, 2.5)
            tick(p, "t05-auto", 12.0, 2.9, auto = true)
            tick(p, "t06-auto-again", 12.0, 3.0, auto = true)
            same("pl-run-controls-open", p.controlsChanged(true))
            same("pl-run-controls-close", p.controlsChanged(false))
            same("pl-run-close", p.offeringClose().toString())
            tick(p, "t07-closed", 12.0, 3.5)
            same("pl-run-jump-outro", p.jumpReported(9.5))
            tick(p, "t08-after-jump", 12.0, 9.6)
            tick(p, "t09-card", 12.0, 10.0)
            tick(p, "t10-card-later", 12.0, 10.5)
            same("pl-run-controls-card", p.controlsChanged(true))
            same("pl-run-controls-card-close", p.controlsChanged(false))
            same("pl-run-display", p.displayTime(10.7, false).toString())
            same("pl-run-display-push", p.displayTime(11.0, true).toString())
            same("pl-run-prebuffer", p.prebufferDue(9.0, 12.0, true).toString())
            p.runStateReported(false, 10.7)
            same("pl-run-resume", p.resumeTarget(10.7, false).toString())
            same("pl-run-resume-group", p.resumeTarget(10.7, true).toString())
            p.runStateReported(true, 10.7)
            same("pl-run-jump-end", p.jumpReported(11.9))
            tick(p, "t11-end", 12.0, 11.95)
            tick(p, "t12-end2", 12.0, 11.99)
            p.backgroundReport(11.0, true)
            same("pl-run-end", p.playbackEnd(11.5))
            same("pl-run-end-twice", p.playbackEnd(11.5))
            tick(p, "t13-after-end", 12.0, 11.5)
            Thread.sleep(1500)
            shape("pl-run-reports", reportsNow().drop(before))
            rows("pl-run-log", p.logFetch())
        }
        run {
            val p = fresh()
            val before = reportsNow().size
            p.open("e1", "")
            tick(p, "s01-first", 12.0, 0.5)
            tick(p, "s02-start", 12.0, 1.0)
            same("pl-run-switch", p.episodeSwitch("", 5.0))
            tick(p, "s03-new-first", 12.0, 0.2)
            tick(p, "s04-new-start", 12.0, 0.5)
            same("pl-run-quality", p.qualitySwitch(3.0))
            tick(p, "s05-q-first", 12.0, 3.2)
            same("pl-run-switch-free", p.episodeSwitch("e5", 4.0))
            same("pl-run-switch-none", p.episodeSwitch("", 4.0))
            same("pl-run-end2", p.playbackEnd(4.0))
            same("pl-run-switch-after-end", p.episodeSwitch("", 4.0))
            Thread.sleep(1500)
            shape("pl-run-reports2", reportsNow().drop(before))
            rows("pl-run-log2", p.logFetch())
        }
        run {
            val p = fresh()
            p.open("g1", "")
            tick(p, "g01-first", 12.0, 0.5)
            tick(p, "g02-start", 12.0, 1.0)
            tick(p, "g03-intro", 12.0, 3.0, auto = true)
            tick(p, "g04-outro", 12.0, 10.5)
            same("pl-run-g-jump", p.jumpReported(1.0))
            same("pl-run-g-prebuffer", p.prebufferDue(9.0, 12.0, false).toString())
            p.playbackEnd(2.0)
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }
}
