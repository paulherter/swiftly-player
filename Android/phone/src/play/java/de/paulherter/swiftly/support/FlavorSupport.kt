package de.paulherter.swiftly.support

import android.app.Activity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import de.paulherter.swiftly.SwiftlyApplication
import de.paulherter.swiftly.core.Kern
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.SecondaryButton
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.tv.TvButton
import de.paulherter.swiftly.tv.TvTheme

/**
 * **The Play build: tips through Google Play Billing.**
 *
 * Products `de.paulherter.swiftly.tip.coffee|cake|movie` (INAPP, the ids come from the package's
 * `SupportTip`), prices from `ProductDetails`. Every purchase is **acknowledged, never consumed**:
 * Play then lists it on every device of that Google account (`queryPurchasesAsync`), which is the
 * only way to get the status back after a reinstall without a server of our own. Each tip can
 * therefore be bought once. **A tip is a thank-you only**: it is confirmed and says thanks, but
 * it never changes the standing or the plan; only the subscription and the lifetime purchase do.
 *
 * Without Play (Huawei, LineageOS without GApps, an emulator without Play) the connection fails,
 * `available` stays false, and the app shows no entry point and points nowhere else. Every error
 * ends in the log, never in a crash.
 */
object FlavorSupport {
    fun channel(app: SwiftlyApplication, support: Support): SupportChannel = PlayChannel(app, support)

    /** The phone sheet: plans, tips, nothing chosen (`GrowSheet.kt`). */
    @Composable
    fun PhoneSheetBody(app: SwiftlyApplication, close: () -> Unit) = GrowSheetBody(app, close)

    /** The TV page: plans, tips, nothing chosen (`TvGrowBody`). */
    @Composable
    fun TvAskBody(app: SwiftlyApplication, close: () -> Unit, first: FocusRequester) =
        de.paulherter.swiftly.tv.TvGrowBody(app, close, first)
}

private class PlayChannel(private val app: SwiftlyApplication, private val support: Support) : SupportChannel {
    private val availableState = mutableStateOf(false)
    private val offersState = mutableStateOf<List<TipOffer>>(emptyList())
    private val plansState = mutableStateOf<List<PlanOffer>>(emptyList())
    override val plans: State<List<PlanOffer>> get() = plansState
    /** Debug builds without Play pretend to buy, so the whole flow can be tried. */
    private var simulated = false
    override val available: State<Boolean> get() = availableState
    private val pricesUnavailableState = mutableStateOf(false)
    override val pricesUnavailable: State<Boolean> get() = pricesUnavailableState
    /** Billing answered (OK); the entry stays visible even when Play delivers no prices. */
    private var connected = false
    /** How many product queries have answered (two are sent); prices count as missing only after both. */
    private var queriesAnswered = 0
    override val offers: State<List<TipOffer>> get() = offersState

    private var details: Map<String, ProductDetails> = emptyMap()
    private var owned: Set<String> = emptySet()
    /** Purchases this process started; only these say thanks (a restore at start does not). */
    private val started = mutableSetOf<String>()
    private val main = android.os.Handler(android.os.Looper.getMainLooper())

    private val listener = PurchasesUpdatedListener { result, purchases ->
        main.post {
            when (result.responseCode) {
                BillingClient.BillingResponseCode.OK -> purchases.orEmpty().forEach { handle(it, fresh = true) }
                BillingClient.BillingResponseCode.USER_CANCELED -> Support.log("Kauf abgebrochen")
                BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED -> refresh()
                else -> Support.log("Kauf: ${result.responseCode} ${result.debugMessage}")
            }
        }
    }

    private val client: BillingClient? = runCatching {
        BillingClient.newBuilder(app)
            .setListener(listener)
            .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
            .enableAutoServiceReconnection()
            .build()
    }.onFailure { Support.log("Billing nicht anlegbar: $it") }.getOrNull()

