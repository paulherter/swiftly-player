package de.paulherter.swiftly

import android.app.Application
import android.content.Context
import android.os.Build
import de.paulherter.swiftly.shared.Texts
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.first
import coil3.request.crossfade
import kotlinx.coroutines.future.await
import org.swift.swiftkit.core.SwiftArena
import java.io.File
import java.util.Locale
import java.util.UUID

/**
 * **What the app needs once at startup:** strings, the package translations, and the core.
 * The core lives as long as the app, like `AppModel` on Apple.
 */
class SwiftlyApplication : Application(), coil3.SingletonImageLoader.Factory {
    lateinit var kern: Kern
        private set
    lateinit var store: Store
        private set
    lateinit var settings: Settings
        private set
    /** "Support Swiftly": records, the package's decision, and this build's way to say thanks. */
    lateinit var support: de.paulherter.swiftly.support.Support
        private set

    /** The looks (phone and tablet only; never started on TV). */
    lateinit var looks: de.paulherter.swiftly.support.Looks
        private set

    /** Counts sign-outs; the activity then returns to server selection. */
    val signedOut = androidx.compose.runtime.mutableIntStateOf(0)
    /** Counts account switches (`AppModel.accountSwitch`); the main view rebuilds. */
    val accountSwitch = androidx.compose.runtime.mutableIntStateOf(0)
    private val run = kotlinx.coroutines.MainScope()
    /** For actions that outlive their view, e.g. a tile menu that closes before the server answers. */
    val applicationRun: kotlinx.coroutines.CoroutineScope get() = run

    /**
     * **The most recently loaded home rows.** Compose tears a page down on section change; without
     * this state the home page was empty for a second on return. iOS keeps the same state in `MainView`.
     */
    var startRails: List<Rail>? = null
    /** When the home page was last loaded, for the refresh on return. */
    var startLoaded = 0L

    /** One state per kind, like the models in `MainView` that survive section changes. */
    val libraries = mutableMapOf<String, LibraryState>()

    /** The last state per title; returning from a deeper page would otherwise rebuild from scratch. */
    val titleCache = mutableMapOf<String, Title>()

    /**
     * **Counterpart to `SeriesCache`.** Only so the way back is not empty, not a source of truth
     * for watch state: the page always reloads over it. Keyed by target (series or episode);
     * episodes hang off the season.
     */
    val seriesCache = mutableMapOf<String, Series>()
    val episodesCache = mutableMapOf<String, List<Episode>>()
    val peopleCache = mutableMapOf<String, PeopleState>()

    /** The open selection sheet. It sits above the bar, so the app holds it, not the page. */
    val sheet = androidx.compose.runtime.mutableStateOf<SheetRequest?>(null)

    /** What is currently playing. The player sits above all pages, below the sheet. */
    val play = androidx.compose.runtime.mutableStateOf<PlayRequest?>(null)

    /**
     * Counts finished playbacks, **only once the stop report has gone through** (mirrors
     * `AppModel.playbackEnded`). Reloading on close asks before the server knows the position and
     * gets the state of the last tick. Pages with progress hang off this.
     */
    val playbackEnded = androidx.compose.runtime.mutableIntStateOf(0)
    /** Counts watch-state changes made from a tile menu (`AppModel.watchStateChanged`); pages refresh. */
    val watchStateChanged = androidx.compose.runtime.mutableIntStateOf(0)
    /** A short message above everything, as reported by a tile menu (`TileRequest.meldung`). */
    val message = androidx.compose.runtime.mutableStateOf<String?>(null)

    /**
     * Which request was already handed to `PlayerActivity`. **Not Compose state and not bound to an
     * activity:** if the main activity is rebuilt (rotation) while the player runs, its
     * `LaunchedEffect(play)` ran again and started the same episode a second time, visible only on
     * close because the old player clears `play` only then.
     */
    @Volatile var playHandOver: PlayRequest? = null

    /**
     * **Title and position currently playing**, advanced by the tick. `PlayerActivity` stores them
     * in its saved state: if Android kills the process in the background, playback resumes on return
     * instead of silently falling back to the home page.
     */
    @Volatile var playPoint: PlayRequest? = null

