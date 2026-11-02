package app.baget.engine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.baget.model.*
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.*
import java.io.File

// Friends, icons, rings, Taste Cards, birthdays, usernames, report and block: the same server calls as the iPhone app.

/** Friends' icons and rings, and your rings. Kept outside the saved state: the server is the source. */
object FriendsState {
    /** Friends' icons (what they picked in Settings), by friend id. */
    val icons = mutableStateMapOf<String, Avatar>()
    /** The ring each friend shows, and their taste palette (for the "taste palette" icon color), by friend id. */
    val rings = mutableStateMapOf<String, String>()
    val palettes = mutableStateMapOf<String, List<String>>()
    /** Your rings (server: my_rings), and a ring you just earned (shown once as a toast). */
    var mine by mutableStateOf<RingState?>(null)
    var ringEarned by mutableStateOf<String?>(null)
    fun clear() { icons.clear(); rings.clear(); palettes.clear(); mine = null; ringEarned = null }
}

val AppStore.friendIcons: Map<String, Avatar> get() = FriendsState.icons
val AppStore.friendRings: Map<String, String> get() = FriendsState.rings
val AppStore.friendPalettes: Map<String, List<String>> get() = FriendsState.palettes
val AppStore.rings: RingState? get() = FriendsState.mine
/** Your Taste Card's palette, when it has one. */
val AppStore.myPalette: List<String> get() = FriendsState.mine?.palette ?: emptyList()

// MARK: Rows

@Serializable
data class FriendIconRow(val friendId: String, val icon: JsonElement? = null, val ring: String? = null, val palette: List<String>? = null)

/** Your rings, as the server sees them. */
@Serializable
data class RingState(
    val owned: List<Owned> = emptyList(), val new: List<String> = emptyList(), val wearing: String? = null,
    val pro: Boolean = false, val streak: Int = 0, val friends: Int = 0, val palette: List<String>? = null,
) {
    @Serializable data class Owned(val ring: String, val earnedAt: String? = null)
    fun owns(r: String): Boolean = if (r == "pro_glow") pro else owned.any { it.ring == r }
}

/** One Taste Card: an AI-written archetype, signature brands, notes and a palette (server: taste_card). */
@Serializable
data class TasteCard(
    val archetype: String = "", val signature: List<String> = emptyList(), val notes: List<String> = emptyList(),
    val hunts: List<String> = emptyList(), val grail: String? = null, val palette: List<String> = emptyList(),
    val number: Int? = null, val friendId: String? = null, val name: String? = null, val handle: String? = null,
)

/** Everything a friend's profile shows (server: friend_profile). Taste parts are there only when both share taste. */
@Serializable
data class FriendProfile(
    val friendId: String, val handle: String? = null, val name: String? = null, val since: String? = null,
    val shares: Boolean = false, val theyShare: Boolean? = null, val match: Int? = null, val dna: List<DNA>? = null,
    val bothLove: List<String>? = null, val theirWorld: List<String>? = null, val hunts: List<String>? = null,
    val grails: List<Grail>? = null, val twins: List<ListingRow>? = null, val gifts: List<ListingRow>? = null,
    val birthday: String? = null, val card: TasteCard? = null, val myCard: TasteCard? = null,
) {
    @Serializable data class DNA(val label: String, val who: String, val strength: Double = 0.0)
    @Serializable data class Grail(val listing: ListingRow, val tag: String = "liked")
}

@Serializable
data class UpcomingBirthday(val friendId: String, val name: String? = null, val handle: String? = null, val birthday: String,
                            val days: Int = 0, val shares: Boolean = false) {
    val first: String get() {
        val n = (name ?: "").trim()
        return if (n.isEmpty()) "@${handle ?: ""}" else n.split(" ").firstOrNull() ?: n
    }
    val whenLabel: String get() = when (days) { 0 -> "Today"; 1 -> "Tomorrow"; else -> "In $days days" }
}

@Serializable
data class BlockedPerson(val userId: String, val handle: String = "", val displayName: String = "")

@Serializable
private data class MatchRow(val friendId: String, val match: Int? = null)

