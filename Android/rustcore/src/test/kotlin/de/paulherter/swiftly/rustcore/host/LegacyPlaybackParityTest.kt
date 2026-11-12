package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.ServerKind
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.crypto.spec.SecretKeySpec

/**
 * Old against new for the open title: the Swift `Kern` answers (`Android/golden`, files `pl-open-*`, `pl-names-*`, ...)
 * against `Core.legacyPlayback` on the fixture's `g1`, a movie and episodes.
 */
class LegacyPlaybackParityTest {
    private val url = System.getenv("SWIFTLY_FIXTURE_URL")
    private val golden = System.getenv("SWIFTLY_GOLDEN_DIR")

    private object Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    private val engineAudio = """[{"id":1,"kennung":"audio/1","name":"Track 1 - [English]","sprache":"eng","fourcc":1631023981,"kanaele":2},{"id":2,"kennung":"audio/2","name":"Track 2 - [Deutsch]","sprache":"deu","fourcc":540681569,"kanaele":6}]"""
    private val engineSubtitle = """[{"id":-1,"kennung":"spu/-1","name":"Disable"},{"id":10,"kennung":"00000000000000000000000000000003/spu/0","name":"Track 3","sprache":"eng"},{"id":11,"kennung":"00000000000000000000000000000004/spu/0","name":"Track 4","sprache":"deu"}]"""

    /** A memory dictionary compared with its stored track imprints read as JSON (their key order is not part of the format). */
    private fun memoryDiff(old: String, new: String): String? {
        fun expand(text: String): JSONObject = JSONObject(text).also { o ->
            for (k in o.keys().asSequence().toList()) { val v = o.getString(k); if (v.startsWith("{")) o.put(k, JSONObject(v)) }
        }
        return JsonParity.diff(expand(old).toString(), expand(new).toString())
    }

    @Test fun playbackAnswers() = runBlocking {
        assumeTrue("no fixture", url != null && golden != null)
        val core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient())
        val account = AccountRef(url!!, "u1", "fixture-token", ServerKind.JELLYFIN, "golden-device")
        val failures = ArrayList<String>()
        fun same(name: String, new: String, memory: Boolean = false) {
            File("/tmp/andplay-new-$name.json").writeText(new)
            // The golden run on the Mac writes sizes with the Mac's decimal comma, the core with the app language's separator.
            val old = File(golden!!, "$name.json").readText().let { if (name.startsWith("pl-tech")) it.replace(Regex("(\\d),(\\d)"), "$1.$2") else it }
            val trimmed = old.trimStart()
            val diff = when {
                memory -> memoryDiff(old, new)
                trimmed.startsWith("{") || trimmed.startsWith("[") -> JsonParity.diff(old, new)
                old == new -> null
                else -> "text old '$old' new '$new'"
            }
            if (diff != null) failures += "$name: $diff"
        }
        for ((name, source) in listOf("g1" to "", "g1b" to "srcg1b")) {
            val p = core.legacyPlayback(account, "en")
            p.playbackSelection(true, 0)
            same("pl-open-$name", p.open("g1", source))
            same("pl-files-$name", p.subtitleFiles())
            p.subtitleAttributeSet(3, "00000000000000000000000000000003")
            p.subtitleAttributeSet(4, "00000000000000000000000000000004")
            same("pl-names-$name", p.trackNames(engineAudio, engineSubtitle))
            same("pl-select-plain-$name", p.tracksSelect(engineAudio, engineSubtitle, 1, "", "", false, "{}", "{}"))
            same("pl-select-wish-$name", p.tracksSelect(engineAudio, engineSubtitle, 1, "Deutsch", "Deutsch", true, "{}", "{}"))
            same("pl-select-off-$name", p.tracksSelect(engineAudio, engineSubtitle, 2, "", "English", true, "{}", """{"g1":""}"""))
            val handAudio = p.audioFromHand(engineAudio, 2, "{}")
            same("pl-hand-audio-$name", handAudio, memory = true)
            val handSub = p.subtitleFromHand(engineSubtitle, 11, "{}")
            same("pl-hand-sub-$name", handSub, memory = true)
            same("pl-hand-sub-off-$name", p.subtitleFromHand(engineSubtitle, -1, "{}"), memory = true)
            same("pl-select-memory-$name", p.tracksSelect(engineAudio, engineSubtitle, 1, "", "", false, handAudio, handSub))
            same("pl-chapters-$name", p.chapterLoad().toString())
            same("pl-chapter-bar-$name", p.chapterBar(12.0, 300.0, 40.0, 2.0))
            same("pl-chapter-bar-narrow-$name", p.chapterBar(12.0, 60.0, 40.0, 2.0))
            for (at in listOf(0.0, 2.5, 3.0, 11.0)) same("pl-chapter-name-${(at * 10).toInt()}-$name", p.chapterName(at))
            same("pl-chapter-piece-$name", p.chapterPiece(0.6, 12.0, 300.0, 40.0).toString())
            same("pl-trick-detail-$name", p.trickplayDetail())
            same("pl-trick-address-$name", p.trickplayAddress(320, 0))
            same("pl-video-codec-$name", p.firstFrameVideoCodec())
        }
        for (id in listOf("m0", "e1", "e2")) {
            val p = core.legacyPlayback(account, "en")
            p.playbackSelection(true, 0)
            same("pl-open-$id", p.open(id, ""))
            same("pl-chapters-$id", p.chapterLoad().toString())
            same("pl-trick-detail-$id", p.trickplayDetail())
        }
        for ((name, id, source) in listOf(Triple("g1", "g1", ""), Triple("g1b", "g1", "srcg1b"), Triple("m0", "m0", ""), Triple("e1", "e1", ""))) {
            val p = core.legacyPlayback(account, "en")
            p.playbackSelection(true, 0)
            p.open(id, source)
            same("pl-tech-$name", p.techFixed(false))
            same("pl-tech-measure-$name", p.techFixed(true))
            same("pl-techtick-$name", p.techTick(5_000_000, 3_000_000, 240, 2, 250, 500, 480, 1, 0, 0, 12.5, true))
            same("pl-techtick-bad-$name", p.techTick(0, 0, 5_000_000_000, 0, 0, 0, 0, 0, 0, 0, 1.0, true))
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }
}
