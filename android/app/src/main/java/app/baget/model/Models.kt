package app.baget.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

fun uuid(): String = UUID.randomUUID().toString().lowercase()
fun now(): Long = System.currentTimeMillis()

// MARK: Categories ("missions")

@Serializable
enum class Category {
    @SerialName("sneakers") SNEAKERS,
    @SerialName("apparel") APPAREL,
    @SerialName("fragrance") FRAGRANCE,
    @SerialName("watches") WATCHES,
    @SerialName("cars") CARS,
    @SerialName("furniture") FURNITURE,
    @SerialName("accessories") ACCESSORIES,
    @SerialName("collectibles") COLLECTIBLES,
    /** Listings found for custom missions. Never offered as a mission or a section. */
    @SerialName("other") OTHER;

    val raw: String get() = name.lowercase()
    val info: CategoryInfo get() = categoryInfo(this)

    companion object {
        /** The missions people can pick. OTHER is deliberately left out. */
        val all = listOf(SNEAKERS, APPAREL, FRAGRANCE, WATCHES, CARS, FURNITURE, ACCESSORIES, COLLECTIBLES)
        fun of(raw: String?): Category? = entries.firstOrNull { it.raw == raw }
    }
}

/** Each mission speaks its own language: what a "trait", a "maker" and a "creator" mean there. */
data class CategoryInfo(
    val label: String, val symbol: String, val sizeRequired: Boolean, val sizeLabel: String?,
    val traitsLabel: String, val traitsPlaceholder: String, val makersLabel: String, val makersPlaceholder: String,
    val creatorsLabel: String, val creatorsPlaceholder: String,
    val traitNoun: String, val makerNoun: String, val creatorVerb: String, val creatorNoun: String,
)

private fun categoryInfo(c: Category): CategoryInfo = when (c) {
    Category.SNEAKERS -> CategoryInfo("Sneakers", "shoe", true, "Shoe size",
        "Silhouettes, colorways, materials", "Jordan 1, suede, low top", "Brands", "Jordan, New Balance",
        "Collabs and designers", "Travis Scott, Aimé Leon Dore", "details", "brand", "Made with", "a collaborator")
    Category.APPAREL -> CategoryInfo("Clothing", "shirt", true, "Clothing size",
        "Fits, fabrics, pieces", "boxy, heavyweight fleece, outerwear", "Labels", "Supreme, Stüssy",
        "Collabs and designers", "The North Face", "details", "label", "Made with", "a collaborator")
    Category.FRAGRANCE -> CategoryInfo("Fragrance", "drop", false, "Bottle size",
        "Notes you love", "oud, rose, saffron, incense", "Houses", "Frédéric Malle, MFK",
        "Perfumers", "Dominique Ropion", "notes", "house", "Composed by", "a perfumer")
    Category.WATCHES -> CategoryInfo("Watches", "watch", false, "Case size",
        "Styles and specs", "integrated bracelet, steel, diver", "Manufactures", "Audemars Piguet, Tudor",
        "Designers", "Gérald Genta", "specs", "manufacture", "Designed by", "a designer")
    Category.CARS -> CategoryInfo("Cars", "car", false, null,
        "Eras, body styles, specs", "air-cooled, manual, coupe", "Makes", "Porsche, BMW M",
        "Tuners and builders", "Singer, RUF", "specs", "make", "Built by", "a builder")
    Category.FURNITURE -> CategoryInfo("Furniture", "sofa", false, null,
        "Periods, materials, forms", "mid-century, walnut, cane", "Makers", "Herman Miller, Cassina",
        "Designers", "Pierre Jeanneret, Eames", "details", "maker", "Designed by", "a designer")
    Category.ACCESSORIES -> CategoryInfo("Accessories", "bag", false, null,
        "Materials and pieces", "sterling silver, leather, rings", "Makers", "Chrome Hearts, Goyard",
        "Designers", "Richard Stark", "details", "maker", "Designed by", "a designer")
    Category.COLLECTIBLES -> CategoryInfo("Collectibles", "star", false, null,
        "Sets, grades, formats", "Base Set, PSA 9, first press", "Brands and labels", "Pokémon, Medicom",
        "Artists", "KAWS, Daft Punk", "details", "brand", "By", "an artist")
    Category.OTHER -> CategoryInfo("Other", "sparkles", false, null, "Traits", "", "Makers", "",
        "Creators", "", "traits", "maker", "By", "a creator")
}

val customMissionInfo = CategoryInfo("Custom", "search", false, "Sizes or specs",
    "Traits you want", "condition, era, color, material", "Brands or makers", "Any you trust",
    "Creators or designers", "Anyone you follow", "traits", "maker", "By", "a creator")

