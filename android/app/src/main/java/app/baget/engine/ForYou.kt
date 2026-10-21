package app.baget.engine

import android.graphics.Bitmap
import android.util.Base64
import app.baget.model.*
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.*
import java.util.Calendar
import kotlin.math.abs

/** A taste signal: "b:jordan" (brand), "t:suede" (trait) or "c:sneakers" (category), with how strongly it counts. */
@Serializable
data class TasteFeature(val feature: String, val weight: Double) {
    val likes: Boolean get() = weight > 0
    val label: String get() {
        val raw = feature.drop(2)
        if (feature.startsWith("c:")) return Category.of(raw)?.info?.label ?: raw.capitalizedFirst()
        if (feature.startsWith("b:")) return raw.split(" ").joinToString(" ") { it.capitalizedFirst() }
        return raw
    }
}

@Serializable
private data class ForYouRow(val listing: ListingRow, val reason: String = "", val kind: String = "match", val findId: String? = null)

enum class ForYouAction(val raw: String) { LIKE("like"), DISMISS("dismiss"), OPEN("open"), BUY("buy") }

/** Loads the feed (signed in: ranked on the server; sample: from the tour catalog). */
suspend fun AppStore.loadForYou(limit: Int = 24) {
    if (!isCloud) {
        forYou = sampleForYou(limit)
        tasteTop = sampleTaste()
        forYouLoadedAt = now()
        return
    }
    if (forYouLoading) return
    forYouLoading = true
    try {
        val (rows, taste) = coroutineScope {
            val a = async { Backend.rpc("for_you", jobj("p_limit" to limit), ListSerializer(ForYouRow.serializer())) }
            val b = async { Backend.rpc("taste_top", jobj("p_limit" to 10), ListSerializer(TasteFeature.serializer())) }
            a.await() to b.await()
        }
        for (r in rows) Catalog.cloud[r.listing.id] = r.listing.item
        val items = rows.map { ForYouItem(it.listing.id, it.reason, it.kind, it.findId) }
        if (items != forYou) forYou = items
        tasteTop = taste
        forYouLoadedAt = now()
        // Kept on the phone, with its products, so the next open shows it instantly.
        val known = state.listings.map { it.id }.toSet()
        state.listings.addAll(rows.map { it.listing.item }.filter { it.id !in known })
        state.forYou = items
        state.forYouAt = now()
        save()
    } catch (e: Exception) {
        // Keep what's on screen; if there's nothing, fall back to your own finds so the section is never blank.
        if (forYou.isEmpty()) forYou = ownFindsFeed(limit)
    } finally {
        forYouLoading = false
    }
}

/** Like, "not for me", or open. Each one teaches the ranking; a like also saves it to Finds under the agent that fits. */
fun AppStore.reactForYou(pick: ForYouItem, action: ForYouAction) {
    Analytics.track(when (action) { ForYouAction.LIKE -> AnalyticsEvent.FIND_LIKED; ForYouAction.DISMISS -> AnalyticsEvent.FIND_PASSED; else -> AnalyticsEvent.CHECKOUT_OPENED },
        mapOf("from" to "for_you", "kind" to pick.kind))
    if (action == ForYouAction.LIKE || action == ForYouAction.DISMISS) forYou = forYou.filter { it.id != pick.id }
    if (isCloud) {
        val row = jobj("listing_id" to pick.id, "action" to action.raw)
        push { it.raw("POST", "/rest/v1/feed_reactions", json = row, prefer = "return=minimal,resolution=ignore-duplicates") }
    } else if (action == ForYouAction.DISMISS) forYouDismissed.add(pick.id)
    val item = Catalog.item(pick.id) ?: return
    when (action) {
        ForYouAction.LIKE -> {
            pick.findID?.let { like(it); return }
            val a = best(item)?.first ?: state.agents.firstOrNull { Matcher.covers(it, item) } ?: state.agents.firstOrNull { it.mission.category == item.category }
            if (a != null) ensureFind(a.id, item.id, pick.reason)?.let { like(it.id) }
        }
        ForYouAction.DISMISS -> pick.findID?.let { pass(it, PassReason.STYLE) }
        else -> {}
    }
    if (forYou.size < 6) scope.launch { loadForYou() }   // keep the feed full
    save()
}

