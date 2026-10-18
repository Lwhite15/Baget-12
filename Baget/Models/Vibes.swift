import Foundation

/// Plain-language taste choices for setup, so nobody needs to know brand names to get good picks.
/// The server turns these into concrete things to search for (e.g. "fresh & clean" → citrus, aquatic, musk).
enum Vibes {
    static func question(_ c: Category) -> String {
        switch c {
        case .fragrance: return "What do you like to smell like?"
        case .sneakers: return "What kind of sneakers?"
        case .apparel: return "What's your style?"
        case .watches: return "What kind of watch?"
        case .cars: return "What kind of car?"
        case .furniture: return "What's your home like?"
        case .accessories: return "What kind of accessories?"
        case .collectibles: return "What do you collect?"
        case .other: return "What are you into?"
        }
    }

    static func options(_ c: Category) -> [String] {
        switch c {
        case .fragrance:
            return ["Fresh & clean", "Citrus & bright", "Sweet & cozy", "Vanilla", "Woody & warm", "Spicy", "Floral",
                    "Smoky & leather", "Beachy & salty", "Earthy & green", "Every day", "Office", "Date night", "Summer", "Gift"]
        case .sneakers:
            return ["Everyday & comfy", "Classic & clean", "Bold colors", "Running & retro", "Basketball", "Skate",
                    "Rare & hyped", "Under the radar"]
        case .apparel:
            return ["Streetwear", "Minimal & clean", "Vintage", "Outdoor & workwear", "Smart casual", "Athletic",
                    "Bold & loud", "Cozy basics"]
        case .watches:
            return ["Everyday", "Dressy", "Sporty & tough", "Dive", "Vintage", "Small & slim", "Big & bold", "Smart features"]
        case .cars:
            return ["Daily driver", "Sporty", "Luxury", "Classic", "Off-road", "Family & roomy", "Electric", "Good on gas"]
        case .furniture:
            return ["Cozy", "Modern & minimal", "Mid-century", "Vintage", "Natural wood", "Bold & colorful", "Small spaces"]
        case .accessories:
            return ["Bags", "Hats", "Jewelry", "Sunglasses", "Wallets", "Everyday", "Statement pieces", "Minimal"]
        case .collectibles:
            return ["Trading cards", "Toys & figures", "Art & prints", "Vinyl & music", "Sports", "Vintage", "Limited drops"]
        case .other:
            return []
        }
    }

    /// The most someone usually spends on one item. 0 means no limit.
    static let budgets: [(label: String, cap: Int?)] = [
        ("Under $50", 50), ("Up to $100", 100), ("Up to $250", 250), ("Up to $500", 500), ("Up to $1,000", 1000), ("No limit", 0),
    ]
}
