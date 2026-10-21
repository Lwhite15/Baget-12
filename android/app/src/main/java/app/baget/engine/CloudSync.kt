package app.baget.engine

import android.graphics.Bitmap
import app.baget.model.*
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.*
import java.util.TimeZone

// MARK: Rows as the server sends them (snake_case keys map to camelCase properties)

@Serializable
data class ListingRow(
    val id: String, val title: String, val brand: String = "", val category: String = "other", val sku: String = "",
    val price: Double? = null, val market: Double? = null, val source: String = "", val url: String? = null,
    val imageUrl: String? = null, val dropAt: String? = null, val soldOut: Boolean = false, val creator: String? = null,
    val traits: List<String> = emptyList(), val tags: List<String> = emptyList(), val sizesInStock: List<String>? = null,
    val firstSeenAt: String? = null, val offers: List<Offer>? = null, val lowPrice: Double? = null, val lowStore: String? = null,
    val about: String? = null, val brandAbout: String? = null,
) {
    val item: Item get() {
        val cat = Category.of(category) ?: Category.OTHER
        val sizes = sizesInStock ?: emptyList()
        return Item(id = id, title = title, brand = brand, category = cat, sku = sku, price = price ?: 0.0, market = market ?: price ?: 0.0,
            source = source, dropOffset = 0.0, soldOutAtStart = soldOut, creator = creator, traits = traits, tags = tags,
            shoeSizes = if (cat == Category.SNEAKERS && sizes.isNotEmpty()) sizes.mapNotNull(Sizes::shoeUS) else null,
            topSizes = if (cat == Category.APPAREL && sizes.isNotEmpty()) sizes.mapNotNull(Sizes::topSize) else null,
            url = url, imageURL = imageUrl, dropAt = parseDate(dropAt), firstSeen = parseDate(firstSeenAt), priceKnown = price != null,
            isSample = false, offers = offers, lowPrice = lowPrice, lowStore = lowStore, about = about, brandAbout = brandAbout)
    }
}

@Serializable
data class AgentRow(
    val id: String, val name: String, val missionCategory: String? = null, val missionCustom: String? = null,
    val keywords: List<String> = emptyList(), val traits: List<String> = emptyList(), val makers: List<String> = emptyList(),
    val creators: List<String> = emptyList(), val size: String = "", val mode: String = "ask", val voice: String = "chill",
    val learned: Map<String, Int> = emptyMap(), val priceNote: Double = 0.0, val icon: JsonElement? = null,
    val paused: Boolean? = null, val alerts: String? = null,
)

@Serializable
data class TastePhotoRow(val id: String, val agentId: String, val storagePath: String, val tags: List<String> = emptyList(),
                         val summary: String = "", val createdAt: String? = null)

@Serializable
data class FindRow(val id: String, val listingId: String, val agentId: String? = null, val score: Int = 0, val why: List<String> = emptyList(),
                   val status: String = "open", val passReason: String? = null, val watching: Boolean = false, val createdAt: String? = null,
                   val listing: ListingRow? = null)

@Serializable
data class PurchaseRow(val id: String, val listingId: String? = null, val agentId: String? = null, val agentName: String = "",
                       val title: String = "", val amount: Double = 0.0, val category: String = "other", val purchasedAt: String? = null)

@Serializable
data class ReminderRow(val listingId: String, val remindAt: String, val offsetMinutes: Int? = null)

@Serializable
data class NoteRow(val id: String, val agentId: String? = null, val friendId: String? = null, val senderName: String = "",
                   val kind: String = "available", val body: String = "", val findId: String? = null, val read: Boolean = false,
                   val heldForMorning: Boolean = false, val createdAt: String? = null)

@Serializable
data class FriendRow(val friendshipId: String, val friendId: String, val handle: String = "", val displayName: String = "",
                     val status: String = "pending", val direction: String = "outgoing", val hunts: List<String> = emptyList(),
                     val likes: List<String> = emptyList())

@Serializable
data class SuggestionRow(val id: String, val shareId: String? = null, val fromUser: String, val listingId: String, val note: String = "",
                         val status: String = "new", val createdAt: String? = null, val listing: ListingRow? = null)

