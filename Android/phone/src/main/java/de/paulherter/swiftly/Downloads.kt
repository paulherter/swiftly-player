package de.paulherter.swiftly

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.IBinder
import android.os.StatFs
import android.os.SystemClock
import androidx.compose.runtime.mutableStateOf
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlin.coroutines.coroutineContext

/**
 * Counterpart of `DownloadItem` in the package: **the same JSON**, so the rules there can compute.
 * `created` stays the number Swift writes (seconds since 2001); it is only passed through here.
 */
data class DownloadItem(
    val id: String, val account: String, val art: String, val title: String,
    val series: String?, val seriesIdentifier: String?, val season: Int?, val episode: Int?,
    val runtimeTicks: Long?, val container: String?, val source: String?, val bytes: Long,
    val loaded: Long, val state: String, val reason: String?, val watched: Boolean,
    val created: Double, val stillOnTheServer: Boolean,
    /** Raw value of `DownloadQuality`; `null` means original. */
    val quality: String? = null,
    /**
     * Offline data, all three computed by the package and only passed through here; if they are missing
     * on save, they are lost. `sections` stays the raw JSON array (`null`: never asked), `recent`
     * like `created` the number Swift writes.
     */
    val sections: String? = null,
    val pointTicks: Long? = null,
    val recent: Double? = null,
) {
    /**
     * Account and id, plus the container extension so VLC guesses the demuxer. Must match
     * `DownloadItem.fileName` in the package (the core looks the file up under this name); all parts
     * come from the server and go through [Pfadteil].
     */
    val fileName: String get() = "${PathPart.safe(account)}-${PathPart.safe(id)}" +
        (PathPart.suffix(container)?.let { ".$it" } ?: "")
    /** Transcoded by the server: `bytes` is an estimate until the end. */
    val converted: Boolean get() = quality != null && quality != "original"
    /** Like `DownloadItem.share`: an estimate never quite reaches full before the end. */
    val share: Double? get() = if (bytes > 0) (loaded.toDouble() / bytes).coerceIn(0.0, 1.0)
        .let { if (converted && state != "fertig") it.coerceAtMost(0.99) else it } else null

    fun json(): JSONObject = JSONObject().apply {
        put("id", id); put("konto", account); put("art", art); put("titel", title)
        putOpt("serie", series); putOpt("serienId", seriesIdentifier); putOpt("staffel", season); putOpt("folge", episode)
        putOpt("laufzeitTicks", runtimeTicks); putOpt("container", container); putOpt("quelle", source)
        put("bytes", bytes); put("geladen", loaded); put("stand", state); putOpt("grund", reason)
        put("gesehen", watched); put("angelegt", created); put("nochAufDemServer", stillOnTheServer)
        putOpt("qualitaet", quality)
        sections?.let { put("abschnitte", JSONArray(it)) }
        putOpt("stelleTicks", pointTicks); putOpt("zuletzt", recent)
    }

    /** Where the list starts playing (`DownloadItem.resumeFrom`); `null` means from the start. */
    val resumeFrom: Double? get() = Kern.downloadResumeFrom(json().toString()).takeIf { it > 0 }

    /** Takes over the watch state from another state of the same item; the core computed it. */
    fun withWatchState(from: DownloadItem) = copy(watched = from.watched, pointTicks = from.pointTicks, recent = from.recent)

    companion object {
        fun read(o: JSONObject) = DownloadItem(
            o.getString("id"), o.getString("konto"), o.getString("art"), o.getString("titel"),
            o.fieldText("serie"), o.fieldText("serienId"), o.optInt("staffel").takeIf { o.has("staffel") && !o.isNull("staffel") },
            o.optInt("folge").takeIf { o.has("folge") && !o.isNull("folge") },
            o.optLong("laufzeitTicks").takeIf { o.has("laufzeitTicks") && !o.isNull("laufzeitTicks") },
            o.optString("container").takeIf { o.has("container") && !o.isNull("container") },
            o.optString("quelle").takeIf { o.has("quelle") && !o.isNull("quelle") },
            o.optLong("bytes"), o.optLong("geladen"), o.getString("stand"),
            o.optString("grund").takeIf { o.has("grund") && !o.isNull("grund") },
            o.optBoolean("gesehen"), o.optDouble("angelegt", 0.0), o.optBoolean("nochAufDemServer", true),
            o.fieldText("qualitaet"),
            o.optJSONArray("abschnitte")?.toString(),
            o.optLong("stelleTicks").takeIf { o.has("stelleTicks") && !o.isNull("stelleTicks") },
            o.optDouble("zuletzt").takeIf { o.has("zuletzt") && !o.isNull("zuletzt") })

        fun list(entries: List<DownloadItem>): String = JSONArray().apply { entries.forEach { put(it.json()) } }.toString()
    }
}

