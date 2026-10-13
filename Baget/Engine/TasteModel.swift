import Foundation

/// What you like, learned across your whole squad from everything you do: likes, passes, buys, watches and taps.
///
/// Every listing is broken into features (brand, creator, traits, tags, category, store). Each signal nudges the
/// weights of that listing's features up or down. Weights fade with a 30-day half-life, so what you liked last week
/// counts more than what you liked last season, and the model follows your taste as it changes.
/// Your agents' briefs (brands, traits, keywords, taste photos) act as a prior, so it isn't blank on day one.
struct TasteModel: Codable, Hashable {
    struct Weight: Codable, Hashable {
        var w: Double
        var at: Date
    }

    /// One listing's run on the Today screen: how many separate days it was shown and whether you ever acted on it.
    struct Impression: Codable, Hashable {
        var days: Int = 0
        var lastDay: String = ""
        var engaged = false
    }

    enum Signal {
        case buy, like, unlike, watch, open
        case passStyle, passPrice, passOwn, passLater

        var delta: Double {
            switch self {
            case .buy: return 3
            case .like: return 2
            case .unlike: return -2
            case .watch: return 1
            case .open: return 0.4
            case .passStyle: return -2
            case .passLater: return -0.3
            case .passPrice, .passOwn: return 0      // says nothing about style
            }
        }
    }

    var weights: [String: Weight] = [:]
    /// Prices of things you liked or bought (most recent last), for learning your price range.
    var likedPrices: [Double] = []
    /// Set when you pass for price: listings well above it are pushed down.
    var priceCeiling: Double? = nil
    var impressions: [String: Impression] = [:]
    /// Listings you passed on from Today that had no find behind them.
    var hidden: Set<String> = []
    var signals = 0
    /// Past finds (likes, passes, buys) have been folded in once.
    var bootstrapped = false

    static let halfLifeDays = 30.0

    init() {}

    // Tolerant decoding, like AppState.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weights = (try? c.decode([String: Weight].self, forKey: .weights)) ?? [:]
        likedPrices = (try? c.decode([Double].self, forKey: .likedPrices)) ?? []
        priceCeiling = try? c.decode(Double.self, forKey: .priceCeiling)
        impressions = (try? c.decode([String: Impression].self, forKey: .impressions)) ?? [:]
        hidden = (try? c.decode(Set<String>.self, forKey: .hidden)) ?? []
        signals = (try? c.decode(Int.self, forKey: .signals)) ?? 0
        bootstrapped = (try? c.decode(Bool.self, forKey: .bootstrapped)) ?? false
    }

    // MARK: Features

    /// Feature keys for a listing, with how much each kind of feature counts.
    static func features(_ item: Item) -> [(key: String, kind: Double)] {
        var out: [(String, Double)] = []
        var seen = Set<String>()
        func add(_ prefix: String, _ raw: String, _ k: Double) {
            let n = TextMatch.norm(raw)
            guard !n.isEmpty, Self.isTaste(raw) else { return }
            let key = "\(prefix):\(n)"
            if seen.insert(key).inserted { out.append((key, k)) }
        }
        add("b", item.brand, 1.0)
        if let c = item.creator { add("c", c, 1.0) }
        item.traits.forEach { add("t", $0, 0.7) }
        item.tags.forEach { add("g", $0, 0.45) }
        out.append(("k:\(item.category.rawValue)", 0.6))
        add("s", item.source, 0.2)
        return out
    }

    /// A real taste word, not a price, sale tag, size, SKU or season code (same rule as AppStore.isTaste).
    static func isTaste(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.count <= 40 else { return false }
        if t.range(of: #"[$£€¥]|\b(sale|price|off|usd|gbp|eur)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if t.filter(\.isNumber).count * 2 >= t.count { return false }
        if t.range(of: #"^(ss|fw|aw)\d{2}$|^size\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return true
    }

    /// A readable label for a feature key ("b:new balance" → "New Balance").
    static func label(_ key: String, item: Item? = nil) -> String {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return key }
        if let item {
            if parts[0] == "b", TextMatch.norm(item.brand) == parts[1] { return item.brand }
            if parts[0] == "c", let c = item.creator, TextMatch.norm(c) == parts[1] { return c }
        }
        if parts[0] == "k", let c = Category(rawValue: parts[1]) { return c.info.label.lowercased() }
        return parts[1]
    }

    // MARK: Weights with decay

    func value(_ key: String, now: Date = .now) -> Double {
        guard let x = weights[key] else { return 0 }
        let days = max(0, now.timeIntervalSince(x.at) / 86400)
        return x.w * pow(0.5, days / Self.halfLifeDays)
    }

    mutating func bump(_ key: String, by d: Double, now: Date = .now) {
        let v = max(-6, min(8, value(key, now: now) + d))
        weights[key] = Weight(w: v, at: now)
    }

    // MARK: Learning

    mutating func observe(_ item: Item, _ signal: Signal, now: Date = .now) {
        let d = signal.delta
        if d != 0 {
            for f in Self.features(item) { bump(f.key, by: d * f.kind, now: now) }
        }
        switch signal {
        case .like, .buy:
            if item.priceKnown, item.price > 0 {
                likedPrices.append(item.price)
                if likedPrices.count > 40 { likedPrices.removeFirst(likedPrices.count - 40) }
                if let c = priceCeiling, item.price > c { priceCeiling = item.price }   // you went above it: loosen
            }
        case .passPrice:
            if item.priceKnown, item.price > 0 { priceCeiling = min(priceCeiling ?? .infinity, item.price * 0.85).rounded() }
        case .passOwn, .passStyle, .passLater:
            hidden.insert(item.id)
        default: break
        }
        if signal != .open { signals += 1 }
        impressions[item.id, default: Impression()].engaged = true
        trim()
    }

    /// Records that a listing was on screen today. Counting days (not views) keeps the order steady within a day.
    mutating func noteShown(_ ids: [String], day: String) {
        for id in ids {
            var imp = impressions[id] ?? Impression()
            if imp.lastDay != day { imp.days += 1; imp.lastDay = day }
            impressions[id] = imp
        }
        trim()
    }

    /// Keeps the saved model small: drop faded weights and old impressions.
    private mutating func trim() {
        if weights.count > 600 {
            let now = Date.now
            weights = weights.filter { abs(value($0.key, now: now)) >= 0.05 }
        }
        if impressions.count > 1500 {
            let keep = impressions.sorted { $0.value.lastDay > $1.value.lastDay }.prefix(1000)
            impressions = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if hidden.count > 1500 { hidden = Set(hidden.prefix(1000)) }
    }

    // MARK: Price

    /// -0.5…+0.2: how well a price sits in the range you actually go for.
    func priceFit(_ item: Item) -> Double {
        guard item.priceKnown, item.price > 0 else { return 0 }
        var s = 0.0
        if let c = priceCeiling, item.price > c { s -= min(0.5, 0.2 + 0.3 * (item.price / c - 1)) }
        let logs = likedPrices.filter { $0 > 0 }.map { Foundation.log($0) }
        if logs.count >= 3 {
            let mean = logs.reduce(0, +) / Double(logs.count)
            let sd = max(0.35, sqrt(logs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(logs.count)))
            let z = (Foundation.log(item.price) - mean) / sd
            s += 0.2 * exp(-z * z / 2) - 0.1     // inside your range +0.1, far outside -0.1
        }
        return s
    }
}

/// Stable 0..<1 number for a string (Swift's hashValue changes every launch, so it can't be used here).
func stableUnit(_ s: String) -> Double {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return Double(h % 10_000) / 10_000
}
