package app.baget.engine

import android.app.Activity
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
import com.android.billingclient.api.acknowledgePurchase
import com.android.billingclient.api.queryProductDetails
import com.android.billingclient.api.queryPurchasesAsync
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonPrimitive
import java.util.Calendar

/** Your plan, as the server sees it. */
@Serializable
data class PlanInfo(
    val plan: String = "free",          // free, pro, comp
    val pro: Boolean = false,
    val proUntil: String? = null,
    val huntStart: Int = 9,
    val hours: Int = 4,
    val huntingNow: Boolean = false,
    /** How many scouts the plan includes (Free 2, Pro 5). */
    val scouts: Int? = null,
) {
    /** "9am to 1pm" */
    val windowLabel: String get() = "${hourLabel(huntStart)} to ${hourLabel((huntStart + hours) % 24)}"

    /** Minutes until the window opens (when resting) or closes (when hunting), in local time. */
    fun minutesToChange(): Int {
        val c = Calendar.getInstance()
        val h = c.get(Calendar.HOUR_OF_DAY); val m = c.get(Calendar.MINUTE)
        val sinceStart = (((h - huntStart) % 24 + 24) % 24) * 60 + m
        return if (huntingNow) maxOf(0, hours * 60 - sinceStart) else maxOf(0, 24 * 60 - sinceStart)
    }

    companion object {
        fun hourLabel(h: Int): String {
            val x = ((h % 24) + 24) % 24
            return "${if (x % 12 == 0) 12 else x % 12}${if (x < 12) "am" else "pm"}"
        }
    }
}

const val TERMS_URL = "https://play.google.com/intl/en_us/about/play-terms/"
const val PRIVACY_URL = "https://github.com/Lwhite15/Baget-12/blob/main/PRIVACY.md"
val PRO_PRODUCT_IDS = listOf("baget.pro.monthly", "baget.pro.yearly")

val AppStore.isPro: Boolean get() = plan?.pro ?: false

/** How many scouts this account may have: Free 2, Pro 5 (the sample tour: no limit to speak of). */
val AppStore.scoutLimit: Int get() = if (isCloud) (plan?.scouts ?: if (isPro) 5 else 2) else 12
val AppStore.squadFull: Boolean get() = state.agents.size >= scoutLimit
val AppStore.scoutLimitMessage: String
    get() = if (isPro) "Pro includes up to $scoutLimit scouts. Retire one to add another." else "Free includes 2 scouts. Go Pro for up to 5."

suspend fun AppStore.loadPlan() {
    if (!isCloud) { plan = null; return }
    runCatching { Backend.rpc("my_plan", JsonObject(emptyMap()), PlanInfo.serializer()) }.getOrNull()?.let { plan = it }
}

/** Free plan: when the daily 4-hour hunting window starts (local hour). */
fun AppStore.setHuntStart(hour: Int) {
    state.settings.huntStart = ((hour % 24) + 24) % 24
    save()
    scope.launch {
        kotlinx.coroutines.delay(1500)   // let the settings sync land first
        loadPlan()
    }
}

/**
 * Baget Pro through Google Play Billing. Every purchase is tied to the Baget account (obfuscated account id),
 * checked by the server with Google, then Pro turns on. Acknowledged only after the server accepts it.
 */
object Billing : PurchasesUpdatedListener {
    var products by mutableStateOf<List<ProductDetails>>(emptyList())
        private set
    private var client: BillingClient? = null
    private var pending: CompletableDeferred<String?>? = null

