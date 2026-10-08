import Foundation

extension Int {
    /// Int(Double) traps on NaN or infinity (for example 0 / 0 when a price is unknown). This never does.
    init(safe d: Double) {
        self = d.isFinite ? Int(Swift.max(Swift.min(d, 1e12), -1e12)) : 0
    }
}

// MARK: - Text helpers

enum TextMatch {
    static let stopWords: Set<String> = ["the", "and", "for", "any", "all", "with", "new", "old", "from", "that", "stuff", "things"]

    /// Lowercased, accent-free, trimmed ("Stüssy" -> "stussy").
    static func norm(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Either string contains the other ("rose" ~ "turkish rose").
    static func loose(_ a: String, _ b: String) -> Bool {
        let x = norm(a), y = norm(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x.contains(y) || y.contains(x)
    }

    /// Meaningful words of a query, with a trailing plural "s" dropped.
    static func words(_ q: String) -> [String] {
        norm(q).components(separatedBy: CharacterSet(charactersIn: " ,"))
            .filter { $0.count > 1 && !stopWords.contains($0) }
            .map { $0.hasSuffix("s") && $0.count > 2 ? String($0.dropLast()) : $0 }
    }

    static func list(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func haystack(_ item: Item) -> String {
        norm(([item.title, item.brand, item.category.info.label, item.creator ?? ""] + item.traits + item.tags).joined(separator: " "))
    }

    /// Every word of the query appears somewhere in the listing.
    static func matches(_ item: Item, query: String) -> Bool {
        let ws = words(query)
        guard !ws.isEmpty else { return false }
        let hay = haystack(item)
        return ws.allSatisfy { hay.contains($0) }
    }
}

// MARK: - Sizes

enum Sizes {
    static let tops = ["XS", "S", "M", "L", "XL", "XXL"]
    static let euToUSMen: [Double: Double] = [36: 4, 36.5: 4.5, 37.5: 5, 38: 5.5, 38.5: 6, 39: 6.5, 40: 7, 40.5: 7.5, 41: 8, 42: 8.5,
                                              42.5: 9, 43: 9.5, 44: 10, 44.5: 10.5, 45: 11, 45.5: 11.5, 46: 12, 47: 12.5,
                                              47.5: 13, 48: 13.5, 48.5: 14, 49: 15]

    /// Converts "US M 10.5", "US W 12", "UK 9.5" or "EU 44.5" to US men's.
    static func shoeUS(_ s: String) -> Double? {
        let up = s.uppercased()
        let numbers = up.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).compactMap { Double($0) }
        guard let n = numbers.first else { return nil }
        if up.contains("EU") { return euToUSMen[n] }
        if up.contains("UK") { return n + 1 }
        let tokens = up.components(separatedBy: CharacterSet.letters.inverted)
        if tokens.contains("W") || up.contains("WOMEN") || up.contains("WMNS") { return n - 1.5 }
        return n
    }

    static func topSize(_ s: String) -> String? {
        let tokens = s.uppercased().replacingOccurrences(of: "2XL", with: "XXL")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        return tokens.first { ["XXS", "XS", "S", "M", "L", "XL", "XXL"].contains($0) }
    }

    static func hasPants(_ s: String) -> Bool {
        s.range(of: #"\d+\s*[xX]\s*\d+"#, options: .regularExpression) != nil
    }

    static func required(_ a: Agent) -> Bool { a.mission.category?.info.sizeRequired ?? false }

    static func has(_ a: Agent) -> Bool {
        switch a.mission.category {
        case .sneakers?: return shoeUS(a.size) != nil
        case .apparel?: return topSize(a.size) != nil || hasPants(a.size)
        default: return true
        }
    }

    /// true = in stock in your size, false = not, nil = sizes don't apply.
    static func fit(_ a: Agent, _ item: Item) -> Bool? {
        switch item.category {
        case .sneakers:
            guard let stock = item.shoeSizes, let u = shoeUS(a.size) else { return nil }
            return stock.contains(u)
        case .apparel:
            guard let stock = item.topSizes, let t = topSize(a.size) else { return nil }
            return stock.contains(t)
        default:
            return nil
        }
    }

    static func display(_ d: Double) -> String {
        d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(d)) : String(d)
    }
}

// MARK: - Matching

struct Match: Hashable {
    var score: Int
    var why: [String]
    var notInSize: Bool = false
}

enum Matcher {
    static func covers(_ a: Agent, _ item: Item) -> Bool {
        switch a.mission {
        case .category(let c): return c == item.category
        case .custom(let text):
            let hay = TextMatch.haystack(item)
            return TextMatch.words(text).contains { hay.contains($0) }
        }
    }

    /// How well the agent knows the shopper, 0-100.
    static func intel(_ a: Agent) -> Int {
        var k = 14
        k += min(a.keywords.count, 5) * 6
        k += (!a.size.isEmpty || !a.mission.info.sizeRequired) ? 10 : 0
        k += a.maxPerItem > 0 ? 6 : 0
        k += a.monthlyLimit > 0 ? 6 : 0
        k += min(a.style.traits.count, 5) * 6
        k += min(a.style.makers.count, 3) * 5
        k += min(a.style.creators.count, 2) * 5
        return min(100, k)
    }

    static func match(_ a: Agent, _ item: Item) -> Match? {
        guard covers(a, item) else { return nil }
        if Sizes.required(a) && !Sizes.has(a) { return nil }           // no size, no hunting
        let fit = Sizes.fit(a, item)
        if fit == false { return Match(score: 0, why: ["Not in stock in your size (\(a.size))"], notInSize: true) }

        let info = item.category.info
        var why: [String] = []
        var pts = 0.0
        let hay = TextMatch.norm(([item.title, item.brand] + item.tags + item.traits).joined(separator: " "))
        let hits = a.keywords.filter { !$0.isEmpty && hay.contains(TextMatch.norm($0)) }
        if !hits.isEmpty { pts += Double(hits.count * 12); why.append("Matches your keywords: \(hits.prefix(3).joined(separator: ", "))") }
        if a.style.makers.contains(where: { TextMatch.loose($0, item.brand) }) {
            pts += 20; why.append("From \(item.brand), a \(info.makerNoun) you like")
        }
        if let c = item.creator, a.style.creators.contains(where: { TextMatch.loose($0, c) }) {
            pts += 18; why.append("\(info.creatorVerb) \(c), \(info.creatorNoun) you follow")
        }
        let shared = a.style.traits.filter { t in item.traits.contains { TextMatch.loose($0, t) } }
        if !shared.isEmpty {
            pts += Double(shared.count * 9)
            let photoTags = Set(a.tasteBoard.flatMap { $0.tags.map(TextMatch.norm) })
            let fromPhotos = shared.filter { photoTags.contains(TextMatch.norm($0)) }
            let fromBrief = shared.filter { !photoTags.contains(TextMatch.norm($0)) }
            if !fromBrief.isEmpty { why.append("Shares your \(fromBrief.joined(separator: ", ")) \(info.traitNoun)") }
            if !fromPhotos.isEmpty { why.append("Like your taste photos: \(fromPhotos.joined(separator: ", "))") }
        }
        if case .custom(let text) = a.mission, why.isEmpty { pts += 14; why.append("Fits your mission: \(text)") }

        // What the agent learned from your buys and passes
        let keys = item.traits + [item.brand]
        let liked = keys.filter { (a.learned[TextMatch.norm($0)] ?? 0) > 0 }
        let disliked = keys.filter { (a.learned[TextMatch.norm($0)] ?? 0) < 0 }
        if !liked.isEmpty {
            pts += Double(liked.reduce(0) { $0 + min(3, a.learned[TextMatch.norm($1)] ?? 0) * 6 })
            why.append("You've gone for \(liked.prefix(3).joined(separator: ", ")) before")
        }
        if !disliked.isEmpty {
            pts += Double(disliked.reduce(0) { $0 + max(-3, a.learned[TextMatch.norm($1)] ?? 0) * 8 })
            why.append("Heads up: you passed on \(disliked.prefix(2).joined(separator: ", ")) before")
        }

        let intelBoost = Double(intel(a))
        if fit == true { why.append("In stock in your size, \(a.size)") }
        if why.isEmpty || (why.count == 1 && fit == true) {
            return Match(score: Int(safe: (28 + intelBoost * 0.12).rounded()), why: ["Broad mission match only"] + why)
        }
        let s = Int(safe: (35 + pts * 0.55 + intelBoost * 0.1).rounded())
        return Match(score: max(5, min(98, s)), why: why)
    }
}

// MARK: - Money and dates

enum Fmt {
    static func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "$\(Int(v))"
    }

    static func monthKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func ago(_ d: Date) -> String {
        let m = Int(Date.now.timeIntervalSince(d) / 60)
        if m < 1 { return "now" }
        if m < 60 { return "\(m)m" }
        if m < 1440 { return "\(m / 60)h" }
        return "\(m / 1440)d"
    }
}

// MARK: - Friend-style texts

enum FriendVoice {
    static func line(agent a: Agent, kind: NoteKind, item: Item?, extra: String = "",
                     when: String = "", remaining: Double = 0, usedPercent: Int = 0) -> String {
        let t = item?.title ?? ""
        let src = item?.source ?? ""
        let price = item.map { Fmt.money($0.price) } ?? ""
        let hook = item.map { hookFor(a, $0) } ?? ""
        let pct = item.map { Int(safe: ((1 - $0.price / max($0.market, 1)) * 100).rounded()) } ?? 0
        let market = item.map { Fmt.money($0.market) } ?? ""

        switch (kind, a.voice) {
        case (.release, .hype): return "Yo! The \(t) drops \(when) at \(src). Total \(hook) energy. Want me to line up checkout?"
        case (.release, .chill): return "Heads up, the \(t) drops \(when) at \(src). It's very your \(hook) thing. Want me to get checkout ready?"
        case (.release, .straight): return "\(t) releases \(when) at \(src), \(price). Matches your \(hook) preference."

        case (.available, .hype): return "Found one for you! The \(t) is up right now at \(src) for \(price). It's so you."
        case (.available, .chill): return "Found something you'll like: the \(t), \(price) at \(src). Has that \(hook) thing you're into."
        case (.available, .straight): return "\(t) is available at \(src) for \(price).\(extra.isEmpty ? "" : " \(extra)% match.")"

        case (.steal, .hype): return "Okay this is a steal: the \(t) is \(price), about \(pct)% under what it trades for. Don't sleep on it."
        case (.steal, .chill): return "The \(t) is going for \(price), roughly \(pct)% under market. Worth a look if you still want one."
        case (.steal, .straight): return "\(t): asking \(price), market \(market). About \(pct)% under."

        case (.watch, .hype): return "Ugh, the \(t) sold out before I could get to it. I'm camped out for the restock."
        case (.watch, .chill): return "The \(t) is sold out right now. I'll keep watching and tell you the second it's back."
        case (.watch, .straight): return "\(t) is sold out. Restock watch is on."

        case (.restock, .hype): return "IT'S BACK. The \(t) just restocked at \(src). Want me to grab it before it's gone again?"
        case (.restock, .chill): return "Good news, the \(t) is back in stock at \(src). Want it?"
        case (.restock, .straight): return "Restock: \(t) at \(src), \(price). Tap to review checkout."

        case (.bought, .hype): return "Done! Grabbed the \(t) for \(price). It's in your Finds."
        case (.bought, .chill): return "Got it for you: the \(t), \(price). It's in your Finds."
        case (.bought, .straight): return "Purchased \(t) for \(price). \(Fmt.money(remaining)) left this month."

        case (.budget, .hype): return "Heads up, we're at \(usedPercent)% of this month's budget. I'll only ping you for the really good stuff now."
        case (.budget, .chill): return "Quick check-in: you're at \(usedPercent)% of your monthly limit, so I'll be pickier for a bit."
        case (.budget, .straight): return "Budget: \(usedPercent)% of \(Fmt.money(a.monthlyLimit)) used this month."

        case (.learned, .hype): return "Noticed you're really into \(extra) lately. Hunting more of that now!"
        case (.learned, .chill): return "Seems like \(extra) is your thing lately. I'll keep an eye out for more."
        case (.learned, .straight): return "Profile updated: added \(extra)."

        case (.friend, _): return extra
        }
    }

    /// The item's own trait that matches your profile, so the text names something real about it.
    static func hookFor(_ a: Agent, _ item: Item) -> String {
        if let t = item.traits.first(where: { x in a.style.traits.contains { TextMatch.loose(x, $0) } }) { return t }
        if a.style.makers.contains(where: { TextMatch.loose($0, item.brand) }) { return item.brand }
        return item.traits.first ?? item.brand
    }
}