@Serializable
data class ReplyRow(val fromUser: String, val body: String = "", val createdAt: String? = null)

@Serializable
data class ShareRow(val id: String, val listingId: String, val toUsers: List<String> = emptyList(), val note: String = "",
                    val isSuggestion: Boolean = false, val createdAt: String? = null, val listing: ListingRow? = null,
                    val replies: List<ReplyRow>? = null)

// MARK: The icon as stored in jsonb (camelCase keys, shared with the iPhone app). Empty ({}) means the default.

fun iconFromJson(e: JsonElement?): Avatar? {
    val o = e as? JsonObject ?: return null
    val style = Avatar.Style.of(o["style"]?.jsonPrimitive?.contentOrNull) ?: return null
    return Avatar(style = style,
        emoji = o["emoji"]?.jsonPrimitive?.contentOrNull ?: "🔥",
        color = o["color"]?.jsonPrimitive?.intOrNull ?: 0,
        photoID = o["photoID"]?.jsonPrimitive?.contentOrNull)
}

fun iconToJson(icon: Avatar?): JsonObject {
    icon ?: return JsonObject(emptyMap())
    return jobj("style" to icon.style.raw, "emoji" to icon.emoji, "color" to icon.color, "photoID" to icon.photoID)
}

/** Live bar tabs in the iPhone app's format ({"kind":{"category":{"_0":"sneakers"}}}), so both apps share one setting. */
fun liveTabToJson(t: LiveTab): JsonObject {
    val kind = when (val k = t.kind) {
        LiveTabKind.ForYou -> jobj("forYou" to JsonObject(emptyMap()))
        LiveTabKind.Latest -> jobj("latest" to JsonObject(emptyMap()))
        is LiveTabKind.Cat -> jobj("category" to jobj("_0" to k.category.raw))
        is LiveTabKind.Custom -> jobj("custom" to jobj("_0" to k.query))
    }
    return jobj("id" to t.id, "kind" to kind, "label" to t.label)
}

fun liveTabFromJson(e: JsonElement): LiveTab? {
    val o = e as? JsonObject ?: return null
    val id = o["id"]?.jsonPrimitive?.contentOrNull ?: return null
    val label = o["label"]?.jsonPrimitive?.contentOrNull ?: return null
    val k = o["kind"] as? JsonObject ?: return null
    val kind = when {
        k.containsKey("forYou") -> LiveTabKind.ForYou
        k.containsKey("latest") -> LiveTabKind.Latest
        k.containsKey("category") -> Category.of((k["category"] as? JsonObject)?.get("_0")?.jsonPrimitive?.contentOrNull)?.let { LiveTabKind.Cat(it) }
        k.containsKey("custom") -> (k["custom"] as? JsonObject)?.get("_0")?.jsonPrimitive?.contentOrNull?.let { LiveTabKind.Custom(it) }
        else -> null
    } ?: return null
    return LiveTab(id, kind, label)
}

// MARK: Sync

val AppStore.api: Backend get() = Backend

/** Signed in and this saved state belongs to the signed-in account. */
val AppStore.isCloud: Boolean get() = Backend.isSignedIn && state.accountID == Backend.userID && state.accountID != null

/** Runs a server write in the background. On failure, says so and re-syncs so the screen shows the truth. */
fun AppStore.push(work: suspend (Backend) -> Unit) {
    if (!isCloud) return
    scope.launch {
        try { work(Backend) } catch (e: Exception) {
            syncProblem = (e as? BackendError)?.message ?: "Couldn't save that. Check your connection."
            pull()
        }
    }
}

suspend fun AppStore.didSignIn(fullName: String?) {
    val uid = Backend.userID ?: return
    state = AppState().also { it.accountID = uid }
    Catalog.cloud = mutableMapOf()
    Catalog.useCloud = true
    save()
    val name = fullName?.trim()
    if (!name.isNullOrEmpty()) runCatching { Backend.update("profiles", "id=eq.$uid", jobj("display_name" to name.take(60))) }
    runCatching { Backend.update("profiles", "id=eq.$uid", jobj("tz" to TimeZone.getDefault().id)) }
    pull()
    Analytics.track(AnalyticsEvent.SIGNED_IN, mapOf("newAccount" to state.agents.isEmpty(), "platform" to "android"))
    registerForPushIfAllowed()
}