object Birthday {
    private val months = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    val monthNames = listOf("January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December")
    /** "11-12" → "Nov 12". */
    fun label(mmdd: String?): String? {
        if (mmdd == null || mmdd.length != 5) return null
        val m = mmdd.take(2).toIntOrNull() ?: return null
        val d = mmdd.takeLast(2).toIntOrNull() ?: return null
        if (m !in 1..12 || d !in 1..31) return null
        return "${months[m - 1]} $d"
    }
    fun daysIn(month: Int): Int = listOf(31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)[(month - 1).coerceIn(0, 11)]
}

/** Report reasons (the raw value is what the server stores). */
enum class ReportReason(val raw: String, val label: String) {
    SPAM("spam", "Spam or scams"), INAPPROPRIATE("inappropriate", "Inappropriate photo or name"),
    HARASSMENT("harassment", "Harassment or hateful messages"), OTHER("other", "Something else")
}

// MARK: Calls

/** Friends' icons, rings and palettes (server: friend_icons). */
suspend fun AppStore.refreshFriendIcons() {
    if (!isCloud) return
    val rows = runCatching { Backend.rpc("friend_icons", JsonObject(emptyMap()), ListSerializer(FriendIconRow.serializer())) }.getOrNull() ?: return
    FriendsState.icons.clear(); FriendsState.rings.clear(); FriendsState.palettes.clear()
    for (r in rows) {
        iconFromJson(r.icon)?.let { FriendsState.icons[r.friendId] = it }
        r.ring?.let { FriendsState.rings[r.friendId] = it }
        r.palette?.let { FriendsState.palettes[r.friendId] = it }
    }
}

/** Fetches your rings (awarding any you've just earned). */
suspend fun AppStore.refreshRings() {
    if (!isCloud) return
    val r = runCatching { Backend.rpc("my_rings", JsonObject(emptyMap()), RingState.serializer()) }.getOrNull() ?: return
    FriendsState.mine = r
    r.new.firstOrNull()?.let { FriendsState.ringEarned = it }
}

/** Wear a ring you own (null takes it off). The server refuses rings you don't own. */
suspend fun AppStore.wearRing(ring: String?): Boolean {
    val uid = Backend.userID
    if (!isCloud || uid == null) return false
    return try {
        Backend.update("profiles", "id=eq.$uid", jobj("ring" to ring))
        refreshRings()
        Analytics.track(AnalyticsEvent.AVATAR_CHANGED, mapOf("ring" to (ring ?: "none")))
        true
    } catch (e: Exception) { false }
}

/** Taste match % for each friend who shares taste (server: friend_matches), keyed by friend id. */
suspend fun AppStore.friendMatches(): Map<String, Int> {
    if (!isCloud) return emptyMap()
    val rows = runCatching { Backend.rpc("friend_matches", JsonObject(emptyMap()), ListSerializer(MatchRow.serializer())) }.getOrNull() ?: return emptyMap()
    return rows.mapNotNull { r -> r.match?.let { r.friendId to it } }.toMap()
}

suspend fun AppStore.friendProfile(id: String): FriendProfile? {
    if (!isCloud) return null
    val e = runCatching { Backend.rpc("friend_profile", jobj("p_friend" to id)) }.getOrNull() ?: return null
    if (e !is JsonObject) return null
    val p = runCatching { rowJson.decodeFromJsonElement(FriendProfile.serializer(), e) }.getOrNull() ?: return null
    for (l in (p.grails ?: emptyList()).map { it.listing } + (p.twins ?: emptyList()) + (p.gifts ?: emptyList())) Catalog.cloud[l.id] = l.item
    return p
}

suspend fun AppStore.myTasteCard(): TasteCard? {
    if (!isCloud) return null
    val e = runCatching { Backend.rpc("my_taste_card") }.getOrNull() as? JsonObject ?: return null
    return runCatching { rowJson.decodeFromJsonElement(TasteCard.serializer(), e) }.getOrNull()
}

suspend fun AppStore.friendCards(): List<TasteCard> {
    if (!isCloud) return emptyList()
    return runCatching { Backend.rpc("friend_cards", JsonObject(emptyMap()), ListSerializer(TasteCard.serializer())) }.getOrNull() ?: emptyList()
}

/** Month and day ("11-12") shown to friends who share taste, or null to clear. */
suspend fun AppStore.setBirthday(mmdd: String?) {
    val uid = Backend.userID
    if (!isCloud || uid == null) return
    runCatching { Backend.update("profiles", "id=eq.$uid", jobj("birthday" to mmdd)) }
}

