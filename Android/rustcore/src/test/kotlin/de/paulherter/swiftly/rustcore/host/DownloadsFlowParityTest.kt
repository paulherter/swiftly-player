package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.DownloadHost
import de.paulherter.swiftly.rustcore.DownloadRequest
import de.paulherter.swiftly.rustcore.DownloadWatchState
import de.paulherter.swiftly.rustcore.DownloadsIntent
import de.paulherter.swiftly.rustcore.DownloadsVm
import de.paulherter.swiftly.rustcore.LegacyDetail
import de.paulherter.swiftly.rustcore.PlayerSection
import de.paulherter.swiftly.rustcore.ServerKind
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.net.HttpURLConnection
import java.nio.file.Files
import javax.crypto.spec.SecretKeySpec

/**
 * Old against new for the downloads: the Swift `Kern` answers (Android/golden) against the core's `DownloadsVm` flow over the
 * real [AndroidDownloadHost], started from the **old `liste.json`**, against the fixture server (`SWIFTLY_FIXTURE_URL`,
 * `SWIFTLY_GOLDEN_DIR`; skipped otherwise). Times (`angelegt`) are normalised: the two sides ran at different moments.
 */
class DownloadsFlowParityTest {
    private val url = System.getenv("SWIFTLY_FIXTURE_URL")
    private val golden = System.getenv("SWIFTLY_GOLDEN_DIR")

    private object Mem : StringPrefs {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
        override fun remove(key: String) { m.remove(key) }
    }

    private lateinit var folder: File
    private lateinit var core: Core
    private lateinit var detail: LegacyDetail
    private lateinit var host: AndroidDownloadHost
    private lateinit var vm: DownloadsVm
    private val images = ArrayList<Pair<String, String>>()
    private val account get() = AccountRef(url!!, "u1", "fixture-token", ServerKind.JELLYFIN, "golden-device")

    /** The old list the Swift side saw as input (`follow` in `golden/main.swift`). */
    private val oldList = """[{"id":"m0","konto":"u1","art":"film","titel":"Nordlicht","bytes":8,"geladen":8,"stand":"fertig","gesehen":false,"angelegt":1,"nochAufDemServer":true},{"id":"e1","konto":"u1","art":"folge","titel":"Folge 1","serie":"Hafenlichter","serienId":"s1","staffel":1,"folge":1,"bytes":8,"geladen":8,"stand":"fertig","gesehen":true,"angelegt":1,"nochAufDemServer":true},{"id":"gone9","konto":"u1","art":"film","titel":"Weg","bytes":8,"geladen":8,"stand":"fertig","gesehen":false,"angelegt":1,"nochAufDemServer":true}]"""

    private fun norm(s: String) = s.replace(Regex("\"angelegt\":[-0-9.eE+]+"), "\"angelegt\":0")
    private fun old(name: String) = File(golden!!, "$name.json").readText()
    private fun items() = String(vm.itemsJson())

    private fun same(name: String, new: String, failures: MutableList<String>) {
        File("/tmp/andscr-new-$name.json").writeText(norm(new))
        val a = norm(old(name))
        val diff = if (a.trimStart().startsWith("{") || a.trimStart().startsWith("[")) JsonParity.diff(a, norm(new))
                   else if (a == new) null else "text old '$a' new '$new'"
        if (diff != null) failures += "$name: $diff"
    }

    private fun waitFor(what: String, seconds: Int = 30, cond: () -> Boolean) {
        val end = System.currentTimeMillis() + seconds * 1000L
        while (System.currentTimeMillis() < end) { if (cond()) return; Thread.sleep(50) }
        throw AssertionError("timed out: $what; list ${items()}")
    }

    private fun state(id: String) = runCatching {
        JSONArray(items()).let { a -> (0 until a.length()).map { a.getJSONObject(it) }.firstOrNull { it.getString("id") == id }?.getString("stand") }
    }.getOrNull()

