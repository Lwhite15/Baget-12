package app.baget.engine

import app.baget.model.*
import java.text.NumberFormat
import java.text.Normalizer
import java.util.Calendar
import java.util.Currency
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Int from a Double that never throws on NaN or infinity (for example 0 / 0 when a price is unknown). */
fun safeInt(d: Double): Int = if (d.isFinite()) max(min(d, 1e9), -1e9).toInt() else 0
fun safeRound(d: Double): Int = if (d.isFinite()) max(min(d, 1e9), -1e9).roundToInt() else 0

fun String.capitalizedFirst(): String = if (isEmpty()) this else substring(0, 1).uppercase() + substring(1)

// MARK: Text helpers

object TextMatch {
    val stopWords = setOf("the", "and", "for", "any", "all", "with", "new", "old", "from", "that", "stuff", "things")
    private val marks = Regex("\\p{Mn}+")

    /** Lowercased, accent-free, trimmed ("Stüssy" -> "stussy"). */
    fun norm(s: String): String = marks.replace(Normalizer.normalize(s, Normalizer.Form.NFD), "").lowercase().trim()

    /** Either string contains the other ("rose" ~ "turkish rose"). */
    fun loose(a: String, b: String): Boolean {
        val x = norm(a); val y = norm(b)
        if (x.isEmpty() || y.isEmpty()) return false
        return x.contains(y) || y.contains(x)
    }

    /** Meaningful words of a query, with a trailing plural "s" dropped. */
    fun words(q: String): List<String> = norm(q).split(' ', ',')
        .filter { it.length > 1 && it !in stopWords }
        .map { if (it.endsWith("s") && it.length > 2) it.dropLast(1) else it }

    fun list(s: String): List<String> = s.split(',').map { it.trim() }.filter { it.isNotEmpty() }

    fun haystack(item: Item): String =
        norm((listOf(item.title, item.brand, item.category.info.label, item.creator ?: "") + item.traits + item.tags).joinToString(" "))

    /** Every word of the query appears somewhere in the listing. */
    fun matches(item: Item, query: String): Boolean {
        val ws = words(query)
        if (ws.isEmpty()) return false
        val hay = haystack(item)
        return ws.all { hay.contains(it) }
    }
}

// MARK: Sizes

object Sizes {
    val tops = listOf("XS", "S", "M", "L", "XL", "XXL")
    val euToUSMen: Map<Double, Double> = mapOf(36.0 to 4.0, 36.5 to 4.5, 37.5 to 5.0, 38.0 to 5.5, 38.5 to 6.0, 39.0 to 6.5, 40.0 to 7.0,
        40.5 to 7.5, 41.0 to 8.0, 42.0 to 8.5, 42.5 to 9.0, 43.0 to 9.5, 44.0 to 10.0, 44.5 to 10.5, 45.0 to 11.0, 45.5 to 11.5, 46.0 to 12.0,
        47.0 to 12.5, 47.5 to 13.0, 48.0 to 13.5, 48.5 to 14.0, 49.0 to 15.0)

    /** Converts "US M 10.5", "US W 12", "UK 9.5" or "EU 44.5" to US men's. */
    fun shoeUS(s: String): Double? {
        val up = s.uppercase()
        val n = Regex("[0-9.]+").findAll(up).mapNotNull { it.value.toDoubleOrNull() }.firstOrNull() ?: return null
        if (up.contains("EU")) return euToUSMen[n]
        if (up.contains("UK")) return n + 1
        val tokens = up.split(Regex("[^A-Z]+"))
        if (tokens.contains("W") || up.contains("WOMEN") || up.contains("WMNS")) return n - 1.5
        return n
    }

    fun topSize(s: String): String? {
        val tokens = s.uppercase().replace("2XL", "XXL").split(Regex("[^A-Z0-9]+"))
        return tokens.firstOrNull { it in listOf("XXS", "XS", "S", "M", "L", "XL", "XXL") }
    }

    fun hasPants(s: String): Boolean = Regex("\\d+\\s*[xX]\\s*\\d+").containsMatchIn(s)

    fun required(a: Agent): Boolean = a.mission.category?.info?.sizeRequired ?: false

    fun has(a: Agent): Boolean = when (a.mission.category) {
        Category.SNEAKERS -> shoeUS(a.size) != null
        Category.APPAREL -> topSize(a.size) != null || hasPants(a.size)
        else -> true
    }

    /** true = in stock in your size, false = not, null = sizes don't apply. */
    fun fit(a: Agent, item: Item): Boolean? = when (item.category) {
        Category.SNEAKERS -> {
            val stock = item.shoeSizes; val u = shoeUS(a.size)
            if (stock == null || u == null) null else stock.contains(u)
        }
        Category.APPAREL -> {
            val stock = item.topSizes; val t = topSize(a.size)
            if (stock == null || t == null) null else stock.contains(t)
        }
        else -> null
    }

