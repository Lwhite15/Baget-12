import SwiftUI
import UIKit

/// A one-glance answer to "is this a good price?", from the asking price, resale value and other stores' prices.
struct DealVerdict: Hashable {
    enum Level { case great, fair, wait, info }
    let level: Level
    let title: String
    let detail: String

    var emoji: String {
        switch level { case .great: return "🟢"; case .fair: return "🟡"; case .wait: return "🔴"; case .info: return "🏷️" }
    }
    var tint: Color {
        switch level { case .great: return Theme.green; case .fair: return Theme.warn; case .wait: return Theme.hot; case .info: return Theme.accent }
    }

    static func of(_ item: Item) -> DealVerdict? {
        let p = item.priceKnown ? item.price : 0
        let low = item.lowPrice ?? 0
        let store = item.lowStore ?? "another store"
        let others = (item.offers ?? []).count
        let hasMarket = item.market > 0 && item.market != item.price
        guard p > 0 else {
            return low > 0 ? DealVerdict(level: .info, title: "From \(Fmt.money(low))", detail: "at \(store)") : nil
        }
        if low > 0 && low < p * 0.95 && !sameStore(store, item.source) {
            return DealVerdict(level: .wait, title: "Cheaper elsewhere", detail: "\(Fmt.money(low)) at \(store), \(Int(safe: ((1 - low / p) * 100).rounded()))% less")
        }
        if hasMarket && item.market > p * 1.15 {
            return DealVerdict(level: .great, title: "Great deal", detail: "\(Int(safe: ((item.market / p - 1) * 100).rounded()))% under resale (\(Fmt.money(item.market)))")
        }
        if others >= 2 && (low == 0 || low >= p * 0.98) {
            return DealVerdict(level: .great, title: "Best price", detail: "Lowest of \(others + 1) stores")
        }
        if hasMarket && item.market < p * 0.9 {
            return DealVerdict(level: .wait, title: "Over resale", detail: "Goes for about \(Fmt.money(item.market)) secondhand")
        }
        if others > 0 || hasMarket {
            return DealVerdict(level: .fair, title: "Fair price", detail: others > 0 ? "In line with \(others) other store\(others == 1 ? "" : "s")" : "Around resale value")
        }
        return nil
    }

    private static func sameStore(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        return !x.isEmpty && !y.isEmpty && (x.contains(y) || y.contains(x))
    }
}