    /** After a title is finished the rating prompt is due; the main activity asks and resets it. */
    val ratingDue = androidx.compose.runtime.mutableStateOf(false)

    /** Same for the one-time community hint (`Community` in the package). */
    val discordHintDue = androidx.compose.runtime.mutableStateOf(false)

    /** The URLs from the package; they are typed only there. */
    fun communityAddress(art: String): String = Kern.communityAddress(art, VersionRow + " · libVLC 3.6.3",
        (if (isTv) "Android TV " else "Android ") + android.os.Build.VERSION.RELEASE)

    /** Opens a URL in the browser. Does nothing on a TV without a browser, where the URL is shown to type in. */
    fun addressOpen(context: android.content.Context, address: String) {
        runCatching {
            context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(address))
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    /**
     * Mirrors `AppModel.doneWatch`. **The rule lives in the package** (`Community.kickoff`):
     * a title counts from 90 % watched and over one minute; the third asks for a rating (once per
     * version), the fifth points to the community once, never both together.
     * Same keys as `UserDefaults` on iOS. TV never asks for a rating: there is no prompt, as on tvOS.
     */
    fun doneWatch(position: Double, duration: Double) {
        if (!Kern.ratingCounts(position, duration)) return
        val done = (store.rememberValue("bewertungFertig")?.toIntOrNull() ?: 0) + 1
        store.remember("bewertungFertig", done.toString())
        when (Kern.communityTrigger(done.toLong(), store.rememberValue("bewertungFassung").orEmpty(), BuildConfigVersion,
                                       store.rememberValue("discordHinweisGezeigt") == "1", !isTv)) {
            "bewertung" -> {
                store.remember("bewertungFassung", BuildConfigVersion)
                ratingDue.value = true
            }
            "discord" -> {
                // Mark as shown right away: better never than twice.
                store.remember("discordHinweisGezeigt", "1")
                discordHintDue.value = true
            }
        }
    }

    /** Is the player in the small window? Then the app shows where the film is underneath. */
    val smallWindow = androidx.compose.runtime.mutableStateOf(false)

    /** "Continue here": what is playing on another device of the same account. */
    val offerings = androidx.compose.runtime.mutableStateOf<List<Offering>>(emptyList())
    /** "Where to continue?" is open; the card grows out of the badge (`TakeoverStatus`). */
    val takeoverSelection = androidx.compose.runtime.mutableStateOf<TakeoverSelection?>(null)

    /** "Watch together": mirror of the state from the core (`Shared.kt`). */
    val gemeinsam = androidx.compose.runtime.mutableStateOf(SharedStatus())
    /** A group message (`SyncPlayError.text`); the main view or player shows it as a hint and clears it. */
    val sharedError = androidx.compose.runtime.mutableStateOf<String?>(null)

    /**
     * TV: the URL from a tap on a Watch Next entry (`TvActivity`, `TvContinueWatchingShelf`). `TvMain`
     * reads it, opens the title and resets it to `null`. The same "swiftly://titel/<id>" URL tvOS Top
     * Shelf uses (`ShelfProvider.swift`), but without `onOpenURL`: Android delivers it via the intent.
     */
    val deepLink = androidx.compose.runtime.mutableStateOf<android.net.Uri?>(null)

    /** Token of the player's media session; the playback service attaches its notification to it. */
    var mediaToken: android.media.session.MediaSession.Token? = null

    /** Term, results and search state; they survive section changes as on iOS. */
    val search = SearchState()

    /** Is Seerr connected? If not, nothing of it is visible anywhere. */
    val seerrConnected = androidx.compose.runtime.mutableStateOf(false)
    /** Results whose detail page is open; the page needs status, year and image up front. */
    val seerrHit = mutableMapOf<String, SeerrTile>()

    /** One access per Jellyfin server, so Seerr survives a switch to another server. */
    private fun seerrKey(): String = "seerr|" + store.accounts?.let { Kern.bundleActive(it) }?.let {
        runCatching { org.json.JSONObject(it).optString("serverURL") }.getOrNull()
    }.orEmpty().lowercase().trimEnd('/')

    fun seerrLoad() {
        val access = store.vaultRead(seerrKey())
        if (access != null) kern.seerrSet(access) else kern.seerrDisconnect()
        seerrConnected.value = access != null
    }
    fun seerrRemember(access: String) { store.vaultWrite(seerrKey(), access); seerrConnected.value = true }
    fun seerrDisconnect() { store.vaultWrite(seerrKey(), null); kern.seerrDisconnect(); seerrConnected.value = false }
    fun seerrAddress(): String? = store.vaultRead(seerrKey())?.let {
        runCatching { org.json.JSONObject(it).optString("adresse") }.getOrNull()
    }

    /**
     * Is the app running on a TV? Then TV UI and no downloads, as on tvOS.
     * Three signals, any one suffices: Leanback, the system's television mode, and Amazon's Fire TV
     * feature. Not every Fire OS reports Leanback reliably.
     */
    val isTv: Boolean by lazy {
        packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_LEANBACK) ||
            packageManager.hasSystemFeature("amazon.hardware.fire_tv") ||
            getSystemService(android.app.UiModeManager::class.java)?.currentModeType ==
                android.content.res.Configuration.UI_MODE_TYPE_TELEVISION
    }