    fun display(d: Double): String = if (d % 1.0 == 0.0) d.toInt().toString() else d.toString()
}

// MARK: Matching

data class Match(val score: Int, val why: List<String>, val notInSize: Boolean = false)

object Matcher {
    fun covers(a: Agent, item: Item): Boolean = when (val m = a.mission) {
        is Mission.Cat -> m.category == item.category
        is Mission.Custom -> {
            val hay = TextMatch.haystack(item)
            TextMatch.words(m.text).any { hay.contains(it) }
        }
    }

    /** How well the agent knows the shopper, 0-100. */
    fun intel(a: Agent): Int {
        var k = 26
        k += min(a.keywords.size, 5) * 6
        k += if (a.size.isNotEmpty() || !a.mission.info.sizeRequired) 10 else 0
        k += min(a.style.traits.size, 5) * 6
        k += min(a.style.makers.size, 3) * 5
        k += min(a.style.creators.size, 2) * 5
        return min(100, k)
    }

    fun match(a: Agent, item: Item): Match? {
        if (!covers(a, item)) return null
        if (Sizes.required(a) && !Sizes.has(a)) return null           // no size, no hunting
        val fit = Sizes.fit(a, item)
        if (fit == false) return Match(0, listOf("Not in stock in your size (${a.size})"), notInSize = true)

        val info = item.category.info
        val why = mutableListOf<String>()
        var pts = 0.0
        val hay = TextMatch.norm((listOf(item.title, item.brand) + item.tags + item.traits).joinToString(" "))
        val hits = a.keywords.filter { it.isNotEmpty() && hay.contains(TextMatch.norm(it)) }
        if (hits.isNotEmpty()) { pts += hits.size * 12; why.add("Matches your keywords: ${hits.take(3).joinToString(", ")}") }
        if (a.style.makers.any { TextMatch.loose(it, item.brand) }) {
            pts += 20; why.add("From ${item.brand}, a ${info.makerNoun} you like")
        }
        val c = item.creator
        if (c != null && a.style.creators.any { TextMatch.loose(it, c) }) {
            pts += 18; why.add("${info.creatorVerb} $c, ${info.creatorNoun} you follow")
        }
        val shared = a.style.traits.filter { t -> item.traits.any { TextMatch.loose(it, t) } }
        if (shared.isNotEmpty()) {
            pts += shared.size * 9
            val photoTags = a.tasteBoard.flatMap { p -> p.tags.map(TextMatch::norm) }.toSet()
            val fromPhotos = shared.filter { TextMatch.norm(it) in photoTags }
            val fromBrief = shared.filter { TextMatch.norm(it) !in photoTags }
            if (fromBrief.isNotEmpty()) why.add("Shares your ${fromBrief.joinToString(", ")} ${info.traitNoun}")
            if (fromPhotos.isNotEmpty()) why.add("Like your taste photos: ${fromPhotos.joinToString(", ")}")
        }
        val mission = a.mission
        if (mission is Mission.Custom && why.isEmpty()) { pts += 14; why.add("Fits your mission: ${mission.text}") }

        // What the agent learned from your buys and passes
        val keys = item.traits + item.brand
        val liked = keys.filter { (a.learned[TextMatch.norm(it)] ?: 0) > 0 }
        val disliked = keys.filter { (a.learned[TextMatch.norm(it)] ?: 0) < 0 }
        if (liked.isNotEmpty()) {
            pts += liked.sumOf { min(3, a.learned[TextMatch.norm(it)] ?: 0) * 6 }
            why.add("You've gone for ${liked.take(3).joinToString(", ")} before")
        }
        if (disliked.isNotEmpty()) {
            pts += disliked.sumOf { max(-3, a.learned[TextMatch.norm(it)] ?: 0) * 8 }
            why.add("Heads up: you passed on ${disliked.take(2).joinToString(", ")} before")
        }

        val intelBoost = intel(a).toDouble()
        if (fit == true) why.add("In stock in your size, ${a.size}")
        if (why.isEmpty() || (why.size == 1 && fit == true)) {
            return Match(safeRound(28 + intelBoost * 0.12), listOf("Broad mission match only") + why)
        }
        val s = safeRound(35 + pts * 0.55 + intelBoost * 0.1)
        return Match(max(5, min(98, s)), why)
    }
}

// MARK: Money and dates

object Fmt {
    private val currency: NumberFormat by lazy {
        NumberFormat.getCurrencyInstance(Locale.US).apply { this.currency = Currency.getInstance("USD"); maximumFractionDigits = 0 }
    }