/// A small verdict chip: "🟢 Great deal".
struct VerdictChip: View {
    let verdict: DealVerdict
    var showDetail = false
    var body: some View {
        HStack(spacing: 5) {
            Text(verdict.emoji).font(.caption2)
            Text(verdict.title).font(.caption.weight(.bold)).foregroundStyle(verdict.tint)
            if showDetail {
                Text("· \(verdict.detail)").font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(verdict.tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Store actions for the new screens

private struct HuntReply: Decodable {
    let agentId: String
    let name: String
    let intro: String
    let needsSize: Bool?
}
private struct OnboardReply: Decodable { let agents: [HuntReply] }

extension AppStore {
    /// "What are you hunting?" One sentence in, a ready agent out. Returns the new agent's id and its hello.
    func hunt(_ text: String) async -> (agentID: String, intro: String, needsSize: Bool)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return nil }
        Analytics.track(.huntStarted, ["words": t.split(separator: " ").count])
        guard isCloud else {
            // Sample tour: a local agent on the spot.
            let a = Agent(id: UUID().uuidString.lowercased(), name: String("\(t.capitalizedFirst) Hunter".prefix(40)), mission: .custom(String(t.prefix(80))),
                          keywords: [], style: StyleProfile(traits: [], makers: [], creators: []), size: "", mode: .ask, voice: .chill)
            deploy(a)
            return (a.id, "I'm on it. I'll text you when I find something.", false)
        }
        if squadFull {
            syncProblem = scoutLimitMessage
            return nil
        }
        do {
            let r: HuntReply = try await api.function("hunt", ["text": t])
            await pull()
            Task { @MainActor in _ = await self.cloudSweep(agentID: r.agentId) }
            return (r.agentId, r.intro.isEmpty ? "I'm on it." : r.intro, r.needsSize ?? false)
        } catch {
            syncProblem = (error as? LocalizedError)?.errorDescription ?? "Couldn't start that hunt. Try again."
            return nil
        }
    }

    /// First-run setup: interests, an optional sentence and up to three photos -> a squad, already searching.
    func onboard(categories: [Category], text: String, photos: [UIImage], liked: [String] = [], passed: [String] = [],
                 vibes: [Category: [String]] = [:], budget: Int? = nil, brands: [Category: [String]] = [:],
                 interests: [String] = []) async -> [String] {
        Analytics.track(.onboardingDone, ["categories": categories.count, "photos": photos.count, "text": !text.isEmpty, "rated": liked.count + passed.count])
        guard isCloud else {
            for c in categories {
                deploy(Agent(id: UUID().uuidString.lowercased(), name: "\(c.info.label) Scout", mission: .category(c), keywords: [],
                             style: StyleProfile(traits: [], makers: [], creators: []), size: "", mode: .ask, voice: .chill))
            }
            for i in interests {
                deploy(Agent(id: UUID().uuidString.lowercased(), name: "\(i.components(separatedBy: " ").first ?? i) Scout", mission: .custom(i.lowercased()),
                             keywords: [], style: StyleProfile(traits: [], makers: [], creators: []), size: "", mode: .ask, voice: .chill))
            }
            return state.agents.map(\.id)
        }
        let images: [[String: String]] = photos.prefix(3).compactMap { img in
            guard let jpg = PhotoTaste.normalized(img, maxSide: 1024).jpegData(compressionQuality: 0.75) else { return nil }
            return ["media_type": "image/jpeg", "data": jpg.base64EncodedString()]
        }
        do {
            var body: [String: Any] = ["categories": categories.map(\.rawValue), "text": text, "images": images,
                                       "liked": liked, "passed": passed,
                                       "vibes": Dictionary(uniqueKeysWithValues: vibes.filter { !$0.value.isEmpty }.map { ($0.key.rawValue, $0.value) })]
            if let budget { body["budget"] = budget }
            if !interests.isEmpty { body["interests"] = interests }
            let picks = brands.filter { !$0.value.isEmpty }
            if !picks.isEmpty { body["brands"] = Dictionary(uniqueKeysWithValues: picks.map { ($0.key.rawValue, $0.value) }) }
            let r: OnboardReply = try await api.function("hunt", body)
            await pull()
            Task { @MainActor in _ = await self.cloudSweep() }
            return r.agents.map(\.agentId)
        } catch {
            syncProblem = (error as? LocalizedError)?.errorDescription ?? "Couldn't set up your squad. Try again."
            return []
        }
    }

    /// Setup's quick taste check: real products in the picked categories, one per brand, photos only.
    func tasteQuiz(_ categories: [Category]) async -> [Item] {
        guard isCloud else {
            let cats = Set(categories)
            var brands = Set<String>()
            return Catalog.items.filter { (cats.isEmpty || cats.contains($0.category)) && brands.insert($0.brand).inserted }.prefix(10).map { $0 }
        }
        let rows: [ListingRow] = (try? await api.rpc("taste_quiz", ["p_categories": categories.map(\.rawValue), "p_limit": 10])) ?? []
        for r in rows { Catalog.cloud[r.id] = r.item }
        return Array(rows.map(\.item).prefix(10))
    }

    /// Records a taste-check answer so For You is personal from the first minute.
    func rateInQuiz(_ item: Item, liked: Bool) {
        guard isCloud else { return }
        let row: [String: Any] = ["listing_id": item.id, "action": liked ? "like" : "dismiss"]
        push { api in try await api.raw("POST", "/rest/v1/feed_reactions", json: row, prefer: "return=minimal,resolution=ignore-duplicates") }
    }

    /// "Watch it for me": the agent re-prices it twice a day and texts on a drop, restock or release.
    func toggleWatch(_ findID: String) {
        guard let fi = state.finds.firstIndex(where: { $0.id == findID }), let item = Catalog.item(state.finds[fi].itemID) else { return }
        if state.finds[fi].watching {
            state.finds[fi].watching = false
            push { api in try await api.update("finds", "id=eq.\(findID)", ["watching": false]) }
            save()
            return
        }
        state.finds[fi].watching = true
        var patch: [String: Any] = ["watching": true]
        if item.priceKnown && item.price > 0 { patch["watch_price"] = item.price }
        push { api in try await api.update("finds", "id=eq.\(findID)", patch) }
        learn(state.finds[fi].agentID, from: item, delta: 1)
        Analytics.track(.findWatched, ["category": item.category.rawValue])
        save()
    }

    /// Removes something an agent learned or was told (a brand, style, keyword, creator, or the size).
    func removeTaste(_ agentID: String, _ value: String) {
        guard let i = agentIndex(agentID) else { return }
        let n = TextMatch.norm(value)
        state.agents[i].style.traits.removeAll { TextMatch.norm($0) == n }
        state.agents[i].style.makers.removeAll { TextMatch.norm($0) == n }
        state.agents[i].style.creators.removeAll { TextMatch.norm($0) == n }
        state.agents[i].keywords.removeAll { TextMatch.norm($0) == n }
        state.agents[i].learned.removeValue(forKey: n)
        if TextMatch.norm(state.agents[i].size) == n { state.agents[i].size = "" }
        if value == "__price" { state.agents[i].priceNote = 0 }
        Analytics.track(.tasteRemoved, [:])
        save()
        pushAgent(agentID)
    }

    /// Today's best: open finds from the last few days, strongest first, one per item.
    func todaysPicks(_ n: Int = 5) -> [Find] {
        let since = Date.now.addingTimeInterval(-4 * 86400)
        let fresh = state.finds.filter { $0.status == .open && $0.foundAt > since && Catalog.item($0.itemID)?.showable == true }
        let pool = fresh.isEmpty ? state.finds.filter { $0.status == .open && Catalog.item($0.itemID)?.showable == true } : fresh
        return Array(pool.sorted { $0.score != $1.score ? $0.score > $1.score : $0.foundAt > $1.foundAt }.prefix(n))
    }

    /// Open finds to swipe through, best first, 10 at a time (the rest wait in Finds and come up in the next round).
    static let swipeRound = 10
    var swipeQueue: [Find] {
        Array(state.finds.filter { $0.status == .open && Catalog.item($0.itemID)?.showable == true }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.foundAt > $1.foundAt }
            .prefix(Self.swipeRound))
    }
}
