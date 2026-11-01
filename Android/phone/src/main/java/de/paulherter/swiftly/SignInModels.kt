package de.paulherter.swiftly

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject

// MARK: - State and steps of the Plex and Emby sign-in
//
// Mirrors `Sources/Shared/SignInModels.swift`: **what the page shows and the calls to the core, and
// nothing that draws.** The phone pages (`PlexSignIn.kt`, `EmbySignIn.kt`) and the TV pages
// (`tv/TvPlexSignIn.kt`, `tv/TvEmbySignIn.kt`) read these models; only the drawing and the way
// the sign-in window opens differ. One place for the steps, so the two cannot drift apart.

// MARK: Plex

data class PlexProfile(val id: String, val name: String, val image: String?, val protected: Boolean)

data class PlexServer(val id: String, val name: String, val sharedBy: String?, val local: Boolean, val online: Boolean)

/** Where the page is. Mirrors `PlexSignInModel.Step` (the failures are three steps instead of one with a payload). */
sealed interface PlexStep {
    data object Start : PlexStep
    /** The button was pressed, the code is being fetched. */
    data object Opening : PlexStep
    /** `url`: the page to open (phone) or to type in (TV); `code`: the short code, TV only. */
    data class Waiting(val url: String, val code: String?, val secondsLeft: Int?) : PlexStep
    /** Signed in, the servers on their way. Placeholders in the shape of what comes. */
    data object LoadingServers : PlexStep
    data class Profiles(val list: List<PlexProfile>) : PlexStep
    data class Pin(val profile: PlexProfile) : PlexStep
    data class Servers(val list: List<PlexServer>) : PlexStep
    data object PlexUnreachable : PlexStep
    data object Expired : PlexStep
    data class Failed(val message: String) : PlexStep
}

/**
 * **Sign in with Plex**: the core does the network steps (`plexStart`/`plexStartTv`, `plexPoll`,
 * `plexPickProfile`, `plexServers`, `plexPickServer`) and answers each with the next step.
 *
 * `tv`: no browser, a short code at plex.tv/link (the two `#if os(tvOS)` places in
 * `AppModel+Servers.swift`). `finished`: signed in and connected, the session is stored already.
 * `leave`: the arrow at the top on the first step.
 */