/** The message is already the sentence for the screen, never a code or a type name. */
private class LoadError(reason: String) : Exception(reason)

/**
 * Mirrors `DownloadManager` in `Sources/Shared/DownloadManager.swift`.
 *
 * **Only one item downloads at a time**, and `tick()` is the **only** place that starts a download,
 * after every change, every network change and at launch. The list holds all accounts, only the
 * current one is visible. Progress is written on pause and at the end, not on every chunk.
 * Resuming uses `Range` on the partial `.part` file.
 */
class DownloadManager(private val app: SwiftlyApplication) {
    val folder = File(app.filesDir, "Downloads").apply { mkdirs() }
    private val listFile = File(folder, "liste.json")
    private var all: List<DownloadItem> = read()

    /** The items of the current account. */
    val entries = mutableStateOf<List<DownloadItem>>(emptyList())
    /** Any network at all, for "Waiting for network" and "No network". */
    val network = mutableStateOf(true)
    /**
     * Taken immediately from the current network, not `true` until the first callback, which only
     * arrives after the first `tick()`. With `true`, a waiting download started on mobile data at
     * launch and the callback stopped it again right away.
     */
    private var wLAN = runCatching {
        val v = app.getSystemService(ConnectivityManager::class.java)
        v.getNetworkCapabilities(v.activeNetwork)?.let { isWLAN(it) } ?: false
    }.getOrDefault(false)
    private var account = ""

    private val run = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var task: Job? = null
    private var ongoing: String? = null
    private var reportedAround = 0L

