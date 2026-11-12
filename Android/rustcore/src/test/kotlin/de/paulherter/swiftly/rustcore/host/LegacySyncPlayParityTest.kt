package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.RemoteEvent
import de.paulherter.swiftly.rustcore.ServerKind
import de.paulherter.swiftly.rustcore.SyncPlayHost
import de.paulherter.swiftly.rustcore.SyncPlayPage
import de.paulherter.swiftly.rustcore.SyncPlayPlayer
import de.paulherter.swiftly.rustcore.SyncPlayStep
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.net.URL
import java.util.Collections
import javax.crypto.spec.SecretKeySpec

/**
 * Old against new for watching together: the scripted group session `Android/golden` runs on the Swift `Kern` (`sp-*`),
 * run here on the core's `SyncPlayModel` over the `RemoteChannel` and the OkHttp websocket, both against the fixture
 * server's groups. Compared: the sheet's state at each stage (fields, not the version counter), the player steps
 * (kind and jump target), and the order of the SyncPlay calls at the server. Needs `SWIFTLY_FIXTURE_URL` and
 * `SWIFTLY_GOLDEN_DIR`.
 */
class LegacySyncPlayParityTest {
    private val url = System.getenv("SWIFTLY_FIXTURE_URL")
    private val golden = System.getenv("SWIFTLY_GOLDEN_DIR")

    private object Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    private class Steps : SyncPlayHost {
        val taken: MutableList<String> = Collections.synchronizedList(ArrayList())
        override fun playerStep(step: SyncPlayStep) {
            taken += when (step) {
                is SyncPlayStep.Proceed -> "weiter"
                is SyncPlayStep.Halt -> "anhalten"
                is SyncPlayStep.Jump -> "springen:${step.seconds}"
            }
        }
        override fun loadTitle(title: String, since: Double) { taken += "laden:$title" }
        fun drain(): List<String> = synchronized(taken) { taken.toList().also { taken.clear() } }
    }

    private fun get(path: String) = URL("$url$path").readText()

    /** The old step JSON as the same short text. */
    private fun oldSteps(name: String): List<String> {
        val a = JSONArray(File(golden!!, "sp-$name.json").readText())
        return (0 until a.length()).map {
            val o = JSONObject(a.get(it).toString())
            when (val art = o.getString("art")) {
                "springen" -> "springen:${o.getDouble("wert")}"
                "laden" -> "laden:${o.optString("titel")}"
                else -> art
            }
        }
    }

    private fun sameSteps(name: String, newSteps: List<String>, failures: MutableList<String>) {
        // A repeated "anhalten" (the old core answers the server's pause twice) is the same for the player: collapse repeats.
        fun collapse(l: List<String>) = l.filterIndexed { i, s -> i == 0 || s != l[i - 1] || s.startsWith("springen") }
        val old = collapse(oldSteps(name))
        val new = collapse(newSteps)
        val ok = old.size == new.size && old.indices.all { i ->
            val (o, n) = old[i] to new[i]
            if (o.startsWith("springen:") && n.startsWith("springen:")) Math.abs(o.substringAfter(':').toDouble() - n.substringAfter(':').toDouble()) < 1.5 else o == n
        }
        if (!ok) failures += "steps $name: old $old, new $new"
    }

    /** The Swift state's `lage` against the core's page: the same facts, the core's words for them. */
    private fun sameState(name: String, page: SyncPlayPage, failures: MutableList<String>) {
        val l = JSONObject(File(golden!!, "sp-$name.json").readText()).getJSONObject("lage")
        fun check(what: String, old: Any?, new: Any?) { if (old != new) failures += "state $name $what: old $old, new $new" }
        check("mayCreate", l.getBoolean("darfAnlegen"), page.mayCreate)
        check("mayJoin", l.getBoolean("darfBeitreten"), page.mayJoin)
        val offered = l.getJSONArray("angebote")
        check("offerings", (0 until offered.length()).map { offered.getJSONObject(it).getString("id") }, page.groups.map { it.id })
        val g = l.optJSONObject("gruppe")
        check("group", g?.getString("id"), page.current?.id)
        check("groupName", g?.getString("name"), page.current?.name)
        // Swift: running/halted/waits or nothing; the core says the phase in words or nothing.
        if (g != null) check("phase shown", !g.isNull("zustand"), page.current?.stateText != null)
        val others = l.getJSONArray("andere")
        for (i in 0 until others.length()) if (page.current?.withWhom?.contains(others.getString(i)) != true) failures += "state $name: ${others.getString(i)} missing in ${page.current?.withWhom}"
        check("queue", l.optString("schlangeTitel").ifEmpty { null }, page.queueTitle)
        check("notice", l.optJSONObject("ereignis")?.getString("text"), page.notice)
        check("error", l.isNull("fehler"), page.error == null)
        check("lastLeave", l.optString("zuletztVerlassen").ifEmpty { null } != null, page.lastLeave != null)
        // The structured side (`SyncPlayDetail`): exactly what the old JSON carried.
        val d = page.detail
        fun texts(a: JSONArray) = (0 until a.length()).map { a.getString(it) }
        check("offerings detail", (0 until offered.length()).map { i -> offered.getJSONObject(i).let { o -> listOf(o.getString("id"), o.optString("name"), texts(o.getJSONArray("teilnehmer")), texts(o.getJSONArray("namen")), o.optString("zustand")) } },
            d.offerings.map { listOf(it.id, it.name, it.participants, it.names, it.phase ?: "") })
        check("group detail", g?.let { listOf(it.getString("id"), it.optString("name"), texts(it.getJSONArray("teilnehmer")), texts(it.getJSONArray("namen")), it.optString("zustand")) },
            d.group?.let { listOf(it.id, it.name, it.participants, it.names, it.phase ?: "") })
        check("other", texts(others), d.other)
        val ev = l.optJSONObject("ereignis")
        check("notice kind", ev?.getString("art"), d.noticeKind)
        check("notice id present", ev != null, d.noticeId != null)
        check("error text", l.optString("fehler").ifEmpty { null }, d.errorLast)
        check("error number", l.optInt("fehlerNummer"), d.errorCount.toInt())
        check("accepted", l.optInt("angenommen"), d.accepted.toInt())
        // The adapter's JSON itself: the same keys as the old one, and (apart from the event's random id and the words) the same values.
        val mine = SyncPlayJson.state(page)
        check("json keys", l.keys().asSequence().toSortedSet().toList(), mine.keys().asSequence().toSortedSet().toList())
        for (k in listOf("darfAnlegen", "darfBeitreten", "andere", "arbeitet", "fehlerNummer", "angenommen")) check("json $k", l.opt(k).toString(), mine.opt(k).toString())
    }