    fun money(v: Double): String = runCatching { currency.format(v) }.getOrDefault("$${safeInt(v)}")

    fun monthKey(d: Long): String {
        val c = Calendar.getInstance().apply { timeInMillis = d }
        return String.format(Locale.US, "%04d-%02d", c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1)
    }

    fun ago(d: Long): String {
        val m = ((now() - d) / 60000).toInt()
        return when {
            m < 1 -> "now"
            m < 60 -> "${m}m"
            m < 1440 -> "${m / 60}h"
            else -> "${m / 1440}d"
        }
    }
}

// MARK: Friend-style texts

object FriendVoice {
    fun line(a: Agent, kind: NoteKind, item: Item?, extra: String = "", whenText: String = ""): String {
        val t = item?.title ?: ""
        val src = item?.source ?: ""
        val price = item?.let { Fmt.money(it.price) } ?: ""
        val hook = item?.let { hookFor(a, it) } ?: ""
        val pct = item?.let { safeRound((1 - it.price / max(it.market, 1.0)) * 100) } ?: 0
        val market = item?.let { Fmt.money(it.market) } ?: ""
        val v = a.voice
        return when (kind) {
            NoteKind.RELEASE -> when (v) {
                Voice.HYPE -> "Yo! The $t drops $whenText at $src. Total $hook energy. Want me to line up checkout?"
                Voice.CHILL -> "Heads up, the $t drops $whenText at $src. It's very your $hook thing. Want me to get checkout ready?"
                Voice.STRAIGHT -> "$t releases $whenText at $src, $price. Matches your $hook preference."
            }
            NoteKind.AVAILABLE -> when (v) {
                Voice.HYPE -> "Found one for you! The $t is up right now at $src for $price. It's so you."
                Voice.CHILL -> "Found something you'll like: the $t, $price at $src. Has that $hook thing you're into."
                Voice.STRAIGHT -> "$t is available at $src for $price.${if (extra.isEmpty()) "" else " $extra% match."}"
            }
            NoteKind.STEAL -> when (v) {
                Voice.HYPE -> "Okay this is a steal: the $t is $price, about $pct% under what it trades for. Don't sleep on it."
                Voice.CHILL -> "The $t is going for $price, roughly $pct% under market. Worth a look if you still want one."
                Voice.STRAIGHT -> "$t: asking $price, market $market. About $pct% under."
            }
            NoteKind.WATCH -> when (v) {
                Voice.HYPE -> "Ugh, the $t sold out before I could get to it. I'm camped out for the restock."
                Voice.CHILL -> "The $t is sold out right now. I'll keep watching and tell you the second it's back."
                Voice.STRAIGHT -> "$t is sold out. Restock watch is on."
            }
            NoteKind.RESTOCK -> when (v) {
                Voice.HYPE -> "IT'S BACK. The $t just restocked at $src. Want me to grab it before it's gone again?"
                Voice.CHILL -> "Good news, the $t is back in stock at $src. Want it?"
                Voice.STRAIGHT -> "Restock: $t at $src, $price. Tap to review checkout."
            }
            NoteKind.BOUGHT -> when (v) {
                Voice.HYPE -> "Done! Grabbed the $t for $price. It's in your Finds."
                Voice.CHILL -> "Got it for you: the $t, $price. It's in your Finds."
                Voice.STRAIGHT -> "Purchased $t for $price. It's in your Finds."
            }
            NoteKind.BUDGET -> "Still hunting for you."
            NoteKind.LEARNED -> when (v) {
                Voice.HYPE -> "Noticed you're really into $extra lately. Hunting more of that now!"
                Voice.CHILL -> "Seems like $extra is your thing lately. I'll keep an eye out for more."
                Voice.STRAIGHT -> "Profile updated: added $extra."
            }
            NoteKind.FRIEND -> extra
            NoteKind.DIGEST -> extra.ifEmpty { "Today's Drop is ready: your squad's best picks." }
            NoteKind.DROP -> "Price drop: the $t is now $price at $src."
            NoteKind.FEEDBACK -> extra
            NoteKind.REMINDER -> "Reminder: the $t releases $whenText at $src."
        }
    }

    /** The item's own trait that matches your profile, so the text names something real about it. */
    fun hookFor(a: Agent, item: Item): String {
        item.traits.firstOrNull { x -> a.style.traits.any { TextMatch.loose(x, it) } }?.let { return it }
        if (a.style.makers.any { TextMatch.loose(it, item.brand) }) return item.brand
        return item.traits.firstOrNull() ?: item.brand
    }
}