suspend fun AppStore.myBirthday(): String? {
    val uid = Backend.userID
    if (!isCloud || uid == null) return null
    val rows = runCatching { Backend.selectRaw("profiles", "select=birthday&id=eq.$uid") }.getOrNull() as? JsonArray ?: return null
    return (rows.firstOrNull() as? JsonObject)?.get("birthday")?.jsonPrimitive?.contentOrNull
}

/** Friends whose birthday is within the next three weeks, soonest first. */
suspend fun AppStore.upcomingBirthdays(): List<UpcomingBirthday> {
    if (!isCloud) return emptyList()
    return runCatching { Backend.rpc("upcoming_birthdays", jobj("p_days" to 21), ListSerializer(UpcomingBirthday.serializer())) }.getOrNull() ?: emptyList()
}

/** "available", "taken", "yours" or "invalid" for a username (server: handle_available). */
suspend fun AppStore.handleAvailability(handle: String): String? {
    if (!isCloud) return null
    return runCatching { Backend.rpc("handle_available", jobj("p_handle" to handle)).jsonPrimitive.contentOrNull }.getOrNull()
}

/** What the invite says: who you are on Baget and how to find you. */
val AppStore.inviteMessage: String get() {
    val h = state.profile?.handle ?: ""
    return if (h.isEmpty()) "I'm hunting on Baget. Add me so we can compare our taste."
    else "I'm hunting on Baget. Add me, @$h, so we can compare our taste."
}

// MARK: Report and block. A block ends the friendship, removes what they sent you, and stops them finding, adding or
// sending you anything, both ways. Reports go to the Baget team, reviewed within 24 hours.

suspend fun AppStore.blockUser(id: String): Boolean {
    if (!isCloud) return false
    return try {
        Backend.rpc("block_user", jobj("p_user" to id))
        state.friends.removeAll { it.id == id }
        state.suggestions.removeAll { it.friendID == id }
        save()
        true
    } catch (e: Exception) { syncProblem = "Couldn't block right now. Try again."; false }
}

suspend fun AppStore.unblockUser(id: String) {
    runCatching { Backend.rpc("unblock_user", jobj("p_user" to id)) }
}

suspend fun AppStore.reportUser(id: String, reason: ReportReason, detail: String, suggestionID: String?): Boolean {
    if (!isCloud) return false
    val args = mutableMapOf<String, Any?>("p_user" to id, "p_reason" to reason.raw, "p_detail" to detail)
    if (suggestionID != null) args["p_suggestion"] = suggestionID
    return try { Backend.rpc("report_user", toJson(args) as JsonObject); true }
    catch (e: Exception) { syncProblem = "Couldn't send the report. Try again."; false }
}

suspend fun AppStore.blockedPeople(): List<BlockedPerson> =
    runCatching { Backend.rpc("my_blocks", JsonObject(emptyMap()), ListSerializer(BlockedPerson.serializer())) }.getOrNull() ?: emptyList()

// MARK: Icons

fun AppStore.setAvatarGlyph(glyph: String) {
    state.avatar.glyph = glyph
    state.avatar.style = Avatar.Style.BAGET
    save()
}

private fun AppStore.iconFile(id: String) = File(File(context.filesDir, "avatar").also { it.mkdirs() }, "$id.jpg")

/** A friend's icon photo (<their id>/avatars/<photo>.jpg), downloaded once and kept on this phone. */
fun AppStore.friendIconImage(friendID: String, photoID: String?): Bitmap? {
    avatarVersion
    val id = photoID ?: return null
    if (!Regex("^[0-9a-zA-Z-]{8,64}$").matches(id)) return null
    val f = iconFile(id)
    if (f.exists()) BitmapFactory.decodeFile(f.path)?.let { return it }
    val key = "avatar-$id"
    if (!isCloud || key in downloading) return null
    downloading.add(key)
    val path = "$friendID/avatars/$id.jpg"
    scope.launch {
        try {
            val data = runCatching { Backend.download("taste-photos", path) }.getOrNull()
            if (data != null && BitmapFactory.decodeByteArray(data, 0, data.size) != null) {
                runCatching { f.writeBytes(data) }
                avatarVersion++
            }
        } finally { downloading.remove(key) }
    }
    return null
}
