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
 * therefore be bought once.
 *
 * Without Play (Huawei, LineageOS without GApps, an emulator without Play) the connection fails,
 * `available` stays false, and the app shows no entry point and points nowhere else. Every error
 * ends in the log, never in a crash.
 */
object FlavorSupport {
    fun channel(app: SwiftlyApplication, support: Support): SupportChannel = PlayChannel(app, support)

    /** The phone sheet: intro, the three tips, nothing chosen; "Maybe later" as large as "Support". */
    @Composable
    fun PhoneSheetBody(app: SwiftlyApplication, close: () -> Unit) {
        val support = app.support
        val offers = support.channel.offers.value
        var chosen by remember { mutableStateOf<String?>(null) }
        val activity = LocalContext.current.findActivity()
        Column {
            SupportMark()
            SheetText(translated("Wir bauen Swiftly ohne Werbung und ohne Tracking. Wenn es deine Abende besser macht, hilft uns ein Kaffee, weiterzumachen."))
            Column(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing).padding(top = 16.dp),
                   verticalArrangement = Arrangement.spacedBy(8.dp)) {
                support.tips.forEach { tip ->
                    val offer = offers.firstOrNull { it.productId == tip.productId } ?: return@forEach
                    TipChoice(tip.emoji, support.tipTitle(tip), offer.price, chosen == tip.productId, offer.owned) {
                        chosen = tip.productId
                    }
                }
            }
            SheetText(translated("Alles bleibt für alle kostenlos."), quiet = false, top = 14.dp)
            SheetText(translated("Als Dankeschön bekommst du ein Herz in „Über“ und zusätzliche App-Icons."), small = true, top = 4.dp)
            val price = offers.firstOrNull { it.productId == chosen }?.price
            Column(Modifier.fillMaxWidth().padding(horizontal = Theme.edgeSpacing).padding(top = 18.dp),
                   verticalArrangement = Arrangement.spacedBy(10.dp)) {
                PrimaryButton(if (price != null) translated("Mit %@ unterstützen", price) else translated("Unterstützen"),
                              released = price != null && activity != null, lockedArea = Theme.raised) {
                    val id = chosen ?: return@PrimaryButton
                    close()
                    activity?.let { support.channel.buy(it, id) }
                }
                SecondaryButton(translated("Vielleicht später"), action = close)
            }
            SheetText(translated("Einmaliger Kauf über deinen App-Store. Nichts verlängert sich."), small = true, center = true, top = 10.dp)
            Spacer(Modifier.height(16.dp))
        }
    }

    /** The TV panel: the tips as buttons in a row; each opens Play's own purchase dialog. */
    @Composable
    fun TvAskBody(app: SwiftlyApplication, close: () -> Unit, first: FocusRequester) {
        val support = app.support
        val offers = support.channel.offers.value
        val activity = LocalContext.current.findActivity()
        Row(Modifier.padding(top = 28.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            support.tips.forEachIndexed { i, tip ->
                val offer = offers.firstOrNull { it.productId == tip.productId } ?: return@forEachIndexed
                TvButton("${tip.emoji}  ${support.tipTitle(tip)} · ${if (offer.owned) translated("Danke") else offer.price}",
                         released = !offer.owned,
                         modifier = if (i == 0) Modifier.focusRequester(first) else Modifier) {
                    close()
                    activity?.let { support.channel.buy(it, tip.productId) }
                }
            }
        }
        Text(translated("Alles bleibt für alle kostenlos."), style = TvTheme.body, color = Theme.font,
             modifier = Modifier.padding(top = 24.dp))
        Text(translated("Einmaliger Kauf über deinen App-Store. Nichts verlängert sich."), style = TvTheme.small,
             color = Theme.fontVeryQuiet, modifier = Modifier.padding(top = 4.dp))
        TvButton(translated("Vielleicht später"), modifier = Modifier.padding(top = 24.dp), perform = close)
    }
}

