package app.baget.engine

import app.baget.model.Catalog
import app.baget.model.Find
import app.baget.model.FindStatus
import app.baget.model.ForYouItem
import app.baget.model.Item

/**
 * The same product at another store: same brand and nearly the same title words, with matching model numbers.
 * Mirrors public.same_product on the server (and ProductMatch.swift on iPhone).
 */
object ProductMatch {
    private val filler = setOf("the", "and", "for", "with", "new", "men", "mens", "women", "womens", "unisex", "size",
        "shoe", "shoes", "sneaker", "sneakers", "eau", "parfum", "toilette", "edp", "edt", "spray")

    fun words(t: String): Set<String> =
        t.lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }
            .filter { (it.length > 2 || it.any(Char::isDigit)) && it !in filler }.toSet()

    fun brandKey(b: String): String = b.lowercase().filter { it.isLetterOrDigit() }

    fun same(a: Item, b: Item): Boolean {
        if (a.id == b.id || brandKey(a.brand) != brandKey(b.brand)) return false
        return sameWords(words(a.title), words(b.title))
    }

    fun sameWords(wa: Set<String>, wb: Set<String>): Boolean {
        if (wa.isEmpty() || wb.isEmpty()) return false
        val hit = wa.intersect(wb).size.toDouble()
        val ra = hit / wa.size; val rb = hit / wb.size
        if (minOf(ra, rb) < 0.7 || maxOf(ra, rb) < 0.85) return false
        val na = wa.filter { w -> w.any(Char::isDigit) } - wb
        val nb = wb.filter { w -> w.any(Char::isDigit) } - wa
        return na.isEmpty() || nb.isEmpty()
    }

    /** The same product from several stores, shown once: at its lowest price, with the other stores one tap away. */
    class Group(val lead: Find, val others: List<Find>) { val storeCount get() = others.size + 1 }

    private var memo: Pair<Int, List<Group>>? = null

    /** Groups finds that are the same product. Compares only within a brand, so it stays quick with hundreds of finds. */
    fun group(finds: List<Find>): List<Group> {
        val key = finds.fold(17) { h, f -> h * 31 + f.id.hashCode() * 7 + f.status.hashCode() }
        memo?.let { if (it.first == key) return it.second }
        val v = makeGroups(finds)
        memo = key to v
        return v
    }

    private class Row(val find: Find, val item: Item, val words: Set<String>)

    private fun price(i: Item) = if (i.priceKnown && i.price > 0) i.price else Double.POSITIVE_INFINITY

    private fun makeGroups(finds: List<Find>): List<Group> {
        val byBrand = LinkedHashMap<String, MutableList<Row>>()
        for (f in finds) {
            val item = Catalog.item(f.itemID) ?: continue
            byBrand.getOrPut(brandKey(item.brand)) { mutableListOf() }.add(Row(f, item, words(item.title)))
        }
        val groups = mutableListOf<MutableList<Row>>()
        val groupIndex = HashMap<String, Int>()
        for ((k, rows) in byBrand) {
            val mine = mutableListOf<Int>()
            for (r in rows) {
                // Only real products with a brand are grouped; the rest stand alone.
                val match = if (k.isEmpty() || !r.item.isProduct) null
                    else mine.firstOrNull { gi -> groups[gi].any { g -> sameWords(r.words, g.words) } }
                if (match != null) { groups[match].add(r); groupIndex[r.find.id] = match }
                else { groups.add(mutableListOf(r)); mine.add(groups.size - 1); groupIndex[r.find.id] = groups.size - 1 }
            }
        }
        // Keep the list's own order: each group appears where its first member was.
        val seen = HashSet<Int>()
        val out = mutableListOf<Group>()
        for (f in finds) {
            val gi = groupIndex[f.id] ?: continue
            if (!seen.add(gi)) continue
            val members = groups[gi].sortedWith(compareBy<Row> { price(it.item) }.thenByDescending { it.find.score }).map { it.find }
            out.add(Group(members[0], members.drop(1)))
        }
        return out
    }

    private var dedupeMemo: Pair<Int, Pair<List<ForYouItem>, Map<String, Int>>>? = null

    /** For You picks with the same product from other stores folded in: the first (best ranked) stays, with a count. */
    fun dedupe(picks: List<ForYouItem>): Pair<List<ForYouItem>, Map<String, Int>> {
        val key = picks.fold(17) { h, p -> h * 31 + p.id.hashCode() }
        dedupeMemo?.let { if (it.first == key) return it.second }
        val kept = mutableListOf<ForYouItem>()
        val keptWords = HashMap<String, MutableList<Pair<String, Set<String>>>>()
        val alsoAt = HashMap<String, Int>()
        for (p in picks) {
            val item = Catalog.item(p.id) ?: continue
            val k = brandKey(item.brand); val w = words(item.title)
            val hit = if (k.isNotEmpty() && item.isProduct) keptWords[k]?.firstOrNull { sameWords(w, it.second) } else null
            if (hit != null) { alsoAt[hit.first] = (alsoAt[hit.first] ?: 0) + 1; continue }
            kept.add(p)
            keptWords.getOrPut(k) { mutableListOf() }.add(p.id to w)
        }
        val v = kept to alsoAt
        dedupeMemo = key to v
        return v
    }
}

/** Your other finds that are this same product (any store), cheapest first. Open or saved ones only. */
fun AppStore.sameProductFinds(find: Find): List<Find> {
    val item = Catalog.item(find.itemID) ?: return emptyList()
    if (!item.isProduct) return emptyList()
    fun p(f: Find) = Catalog.item(f.itemID)?.let { if (it.priceKnown && it.price > 0) it.price else null } ?: Double.POSITIVE_INFINITY
    return state.finds.filter { f ->
        f.id != find.id && (f.status == FindStatus.OPEN || f.status == FindStatus.LIKED) &&
            Catalog.item(f.itemID)?.let { ProductMatch.same(item, it) } == true
    }.sortedBy { p(it) }
}