suspend fun AppStore.signOut() {
    Push.currentToken(context)?.let { t -> runCatching { Backend.rpc("unregister_device", jobj("p_token" to t)) } }
    Backend.signOut()
    isAdmin = false
    plan = null
    resetToWelcome()
}

suspend fun AppStore.deleteAccount() {
    Backend.function("delete-account", JsonObject(emptyMap()))
    Backend.forgetSession()
    resetToWelcome()
}

fun AppStore.resetToWelcome() {
    state = AppState()
    Catalog.cloud = mutableMapOf()
    Catalog.useCloud = false
    save()
}

fun AppStore.exploreSamples() {
    state = AppState().also { it.exploringSamples = true }
    Catalog.useCloud = false
    seed()
    save()
}

// MARK: Pull everything

suspend fun AppStore.pull() {
    val uid = Backend.userID
    if (!isCloud || uid == null || pulling) return
    pulling = true
    try {
        scope.launch { isAdmin = runCatching { Backend.rpc("am_i_admin").jsonPrimitive.booleanOrNull }.getOrNull() ?: false }
        scope.launch { loadPlan() }
        coroutineScope {
            val agentsQ = async { Backend.select("agents", "select=*&order=created_at.asc", ListSerializer(AgentRow.serializer())) }
            val photosQ = async { Backend.select("taste_photos", "select=*&order=created_at.desc", ListSerializer(TastePhotoRow.serializer())) }
            // Removed finds aren't shown anywhere, so they aren't downloaded.
            val findsQ = async { Backend.select("finds", "select=*,listing:listings(*)&status=neq.removed&order=created_at.desc&limit=300", ListSerializer(FindRow.serializer())) }
            val purchasesQ = async { Backend.select("purchases", "select=*&order=purchased_at.desc&limit=500", ListSerializer(PurchaseRow.serializer())) }
            val notesQ = async { Backend.select("notes", "select=*&order=created_at.desc&limit=100", ListSerializer(NoteRow.serializer())) }
            val friendsQ = async { Backend.rpc("my_friends", JsonObject(emptyMap()), ListSerializer(FriendRow.serializer())) }
            val suggestionsQ = async { Backend.select("suggestions", "select=*,listing:listings(*)&to_user=eq.$uid&order=created_at.desc&limit=100", ListSerializer(SuggestionRow.serializer())) }
            val sharesQ = async { Backend.select("shares", "select=*,listing:listings(*),replies:share_replies(*)&from_user=eq.$uid&order=created_at.desc&limit=100", ListSerializer(ShareRow.serializer())) }
            val remindersQ = async { runCatching { Backend.select("release_reminders", "select=listing_id,remind_at,offset_minutes&sent_at=is.null", ListSerializer(ReminderRow.serializer())) }.getOrDefault(emptyList()) }
            val profileQ = async { Backend.selectRaw("profiles", "select=*&id=eq.$uid") }

            val agents = agentsQ.await(); val photos = photosQ.await(); val finds = findsQ.await()
            val purchases = purchasesQ.await(); val notes = notesQ.await(); val friends = friendsQ.await()
            val suggestions = suggestionsQ.await(); val shares = sharesQ.await(); val reminders = remindersQ.await()
            val profile = profileQ.await()
            if (!isCloud) return@coroutineScope   // signed out while loading

            state.reminders = reminders.mapNotNull { r -> parseDate(r.remindAt)?.let { r.listingId to ReleaseReminder(it, r.offsetMinutes) } }
                .toMap().toMutableMap()

            val catalog = mutableMapOf<String, Item>()
            for (f in finds) f.listing?.let { catalog[it.id] = it.item }
            for (s in suggestions) s.listing?.let { catalog[it.id] = it.item }
            for (s in shares) s.listing?.let { catalog[it.id] = it.item }
            for (p in forYou) if (catalog[p.id] == null) Catalog.cloud[p.id]?.let { catalog[p.id] = it }
            Catalog.cloud = catalog
            Catalog.useCloud = true
            state.listings = catalog.values.toMutableList()

            val board = photos.groupBy { it.agentId }
            state.agents = agents.map { r ->
                Agent(id = r.id, name = r.name,
                    mission = Category.of(r.missionCategory)?.let { Mission.Cat(it) } ?: Mission.Custom(r.missionCustom ?: ""),
                    keywords = r.keywords.toMutableList(),
                    style = StyleProfile(r.traits.toMutableList(), r.makers.toMutableList(), r.creators.toMutableList()),
                    size = r.size, mode = BuyMode.of(r.mode) ?: BuyMode.ASK, voice = Voice.of(r.voice) ?: Voice.CHILL,
                    learned = r.learned.toMutableMap(), priceNote = r.priceNote,
                    tasteBoard = (board[r.id] ?: emptyList()).map { TastePhoto(it.id, parseDate(it.createdAt) ?: now(), it.tags, it.summary, it.storagePath) }.toMutableList(),
                    icon = iconFromJson(r.icon), paused = r.paused ?: false, alerts = AgentAlerts.of(r.alerts) ?: AgentAlerts.NORMAL)
            }.toMutableList()
            state.finds = finds.map { f ->
                Find(f.id, f.listingId, f.agentId ?: "", f.score, f.why, FindStatus.of(f.status) ?: FindStatus.OPEN, f.passReason, f.watching,
                    parseDate(f.createdAt) ?: now())
            }.toMutableList()
            state.purchases = purchases.map { p ->
                Purchase(p.id, parseDate(p.purchasedAt) ?: now(), p.title, p.amount, p.agentId ?: "", Category.of(p.category) ?: Category.OTHER,
                    false, p.listingId, p.agentName)
            }.toMutableList()
            state.notes = notes.map { n ->
                AppNote(n.id, parseDate(n.createdAt) ?: now(), n.agentId, n.friendId, NoteKind.of(n.kind) ?: NoteKind.AVAILABLE, n.body, n.findId,
                    n.read, n.heldForMorning, n.senderName)
            }.toMutableList()
            state.friends = friends.map { f ->
                Friend(f.friendId, if (f.displayName.isEmpty()) "@${f.handle}" else f.displayName, "@${f.handle}",
                    f.hunts.mapNotNull { Category.of(it) }, f.likes, isPending = f.status != "accepted", isSample = false,
                    replies = emptyList(), friendshipID = f.friendshipId, incoming = f.direction == "incoming")
            }.toMutableList()
            state.suggestions = suggestions.map { s ->
                Suggestion(s.id, s.fromUser, s.listingId, s.note, parseDate(s.createdAt) ?: now(), SuggestionStatus.of(s.status) ?: SuggestionStatus.NEW, s.shareId)
            }.toMutableList()
            state.shares = shares.map { s ->
                Share(s.id, s.listingId, s.toUsers, s.note, parseDate(s.createdAt) ?: now(), s.isSuggestion,
                    (s.replies ?: emptyList()).sortedBy { parseDate(it.createdAt) ?: 0 }
                        .map { ShareReply(it.fromUser, it.body, parseDate(it.createdAt) ?: now()) }.toMutableList())
            }.toMutableList()
            applyProfile(profile)
            state.lastSynced = now()
            save()
        }
    } catch (e: Exception) {
        if (!Backend.isSignedIn) { resetToWelcome(); return }
        syncProblem = (e as? BackendError)?.message ?: "Couldn't refresh. Check your connection."
    } finally {
        pulling = false
    }
}