    /** A fixture server that the VM can reach; hooks over the core exactly as the app builds them. */
    private fun start(list: String, onlyOverWlan: Boolean, nextAuto: Boolean) {
        folder = Files.createTempDirectory("dlflow").toFile()
        File(folder, "liste.json").writeText(list)
        core = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            DownloadIndexStore(folder, AndroidKeyValueStore(Mem)), AndroidHttpClient())
        detail = core.legacyDetail(account, "en")
        val hooks = object : DownloadHooks {
            override suspend fun address(id: String, source: String?, quality: String, audioIndex: Int?) =
                core.downloadAddress(account, "en", id, source, quality, audioIndex?.toLong())
            override suspend fun subtitles(id: String, source: String?) {}
            override suspend fun sections(id: String): List<PlayerSection>? = detail.downloadSectionsTyped(id)
            override suspend fun successor(id: String, seriesId: String): Pair<ByteArray, String?>? {
                val a = JSONArray(items())
                val watched = (0 until a.length()).map { a.getJSONObject(it) }.first { it.getString("id") == id }
                return detail.downloadSuccessor(watched.toString())?.let { it.episodesJson to it.image }
            }
            override fun prepare(connection: HttpURLConnection) {}
            override fun failureText(status: Int?, error: Throwable?) = "status $status ${error?.message}"
        }
        host = AndroidDownloadHost(folder, hooks)
        val spy = object : DownloadHost by host {
            override fun fetchImage(name: String, url: String) { images += name to url; host.fetchImage(name, url) }
        }
        vm = core.downloadsVm(spy, "en", onlyOverWlan, nextAuto)
        host.sink = { vm.send(it) }
        vm.send(DownloadsIntent.SignIn("u1", true))
        // `StatFs` is not there in a unit test: the free space, as the device would measure it.
        vm.send(DownloadsIntent.SpaceChanged(50_000_000_000L))
    }

    @After fun clean() { if (this::folder.isInitialized) folder.deleteRecursively() }

    private fun request(post: JSONObject, replaces: String? = null) = DownloadRequest(
        post.getString("id"), post.getString("konto"), post.getString("art") == "folge", post.getString("titel"),
        post.optString("serie").ifEmpty { null }, post.optString("serienId").ifEmpty { null },
        if (post.has("staffel")) post.getLong("staffel") else null, if (post.has("folge")) post.getLong("folge") else null,
        if (post.has("laufzeitTicks")) post.getLong("laufzeitTicks") else null, post.optString("container").ifEmpty { null },
        post.optString("quelle").ifEmpty { null }, post.optLong("bytes"), post.getDouble("angelegt") + 978307200.0, null,
        post.optString("qualitaet").ifEmpty { null }, null, null, post.optString("bildcodec").ifEmpty { null }, replaces)

    @Test fun oldListIsReadAndTheCatchUpIsTheOldOne() = runBlocking {
        assumeTrue("no fixture", url != null && golden != null)
        start(oldList, onlyOverWlan = true, nextAuto = false)
        val failures = ArrayList<String>()
        // The old file, read as is.
        val read = JsonParity.diff(norm(oldList), norm(items()))
        if (read != null) failures += "old list read: $read"
        val f = detail.downloadFollowFetch(listOf("m0", "e1", "gone9"))!!
        vm.send(DownloadsIntent.ServerFollow(f.available, f.states))
        same("dl-catch-up", items(), failures)
        assertEquals(failures.joinToString("\n"), 0, failures.size)
    }

    @Test fun aTitleDownloadsUnderTheOldNamesAndTheListStaysReadable() = runBlocking {
        assumeTrue("no fixture", url != null && golden != null)
        start("[]", onlyOverWlan = false, nextAuto = false)
        val answer = JSONArray(detail.downloadItem(listOf("m0")))
        val failures = ArrayList<String>()
        // The post the old facade made, the same title the same way.
        val swift = JSONArray(old("dl-item"))
        val mine = JSONObject().put("posten", answer.getJSONObject(0).getJSONObject("posten")).put("bild", answer.getJSONObject(0).opt("bild"))
        val theirs = (0 until swift.length()).map { swift.getJSONObject(it) }.first { it.getJSONObject("posten").getString("id") == "m0" }
        JsonParity.diff(norm(theirs.toString()), norm(mine.toString()))?.let { failures += "dl-item m0: $it" }
        assertEquals(failures.joinToString("\n"), 0, failures.size)
        val post = answer.getJSONObject(0)
        vm.send(DownloadsIntent.Start(listOf(request(post.getJSONObject("posten"))), listOf(), false))
        waitFor("fertig") { state("m0") == "fertig" }
        // The files the old build would have written: <account>-<id>.<container>, no .teil left, the index `liste.json`.
        val file = File(folder, "u1-m0.mp4")
        assertTrue("file ${folder.list()?.toList()}", file.exists() && file.length() > 0)
        assertFalse(File(folder, "u1-m0.mp4.teil").exists())
        val index = JSONArray(File(folder, "liste.json").readText())
        assertEquals("fertig", index.getJSONObject(0).getString("stand"))
        assertEquals("u1", index.getJSONObject(0).getString("konto"))
    }

    @Test fun theNextEpisodeIsTheOldOne() = runBlocking {
        assumeTrue("no fixture", url != null && golden != null)
        // Wi-Fi only without Wi-Fi: the follower is queued and stays waiting.
        val watched = """{"id":"e1","konto":"u1","art":"folge","titel":"Folge 1","serie":"Hafenlichter","serienId":"s1","staffel":1,"folge":1,"bytes":8,"geladen":8,"stand":"fertig","gesehen":true,"angelegt":1,"nochAufDemServer":true,"qualitaet":"hd720","naechsteOffen":true}"""
        start("[$watched]", onlyOverWlan = true, nextAuto = true)
        vm.send(DownloadsIntent.NetworkChanged(wlan = false, none = false))
        vm.send(DownloadsIntent.SmartCatchUp)
        waitFor("follower") { state("e2") != null }
        val failures = ArrayList<String>()
        val swift = JSONObject(old("dl-following"))
        val a = JSONArray(items())
        val follower = (0 until a.length()).map { a.getJSONObject(it) }.first { it.getString("id") == "e2" }
        JsonParity.diff(norm(swift.getJSONObject("posten").toString()), norm(follower.toString()))?.let { failures += "dl-following posten: $it" }
        waitFor("image") { images.any { it.first.contains("e2") } }
        val image = images.first { it.first.contains("e2") }.second
        if (swift.optString("bild") != image) failures += "dl-following bild: old ${swift.optString("bild")} new $image"
        // The watched one is no longer pending.
        val first = (0 until a.length()).map { a.getJSONObject(it) }.first { it.getString("id") == "e1" }
        if (first.has("naechsteOffen")) failures += "e1 still pending"
        assertEquals(failures.joinToString("\n"), 0, failures.size)
    }

    @Test fun nothingFollowsTheLastEpisode() = runBlocking {
        assumeTrue("no fixture", url != null && golden != null)
        assertEquals("{}", old("dl-following-last"))
        val last = """{"id":"e3","konto":"u1","art":"folge","titel":"Folge 3","serie":"Hafenlichter","serienId":"s1","staffel":1,"folge":3,"bytes":8,"geladen":8,"stand":"fertig","gesehen":true,"angelegt":1,"nochAufDemServer":true,"naechsteOffen":true}"""
        start("[$last]", onlyOverWlan = true, nextAuto = true)
        vm.send(DownloadsIntent.NetworkChanged(wlan = false, none = false))
        vm.send(DownloadsIntent.SmartCatchUp)
        waitFor("pending cleared") { !items().contains("naechsteOffen") }
        assertEquals(1, JSONArray(items()).length())
    }

    @Test fun theWatchedEpisodeGoesOnceTheNextIsOnTheDevice() = runBlocking {
        assumeTrue("no fixture", url != null && golden != null)
        start(oldList, onlyOverWlan = false, nextAuto = true)
        val post = JSONArray(detail.downloadItem(listOf("e2"))).getJSONObject(0).getJSONObject("posten")
        vm.send(DownloadsIntent.Start(listOf(request(post, replaces = "e1")), listOf(), false))
        waitFor("e2 fertig") { state("e2") == "fertig" }
        waitFor("e1 gone") { state("e1") == null }
        // The old rule named the same one.
        assertEquals("e1", old("dl-replaced"))
    }

    @Test fun serverCallsAreTheOldOnes() = runBlocking {
        assumeTrue("no fixture", url != null && golden != null)
        val det = Core(AndroidPlatform("Golden", null) {}, AndroidSecretStore(Mem, GcmSealer { SecretKeySpec(ByteArray(32), "AES") }),
            AndroidKeyValueStore(Mem), AndroidHttpClient()).legacyDetail(account, "en")
        val failures = ArrayList<String>()
        same("dl-item", det.downloadItem(listOf("m0", "m9", "e1", "nope")), failures)
        same("dl-audio-single", det.downloadAudioOptions(listOf("m9"), "deu", "en"), failures)
        same("dl-audio-single-none", det.downloadAudioOptions(listOf("m0"), "deu", "en"), failures)
        same("dl-audio-selection", det.downloadAudioOptions(listOf("m0", "m9"), "eng", "en"), failures)
        val nine = """[{"id":"m9","konto":"u1","art":"film","titel":"Papierschiffe","bytes":1500000,"geladen":0,"stand":"wartet","gesehen":false,"angelegt":1,"nochAufDemServer":true,"container":"mp4","quelle":"src9"}]"""
        same("dl-with-audio-track", det.downloadWithAudio(nine, "track:3", "en"), failures)
        same("dl-with-audio-lang", det.downloadWithAudio(nine, "lang:eng", "en"), failures)
        same("dl-with-audio-all", det.downloadWithAudio(nine, "all", "en"), failures)
        same("dl-header-series", det.downloadHeaderImage("s1", 1200), failures)
        same("dl-header-missing", det.downloadHeaderImage("nope", 1200), failures)
        same("dl-sections", det.downloadSections("e1"), failures)
        val m1 = """{"itemID":"m0","konto":"u1","ticks":900,"wann":700000000}"""
        val m2 = """{"itemID":"m0","konto":"u1","ticks":100,"wann":700000100}"""
        val m3 = """{"itemID":"m1","konto":"u1","ticks":300,"wann":700000050}"""
        val s1 = de.paulherter.swiftly.rustcore.legacyPendingReportRecord("[]", m1)
        same("pending-record-first", s1, failures)
        val s2 = de.paulherter.swiftly.rustcore.legacyPendingReportRecord(s1, m2)
        same("pending-record-newer", s2, failures)
        val s3 = de.paulherter.swiftly.rustcore.legacyPendingReportRecord(s2, m3)
        same("pending-record-two", s3, failures)
        same("pending-record-garbage", de.paulherter.swiftly.rustcore.legacyPendingReportRecord(s3, "{nope"), failures)
        same("pending-done", de.paulherter.swiftly.rustcore.legacyPendingDone(s3, """["u1/m0"]"""), failures)
        same("pending-done-none", de.paulherter.swiftly.rustcore.legacyPendingDone(s3, "[]"), failures)
        same("watchers-m0", det.watchers("m0"), failures)
        same("lists-bitrate", de.paulherter.swiftly.rustcore.legacyBitrateLevels("en"), failures)
        same("lists-span", de.paulherter.swiftly.rustcore.legacySpan(), failures)
        same("lists-languages-file", de.paulherter.swiftly.rustcore.legacyLanguages("", "en"), failures)
        same("lists-languages-off", de.paulherter.swiftly.rustcore.legacyLanguages("Off", "en"), failures)
        same("lists-buffer", de.paulherter.swiftly.rustcore.legacyBufferLevels("en"), failures)
        same("pending-submit", det.pendingSubmit(s3), failures)
        same("pending-submit-empty", det.pendingSubmit("[]"), failures)
        assertEquals(failures.joinToString("\n"), 0, failures.size)
    }
}
