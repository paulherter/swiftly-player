package de.paulherter.swiftly

import de.paulherter.swiftly.rustcore.legacyStopsProcess
import android.content.Context
import de.paulherter.swiftly.shared.Texts
import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.CoreException
import de.paulherter.swiftly.rustcore.LegacyDetail
import de.paulherter.swiftly.rustcore.LegacyPlexDetail
import de.paulherter.swiftly.rustcore.LegacyHoldCounters
import de.paulherter.swiftly.rustcore.LegacyLibrary
import de.paulherter.swiftly.rustcore.LegacyPlayback
import de.paulherter.swiftly.rustcore.LegacyLogin
import de.paulherter.swiftly.rustcore.legacySubtitleFileStyleAdjustable
import de.paulherter.swiftly.rustcore.legacyUserImage
import de.paulherter.swiftly.rustcore.LegacyPlexSignIn
import de.paulherter.swiftly.rustcore.LegacySeerr
import de.paulherter.swiftly.rustcore.NetHeader
import de.paulherter.swiftly.rustcore.ServerKind
import de.paulherter.swiftly.rustcore.host.AndroidDatagramHost
import de.paulherter.swiftly.rustcore.host.AndroidHttpClient
import de.paulherter.swiftly.rustcore.host.AndroidKeyValueStore
import de.paulherter.swiftly.rustcore.host.AndroidLanguageNames
import de.paulherter.swiftly.rustcore.host.AndroidPlatform
import de.paulherter.swiftly.rustcore.host.AndroidSecretStore
import de.paulherter.swiftly.rustcore.host.DownloadIndexStore
import de.paulherter.swiftly.rustcore.host.GcmSealer
import de.paulherter.swiftly.rustcore.host.SettingsSyncAdapter
import de.paulherter.swiftly.rustcore.host.SharedStringPrefs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.future.await
import kotlinx.coroutines.future.future
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CompletableFuture

/**
 * **The Rust core behind the old `Kern` calls.** Same names, same argument types, same JSON answers, so the Compose
 * code only changed the receiver (the old receiver was replaced by `app.rk`). Every moved call is compared with the
 * Swift answer by the golden tests (`Android/golden`, `LegacyXParityTest`).
 *
 * - The account comes from the session JSON the app already hands `Kern.sessionSet` ([sessionSet]); one set of per-account
 *   objects (library state, detail state) is built from it, on first use and off the main thread.
 * - **Plex is on the core for the title pages and the playback; the rest stays on the Swift path until it is compared; so does everything while there is no
 *   session or the Rust library fails to start. Without a core there is no fallback: the call fails loudly (`noCore`).
 * - A failure reads like the Swift one: the readable sentence is the exception's message.
 */