private fun AppStore.applyProfile(data: JsonElement) {
    val p = (data as? JsonArray)?.firstOrNull() as? JsonObject ?: return
    state.profile = Profile(p["handle"]?.jsonPrimitive?.contentOrNull ?: "", p["display_name"]?.jsonPrimitive?.contentOrNull ?: "")
    state.settings.shareTasteWithFriends = p["share_taste"]?.jsonPrimitive?.booleanOrNull ?: true
    state.settings.sharePurchasesWithFriends = p["share_purchases"]?.jsonPrimitive?.booleanOrNull ?: false
    val blob = p["settings"] as? JsonObject
    if (blob != null) {
        blob["sweepMinutes"]?.jsonPrimitive?.intOrNull?.let { state.settings.sweepMinutes = it }
        blob["quietHours"]?.jsonPrimitive?.booleanOrNull?.let { state.settings.quietHours = it }
        (blob["groups"] as? JsonArray)?.let { g -> state.settings.groups = g.mapNotNull { NoteGroup.of(it.jsonPrimitive.contentOrNull) }.toMutableSet() }
        (blob["liveTabs"] as? JsonArray)?.mapNotNull { liveTabFromJson(it) }?.takeIf { it.isNotEmpty() }?.let { state.liveTabs = it.toMutableList() }
        iconFromJson(blob["avatar"])?.let { state.avatar = it }
        state.settings.pushLevel = PushLevel.of(blob["pushLevel"]?.jsonPrimitive?.contentOrNull)
        state.settings.huntStart = blob["huntStart"]?.jsonPrimitive?.intOrNull
    }
    lastSettingsSnapshot = settingsSnapshot()
}