    /** Downloads; the list lives as long as the app, like `DownloadManager` on iOS. */
    val downloads by lazy { DownloadManager(this) }

    /** The `userID` of the current account; downloads and pending reports hang off it. */
    fun accountId(): String = store.accounts?.let { Kern.bundleActive(it) }?.let {
        runCatching { org.json.JSONObject(it).optString("userID") }.getOrNull()
    }.orEmpty()

    /** Report the end of playback; if that fails, the position is stored and reported later. */
    fun playbackEnd(position: Double) {
        run.launch {
            val message = runCatching {
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { kern.playbackEnd(position).await() }
            }.getOrDefault("")
            toStop(message)
            support.watchSave(force = true)
            logWrite()
            // Remembered titles, series and episodes carry the state from before watching: opening a series
            // afterwards would otherwise show yesterday's ticks and bars (`SeriesCache.forget` in
            // `reportStopped`).
            titleCache.clear(); seriesCache.clear(); episodesCache.clear()
            playbackEnded.intValue += 1
        }
    }

    /** Store a pending report from the core, on close and on episode change. */
    fun pendingReportStore(message: String) {
        store.remember(PendingReports, Kern.pendingReportRecord(store.rememberValue(PendingReports) ?: "[]", message))
    }

    /**
     * **After every stop:** close, episode change, quality change. `meldung` is the pending report
     * from the core, empty if the stop arrived. Then what the core makes of it (mirrors
     * `AppModel.reportStopped`): the download's watch state, with and without network, and an
     * arrived report clears the pending one for the same title.
     */
    fun toStop(message: String?) {
        if (!message.isNullOrEmpty()) pendingReportStore(message)
        val o = runCatching {
            org.json.JSONObject(kern.stoppsProcess(store.rememberValue(PendingReports) ?: "[]", downloads.listJson()))
        }.getOrNull() ?: return
        store.remember(PendingReports, o.getString("ablage"))
        val a = o.getJSONArray("posten")
        downloads.watchStateAdopt((0 until a.length()).map { DownloadItem.read(a.getJSONObject(it)) })
    }

    /** The core's log lines (start, stopped, switch) go to logcat under "Swiftly". */
    fun logWrite() {
        kern.logFetch().takeIf { it.isNotEmpty() }?.lines()?.forEach { AppLog.writeOut("[Melden] $it") }
    }

    /**
     * **After a successful connection**, the only point where the server is demonstrably reachable:
     * send what was left over, then catch up watched state and "still on the server" for downloads.
     */
    suspend fun postConnect() {
        if (serverName.value == null) return
        // **Report first, then read**, or the server list returns the state from before the flight.
        val raw = store.rememberValue(PendingReports) ?: "[]"
        if (raw != "[]") runCatching { kern.pendingSubmit(raw).await() }.getOrNull()?.let { completed ->
            // From the store as it is now; a new one may have arrived while waiting.
            store.remember(PendingReports, Kern.pendingDone(store.rememberValue(PendingReports) ?: "[]", completed))
        }
        logWrite()
        downloads.follow()
    }

