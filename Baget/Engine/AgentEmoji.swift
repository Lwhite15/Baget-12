import Foundation

/// Picks an emoji that fits what a scout hunts, from its name, mission and keywords.
/// Used whenever the scout has no emoji or photo of its own, so no scout ever shows plain initials.
enum AgentEmoji {
    /// Most specific first: "Glock sights" should land on 🎯, not the generic accessories pick.
    private static let rules: [([String], String)] = [
        (["glock", "pistol", "handgun", "rifle", "firearm", "holster", "optic", "sights", "ammo", "tactical"], "🎯"),
        (["knife", "knives", "blade", "edc"], "🔪"),
        (["sneaker", "jordan", "dunk", "yeezy", "nike", "new balance", "kicks", "trainer", "air max", "shoe"], "👟"),
        (["boot", "loafer", "heel"], "🥾"),
        (["fragrance", "perfume", "parfum", "cologne", "scent", "oud", "extrait", "longevity", "smell"], "🧴"),
        (["watch", "rolex", "omega", "patek", "audemars", "seiko", "timepiece", "chronograph"], "⌚️"),
        (["porsche", "ferrari", "lambo", "car", "cars", "vehicle", "gt3", "bmw", "mercedes", "911", "truck", "jdm"], "🏎️"),
        (["motorcycle", "motorbike", "ducati", "harley"], "🏍️"),
        (["sofa", "couch", "chair", "furniture", "table", "lamp", "eames", "decor", "rug", "interior"], "🛋️"),
        (["vinyl", "record", "turntable", "album"], "💿"),
        (["headphone", "speaker", "audio", "hifi", "hi-fi"], "🎧"),
        (["camera", "lens", "leica", "film"], "📸"),
        (["art", "print", "painting", "poster"], "🎨"),
        (["card", "pokemon", "pokémon", "tcg", "graded", "psa"], "🃏"),
        (["toy", "figure", "lego", "bearbrick", "kaws", "collectible", "funko"], "🧸"),
        (["comic", "manga", "book"], "📚"),
        (["game", "console", "nintendo", "playstation", "xbox", "gaming"], "🎮"),
        (["laptop", "phone", "iphone", "tech", "gadget", "computer", "pc"], "💻"),
        (["golf"], "⛳️"),
        (["bike", "cycling", "bicycle"], "🚲"),
        (["surf", "skate", "snowboard", "ski"], "🏄"),
        (["fishing", "outdoor", "camping", "hiking", "gear"], "🏕️"),
        (["wine", "whiskey", "bourbon", "tequila", "spirits", "liquor"], "🥃"),
        (["coffee", "espresso"], "☕️"),
        (["jewelry", "jewellery", "ring", "chain", "diamond", "necklace", "bracelet", "cartier"], "💎"),
        (["bag", "handbag", "purse", "hermes", "hermès", "birkin", "backpack", "wallet"], "👜"),
        (["sunglass", "glasses", "eyewear"], "🕶️"),
        (["hat", "cap", "beanie"], "🧢"),
        (["supreme", "hoodie", "streetwear", "tee", "shirt", "jacket", "apparel", "clothes", "clothing", "denim", "jeans", "drip", "fashion"], "🧥"),
        (["plant", "garden"], "🌿"),
        (["deal", "discount", "sale", "bargain"], "🏷️"),
        (["grail", "rare", "limited", "exclusive", "drop"], "🔥"),
    ]

    private static let byCategory: [Category: String] = [
        .sneakers: "👟", .apparel: "🧥", .fragrance: "🧴", .watches: "⌚️", .cars: "🏎️",
        .furniture: "🛋️", .accessories: "🕶️", .collectibles: "🧸", .other: "🕵️",
    ]

    static func pick(name: String, mission: Mission? = nil, keywords: [String] = []) -> String {
        var parts = [name] + keywords
        if case .custom(let text)? = mission { parts.append(text) }
        let text = " " + parts.joined(separator: " ").lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\- ]+"#, with: " ", options: .regularExpression) + " "
        // Clear-cut missions keep their own emoji; broad ones (apparel, accessories, collectibles, custom) read the words.
        if let c = mission?.category, [.sneakers, .fragrance, .watches, .cars, .furniture].contains(c), let e = byCategory[c] { return e }
        for (words, emoji) in rules where words.contains(where: { matches(text, $0) }) { return emoji }
        if let c = mission?.category, let e = byCategory[c] { return e }
        return "🕵️"
    }

    static func pick(_ agent: Agent) -> String { pick(name: agent.name, mission: agent.mission, keywords: agent.keywords) }

    /// Whole word, allowing a plural or -ing ending ("sights" matches "sight", "cars" matches "car").
    private static func matches(_ text: String, _ word: String) -> Bool {
        text.range(of: #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: word) + #"(s|es|ing)?(?![\p{L}\p{N}])"#,
                   options: .regularExpression) != nil
    }
}