/** Your own open and liked finds, as a last resort. */
fun AppStore.ownFindsFeed(limit: Int): List<ForYouItem> =
    state.finds.filter { (it.status == FindStatus.OPEN || it.status == FindStatus.LIKED) && Catalog.item(it.itemID) != null }
        .sortedByDescending { it.score }.take(limit)
        .map { ForYouItem(it.itemID, "From your finds", "yours", it.id) }

/** The sample tour: rank the tour catalog with the same matcher the agents use, shuffled a little each day. */
private fun AppStore.sampleForYou(limit: Int): List<ForYouItem> {
    val found = state.finds.map { it.itemID }.toSet()
    val day = Calendar.getInstance().get(Calendar.DAY_OF_YEAR)
    fun jitter(id: String) = abs((id + day).hashCode() % 100) / 100.0
    data class R(val item: Item, val rank: Double, val reason: String, val matched: Boolean)
    val ranked = Catalog.items.filter { it.id !in found && it.id !in forYouDismissed }.map { item ->
        val b = best(item)
        if (b != null) R(item, b.second.score / 20.0 + jitter(item.id), b.second.why.firstOrNull() ?: "Fits your taste", true)
        else R(item, jitter(item.id), "Something new to try", false)
    }.sortedByDescending { it.rank }
    val out = mutableListOf<ForYouItem>()
    val matched = ranked.filter { it.matched }.iterator()
    val other = ranked.filter { !it.matched }.iterator()
    while (out.size < limit) {
        val next = if ((out.size + 1) % 5 == 0) (if (other.hasNext()) other.next() else if (matched.hasNext()) matched.next() else null)
                   else (if (matched.hasNext()) matched.next() else if (other.hasNext()) other.next() else null)
        next ?: break
        out.add(ForYouItem(next.item.id, next.reason, if (next.matched) "match" else "explore"))
    }
    return out.ifEmpty { ownFindsFeed(limit) }
}

private fun AppStore.sampleTaste(): List<TasteFeature> {
    val w = mutableMapOf<String, Double>()
    for (a in state.agents) {
        for (m in a.style.makers) w["b:" + m.lowercase()] = (w["b:" + m.lowercase()] ?: 0.0) + 2
        for (t in a.style.traits) w["t:" + t.lowercase()] = (w["t:" + t.lowercase()] ?: 0.0) + 1.5
        for ((k, v) in a.learned) w["t:" + k.lowercase()] = (w["t:" + k.lowercase()] ?: 0.0) + v
    }
    return w.filter { abs(it.value) >= 1 }.entries.sortedByDescending { abs(it.value) }.take(10).map { TasteFeature(it.key, it.value) }
}

// MARK: Deals: a one-glance answer to "is this a good price?"

data class DealVerdict(val level: Level, val title: String, val detail: String) {
    enum class Level { GREAT, FAIR, WAIT, INFO }
    val emoji: String get() = when (level) { Level.GREAT -> "🟢"; Level.FAIR -> "🟡"; Level.WAIT -> "🔴"; Level.INFO -> "🏷️" }

    companion object {
        fun of(item: Item): DealVerdict? {
            val p = if (item.priceKnown) item.price else 0.0
            val low = item.lowPrice ?: 0.0
            val store = item.lowStore ?: "another store"
            val others = (item.offers ?: emptyList()).size
            val hasMarket = item.market > 0 && item.market != item.price
            if (p <= 0) return if (low > 0) DealVerdict(Level.INFO, "From ${Fmt.money(low)}", "at $store") else null
            if (low > 0 && low < p * 0.95 && !sameStore(store, item.source))
                return DealVerdict(Level.WAIT, "Cheaper elsewhere", "${Fmt.money(low)} at $store, ${safeRound((1 - low / p) * 100)}% less")
            if (hasMarket && item.market > p * 1.15)
                return DealVerdict(Level.GREAT, "Great deal", "${safeRound((item.market / p - 1) * 100)}% under resale (${Fmt.money(item.market)})")
            if (others >= 2 && (low == 0.0 || low >= p * 0.98)) return DealVerdict(Level.GREAT, "Best price", "Lowest of ${others + 1} stores")
            if (hasMarket && item.market < p * 0.9) return DealVerdict(Level.WAIT, "Over resale", "Goes for about ${Fmt.money(item.market)} secondhand")
            if (others > 0 || hasMarket) return DealVerdict(Level.FAIR, "Fair price",
                if (others > 0) "In line with $others other store${if (others == 1) "" else "s"}" else "Around resale value")
            return null
        }

        private fun sameStore(a: String, b: String): Boolean {
            val x = a.lowercase(); val y = b.lowercase()
            return x.isNotEmpty() && y.isNotEmpty() && (x.contains(y) || y.contains(x))
        }
    }
}