    /**
     * Fetch posts from the core, then the loading sheet; what is already there drops out first.
     * `abwarten`: if the call comes from a sheet that is sliding down, the loading sheet waits for it.
     * **One sheet at a time**; two at once would be two cards crossing.
     */
    /**
     * **Ask for notifications only at the first download**, the usual moment: then the user knows
     * why. Not asked at startup. `MainActivity` registers the call here (only it can ask) and removes
     * it on exit. **Once:** if the user declines, downloads still run, just without notification, and
     * the app does not ask again.
     */
    @Volatile var messageRightAsk: (() -> Unit)? = null

    private fun messageRightInTimesAsk() {
        if (Build.VERSION.SDK_INT < 33) return
        if (androidx.core.content.ContextCompat.checkSelfPermission(this, android.Manifest.permission.POST_NOTIFICATIONS)
            == android.content.pm.PackageManager.PERMISSION_GRANTED) return
        if (store.rememberValue(MESSAGE_RIGHT_ASKED) == "1") return
        val ask = messageRightAsk ?: return
        store.remember(MESSAGE_RIGHT_ASKED, "1")
        ask()
    }

    fun downloadsCreate(ids: List<String>, title: String, waitFor: Long = 0, quality: String = "original") {
        messageRightInTimesAsk()
        val beginning = android.os.SystemClock.uptimeMillis()
        run.launch {
            val raw = runCatching { kern.downloadItem(ids.toTypedArray()).await() }.getOrNull() ?: return@launch
            val a = org.json.JSONArray(raw)
            val newOne = mutableListOf<DownloadItem>()
            val images = mutableMapOf<String, String>()
            for (i in 0 until a.length()) {
                val o = a.getJSONObject(i)
                // The quality comes with the load selection: Matroska and estimated size.
                val raw1 = o.getJSONObject("posten")
                val p = if (quality == "original") DownloadItem.read(raw1)
                        else DownloadItem.read(org.json.JSONArray(Kern.downloadInQuality("[$raw1]", quality)).getJSONObject(0))
                if (downloads.entries(p.id) != null) continue
                newOne += p
                o.fieldText("bild")?.let { images[p.id] = it }
                p.seriesIdentifier?.let { sid -> o.fieldText("serienbild")?.let { images[sid] = it } }
            }
            // **The large series header image** goes along, once per series, for the series page in
            // Downloads. At screen width, at least as wide as a 16:9 image needs for the 300 high header
            // area (mirrors `SeriesView.loadImages`).
            for (sid in newOne.mapNotNull { it.seriesIdentifier }.distinct()) {
                if (downloads.headerImage(sid) != null) continue
                val address = runCatching { kern.downloadHeaderImage(sid, headerImageWidth()).await() }.getOrNull()
                if (!address.isNullOrEmpty()) images[downloads.headerId(sid)] = address
            }
            val rest = waitFor - (android.os.SystemClock.uptimeMillis() - beginning)
            if (rest > 0) kotlinx.coroutines.delay(rest)
            // A single film gets its choice in the loading sheet; a series brings it from the selection.
            if (newOne.isNotEmpty()) loadSheetShow(this@SwiftlyApplication, newOne, images, title,
                                                   qualitySelect = quality == "original" && newOne.size == 1 && newOne[0].art == "film")
        }
    }

    /** Header image width in pixels: page width, at least `heroHeightValue` × 16 / 9. */
    fun headerImageWidth(): Long {
        val m = resources.displayMetrics
        return maxOf(m.widthPixels.toFloat(), 300f * 16f / 9f * m.density).toLong()
    }

    /** Kind, sort order and the loaded titles of the watchlist. */
    val watchlist by lazy { WatchlistState(store) }

    /**
     * **The server name, once for all pages**, like `AppModel.serverName`. `null` means "not asked
     * yet", empty means "the server reports none".
     * It used to be held per library and arrived after the placeholders, so the header grew by a
     * line and the whole grid shifted down.
     */
    val serverName = androidx.compose.runtime.mutableStateOf<String?>(null)

