import Foundation

/// One pick in the Today screen's "For You" feed.
struct ForYouItem: Identifiable, Hashable, Codable {
    /// The listing (also the Catalog item id).
    let id: String
    let reason: String
    /// "match" (fits your taste), "explore" (something new to try) or "yours" (one of your own finds).
    let kind: String
    let findID: String?
}

/// A taste signal: "b:jordan" (brand), "t:suede" (trait) or "c:sneakers" (category), with how strongly it counts.
struct TasteFeature: Decodable, Hashable, Identifiable {
    let feature: String
    let weight: Double
    var id: String { feature }
    var likes: Bool { weight > 0 }
    var label: String {
        let raw = String(feature.dropFirst(2))
        if feature.hasPrefix("c:") { return Category(rawValue: raw)?.info.label ?? raw.capitalized }
        if feature.hasPrefix("b:") { return raw.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }
        return raw
    }
}

private struct ForYouRow: Decodable {
    let listing: ListingRow
    let reason: String
    let kind: String
    let findId: String?
}

enum ForYouAction: String { case like, dismiss, open, buy }

extension AppStore {
    /// Loads the feed (signed in: ranked on the server from everything Baget's agents have found; sample: from the tour catalog).
    func loadForYou(limit: Int = 24) async {
        guard isCloud else {
            forYou = sampleForYou(limit: limit)
            tasteTop = sampleTaste()
            forYouLoadedAt = .now
            return
        }
        guard !forYouLoading else { return }
        forYouLoading = true
        defer { forYouLoading = false }
        do {
            async let rowsQ: [ForYouRow] = api.rpc("for_you", ["p_limit": limit])
            async let tasteQ: [TasteFeature] = api.rpc("taste_top", ["p_limit": 10])
            let (rows, taste) = try await (rowsQ, tasteQ)
            for r in rows { Catalog.cloud[r.listing.id] = r.listing.item }
            let items = rows.map { ForYouItem(id: $0.listing.id, reason: $0.reason, kind: $0.kind, findID: $0.findId) }
            if items != forYou { forYou = items }   // no redraw when nothing changed
            tasteTop = taste
            forYouLoadedAt = .now
            // Kept on the phone, with its products, so the next open shows it instantly.
            let known = Set(state.listings.map(\.id))
            state.listings.append(contentsOf: rows.map(\.listing.item).filter { !known.contains($0.id) })
            state.forYou = items
            state.forYouAt = .now
            save()
        } catch {
            // Keep what's on screen; if there's nothing, fall back to your own finds so the section is never blank.
            if forYou.isEmpty { forYou = ownFindsFeed(limit: limit) }
        }
    }

    /// Like, "not for me", or open. Each one teaches the ranking; a like also saves it to Finds under the agent that fits.
    func reactForYou(_ pick: ForYouItem, _ action: ForYouAction) {
        Analytics.track(action == .like ? .findLiked : action == .dismiss ? .findPassed : .checkoutOpened,
                        ["from": "for_you", "kind": pick.kind])
        if action == .like || action == .dismiss {
            forYou.removeAll { $0.id == pick.id }
        }
        if isCloud {
            let row: [String: Any] = ["listing_id": pick.id, "action": action.rawValue]
            push { api in try await api.raw("POST", "/rest/v1/feed_reactions", json: row, prefer: "return=minimal,resolution=ignore-duplicates") }
        } else if action == .dismiss {
            forYouDismissed.insert(pick.id)
        }
        guard let item = Catalog.item(pick.id) else { return }
        switch action {
        case .like:
            if let fid = pick.findID { like(fid); return }
            let agent = best(for: item)?.agent ?? state.agents.first { Matcher.covers($0, item) } ?? state.agents.first { $0.mission.category == item.category }
            if let a = agent, let f = ensureFind(agentID: a.id, itemID: item.id, why: pick.reason) { like(f.id) }
        case .dismiss:
            if let fid = pick.findID { pass(fid, reason: .style) }
        case .open, .buy:
            break
        }
        if forYou.count < 6 { Task { await loadForYou() } }   // keep the feed full
    }

    /// Your own open and liked finds, as a last resort.
    func ownFindsFeed(limit: Int) -> [ForYouItem] {
        state.finds.filter { ($0.status == .open || $0.status == .liked) && Catalog.item($0.itemID) != nil }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { ForYouItem(id: $0.itemID, reason: "From your finds", kind: "yours", findID: $0.id) }
    }

    /// The sample tour: rank the tour catalog with the same matcher the agents use, shuffled a little each day.
    private func sampleForYou(limit: Int) -> [ForYouItem] {
        let found = Set(state.finds.map(\.itemID))
        let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        let jitter = { (id: String) -> Double in Double(abs((id + "\(day)").hashValue % 100)) / 100 }
        let ranked = Catalog.items
            .filter { !found.contains($0.id) && !forYouDismissed.contains($0.id) }
            .map { item -> (Item, Double, String, Bool) in
                if let b = best(for: item) { return (item, Double(b.match.score) / 20 + jitter(item.id), b.match.why.first ?? "Fits your taste", true) }
                return (item, jitter(item.id), "Something new to try", false)
            }
            .sorted { $0.1 > $1.1 }
        var out: [ForYouItem] = []
        var matched = ranked.filter { $0.3 }.makeIterator()
        var other = ranked.filter { !$0.3 }.makeIterator()
        while out.count < limit {
            let next = (out.count + 1) % 5 == 0 ? (other.next() ?? matched.next()) : (matched.next() ?? other.next())
            guard let n = next else { break }
            out.append(ForYouItem(id: n.0.id, reason: n.2, kind: n.3 ? "match" : "explore", findID: nil))
        }
        return out.isEmpty ? ownFindsFeed(limit: limit) : out
    }

    private func sampleTaste() -> [TasteFeature] {
        var w: [String: Double] = [:]
        for a in state.agents {
            for m in a.style.makers { w["b:" + m.lowercased(), default: 0] += 2 }
            for t in a.style.traits { w["t:" + t.lowercased(), default: 0] += 1.5 }
            for (k, v) in a.learned { w["t:" + k.lowercased(), default: 0] += Double(v) }
        }
        return w.filter { abs($0.value) >= 1 }.sorted { abs($0.value) > abs($1.value) }.prefix(10)
            .map { TasteFeature(feature: $0.key, weight: $0.value) }
    }
}