/** What the server should hold for settings; compared on every save so any screen's change syncs. */
fun AppStore.settingsSnapshot(): String {
    val s = state.settings
    val blob = jobj(
        "sweepMinutes" to s.sweepMinutes, "quietHours" to s.quietHours,
        "groups" to s.groups.map { it.raw }.sorted(), "liveTabs" to state.liveTabs.map { liveTabToJson(it) },
        "avatar" to iconToJson(state.avatar), "pushLevel" to (s.pushLevel ?: PushLevel.BEST).raw, "huntStart" to (s.huntStart ?: 9),
    )
    return jobj("settings" to blob, "share_taste" to s.shareTasteWithFriends, "share_purchases" to s.sharePurchasesWithFriends).toString()
}

fun AppStore.syncSettingsIfChanged() {
    val uid = Backend.userID ?: return
    if (!isCloud) return
    val snap = settingsSnapshot()
    if (snap == lastSettingsSnapshot) return
    lastSettingsSnapshot = snap
    val obj = rowJson.parseToJsonElement(snap).jsonObject
    push { it.update("profiles", "id=eq.$uid", obj) }
}

suspend fun AppStore.updateHandle(raw: String): String? {
    val h = raw.trim('@', ' ').lowercase()
    if (!Regex("^[a-z0-9._]{3,24}$").matches(h)) return "Use 3 to 24 letters, numbers, dots or underscores."
    val uid = Backend.userID ?: return BackendError.notSignedIn.message
    return try {
        Backend.update("profiles", "id=eq.$uid", jobj("handle" to h))
        state.profile?.handle = h
        save()
        null
    } catch (e: BackendError) {
        if (e.status == 409) "@$h is taken. Try another." else e.message
    }
}

suspend fun AppStore.updateDisplayName(raw: String): String? {
    val name = raw.trim().take(60)
    if (!isCloud) {
        state.profile = Profile(state.profile?.handle ?: "", name)
        save()
        return null
    }
    val uid = Backend.userID ?: return BackendError.notSignedIn.message
    return try {
        Backend.update("profiles", "id=eq.$uid", jobj("display_name" to name))
        state.profile?.displayName = name
        save()
        null
    } catch (e: BackendError) { e.message }
}

// MARK: Agents

fun AppStore.agentFields(a: Agent): JsonObject = jobj(
    "name" to a.name, "keywords" to a.keywords, "traits" to a.style.traits, "makers" to a.style.makers, "creators" to a.style.creators,
    "size" to a.size, "mode" to a.mode.raw, "voice" to a.voice.raw, "learned" to a.learned, "price_note" to a.priceNote,
    "icon" to iconToJson(a.icon), "paused" to a.isOff, "alerts" to a.alerts.raw,
)