    suspend fun serverNameLoad() {
        if (serverName.value != null) return
        try {
            serverName.value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                kern.serverName().await()
            }
        } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) {}
    }

    /**
     * Images fade in on first load (`Picture` on iOS, `Theme.einblenden`). What is already in memory
     * appears immediately: Coil does not fade memory hits.
     */
    override fun newImageLoader(context: coil3.PlatformContext): coil3.ImageLoader =
        coil3.ImageLoader.Builder(context).crossfade(280)
            // Custom server headers on every image request; without entries the request is unchanged.
            .components {
                add(coil3.network.okhttp.OkHttpNetworkFetcherFactory(callFactory = {
                    okhttp3.OkHttpClient.Builder().addInterceptor(OwnHeadersCatch).build()
                }))
            }
            .build()

    // MARK: Custom headers (mirrors `LoginModel.swift`)

    /** The current account's base URL, or `null` when signed out. */
    fun activeServer(): String? = store.accounts?.let { Kern.bundleActive(it) }?.let {
        runCatching { org.json.JSONObject(it).optString("serverURL") }.getOrNull()
    }?.takeIf { it.isNotEmpty() }

    /** What is entered for a server, for "Advanced". JSON `[{"name","wert"}]`. */
    fun ownHeaders(server: String?): String = server?.let { Kern.ownHeadersRegistered(it) } ?: "[]"

    /**
     * The whole table goes into the vault, **not into settings**: the values are credentials like
     * the device identifier itself. After every successful connection with headers and after "Save".
     */
    fun storeOwnHeaders() {
        val panel = Kern.ownHeadersStore()
        store.vaultWrite(OwnHeaders, if (panel == "{}") null else panel)
    }

    /** Set and store. An empty list removes the server. Only the names go to the log. */
    fun ownHeadersSafe(headers: String, server: String) {
        Kern.ownHeadersSet(server, headers)
        storeOwnHeaders()
        AppLog.writeOut("Eigene Header gesichert: " + Kern.ownHeadersNames(server))
    }

    override fun onCreate() {
        super.onCreate()
        store = Store(this)
        settings = Settings(store)
        settings.serverKey = { activeServer().orEmpty().lowercase().trimEnd('/') }
        Texts.load(this)
        // Before the core's first request: custom certificate authorities for URLSession and VLC too.
        Certificates.readySet(this)
        Certificates.observe(this)
        // **Before the session.** Behind a gateway even the first request needs the custom headers.
        Kern.ownHeadersLoad(store.vaultRead(OwnHeaders).orEmpty())
        val language = if (Locale.getDefault().language == "de") "de" else "en"
        // Before the first package string, or the keys show instead.
        Kern.packageLanguageSet(packageLanguageUnpack().absolutePath, language)
        // "Android" in the program name lets other devices recognise a phone (or the TV).
        kern = Kern.init(store.devicesIdentifier(), Build.MODEL ?: "Android", BuildConfigVersion,
                         if (isTv) "Swiftly Player Android TV" else "Swiftly Player Android", SwiftArena.ofAuto())
        qualityReport()
        sharedListen(run)
        support = de.paulherter.swiftly.support.Support(this)
        support.start()
        looks = de.paulherter.swiftly.support.Looks(this)
        looks.start()
        // The system icon follows what is worn; a look that was ended by a refund goes back (no-op on TV).
        looks.applyIcon()
        // Watched time goes to storage at most once a minute (`WatchTimeCounter.needsSave`), and in
        // full at the end of playback (`playbackEnd`).
        run.launch { while (true) { kotlinx.coroutines.delay(60_000); support.watchSave(force = false) } }
    }

    /** Direct Play and bitrate to the facade, at startup and on every change. */
    fun qualityReport() = kern.playbackSelection(settings.alwaysDirectPlay, settings.bitratesLimit.toLong())


    /**
     * Restores the current account. **Migration:** a single old-format session becomes a bundle at
     * the first start, so nobody has to sign in again.
     */
    fun sessionAgainFromSet(): Boolean {
        if (store.accounts == null) {
            store.session?.let { alt -> Kern.bundleFromSession(alt).takeIf { it.isNotEmpty() }?.let { store.accounts = it } }
        }
        val bundle = store.accounts ?: return false
        val active = Kern.bundleActive(bundle).takeIf { it.isNotEmpty() } ?: return false
        return try { kern.sessionSet(active); true } catch (e: Exception) { false }
    }

    /**
     * A sentence for server selection after a revoked login was signed out. The page shows it as an
     * error and clears it.
     */
    val loginHint = androidx.compose.runtime.mutableStateOf<String?>(null)
    private var sessionChecked = false

    /**
     * Mirrors `AppModel` after restore. **If the device is no longer valid** (removed in the
     * dashboard, password changed), sign out: if an account remains, the next one becomes current,
     * otherwise go to server selection. Otherwise the app opened on an empty home page with an
     * error, reachable only via Profile → Sign out. Runs in `run`, not in the main view, which
     * tears down on sign-out and would cancel the check midway.
     */
    fun sessionCheck() {
        // Once per start, as on Apple; not on every rotation that rebuilds the main view.
        if (sessionChecked) return
        sessionChecked = true
        accountPreGiftFetch()
        run.launch {
            val applies = runCatching {
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { kern.sessionApplies().await() }
            }.getOrDefault(true)
            if (applies) return@launch
            val name = username()
            val rest = store.accounts?.let { Kern.bundleRemoved(it, Kern.bundleActiveId(it)) }.orEmpty()
            val proceed = rest.takeIf { it.isNotEmpty() }?.let { Kern.bundleActive(it) }
                ?.let { runCatching { org.json.JSONObject(it).optString("userName") }.getOrNull() }
            val sentence = if (proceed.isNullOrEmpty()) de.paulherter.swiftly.shared.translated("Die Anmeldung gilt nicht mehr. Bitte neu anmelden.")
                       else de.paulherter.swiftly.shared.translated("Die Anmeldung von %@ gilt nicht mehr. Jetzt angemeldet als %@.", name, proceed)
            AppLog.writeOut("Anmeldung widerrufen, abgemeldet (weiteres Konto: ${!proceed.isNullOrEmpty()})")
            if (proceed.isNullOrEmpty()) loginHint.value = sentence
            else android.widget.Toast.makeText(this@SwiftlyApplication, sentence, android.widget.Toast.LENGTH_LONG).show()
            signOutNow()
        }
    }

    /**
     * What the current account dictates: `EnableNextEpisodeAutoPlay` and the download right
     * `EnableContentDownloading`. Anyone who never toggled "Next episode automatically" follows the
     * server, like `AppModel` on iOS; without the right the download buttons disappear. **One
     * request for both**, in the background and without error message: if nothing comes back, the
     * own choice stays and the right stays "unknown", i.e. allowed.
     */
    fun accountPreGiftFetch() {
        settings.nextAutomaticAccount = ""
        settings.downloadRightAccount = ""
        settings.convertAllowedAccount = ""
        settings.downloadQualityAccount = ""
        run.launch {
            val parts = runCatching {
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { kern.accountDefaults().await() }
            }.getOrDefault("||").split("|")
            settings.nextAutomaticAccount = parts.getOrElse(0) { "" }
            settings.downloadRightAccount = parts.getOrElse(1) { "" }
            settings.convertAllowedAccount = parts.getOrElse(2) { "" }
            settings.downloadQualityAccount = parts.getOrElse(3) { "" }
        }
    }

    /** The current account's name, for the profile badge. */
    fun username(): String = store.accounts?.let { Kern.bundleActive(it) }?.let {
        runCatching { org.json.JSONObject(it).optString("userName") }.getOrNull()
    }.orEmpty().ifEmpty { "?" }

    /**
     * **Who did not answer**, mirrors `AppModel.serverAddress`. The server's host name, else
     * "The server".
     * This is the real gain in the failure state: it shows at a glance whether the server is down
     * or you are on the wrong network.
     */
    fun serverAddress(): String =
        store.lastServer?.let { runCatching { java.net.URI(it).host }.getOrNull() }
            ?.takeIf { it.isNotEmpty() } ?: de.paulherter.swiftly.shared.translated("Der Server")

    /** Takes a fresh session; if accounts already existed, this is a switch. */
    fun sessionRecord(session: String) {
        val before = store.accounts
        store.accounts = Kern.bundleRecord(session, before.orEmpty())
        kern.sessionSet(session)
        if (before != null) afterSwitch() else { settings.librariesNewRead(); accountPreGiftFetch() }
    }

    /**
     * **An open player ends before account switch and sign-out**, also in the small window. The core
     * is one per process: if the tick kept running, progress and stop would go out with the new
     * account's session. The player observes the counter, still reports the stop with the old
     * account and closes; the wait for that report is capped at 4 s.
     */
    val playerClose = androidx.compose.runtime.mutableIntStateOf(0)

    private suspend fun playbackPreSwitchEnd() {
        if (play.value == null) return
        val before = playbackEnded.intValue
        playerClose.intValue++
        AppLog.writeOut("Kontowechsel: offener Player wird zuerst beendet")
        kotlinx.coroutines.withTimeoutOrNull(4000) {
            androidx.compose.runtime.snapshotFlow { playbackEnded.intValue }.first { it != before }
        }
    }

    /** **A switch does not sign out**; the abandoned account stays valid for the way back. */
    fun switchAccount(identifier: String) {
        if (play.value != null) { run.launch { playbackPreSwitchEnd(); accountSwitchNow(identifier) }; return }
        accountSwitchNow(identifier)
    }

    private fun accountSwitchNow(identifier: String) {
        val bundle = store.accounts ?: return
        if (Kern.bundleActiveId(bundle) == identifier) return
        val new = Kern.bundleSwitch(bundle, identifier)
        store.accounts = new
        kern.sessionSet(Kern.bundleActive(new))
        afterSwitch()
    }

    /**
     * **Sign-out affects only the current account**, without confirmation as on iOS. If others
     * remain, the next becomes current; if it was the last, go back to server selection.
     */
    fun signOff() {
        run.launch { signOutNow() }
    }

    private suspend fun signOutNow() {
        playbackPreSwitchEnd()
        runCatching { kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { kern.signOff().await() } }
        val bundle = store.accounts
        val rest = bundle?.let { Kern.bundleRemoved(it, Kern.bundleActiveId(it)) }.orEmpty()
        if (rest.isEmpty()) {
            store.accounts = null
            store.session = null
            clearIntermediates()
            signedOut.intValue++
        } else {
            store.accounts = rest
            kern.sessionSet(Kern.bundleActive(rest))
            afterSwitch()
        }
    }

    /** What belongs to an account is gone after the switch; `accountSwitch` rebuilds the main view. */
    private fun afterSwitch() {
        clearIntermediates()
        accountPreGiftFetch()
        accountSwitch.intValue++
        run.launch { serverNameLoad() }
    }

    private fun clearIntermediates() {
        // The socket belongs to the previous account; the main view starts it for the new one.
        run.launch { runCatching { kern.remoteControlEnd().await() } }
        startRails = null
        settings.librariesNewRead()
        libraries.clear(); titleCache.clear(); seriesCache.clear(); episodesCache.clear(); peopleCache.clear()
        serverName.value = null
        watchlist.forget()
        search.forget()
        // Mirrors `AppModel.afterSwitch`/sign-out on Apple, `Shelf.leeren()`. Otherwise Watch Next
        // on the TV home screen keeps showing the previous account's films and series, visible to
        // everyone in the room.
        de.paulherter.swiftly.tv.TvContinueWatchingShelf.wipe(this)
    }

    /** Assets cannot give a file path, but `Bundle(path:)` needs one, so extract once. */
    private fun packageLanguageUnpack(): File {
        val target = File(filesDir, "paketsprache")
        target.deleteRecursively()
        copy("paketsprache", target)
        return target
    }

    private fun copy(path: String, target: File) {
        val children = assets.list(path) ?: emptyArray()
        if (children.isEmpty()) {
            target.parentFile?.mkdirs()
            assets.open(path).use { on -> target.outputStream().use { on.copyTo(it) } }
        } else {
            target.mkdirs()
            children.forEach { copy("$path/$it", File(target, it)) }
        }
    }

    companion object {
        /**
         * **Read from the build, not maintained by hand.**
         * The version was hard-coded while `versionName` in `build.gradle.kts` moved on. Settings then
         * showed a wrong version, and the same value was sent to the Jellyfin server as client version.
         * Two places for one number drift apart.
         */
        val BuildConfigVersion: String = BuildConfig.VERSION_NAME
        /** `Version.row` on iOS. */
        val VersionRow: String =
            "Swiftly Player ${BuildConfig.VERSION_NAME} (Build ${BuildConfig.VERSION_CODE})"
        /** Same key as in `UserDefaults` on iOS. */
        const val PendingReports = "nachmeldungen"
        const val MESSAGE_RIGHT_ASKED = "meldungsrechtGefragt"
        /** One entry for all servers: the whole table from `OwnHeaders`, same name as in the keychain. */
        const val OwnHeaders = "eigenkoepfe"
    }
}