// MARK: Catalog items

@Serializable
data class Offer(val store: String, val price: Double)

@Serializable
data class Item(
    val id: String,
    val title: String,
    val brand: String,
    val category: Category,
    val sku: String,
    /** 0 when the store doesn't show a price yet (see priceKnown). */
    val price: Double,
    /** Typical resale or secondhand price. Equals price when unknown. */
    val market: Double,
    val source: String,
    /** Sample listings only: minutes after the catalog start when this goes live. */
    val dropOffset: Double,
    val soldOutAtStart: Boolean,
    val creator: String? = null,
    val traits: List<String> = emptyList(),
    val tags: List<String> = emptyList(),
    val shoeSizes: List<Double>? = null,
    val topSizes: List<String>? = null,
    val url: String? = null,
    val imageURL: String? = null,
    val dropAt: Long? = null,
    val firstSeen: Long? = null,
    val priceKnown: Boolean = true,
    val isSample: Boolean = true,
    val offers: List<Offer>? = null,
    val lowPrice: Double? = null,
    val lowStore: String? = null,
    val about: String? = null,
    val brandAbout: String? = null,
) {
    /** Shown in Finds, Swipe and Today's Drop only once Baget has its real photo (sample listings always show). */
    val showable: Boolean get() = isSample || (imageURL?.startsWith("https://") == true)
}

// MARK: Agents

@Serializable
sealed class Mission {
    @Serializable @SerialName("category") data class Cat(@SerialName("category") val cat: Category) : Mission()
    @Serializable @SerialName("custom") data class Custom(val text: String) : Mission()

    val label: String get() = when (this) { is Cat -> cat.info.label; is Custom -> text }
    val info: CategoryInfo get() = when (this) { is Cat -> cat.info; is Custom -> customMissionInfo }
    val category: Category? get() = (this as? Cat)?.cat
}

@Serializable
enum class BuyMode(val label: String, val short: String) {
    @SerialName("alert") ALERT("Alert only", "Alert only"),
    @SerialName("ask") ASK("Ask before buying", "Asks to buy"),
    @SerialName("auto") AUTO("Auto-buy (beta)", "Auto-buy");
    val raw get() = name.lowercase()
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

@Serializable
enum class Voice(val label: String, val blurb: String) {
    @SerialName("hype") HYPE("Hype friend", "Excited, never lets you miss a drop"),
    @SerialName("chill") CHILL("Chill friend", "Easygoing, gives you the gist"),
    @SerialName("straight") STRAIGHT("Straight shooter", "Just the facts and the price");
    val raw get() = name.lowercase()
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

@Serializable
data class StyleProfile(
    var traits: MutableList<String> = mutableListOf(),
    var makers: MutableList<String> = mutableListOf(),
    var creators: MutableList<String> = mutableListOf(),
)

/** Per-agent texting, on top of the account's "How often Baget texts you". */
@Serializable
enum class AgentAlerts(val label: String, val short: String, val blurb: String) {
    @SerialName("normal") NORMAL("Normal texts", "Texts", "Follows your texting setting"),
    @SerialName("quiet") QUIET("Only the very best", "Quiet", "Only standout finds buzz your phone"),
    @SerialName("off") OFF("No texts", "Muted", "Finds still show up in the app, silently");
    val raw get() = name.lowercase()
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

@Serializable
data class TastePhoto(
    val id: String = uuid(),
    val addedAt: Long = now(),
    /** What the agent kept from the photo, after you reviewed it. */
    val tags: List<String>,
    val summary: String,
    /** Where the photo lives in cloud storage (signed in only). */
    var storagePath: String? = null,
)

@Serializable
data class Agent(
    val id: String,
    var name: String,
    var mission: Mission,
    var keywords: MutableList<String> = mutableListOf(),
    var style: StyleProfile = StyleProfile(),
    var size: String = "",
    var mode: BuyMode = BuyMode.ASK,
    var voice: Voice = Voice.CHILL,
    /** What the agent picked up from your buys and passes: positive = likes, negative = not into. */
    var learned: MutableMap<String, Int> = mutableMapOf(),
    /** Set when you pass on things for being too pricey. */
    var priceNote: Double = 0.0,
    /** Photos you showed the agent to teach it your taste (newest first, up to 6). */
    var tasteBoard: MutableList<TastePhoto> = mutableListOf(),
    var icon: Avatar? = null,
    var paused: Boolean = false,
    var alerts: AgentAlerts = AgentAlerts.NORMAL,
) {
    val isOff: Boolean get() = paused
    fun deepCopy(): Agent = copy(
        keywords = keywords.toMutableList(),
        style = StyleProfile(style.traits.toMutableList(), style.makers.toMutableList(), style.creators.toMutableList()),
        learned = learned.toMutableMap(), tasteBoard = tasteBoard.toMutableList(), icon = icon?.copy(),
    )
}

// MARK: Finds, purchases, notifications

@Serializable
enum class FindStatus {
    @SerialName("open") OPEN, @SerialName("liked") LIKED, @SerialName("passed") PASSED, @SerialName("acquired") ACQUIRED,
    /** Cleared from Finds without a pass: no learning, and the agent won't show it again. */
    @SerialName("removed") REMOVED;
    val raw get() = name.lowercase()
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

@Serializable
data class Find(
    val id: String,
    val itemID: String,
    val agentID: String,
    val score: Int,
    var why: List<String>,
    var status: FindStatus = FindStatus.OPEN,
    var passReason: String? = null,
    var watching: Boolean = false,
    val foundAt: Long = now(),
)

@Serializable
data class Purchase(
    val id: String = uuid(),
    val date: Long,
    val title: String,
    val amount: Double,
    val agentID: String,
    val category: Category,
    val isSample: Boolean = false,
    val listingID: String? = null,
    val agentName: String = "",
)

@Serializable
enum class NoteKind {
    @SerialName("release") RELEASE, @SerialName("available") AVAILABLE, @SerialName("steal") STEAL,
    @SerialName("watch") WATCH, @SerialName("restock") RESTOCK, @SerialName("bought") BOUGHT,
    @SerialName("budget") BUDGET, @SerialName("learned") LEARNED, @SerialName("friend") FRIEND,
    /** The 8am "Today's Drop" text, and a price drop on something you're watching. */
    @SerialName("digest") DIGEST, @SerialName("drop") DROP,
    /** A tester sent feedback (owner accounts only). */
    @SerialName("feedback") FEEDBACK,
    /** A release reminder the person set on an upcoming find. */
    @SerialName("reminder") REMINDER;

