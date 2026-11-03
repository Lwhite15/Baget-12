import Foundation

/// The same product at another store: same brand and nearly the same title words, with matching model numbers.
/// Mirrors public.same_product on the server.
enum ProductMatch {
    private static let filler: Set<String> = ["the", "and", "for", "with", "new", "men", "mens", "women", "womens", "unisex", "size",
                                              "shoe", "shoes", "sneaker", "sneakers", "eau", "parfum", "toilette", "edp", "edt", "spray"]

    static func words(_ t: String) -> Set<String> {
        Set(t.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
            .filter { ($0.count > 2 || $0.contains(where: \.isNumber)) && !filler.contains($0) })
    }

    static func brandKey(_ b: String) -> String { b.lowercased().filter { $0.isLetter || $0.isNumber } }

    static func same(_ a: Item, _ b: Item) -> Bool {
        guard a.id != b.id, brandKey(a.brand) == brandKey(b.brand) else { return false }
        return sameWords(words(a.title), words(b.title))
    }
}

/// The same product from several stores, shown once: at its lowest price, with the other stores one tap away.
struct ProductGroup {
    /// The find shown: the lowest known price (then the strongest match).
    let lead: Find
    /// The same product's other finds, cheapest first.
    let others: [Find]
    var storeCount: Int { others.count + 1 }
}

extension ProductMatch {
    /// The last grouping, reused while the finds haven't changed (views redraw often).
    @MainActor private static var memo: (key: Int, value: [ProductGroup])?

    /// Groups finds that are the same product. Compares only within a brand, so it stays quick with hundreds of finds.
    @MainActor static func group(_ finds: [Find]) -> [ProductGroup] {
        var h = Hasher()
        for f in finds { h.combine(f.id); h.combine(f.status) }
        let key = h.finalize()
        if let m = memo, m.key == key { return m.value }
        let value = makeGroups(finds)
        memo = (key, value)
        return value
    }

    @MainActor private static func makeGroups(_ finds: [Find]) -> [ProductGroup] {
        var byBrand: [String: [(Find, Item, Set<String>)]] = [:]
        var order: [String] = []
        for f in finds {
            guard let item = Catalog.item(f.itemID) else { continue }
            let k = brandKey(item.brand)
            if byBrand[k] == nil { order.append(k) }
            byBrand[k, default: []].append((f, item, words(item.title)))
        }
        var groups: [[(Find, Item, Set<String>)]] = []
        var groupIndex: [String: Int] = [:]   // find id -> group
        for k in order {
            let rows = byBrand[k] ?? []
            var mine: [Int] = []   // group indexes made for this brand
            for (f, item, w) in rows {
                // Only real products with a brand are grouped; the rest stand alone.
                let match = k.isEmpty || !item.isProduct ? nil : mine.first { gi in
                    groups[gi].contains { g in sameWords(w, g.2) }
                }
                if let gi = match { groups[gi].append((f, item, w)); groupIndex[f.id] = gi }
                else { groups.append([(f, item, w)]); mine.append(groups.count - 1); groupIndex[f.id] = groups.count - 1 }
            }
        }
        func price(_ i: Item) -> Double { i.priceKnown && i.price > 0 ? i.price : .infinity }
        // Keep the list's own order: each group appears where its first member was.
        var seen = Set<Int>()
        var out: [ProductGroup] = []
        for f in finds {
            guard let gi = groupIndex[f.id], seen.insert(gi).inserted else { continue }
            let members = groups[gi].sorted { a, b in
                price(a.1) != price(b.1) ? price(a.1) < price(b.1) : a.0.score > b.0.score
            }.map(\.0)
            out.append(ProductGroup(lead: members[0], others: Array(members.dropFirst())))
        }
        return out
    }

    static func sameWords(_ wa: Set<String>, _ wb: Set<String>) -> Bool {
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        let hit = Double(wa.intersection(wb).count)
        let ra = hit / Double(wa.count), rb = hit / Double(wb.count)
        guard min(ra, rb) >= 0.7, max(ra, rb) >= 0.85 else { return false }
        let na = wa.filter { $0.contains(where: \.isNumber) }.subtracting(wb), nb = wb.filter { $0.contains(where: \.isNumber) }.subtracting(wa)
        return na.isEmpty || nb.isEmpty
    }
}

extension AppStore {
    /// Your other finds that are this same product (any store), cheapest first. Open or saved ones only.
    func sameProductFinds(_ find: Find) -> [Find] {
        guard let item = Catalog.item(find.itemID), item.isProduct else { return [] }
        return state.finds.filter { f in
            f.id != find.id && (f.status == .open || f.status == .liked) && Catalog.item(f.itemID).map { ProductMatch.same(item, $0) } == true
        }.sorted { a, b in
            let pa = Catalog.item(a.itemID).map { $0.priceKnown && $0.price > 0 ? $0.price : .infinity } ?? .infinity
            let pb = Catalog.item(b.itemID).map { $0.priceKnown && $0.price > 0 ? $0.price : .infinity } ?? .infinity
            return pa < pb
        }
    }
}

extension ProductMatch {
    /// For You picks with the same product from other stores folded in: the first (best ranked) stays, with a count.
    @MainActor static func dedupe(_ picks: [ForYouItem]) -> (picks: [ForYouItem], alsoAt: [String: Int]) {
        var kept: [ForYouItem] = []
        var keptWords: [String: [(String, Set<String>)]] = [:]   // brand -> (kept id, words)
        var alsoAt: [String: Int] = [:]
        for p in picks {
            guard let item = Catalog.item(p.id) else { continue }
            let k = brandKey(item.brand), w = words(item.title)
            if !k.isEmpty, item.isProduct, let hit = keptWords[k]?.first(where: { sameWords(w, $0.1) }) {
                alsoAt[hit.0, default: 0] += 1
                continue
            }
            kept.append(p)
            keptWords[k, default: []].append((p.id, w))
        }
        return (kept, alsoAt)
    }
}