private class PlayChannel(private val app: SwiftlyApplication, private val support: Support) : SupportChannel {
    private val availableState = mutableStateOf(false)
    private val offersState = mutableStateOf<List<TipOffer>>(emptyList())
    override val available: State<Boolean> get() = availableState
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
                            loadProducts(); refresh()
                        } else if (result.responseCode == BillingClient.BillingResponseCode.DEVELOPER_ERROR) {
                            // "Already connecting": a second attempt overlapped; the first one answers.
                            Support.log("Billing: ${result.debugMessage}")
                        } else {
                            // No Play Store, no account, or Billing unsupported: hide everything, no link.
                            Support.log("Billing nicht verfuegbar: ${result.responseCode} ${result.debugMessage}")
                            availableState.value = false
                        }
                    }
                }
                override fun onBillingServiceDisconnected() {
                    Support.log("Billing getrennt")
                }
            })
        }.onFailure { Support.log("Billing-Verbindung: $it"); availableState.value = false }
    }

    private fun loadProducts() {
        val c = client ?: return
        val products = support.tips.map {
            QueryProductDetailsParams.Product.newBuilder().setProductId(it.productId)
                .setProductType(BillingClient.ProductType.INAPP).build()
        }
        if (products.isEmpty()) return
        runCatching {
            c.queryProductDetailsAsync(QueryProductDetailsParams.newBuilder().setProductList(products).build()) { result, found ->
                main.post {
                    if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                        Support.log("Produkte: ${result.responseCode} ${result.debugMessage}")
                        return@post
                    }
                    details = found.productDetailsList.associateBy { it.productId }
                    Support.log("Produkte: ${details.keys.sorted()}")
                    publish()
                }
            }
        }.onFailure { Support.log("Produkte: $it") }
    }

    private fun publish() {
        offersState.value = support.tips.mapNotNull { tip ->
            val d = details[tip.productId] ?: return@mapNotNull null
            val price = d.oneTimePurchaseOfferDetails?.formattedPrice ?: return@mapNotNull null
            TipOffer(tip.productId, price, tip.productId in owned)
        }
        availableState.value = offersState.value.isNotEmpty()
    }

    override fun refresh() {
        val c = client ?: return
        if (!c.isReady) return
        runCatching {
            c.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.INAPP).build()) { result, purchases ->
                main.post {
                    if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                        Support.log("Kaeufe: ${result.responseCode} ${result.debugMessage}"); return@post
                    }
                    val summary = PlayPurchases.summarize(support.tips.map { it.productId }.toSet(),
                        purchases.map { PlayPurchases.Seen(it.products, it.purchaseState == Purchase.PurchaseState.PURCHASED) })
                    purchases.filterIndexed { i, _ -> i in summary.relevant }.forEach { handle(it, fresh = false) }
                    owned = summary.owned
                    if (summary.statusGone) support.storeStatusGone()
                    publish()
                }
            }
        }.onFailure { Support.log("Kaeufe: $it") }
    }

    /** A purchase: acknowledge within three days (never consume), then the status. Pending waits. */
    private fun handle(purchase: Purchase, fresh: Boolean) {
        if (purchase.purchaseState != Purchase.PurchaseState.PURCHASED) {
            Support.log("Kauf ausstehend: ${purchase.products}")
            return
        }
        val thanks = fresh || purchase.products.any { it in started }
        val confirmed = {
            support.becameSupporter(Kern.supportStoreStatus(purchase.purchaseTime), fresh = thanks)
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
        val c = client ?: return
        val d = details[productId] ?: return
        runCatching {
            started += productId
            val result = c.launchBillingFlow(activity, BillingFlowParams.newBuilder().setProductDetailsParamsList(listOf(
                BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(d).build())).build())
            if (result.responseCode != BillingClient.BillingResponseCode.OK)
                Support.log("Kaufdialog: ${result.responseCode} ${result.debugMessage}")
        }.onFailure { Support.log("Kaufdialog: $it") }
    }
}

/**
 * **What Play's purchase list means for the status**, without Billing types so a JVM test can
 * check it (`PlayPurchasesTest`). Only our tip products count; a pending purchase owns nothing yet;
 * the store status goes only when no tip is purchased any more (refund), never on an error.
 */
internal object PlayPurchases {
    data class Seen(val products: List<String>, val purchased: Boolean)
    data class Summary(val owned: Set<String>, val relevant: Set<Int>, val statusGone: Boolean)

    fun summarize(tipIds: Set<String>, seen: List<Seen>): Summary {
        val relevant = seen.indices.filter { i -> seen[i].products.any { it in tipIds } }.toSet()
        val owned = relevant.filter { seen[it].purchased }.flatMap { seen[it].products }.filter { it in tipIds }.toSet()
        return Summary(owned, relevant, owned.isEmpty())
    }
}
