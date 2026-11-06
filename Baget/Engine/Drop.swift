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
        if note.kind == .dated { return note.body.hasPrefix("Heads up") ? String(localized: "Moved") : String(localized: "Dated") }
        if let r = note.body.range(of: #"\$[0-9,]+(\.[0-9]+)? off"#, options: .regularExpression) {
            return "−" + note.body[r].replacingOccurrences(of: " off", with: "")
        }
        return String(localized: "Price drop")
    }
    var line: String {
        switch note.kind {
        case .restock: return String(localized: "Back in stock at \(item.source)")
        case .dated: return item.dropAt.map { String(localized: "Releasing \(ReminderSheet.fmt($0))") } ?? String(localized: "New release date")
        default: return String(localized: "You're watching it · now \(Fmt.money(item.lowPrice ?? item.price))")
        }
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
            .filter { ($0.kind == .drop || $0.kind == .restock || $0.kind == .dated) && $0.date > now.addingTimeInterval(-36 * 3600) }
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

/// One card in Today's swipe deck.
enum DeckCard: Identifiable {
    /// What a scout caught on something you watch (price drop, restock, release date).
    case payoff(Payoff)
    /// Something you found that releases soon, with a countdown.
    case release(find: Find, item: Item, at: Date)
    /// One of today's drop picks.
    case pick(Find)
    /// After the drop: more picks ranked by your taste ("Keep swiping").
    case more(ForYouItem)

    var id: String {
        switch self {
        case .payoff(let p): return "pay-\(p.id)"
        case .release(let f, _, _): return "rel-\(f.id)"
        case .pick(let f): return "pick-\(f.id)"
        case .more(let m): return "more-\(m.id)"
        }
    }
}

/// "Your scouts are watching 23 items · checked 1h ago · 3 changes this week", and what's releasing next.
struct WatchSummary {
    var count: Int
    var checked: Date?
    var changes: Int
    var upcoming: [(item: Item, at: Date)]
}

extension AppStore {
    /// The morning deck, in order: payoffs, releases coming up, then each scout's picks (scouts taking turns).
    func dropDeck(now: Date = .now) -> [DeckCard] {
        let groups = dropGroups()
        let longest = groups.map(\.finds.count).max() ?? 0
        let picks = (0..<longest).flatMap { i in groups.compactMap { i < $0.finds.count ? $0.finds[i] : nil } }
        let pickIDs = Set(picks.map(\.id))
        let pays = payoffs(now: now).map(DeckCard.payoff)
        let paidFinds = Set(payoffs(now: now).map(\.find.id))
        let releases = state.finds
            .filter { ($0.status == .open || $0.status == .liked || $0.watching) && !pickIDs.contains($0.id) && !paidFinds.contains($0.id) }
            .compactMap { f -> (Find, Item, Date)? in
                guard let item = Catalog.item(f.itemID), !item.isSample, let d = item.dropAt,
                      d > now, d < now.addingTimeInterval(7 * 86400) else { return nil }
                return (f, item, d)
            }
            .sorted { $0.2 < $1.2 }
            .prefix(4)
            .map { DeckCard.release(find: $0.0, item: $0.1, at: $0.2) }
        return pays + releases + picks.map(DeckCard.pick)
    }

    /// "Keep swiping": picks from everything Baget's scouts find, ranked by taste. Only real matches (no filler),
    /// and nothing already in today's drop or already yours.
    func keepSwipingPool(excluding: Set<String>) -> [ForYouItem] {
        forYou.filter { $0.kind != "yours" && !excluding.contains($0.id) && Catalog.item($0.id) != nil }
    }

    func watchSummary(now: Date = .now) -> WatchSummary {
        let watched = state.finds.filter { $0.watching && ($0.status == .open || $0.status == .liked) }
        let items = watched.compactMap { Catalog.item($0.itemID) }
        let changes = state.notes.filter { [.drop, .restock, .dated].contains($0.kind) && $0.date > now.addingTimeInterval(-7 * 86400) }.count
        let upcoming = items.compactMap { i in i.dropAt.flatMap { $0 > now ? (item: i, at: $0) : nil } }.sorted { $0.at < $1.at }
        return WatchSummary(count: watched.count, checked: items.compactMap(\.checkedAt).max(), changes: changes, upcoming: Array(upcoming.prefix(3)))
    }
}