/**
 * **Platform storage**, counterpart to Keychain and UserDefaults on Apple.
 * The session format comes from the package; this only stores.
 */
class Store(context: Context) {
    private val prefs = context.getSharedPreferences("swiftly", Context.MODE_PRIVATE)

    /**
     * **Decrypt once, not on every read.** Every access to `accounts` went through the Keystore
     * (user name, account id, Seerr, server): StrictMode counted 13 such reads on the main thread
     * at cold start, each a call into the Keystore service. Writes still encrypt immediately; this
     * holds only what the process already had in plaintext.
     */
    private val clearText = HashMap<String, String?>()

    private fun vaultValue(key: String): String? = synchronized(clearText) {
        if (clearText.containsKey(key)) return clearText[key]
        val value = prefs.getString(key, null)?.let { Vault.decrypt(it) }
        clearText[key] = value
        value
    }

    private fun vaultSet(key: String, value: String?) {
        synchronized(clearText) { clearText[key] = value }
        val editState = prefs.edit()
        if (value == null) editState.remove(key) else editState.putString(key, Vault.encrypt(value))
        editState.apply()
    }

    /**
     * **Encrypted in the Android Keystore**, counterpart to the keychain. An old plaintext session
     * is migrated and deleted on first read; nobody has to sign in again.
     */
    var session: String?
        get() {
            prefs.getString("sitzung", null)?.let { clear -> session = clear; return clear }
            return vaultValue("sitzung.tresor")
        }
        set(value) {
            prefs.edit().remove("sitzung").apply()
            vaultSet("sitzung.tresor", value)
        }