    private suspend fun connected(): BillingClient? {
        val c = client ?: BillingClient.newBuilder(AppStore.context)
            .setListener(this)
            .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
            .enableAutoServiceReconnection()
            .build().also { client = it }
        if (c.isReady) return c
        val done = CompletableDeferred<Boolean>()
        c.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(r: BillingResult) { done.complete(r.responseCode == BillingClient.BillingResponseCode.OK) }
            override fun onBillingServiceDisconnected() { if (!done.isCompleted) done.complete(false) }
        })
        return if (done.await()) c else null
    }

    /** "7-day" when this plan has a free trial this Google account can still start; null otherwise (Play only offers eligible trials). */
    fun trial(p: ProductDetails?): String? {
        if (p == null || AppStore.isPro) return null
        val phase = trialOffer(p)?.pricingPhases?.pricingPhaseList?.firstOrNull() ?: return null
        val m = Regex("^P(\\d+)([DWMY])$").find(phase.billingPeriod) ?: return null
        val n = m.groupValues[1].toInt() * maxOf(1, phase.billingCycleCount)
        return when (m.groupValues[2]) {
            "D" -> "$n-day"; "W" -> "${n * 7}-day"; "M" -> if (n == 1) "1-month" else "$n-month"; else -> "1-year"
        }
    }

    private fun trialOffer(p: ProductDetails) = p.subscriptionOfferDetails?.firstOrNull { o ->
        o.pricingPhases.pricingPhaseList.firstOrNull()?.priceAmountMicros == 0L
    }

    /** "7-day" -> "7 days". */
    fun spoken(t: String): String {
        val parts = t.split("-")
        val n = parts.getOrNull(0)?.toIntOrNull() ?: return t
        return "$n ${parts.getOrElse(1) { "" }}${if (n == 1) "" else "s"}"
    }

    /** The trial on offer for the yearly plan (what setup and the badges talk about). */
    val proTrial: String? get() = trial(products.firstOrNull { it.productId == "baget.pro.yearly" } ?: products.firstOrNull())

    suspend fun loadProducts() {
        if (products.isNotEmpty()) return
        val c = connected() ?: return
        val params = QueryProductDetailsParams.newBuilder().setProductList(PRO_PRODUCT_IDS.map {
            QueryProductDetailsParams.Product.newBuilder().setProductId(it).setProductType(BillingClient.ProductType.SUBS).build()
        }).build()
        val r = c.queryProductDetails(params)
        products = (r.productDetailsList ?: emptyList()).sortedBy { if (it.productId.endsWith("monthly")) 0 else 1 }
    }

    /** Buys Pro. Returns what to tell the person, or null when there's nothing to say. */
    suspend fun buy(activity: Activity, product: ProductDetails): String? {
        val store = AppStore
        val uid = Backend.userID
        if (!store.isCloud || uid == null) return "Sign in to go Pro."
        val c = connected() ?: return "Google Play isn't available right now. Try again in a minute."
        val offer = (trialOffer(product) ?: product.subscriptionOfferDetails?.firstOrNull())?.offerToken ?: return "That plan isn't available right now."
        store.purchasing = true
        try {
            val flow = BillingFlowParams.newBuilder()
                .setProductDetailsParamsList(listOf(BillingFlowParams.ProductDetailsParams.newBuilder()
                    .setProductDetails(product).setOfferToken(offer).build()))
                .setObfuscatedAccountId(uid)
                .build()
            pending = CompletableDeferred()
            val r = c.launchBillingFlow(activity, flow)
            if (r.responseCode != BillingClient.BillingResponseCode.OK) return "The purchase didn't go through. ${r.debugMessage}"
            return pending?.await()
        } finally {
            pending = null
            store.purchasing = false
        }
    }

    override fun onPurchasesUpdated(result: BillingResult, purchases: MutableList<Purchase>?) {
        AppStore.scope.launch {
            val msg: String? = when (result.responseCode) {
                BillingClient.BillingResponseCode.OK -> {
                    var m: String? = null
                    for (p in purchases ?: emptyList()) m = handle(p) ?: m
                    AppStore.loadPlan()
                    Analytics.track(AnalyticsEvent.PURCHASE_CONFIRMED, mapOf("pro" to (purchases?.firstOrNull()?.products?.firstOrNull() ?: "")))
                    m
                }
                BillingClient.BillingResponseCode.USER_CANCELED -> null
                BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED -> { sync(); "You already have Pro. Restored it." }
                else -> "The purchase didn't go through. ${result.debugMessage}"
            }
            pending?.complete(msg)
        }
    }

    /** Sends a purchase to the server; acknowledges it once Pro is on. */
    private suspend fun handle(p: Purchase): String? {
        if (p.purchaseState == Purchase.PurchaseState.PENDING) return "Your purchase is waiting for approval."
        if (p.purchaseState != Purchase.PurchaseState.PURCHASED) return null
        val product = p.products.firstOrNull { it in PRO_PRODUCT_IDS } ?: return null
        val reply = try {
            Backend.function("subscription", jobj("platform" to "android", "product_id" to product, "purchase_token" to p.purchaseToken,
                "package_name" to AppStore.context.packageName))
        } catch (e: Exception) {
            return (e as? BackendError)?.message ?: "Couldn't confirm the purchase. Try Restore in a minute."
        }
        if (!p.isAcknowledged) {
            client?.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(p.purchaseToken).build())
        }
        val pro = (reply as? JsonObject)?.get("pro")?.jsonPrimitive?.booleanOrNull
        return if (pro == true) null else "That subscription has ended."
    }

    /** On launch and Restore: sends current subscriptions to the server, so renewals and cancellations stay accurate. */
    suspend fun sync() {
        if (!AppStore.isCloud) return
        val c = connected() ?: return
        val r = c.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build())
        for (p in r.purchasesList) if (p.products.any { it in PRO_PRODUCT_IDS }) handle(p)
    }

    suspend fun restore(): String {
        sync()
        AppStore.loadPlan()
        return if (AppStore.isPro) "Pro restored." else "No Baget Pro subscription found for this Google account."
    }
}