    override fun connect() {
        val c = client ?: return
        // One connection attempt at a time; Billing reconnects by itself after that.
        if (c.connectionState == BillingClient.ConnectionState.CONNECTING ||
            c.connectionState == BillingClient.ConnectionState.CONNECTED) return
        runCatching {
            c.startConnection(object : BillingClientStateListener {
                override fun onBillingSetupFinished(result: BillingResult) {
                    main.post {
                        if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                            Support.log("Billing verbunden")
                            connected = true
                            loadProducts(); refresh()
                        } else if (result.responseCode == BillingClient.BillingResponseCode.DEVELOPER_ERROR) {
                            // "Already connecting": a second attempt overlapped; the first one answers.
                            Support.log("Billing: ${result.debugMessage}")
                        } else {
                            // No Play Store, no account, or Billing unsupported: hide everything, no link.
                            Support.log("Billing nicht verfuegbar: ${result.responseCode} ${result.debugMessage}")
                            availableState.value = false
                            simulate()
                        }
                    }
                }
                override fun onBillingServiceDisconnected() {
                    Support.log("Billing getrennt")
                }
            })
        }.onFailure { Support.log("Billing-Verbindung: $it"); availableState.value = false; simulate() }
    }

    private fun loadProducts() {
        val c = client ?: return
        queriesAnswered = 0
        fun query(ids: List<String>, type: String) {
            if (ids.isEmpty()) return
            val products = ids.map { QueryProductDetailsParams.Product.newBuilder().setProductId(it).setProductType(type).build() }
            runCatching {
                c.queryProductDetailsAsync(QueryProductDetailsParams.newBuilder().setProductList(products).build()) { result, found ->
                    main.post {
                        queriesAnswered++
                        if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                            Support.log("Produkte: ${result.responseCode} ${result.debugMessage}")
                            publish()
                            return@post
                        }
                        details = details + found.productDetailsList.associateBy { it.productId }
                        Support.log("Produkte: ${details.keys.sorted()}")
                        publish()
                    }
                }
            }.onFailure { Support.log("Produkte: $it"); queriesAnswered++; publish() }
        }
        query(support.tips.map { it.productId } + LIFETIME, BillingClient.ProductType.INAPP)
        query(listOf(MONTHLY), BillingClient.ProductType.SUBS)
    }

    /** The subscription's offer for the base plan `monthly`. */
    private fun monthlyOffer(d: ProductDetails): ProductDetails.SubscriptionOfferDetails? =
        d.subscriptionOfferDetails?.firstOrNull { it.basePlanId == "monthly" } ?: d.subscriptionOfferDetails?.firstOrNull()

    private fun monthlyPrice(d: ProductDetails): String? =
        monthlyOffer(d)?.pricingPhases?.pricingPhaseList?.lastOrNull()?.formattedPrice

    private fun publish() {
        offersState.value = support.tips.mapNotNull { tip ->
            val d = details[tip.productId] ?: return@mapNotNull null
            val price = d.oneTimePurchaseOfferDetails?.formattedPrice ?: return@mapNotNull null
            TipOffer(tip.productId, price, tip.productId in owned)
        }
        plansState.value = listOfNotNull(
            details[MONTHLY]?.let { d -> monthlyPrice(d)?.let { PlanOffer(MONTHLY, "monthly", it) } },
            details[LIFETIME]?.let { d -> d.oneTimePurchaseOfferDetails?.formattedPrice?.let { PlanOffer(LIFETIME, "lifetime", it) } })
        val priced = offersState.value.isNotEmpty() || plansState.value.isNotEmpty()
        // A working Billing connection keeps the entry; missing prices show the "unavailable" card, never fake ones.
        pricesUnavailableState.value = connected && !priced && queriesAnswered >= 2
        availableState.value = priced || connected
    }

    private val allIds: Set<String> get() = support.tips.map { it.productId }.toSet() + MONTHLY + LIFETIME

    override fun refresh() {
        val c = client ?: return
        if (!c.isReady) return
        val found = mutableListOf<Purchase>()
        var failed = false
        var pending = 2
        fun done() {
            if (--pending > 0) return
            if (failed) return
            val summary = PlayPurchases.summarize(allIds, found.map {
                PlayPurchases.Seen(it.products, it.purchaseState == Purchase.PurchaseState.PURCHASED)
            })
            owned = summary.owned
            // Weakest first, so the best plan is the last word (a lifetime beats a monthly; tips unlock nothing).
            found.filterIndexed { i, _ -> i in summary.relevant }
                .sortedBy { PlayPurchases.rank(it.products) }
                .forEach { handle(it, fresh = false) }
            if (summary.statusGone) support.storeStatusGone()
            publish()
        }
        for (type in listOf(BillingClient.ProductType.INAPP, BillingClient.ProductType.SUBS)) {
            runCatching {
                c.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(type).build()) { result, purchases ->
                    main.post {
                        if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                            Support.log("Kaeufe: ${result.responseCode} ${result.debugMessage}"); failed = true
                        } else found += purchases
                        done()
                    }
                }
            }.onFailure { Support.log("Kaeufe: $it"); failed = true; done() }
        }
    }

    /** A purchase: acknowledge within three days (never consume), then the status. Pending waits. */
    private fun handle(purchase: Purchase, fresh: Boolean) {
        if (purchase.purchaseState != Purchase.PurchaseState.PURCHASED) {
            Support.log("Kauf ausstehend: ${purchase.products}")
            return
        }
        val thanks = fresh || purchase.products.any { it in started }
        val confirmed = {
            val plan = PlayPurchases.plan(purchase.products)
            if (plan.isEmpty()) {
                // A tip: thanks only, no standing and no plan.
                if (thanks) support.thanksDue.value = true
            } else {
                support.becameSupporter(Kern.supportStoreStatus(purchase.purchaseTime), fresh = thanks, plan = plan)
            }
            owned = owned + purchase.products
            purchase.products.forEach { started.remove(it) }
            publish()
        }
        if (purchase.isAcknowledged) { confirmed(); return }
        val c = client ?: return
        runCatching {
            c.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(purchase.purchaseToken).build()) { result ->
                main.post {
                    if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                        Support.log("Bestaetigt: ${purchase.products}")
                        confirmed()
                    } else {
                        // Tried again at the next start or return to the app (`refresh`), well within three days.
                        Support.log("Bestaetigung: ${result.responseCode} ${result.debugMessage}")
                    }
                }
            }
        }.onFailure { Support.log("Bestaetigung: $it") }
    }

    override fun buy(activity: Activity, productId: String) {
        if (simulated) {
            val plan = PlayPurchases.plan(listOf(productId))
            if (plan.isEmpty()) support.thanksDue.value = true
            else support.becameSupporter(Kern.supportStoreStatus(System.currentTimeMillis()), fresh = true, plan = plan)
            return
        }
        val c = client ?: return
        val d = details[productId] ?: return
        runCatching {
            started += productId
            val params = BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(d)
            if (productId == MONTHLY) {
                val token = monthlyOffer(d)?.offerToken ?: return
                params.setOfferToken(token)
            }
            val result = c.launchBillingFlow(activity, BillingFlowParams.newBuilder().setProductDetailsParamsList(listOf(params.build())).build())
            if (result.responseCode != BillingClient.BillingResponseCode.OK)
                Support.log("Kaufdialog: ${result.responseCode} ${result.debugMessage}")
        }.onFailure { Support.log("Kaufdialog: $it") }
    }

    /** Debug only: prices and a purchase without Play, so the sheets can be walked through. */
    private fun simulate() {
        if (!de.paulherter.swiftly.BuildConfig.DEBUG) return
        simulated = true
        offersState.value = support.tips.map { TipOffer(it.productId, "1,99 €", false) }
        plansState.value = listOf(PlanOffer(MONTHLY, "monthly", "1,99 €"), PlanOffer(LIFETIME, "lifetime", "19,99 €"))
        availableState.value = true
        pricesUnavailableState.value = false
    }

    companion object {
        /** Play Console: subscription `supporter` with base plan `monthly`; in-app product `supporter_lifetime`. */
        const val MONTHLY = "supporter"
        const val LIFETIME = "supporter_lifetime"
    }
}

