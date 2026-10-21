package app.baget.engine

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.baget.model.*
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Calendar
import kotlin.math.max
import kotlin.math.min

data class Story(
    val item: Item, val kind: String, val headline: String, val dek: String, val minutesAgo: Int,
    val agentID: String?, val match: Match?, val isLive: Boolean,
) {
    val id: String get() = item.id
    val forYou: Boolean get() = (match?.score ?: 0) >= 60 && match?.notInSize != true
    val score: Int get() = match?.score ?: 12
}

data class FriendTake(val text: String, val caution: Boolean)

enum class PassReason(val label: String) {
    STYLE("Not my style"), PRICE("Too pricey"), OWN("Have one like it"), LATER("Just not now");
}

/**
 * Everything the app knows and does. One instance, on the main thread.
 * Screens read `tick` (through `observe()`) so any change to the state redraws them.
 */
object AppStore {
    lateinit var context: Context
        private set
    val scope = MainScope()

    var state: AppState = AppState()
    /** Bumped on every change, so Compose redraws whatever read it. */
    var tick by mutableIntStateOf(0)
        private set

    /** In-app banner (the phone-style notification shown while the app is open). */
    var banner by mutableStateOf<AppNote?>(null)
    /** Set when you tap a system notification; the root view opens it. */
    var openNoteFromSystem by mutableStateOf<String?>(null)
    /** A sync problem to tell the person about (shown as a toast, then cleared). */
    var syncProblem by mutableStateOf<String?>(null)
    /** The agent whose chat is waiting on a reply. */
    var chatBusy by mutableStateOf<String?>(null)
    /** The Today screen's personal feed, best first, and the strongest taste signals behind it. */
    var forYou by mutableStateOf<List<ForYouItem>>(emptyList())
    var tasteTop by mutableStateOf<List<TasteFeature>>(emptyList())
    var forYouLoading = false
    var forYouLoadedAt by mutableStateOf<Long?>(null)
    val forYouDismissed = mutableSetOf<String>()
    /** Free or Pro, and (Free) whether the scouts are in their hunting window. Null until loaded or when not signed in. */
    var plan by mutableStateOf<PlanInfo?>(null)
    var purchasing by mutableStateOf(false)
    /** Owner accounts see the Stats screen (the server decides; the screen's data is admin-only too). */
    var isAdmin by mutableStateOf(false)
    /** Bumped when a taste photo or icon photo finishes downloading, so boards redraw. */
    var photoVersion by mutableIntStateOf(0)
    var avatarVersion by mutableIntStateOf(0)
    var pushRegistered = false
    internal var pulling = false
    internal var lastSettingsSnapshot: String? = null
    internal val downloading = mutableSetOf<String>()
    private var saveJob: Job? = null

    private val stateFile: File get() = File(context.filesDir, "baget-state.json")

    fun init(ctx: Context) {
        context = ctx.applicationContext
        Backend.init(context)
        val saved = runCatching { plainJson.decodeFromString(AppState.serializer(), stateFile.readText()) }.getOrNull()
        state = saved ?: AppState()
        if (Backend.isSignedIn) {
            if (state.accountID != Backend.userID) {
                // Signed in, but this saved data belongs to someone else or to the sample tour: start clean.
                state = AppState().also { it.accountID = Backend.userID }
            }
            Catalog.cloud = state.listings.associateBy { it.id }.toMutableMap()
            Catalog.useCloud = true
            forYou = state.forYou
            forYouLoadedAt = state.forYouAt
        } else {
            if (state.accountID != null) state = AppState()      // session ended
            Catalog.useCloud = false
            if (!Backend.isConfigured) state.exploringSamples = true   // no server yet: the sample tour is the app
            if (state.exploringSamples && state.agents.isEmpty() && state.purchases.isEmpty()) seed()
        }
        lastSettingsSnapshot = settingsSnapshot()
    }

    /** Read this from a composable to redraw when anything changes. */
    fun observe(): AppState { tick; return state }

    /** Whether to show the welcome screen (sign in, or look around with samples). */
    val needsWelcome: Boolean get() { tick; return Backend.isConfigured && !isCloud && !state.exploringSamples }