    /** The account bundle (`AccountBundle`), encrypted like the session. */
    var accounts: String?
        get() = vaultValue("konten.tresor")
        set(value) = vaultSet("konten.tresor", value)

    fun vaultRead(key: String): String? = vaultValue("$key.tresor")
    fun vaultWrite(key: String, value: String?) = vaultSet("$key.tresor", value)

    var lastServer: String?
        get() = prefs.getString("letzterServer", null)
        set(value) { prefs.edit().putString("letzterServer", value).apply() }

    /** Sort order, filter, selected library; same keys as in UserDefaults on Apple. */
    fun rememberValue(key: String): String? = prefs.getString(key, null)
    fun remember(key: String, value: String) { prefs.edit().putString(key, value).apply() }

    fun devicesIdentifier(): String = prefs.getString("de.paulherter.swiftly.deviceID", null)
        ?: UUID.randomUUID().toString().also { prefs.edit().putString("de.paulherter.swiftly.deviceID", it).apply() }
}

/**
 * AES-GCM with a key that never leaves the Keystore. If something cannot be decrypted (key gone
 * after a restore), the session counts as absent.
 */
internal object Vault {
    private const val NAME = "de.paulherter.swiftly.sitzung"

    private fun key(): javax.crypto.SecretKey {
        val lager = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (lager.getKey(NAME, null) as? javax.crypto.SecretKey)?.let { return it }
        val creator = javax.crypto.KeyGenerator.getInstance(android.security.keystore.KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        creator.init(android.security.keystore.KeyGenParameterSpec.Builder(NAME,
                android.security.keystore.KeyProperties.PURPOSE_ENCRYPT or android.security.keystore.KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE)
            .build())
        return creator.generateKey()
    }

    fun encrypt(clear: String): String {
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, key())
        val data = cipher.doFinal(clear.toByteArray(Charsets.UTF_8))
        return android.util.Base64.encodeToString(cipher.iv + data, android.util.Base64.NO_WRAP)
    }

    fun decrypt(raw: String): String? = runCatching {
        val everything = android.util.Base64.decode(raw, android.util.Base64.NO_WRAP)
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(javax.crypto.Cipher.DECRYPT_MODE, key(), javax.crypto.spec.GCMParameterSpec(128, everything, 0, 12))
        String(cipher.doFinal(everything, 12, everything.size - 12), Charsets.UTF_8)
    }.getOrNull()
}