    init {
        val connection = app.getSystemService(ConnectivityManager::class.java)
        runCatching {
            connection.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(n: Network, c: NetworkCapabilities) {
                    val wlan = isWLAN(c)
                    run.launch { network.value = true; wLAN = wlan; coreReport(); tick() }
                }
                override fun onLost(n: Network) { run.launch { network.value = false; wLAN = false; coreReport(); tick() } }
            })
        }
    }

    // Ethernet counts like Wi-Fi: both are free.
    private fun isWLAN(c: NetworkCapabilities) =
        c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || c.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)

    private fun read(): List<DownloadItem> = runCatching {
        JSONArray(listFile.readText()).let { a -> (0 until a.length()).map { DownloadItem.read(a.getJSONObject(it)) } }
    }.getOrDefault(emptyList())
        // Whoever was loading when the app quit now waits; what is loaded is what is on disk.
        .map { if (it.state == "laedt") it.copy(state = "wartet", loaded = part(it).length()) else it }

    private fun persist() {
        val new = File(folder, "liste.json.neu")
        new.writeText(DownloadItem.list(all))
        new.renameTo(listFile)
    }

    private fun showItem() {
        entries.value = all.filter { it.account == account }
        coreReport()
    }

    /** The core needs the list for "Next episode", chapters and watch state without a server. */
    private fun coreReport() {
        runCatching { app.kern.downloadsKnown(DownloadItem.list(entries.value), folder.path, !network.value) }
    }

    private fun part(p: DownloadItem) = File(folder, p.fileName + ".teil")
    fun imageFile(identifier: String) = File(folder, "${PathPart.safe(account)}-${PathPart.safe(identifier)}.jpg")

    fun mayLoad(): Boolean = Kern.downloadMayLoad(wLAN, app.settings.onlyOverWLAN)

    fun free(): Long = runCatching { StatFs(folder.path).availableBytes }.getOrDefault(0L)
    fun total(): Long = runCatching { StatFs(folder.path).totalBytes }.getOrDefault(0L)

    /** After sign-in, what belongs to this account applies. A running item of the old one stops. */
    fun accountSet(new: String) {
        if (new == account) return
        ongoing?.let { id -> if (all.any { it.id == id && it.account != new }) halt(id) }
        account = new
        showItem()
        tick()
    }

    fun entries(id: String): DownloadItem? = entries.value.firstOrNull { it.id == id }

    fun file(id: String): File? = entries(id)?.takeIf { it.state == "fertig" }?.let { File(folder, it.fileName) }?.takeIf { it.exists() }

    private fun change(id: String, write: Boolean = true, new: (DownloadItem) -> DownloadItem) {
        all = all.map { if (it.id == id && it.account == account) new(it) else it }
        showItem()
        if (write) persist()
    }

    /** New items into the queue; what is already there is not added again. Images load too. */
    fun insert(newOne: List<DownloadItem>, images: Map<String, String>) {
        val freshValue = newOne.filter { n -> all.none { it.id == n.id && it.account == n.account } }
        if (freshValue.isEmpty()) return
        all = all + freshValue
        showItem(); persist()
        run.launch(Dispatchers.IO) { images.forEach { (identifier, address) -> imageSafe(imageFile(identifier), address) } }
        tick()
    }

    /** Does not load what is already there; only a fully loaded file is moved into place. */
    private fun imageSafe(target: File, address: String): Boolean {
        if (target.exists()) return true
        return runCatching {
            val v = URL(address).openConnection() as HttpURLConnection
            v.connectTimeout = 15000; v.readTimeout = 30000
            ownHeadersFields(address).forEach { (name, value) -> v.setRequestProperty(name, value) }
            val new = File(target.path + ".neu")
            val went = v.responseCode in 200..299 && v.inputStream.use { on -> new.outputStream().use { on.copyTo(it) } } > 0
            v.disconnect()
            went && new.renameTo(target)
        }.getOrDefault(false)
    }

    /** Under this key the series page passes the large header image into `insert`. */
    fun headerId(seriesIdentifier: String) = "$seriesIdentifier-kopf"

    /**
     * **The series' header image at screen resolution** (mirrors `DownloadManager.headerImage`).
     * Poster and landscape images are sized for rows and looked stretched and soft in the header.
     */
    fun headerImage(seriesIdentifier: String): File? = imageFile(headerId(seriesIdentifier)).takeIf { it.exists() }

    /** For earlier downloads that lack it: fetched on the next open with network. */
    suspend fun headerImageCatchUp(seriesIdentifier: String, address: String): File? = withContext(Dispatchers.IO) {
        val target = imageFile(headerId(seriesIdentifier))
        if (imageSafe(target, address)) target else null
    }

    /** `ringTap`: one ring, one rule. Loaded items are removed only via the list. */
    fun paintTap(p: DownloadItem?, create: () -> Unit) {
        when (p?.state) {
            null -> create()
            "laedt" -> halt(p.id)
            "angehalten", "fehler", "wartet" -> resume(p.id)
        }
    }

    fun halt(id: String) {
        if (ongoing == id) { task?.cancel(); task = null; ongoing = null }
        // Pause takes effect immediately; the estimator does not keep counting over the pause.
        Kern.downloadEstimatorHalt(id)
        val p = all.firstOrNull { it.id == id } ?: return
        change(id) { it.copy(state = "angehalten", loaded = part(p).length(), reason = null) }
        tick()
    }

    fun resume(id: String) {
        change(id) { if (it.state == "fertig" || it.state == "laedt") it else it.copy(state = "wartet", reason = null) }
        tick()
    }

    /** Running ones cancel, file and own image go; the series poster only with the last episode. */
    fun remove(ids: Collection<String>) {
        val distance = all.filter { it.account == account && it.id in ids }
        if (ongoing in ids) { task?.cancel(); task = null; ongoing = null }
        all = all - distance.toSet()
        distance.forEach { p ->
            File(folder, p.fileName).delete(); part(p).delete(); imageFile(p.id).delete()
            Kern.downloadEstimatorForget(p.id)
            val sid = p.seriesIdentifier
            if (sid != null && all.none { it.account == account && it.seriesIdentifier == sid }) {
                imageFile(sid).delete(); imageFile(headerId(sid)).delete()
            }
        }
        showItem(); persist()
        tick()
    }

    fun allRemove() = remove(entries.value.map { it.id })

    /** The only place that starts. If Wi-Fi is missing and "Wi-Fi only" applies, the running one stops and waits. */
    fun tick() {
        val onlyWLAN = app.settings.onlyOverWLAN
        val may = Kern.downloadMayLoad(wLAN, onlyWLAN)
        ongoing?.let { id ->
            if (!may) {
                task?.cancel(); task = null; ongoing = null
                val p = all.firstOrNull { it.id == id }
                Kern.downloadEstimatorHalt(id)
                if (p != null) change(id) { it.copy(state = "wartet", loaded = part(p).length()) }
            }
        }
        if (ongoing == null && account.isNotEmpty()) {
            val id = Kern.downloadNext(DownloadItem.list(entries.value), wLAN, onlyWLAN)
            entries.value.firstOrNull { it.id == id }?.let { start(it) }
        }
        if (ongoing == null) DownloadService.from(app)
    }

    private fun start(p: DownloadItem) {
        ongoing = p.id
        change(p.id) { it.copy(state = "laedt", reason = null) }
        DownloadService.an(app, p.title, p.share)
        task = run.launch {
            val result = withContext(Dispatchers.IO) { runCatching { load(p) } }
            // Cancelled does not arrive here: whoever cancels sets the state itself.
            ongoing = null; task = null
            val error = result.exceptionOrNull()
            if (error == null) Kern.downloadEstimatorForget(p.id) else Kern.downloadEstimatorHalt(p.id)
            when {
                // Once transcoded, the estimate gives way to the real size.
                error == null -> {
                    change(p.id) {
                        val real = result.getOrDefault(it.bytes)
                        it.copy(state = "fertig", loaded = real, bytes = if (it.converted) real else it.bytes, reason = null)
                    }
                    sectionsFetch(p.id)
                }
                // Without network and with a partial file: paused, no error text, it continues there.
                error is IOException && error !is LoadError && part(p).length() > 0 ->
                    change(p.id) { it.copy(state = "angehalten", loaded = part(p).length()) }
                else -> change(p.id) { it.copy(state = "fehler", reason = if (error is LoadError) error.message else errorString(app, error), loaded = part(p).length()) }
            }
            tick()
        }
    }

    private suspend fun load(p: DownloadItem): Long {
        val address = app.kern.downloadAddress(p.id, p.source.orEmpty(), p.quality ?: "original").await()
        val part = part(p)
        val already = if (part.exists()) part.length() else 0L
        val v = URL(address).openConnection() as HttpURLConnection
        v.connectTimeout = 15000; v.readTimeout = 30000
        // With the server's own headers; without an entry, the same request as before.
        ownHeadersFields(address).forEach { (name, value) -> v.setRequestProperty(name, value) }
        // A transcoded file accepts no range requests (`Accept-Ranges: none`) and restarts; the server
        // then answers 200 and the `.part` file is overwritten below.
        if (already > 0 && !p.converted) v.setRequestProperty("Range", "bytes=$already-")
        try {
            val code = v.responseCode
            // An error page is not a finished file.
            if (code !in 200..299) throw LoadError(Kern.downloadErrorText(code.toLong()))
            val append = code == 206
            var loaded = if (append) already else 0L
            val total = if (p.bytes > 0) p.bytes else v.contentLengthLong.takeIf { it > 0 }?.plus(loaded) ?: 0L
            // **At most once per second** (`DownloadRules.progressShow`). Half a percent alone let
            // five or more numbers per second through on a fast line, so the subtitle jittered instead of
            // counting. In between the estimator keeps counting.
            var reported = -1L
            var reportedTime = 0L
            v.inputStream.use { on ->
                FileOutputStream(part, append).use { from ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        coroutineContext.ensureActive()
                        val n = on.read(buffer)
                        if (n < 0) break
                        from.write(buffer, 0, n)
                        loaded += n
                        val now = SystemClock.elapsedRealtime()
                        if (Kern.downloadProgressShow(loaded, total, reported,
                                                           if (reported < 0) -1.0 else (now - reportedTime) / 1000.0)) {
                            reported = loaded
                            reportedTime = now
                            val state = loaded
                            withContext(Dispatchers.Main) { progress(p, state, total) }
                        }
                    }
                }
            }
            coroutineContext.ensureActive()
            if (!part.renameTo(File(folder, p.fileName))) throw LoadError(translated("Die Datei liess sich nicht ablegen."))
            return loaded
        } finally { v.disconnect() }
    }

    private fun progress(p: DownloadItem, loaded: Long, total: Long) {
        if (ongoing != p.id) return
        Kern.downloadEstimatorReport(p.id, loaded, if (total > 0) total else p.bytes)
        change(p.id, write = false) { it.copy(loaded = loaded) }
        val now = SystemClock.elapsedRealtime()
        if (now - reportedAround > 1500) { reportedAround = now; DownloadService.report(app, p.title, entries(p.id)?.share) }
    }

    /**
     * **Fetch intro and outro segments** once the file is there (mirrors `sectionsFetch` in
     * `DownloadManager.swift`). Without a response the field stays empty and `nachziehen` asks
     * again on the next contact.
     */
    private fun sectionsFetch(id: String) {
        run.launch {
            val raw = runCatching { app.kern.downloadSections(id).await() }.getOrDefault("")
            if (raw.isNotEmpty()) change(id) { it.copy(sections = raw) }
        }
    }

    /** What the stops changed in the watch state (`Kern.stoppsProcess`), with and without network. */
    fun watchStateAdopt(new: List<DownloadItem>) {
        if (new.isEmpty()) return
        val card = new.associateBy { it.id }
        all = all.map { p -> if (p.account != account) p else card[p.id]?.let { p.withWatchState(it) } ?: p }
        showItem(); persist()
    }

    /** The current account's items as JSON, for the core. */
    fun listJson(): String = DownloadItem.list(entries.value)

    /** Watch state and "still on the server": after every connect, only with a response. */
    suspend fun follow() {
        val ownOnes = entries.value
        if (ownOnes.isEmpty()) return
        val new = runCatching {
            JSONArray(app.kern.downloadsCatchUp(DownloadItem.list(ownOnes)).await())
                .let { a -> (0 until a.length()).map { DownloadItem.read(a.getJSONObject(it)) } }
        }.getOrNull() ?: return
        val card = new.associateBy { it.id }
        all = all.map { p ->
            if (p.account != account) p
            else card[p.id]?.let { p.withWatchState(it).copy(stillOnTheServer = it.stillOnTheServer) } ?: p
        }
        showItem(); persist()
        // For everything downloaded before these fields existed or that got no response while loading.
        entries.value.filter { it.state == "fertig" && it.sections == null }.forEach { sectionsFetch(it.id) }
    }
}

