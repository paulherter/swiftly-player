package de.paulherter.swiftly.rustcore.host

import android.os.StatFs
import de.paulherter.swiftly.rustcore.DownloadHost
import de.paulherter.swiftly.rustcore.DownloadsIntent
import de.paulherter.swiftly.rustcore.PlayerSection
import de.paulherter.swiftly.rustcore.RunningTransferInfo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * What the app supplies to the download host: the server-side questions and the sentence for a failure. Everything
 * runs on an IO thread, never the main thread.
 */
interface DownloadHooks {
    /** The file address of a title (`Kern.downloadAddress` today); throws if the server gives none. */
    suspend fun address(id: String, source: String?, quality: String, audioIndex: Int?): String
    /** Fetch the external subtitle files and write them next to the media file. */
    suspend fun subtitles(id: String, source: String?)
    /** Intro/outro sections, `null` when there is no answer (the core asks again on the next contact). */
    suspend fun sections(id: String): List<PlayerSection>?
    /** The series' episodes as the server's `Items` JSON plus the next episode's landscape image. */
    suspend fun successor(id: String, seriesId: String): Pair<ByteArray, String?>?
    /** The server's own headers (`ownHeadersFields`), set on every request of this host. */
    fun prepare(connection: HttpURLConnection)
    /** The sentence for the screen: a status (`Kern.downloadErrorText`) or an error. */
    fun failureText(status: Int?, error: Throwable?): String
}

/**
 * The core's `DownloadHost` on the app's current mechanism: **plain `HttpURLConnection` transfers in the app's own
 * process** (a foreground service keeps it alive, see `DownloadService`), not WorkManager or the system
 * DownloadManager. The files are the old ones, so downloads made by either build stay usable:
 *
 * - folder `files/Downloads`, finished file `<file>` as the core names it (`<account>-<id>.<ext>`, same rule as the
 *   old `DownloadItem.fileName`), partial file `<file>.teil`, images `<account>-<id>.jpg`, index `liste.json`
 *   (kept by [DownloadIndexStore] under the core's `downloads.list` key);
 * - a transfer resumes with `Range: bytes=<size of .teil>-` whenever a partial file exists, whatever the core
 *   passes as resume data (the old manager did the same; a server that answers 200 restarts the file, which is what a
 *   transcoded stream does);
 * - the core's resume data is only the marker [RESUME]; the real state is the `.teil` file.
 *
 * Commands return at once; transfers run on [scope] and answer through [sink] (`DownloadsVm.send`). Progress goes
 * out at most once per [progressEveryMs] (the old `DownloadRules.progressShow` throttle).
 */