class PlexSignInModel(private val app: SwiftlyApplication, private val scope: CoroutineScope, private val tv: Boolean,
                      private val finished: () -> Unit, private val leave: () -> Unit) {
    var step by mutableStateOf<PlexStep>(PlexStep.Start)
        private set
    /** The plex.tv account's name once known; it becomes the page title. */
    var account by mutableStateOf<String?>(null)
        private set
    /** The profile chosen in Plex Home; shown above the server list. */
    var profileName by mutableStateOf<String?>(null)
        private set
    /** Remembered so the PIN page can go back without asking plex.tv again. */
    var lastProfiles by mutableStateOf<List<PlexProfile>?>(null)
    var pinWrong by mutableStateOf(false)
    var pinChecking by mutableStateOf(false)
        private set
    /** The server being connected to right now. */
    var connecting by mutableStateOf<String?>(null)
        private set
    /** Servers that did not answer at any of their addresses. */
    var unreachable by mutableStateOf<Set<String>>(emptySet())
        private set

    /** The poll saw something else than "waiting": the sign-in window (phone) did its job. */
    var waitingEnded: () -> Unit = {}
    /** A nudge for the poll loop: look right now (the page came back to the front). */
    private val nudge = Channel<Unit>(Channel.CONFLATED)

    /** The page title: the account's name once signed in, like the server's name on the Jellyfin page. */
    val title: String get() = when (step) {
        PlexStep.Start, PlexStep.Opening, is PlexStep.Waiting, PlexStep.PlexUnreachable, PlexStep.Expired, is PlexStep.Failed ->
            ServerKind.Plex.shownName
        else -> account ?: ServerKind.Plex.displayName
    }

    private fun readProfiles(o: JSONObject) = o.fieldList("profiles") {
        PlexProfile(it.getString("id"), it.getString("name"), it.fieldText("image"), it.optBoolean("protected"))
    }

    /** Takes the core's answer into the page. `true` when it was `done` (the page is leaving). */
    private fun apply(answer: String): Boolean {
        val o = JSONObject(answer)
        val before = step
        when (o.getString("step")) {
            "waiting" -> {
                val url = o.fieldText("url")
                val seconds = o.optInt("secondsLeft", 0)
                if (url != null) step = PlexStep.Waiting(url, o.fieldText("code"), seconds.takeIf { it > 0 })
                // A beat that only says "nothing yet" keeps the countdown; 0 means the core has nothing to add.
                else if (before is PlexStep.Waiting && seconds > 0) step = before.copy(secondsLeft = seconds)
            }
            "profiles" -> {
                o.fieldText("account")?.let { account = it }
                val list = readProfiles(o)
                lastProfiles = list
                step = PlexStep.Profiles(list)
            }
            "servers" -> {
                o.fieldText("account")?.let { account = it }
                profileName = o.fieldText("profile")
                unreachable = emptySet()
                step = PlexStep.Servers(o.fieldList("servers") {
                    PlexServer(it.getString("id"), it.getString("name"),
                               it.fieldText("sharedBy")?.let { who -> who.ifEmpty { translated("einem anderen Konto") } },
                               it.optBoolean("local"), it.optBoolean("online", true))
                })
            }
            "plexUnreachable" -> step = PlexStep.PlexUnreachable
            "expired" -> step = PlexStep.Expired
            "failed" -> step = PlexStep.Failed(o.fieldText("message").orEmpty())
            "done" -> {
                app.sessionRecord(o.getString("session"))
                finished()
                return true
            }
        }
        if (before is PlexStep.Waiting && step !is PlexStep.Waiting) waitingEnded()
        return false
    }

    /** One call to the core; an unexpected exception ends the flow with its own words, never silently. */
    private suspend fun ask(call: suspend () -> String): String? = try {
        withContext(Dispatchers.IO) { call() }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        step = PlexStep.Failed(errorString(app, e))
        null
    }

    /** "Mit Plex anmelden" and "Neuen Code holen". `opened` is called with the waiting step once it is there. */
    fun start(opened: (PlexStep.Waiting) -> Unit = {}) {
        step = PlexStep.Opening
        scope.launch {
            val answer = ask { (if (tv) app.kern.plexStartTv() else app.kern.plexStart()).await() } ?: return@launch
            apply(answer)
            (step as? PlexStep.Waiting)?.let(opened)
        }
    }

    fun loadServers() {
        step = PlexStep.LoadingServers
        scope.launch { ask { app.kern.plexServers().await() }?.let { apply(it) } }
    }

    fun pickProfile(p: PlexProfile) {
        if (p.protected) { pinWrong = false; step = PlexStep.Pin(p); return }
        step = PlexStep.LoadingServers
        scope.launch { ask { app.kern.plexPickProfile(p.id, "").await() }?.let { apply(it) } }
    }

    fun submitPin(p: PlexProfile, pin: String) {
        if (pinChecking) return
        pinChecking = true; pinWrong = false
        scope.launch {
            try {
                val answer = ask { app.kern.plexPickProfile(p.id, pin).await() }
                if (answer != null && JSONObject(answer).getString("step") == "pinWrong") pinWrong = true
                else if (answer != null) apply(answer)
            } finally { pinChecking = false }
        }
    }

    fun pickServer(s: PlexServer) {
        if (connecting != null) return
        connecting = s.id
        unreachable = unreachable - s.id
        scope.launch {
            try {
                val answer = ask { app.kern.plexPickServer(s.id).await() } ?: return@launch
                if (JSONObject(answer).getString("step") == "unreachable") unreachable = unreachable + s.id
                else apply(answer)
            } finally { connecting = null }
        }
    }

    fun otherAccount() {
        app.kern.plexReset()
        account = null; profileName = null; lastProfiles = null; unreachable = emptySet()
        step = PlexStep.Start
    }

    /** The arrow at the top: one step back within the flow (from the PIN or the servers to the profiles), or out of it. */
    fun goBack() {
        val profiles = lastProfiles
        val s = step
        if (profiles != null && profiles.size > 1 &&
            (s is PlexStep.Pin || s is PlexStep.Servers || s is PlexStep.LoadingServers)) {
            step = PlexStep.Profiles(profiles)
        } else {
            app.kern.plexReset()
            leave()
        }
    }

    /** The page came back to the front, or the window was closed by hand: look right now. */
    fun lookNow() { nudge.trySend(Unit) }

    /** About once a second until the token is seen or the code is gone; one look at a time. Runs while [step] is waiting. */
    suspend fun poll() {
        while (true) {
            withTimeoutOrNull(1000) { nudge.receive() }
            val answer = ask { app.kern.plexPoll().await() } ?: return
            apply(answer)
            if (step !is PlexStep.Waiting) return
        }
    }

    /** What the flow holds in the core goes with the page, by whatever route. */
    fun dispose() { app.kern.plexReset() }
}