/** Picks an emoji that fits what a scout hunts, from its name, mission and keywords. */
object AgentEmoji {
    private val rules: List<Pair<List<String>, String>> = listOf(
        listOf("glock", "pistol", "handgun", "rifle", "firearm", "holster", "optic", "sights", "ammo", "tactical") to "🎯",
        listOf("knife", "knives", "blade", "edc") to "🔪",
        listOf("sneaker", "jordan", "dunk", "yeezy", "nike", "new balance", "kicks", "trainer", "air max", "shoe") to "👟",
        listOf("boot", "loafer", "heel") to "🥾",
        listOf("fragrance", "perfume", "parfum", "cologne", "scent", "oud", "extrait", "longevity", "smell") to "🧴",
        listOf("watch", "rolex", "omega", "patek", "audemars", "seiko", "timepiece", "chronograph") to "⌚️",
        listOf("porsche", "ferrari", "lambo", "car", "cars", "vehicle", "gt3", "bmw", "mercedes", "911", "truck", "jdm") to "🏎️",
        listOf("motorcycle", "motorbike", "ducati", "harley") to "🏍️",
        listOf("sofa", "couch", "chair", "furniture", "table", "lamp", "eames", "decor", "rug", "interior") to "🛋️",
        listOf("vinyl", "record", "turntable", "album") to "💿",
        listOf("headphone", "speaker", "audio", "hifi", "hi-fi") to "🎧",
        listOf("camera", "lens", "leica", "film") to "📸",
        listOf("art", "print", "painting", "poster") to "🎨",
        listOf("card", "pokemon", "pokémon", "tcg", "graded", "psa") to "🃏",
        listOf("toy", "figure", "lego", "bearbrick", "kaws", "collectible", "funko") to "🧸",
        listOf("comic", "manga", "book") to "📚",
        listOf("game", "console", "nintendo", "playstation", "xbox", "gaming") to "🎮",
        listOf("laptop", "phone", "iphone", "tech", "gadget", "computer", "pc") to "💻",
        listOf("golf") to "⛳️",
        listOf("bike", "cycling", "bicycle") to "🚲",
        listOf("surf", "skate", "snowboard", "ski") to "🏄",
        listOf("fishing", "outdoor", "camping", "hiking", "gear") to "🏕️",
        listOf("wine", "whiskey", "bourbon", "tequila", "spirits", "liquor") to "🥃",
        listOf("coffee", "espresso") to "☕️",
        listOf("jewelry", "jewellery", "ring", "chain", "diamond", "necklace", "bracelet", "cartier") to "💎",
        listOf("bag", "handbag", "purse", "hermes", "hermès", "birkin", "backpack", "wallet") to "👜",
        listOf("sunglass", "glasses", "eyewear") to "🕶️",
        listOf("hat", "cap", "beanie") to "🧢",
        listOf("supreme", "hoodie", "streetwear", "tee", "shirt", "jacket", "apparel", "clothes", "clothing", "denim", "jeans", "drip", "fashion") to "🧥",
        listOf("plant", "garden") to "🌿",
        listOf("deal", "discount", "sale", "bargain") to "🏷️",
        listOf("grail", "rare", "limited", "exclusive", "drop") to "🔥",
    )

    private val byCategory = mapOf(
        Category.SNEAKERS to "👟", Category.APPAREL to "🧥", Category.FRAGRANCE to "🧴", Category.WATCHES to "⌚️", Category.CARS to "🏎️",
        Category.FURNITURE to "🛋️", Category.ACCESSORIES to "🕶️", Category.COLLECTIBLES to "🧸", Category.OTHER to "🕵️",
    )

    fun pick(name: String, mission: Mission? = null, keywords: List<String> = emptyList()): String {
        val parts = mutableListOf(name) + keywords + listOfNotNull((mission as? Mission.Custom)?.text)
        val text = " " + parts.joinToString(" ").lowercase().replace(Regex("[^\\p{L}\\p{N}\\- ]+"), " ") + " "
        val c = mission?.category
        if (c != null && c in setOf(Category.SNEAKERS, Category.FRAGRANCE, Category.WATCHES, Category.CARS, Category.FURNITURE)) byCategory[c]?.let { return it }
        for ((words, emoji) in rules) if (words.any { matches(text, it) }) return emoji
        if (c != null) byCategory[c]?.let { return it }
        return "🕵️"
    }

    fun pick(agent: Agent): String = pick(agent.name, agent.mission, agent.keywords)

    /** Whole word, allowing a plural or -ing ending. */
    private fun matches(text: String, word: String): Boolean =
        Regex("(?<![\\p{L}\\p{N}])" + Regex.escape(word) + "(s|es|ing)?(?![\\p{L}\\p{N}])").containsMatchIn(text)
}
