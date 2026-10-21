package de.paulherter.swiftly.support

import android.app.Activity
import android.os.SystemClock
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.core.Kern
import de.paulherter.swiftly.shared.translated
import org.json.JSONArray
import org.json.JSONObject

/**
 * **"Support Swiftly" on Android**, phone and TV. Mirrors the SupportKit use in the Apple apps.
 *
 * Every rule lives in the package (`SupportPrompt`, `SupportStore`, `WatchTimeCounter`), reached
 * through the core (`Support.swift`). This class only keeps the three records in SharedPreferences
 * under the package's keys (`support.status`, `support.usage`, `support.promptHistory`, unchanged)
 * and turns the answers into Compose state.
 *
 * **Two ways, chosen at build time** (`FlavorSupport` in `src/play` and `src/direct`): Google Play
 * Billing in the Play build, the website in the direct APK. Nothing here
 * names either.
 */
class Support(private val app: SwiftlyApplication) {
    /** When this process started; the package asks for quiet in the first 60 seconds. */
    private val launchedAt = SystemClock.elapsedRealtime()

    /** The way to say thanks this build has. */
    val channel: SupportChannel = FlavorSupport.channel(app, this)

    /** Supporter on this device: "store", "key", or "" for none. Drives hearts and badges. */
    val source = mutableStateOf(Kern.supportSource(record(STATUS)))
    val isSupporter: Boolean get() = source.value.isNotEmpty()

    /** Whether the usage record existed before this launch (the package's `usedBeforeThisLaunch`). */
    var usedBeforeThisLaunch = false
        private set

    /** Counts changes to the records; the home card and the settings row read again on change. */
    val changed = mutableIntStateOf(0)

    /** The thank-you sheet is due (after a purchase or an accepted key). The UI shows and clears it. */
    val thanksDue = mutableStateOf(false)

    /**
     * How the phone's main view opens a page; the thanks sheet leads to the icon picker through it.
     * Set by `MainScreen`.
     */
    var openPage: (de.paulherter.swiftly.Destination) -> Unit = {}

    /** TV only: which support panel is open. The phone uses `app.sheet`. */
    val tvPanel: MutableState<TvSupportPanel?> = mutableStateOf(null)

    /** The three tips, in display order, from the package (title per language, symbol). */
    val tips: List<SupportTipInfo> = runCatching {
        val a = JSONArray(Kern.supportTips())
        (0 until a.length()).map { a.getJSONObject(it).let { o ->
            SupportTipInfo(o.getString("id"), o.getString("de"), o.getString("emoji"))
        } }
    }.getOrDefault(emptyList())

    /** Whether "Support Swiftly" may show at all. False on a Play build without Play (no link then). */
    val available: Boolean get() = channel.available.value

    private fun record(key: String): String = app.store.rememberValue(key).orEmpty()

    /** When the support began (the record's `since`, seconds), in milliseconds; null without one. */
    val sinceMillis: Long? get() = runCatching { JSONObject(record(STATUS)).optDouble("since", 0.0) }.getOrNull()
        ?.takeIf { it > 0 }?.let { (it * 1000).toLong() }

    private fun store(key: String, value: String) {
        if (value.isEmpty()) return
        app.store.remember(key, value)
        changed.intValue += 1
    }

    /** Once per process: first launch, the watch counter, the store connection. */
    fun start() {
        usedBeforeThisLaunch = record(USAGE).isNotEmpty()
        runCatching {
            store(USAGE, Kern.supportRecordLaunch(record(USAGE), System.currentTimeMillis()))
            app.kern.supportWatchBegin(record(USAGE))
        }.onFailure { log("start: $it") }
        channel.connect()
    }

    /** Store counted watch time; `force` at the end of playback. Cheap when nothing is due. */
    fun watchSave(force: Boolean) {
        runCatching { store(USAGE, app.kern.supportWatchTake(record(USAGE), force)) }
            .onFailure { log("watch: $it") }
    }

    /** What the package decides right now. */
    fun decide(): SupportDecision = runCatching {
        val o = JSONObject(Kern.supportDecide(record(STATUS), record(USAGE), record(HISTORY),
            app.play.value != null, (SystemClock.elapsedRealtime() - launchedAt) / 1000.0, app.isTv,
            System.currentTimeMillis()))
        SupportDecision(o.getBoolean("showsHeart") && available, o.getBoolean("showsCard") && available,
            o.getBoolean("showsSheet") && available, o.getInt("watchedHours"))
    }.getOrDefault(SupportDecision(false, false, false, 0))

