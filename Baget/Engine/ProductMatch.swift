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
        let wa = words(a.title), wb = words(b.title)
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        let hit = Double(wa.intersection(wb).count)
        let ra = hit / Double(wa.count), rb = hit / Double(wb.count)
        guard min(ra, rb) >= 0.7, max(ra, rb) >= 0.85 else { return false }
        let na = wa.filter { $0.contains(where: \.isNumber) }.subtracting(wb), nb = wb.filter { $0.contains(where: \.isNumber) }.subtracting(wa)
        return na.isEmpty || nb.isEmpty
    }
}
