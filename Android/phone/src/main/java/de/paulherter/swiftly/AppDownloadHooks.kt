package de.paulherter.swiftly

import de.paulherter.swiftly.rustcore.PlayerSection
import de.paulherter.swiftly.rustcore.PlayerSectionKind
import de.paulherter.swiftly.rustcore.host.DownloadHooks
import de.paulherter.swiftly.shared.Texts
import kotlinx.coroutines.future.await
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * What the core's download host asks the app: the file address, the intro/outro sections, the series' episodes for the
 * next episode, the server's own headers and the sentence for a failure. Jellyfin and Emby answer from the Rust core;
 * **Plex still answers from the Swift core** until it is compared (`RustKern`), so its downloads work as before.
 */
class AppDownloadHooks(private val app: SwiftlyApplication) : DownloadHooks {
    override suspend fun address(id: String, source: String?, quality: String, audioIndex: Int?): String {
        val account = app.rk.account() ?: error("not signed in")
        app.rk.plexDetail()?.let { return it.downloadAddress(id, source, quality, audioIndex?.toLong()) }
        return app.rk.core().downloadAddress(account, Texts.language, id, source, quality, audioIndex?.toLong())
    }

    /**
     * **Takes the external subtitle files along** once the film itself is there (and, for a file the server built, the
     * embedded text tracks, which that file does not carry). The core names them (`SubtitleFile.with_load`); each lands
     * in `<file>.untertitel/<index>.<ending>`, a folder of its own so the player does not load them twice.
     */
    override suspend fun subtitles(id: String, source: String?) {
        val item = app.downloads.entries(id) ?: return
        val raw = runCatching {
            val chosen = item.source ?: source
            app.rk.plexDetail()?.downloadSubtitleFiles(id, chosen, item.streamed)
                ?: app.rk.detail()?.downloadSubtitleFiles(id, chosen, item.streamed)
        }.getOrNull().orEmpty()
        // A listing that cannot be read throws: the core keeps the title open and asks again on the next online start.
        val rows = runCatching { JSONArray(raw) }.getOrNull() ?: error("subtitle list unavailable")
        if (rows.length() == 0) return
        val target = DownloadSubtitles.folder(app.downloads.folder, item)
        target.mkdirs()
        var loaded = 0
        val facts = JSONArray()
        for (i in 0 until rows.length()) {
            val o = rows.getJSONObject(i)
            val bytes = runCatching { withContext(Dispatchers.IO) { fetch(o.getString("adresse")) } }.getOrNull() ?: continue
            val out = File(target, "${o.getLong("index")}.${o.getString("endung")}")
            if (runCatching { withContext(Dispatchers.IO) { out.writeBytes(bytes) } }.isSuccess) {
                loaded++
                o.optJSONObject("meta")?.let { facts.put(it) }
            }
        }
        // What each file is (language, title, flags; never an address) lies next to them, so offline reads like online.
        if (facts.length() > 0) runCatching { File(target, "info.json").writeText(facts.toString()) }
        AppLog.writeOut("[Download] Untertitel für $id: $loaded von ${rows.length()}")
        if (loaded < rows.length()) error("subtitle files missing")
    }

    private fun fetch(address: String): ByteArray? {
        val c = java.net.URL(address).openConnection() as HttpURLConnection
        return try {
            prepare(c)
            c.connectTimeout = 15000; c.readTimeout = 30000
            if (c.responseCode != 200) null else c.inputStream.use { it.readBytes() }.takeIf { it.isNotEmpty() }
        } finally { c.disconnect() }
    }

    override suspend fun sections(id: String): List<PlayerSection>? =
        app.rk.plexDetail()?.downloadSectionsTyped(id) ?: app.rk.detail()?.downloadSectionsTyped(id)

    override suspend fun successor(id: String, seriesId: String): Pair<ByteArray, String?>? {
        val watched = app.downloads.itemJson(id) ?: return null
        val found = app.rk.plexDetail()?.downloadSuccessor(watched) ?: app.rk.detail()?.downloadSuccessor(watched)
        return found?.let { it.episodesJson to it.image }
    }

    override fun prepare(connection: HttpURLConnection) {
        ownHeadersFields(connection.url.toString()).forEach { (name, value) -> connection.setRequestProperty(name, value) }
    }

    override fun failureText(status: Int?, error: Throwable?): String =
        if (status != null) KernRules.downloadErrorText(status.toLong()) else errorString(app, error ?: Exception())
}

/** Where a download's external subtitles live and how the player reads them back offline. */
object DownloadSubtitles {
    fun folder(downloads: File, item: DownloadItem) = File(downloads, item.fileName + ".untertitel")

    /** `<index>.<ending>` files of a folder as (index, ending, file), sorted by index. */
    fun list(folder: File): List<Triple<Long, String, File>> =
        folder.listFiles().orEmpty().mapNotNull { f ->
            val index = f.name.substringBefore('.').toLongOrNull() ?: return@mapNotNull null
            Triple(index, f.name.substringAfter('.'), f)
        }.sortedBy { it.first }
}
