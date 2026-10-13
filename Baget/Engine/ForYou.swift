import Foundation
import SwiftUI

/// One listing picked for you on Today, with the reason it was picked.
struct ForYouPick: Identifiable, Hashable {
    var id: String { item.id }
    let item: Item
    let score: Double
    let reason: String
    /// Picked to explore something you haven't shown an opinion on yet.
    let isExplore: Bool
    /// A sample listing shown as an idea because there isn't enough real inventory yet. Its price is illustrative.
    let isExample: Bool
    /// The open find behind it, if your squad already flagged it.
    let findID: String?
}

/// A row of listings that share one thing you like ("Because you like suede").
struct ForYouShelf: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let title: String
    let picks: [ForYouPick]
}

/// Everything Today shows. `picks` is never empty while any listing exists, and the sample catalog always does.
struct ForYouFeed {
    var hero: ForYouPick?
    var picks: [ForYouPick] = []
    var shelves: [ForYouShelf] = []
    /// Things you liked or are watching, so the screen has something of yours even on a quiet day.
    var radar: [ForYouPick] = []
    /// Few signals yet: Today says it's still learning and asks for likes and passes.
    var learning = true
    var signals = 0
}

extension AppStore {
    /// Today's date in local time, e.g. "2026-10-12".
    static var dayKey: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Ranking