    /** "Not now" on the card (30 days), "Don't show again", or the sheet appeared. */
    fun answer(kind: String) {
        runCatching { store(HISTORY, Kern.supportHistoryAfter(record(HISTORY), kind, System.currentTimeMillis())) }
            .onFailure { log("answer: $it") }
    }

    /**
     * A purchase or key was confirmed. `fresh`: it just happened here, so say thanks; a restore at
     * start does not.
     */
    fun becameSupporter(status: String, fresh: Boolean, plan: String = "") {
        if (plan.isNotEmpty() && app.store.rememberValue(PLAN) != plan) app.store.remember(PLAN, plan)
        // A restore at every start must not rewrite the record (and its date) each time.
        if (!fresh && isSupporter) return
        store(STATUS, status)
        source.value = Kern.supportSource(record(STATUS))
        if (fresh) thanksDue.value = true
    }

    /** The store no longer lists any tip (refund). Only a store status is withdrawn, never a key. */
    fun storeStatusGone() {
        if (source.value != "store") return
        app.store.remember(STATUS, "")
        app.store.remember(PLAN, "")
        source.value = ""
        changed.intValue += 1
        AppIcons.reset(app)
    }

    /** A key-based status ended (expired or refunded; direct build). Only that status is withdrawn, never a store's. */
    fun keyStatusGone() {
        if (source.value != "key") return
        app.store.remember(STATUS, "")
        app.store.remember(PLAN, "")
        source.value = ""
        changed.intValue += 1
        AppIcons.reset(app)
    }

    /** Title of a tip in the current language (the package gives the German key, the catalog the rest). */
    fun tipTitle(tip: SupportTipInfo): String = translated(tip.titleKey)

    companion object {
        /** `SupportStorageKey` in the package. Never change: devices have stored under these. */
        const val STATUS = "support.status"
        const val USAGE = "support.usage"
        const val HISTORY = "support.promptHistory"
        const val PLAN = "support.plan"

        fun log(text: String) = android.util.Log.i("Swiftly", "Unterstuetzen: $text")
    }
}

data class SupportDecision(val showsHeart: Boolean, val showsCard: Boolean, val showsSheet: Boolean, val watchedHours: Int)

/** `titleKey` is the German catalog key (`SupportCopy.tipCoffee` …). */
data class SupportTipInfo(val productId: String, val titleKey: String, val emoji: String)

/** A tip as the store sells it. `owned`: bought before; Play keeps it (acknowledged, never consumed). */
data class TipOffer(val productId: String, val price: String, val owned: Boolean)

/** A plan as the store sells it: `plan` is "monthly" or "lifetime". */
data class PlanOffer(val productId: String, val plan: String, val price: String)

/** TV panels: the ask, then the thanks. The direct build adds its own steps through `FlavorSupport`. */
enum class TvSupportPanel { Ask, Thanks, Key }

/**
 * **What a build can do to say thanks.** Implemented per flavor (`FlavorSupport.channel`).
 *
 * Play: `available` only with a working Billing connection and known products; otherwise the entry
 * points stay hidden and nothing points elsewhere. Direct: always available, no offers.
 */
private val NoPricesProblem: State<Boolean> = androidx.compose.runtime.mutableStateOf(false)

interface SupportChannel {
    val available: State<Boolean>
    /** Priced tips, smallest first; empty in the direct build. */
    val offers: State<List<TipOffer>>
    /** The monthly and lifetime plans with prices; empty in the direct build. */
    val plans: State<List<PlanOffer>>
    /** Billing works but Play delivered no prices: the sheet shows a "prices unavailable" card instead of plans. */
    val pricesUnavailable: State<Boolean> get() = NoPricesProblem
    /** Asks the store again (on start and when the app returns to the front). */
    fun connect()
    fun refresh()
    /** Starts the store's purchase flow for one tip. Does nothing in the direct build. */
    fun buy(activity: Activity, productId: String)
}

/** The activity a composable lives in, for the purchase flow. */
fun android.content.Context.findActivity(): Activity? {
    var c: android.content.Context? = this
    while (c is android.content.ContextWrapper) {
        if (c is Activity) return c
        c = c.baseContext
    }
    return null
}