fun AppStore.pushAgent(id: String) {
    val a = agent(id) ?: return
    val fields = agentFields(a)
    push { it.update("agents", "id=eq.$id", fields) }
}

suspend fun AppStore.cloudDeploy(a: Agent): String {
    val row = agentFields(a).toMutableMap()
    row["id"] = JsonPrimitive(a.id)
    when (val m = a.mission) {
        is Mission.Cat -> row["mission_category"] = JsonPrimitive(m.cat.raw)
        is Mission.Custom -> row["mission_custom"] = JsonPrimitive(m.text.take(80))
    }
    try {
        Backend.insert("agents", JsonObject(row))
    } catch (e: Exception) {
        state.agents.removeAll { it.id == a.id }
        save()
        val msg = (e as? BackendError)?.message ?: ""
        return if (msg.contains("agent_limit")) scoutLimitMessage else "Couldn't deploy ${a.name}. $msg"
    }
    return cloudSweep(a.id, quietIfNone = true) ?: "${a.name} is out hunting. Finds land here as it spots them."
}

/** Asks the server to sweep now. Returns what to tell the person. */
suspend fun AppStore.cloudSweep(agentID: String? = null, quietIfNone: Boolean = false): String? = try {
    val body = if (agentID != null) jobj("agent_id" to agentID) else JsonObject(emptyMap())
    val r = Backend.function("sweep", body) as? JsonObject
    pull()
    val m = r?.get("message")?.jsonPrimitive?.contentOrNull
    val n = r?.get("found")?.jsonPrimitive?.intOrNull ?: 0
    when {
        m != null -> m
        n == 0 && quietIfNone -> null
        n > 0 -> "$n new find${if (n == 1) "" else "s"}"
        else -> "Your squad looked. Nothing new fits you right now."
    }
} catch (e: Exception) {
    (e as? BackendError)?.message ?: "Your squad couldn't reach the web just now."
}

// MARK: Taste photos

data class PhotoReading(val summary: String, var traits: List<String>, val makers: List<String> = emptyList(),
                        val creators: List<String> = emptyList(), val byClaude: Boolean = false)

suspend fun AppStore.readPhotoCloud(agentID: String, image: Bitmap): PhotoReading? {
    if (!isCloud) return null
    val jpeg = Images.jpeg(Images.scaled(image, 768), 70)
    return try {
        val r = Backend.function("read-photo", jobj("agent_id" to agentID, "image_base64" to android.util.Base64.encodeToString(jpeg, android.util.Base64.NO_WRAP),
            "media_type" to "image/jpeg")).jsonObject
        fun list(k: String) = (r[k] as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull } ?: emptyList()
        PhotoReading(r["summary"]?.jsonPrimitive?.contentOrNull ?: "", list("traits"), list("makers"), list("creators"), true)
    } catch (e: Exception) { null }
}

fun AppStore.uploadTastePhoto(agentID: String, photo: TastePhoto, jpeg: ByteArray) {
    val uid = Backend.userID ?: return
    val path = "$uid/${photo.id}.jpg"
    agent(agentID)?.tasteBoard?.firstOrNull { it.id == photo.id }?.storagePath = path
    val fields = agent(agentID)?.let { agentFields(it) }
    push {
        it.upload("taste-photos", path, jpeg)
        it.insert("taste_photos", jobj("id" to photo.id, "agent_id" to agentID, "storage_path" to path, "tags" to photo.tags, "summary" to photo.summary))
        if (fields != null) it.update("agents", "id=eq.$agentID", fields)
    }
}

fun AppStore.deleteTastePhotoCloud(photo: TastePhoto, agentID: String) {
    val fields = agent(agentID)?.let { agentFields(it) }
    push {
        it.delete("taste_photos", "id=eq.${photo.id}")
        photo.storagePath?.let { p -> runCatching { it.removeFile("taste-photos", p) } }
        if (fields != null) it.update("agents", "id=eq.$agentID", fields)
    }
}