/** Where an item can actually be bought: its own https page, never a search page. */
object BuyLink {
    fun url(item: Item): String? {
        if (item.isSample) return null
        val s = item.url ?: return null
        if (!s.startsWith("https://")) return null
        val u = runCatching { java.net.URI(s) }.getOrNull() ?: return null
        val host = u.host ?: return null
        val q = (u.rawQuery ?: "").lowercase()
        val path = (u.path ?: "").lowercase()
        if (listOf("_nkw=", "q=", "query=", "keyword=", "k=", "search=").any { q.startsWith(it) || q.contains("&$it") }) return null
        if (path.contains("/search") || path.contains("/sch/") || path.isEmpty() || path == "/") return null
        if (host.contains("ebay.") && !path.startsWith("/itm/")) return null
        return s
    }

    /** Through Baget's "go" redirect when signed in (logs the tap, adds affiliate tracking), else the store page itself. */
    fun tracked(item: Item, from: String): String? {
        val direct = url(item) ?: return null
        val base = Backend.baseURL
        if (!Backend.isSignedIn || base == null || !Regex("^[0-9a-fA-F-]{36}$").matches(item.id)) return direct
        val u = Backend.userID?.let { "&u=$it" } ?: ""
        return "$base/functions/v1/go?l=${item.id}&s=$from$u"
    }
}

// MARK: Hunting, setup and the taste check

data class HuntResult(val agentID: String, val intro: String, val needsSize: Boolean)

/** "What are you hunting?" One sentence in, a ready agent out. */
suspend fun AppStore.hunt(text: String): HuntResult? {
    val t = text.trim()
    if (t.length < 2) return null
    Analytics.track(AnalyticsEvent.HUNT_STARTED, mapOf("words" to t.split(" ").size))
    if (!isCloud) {
        val a = Agent(uuid(), "${t.capitalizedFirst()} Hunter".take(40), Mission.Custom(t.take(80)))
        deploy(a)
        return HuntResult(a.id, "I'm on it. I'll text you when I find something.", false)
    }
    if (squadFull) { syncProblem = scoutLimitMessage; return null }
    return try {
        val r = Backend.function("hunt", jobj("text" to t)).jsonObject
        pull()
        val id = r["agent_id"]?.jsonPrimitive?.contentOrNull ?: return null
        scope.launch { cloudSweep(id) }
        HuntResult(id, r["intro"]?.jsonPrimitive?.contentOrNull?.ifEmpty { null } ?: "I'm on it.", r["needs_size"]?.jsonPrimitive?.booleanOrNull ?: false)
    } catch (e: Exception) {
        syncProblem = (e as? BackendError)?.message ?: "Couldn't start that hunt. Try again."
        null
    }
}

/** First-run setup: interests, an optional sentence and up to three photos -> a squad, already searching. */
suspend fun AppStore.onboard(categories: List<Category>, text: String, photos: List<Bitmap>, liked: List<String> = emptyList(),
                             passed: List<String> = emptyList(), vibes: Map<Category, List<String>> = emptyMap(), budget: Int? = null,
                             brands: Map<Category, List<String>> = emptyMap(), interests: List<String> = emptyList()): List<String> {
    Analytics.track(AnalyticsEvent.ONBOARDING_DONE, mapOf("categories" to categories.size, "photos" to photos.size, "text" to text.isNotEmpty(),
        "rated" to liked.size + passed.size))
    if (!isCloud) {
        for (c in categories) deploy(Agent(uuid(), "${c.info.label} Scout", Mission.Cat(c)))
        for (i in interests) deploy(Agent(uuid(), "${i.split(" ").first()} Scout", Mission.Custom(i.lowercase())))
        return state.agents.map { it.id }
    }
    val images = photos.take(3).map { mapOf("media_type" to "image/jpeg", "data" to Base64.encodeToString(Images.jpeg(Images.scaled(it, 1024), 75), Base64.NO_WRAP)) }
    return try {
        val body = mutableMapOf<String, Any?>("categories" to categories.map { it.raw }, "text" to text, "images" to images,
            "liked" to liked, "passed" to passed, "vibes" to vibes.filter { it.value.isNotEmpty() }.mapKeys { it.key.raw })
        if (budget != null) body["budget"] = budget
        if (interests.isNotEmpty()) body["interests"] = interests
        val picks = brands.filter { it.value.isNotEmpty() }
        if (picks.isNotEmpty()) body["brands"] = picks.mapKeys { it.key.raw }
        val r = Backend.function("hunt", toJson(body)).jsonObject
        pull()
        scope.launch { cloudSweep() }
        (r["agents"] as? JsonArray)?.mapNotNull { (it as? JsonObject)?.get("agent_id")?.jsonPrimitive?.contentOrNull } ?: emptyList()
    } catch (e: Exception) {
        syncProblem = (e as? BackendError)?.message ?: "Couldn't set up your squad. Try again."
        emptyList()
    }
}