/**
 * **What Play's purchase list means for the status**, without Billing types so a JVM test can
 * check it (`PlayPurchasesTest`). Only our products count; a pending purchase owns nothing yet.
 * `owned` includes tips (the sheet reads "Danke" for them), but a tip never keeps the status: the
 * store status goes when no plan (subscription or lifetime) is purchased any more (refund, lapse,
 * or a status an older version gave for a tip), never on an error.
 */
internal object PlayChannelIds {
    const val MONTHLY = "supporter"
    const val LIFETIME = "supporter_lifetime"
}

internal object PlayPurchases {
    data class Seen(val products: List<String>, val purchased: Boolean)
    data class Summary(val owned: Set<String>, val relevant: Set<Int>, val statusGone: Boolean)

    /** Higher is better: lifetime, then the subscription; a tip is 0 and unlocks nothing. */
    fun rank(products: List<String>): Int = when {
        PlayChannelIds.LIFETIME in products -> 2
        PlayChannelIds.MONTHLY in products -> 1
        else -> 0
    }

    /** "lifetime", "monthly", or "" for a tip: a tip has no plan. */
    fun plan(products: List<String>): String = when (rank(products)) { 2 -> "lifetime"; 1 -> "monthly"; else -> "" }

    /** The plan a set of purchases stands for: the best one; "" when there are only tips. */
    fun bestPlan(all: List<List<String>>): String = plan(all.maxByOrNull { rank(it) } ?: emptyList())

    fun summarize(tipIds: Set<String>, seen: List<Seen>): Summary {
        val relevant = seen.indices.filter { i -> seen[i].products.any { it in tipIds } }.toSet()
        val owned = relevant.filter { seen[it].purchased }.flatMap { seen[it].products }.filter { it in tipIds }.toSet()
        val plan = relevant.any { seen[it].purchased && rank(seen[it].products) > 0 }
        return Summary(owned, relevant, !plan)
    }
}