/**
 * **Keeps the download alive** while the app is in the background; counterpart of the `URLSession`
 * background session. The download itself runs in `DownloadManager`.
 */
class DownloadService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = postDirection(this, intent?.getStringExtra("titel").orEmpty(), intent?.getDoubleExtra("anteil", -1.0) ?: -1.0)
        // **Can throw** (Android 14+): once the `dataSync` budget is used up, the system refuses; uncaught,
        // the app crashed. The download itself keeps running without the service.
        val front = runCatching {
            if (Build.VERSION.SDK_INT >= 29) startForeground(NUMBER, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else startForeground(NUMBER, n)
        }.onFailure { AppLog.writeOut("[Dienst] Download nicht im Vordergrund: ${it.javaClass.simpleName}") }.isSuccess
        if (opened > 0) opened--
        // `aus()` came before this call: only now, after `startForeground`, may the service end.
        // With `startId`: if another start is pending, the service stays for its `startForeground`.
        if (!running || !front) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(startId) }
        return START_NOT_STICKY
    }

    /**
     * **Android 15: `dataSync` may run in the foreground for six hours a day at most.** After that the
     * system calls here and kills the app if the service does not end within seconds
     * (`ForegroundServiceDidNotStopInTimeException`); reachable with a long season overnight. The
     * service ends; the download continues as long as Android lets the app live, and otherwise waits
     * for the next start (`read()`).
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        AppLog.writeOut("[Dienst] Download-Frist abgelaufen, Dienst endet")
        running = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    companion object {
        private const val Channel = "downloads"
        private const val NUMBER = 2
        private var running = false
        /**
         * Started services whose `onStartCommand` is still pending. Every `startForegroundService` needs
         * its own `startForeground`, also on an already running service (next queued download).
         */
        private var opened = 0

        private fun postDirection(k: Context, title: String, share: Double): Notification {
            val handler = k.getSystemService(NotificationManager::class.java)
            if (handler.getNotificationChannel(Channel) == null) {
                handler.createNotificationChannel(NotificationChannel(Channel, "Downloads", NotificationManager.IMPORTANCE_LOW))
            }
            val open = PendingIntent.getActivity(k, 1, Intent(k, MainActivity::class.java),
                                                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            return Notification.Builder(k, Channel)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(title)
                .setProgress(1000, (share.coerceAtLeast(0.0) * 1000).toInt(), share < 0)
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
        }

        fun an(k: Context, title: String, share: Double?) {
            // A foreground service may not always start from the background; the download then runs anyway.
            runCatching {
                k.startForegroundService(Intent(k, DownloadService::class.java)
                    .putExtra("titel", title).putExtra("anteil", share ?: -1.0))
                running = true
                opened++
            }.onFailure { AppLog.writeOut("[Dienst] Download-Dienst nicht gestartet: ${it.javaClass.simpleName}") }
        }

        fun report(k: Context, title: String, share: Double?) {
            if (!running) return
            // Without notification permission (denied, Android 13+) the download continues silently.
            if (android.os.Build.VERSION.SDK_INT >= 33 && androidx.core.content.ContextCompat.checkSelfPermission(k,
                    android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
            runCatching { k.getSystemService(NotificationManager::class.java).notify(NUMBER, postDirection(k, title, share ?: -1.0)) }
        }

        fun from(k: Context) {
            if (!running) return
            running = false
            // If it ends before `startForeground`, Android kills the app
            // (ForegroundServiceDidNotStartInTimeException); so the service ends in `onStartCommand`.
            if (opened == 0) runCatching { k.stopService(Intent(k, DownloadService::class.java)) }
        }
    }
}

/**
 * A piece of a file name from server data, never a path out of the folder; same rule as `PathPart`
 * in the package (tested there). Real values (GUIDs, `mkv`, `mov,mp4,m4a`) stay unchanged.
 */
internal object PathPart {
    private val linkPiece = Regex("[a-z0-9]{1,8}")

    /** Letters, digits, `-` and `_` stay, everything else becomes `_`; empty becomes `_`. */
    fun safe(part: String): String = buildString {
        for (z in part) append(if (z in 'a'..'z' || z in 'A'..'Z' || z in '0'..'9' || z == '-' || z == '_') z else '_')
    }.ifEmpty { "_" }

    /** The extension: each part `[a-z0-9]{1,8}`, otherwise `null` (then no extension). */
    fun suffix(container: String?): String? {
        val c = container?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        return c.takeIf { t -> t.split(',').all { linkPiece.matches(it) } }
    }
}