    /// Builds Today. Works with or without finds: it ranks every listing the app knows about against what you like.
    func forYouFeed(limit: Int = 8) -> ForYouFeed {
        let taste = state.taste
        let now = Date.now
        let day = Self.dayKey
        let prior = tastePrior()

        // Where each listing stands in Finds (one find per item; the latest wins).
        var findByItem: [String: Find] = [:]
        for f in state.finds where findByItem[f.itemID] == nil { findByItem[f.itemID] = f }

        func excluded(_ item: Item, relaxed: Bool) -> Bool {
            if let f = findByItem[item.id] {
                if f.status == .acquired { return true }
                if !relaxed, f.status == .passed || f.status == .removed || f.status == .liked { return true }
            }
            if !relaxed, taste.hidden.contains(item.id) { return true }
            return false
        }

        // Candidate pool: real listings first; sample ideas fill in only when there aren't enough.
        let real = Catalog.all.filter { !(isCloud && $0.isSample) }
        var pool = real.filter { !excluded($0, relaxed: false) }
        var examples = Set<String>()
        if pool.count < limit + 4 {
            let ids = Set(pool.map(\.id))
            let extra = Catalog.items.filter { !ids.contains($0.id) && !excluded($0, relaxed: false) }
            if isCloud { extra.forEach { examples.insert($0.id) } }
            pool += extra
        }
        if pool.isEmpty {   // you've passed on everything: start the cycle again rather than show nothing
            pool = (real.isEmpty ? Catalog.items : real).filter { !excluded($0, relaxed: true) }
            if real.isEmpty && isCloud { pool.forEach { examples.insert($0.id) } }
        }

        // Exploration fades as the model learns: lots of variety early, mostly exploitation later.
        let explore = max(0.06, 0.28 - Double(taste.signals) * 0.012)

        struct Scored { let item: Item; let score: Double; let reason: String }
        var scored: [Scored] = []
        for item in pool {
            let feats = TasteModel.features(item)
            var raw = 0.0
            var bestKey: String? = nil
            var bestVal = 0.0
            for f in feats {
                let v = (taste.value(f.key, now: now) + (prior[f.key] ?? 0)) * f.kind
                raw += v
                if v > bestVal, !f.key.hasPrefix("s:") { bestVal = v; bestKey = f.key }
            }
            let spread: Double = max(1, sqrt(Double(feats.count)))
            let affinity: Double = tanh(raw / spread / 2.2)       // -1…1

            let match = best(for: item)
            if match?.match.notInSize == true { continue }
            let agentScore = match?.match.score ?? 0
            let agentPart = Double(agentScore) / 100

            var fresh = 0.0
            if let seen = item.firstSeen, now.timeIntervalSince(seen) < 2 * 86400 { fresh += 0.08 }
            if let f = findByItem[item.id], f.status == .open, now.timeIntervalSince(f.foundAt) < 3 * 86400 { fresh += 0.1 }
            let drop = dropDate(item).timeIntervalSince(now)
            if drop > 0 && drop < 2 * 86400 { fresh += 0.06 }
            if item.priceKnown, item.price > 0, item.market > item.price * 1.15 { fresh += 0.05 }
            if isSoldOut(item) { fresh -= 0.08 }

            let imp = taste.impressions[item.id]
            // Shown on earlier days and never acted on: let it rest so Today rotates.
            var fatigue = 0.0
            if let imp, !imp.engaged {
                let earlierDays = imp.days - (imp.lastDay == day ? 1 : 0)
                fatigue = min(0.5, 0.12 * Double(max(0, earlierDays)))
            }
            let jitter: Double = (stableUnit(item.id + day) - 0.5) * explore
            let pricePart: Double = taste.priceFit(item)

            var score: Double = 0.48 * affinity + 0.32 * agentPart
            score += fresh + pricePart + jitter - fatigue
            if examples.contains(item.id) { score -= 0.15 }

            let reason = reasonFor(item, topKey: bestKey, topValue: bestVal, match: match?.match, find: findByItem[item.id])
            scored.append(Scored(item: item, score: score, reason: reason))
        }

        // Pick with variety: each pick from a brand or category already on screen costs a little.
        var remaining = scored.sorted { $0.score > $1.score }
        var chosen: [ForYouPick] = []
        var brands: [String: Int] = [:], cats: [Category: Int] = [:]
        func pick(_ s: Scored, explore: Bool) {
            chosen.append(ForYouPick(item: s.item, score: s.score, reason: explore ? "Something new to try" : s.reason,
                                     isExplore: explore, isExample: examples.contains(s.item.id),
                                     findID: findByItem[s.item.id].flatMap { $0.status == .open ? $0.id : nil }))
            brands[TextMatch.norm(s.item.brand), default: 0] += 1
            cats[s.item.category, default: 0] += 1
        }
        while chosen.count < limit, !remaining.isEmpty {
            // Every 4th slot explores: the best listing from a category you've told it little about.
            if chosen.count % 4 == 3 {
                var exploreI: Int? = nil
                for (i, s) in remaining.enumerated() {
                    let catKey = "k:" + s.item.category.rawValue
                    let known = abs(taste.value(catKey, now: now)) + (prior[catKey] ?? 0)
                    if known < 0.5 { exploreI = i; break }   // remaining is sorted, so the first is the best
                }
                if let i = exploreI {
                    pick(remaining.remove(at: i), explore: true)
                    continue
                }
            }
            var bestI = 0, bestAdj = -Double.infinity
            for (i, s) in remaining.prefix(40).enumerated() {
                let sameBrand = Double(brands[TextMatch.norm(s.item.brand)] ?? 0)
                let sameCat = Double(max(0, (cats[s.item.category] ?? 0) - 1))
                let adj: Double = s.score - 0.14 * sameBrand - 0.08 * sameCat
                if adj > bestAdj { bestAdj = adj; bestI = i }
            }
            pick(remaining.remove(at: bestI), explore: false)
        }

        var feed = ForYouFeed()
        feed.signals = taste.signals
        feed.learning = taste.signals < 6
        feed.hero = chosen.first
        feed.picks = Array(chosen.dropFirst())

        // Shelves: your two strongest likes that have enough listings left to fill a row.
        let shown = Set(chosen.map(\.id))
        var combined: [String: Double] = prior
        for (k, _) in taste.weights { combined[k, default: 0] += taste.value(k, now: now) }
        let top = combined.filter { $0.value > 0.6 && !$0.key.hasPrefix("s:") }.sorted { $0.value > $1.value }
        var used = shown
        for (key, _) in top where feed.shelves.count < 2 {
            let rows = remaining.filter { s in
                !used.contains(s.item.id) && TasteModel.features(s.item).contains(where: { $0.key == key })
            }.prefix(6)
            guard rows.count >= 3, let first = rows.first?.item else { continue }
            let picks = rows.map { s in
                ForYouPick(item: s.item, score: s.score, reason: s.reason, isExplore: false, isExample: examples.contains(s.item.id),
                           findID: findByItem[s.item.id].flatMap { $0.status == .open ? $0.id : nil })
            }
            picks.forEach { used.insert($0.id) }
            let name = TasteModel.label(key, item: first)
            let title = key.hasPrefix("k:") ? "More \(name) for you" : "Because you like \(name)"
            feed.shelves.append(ForYouShelf(key: key, title: title, picks: Array(picks)))
        }

        // On your radar: liked or watching, newest first.
        feed.radar = state.finds.filter { ($0.status == .liked || $0.watching) && $0.status != .acquired && $0.status != .removed }
            .prefix(10)
            .compactMap { f in
                guard let item = Catalog.item(f.itemID) else { return nil }
                let why = isSoldOut(item) ? "Watching for a restock" : dropDate(item) > now ? "Drops \(whenText(item))" : "You liked this"
                return ForYouPick(item: item, score: 0, reason: why, isExplore: false, isExample: false, findID: f.id)
            }
        return feed
    }