    /** Saves to the phone in the background: a burst of changes becomes one write, and the screen never waits on it. */
    fun save() {
        syncSettingsIfChanged()
        tick++
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(400)
            saveNow()
        }
    }

    /** Writes right away (used when the app goes to the background). */
    fun saveNow() {
        val text = runCatching { plainJson.encodeToString(AppState.serializer(), state) }.getOrNull() ?: return
        val file = stateFile
        scope.launch(Dispatchers.IO) {
            runCatching {
                val tmp = File(file.parentFile, file.name + ".tmp")
                tmp.writeText(text)
                tmp.renameTo(file)
            }
        }
    }

    // MARK: Availability

    fun dropDate(item: Item): Long = item.dropAt ?: (state.catalogStart + (item.dropOffset * 60_000).toLong())
    fun isSoldOut(item: Item): Boolean = item.soldOutAtStart && item.id !in state.restockedItemIDs
    fun isLive(item: Item): Boolean = !isSoldOut(item) && dropDate(item) <= now()

    fun whenLabel(item: Item): String {
        if (isSoldOut(item)) return "RESTOCK WATCH"
        val m = (dropDate(item) - now()) / 60000.0
        return when {
            m <= 0 -> "AVAILABLE"
            m < 60 -> "IN ${kotlin.math.ceil(m).toInt()}M"
            m < 1440 -> "IN ${(m / 60).toInt()}H ${(m % 60).toInt()}M"
            else -> "IN ${safeRound(m / 1440)}D"
        }
    }

    fun whenText(item: Item): String {
        val m = (dropDate(item) - now()) / 60000.0
        return when {
            m <= 0 -> "right now"
            m < 60 -> "in ${kotlin.math.ceil(m).toInt()} minutes"
            m < 1440 -> "in about ${safeRound(m / 60)} hours"
            m < 2880 -> "tomorrow"
            else -> "this week"
        }
    }

    // MARK: Agents

    fun agent(id: String?): Agent? = state.agents.firstOrNull { it.id == id }
    fun agentIndex(id: String): Int? = state.agents.indexOfFirst { it.id == id }.takeIf { it >= 0 }

    fun best(item: Item): Pair<Agent, Match>? {
        var best: Pair<Agent, Match>? = null
        for (a in state.agents) {
            if (a.isOff) continue
            val m = Matcher.match(a, item) ?: continue
            if (m.score > (best?.second?.score ?: -1)) best = a to m
        }
        return best
    }

    fun owned(a: Agent): List<Item> =
        state.finds.filter { it.agentID == a.id && it.status == FindStatus.ACQUIRED }.mapNotNull { Catalog.item(it.itemID) }

    /** The honest friend's take on a find. */
    fun take(a: Agent, item: Item): FriendTake {
        val twin = owned(a).firstOrNull { it.id != item.id && it.brand == item.brand && it.traits.toSet().intersect(item.traits.toSet()).size >= 2 }
        if (isSoldOut(item)) return FriendTake("Sold out at the source. I'll watch for a restock and won't let you overpay resale.", false)
        if (twin != null) return FriendTake("You already picked up the ${twin.title}. This is close. Sure you want both?", true)
        if (a.priceNote > 0 && item.price > a.priceNote) return FriendTake("You've passed on things at this price before. Flagging it anyway because it fits you so well.", true)
        if (item.market < item.price * 0.97) return FriendTake("Market's below the asking price right now. I'd wait or buy it secondhand.", true)
        if (item.price > 0 && item.market > item.price * 1.25) return FriendTake("Asking is ${safeRound((item.market / item.price - 1) * 100)}% under market. If you love it, this is the moment.", false)
        return FriendTake("Fair price, right in your lane.", false)
    }

    // MARK: Sweeps (the sample tour; signed in, the server sweeps)

    fun kindFor(item: Item): NoteKind = when {
        isSoldOut(item) -> NoteKind.WATCH
        dropDate(item) > now() -> NoteKind.RELEASE
        item.market > item.price * 1.2 -> NoteKind.STEAL
        else -> NoteKind.AVAILABLE
    }

    data class SweepResult(val found: Int, val bought: Int, val notes: Int)

    fun sweep(background: Boolean = false, quiet: Boolean = false): SweepResult {
        val unseen = Catalog.items.filter { it.id !in state.seenItemIDs }
        val avgIntel = if (state.agents.isEmpty()) 0.0 else state.agents.map(Matcher::intel).sum().toDouble() / state.agents.size
        val quota = if (background) max(2, safeRound(1 + state.agents.size * 0.6)) else safeRound(2 + state.agents.size * 1.2 + avgIntel / 25)
        var found = 0; var bought = 0
        val notes = mutableListOf<AppNote>()
        for (item in unseen) {
            if (found >= quota) break
            val b = best(item) ?: continue        // nobody covers it yet; a future agent might
            state.seenItemIDs.add(item.id)
            if (b.second.score < 45) continue
            val a = b.first
            val find = Find(uuid(), item.id, a.id, b.second.score, b.second.why)
            found++
            Analytics.track(AnalyticsEvent.FIND_CREATED, mapOf("category" to item.category.raw, "mission" to (a.mission.category?.raw ?: "custom"),
                "score" to find.score, "mode" to a.mode.raw, "background" to background,
                "fromLearning" to b.second.why.any { it.startsWith("You've gone for") }))
            if (a.mode == BuyMode.AUTO && find.score >= 80 && !isSoldOut(item) && item.priceKnown && isLive(item)) {
                find.status = FindStatus.ACQUIRED
                state.finds.add(0, find)
                record(a, item)
                log("${a.name} auto-bought ${item.title} for ${Fmt.money(item.price)}")
                bought++
                notify(a, NoteKind.BOUGHT, item, find.id)?.let { notes.add(it) }
            } else {
                state.finds.add(0, find)
                log("${a.name} flagged ${item.title} (${find.score}% match)")
                notify(a, kindFor(item), item, find.id, extra = "${find.score}")?.let { notes.add(it) }
            }
        }
        save()
        if (background) {
            notes.filter { !it.heldForMorning }.forEach { Notifier.post(context, it, agent(it.agentID)?.name ?: "Baget") }
            notes.filter { it.heldForMorning }.forEach { Notifier.postAtMorning(context, it, agent(it.agentID)?.name ?: "Baget") }
        } else if (!quiet) {
            notes.firstOrNull()?.let { showBanner(it) }
        }
        return SweepResult(found, bought, notes.size)
    }

    /** Catches up when you reopen the sample tour. */
    fun catchUp(minutes: Double) {
        if (isCloud) return
        val every = max(15, state.settings.sweepMinutes).toDouble()
        val runs = min(4, (minutes / every).toInt())
        if (runs <= 0 || state.agents.isEmpty()) return
        var found = 0; var bought = 0; var notes = 0; var restocks = 0
        for (r in 0 until runs) {
            if (r == runs - 1) {
                val w = state.finds.firstOrNull { f -> Catalog.item(f.itemID)?.let { isSoldOut(it) && f.watching } ?: false }
                val it = w?.let { Catalog.item(it.itemID) }
                val a = w?.let { agent(it.agentID) }
                if (w != null && it != null && a != null) {
                    state.restockedItemIDs.add(it.id)
                    restocks++
                    if (notify(a, NoteKind.RESTOCK, it, w.id) != null) notes++
                }
            }
            val res = sweep(background = false, quiet = true)
            found += res.found; bought += res.bought; notes += res.notes
        }
        state.awayReport = AwayReport(now(), minutes.toInt(), runs, runs * Catalog.items.size * 3, found, bought, notes, restocks)
        log("Background: $runs sweep${if (runs > 1) "s" else ""} while you were away, $found new find${if (found == 1) "" else "s"}")
        save()
    }

    /** Signed in, a quiet refresh: pick up what the server found and prepare photos. */
    suspend fun backgroundRefresh() {
        if (isCloud) {
            val hadSynced = state.lastSynced != null
            val before = state.notes.map { it.id }.toSet()
            pull()
            loadForYou()
            if (hadSynced && !pushRegistered) {
                for (n in state.notes) if (n.id !in before && !n.read && !n.heldForMorning) Notifier.post(context, n, noteSender(n))
            }
            state.lastSeen = now()
            save()
            return
        }
        val res = sweep(background = true)
        if (res.found > 0) log("Background sweep found ${res.found}")
        state.lastSeen = now()
        save()
    }

    /** While the app is open: a quiet refresh every few minutes. */
    suspend fun refreshQuietly() {
        if (!isCloud || pulling) return
        pull()
        loadForYou()
    }

    /** When the app opens: the sample tour simulates missed sweeps; signed in, it pulls what the server found. */
    suspend fun cameBack(goneMinutes: Double) {
        if (isCloud) {
            val since = state.lastSeen
            pull()
            scope.launch { loadForYou() }
            val found = state.finds.count { it.foundAt > since }
            val notes = state.notes.count { it.date > since }
            if (goneMinutes >= 15 && (found > 0 || notes > 0)) {
                state.awayReport = AwayReport(now(), goneMinutes.toInt(), 0, 0, found, 0, notes,
                    state.notes.count { it.date > since && it.kind == NoteKind.RESTOCK })
                save()
            }
        } else if (goneMinutes >= 15) {
            catchUp(goneMinutes)
        }
    }

    // MARK: Notifications

    private fun inQuietHours(): Boolean {
        val h = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
        return h >= 22 || h < 8
    }

    fun notify(a: Agent, kind: NoteKind, item: Item?, findID: String? = null, extra: String = ""): AppNote? {
        kind.group?.let { if (it !in state.settings.groups) return null }
        val urgent = kind == NoteKind.RESTOCK || kind == NoteKind.BOUGHT ||
            (kind == NoteKind.RELEASE && (item?.let { dropDate(it) - now() < 90 * 60_000 } ?: false))
        val body = FriendVoice.line(a, kind, item, extra, item?.let { whenText(it) } ?: "")
        val note = AppNote(uuid(), agentID = a.id, kind = kind, body = body, findID = findID,
            heldForMorning = state.settings.quietHours && inQuietHours() && !urgent, senderName = a.name)
        state.notes.add(0, note)
        if (kind == NoteKind.LEARNED) {
            val row = jobj("id" to note.id, "agent_id" to a.id, "kind" to "learned", "body" to body.take(500), "sender_name" to a.name)
            push { it.insert("notes", row) }
        }
        Analytics.track(AnalyticsEvent.NOTIFICATION_SENT, mapOf("kind" to kind.raw, "voice" to a.voice.raw, "heldForMorning" to note.heldForMorning))
        while (state.notes.size > 100) state.notes.removeAt(state.notes.lastIndex)
        return note
    }

    fun showBanner(note: AppNote) {
        banner = note
        scope.launch {
            delay(6000)
            if (banner?.id == note.id) banner = null
        }
    }

    val unreadCount: Int get() { tick; return state.notes.count { !it.read } }

    fun noteSender(n: AppNote): String {
        n.friendID?.let { f -> return state.friends.firstOrNull { it.id == f }?.name ?: "A friend" }
        return agent(n.agentID)?.name ?: n.senderName.ifEmpty { "Retired agent" }
    }

    // MARK: Learning

    fun learn(agentID: String, item: Item, delta: Int, note: String? = null) {
        val i = agentIndex(agentID) ?: return
        val a = state.agents[i]
        val gained = mutableListOf<String>()
        for (k in item.traits + item.brand) {
            if (!isTaste(k)) continue
            val n = TextMatch.norm(k)
            val before = a.learned[n] ?: 0
            a.learned[n] = max(-3, min(5, before + delta))
            // a taste that keeps coming up becomes part of the brief
            if (delta > 0 && before < 2 && (a.learned[n] ?: 0) >= 2) {
                if (k == item.brand) {
                    if (a.style.makers.none { TextMatch.norm(it) == n }) { a.style.makers.add(k); gained.add(k) }
                } else if (a.style.traits.none { TextMatch.norm(it) == n }) {
                    a.style.traits.add(n); gained.add(n)
                }
            }
        }
        if (gained.isNotEmpty()) {
            log("${a.name} learned you like ${gained.joinToString(", ")}")
            Analytics.track(AnalyticsEvent.AGENT_LEARNED, mapOf("mission" to (a.mission.category?.raw ?: "custom"), "count" to gained.size))
            notify(a, NoteKind.LEARNED, null, extra = gained.joinToString(", "))?.let { showBanner(it) }
        } else if (note != null) log("${a.name} noted: $note")
        save()
        pushAgent(agentID)
    }

    /** A real taste word, not a price, sale tag, size, SKU or season code. */
    fun isTaste(s: String): Boolean {
        val t = s.trim()
        if (t.length < 2 || t.length > 40) return false
        if (Regex("[$£€¥]|\\b(sale|price|off|usd|gbp|eur)\\b", RegexOption.IGNORE_CASE).containsMatchIn(t)) return false
        val digits = t.count { it.isDigit() }
        if (digits * 2 >= t.length) return false                       // mostly numbers: 2023, 818989, 10.5
        if (Regex("^(ss|fw|aw)\\d{2}$|^size\\b", RegexOption.IGNORE_CASE).containsMatchIn(t)) return false
        return true
    }

    fun unlearn(agentID: String, key: String) {
        val i = agentIndex(agentID) ?: return
        val a = state.agents[i]
        if (key == "__price") a.priceNote = 0.0 else {
            a.learned.remove(key)
            a.style.traits.removeAll { TextMatch.norm(it) == key }
            a.style.makers.removeAll { TextMatch.norm(it) == key }
        }
        log("${a.name} forgot ${if (key == "__price") "your price preference" else key}")
        save()
        pushAgent(agentID)
    }

    // MARK: Actions on finds

    fun record(a: Agent, item: Item, amount: Double? = null): Purchase {
        val p = Purchase(uuid(), now(), item.title, amount ?: item.price, a.id, item.category,
            listingID = if (item.isSample) null else item.id, agentName = a.name)
        state.purchases.add(p)
        return p
    }

    private fun findIndex(id: String): Int? = state.finds.indexOfFirst { it.id == id }.takeIf { it >= 0 }

    /** Signed in, this records a purchase you made at the store. In the sample tour it simulates one. */
    fun confirmPurchase(findID: String, amount: Double? = null) {
        val fi = findIndex(findID) ?: return
        val f = state.finds[fi]
        val item = Catalog.item(f.itemID) ?: return
        val a = agent(f.agentID) ?: state.agents.firstOrNull { Matcher.covers(it, item) } ?: return
        f.status = FindStatus.ACQUIRED
        val p = record(a, item, amount)
        log("You bought ${item.title} via ${a.name} (${Fmt.money(p.amount)})")
        val row = jobj("id" to p.id, "title" to p.title, "amount" to p.amount, "category" to p.category.raw,
            "agent_id" to a.id, "agent_name" to a.name, "listing_id" to p.listingID)
        push {
            it.update("finds", "id=eq.$findID", jobj("status" to "acquired"))
            it.insert("purchases", row)
        }
        learn(a.id, item, 2)
        save()
    }

    fun reminder(item: Item): ReleaseReminder? = state.reminders[item.id]?.takeIf { it.remindAt > now() - 60_000 }

    /** Remind me offsetMinutes before the drop, or at an exact time. Returns false if that moment has passed. */
    fun setReminder(item: Item, findID: String?, offsetMinutes: Int? = null, at: Long? = null): Boolean {
        val drop = item.dropAt
        val whenMs = when {
            offsetMinutes != null && drop != null -> drop - offsetMinutes * 60_000L
            at != null -> at
            else -> return false
        }
        if (whenMs <= now()) return false
        state.reminders[item.id] = ReleaseReminder(whenMs, offsetMinutes)
        val args = mutableMapOf<String, Any?>("p_listing" to item.id, "p_find" to findID)
        if (offsetMinutes != null) args["p_offset_minutes"] = offsetMinutes else args["p_remind_at"] = isoDate(whenMs)
        push { it.rpc("set_release_reminder", toJson(args) as kotlinx.serialization.json.JsonObject) }
        Analytics.track(AnalyticsEvent.REMINDER_SET, mapOf("category" to item.category.raw, "offset" to (offsetMinutes ?: -1)))
        save()
        return true
    }

    fun removeReminder(item: Item) {
        state.reminders.remove(item.id)
        push { it.delete("release_reminders", "listing_id=eq.${item.id}") }
        save()
    }

    fun watch(findID: String) {
        val fi = findIndex(findID) ?: return
        val f = state.finds[fi]
        val item = Catalog.item(f.itemID) ?: return
        f.watching = true
        push { it.update("finds", "id=eq.$findID", jobj("watching" to true)) }
        log("${agent(f.agentID)?.name ?: "Agent"} is watching ${item.title}")
        learn(f.agentID, item, 1)
        save()
    }

    /** You like it: the agent leans into its brand and traits, and keeps an eye on it if it isn't buyable yet. */
    fun like(findID: String) {
        val fi = findIndex(findID) ?: return
        val f = state.finds[fi]
        val item = Catalog.item(f.itemID) ?: return
        if (f.status == FindStatus.LIKED) return
        f.status = FindStatus.LIKED
        f.passReason = null
        val watchIt = isSoldOut(item) || !isLive(item)
        if (watchIt) f.watching = true
        val patch = mutableMapOf<String, Any?>("status" to "liked", "pass_reason" to null)
        if (watchIt) patch["watching"] = true
        push { it.update("finds", "id=eq.$findID", toJson(patch) as kotlinx.serialization.json.JsonObject) }
        log("You liked ${item.title}")
        learn(f.agentID, item, 2)
        Analytics.track(AnalyticsEvent.FIND_LIKED, mapOf("category" to item.category.raw, "score" to f.score, "watching" to watchIt))
        save()
    }

    fun unlike(findID: String) {
        val fi = findIndex(findID) ?: return
        val f = state.finds[fi]
        if (f.status != FindStatus.LIKED) return
        val item = Catalog.item(f.itemID) ?: return
        f.status = FindStatus.OPEN
        push { it.update("finds", "id=eq.$findID", jobj("status" to "open")) }
        learn(f.agentID, item, -2)
        Analytics.track(AnalyticsEvent.FIND_UNLIKED, mapOf("category" to item.category.raw))
        save()
    }

    fun pass(findID: String, reason: PassReason) {
        val fi = findIndex(findID) ?: return
        val f = state.finds[fi]
        val item = Catalog.item(f.itemID) ?: return
        if (f.status == FindStatus.LIKED) learn(f.agentID, item, -2)
        f.status = FindStatus.PASSED
        val reasonText = reason.label.lowercase()
        f.passReason = reasonText
        push { it.update("finds", "id=eq.$findID", jobj("status" to "passed", "pass_reason" to reasonText)) }
        val aid = f.agentID
        when (reason) {
            PassReason.STYLE -> learn(aid, item, -2, "you're not into ${item.traits.take(2).joinToString(", ")}")
            PassReason.PRICE -> {
                // Only a real price can set a price preference ("under $0" is nonsense).
                val i = agentIndex(aid)
                if (item.priceKnown && item.price > 0 && i != null) {
                    val a = state.agents[i]
                    val current = if (a.priceNote > 0) a.priceNote else Double.POSITIVE_INFINITY
                    a.priceNote = Math.round(min(current, item.price * 0.85)).toDouble()
                    log("${a.name} noted you prefer things under ${Fmt.money(a.priceNote)}")
                    pushAgent(aid)
                }
            }
            PassReason.OWN -> log("${agent(aid)?.name ?: "Agent"} will skip near-duplicates of ${item.title}")
            PassReason.LATER -> {}
        }
        save()
    }

    /** Takes finds off the Finds screen. Unlike Pass, this teaches the agent nothing; it just won't show them again. */
    fun removeFinds(ids: List<String>) {
        val set = ids.toSet()
        if (set.isEmpty()) return
        for (f in state.finds) if (f.id in set) { f.status = FindStatus.REMOVED; f.watching = false }
        log(if (set.size == 1) "Removed a find" else "Cleared ${set.size} finds")
        for (chunk in ids.chunked(80)) {
            val filter = "id=in.(${chunk.joinToString(",")})"
            push { it.update("finds", filter, jobj("status" to "removed", "watching" to false)) }
        }
        save()
    }

    /** Brings a removed find back (for example when you tap that item again in Today). */
    fun restoreFind(findID: String) {
        val f = state.finds.firstOrNull { it.id == findID } ?: return
        if (f.status != FindStatus.REMOVED) return
        f.status = FindStatus.OPEN
        push { it.update("finds", "id=eq.$findID", jobj("status" to "open")) }
        save()
    }

    fun undoPass(findID: String) {
        val f = state.finds.firstOrNull { it.id == findID } ?: return
        f.status = FindStatus.OPEN
        f.passReason = null
        push { it.update("finds", "id=eq.$findID", jobj("status" to "open", "pass_reason" to null)) }
        save()
    }

    /** Puts a listing in Finds for an agent (from Live, a friend, or chat). */
    fun ensureFind(agentID: String, itemID: String, why: String? = null): Find? {
        state.finds.firstOrNull { it.itemID == itemID }?.let { return it }
        val a = agent(agentID) ?: return null
        val item = Catalog.item(itemID) ?: return null
        val m = Matcher.match(a, item) ?: Match(50, emptyList())
        val reasons = (listOfNotNull(why) + m.why).take(6)
        val f = Find(uuid(), itemID, agentID, max(0, min(100, m.score)), reasons)
        state.finds.add(0, f)
        state.seenItemIDs.add(itemID)
        val row = jobj("id" to f.id, "listing_id" to itemID, "agent_id" to agentID, "score" to f.score, "why" to reasons)
        push { it.insert("finds", row) }
        save()
        return f
    }

    fun markRead(ids: List<String>) {
        val set = ids.toSet()
        val changed = mutableListOf<String>()
        for (n in state.notes) if (n.id in set && !n.read) { n.read = true; changed.add(n.id) }
        if (changed.isEmpty()) return
        save()
        Notifier.clear(context, changed)
        push { it.update("notes", "id=in.(${changed.joinToString(",")})", jobj("read" to true)) }
    }

    // MARK: Squad

    /** Adds the agent. In the sample tour it sweeps at once; signed in, call cloudDeploy to save it and start the hunt. */
    fun deploy(a: Agent) {
        state.agents.add(a)
        log("${a.name} deployed on ${a.mission.label}")
        if (isCloud) save() else sweep(quiet = false)
    }

    /** Turns an agent off (no searching, no texts) or back on. */
    fun setOff(id: String, off: Boolean) {
        val a = agent(id)?.deepCopy() ?: return
        a.paused = off
        update(a)
        log(if (off) "${a.name} turned off" else "${a.name} is back on the hunt")
    }

    fun retire(id: String) {
        val a = agent(id) ?: return
        state.agents.removeAll { it.id == id }
        log("${a.name} deleted")
        push { it.delete("agents", "id=eq.$id") }
        save()
    }

    fun update(a: Agent) {
        val i = agentIndex(a.id) ?: return
        state.agents[i] = a
        save()
        pushAgent(a.id)
    }

    fun log(text: String) {
        // Same line twice in a row (for example two quick passes) is one event.
        val last = state.log.firstOrNull()
        if (last != null && last.text == text && now() - last.date < 600_000) return
        state.log.add(0, LogLine(text = text))
        while (state.log.size > 60) state.log.removeAt(state.log.lastIndex)
    }

    // MARK: Taste photos

    const val maxTastePhotos = 6

    private val photoDir: File get() = File(context.filesDir, "taste").also { it.mkdirs() }
    private fun photoFile(id: String) = File(photoDir, "$id.jpg")

    fun image(photo: TastePhoto): Bitmap? {
        photoVersion   // redraw when a download lands
        val f = photoFile(photo.id)
        if (f.exists()) BitmapFactory.decodeFile(f.path)?.let { return it }
        fetchPhotoIfNeeded(photo)
        return null
    }

    fun cacheTastePhoto(id: String, data: ByteArray) { runCatching { photoFile(id).writeBytes(data) } }

    /** Saves the photo on the phone (and your account, when signed in) and teaches the agent what you kept. */
    fun addTastePhoto(agentID: String, image: Bitmap, tags: List<String>, makers: List<String> = emptyList(),
                      creators: List<String> = emptyList(), summary: String) {
        val i = agentIndex(agentID) ?: return
        if (tags.isEmpty() && makers.isEmpty() && creators.isEmpty()) return
        val a = state.agents[i]
        val photo = TastePhoto(uuid(), tags = (tags.map { it.lowercase() } + makers + creators).take(12), summary = summary)
        val jpeg = Images.jpeg(Images.scaled(image, 720), 80)
        cacheTastePhoto(photo.id, jpeg)
        for (m in makers) if (a.style.makers.none { TextMatch.norm(it) == TextMatch.norm(m) }) a.style.makers.add(m)
        for (c in creators) if (a.style.creators.none { TextMatch.norm(it) == TextMatch.norm(c) }) a.style.creators.add(c)
        a.tasteBoard.add(0, photo)
        while (a.tasteBoard.size > maxTastePhotos) {
            val old = a.tasteBoard.removeAt(a.tasteBoard.lastIndex)
            photoFile(old.id).delete()
        }
        for (t in tags.map { it.lowercase() }) {
            if (a.style.traits.none { TextMatch.norm(it) == TextMatch.norm(t) }) a.style.traits.add(t)
            // what you choose to show is a strong signal
            a.learned[TextMatch.norm(t)] = max(a.learned[TextMatch.norm(t)] ?: 0, 1)
        }
        log("${a.name} learned from your photo: ${photo.tags.take(4).joinToString(", ")}")
        Analytics.track(AnalyticsEvent.TASTE_PHOTO_ADDED, mapOf("mission" to (a.mission.category?.raw ?: "custom"), "tags" to photo.tags.size,
            "boardSize" to a.tasteBoard.size))
        notify(a, NoteKind.LEARNED, null, extra = photo.tags.take(3).joinToString(", "))?.let { showBanner(it) }
        if (isCloud) uploadTastePhoto(agentID, photo, jpeg)
        save()
    }

    /** Removes a photo, and forgets tags that only came from it. */
    fun removeTastePhoto(agentID: String, photoID: String) {
        val i = agentIndex(agentID) ?: return
        val a = state.agents[i]
        val p = a.tasteBoard.firstOrNull { it.id == photoID } ?: return
        a.tasteBoard.removeAll { it.id == photoID }
        photoFile(photoID).delete()
        val still = a.tasteBoard.flatMap { ph -> ph.tags.map(TextMatch::norm) }.toSet()
        val drop = p.tags.map(TextMatch::norm).toSet() - still
        a.style.traits.removeAll { TextMatch.norm(it) in drop }
        for (k in drop) if (a.learned[k] == 1) a.learned.remove(k)
        log("${a.name} forgot a taste photo")
        save()
        deleteTastePhotoCloud(p, agentID)
    }

    // MARK: Live

    fun stories(): List<Story> = Catalog.all.map { item ->
        val pct = if (item.price > 0) safeRound((item.market / item.price - 1) * 100) else 0
        val drop = (dropDate(item) - now()) / 60000.0
        val kind: String; val head: String
        when {
            isSoldOut(item) -> { kind = "Restock watch"; head = "${item.title} Sold Out Fast. Here's the Restock Play" }
            drop > 0 -> { kind = "Release"; head = "${item.title} ${if (drop < 1440) "Drops Today" else if (drop < 2880) "Drops Tomorrow" else "Lands This Week"} at ${item.source}" }
            pct >= 20 -> { kind = "Market"; head = "${item.title} Is Trading $pct% Above Asking" }
            pct <= -3 -> { kind = "Price watch"; head = "The Market Is Cooling on the ${item.title}" }
            else -> { kind = "Available now"; head = "${item.title} Is Available Now via ${item.source}" }
        }
        val info = item.category.info
        var dek = item.creator?.let { "${info.creatorVerb} $it. " } ?: ""
        dek += item.traits.take(3).joinToString(", ").capitalizedFirst() + ". "
        dek += if (item.priceKnown) "${Fmt.money(item.price)} at ${item.source}" else "Price TBA at ${item.source}"
        if (item.priceKnown && item.market != item.price) dek += ", ${Fmt.money(item.market)} on the market"
        dek += "."
        val b = best(item)
        Story(item, kind, head, dek, minutesAgo(item), b?.first?.id, b?.second, isLive(item))
    }

    private fun minutesAgo(item: Item): Int {
        item.firstSeen?.let { return max(1, ((now() - it) / 60000).toInt()) }
        return item.id.fold(0) { acc, c -> (acc * 31 + c.code) % 997 } % 170 + 3   // sample stories: stable spread
    }

    fun stories(tab: LiveTab): List<Story> {
        val all = stories()
        return when (val k = tab.kind) {
            LiveTabKind.ForYou -> all.filter { it.forYou }.sortedWith(compareByDescending<Story> { it.score }.thenBy { it.minutesAgo })
            LiveTabKind.Latest -> all.sortedBy { it.minutesAgo }
            is LiveTabKind.Cat -> all.filter { it.item.category == k.category }.sortedByDescending { it.score }
            is LiveTabKind.Custom -> all.filter { TextMatch.matches(it.item, k.query) }.sortedByDescending { it.score }
        }
    }

    // MARK: Friends

    fun friend(id: String): Friend? = state.friends.firstOrNull { it.id == id }

    fun acceptSuggestion(id: String) {
        val s = state.suggestions.firstOrNull { it.id == id } ?: return
        s.status = SuggestionStatus.SENT
        push { it.update("suggestions", "id=eq.$id", jobj("status" to "sent")) }
        val item = Catalog.item(s.itemID); val f = friend(s.friendID)
        if (item == null || f == null) { save(); return }
        val target = best(item)?.first ?: state.agents.firstOrNull { Matcher.covers(it, item) }
        val credit = "${f.name} suggested it: “${s.note}”"
        if (target != null) {
            val find = ensureFind(target.id, item.id, credit)
            if (find != null) {
                find.why = listOf(credit) + find.why.filter { !it.contains("suggested it") }
                if (find.status != FindStatus.ACQUIRED) find.status = FindStatus.OPEN
                learn(target.id, item, 1, "your friend ${f.name} thinks you'd like ${item.title}")
            }
        }
        log("You took ${f.name}'s suggestion: ${item.title}")
        save()
    }

    fun passSuggestion(id: String) {
        val s = state.suggestions.firstOrNull { it.id == id } ?: return
        s.status = SuggestionStatus.PASSED
        push { it.update("suggestions", "id=eq.$id", jobj("status" to "passed")) }
        save()
    }

    fun share(itemID: String, to: List<String>, note: String, isSuggestion: Boolean) {
        val sh = Share(itemID = itemID, to = to, note = note, isSuggestion = isSuggestion)
        state.shares.add(0, sh)
        val names = to.mapNotNull { friend(it)?.name }.joinToString(", ")
        log("You ${if (isSuggestion) "suggested" else "shared"} ${Catalog.item(itemID)?.title ?: "an item"} with $names")
        save()
        if (isCloud) {
            push {
                it.rpc("share_listing", jobj("p_listing" to itemID, "p_to" to to, "p_note" to note, "p_is_suggestion" to isSuggestion))
                pull()
            }
            return
        }
        // Sample tour: sample friends reply a few seconds later.
        to.forEachIndexed { k, fid ->
            scope.launch {
                delay((3500 + k * 2500).toLong())
                val f = friend(fid) ?: return@launch
                val target = state.shares.firstOrNull { it.id == sh.id } ?: return@launch
                val text = f.replies[(itemID.length + k) % max(1, f.replies.size)]
                target.replies.add(ShareReply(fid, text, now()))
                val n = AppNote(friendID = fid, kind = NoteKind.FRIEND, body = text)
                state.notes.add(0, n)
                save()
                showBanner(n)
            }
        }
    }

    /** Sample tour: adds a pretend friend who accepts a few seconds later. */
    fun addFriend(raw: String): String? {
        val h = raw.trim()
        if (h.isEmpty()) return "Enter a handle like @maya or an email address."
        val handle = (if (h.contains("@") && !h.startsWith("@")) h else if (h.startsWith("@")) h else "@$h").lowercase()
        if (state.friends.any { it.handle.lowercase() == handle }) return "You've already added them."
        val base = handle.replace("@", " ").split(' ', '.', '_').firstOrNull { it.isNotEmpty() } ?: "friend"
        val id = "u" + uuid().take(6)
        state.friends.add(Friend(id, base.capitalizedFirst(), handle, emptyList(), emptyList(), isPending = true,
            replies = listOf("Love that. Thanks for thinking of me.", "Ooh, good find.", "Adding it to my list.")))
        log("Friend invite sent to $handle")
        save()
        scope.launch {
            delay(4000)
            val f = state.friends.firstOrNull { it.id == id } ?: return@launch
            if (!f.isPending) return@launch
            f.isPending = false
            f.hunts = listOf(Category.SNEAKERS, Category.FRAGRANCE)
            f.likes = listOf("suede", "rose")
            val n = AppNote(friendID = id, kind = NoteKind.FRIEND, body = "${f.name} accepted your friend request. You can now swap suggestions.")
            state.notes.add(0, n)
            save()
            showBanner(n)
        }
        return null
    }

    fun removeFriend(id: String) {
        val fid = friend(id)?.friendshipID
        state.friends.removeAll { it.id == id }
        save()
        if (fid != null) push { it.delete("friendships", "id=eq.$fid") }
    }

    fun friendPicks(f: Friend): List<Item> = Catalog.all.map { item ->
        if (item.category !in f.hunts) item to 0
        else item to 30 + item.traits.count { t -> f.likes.any { TextMatch.loose(it, t) } } * 20
    }.filter { it.second > 0 }.sortedByDescending { it.second }.take(6).map { it.first }

    fun sharedTaste(f: Friend): List<String> {
        val mine = state.agents.flatMap { it.style.traits }
        return f.likes.filter { l -> mine.any { TextMatch.loose(it, l) } }
    }

    // MARK: Files

    suspend fun readBytes(file: File): ByteArray? = withContext(Dispatchers.IO) { runCatching { file.readBytes() }.getOrNull() }
}