    @Test fun groupSession() = runBlocking {
        assumeTrue("no fixture", url != null && golden != null && File(golden, "sp-00-start.json").exists())
        val core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient())
        val account = AccountRef(url!!, "u1", "fixture-token", ServerKind.JELLYFIN, "golden-device")
        get("/fixture/syncplay/reset")
        val player = Steps()
        val model = core.syncPlayModel(account, "en", "demo", player)
        val channel = core.remoteChannel(account, AndroidWebSocketLink(), LambdaRemoteListener(
            { e -> if (e is RemoteEvent.SyncPlay) model.feed(e.text) else if (e is RemoteEvent.ConnectionLost) model.linkLost() else if (e is RemoteEvent.ConnectionAgain) model.linkAgain() },
            {},
        ))
        val failures = ArrayList<String>()
        channel.start()
        model.refresh()
        delay(800)
        sameState("00-start", model.page(), failures)
        model.refresh()
        delay(800)
        sameState("01-offerings", model.page(), failures)
        model.create("Abend", "m1")
        delay(1200)
        sameState("02-created", model.page(), failures)
        get("/fixture/syncplay/guest?join=Anna")
        delay(800)
        sameState("03-guest", model.page(), failures)
        // Before the player is open the group's title comes as a load request (old: `syncPlayRequest` {"titel":"m1"}), not as a step.
        val asked = player.drain()
        if (asked != listOf("laden:m1")) failures += "play request: old [laden:m1], new $asked"
        var spot = 0.0
        var running = false
        val view = { SyncPlayPlayer("m1", true, spot) }
        model.playerAttached(view())
        suspend fun pump(seconds: Double) {
            repeat((seconds / 0.25).toInt()) {
                model.playerUpdate(view())
                model.playerTick()
                if (running) spot += 0.25
                delay(250)
            }
        }
        suspend fun steps(name: String) {
            delay(500)
            val all = player.drain()
            for (s in all) when {
                s == "weiter" -> running = true
                s == "anhalten" -> running = false
                s.startsWith("springen:") -> spot = s.substringAfter(':').toDouble()
            }
            sameSteps(name, all, failures)
        }
        pump(1.0); steps("05-steps-open"); sameState("05-open", model.page(), failures)
        model.requestToggle(running); pump(1.0); steps("06-steps-play"); sameState("06-play", model.page(), failures)
        model.requestJump(6.0); pump(1.0); steps("07-steps-jump"); sameState("07-jump", model.page(), failures)
        model.requestToggle(running); pump(1.0); steps("08-steps-pause"); sameState("08-pause", model.page(), failures)
        get("/fixture/syncplay/guest?leave=Anna")
        delay(800)
        sameState("09-guest-left", model.page(), failures)
        model.playerDetached()
        model.leave()
        delay(1000)
        sameState("10-left", model.page(), failures)
        val keep = Regex("^POST SyncPlay/(New|Join|SetNewQueue|Pause|Unpause|Seek|Leave)$")
        fun calls(json: String) = JSONArray(json).let { a -> (0 until a.length()).map { a.getString(it) }.filter { keep.matches(it) } }
        val old = calls(File(golden!!, "sp-calls.json").readText())
        val new = calls(get("/fixture/syncplay/calls"))
        if (old != new) failures += "calls: old $old, new $new"
        val keepAlive = JSONArray(get("/fixture/syncplay/calls")).let { a -> (0 until a.length()).any { a.getString(it).contains("KeepAlive") } }
        channel.stop()
        File("/tmp/andplay-sp-failures.txt").writeText(failures.joinToString("\n"))
        assertTrue("old and new SyncPlay differ (keepAlive seen=$keepAlive):\n" + failures.joinToString("\n"), failures.isEmpty())
    }
}