class AndroidDownloadHost(
    val folder: File,
    private val hooks: DownloadHooks,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val progressEveryMs: Long = 1000,
    private val clock: () -> Long = System::currentTimeMillis,
) : DownloadHost {
    /** Set after the `DownloadsVm` exists: `host.sink = { vm.send(it) }`. */
    @Volatile var sink: ((DownloadsIntent) -> Unit)? = null
    /** Told at every progress step (the foreground notification). */
    @Volatile var onProgress: ((id: String, loaded: Long, total: Long) -> Unit)? = null

    private class Running(val generation: Long, val file: String, val job: Job)
    private val running = HashMap<String, MutableList<Running>>()

    init { folder.mkdirs() }

    private fun emit(intent: DownloadsIntent) { sink?.invoke(intent) }
    /** Seconds since 2001, the clock the core expects in `TransferProgress.now`. */
    private fun appleNow() = clock() / 1000.0 - 978307200.0

    private fun part(file: String) = File(folder, "$file.teil")

    // ---- transfers ------------------------------------------------------------------------------------------------

    override fun startTransfer(id: String, generation: Long, file: String, address: String, resume: ByteArray?) {
        val job = scope.launch {
            try {
                val size = transfer(id, generation, file, address)
                emit(DownloadsIntent.TransferFinished(id, generation, file, worked = size != null, realSize = size))
            } catch (e: CancellationException) {
                throw e
            } catch (e: HttpStatus) {
                emit(DownloadsIntent.TransferFailed(id, generation, file, hooks.failureText(e.code, null), null))
            } catch (e: Throwable) {
                // With a partial file the old manager paused instead of failing; resume data tells the core that.
                val data = if (part(file).length() > 0) RESUME else null
                emit(DownloadsIntent.TransferFailed(id, generation, file, hooks.failureText(null, e), data))
            }
        }
        synchronized(running) { running.getOrPut(id) { ArrayList() }.add(Running(generation, file, job)) }
        job.invokeOnCompletion { synchronized(running) { running[id]?.removeAll { it.job === job } } }
    }

    private class HttpStatus(val code: Int) : IOException("HTTP $code")

    /** Returns the size of the finished file, or `null` if it could not be put in place. */
    private suspend fun transfer(id: String, generation: Long, file: String, address: String): Long? {
        val part = part(file)
        val already = if (part.exists()) part.length() else 0L
        val c = URL(address).openConnection() as HttpURLConnection
        try {
            c.connectTimeout = 15000; c.readTimeout = 30000
            hooks.prepare(c)
            if (already > 0) c.setRequestProperty("Range", "bytes=$already-")
            val code = c.responseCode
            // An error page is not a finished file.
            if (code !in 200..299) throw HttpStatus(code)
            val append = code == 206
            var loaded = if (append) already else 0L
            val total = c.contentLengthLong.takeIf { it > 0 }?.plus(loaded) ?: 0L
            var reportedAt = Long.MIN_VALUE
            c.inputStream.use { input ->
                FileOutputStream(part, append).use { out ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        kotlin.coroutines.coroutineContext.ensureActive()
                        val n = input.read(buffer)
                        if (n < 0) break
                        out.write(buffer, 0, n)
                        loaded += n
                        val now = clock()
                        if (reportedAt == Long.MIN_VALUE || now - reportedAt >= progressEveryMs) {
                            reportedAt = now
                            onProgress?.invoke(id, loaded, total)
                            emit(DownloadsIntent.TransferProgress(id, generation, file, loaded, total, appleNow()))
                        }
                    }
                }
            }
            kotlin.coroutines.coroutineContext.ensureActive()
            val target = File(folder, file)
            target.delete()
            return if (part.renameTo(target)) target.length() else null
        } finally {
            c.disconnect()
        }
    }

    override fun cancelTransfer(id: String, taskGeneration: Long?, newGeneration: Long, wantResumeData: Boolean) {
        val hit = synchronized(running) {
            val all = running[id].orEmpty()
            val hit = all.filter { taskGeneration == null || it.generation == taskGeneration }
            running[id] = all.filterTo(ArrayList()) { it !in hit }
            hit
        }
        for (r in hit) {
            r.job.cancel()
            if (wantResumeData) scope.launch {
                r.job.join()
                if (part(r.file).length() > 0) emit(DownloadsIntent.ResumeData(id, newGeneration, RESUME))
            }
        }
    }

    /** Nothing is suspended here: a paused transfer is a cancelled one with its `.teil` file. */
    override fun resumeTransfer(id: String) {}

    /** Transfers do not outlive the process; the core re-queues what was running (the old `read()` did the same). */
    override fun runningTransfers(): List<RunningTransferInfo> = emptyList()

    // ---- server questions -----------------------------------------------------------------------------------------

    override fun requestAddress(id: String, generation: Long, source: String?, quality: String, audioIndex: Long?) {
        scope.launch {
            try {
                val a = hooks.address(id, source, quality.lowercase(), audioIndex?.toInt())
                emit(DownloadsIntent.AddressReady(id, generation, a))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                emit(DownloadsIntent.AddressFailed(id, generation, "Keine Adresse vom Server."))
            }
        }
    }

    override fun fetchSubtitles(id: String, source: String?) {
        scope.launch {
            val ok = try { hooks.subtitles(id, source); true } catch (e: CancellationException) { throw e } catch (e: Throwable) { false }
            emit(DownloadsIntent.SubtitlesFetched(id, ok))
        }
    }

    override fun fetchSections(id: String) {
        scope.launch {
            val sections = runCatching { hooks.sections(id) }.getOrNull() ?: return@launch
            emit(DownloadsIntent.SectionsFetched(id, sections))
        }
    }

    override fun lookupSuccessor(id: String, seriesId: String) {
        scope.launch {
            val a = runCatching { hooks.successor(id, seriesId) }.getOrNull()
            emit(DownloadsIntent.SuccessorFound(id, a?.first, a?.second, clock() / 1000.0))
        }
    }

    // ---- files ----------------------------------------------------------------------------------------------------

    override fun deleteFile(kind: String, name: String) {
        // `name` comes from the core, relative to the folder; never a path out of it.
        val target = File(folder, name).canonicalFile
        if (target.parentFile?.canonicalPath != folder.canonicalPath) return
        target.deleteRecursively()
        if (kind == "media") part(name).delete()
    }

    override fun fetchImage(name: String, url: String) {
        val target = File(folder, name)
        if (target.exists()) return
        scope.launch {
            runCatching {
                val c = URL(url).openConnection() as HttpURLConnection
                try {
                    c.connectTimeout = 15000; c.readTimeout = 30000
                    hooks.prepare(c)
                    val new = File(target.path + ".neu")
                    val ok = c.responseCode in 200..299 && c.inputStream.use { i -> new.outputStream().use { i.copyTo(it) } } > 0
                    if (ok) new.renameTo(target) else new.delete()
                } finally { c.disconnect() }
            }
        }
    }

    override fun measureSpace() {
        emit(DownloadsIntent.SpaceChanged(runCatching { StatFs(folder.path).availableBytes }.getOrDefault(0L)))
    }

    companion object {
        /** What the core keeps as "resume data": the partial file is the real state. */
        val RESUME = "teil".toByteArray()
    }
}

/**
 * The core keeps its download list in the key-value store under `downloads.list`. This store hands that one key to
 * the file the old app wrote, `Downloads/liste.json` (same JSON array of items, same German field names), so an old
 * and a new build read one index; every other key goes to [other]. The old app writes through `liste.json.neu` and a
 * rename, and so does this.
 */
class DownloadIndexStore(
    private val folder: File,
    private val other: de.paulherter.swiftly.rustcore.KeyValueStore,
) : de.paulherter.swiftly.rustcore.KeyValueStore {
    private val list get() = File(folder, "liste.json")

    override fun get(key: String): ByteArray? =
        if (key == KEY) list.takeIf { it.exists() }?.readBytes() else other.get(key)

    override fun set(key: String, value: ByteArray) {
        if (key != KEY) return other.set(key, value)
        folder.mkdirs()
        val new = File(folder, "liste.json.neu")
        new.writeBytes(value)
        new.renameTo(list)
    }

    override fun remove(key: String) { if (key == KEY) list.delete() else other.remove(key) }

    companion object { const val KEY = "downloads.list" }
}