    val raw get() = name.lowercase()
    val group: NoteGroup? get() = when (this) {
        RELEASE, AVAILABLE, REMINDER, DIGEST -> NoteGroup.FINDS
        WATCH, RESTOCK -> NoteGroup.RESTOCKS
        STEAL, DROP -> NoteGroup.STEALS
        BOUGHT, BUDGET -> NoteGroup.MONEY
        LEARNED -> NoteGroup.LEARNING
        FRIEND, FEEDBACK -> null
    }
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

/** "Remind me" on an upcoming release: some minutes before the drop, or an exact time. */
@Serializable
data class ReleaseReminder(val remindAt: Long, val offsetMinutes: Int? = null)

@Serializable
enum class NoteGroup(val label: String) {
    @SerialName("finds") FINDS("New finds and drops"),
    @SerialName("restocks") RESTOCKS("Restocks"),
    @SerialName("steals") STEALS("Prices well under market"),
    @SerialName("money") MONEY("Purchases"),
    @SerialName("learning") LEARNING("What my agents learn");
    val raw get() = name.lowercase()
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

@Serializable
data class AppNote(
    val id: String = uuid(),
    val date: Long = now(),
    val agentID: String? = null,
    val friendID: String? = null,
    val kind: NoteKind,
    val body: String,
    val findID: String? = null,
    var read: Boolean = false,
    val heldForMorning: Boolean = false,
    val senderName: String = "",
)

// MARK: Friends

@Serializable
data class Friend(
    val id: String,
    var name: String,
    val handle: String,
    var hunts: List<Category>,
    var likes: List<String>,
    var isPending: Boolean = false,
    val isSample: Boolean = true,
    val replies: List<String> = emptyList(),
    val friendshipID: String? = null,
    val incoming: Boolean = false,
)

@Serializable
enum class SuggestionStatus { @SerialName("new") NEW, @SerialName("sent") SENT, @SerialName("passed") PASSED;
    val raw get() = name.lowercase()
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

@Serializable
data class Suggestion(
    val id: String,
    val friendID: String,
    val itemID: String,
    val note: String,
    val date: Long,
    var status: SuggestionStatus = SuggestionStatus.NEW,
    val shareID: String? = null,
)

@Serializable
data class ShareReply(val friendID: String, val text: String, val date: Long)

@Serializable
data class Share(
    val id: String = uuid(),
    val itemID: String,
    val to: List<String>,
    val note: String,
    val date: Long = now(),
    val isSuggestion: Boolean = false,
    val replies: MutableList<ShareReply> = mutableListOf(),
)

// MARK: Live bar and settings

@Serializable
sealed class LiveTabKind {
    @Serializable @SerialName("forYou") data object ForYou : LiveTabKind()
    @Serializable @SerialName("latest") data object Latest : LiveTabKind()
    @Serializable @SerialName("category") data class Cat(val category: Category) : LiveTabKind()
    @Serializable @SerialName("custom") data class Custom(val query: String) : LiveTabKind()
}

@Serializable
data class LiveTab(val id: String, val kind: LiveTabKind, val label: String) {
    companion object {
        val presets: List<LiveTab> get() =
            listOf(LiveTab("foryou", LiveTabKind.ForYou, "For you"), LiveTab("latest", LiveTabKind.Latest, "Latest")) +
                Category.all.map { LiveTab(it.raw, LiveTabKind.Cat(it), it.info.label) }
    }
}

@Serializable
enum class PushLevel(val label: String, val blurb: String) {
    @SerialName("best") BEST("Only the best", "Texts for strong matches (85%+) only, at most 6 a day, plus price drops, restocks, Today's Drop and friends."),
    @SerialName("all") ALL("Everything", "Every find, as it happens."),
    @SerialName("daily") DAILY("Daily only", "Just the 8am Today's Drop, plus price drops and restocks on things you're watching.");
    val raw get() = name.lowercase()
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

@Serializable
data class Settings(
    var sweepMinutes: Int = 180,
    var quietHours: Boolean = true,
    var groups: MutableSet<NoteGroup> = NoteGroup.entries.toMutableSet(),
    var shareTasteWithFriends: Boolean = true,
    var sharePurchasesWithFriends: Boolean = false,
    /** How often Baget texts you. Null means the default, BEST. */
    var pushLevel: PushLevel? = null,
    /** Free plan: the local hour the daily 4-hour hunting window starts. Null means 9am. */
    var huntStart: Int? = null,
)

/** Your icon: initials or an emoji on a colored tile, or a photo. */
@Serializable
data class Avatar(
    var style: Style = Style.INITIALS,
    var emoji: String = "🔥",
    var color: Int = 0,
    /** The photo's id: its file on this phone, and avatars/<id>.jpg in your account's photo folder. */
    var photoID: String? = null,
) {
    @Serializable
    enum class Style { @SerialName("initials") INITIALS, @SerialName("emoji") EMOJI, @SerialName("photo") PHOTO;
        val raw get() = name.lowercase()
        companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
    }
}

@Serializable
data class Profile(var handle: String, var displayName: String)

@Serializable
data class ChatAction(val type: String, val findID: String? = null, val title: String? = null)

@Serializable
data class ChatTurn(val id: String = uuid(), val role: String, val text: String, val actions: List<ChatAction> = emptyList())

@Serializable
data class LogLine(val id: String = uuid(), val date: Long = now(), val text: String)

@Serializable
data class AwayReport(val date: Long, val minutes: Int, val sweeps: Int, val checked: Int, val found: Int,
                      val bought: Int, val notes: Int, val restocks: Int)

/** One pick in the Today screen's "For You" feed. */
@Serializable
data class ForYouItem(val id: String, val reason: String, val kind: String, val findID: String? = null)

// MARK: Root state (saved as JSON; unknown or missing fields fall back to defaults)

@Serializable
data class AppState(
    var catalogStart: Long = now(),
    var agents: MutableList<Agent> = mutableListOf(),
    var finds: MutableList<Find> = mutableListOf(),
    var seenItemIDs: MutableSet<String> = mutableSetOf(),
    var restockedItemIDs: MutableSet<String> = mutableSetOf(),
    var purchases: MutableList<Purchase> = mutableListOf(),
    var notes: MutableList<AppNote> = mutableListOf(),
    var log: MutableList<LogLine> = mutableListOf(),
    var friends: MutableList<Friend> = mutableListOf(),
    var suggestions: MutableList<Suggestion> = mutableListOf(),
    var shares: MutableList<Share> = mutableListOf(),
    var liveTabs: MutableList<LiveTab> = LiveTab.presets.toMutableList(),
    var settings: Settings = Settings(),
    var lastSeen: Long = now(),
    var awayReport: AwayReport? = null,
    var accountID: String? = null,
    var profile: Profile? = null,
    var listings: MutableList<Item> = mutableListOf(),
    var chats: MutableMap<String, MutableList<ChatTurn>> = mutableMapOf(),
    var lastSynced: Long? = null,
    /** The person chose to look around with sample data instead of signing in. */
    var exploringSamples: Boolean = false,
    var avatar: Avatar = Avatar(),
    var forYou: List<ForYouItem> = emptyList(),
    var forYouAt: Long? = null,
    /** Release reminders you've set, by listing id. */
    var reminders: MutableMap<String, ReleaseReminder> = mutableMapOf(),
)