/** Photos added on another device are fetched once and kept on this phone. */
fun AppStore.fetchPhotoIfNeeded(photo: TastePhoto) {
    val path = photo.storagePath ?: return
    if (!isCloud || photo.id in downloading) return
    downloading.add(photo.id)
    scope.launch {
        try {
            runCatching { Backend.download("taste-photos", path) }.getOrNull()?.let {
                cacheTastePhoto(photo.id, it)
                photoVersion++
            }
        } finally { downloading.remove(photo.id) }
    }
}

// MARK: Chat

suspend fun AppStore.sendChat(agentID: String, text: String) {
    val turns = state.chats.getOrPut(agentID) { mutableListOf() }
    turns.add(ChatTurn(role = "user", text = text))
    chatBusy = agentID
    save()
    val history = turns.takeLast(14).map { mapOf("role" to it.role, "content" to it.text) }
    try {
        val r = Backend.function("chat", jobj("agent_id" to agentID, "messages" to history)).jsonObject
        val actions = (r["actions"] as? JsonArray)?.mapNotNull { a ->
            val o = a as? JsonObject ?: return@mapNotNull null
            ChatAction(o["type"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null,
                o["find_id"]?.jsonPrimitive?.contentOrNull, o["title"]?.jsonPrimitive?.contentOrNull)
        } ?: emptyList()
        state.chats.getOrPut(agentID) { mutableListOf() }.add(ChatTurn(role = "assistant", text = r["reply"]?.jsonPrimitive?.contentOrNull ?: "", actions = actions))
        Analytics.track(AnalyticsEvent.CHAT_SENT, mapOf("actions" to actions.size))
        if (actions.isNotEmpty()) pull()
    } catch (e: Exception) {
        state.chats.getOrPut(agentID) { mutableListOf() }.add(ChatTurn(role = "assistant",
            text = (e as? BackendError)?.message ?: "I lost the connection there. Send that again?"))
    }
    chatBusy = null
    state.chats[agentID]?.let { while (it.size > 60) it.removeAt(0) }
    save()
}

// MARK: Friends

suspend fun AppStore.addFriendCloud(raw: String): Pair<Boolean, String> {
    val h = raw.trim('@', ' ').lowercase()
    if (h.isEmpty()) return false to "Enter a friend's handle, like @maya."
    return try {
        val r = Backend.rpc("request_friend", jobj("p_handle" to h)).jsonObject
        pull()
        when (r["status"]?.jsonPrimitive?.contentOrNull) {
            "requested" -> { Analytics.track(AnalyticsEvent.FRIEND_INVITED); true to "Request sent to @$h" }
            "accepted" -> true to "You and @$h are now friends"
            "exists" -> false to "You've already added @$h."
            "self" -> false to "That's your own handle."
            else -> false to "No one on Baget goes by @$h. Check the spelling."
        }
    } catch (e: Exception) {
        false to ((e as? BackendError)?.message ?: "Couldn't send that request.")
    }
}

fun AppStore.respondToFriend(friend: Friend, accept: Boolean) {
    val fid = friend.friendshipID ?: return
    if (accept) state.friends.firstOrNull { it.id == friend.id }?.isPending = false
    else state.friends.removeAll { it.id == friend.id }
    save()
    push {
        it.rpc("respond_friend", jobj("p_id" to fid, "p_accept" to accept))
        pull()
    }
}

fun AppStore.replyToSuggestion(s: Suggestion, text: String) {
    val shareID = s.shareID ?: return
    push { it.insert("share_replies", jobj("share_id" to shareID, "body" to text.take(280))) }
}

// MARK: Push registration

/** At launch, or after setup asks: register this phone for push if notifications are allowed. */
suspend fun AppStore.registerForPushIfAllowed() {
    if (!Notifier.allowed(context)) return
    val token = Push.fetchToken() ?: return
    registerDevice(token)
}

suspend fun AppStore.registerDevice(token: String) {
    if (!isCloud) return
    pushRegistered = try {
        Backend.rpc("register_device", jobj("p_token" to token, "p_env" to "production", "p_platform" to "android"))
        Push.saveToken(context, token)
        true
    } catch (e: Exception) { false }
}
