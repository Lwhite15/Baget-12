import Foundation

/// Today's drop: the finds the server picked this morning (each scout's 3 best).
struct DailyDrop: Decodable, Equatable {
    var date: String?
    var hour: Int
    var ids: [String]
}

/// Friends who liked (or, if they share purchases, bought) the same product.
struct FriendSignal: Decodable, Equatable {
    var listingId: String
    var names: [String]
    var bought: Bool?

    /// "Jordan likes this", "Jordan and Mia like this", "Sam got this".
    var line: String {
        let n = names.filter { !$0.isEmpty }
        guard let first = n.first else { return "" }
        if bought == true && n.count == 1 { return String(localized: "\(first) got this") }
        switch n.count {
        case 1: return String(localized: "\(first) likes this")
        case 2: return String(localized: "\(first) and \(n[1]) like this")
        default: return String(localized: "\(first), \(n[1]) and \(n.count - 2) more like this")
        }
    }
}

/// "Since yesterday": what changed on things you watched (a price drop, a restock), newest first.
struct Payoff: Identifiable {
    var id: String { note.id }
    let note: AppNote
    let find: Find
    let item: Item
    var tag: String {
        if note.kind == .restock { return String(localized: "Back") }
        if let r = note.body.range(of: #"\$[0-9,]+(\.[0-9]+)? off"#, options: .regularExpression) {
            return "−" + note.body[r].replacingOccurrences(of: " off", with: "")
        }
        return String(localized: "Price drop")
    }
    var line: String {
        note.kind == .restock ? String(localized: "Back in stock at \(item.source)") : String(localized: "You're watching it · now \(item.priceLabel)")
    }
}

extension AppStore {
    /// Asks the server for today's drop (it makes it once the drop time has passed), plus friends' likes on those products.
    @MainActor func loadDrop() async {
        guard isCloud else { return }
        guard let d = try? await api.rpc("my_drop", as: DailyDrop.self) else { return }
        if d != drop { drop = d }
        let listings = d.ids.compactMap { id in state.finds.first { $0.id == id }?.itemID }
        guard !listings.isEmpty, let rows = try? await api.rpc("friend_signals", ["p_listings": listings], as: [FriendSignal].self) else { return }
        friendSignals = Dictionary(rows.map { ($0.listingId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The drop's finds, grouped by scout in squad order. Signed out (the sample tour), each scout's 3 best open finds.
    func dropGroups() -> [(agent: Agent, finds: [Find])] {
        let byID = Dictionary(state.finds.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var finds: [Find]
        if let d = drop, isCloud {
            finds = d.ids.compactMap { byID[$0] }
        } else {
            finds = Dictionary(grouping: state.finds.filter { $0.status == .open }, by: \.agentID)
                .flatMap { $0.value.sorted { $0.score > $1.score }.prefix(3) }
        }
        finds = finds.filter { $0.status != .removed && Catalog.item($0.itemID) != nil }
        return state.agents.compactMap { a in
            let mine = finds.filter { $0.agentID == a.id }.sorted { $0.score > $1.score }
            return mine.isEmpty ? nil : (a, mine)
        }
    }

    /// Price drops and restocks on watched finds from the last day and a half (one per find).
    func payoffs(now: Date = .now) -> [Payoff] {
        var seen = Set<String>()
        return state.notes
            .filter { ($0.kind == .drop || $0.kind == .restock) && $0.date > now.addingTimeInterval(-36 * 3600) }
            .sorted { $0.date > $1.date }
            .compactMap { n -> Payoff? in
                guard let fid = n.findID, seen.insert(fid).inserted,
                      let f = state.finds.first(where: { $0.id == fid }), f.status != .passed, f.status != .removed,
                      let item = Catalog.item(f.itemID) else { return nil }
                return Payoff(note: n, find: f, item: item)
            }
            .prefix(3).map { $0 }
    }

    /// Releases from your finds happening within the next day and a half (or that just went live), soonest first.
    func droppingToday(now: Date = .now) -> [(find: Find, item: Item, at: Date)] {
        state.finds
            .filter { $0.status == .open || $0.status == .liked || $0.watching }
            .compactMap { f -> (Find, Item, Date)? in
                guard let item = Catalog.item(f.itemID), !item.isSample, let d = item.dropAt,
                      d > now.addingTimeInterval(-2 * 3600), d < now.addingTimeInterval(36 * 3600) else { return nil }
                return (f, item, d)
            }
            .sorted { $0.2 < $1.2 }
            .prefix(8).map { (find: $0.0, item: $0.1, at: $0.2) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