/** Setup's quick taste check: real products in the picked categories, one per brand, photos only. */
suspend fun AppStore.tasteQuiz(categories: List<Category>): List<Item> {
    if (!isCloud) {
        val cats = categories.toSet()
        val brands = mutableSetOf<String>()
        return Catalog.items.filter { (cats.isEmpty() || it.category in cats) && brands.add(it.brand) }.take(10)
    }
    val rows = runCatching { Backend.rpc("taste_quiz", jobj("p_categories" to categories.map { it.raw }, "p_limit" to 10), ListSerializer(ListingRow.serializer())) }
        .getOrDefault(emptyList())
    for (r in rows) Catalog.cloud[r.id] = r.item
    return rows.map { it.item }.take(10)
}

/** Records a taste-check answer so For You is personal from the first minute. */
fun AppStore.rateInQuiz(item: Item, liked: Boolean) {
    if (!isCloud) return
    val row = jobj("listing_id" to item.id, "action" to if (liked) "like" else "dismiss")
    push { it.raw("POST", "/rest/v1/feed_reactions", json = row, prefer = "return=minimal,resolution=ignore-duplicates") }
}

/** "Watch it for me": the agent re-prices it twice a day and texts on a drop, restock or release. */
fun AppStore.toggleWatch(findID: String) {
    val f = state.finds.firstOrNull { it.id == findID } ?: return
    val item = Catalog.item(f.itemID) ?: return
    if (f.watching) {
        f.watching = false
        push { it.update("finds", "id=eq.$findID", jobj("watching" to false)) }
        save()
        return
    }
    f.watching = true
    val patch = mutableMapOf<String, Any?>("watching" to true)
    if (item.priceKnown && item.price > 0) patch["watch_price"] = item.price
    push { it.update("finds", "id=eq.$findID", toJson(patch).jsonObject) }
    learn(f.agentID, item, 1)
    Analytics.track(AnalyticsEvent.FIND_WATCHED, mapOf("category" to item.category.raw))
    save()
}

/** Removes something an agent learned or was told (a brand, style, keyword, creator, or the size). */
fun AppStore.removeTaste(agentID: String, value: String) {
    val a = agent(agentID) ?: return
    val n = TextMatch.norm(value)
    a.style.traits.removeAll { TextMatch.norm(it) == n }
    a.style.makers.removeAll { TextMatch.norm(it) == n }
    a.style.creators.removeAll { TextMatch.norm(it) == n }
    a.keywords.removeAll { TextMatch.norm(it) == n }
    a.learned.remove(n)
    if (TextMatch.norm(a.size) == n) a.size = ""
    if (value == "__price") a.priceNote = 0.0
    Analytics.track(AnalyticsEvent.TASTE_REMOVED)
    save()
    pushAgent(agentID)
}

/** Today's best: open finds from the last few days, strongest first. */
fun AppStore.todaysPicks(n: Int = 5): List<Find> {
    val since = now() - 4 * 86_400_000L
    val fresh = state.finds.filter { it.status == FindStatus.OPEN && it.foundAt > since && Catalog.item(it.itemID)?.showable == true }
    val pool = fresh.ifEmpty { state.finds.filter { it.status == FindStatus.OPEN && Catalog.item(it.itemID)?.showable == true } }
    return pool.sortedWith(compareByDescending<Find> { it.score }.thenByDescending { it.foundAt }).take(n)
}

/** Open finds to swipe through, best first, 10 at a time. */
const val SWIPE_ROUND = 10
val AppStore.swipeQueue: List<Find>
    get() = state.finds.filter { it.status == FindStatus.OPEN && Catalog.item(it.itemID)?.showable == true }
        .sortedWith(compareByDescending<Find> { it.score }.thenByDescending { it.foundAt }).take(SWIPE_ROUND)