class RustKern(private val app: SwiftlyApplication) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private class Rust(
        val core: Core, val account: AccountRef, val library: LegacyLibrary, val detail: LegacyDetail, val sync: SettingsSyncAdapter,
        val playback: LegacyPlayback,
    ) {
        /** "Continue here" / "play on" server calls of this account. */
        val takeover: de.paulherter.swiftly.rustcore.TakeoverCalls by lazy { core.takeoverCalls(account) }
        /** Watching together and the control channel; built on first use, Jellyfin only. */
        @Volatile var syncPlay: RustSyncPlay? = null
    }

    @Volatile private var session: AccountRef? = null
    @Volatile private var userName = ""
    @Volatile private var sessionJson: String? = null
    @Volatile private var plex = false
    @Volatile private var rust: Rust? = null
    @Volatile private var core: Core? = null
    private val barrier = Any()
    private var always = true
    private var megabit = 0L
    private var serverExtractsText = false
    private var downloadsList = "[]"
    private var withoutNetwork = false
    /** The title that is open runs in the Rust core (otherwise in the Swift one: a group, a stored file, Plex). */
    @Volatile private var onRust = false
    private class Plays(val playback: LegacyPlayback)
    /** The open title's playback object (Jellyfin/Emby: the per-account one; Plex: its own). */
    @Volatile private var current: Plays? = null
    @Volatile private var plexPlay: Pair<AccountRef, LegacyPlayback>? = null

    /** Called whenever `Kern.sessionSet` is: the account the moved calls answer for. */
    fun sessionSet(json: String) {
        runCatching { login().sessionSet(json) }
        val o = runCatching { JSONObject(json) }.getOrNull()
        synchronized(barrier) {
            sessionJson = json.takeIf { o != null }
            // A new account: the old one's control channel and group end with it.
            rust?.syncPlay?.controlEnd()
            idleEnd()
            rust = null
            if (o == null) { session = null; plexDetail = null; plexLib = null; plexPlay = null; current = null; plex = false; return }
            userName = o.optString("userName")
            val kind = o.optString("kind", "jellyfin")
            plex = kind == "plex"
            session = AccountRef(
                o.optString("serverURL"), o.optString("userID"), o.optString("accessToken"),
                when (kind) { "emby" -> ServerKind.EMBY; "plex" -> ServerKind.PLEX; else -> ServerKind.JELLYFIN },
                app.store.devicesIdentifier(),
                // Plex only: what the core needs to ask plex.tv for the server's addresses again.
                o.optJSONObject("plex")?.optString("machineIdentifier")?.takeIf { it.isNotEmpty() },
                o.optJSONObject("plex")?.optString("accountToken")?.takeIf { it.isNotEmpty() },
            )
        }
    }

    /** There is no second core any more: a call that needs the account's objects fails loudly when they did not start. */
    private fun noCore(call: String): Nothing = throw IllegalStateException("[Kern] $call: no core for this account (no session or the Rust core did not start)")

    /** The current account's kind (`jellyfin`, `emby`, `plex`); `jellyfin` without a session. */
    fun kind(): String = when (session?.serverKind) { ServerKind.EMBY -> "emby"; ServerKind.PLEX -> "plex"; else -> "jellyfin" }

    /** `Kern.can`: whether the current server can do this (`ServerCapability` raw value). */
    fun can(capability: String): Boolean = core().legacyCan(session?.serverKind ?: ServerKind.JELLYFIN, capability)

    /** `Kern.serverName`. */
    fun serverName(): CompletableFuture<String> = scope.future { try { core().legacyServerName(session ?: noCore("serverName")) } catch (e: Throwable) { throw unwrap<Unit>(e) } }

    /** `Kern.accountDefaults`: `nextAutomatic|downloadRight|convertAllowed|qualitySelectable`, `|||1` without an answer. */
    fun accountDefaults(): CompletableFuture<String> = scope.future {
        val a = session ?: return@future "|||1"
        try { core().legacyAccountDefaults(a) } catch (e: Throwable) { if (e is kotlinx.coroutines.CancellationException) throw e; "|||1" }
    }

    /** A Plex server moved to another address (the session to store) or no longer accepts the token (`Kern.sessionEvents`). */
    @Volatile private var plexMoved = ""
    @Volatile private var plexRejected = false

    /** What happened to the connected Plex server since the last call: `{"moved": <session JSON or "">, "revoked": <bool>}`. */
    fun sessionEvents(): CompletableFuture<String> = scope.future {
        val moved = plexMoved.also { plexMoved = "" }
        val rejected = plexRejected.also { plexRejected = false }
        // A single title can answer 401 too, so the token is asked once before it counts (`sessionAppliesStill`).
        // Without a network the answer is "applies" (nobody is signed out).
        val revoked = rejected && !(try { loginCall { it.sessionApplies() }.await() } catch (e: Throwable) { if (e is kotlinx.coroutines.CancellationException) throw e; true })
        JSONObject().put("moved", moved).put("revoked", revoked).toString()
    }

    /** Called when the account signs out. */
    fun sessionClear() = synchronized(barrier) { runCatching { login().sessionClear() }; rust?.syncPlay?.controlEnd(); session = null; rust = null; plexDetail = null; plexLib = null; plexPlay = null; current = null; plex = false }

    /** Called with the playback settings (`Kern.playbackSelection`). */
    fun playbackSelection(alwaysDirectPlay: Boolean, megabit: Long) {
        synchronized(barrier) { always = alwaysDirectPlay; this.megabit = megabit; rust?.detail?.playbackSelection(alwaysDirectPlay, megabit); plexDetail?.second?.playbackSelection(alwaysDirectPlay, megabit); anyPlayback()?.playbackSelection(alwaysDirectPlay, megabit) }
    }

    private val language get() = Texts.language

    /** The core, built on first use (call off the main thread). */
    fun core(): Core = core ?: synchronized(barrier) {
        core ?: Core(
            AndroidPlatform.of(app) { AppLog.writeOut("[Kern] $it") },
            AndroidSecretStore(SharedStringPrefs(app.getSharedPreferences("swiftly", Context.MODE_PRIVATE)), GcmSealer.keystore()),
            // The downloads list is the old `Downloads/liste.json` (same file, same JSON); every other key is the core's own.
            DownloadIndexStore(File(app.filesDir, "Downloads"), AndroidKeyValueStore(SharedStringPrefs(app.getSharedPreferences("swiftly-core", Context.MODE_PRIVATE)))),
            AndroidHttpClient(prepare = { url, headers ->
                ownHeadersFields(url).forEach { (n, v) -> headers.removeAll { it.name.equals(n, true) }; headers.add(NetHeader(n, v)) }
            }),
        ).also { it.setLanguageNames(AndroidLanguageNames()); core = it }
    }

    /** The per-account objects, or `null` when the Swift path answers (Plex, no session, a start failure). */
    private fun rustOrNull(): Rust? {
        rust?.let { return it }
        val account = session ?: return null
        if (plex) return null
        return synchronized(barrier) {
            rust ?: runCatching {
                val c = core()
                val detail = c.legacyDetail(account, language).also { it.playbackSelection(always, megabit) }
                Rust(c, account, c.legacyLibrary(account, language), detail, SettingsSyncAdapter(c.settingsSyncModel(account, language)),
                    c.legacyPlayback(account, language).also { it.playbackSelection(always, megabit); it.setServerExtractsText(serverExtractsText); it.setNoDolbyVisionDecoder(!PlayerEngine.dolbyVisionAnyDecoder()); it.setDownloads(downloadsList, withoutNetwork) })
            }.onFailure { AppLog.writeOut("[Kern] Rust-Kern startet nicht: ${it.message}") }.getOrNull()?.also { rust = it; AppLog.writeOut("[Kern] Rust-Kern aktiv (${account.serverKind})") }
        }
    }

    /** The Plex title pages of the current session's account (title, series, episodes, trailers, person, watched, refresh). */
    @Volatile private var plexDetail: Pair<AccountRef, LegacyPlexDetail>? = null
    fun plexDetail(): LegacyPlexDetail? = plexDetailOrNull()
    private fun plexDetailOrNull(): LegacyPlexDetail? {
        val account = session ?: return null
        if (!plex) return null
        plexDetail?.let { if (it.first == account) return it.second }
        return synchronized(barrier) {
            plexDetail?.takeIf { it.first == account }?.second ?: runCatching {
                core().legacyPlexDetail(account, language).also { it.playbackSelection(always, megabit) }
            }.onFailure { AppLog.writeOut("[Kern] Plex-Detail startet nicht: ${it.message}") }.getOrNull()?.also { plexDetail = account to it }
        }
    }

    /** A detail call: Jellyfin/Emby and Plex answer from the core, the Swift path only when the core object did not start. */
    private inline fun dfut(
        crossinline jf: suspend (LegacyDetail) -> String, crossinline px: suspend (LegacyPlexDetail) -> String, swift: () -> CompletableFuture<String>,
    ): CompletableFuture<String> {
        if (!plex) return fut({ jf(it.detail) }, swift)
        val d = plexDetailOrNull() ?: return swift()
        return scope.future { try { px(d) } catch (e: Throwable) { if (e !is kotlinx.coroutines.CancellationException) AppLog.writeOut("[Kern] Plex-Aufruf fehlgeschlagen: ${e.message}"); throw unwrap<Unit>(e) } }
    }

    /** The library section state of a Plex account (the same object type as the per-account one). */
    @Volatile private var plexLib: Pair<AccountRef, LegacyLibrary>? = null
    private fun libOrNull(): LegacyLibrary? {
        rustOrNull()?.let { return it.library }
        val account = session ?: return null
        if (!plex) return null
        plexLib?.let { if (it.first == account) return it.second }
        return synchronized(barrier) {
            plexLib?.takeIf { it.first == account }?.second ?: runCatching { core().legacyLibrary(account, language) }
                .onFailure { AppLog.writeOut("[Kern] Plex-Bibliothek startet nicht: ${it.message}") }.getOrNull()?.also { plexLib = account to it }
        }
    }
    private inline fun libFut(crossinline body: suspend (LegacyLibrary) -> String, swift: () -> CompletableFuture<String>): CompletableFuture<String> {
        val l = libOrNull() ?: return swift()
        return scope.future { try { body(l) } catch (e: Throwable) { if (e !is kotlinx.coroutines.CancellationException) AppLog.writeOut("[Kern] Rust-Aufruf fehlgeschlagen: ${e.message}"); throw unwrap<Unit>(e) } }
    }

    /** The account the moved calls answer for (Plex included), `null` without a session. */
    fun account(): AccountRef? = session

    /** The title/series/download object of the current account, `null` when the Swift path answers (Plex, no session). */
    fun detail(): LegacyDetail? = rustOrNull()?.detail

    private fun <T> unwrap(e: Throwable): Throwable = when (e) {
        is CoreException.Failed -> RuntimeException(e.detail)
        else -> e
    }

    private inline fun fut(crossinline body: suspend (Rust) -> String, swift: () -> CompletableFuture<String>): CompletableFuture<String> {
        val r = rustOrNull() ?: return swift()
        return scope.future { try { body(r) } catch (e: Throwable) { if (e !is kotlinx.coroutines.CancellationException) AppLog.writeOut("[Kern] Rust-Aufruf fehlgeschlagen: ${e.message}"); throw unwrap<Unit>(e) } }
    }

    /**
     * For the calls the core answers from the account alone (Home, Library page, genres, watchlist, search): Plex included, they
     * are compared old against new (`LegacyPlexParityTest`). A start failure of the per-account objects does not matter here.
     */
    private inline fun acct(crossinline body: suspend (Core, AccountRef) -> String, swift: () -> CompletableFuture<String>): CompletableFuture<String> {
        val account = session ?: return swift()
        if (!plex) return fut({ body(it.core, it.account) }, swift)
        return scope.future {
            try { body(core(), account) } catch (e: Throwable) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                AppLog.writeOut("[Kern] Rust-Aufruf fehlgeschlagen: ${e.message}")
                // A moved server: ask plex.tv for the addresses again and ask once more at the one that answers.
                val healed = plexHeal(account) ?: run {
                    if (e.message.orEmpty().let { it.contains("401") || it.contains("nauthorized", true) }) plexRejected = true
                    throw unwrap<Unit>(e)
                }
                try { body(core(), healed) } catch (e2: Throwable) { throw unwrap<Unit>(e2) }
            }
        }
    }

    /**
     * Plex self-healing (`PlexSignIn.bestRoute`): the new account when plex.tv knows an address that differs from the one that failed,
     * otherwise `null`. The session keeps the new address, so the next call goes there at once; the Swift path stores it for good
     * (its own `sessionEvents`), the core's `AccountsModel.movePlexRoute` is for accounts the core itself holds.
     */
    private suspend fun plexHeal(failed: AccountRef): AccountRef? {
        val machine = failed.plexMachineId ?: return null
        val token = failed.plexAccountToken ?: return null
        val route = try {
            core().accountsModel(failed.deviceId, language)
                .plexSignIn(failed.deviceId, "1.0", "Android", android.os.Build.MODEL, android.os.Build.MODEL)
                .bestRoute(token, machine, failed.baseUrl)
        } catch (e: Throwable) { if (e is kotlinx.coroutines.CancellationException) throw e; AppLog.writeOut("[Kern] Plex-Adresse nicht erneuert: ${e.message}"); null } ?: return null
        if (route.uri == failed.baseUrl && route.token == failed.token) return null
        val healed = failed.copy(baseUrl = route.uri, token = route.token)
        synchronized(barrier) {
            if (session?.baseUrl == failed.baseUrl) {
                session = healed
                // The session as stored, with the new address and token: the app keeps the bundle's newest address.
                plexMoved = runCatching { JSONObject(sessionJson ?: "").put("serverURL", route.uri).put("accessToken", route.token).toString() }.getOrDefault("")
                sessionJson = plexMoved.ifEmpty { sessionJson }
            }
        }
        AppLog.writeOut("[Kern] Plex-Server hat die Adresse gewechselt, neue Route gesetzt")
        return healed
    }

    // ---- Home ----------------------------------------------------------------------------------------------------

    fun home(disconnected: Boolean, stored: Array<String>, from: Array<String>, filmLibrary: String, seriesLibrary: String,
             genres: Array<String>, asChips: Boolean, libraries: String): CompletableFuture<String> =
        acct({ c, a -> c.legacyHome(a, language, disconnected, stored.toList(), from.toList(), filmLibrary, seriesLibrary, genres.toList(), asChips, libraries) },
            { noCore("home") })

    fun startSelection(selected: String): CompletableFuture<String> =
        libFut({ it.startSelection(selected) }, { noCore("startSelection") })

    // ---- Library -------------------------------------------------------------------------------------------------

    fun libraryPage(library: String, art: String, sorting: String, filter: String, since: Long, count: Long): CompletableFuture<String> =
        acct({ c, a -> c.legacyLibraryPage(a, language, library, art, sorting, filter, since, count) },
            { noCore("libraryPage") })

    fun genre(name: String): CompletableFuture<String> =
        acct({ c, a -> c.legacyGenre(a, language, name) }, { noCore("genre") })

    fun genres(): CompletableFuture<String> = acct({ c, a -> c.legacyGenres(a, language) }, { noCore("genres") })

    fun watchlist(genre: String, sorting: String, since: Long, count: Long): CompletableFuture<String> =
        acct({ c, a -> c.legacyWatchlist(a, language, genre, sorting, since, count) }, { noCore("watchlist") })

    fun sectionOffering(art: String, remembered: String): CompletableFuture<String> =
        libFut({ it.sectionOffering(art, remembered) }, { noCore("sectionOffering") })

    fun sectionPage(art: String, choice: String, sorting: String, filter: String, since: Long, count: Long): CompletableFuture<String> =
        libFut({ it.sectionPage(art, choice, sorting, filter, since, count) }, { noCore("sectionPage") })

    fun offeringLoad(): CompletableFuture<Void?> {
        val l = libOrNull() ?: return noCore("offeringLoad")
        return scope.future { l.offeringLoad(); null }
    }

    fun collections(art: String): CompletableFuture<String> = libFut({ it.collections(art) }, { noCore("collections") })
    fun playlists(art: String): CompletableFuture<String> = libFut({ it.playlists(art) }, { noCore("playlists") })
    fun playlistPage(id: String, art: String): CompletableFuture<String> = libFut({ it.playlistPage(id, art) }, { noCore("playlistPage") })
    fun playlistStart(id: String, art: String): CompletableFuture<String> = libFut({ it.playlistStart(id, art) }, { noCore("playlistStart") })
    fun collectionMosaic(id: String, art: String, height: Long): CompletableFuture<String> =
        libFut({ it.collectionMosaic(id, art, height) }, { noCore("collectionMosaic") })
    fun collectionPage(id: String, art: String, sorting: String, filter: String, since: Long, count: Long): CompletableFuture<String> =
        libFut({ it.collectionPage(id, art, sorting, filter, since, count) }, { noCore("collectionPage") })
    fun collectionsForTitle(id: String): CompletableFuture<String> = libFut({ it.collectionsForTitle(id) }, { noCore("collectionsForTitle") })

    // ---- Search --------------------------------------------------------------------------------------------------

    fun search(term: String): CompletableFuture<String> = acct({ c, a -> c.legacySearch(a, language, term) }, { noCore("search") })

    // ---- Detail / series -----------------------------------------------------------------------------------------

    fun title(id: String): CompletableFuture<String> = dfut({ it.title(id) }, { it.title(id) }, { noCore("title") })
    fun series(id: String): CompletableFuture<String> = dfut({ it.series(id) }, { it.series(id) }, { noCore("series") })
    fun episodes(series: String, season: String): CompletableFuture<String> = dfut({ it.episodes(series, season) }, { it.episodes(series, season) }, { noCore("episodes") })
    fun titleField(id: String): CompletableFuture<String> = dfut({ it.titleField(id) }, { it.titleField(id) }, { noCore("titleField") })
    fun trailers(id: String, canOpenWeb: Boolean): CompletableFuture<String> = dfut({ it.trailers(id, canOpenWeb) }, { it.trailers(id, canOpenWeb) }, { noCore("trailers") })
    fun person(id: String): CompletableFuture<String> = dfut({ it.person(id) }, { it.person(id) }, { noCore("person") })
    fun episodeAfter(episode: String, series: String): CompletableFuture<String> = dfut({ it.episodeAfter(episode, series) }, { it.episodeAfter(episode, series) }, { noCore("episodeAfter") })
    fun shuffleStart(series: String): CompletableFuture<String> = dfut({ it.shuffleStart(series) }, { it.shuffleStart(series) }, { noCore("shuffleStart") })
    fun remember(id: String, an: Boolean): CompletableFuture<String> = dfut({ it.remember(id, an) }, { it.remember(id, an) }, { noCore("remember") })
    fun watched(id: String, an: Boolean): CompletableFuture<String> = dfut({ it.watched(id, an) }, { it.watched(id, an) }, { noCore("watched") })
    /** `{"lossless","methode"}` or `{}`; Plex still answers from the Swift side. */
    fun plan(id: String): CompletableFuture<String> = dfut({ it.plan(id) }, { it.plan(id) }, { noCore("plan") })
    fun fromContinueWatchingTake(id: String): CompletableFuture<String> = dfut({ it.fromContinueWatchingTake(id) }, { it.fromContinueWatchingTake(id) }, { noCore("fromContinueWatchingTake") })
    fun loadSelectionEpisodes(series: String, season: String): CompletableFuture<String> =
        dfut({ it.loadSelectionEpisodes(series, season) }, { it.loadSelectionEpisodes(series, season) }, { noCore("loadSelectionEpisodes") })
    /** The picture of the signed-in account, `null` without a session (Plex: the address plex.tv gave). */
    fun userImage(border: Long): String? = sessionJson?.let { legacyUserImage(it, border) }?.takeIf { it.isNotEmpty() }
    fun subtitleFileStyleAdjustable(): Boolean = legacySubtitleFileStyleAdjustable(if (plex) "plex" else "jellyfin")

    fun metadataRefresh(id: String): CompletableFuture<String> = dfut({ it.metadataRefresh(id) }, { it.metadataRefresh(id) }, { noCore("metadataRefresh") })

    // ---- Player helpers --------------------------------------------------------------------------------------------

    private val holds by lazy { LegacyHoldCounters() }

    /** `Kern.delayPress`: how many steps a press on - or + counts for (a held button is faster). */
    fun delayPress(row: String): Long = holds.press(row)

    // ---- The open title (playback) ---------------------------------------------------------------------------------

    /** `Kern.subtitleLookReport`: with "keep the file's style" off the server hands ASS out as SRT. */
    fun subtitleLookReport(json: String) {
        val keep = runCatching { JSONObject(json).optBoolean("keepFileStyle", true) }.getOrDefault(true)
        synchronized(barrier) { serverExtractsText = !keep && !plex; anyPlayback()?.setServerExtractsText(serverExtractsText) }
    }

    /** `Kern.downloadsKnown`: the downloads list and the network state, for the next episode and the stored files. */
    fun downloadsKnown(list: String, folder: String, withoutNetwork: Boolean) {
        synchronized(barrier) { downloadsList = list; this.withoutNetwork = withoutNetwork; anyPlayback()?.setDownloads(list, withoutNetwork) }
    }

    private fun anyPlayback(): LegacyPlayback? = rust?.playback ?: plexPlay?.second

    /** The playback object of a Plex account (Plex title pages stay in `plexDetail`). */
    private fun plexPlaybackOrNull(): LegacyPlayback? {
        val account = session ?: return null
        if (!plex) return null
        plexPlay?.let { if (it.first == account) return it.second }
        return synchronized(barrier) {
            plexPlay?.takeIf { it.first == account }?.second ?: runCatching {
                core().legacyPlayback(account, language).also { it.playbackSelection(always, megabit); it.setDownloads(downloadsList, withoutNetwork) }
            }.onFailure { AppLog.writeOut("[Kern] Plex-Wiedergabe startet nicht: ${it.message}") }.getOrNull()?.also { plexPlay = account to it }
        }
    }

    /** The title that plays; before the open has finished (the player screen asks first) and after the stop, the account's own idle playback object. */
    private fun playing(): Plays? = current ?: (rustOrNull()?.playback ?: plexPlaybackOrNull())?.let { Plays(it) }

    private fun bitrateLimit(): Long = if (always || megabit <= 0) 1_000_000_000L else megabit * 1_000_000L

    // MARK: Continue here / play on (the core: `TakeoverCalls`; the Swift Kern only when the core object did not start)
    fun takeoverOfferings(): CompletableFuture<String> = if (plex) CompletableFuture.completedFuture("[]") else fut({ it.takeover.offerings() }, { noCore("takeoverOfferings") })
    fun handedOver(session: String, itemID: String, spot: Double, ownName: String): CompletableFuture<String> =
        if (plex) CompletableFuture.completedFuture(JSONObject().put("grund", "nichtVerbunden").put("ab", spot).toString()) else fut({ it.takeover.handedOver(session, itemID, spot, ownName, bitrateLimit()) }, { noCore("handedOver") })
    fun playTargets(): String = if (plex) "[]" else rustOrNull()?.takeover?.playTargets() ?: noCore("playTargets")
    fun playOn(itemID: String, deviceID: String, name: String, position: Double): CompletableFuture<String> =
        if (plex) CompletableFuture.completedFuture(JSONObject().put("grund", "nichtVerbunden").put("name", name).toString()) else fut({ it.takeover.playOn(itemID, deviceID, name, position) }, { noCore("playOn") })
    fun playHandOver(deviceID: String, name: String, position: Double): CompletableFuture<String> {
        if (plex) return CompletableFuture.completedFuture(JSONObject().put("grund", "nichtVerbunden").put("name", name).toString())
        val p = playing()?.playback
        val t = rustOrNull()?.takeover
        if (p == null || t == null) return noCore("playHandOver")
        return scope.future { t.playHandOver(p, deviceID, name, position) }
    }

    /**
     * `Kern.playbackOpen`. The Rust core plans the title unless a group plays (its steps and next episode live in the Swift
     * core), the account is Plex, or the Rust core does not start; every later call goes where the title opened.
     */
    fun playbackOpen(id: String, sourceID: String, inGroup: Boolean = false): CompletableFuture<String> {
        val r = (rustOrNull()?.playback ?: plexPlaybackOrNull())?.let { Plays(it) }
        if (r == null) { onRust = false; current = null; AppLog.writeOut("[Kern] Wiedergabe: Swift-Kern (kein Rust-Kern)"); return noCore("playbackOpen") }
        return scope.future {
            try {
                val plan = r.playback.open(id, sourceID)
                current = r
                onRust = true
                AppLog.writeOut("[Kern] Wiedergabe: Rust-Kern ($id)")
                plan
            } catch (e: Throwable) {
                if (e !is kotlinx.coroutines.CancellationException) AppLog.writeOut("[Kern] Rust-Aufruf fehlgeschlagen: ${e.message}")
                throw unwrap<Unit>(e)
            }
        }
    }

    /** `Kern.playbackFromTheSlab`: a stored file plays before any server; the core builds the plan from the list entry. */
    fun playbackFromTheSlab(entries: String, path: String, image: String): String {
        val r = (rustOrNull()?.playback ?: plexPlaybackOrNull())?.let { Plays(it) } ?: noCore("playbackFromTheSlab")
        val plan = r.playback.openSlab(entries, path, image)
        current = r
        onRust = true
        AppLog.writeOut("[Kern] Wiedergabe: Rust-Kern (gespeicherte Datei)")
        return plan
    }

    /** `Kern.playbackLookUp`: what the server adds to a stored file's plan after the start (empty: nothing changed). */
    fun playbackLookUp(): CompletableFuture<String> = scope.future { playing()?.playback?.lookUp().orEmpty() }
    fun playbackPoint(since: Double) { playing()?.playback?.playbackPoint(since) ?: noCore("playbackPoint") }
    fun displayTime(position: Double, atPush: Boolean): Double = playing()?.playback?.displayTime(position, atPush) ?: noCore("displayTime")
    fun controlsChanged(opened: Boolean): String = playing()?.playback?.controlsChanged(opened) ?: noCore("controlsChanged")
    fun offeringClose(): Boolean = playing()?.playback?.offeringClose() ?: noCore("offeringClose")
    fun offeringPressed() { playing()?.playback?.offeringPressed() ?: noCore("offeringPressed") }
    fun nextAutomaticSet(on: Boolean) { anyPlayback()?.nextAutomaticSet(on) }
    fun resumeTarget(position: Double, inGroup: Boolean): Double = playing()?.playback?.resumeTarget(position, inGroup) ?: noCore("resumeTarget")
    fun prebufferDue(position: Double, duration: Double, networkFavorable: Boolean): Boolean =
        playing()?.playback?.prebufferDue(position, duration, networkFavorable) ?: noCore("prebufferDue")
    fun episodePrepare(): CompletableFuture<Void?> {
        val r = playing() ?: return noCore("episodePrepare")
        return scope.future { r.playback.episodePrepare(); null }
    }
    /** The watch-time counter of the support screen (`Support.watchSave`). */
    private val supportWatch by lazy { de.paulherter.swiftly.rustcore.LegacySupportWatch() }
    fun supportWatchBegin(usage: String) = supportWatch.begin(usage)
    fun supportWatchTake(usage: String, force: Boolean): String = supportWatch.take(usage, force)
    fun playbackTick(duration: Double, position: Double, showsImage: Boolean, running: Boolean, hasAudioTracks: Boolean, atPush: Boolean, autoSkip: Boolean): String {
        supportWatch.progress(running && showsImage && !atPush, System.currentTimeMillis())
        val r = playing() ?: return noCore("playbackTick")
        return r.playback.playbackTick(duration, position, showsImage, running, hasAudioTracks, atPush, autoSkip)
    }
    fun runStateReported(running: Boolean, position: Double) { playing()?.playback?.runStateReported(running, position) }
    fun jumpReported(target: Double): String = playing()?.playback?.jumpReported(target) ?: noCore("jumpReported")
    fun backgroundReport(position: Double, paused: Boolean) { playing()?.playback?.backgroundReport(position, paused) }

    fun playbackEnd(position: Double): CompletableFuture<String> {
        supportWatch.stopped(System.currentTimeMillis())
        val r = playing() ?: return noCore("playbackEnd")
        return scope.future {
            val answer = r.playback.playbackEnd(position)
            onRust = false
            answer
        }
    }
    fun qualitySwitch(position: Double): CompletableFuture<String> {
        val r = playing() ?: return noCore("qualitySwitch")
        return scope.future { r.playback.qualitySwitch(position) }
    }
    fun episodeSwitch(id: String, position: Double): CompletableFuture<String> {
        val r = playing() ?: return noCore("episodeSwitch")
        return scope.future { r.playback.episodeSwitch(id, position) }
    }

    fun subtitleFiles(): String = playing()?.playback?.subtitleFiles() ?: noCore("subtitleFiles")
    fun subtitleAttributeSet(index: Long, attribute: String) { playing()?.playback?.subtitleAttributeSet(index, attribute) ?: noCore("subtitleAttributeSet") }
    fun tracksSelect(audio: String, subtitle: String, audioNow: Long, audioWish: String, subtitlePreference: String, automatic: Boolean,
                     audioMemory: String, subtitleMemory: String): String =
        playing()?.playback?.tracksSelect(audio, subtitle, audioNow, audioWish, subtitlePreference, automatic, audioMemory, subtitleMemory)
            ?: noCore("tracksSelect")
    fun openSubtitle(subtitle: String): Long = playing()?.playback?.openSubtitle(subtitle) ?: noCore("openSubtitle")
    fun audioFromHand(audio: String, id: Long, memory: String): String = playing()?.playback?.audioFromHand(audio, id, memory) ?: noCore("audioFromHand")
    fun subtitleFromHand(subtitle: String, id: Long, memory: String): String = playing()?.playback?.subtitleFromHand(subtitle, id, memory) ?: noCore("subtitleFromHand")
    fun trackNames(audio: String, subtitle: String): String = playing()?.playback?.trackNames(audio, subtitle) ?: noCore("trackNames")

    fun chapterLoad(): CompletableFuture<Long> {
        val r = playing() ?: return noCore("chapterLoad")
        return CompletableFuture.completedFuture(r.playback.chapterLoad())
    }
    fun chapterBar(duration: Double, width: Double, minWidth: Double, gap: Double): String =
        current?.playback?.chapterBar(duration, width, minWidth, gap) ?: """{"stuecke":[],"fang":[]}"""
    fun chapterName(at: Double): String = current?.playback?.chapterName(at) ?: ""
    fun chapterPiece(share: Double, duration: Double, width: Double, minWidth: Double): Long =
        current?.playback?.chapterPiece(share, duration, width, minWidth) ?: -1L
    fun trickplayDetail(): CompletableFuture<String> {
        val r = playing() ?: return noCore("trickplayDetail")
        return CompletableFuture.completedFuture(r.playback.trickplayDetail())
    }
    fun trickplayAddress(width: Long, sheet: Long): CompletableFuture<String> {
        val r = playing() ?: return noCore("trickplayAddress")
        return CompletableFuture.completedFuture(r.playback.trickplayAddress(width, sheet))
    }
    fun firstFrameVideoCodec(): String = playing()?.playback?.firstFrameVideoCodec() ?: noCore("firstFrameVideoCodec")
    /** `Kern.techTick`: a measurement point from VLC's counters (the core keeps the previous one). */
    fun techTick(
        hasRead: Long, unpacked: Long, shown: Long, discarded: Long, videoBlocks: Long, audioBlocks: Long, audioPlay: Long,
        audioLost: Long, damaged: Long, jumps: Long, spot: Double, running: Boolean,
    ): String = playing()?.playback?.techTick(hasRead, unpacked, shown, discarded, videoBlocks, audioBlocks, audioPlay, audioLost, damaged, jumps, spot, running)
        ?: noCore("techTick")

    fun techFixed(measure: Boolean): String = playing()?.playback?.techFixed(measure) ?: noCore("techFixed")

    /** What the stops since the last pickup mean for the downloads and the catch-up reports (the core's rules). */
    fun stoppsProcess(store: String, list: String, nextAuto: Boolean): String =
        legacyStopsProcess(store, list, nextAuto, anyPlayback()?.stopsTake().orEmpty())

    /** The playback's log rows since the last pickup. */
    fun logFetch(): String = anyPlayback()?.logFetch().orEmpty()

    // ---- Watching together, the control channel (the group's flow is the core's `SyncPlayModel`) -------------------------

    /** The Rust glue for this account, or `null` when the Swift core answers (Plex, Emby, no session, a start failure). */
    private fun sp(): RustSyncPlay? {
        val r = rustOrNull() ?: return null
        if (r.account.serverKind != ServerKind.JELLYFIN) return null
        r.syncPlay?.let { return it }
        return synchronized(barrier) {
            r.syncPlay ?: runCatching {
                RustSyncPlay(r.core, r.account, language, userName.ifEmpty { null }, scope,
                    titleExists = { id -> runCatching { r.detail.title(id) }.isSuccess },
                    ordered = { id, audio, subtitle -> r.playback.setOrdered(id, audio, subtitle) },
                    log = { AppLog.writeOut("[Gemeinsam] $it") })
            }.onFailure { AppLog.writeOut("[Kern] SyncPlay startet nicht: ${it.message}") }.getOrNull()?.also { r.syncPlay = it }
        }
    }

    /**
     * Accounts without SyncPlay and remote control (Emby, Plex: `ServerCapability` lacks both): the old core waited for events
     * that never came. The waits stay pending until the account ends (`remoteControlEnd`), then they fail and the loops ask again.
     */
    private val idleWaits = java.util.concurrent.CopyOnWriteArrayList<CompletableFuture<*>>()
    @Suppress("UNCHECKED_CAST")
    private fun <T> idle(): CompletableFuture<T> = CompletableFuture<T>().also { f -> idleWaits.add(f); f.whenComplete { _, _ -> idleWaits.remove(f) } }
    private fun idleEnd() { idleWaits.toList().forEach { it.completeExceptionally(java.util.concurrent.CancellationException("account ended")) } }

    private fun <T> spFuture(body: suspend (RustSyncPlay) -> T, none: () -> CompletableFuture<T>): CompletableFuture<T> {
        val s = sp() ?: return none()
        return scope.future { body(s) }
    }

    fun syncPlayStatus(to: Long): CompletableFuture<String> = spFuture({ it.status(to) }, { idle() })
    fun syncPlayRequest(): CompletableFuture<String> = spFuture({ it.request() }, { idle() })
    fun syncPlayOfferingsAsk(): CompletableFuture<Void?> = spFuture<Void?>({ it.offeringsAsk(); null }, { CompletableFuture.completedFuture(null) })
    fun syncPlayCreate(name: String, title: String): CompletableFuture<Boolean> = spFuture({ it.create(name, title) }, { CompletableFuture.completedFuture(false) })
    fun syncPlayJoin(group: String): CompletableFuture<Boolean> = spFuture({ it.join(group) }, { CompletableFuture.completedFuture(false) })
    fun syncPlayAgainJoin(): CompletableFuture<Void?> = spFuture<Void?>({ it.rejoin(); null }, { CompletableFuture.completedFuture(null) })
    fun syncPlayConnect(title: String): CompletableFuture<Long> = spFuture({
        it.connect(title).also { mark -> if (mark > 0) rust?.playback?.setWithoutNext(true) }
    }, { CompletableFuture.completedFuture(0L) })
    fun syncPlayDetach(mark: Long) {
        val s = sp() ?: return
        s.detach(mark); rust?.playback?.setWithoutNext(false)
    }
    fun syncPlayTick(mark: Long, title: String, ready: Boolean, spot: Double, running: Boolean) {
        sp()?.tick(mark, title, ready, spot, running)
    }
    fun syncPlayStep(mark: Long): CompletableFuture<String> = spFuture({ it.step(mark) }, { CompletableFuture.completedFuture("") })
    fun syncPlayPleaseToggle(running: Boolean) { sp()?.pleaseToggle(running) }
    fun syncPlayPleaseTitle(title: String) { sp()?.pleaseTitle(title) }
    fun syncPlayPleaseJump(seconds: Double) { sp()?.pleaseJump(seconds) }

    fun remoteControlStart(): CompletableFuture<Void?> =
        sp()?.let { s -> scope.future<Void?> { s.controlStart(); null } } ?: CompletableFuture.completedFuture(null)
    fun remoteControlEnd(): CompletableFuture<Void?> {
        val s = rust?.syncPlay
        if (s != null) s.controlEnd()
        idleEnd()
        return CompletableFuture.completedFuture(null)
    }
    fun remoteCommands(): String = sp()?.commandsTake() ?: "[]"
    fun handoffTargetTake(): String = sp()?.hintTake() ?: ""
    fun playOrderWait(): CompletableFuture<String> = spFuture({ it.orderWait() }, { idle() })

    // ---- Settings sync -------------------------------------------------------------------------------------------

    fun settingsSyncRun(local: String, localChanged: Double, remoteSeen: Double, otherAccount: Boolean, seerr: String, seerrChanged: Double): CompletableFuture<String> =
        // Display preferences are Jellyfin's: nothing to compare on Plex.
        if (plex) CompletableFuture.completedFuture("""{"decision":"nothing","remote":0.0,"stamp":0.0,"values":{},"seerr":"nothing","seerrAccess":"","seerrStamp":0.0}""") else fut({ it.sync.run(local, localChanged, remoteSeen, otherAccount, seerr, seerrChanged) },
            { noCore("settingsSyncRun") })

    // ---- Downloads (the server calls; the queue is the core's `DownloadsVm`) -----------------------------------------

    fun downloadItem(ids: Array<String>): CompletableFuture<String> =
        dfut({ it.downloadItem(ids.toList()) }, { it.downloadItem(ids.toList()) }, { noCore("downloadItem") })
    fun downloadAudioOptions(ids: Array<String>, preferred: String): CompletableFuture<String> =
        dfut({ it.downloadAudioOptions(ids.toList(), preferred, language) }, { it.downloadAudioOptions(ids.toList(), preferred, language) }, { noCore("downloadAudioOptions") })
    fun downloadWithAudio(list: String, choice: String): String =
        rustOrNull()?.detail?.downloadWithAudio(list, choice, language) ?: plexDetailOrNull()?.downloadWithAudio(list, choice, language) ?: noCore("downloadWithAudio")
    fun downloadHeaderImage(series: String, width: Long): CompletableFuture<String> =
        dfut({ it.downloadHeaderImage(series, width) }, { it.downloadHeaderImage(series, width) }, { noCore("downloadHeaderImage") })
    // ---- Seerr: the stored access is kept here; the core's object is built on first use (off the main thread) ----

    @Volatile private var seerrAccess: String? = null
    @Volatile private var seerrObject: LegacySeerr? = null

    private fun seerr(): LegacySeerr? = seerrObject ?: synchronized(barrier) {
        seerrObject ?: seerrAccess?.let { a -> runCatching { core().legacySeerr(a) }.getOrNull() }?.also { seerrObject = it }
    }

    /** Sets the remembered access (`{"adresse","keks","koepfe"}`, the vault's text); garbage means not connected. */
    fun seerrSet(access: String) { synchronized(barrier) { seerrAccess = access; seerrObject = null } }

    /** The platform cookies go too, so a still-valid session cannot keep a new sign-in from getting its own. */
    fun seerrDisconnect() { val old = seerrObject; synchronized(barrier) { seerrAccess = null; seerrObject = null }; old?.forgetCookies() }

    // ---- Server search, public users, Quick Connect, sign-in and adding a server: the core's, in the old JSON ----

    @Volatile private var loginObject: LegacyLogin? = null
    private fun login(): LegacyLogin = loginObject ?: synchronized(barrier) {
        loginObject ?: core().accountsModel(app.store.devicesIdentifier().lowercase(), language).legacyLogin().also { loginObject = it }
    }
    private fun <T> loginCall(body: suspend (LegacyLogin) -> T): CompletableFuture<T> = scope.future {
        try { body(login()) } catch (e: Throwable) { throw unwrap<Unit>(e) }
    }
    fun serverInfo(): CompletableFuture<String> = loginCall { it.serverInfo() }
    fun serverSearchPause(): Long = login().serverSearchPause()
    fun serverSearch(known: String, except: String): CompletableFuture<String> =
        loginCall { it.serverSearch(AndroidDatagramHost(), AndroidDatagramHost.interfaces(), known, except) }
    fun publicUser(newServer: Boolean): CompletableFuture<String> = loginCall { it.publicUser(newServer) }
    fun onboardingConnect(address: String, headers: String): CompletableFuture<String> = loginCall { it.onboardingConnect(address, headers) }
    fun onboardingCancel() { loginObject?.onboardingCancel() }
    fun onboardingSignIn(user: String, password: String): CompletableFuture<String> = loginCall { it.onboardingSignIn(user, password) }
    fun embySignIn(user: String, password: String): CompletableFuture<String> = loginCall { it.embySignIn(user, password) }
    /** Remembers a server checked elsewhere as the one being added (the Emby check does it itself now). */
    fun onboardingRemember(address: String, emby: Boolean) { runCatching { login().onboardingRemember(address, emby) } }
    /** The address check that makes the server the connected one, then [signIn] goes there. */
    fun linkUp(address: String, headers: String): CompletableFuture<String> = loginCall { it.linkUp(address, headers) }
    fun signIn(user: String, password: String): CompletableFuture<String> = loginCall { it.signIn(user, password) }
    fun embyCheck(address: String, headers: String): CompletableFuture<String> = loginCall { it.embyCheck(address, headers) }
    /** Approves another device's Quick Connect code: empty is done, otherwise the sentence to show. */
    fun quickConnectShare(code: String): CompletableFuture<String> = loginCall { it.quickConnectShare(code) }
    /** `false` only when the server refused the token. */
    fun sessionApplies(): CompletableFuture<Boolean> = loginCall { it.sessionApplies() }
    fun signOff(): CompletableFuture<Unit> = loginCall { it.signOff() }
    fun quickConnectStart(newServer: Boolean): CompletableFuture<String> = loginCall { it.quickConnectStart(newServer) }
    fun quickConnectWait(newServer: Boolean): CompletableFuture<String> = loginCall { it.quickConnectWait(newServer) }
    fun quickConnectRest(): Long = loginObject?.quickConnectRest() ?: 0L
    fun quickConnectWaitEnd(code: String) { loginObject?.quickConnectWaitEnd(code) }
    fun quickConnectSignIn(newServer: Boolean): CompletableFuture<String> = loginCall { it.quickConnectSignIn(newServer) }

    // ---- Plex sign-in: the core's steps in the old JSON; one flow object, built on first use (off the main thread) ----

    @Volatile private var plexFlow: LegacyPlexSignIn? = null
    /** Stands in for plex.tv (tests and debug builds only); `null` is the real one. */
    @Volatile var plexBaseUrl: String? = null

    private fun plexFlow(): LegacyPlexSignIn = plexFlow ?: synchronized(barrier) {
        plexFlow ?: core().accountsModel(app.store.devicesIdentifier().lowercase(), language)
            .legacyPlexSignIn(app.store.devicesIdentifier().lowercase(), SwiftlyApplication.BuildConfigVersion, "Android", android.os.Build.MODEL, android.os.Build.MODEL, plexBaseUrl)
            .also { plexFlow = it }
    }
    private fun <T> plexCall(body: suspend (LegacyPlexSignIn) -> T): CompletableFuture<T> = scope.future {
        try { body(plexFlow()) } catch (e: Throwable) { throw unwrap<Unit>(e) }
    }
    fun plexStart(): CompletableFuture<String> = plexCall { it.start() }
    fun plexStartTv(): CompletableFuture<String> = plexCall { it.startTv() }
    fun plexPoll(): CompletableFuture<String> = plexCall { it.poll() }
    fun plexPickProfile(id: String, pin: String): CompletableFuture<String> = plexCall { it.pickProfile(id, pin) }
    fun plexServers(): CompletableFuture<String> = plexCall { it.servers() }
    fun plexPickServer(id: String): CompletableFuture<String> = plexCall { it.pickServer(id) }
    fun plexReset() { plexFlow?.reset() }

    /** Signs in with the Jellyfin name and password; the answer is the access to store. `headers` are the "Advanced" rows. */
    fun seerrConnect(address: String, user: String, password: String, headers: String): CompletableFuture<String> = scope.future {
        try { core().legacySeerrConnect(address, user, password, headers).also { seerrSet(it) } }
        catch (e: Throwable) { throw unwrap<Unit>(e) }
    }

    fun seerrApplies(): CompletableFuture<Boolean> = scope.future { seerr()?.applies() ?: false }
    fun seerrSearch(term: String): CompletableFuture<String> = scope.future { seerr()?.search(term) ?: "[]" }
    fun seerrFilmography(tmdb: Long): CompletableFuture<String> = scope.future { seerr()?.filmography(tmdb) ?: "[]" }
    fun seerrDetail(art: String, id: Long): CompletableFuture<String> = scope.future { seerr()?.detail(art, id) ?: "{}" }
    fun seerrRequest(art: String, id: Long, seasons: String): CompletableFuture<String> = scope.future { seerr()?.request(art, id, seasons) ?: "nichtAngemeldet" }

    fun watchers(id: String): CompletableFuture<String> =
        if (plex) CompletableFuture.completedFuture("absent") else fut({ it.detail.watchers(id) }, { noCore("watchers") })
    fun pendingSubmit(store: String): CompletableFuture<String> =
        if (plex) CompletableFuture.completedFuture("[]") else fut({ it.detail.pendingSubmit(store) }, { noCore("pendingSubmit") })
}
