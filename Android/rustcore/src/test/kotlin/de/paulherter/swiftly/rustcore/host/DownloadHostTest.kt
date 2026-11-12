package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.DownloadsIntent
import de.paulherter.swiftly.rustcore.KeyValueStore
import de.paulherter.swiftly.rustcore.PlayerSection
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.HttpURLConnection
import java.nio.file.Files
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

private class Hooks : DownloadHooks {
    override suspend fun address(id: String, source: String?, quality: String, audioIndex: Int?) = "http://x/$id"
    override suspend fun subtitles(id: String, source: String?) {}
    override suspend fun sections(id: String): List<PlayerSection>? = null
    override suspend fun successor(id: String, seriesId: String): Pair<ByteArray, String?>? = null
    override fun prepare(connection: HttpURLConnection) { connection.setRequestProperty("X-Own", "1") }
    override fun failureText(status: Int?, error: Throwable?) = if (status != null) "status $status" else "error ${error?.javaClass?.simpleName}"
}

/** The Kotlin download host against a local server, on the files and the index of the old app. */
class DownloadHostTest {
    private val server = MockWebServer().apply { start() }
    private val folder: File = Files.createTempDirectory("downloads").toFile()
    private val events = LinkedBlockingQueue<DownloadsIntent>()
    private val host = AndroidDownloadHost(folder, Hooks(), CoroutineScope(SupervisorJob() + Dispatchers.IO), progressEveryMs = 0)
        .also { it.sink = { e -> events.add(e) } }

    @After fun tearDown() { server.shutdown(); folder.deleteRecursively() }

    private fun last(): DownloadsIntent {
        var out: DownloadsIntent? = null
        while (true) {
            val e = events.poll(5, TimeUnit.SECONDS) ?: error("no event, last: $out")
            out = e
            if (e !is DownloadsIntent.TransferProgress) return e
        }
    }

    @Test fun wholeFileLandsUnderItsNameWithOwnHeaders() {
        val body = ByteArray(5000) { it.toByte() }
        server.enqueue(MockResponse().setBody(Buffer().write(body)))
        host.startTransfer("a", 1, "anna-a.mkv", server.url("/f").toString(), null)
        val done = last() as DownloadsIntent.TransferFinished
        assertTrue(done.worked); assertEquals(5000L, done.realSize)
        assertArrayEquals(body, File(folder, "anna-a.mkv").readBytes())
        assertFalse(File(folder, "anna-a.mkv.teil").exists())
        assertEquals("1", server.takeRequest().getHeader("X-Own"))
    }

    @Test fun oldPartialFileResumesWithRange() {
        val body = ByteArray(5000) { (it % 251).toByte() }
        File(folder, "anna-b.mkv.teil").writeBytes(body.copyOfRange(0, 2000))
        server.enqueue(MockResponse().setResponseCode(206).setBody(Buffer().write(body.copyOfRange(2000, 5000))))
        host.startTransfer("b", 1, "anna-b.mkv", server.url("/f").toString(), null)
        assertTrue((last() as DownloadsIntent.TransferFinished).worked)
        assertEquals("bytes=2000-", server.takeRequest().getHeader("Range"))
        assertArrayEquals(body, File(folder, "anna-b.mkv").readBytes())
    }

    @Test fun serverThatIgnoresRangeRestartsTheFile() {
        val body = ByteArray(3000) { 7 }
        File(folder, "anna-c.mkv.teil").writeBytes(ByteArray(1000) { 1 })
        server.enqueue(MockResponse().setResponseCode(200).setBody(Buffer().write(body)))
        host.startTransfer("c", 1, "anna-c.mkv", server.url("/f").toString(), null)
        assertTrue((last() as DownloadsIntent.TransferFinished).worked)
        assertArrayEquals(body, File(folder, "anna-c.mkv").readBytes())
    }

    @Test fun errorStatusFailsWithTheSentenceAndNoFile() {
        server.enqueue(MockResponse().setResponseCode(401).setBody("nope"))
        host.startTransfer("d", 4, "anna-d.mkv", server.url("/f").toString(), null)
        val failed = last() as DownloadsIntent.TransferFailed
        assertEquals("status 401", failed.reason); assertEquals(4L, failed.generation); assertNull(failed.resume)
        assertFalse(File(folder, "anna-d.mkv").exists())
    }

    @Test fun deleteStaysInsideTheFolder() {
        val outside = File(folder.parentFile, "outside-${System.nanoTime()}").apply { writeText("x") }
        File(folder, "anna-e.mkv").writeText("x"); File(folder, "anna-e.mkv.teil").writeText("x")
        host.deleteFile("media", "anna-e.mkv")
        host.deleteFile("media", "../${outside.name}")
        assertFalse(File(folder, "anna-e.mkv").exists()); assertFalse(File(folder, "anna-e.mkv.teil").exists())
        assertTrue(outside.exists()); outside.delete()
    }

    @Test fun imageIsFetchedOnceAndNeverHalfWritten() {
        server.enqueue(MockResponse().setBody("jpg"))
        host.fetchImage("anna-e.jpg", server.url("/i").toString())
        val deadline = System.currentTimeMillis() + 5000
        while (!File(folder, "anna-e.jpg").exists() && System.currentTimeMillis() < deadline) Thread.sleep(20)
        assertEquals("jpg", File(folder, "anna-e.jpg").readText())
        assertFalse(File(folder, "anna-e.jpg.neu").exists())
    }

    @Test fun indexKeyGoesToTheOldListFileAndOthersToTheStore() {
        val other = object : KeyValueStore {
            val map = HashMap<String, ByteArray>()
            override fun get(key: String) = map[key]
            override fun set(key: String, value: ByteArray) { map[key] = value }
            override fun remove(key: String) { map.remove(key) }
        }
        val store = DownloadIndexStore(folder, other)
        // A list as the old app wrote it (German keys, seconds since 2001).
        val old = """[{"id":"a","konto":"anna","art":"film","titel":"T","bytes":10,"geladen":10,"stand":"fertig","gesehen":false,"angelegt":7.5e8,"nochAufDemServer":true}]"""
        File(folder, "liste.json").writeText(old)
        assertEquals(old, String(store.get("downloads.list")!!))
        store.set("downloads.list", "[]".toByteArray())
        assertEquals("[]", File(folder, "liste.json").readText())
        assertFalse(File(folder, "liste.json.neu").exists())
        store.set("other", byteArrayOf(1)); assertNotNull(other.map["other"]); assertNull(store.get("nothing"))
    }
}