    private func reasonFor(_ item: Item, topKey: String?, topValue: Double, match: Match?, find: Find?) -> String {
        if let find, find.status == .open, let w = find.why.first, !w.hasPrefix("Broad") { return w }
        if let k = topKey, topValue > 0.4 {
            let name = TasteModel.label(k, item: item)
            switch k.prefix(1) {
            case "b": return "Because you like \(name)"
            case "c": return "\(item.category.info.creatorVerb) \(name), who you're into"
            case "k": return "Picked from your \(name)"
            default: return "You've been into \(name)"
            }
        }
        if let w = match?.why.first, !w.hasPrefix("Broad") { return w }
        if item.priceKnown, item.price > 0, item.market > item.price * 1.15 { return "Trading above what it costs" }
        if let seen = item.firstSeen, Date.now.timeIntervalSince(seen) < 86400 { return "Just found" }
        return "Picked to learn your taste"
    }

    /// What your agents' briefs say you like. Live, so a new agent changes Today right away.
    func tastePrior() -> [String: Double] {
        var p: [String: Double] = [:]
        func add(_ key: String, _ v: Double) { p[key, default: 0] += v }
        for a in state.agents where !a.isOff {
            if let c = a.mission.category { add("k:\(c.rawValue)", 1.2) }
            a.style.makers.forEach { add("b:\(TextMatch.norm($0))", 1.4) }
            a.style.creators.forEach { add("c:\(TextMatch.norm($0))", 1.4) }
            a.style.traits.forEach { add("t:\(TextMatch.norm($0))", 1.0) }
            a.keywords.forEach { k in
                let n = TextMatch.norm(k)
                add("t:\(n)", 0.6); add("g:\(n)", 0.6)
            }
            a.tasteBoard.flatMap(\.tags).forEach { add("t:\(TextMatch.norm($0))", 0.5) }
        }
        return p
    }

    /// Folds your past finds into the model once, so it starts from what you've already done.
    /// Called from Today's onAppear (never while a view is drawing).
    func bootstrapTasteIfNeeded() {
        guard !state.taste.bootstrapped else { return }
        var t = state.taste
        for f in state.finds {
            guard let item = Catalog.item(f.itemID) else { continue }
            switch f.status {
            case .acquired: t.observe(item, .buy, now: f.foundAt)
            case .liked: t.observe(item, .like, now: f.foundAt)
            case .passed:
                switch f.passReason {
                case "not my style": t.observe(item, .passStyle, now: f.foundAt)
                case "too pricey": t.observe(item, .passPrice, now: f.foundAt)
                default: break
                }
            default: if f.watching { t.observe(item, .watch, now: f.foundAt) }
            }
        }
        t.bootstrapped = true
        state.taste = t
        save()
    }

    // MARK: - Actions from Today

    /// The find for an item, creating one through the best agent when it's a real listing.
    private func findFor(_ item: Item) -> Find? {
        if let f = state.finds.first(where: { $0.itemID == item.id }) { return f }
        guard !(isCloud && item.isSample), let b = best(for: item), !b.match.notInSize else { return nil }
        return ensureFind(agentID: b.agent.id, itemID: item.id)
    }

    func forYouLike(_ item: Item) {
        if let f = findFor(item) {
            if f.status == .passed || f.status == .removed { undoPass(f.id) }
            like(f.id)                       // teaches the agent and the taste model
        } else {
            state.taste.observe(item, .like)
            save()
        }
        Analytics.track(.forYouLiked, ["category": item.category.rawValue, "sample": item.isSample])
    }

    func forYouPass(_ item: Item, reason: PassReason) {
        if let f = state.finds.first(where: { $0.itemID == item.id }), f.status != .acquired {
            pass(f.id, reason: reason)       // teaches the agent and the taste model
        } else {
            state.taste.observe(item, Self.signal(for: reason))
            state.taste.hidden.insert(item.id)
            save()
        }
        Analytics.track(.forYouPassed, ["category": item.category.rawValue, "reason": reason.rawValue, "sample": item.isSample])
    }

    /// Tapping a pick counts as mild interest, then opens it in Finds when a find can exist for it.
    func forYouOpen(_ item: Item, router: Router) {
        state.taste.observe(item, .open)
        Analytics.track(.forYouOpened, ["category": item.category.rawValue, "sample": item.isSample])
        guard let f = findFor(item) else {
            save()
            router.say(isCloud && item.isSample ? "An example. Like or pass to teach your squad"
                                                : "Deploy a \(item.category.info.label.lowercased()) agent to track this")
            return
        }
        if f.status == .removed { restoreFind(f.id) }
        if f.status == .acquired { router.say("You bought this one"); save(); return }
        save()
        router.focusFind = f.id
        router.tab = .finds
    }

    func noteTodayShown(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        state.taste.noteShown(ids, day: Self.dayKey)
        save()
    }

    static func signal(for reason: PassReason) -> TasteModel.Signal {
        switch reason {
        case .style: return .passStyle
        case .price: return .passPrice
        case .own: return .passOwn
        case .later: return .passLater
        }
    }
}