// MARK: Emby

data class EmbyUser(val id: String, val name: String, val image: String?)

/** What went wrong at the address step, in the three shapes the page tells apart. */
sealed interface EmbyProblem {
    /** Nothing answered: the same hint as everywhere a server does not. */
    data class Unreachable(val address: String) : EmbyProblem
    /** Something answered, but not Emby. `found` names it when known ("Jellyfin"). */
    data class NotEmby(val found: String?) : EmbyProblem
    data class Other(val message: String) : EmbyProblem
}

/**
 * **Sign in with Emby: the Jellyfin way, two steps on one page.** An address (`embyCheck`), then name
 * and password (`embySignIn`), with the accounts the server shows. `server` is `null` on the address
 * step; otherwise the server's name and version.
 */
class EmbySignInModel(private val app: SwiftlyApplication, private val scope: CoroutineScope, address: String?,
                      private val finished: () -> Unit, private val leave: () -> Unit) {
    var address by mutableStateOf(address.orEmpty())
    var checking by mutableStateOf(false)
        private set
    var problem by mutableStateOf<EmbyProblem?>(null)
    var server by mutableStateOf<Pair<String, String>?>(null)
        private set
    /** `null` until the check answered; empty when the server shows none. */
    var users by mutableStateOf<List<EmbyUser>?>(null)
        private set
    var user by mutableStateOf("")
    var password by mutableStateOf("")
    var signingIn by mutableStateOf(false)
        private set
    var signInError by mutableStateOf<String?>(null)
    private var verification: Job? = null

    fun check(headers: List<HeaderRow>) {
        val raw = address.trim()
        if (raw.isEmpty() || checking) return
        checking = true; problem = null
        verification = scope.launch {
            try {
                val o = JSONObject(withContext(Dispatchers.IO) { app.kern.embyCheck(raw, headers.asJson()).await() })
                when (o.getString("result")) {
                    "ok" -> {
                        // Store only now: an address where nothing answers leaves nothing behind.
                        if (headers.isNotEmpty()) app.storeOwnHeaders()
                        address = o.fieldText("adresse")?.takeIf { it.isNotEmpty() } ?: address
                        val list = o.fieldList("konten") { EmbyUser(it.getString("id"), it.getString("name"), it.fieldText("image")) }
                        users = list
                        // One account: nothing to choose, the name is filled in. As on the Jellyfin page.
                        if (list.size == 1 && user.isEmpty()) user = list[0].name
                        server = o.getString("name") to o.getString("version")
                    }
                    "unreachable" -> problem = EmbyProblem.Unreachable(raw)
                    "badAddress" -> problem = EmbyProblem.Other(translated("Die Adresse konnte nicht gelesen werden."))
                    "notEmby" -> problem = EmbyProblem.NotEmby(o.fieldText("found"))
                    else -> problem = EmbyProblem.Other(o.fieldText("message").orEmpty())
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                problem = EmbyProblem.Other(errorString(app, e))
            } finally { checking = false }
        }
    }

    fun signIn() {
        if (user.isEmpty() || signingIn) return
        signingIn = true; signInError = null
        scope.launch {
            try {
                val session = withContext(Dispatchers.IO) { app.kern.embySignIn(user, password).await() }
                app.kern.onboardingCancel()
                app.sessionRecord(session)
                finished()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                signInError = errorString(app, e)
            } finally { signingIn = false }
        }
    }

    /** The arrow: from the sign-in back to the address, from the address out. */
    fun goBack() {
        if (server != null) {
            server = null; signInError = null; password = ""
        } else {
            verification?.cancel()
            app.kern.onboardingCancel()
            leave()
        }
    }

    /** The checked server waits in the core; it goes with the page, by whatever route. */
    fun dispose() { app.kern.onboardingCancel() }
}
