import Foundation

/// Plain-language taste choices for setup, so nobody needs to know brand names to get good picks.
/// The server turns these into concrete things to search for (e.g. "fresh & clean" → citrus, aquatic, musk).
enum Vibes {
    /// Sizes to tap in setup, for the categories whose scouts only flag what's in stock in your size.
    static func sizes(_ c: Category, women: Bool = false) -> [String]? {
        let half = { (a: Double, b: Double) in stride(from: a, through: b, by: 0.5).map { $0 == $0.rounded() ? String(Int($0)) : String($0) } }
        switch c {
        case .sneakers: return women ? half(5, 12) : half(6, 14) + ["15"]
        case .apparel: return ["XS", "S", "M", "L", "XL", "XXL"]
        default: return nil
        }
    }

    /// How a tapped size is saved on the scout. Women's shoes say "US W 8" (read as US men's 6.5 when checking stock);
    /// women's clothing keeps the letter size and says womenswear, so the scout hunts the right department.
    static func sizeValue(_ c: Category, _ size: String, women: Bool) -> String {
        guard women else { return size }
        return c == .sneakers ? "US W \(size)" : "\(size) (womenswear)"
    }

    static func question(_ c: Category) -> String {
        switch c {
        case .fragrance: return String(localized: "What do you like to smell like?")
        case .sneakers: return String(localized: "What kind of sneakers?")
        case .apparel: return String(localized: "What's your style?")
        case .watches: return String(localized: "What kind of watch?")
        case .cars: return String(localized: "What kind of car?")
        case .furniture: return String(localized: "What's your home like?")
        case .accessories: return String(localized: "What kind of accessories?")
        case .collectibles: return String(localized: "What do you collect?")
        case .other: return String(localized: "What are you into?")
        }
    }

    static func options(_ c: Category) -> [String] {
        switch c {
        case .fragrance:
            return [String(localized: "Fresh & clean"), String(localized: "Citrus & bright"), String(localized: "Sweet & cozy"), String(localized: "Vanilla"), String(localized: "Woody & warm"), String(localized: "Spicy"), String(localized: "Floral"),
                    String(localized: "Smoky & leather"), String(localized: "Beachy & salty"), String(localized: "Earthy & green"), String(localized: "Every day"), String(localized: "Office"), String(localized: "Date night"), String(localized: "Summer"), String(localized: "Gift")]
        case .sneakers:
            return [String(localized: "Everyday & comfy"), String(localized: "Classic & clean"), String(localized: "Bold colors"), String(localized: "Running & retro"), String(localized: "Basketball"), String(localized: "Skate"),
                    String(localized: "Rare & hyped"), String(localized: "Under the radar")]
        case .apparel:
            return [String(localized: "Streetwear"), String(localized: "Minimal & clean"), String(localized: "Vintage"), String(localized: "Outdoor & workwear"), String(localized: "Smart casual"), String(localized: "Athletic"),
                    String(localized: "Bold & loud"), String(localized: "Cozy basics")]
        case .watches:
            return [String(localized: "Everyday"), String(localized: "Dressy"), String(localized: "Sporty & tough"), String(localized: "Dive"), String(localized: "Vintage"), String(localized: "Small & slim"), String(localized: "Big & bold"), String(localized: "Smart features")]
        case .cars:
            return [String(localized: "Daily driver"), String(localized: "Sporty"), String(localized: "Luxury"), String(localized: "Classic"), String(localized: "Off-road"), String(localized: "Family & roomy"), String(localized: "Electric"), String(localized: "Good on gas")]
        case .furniture:
            return [String(localized: "Cozy"), String(localized: "Modern & minimal"), String(localized: "Mid-century"), String(localized: "Vintage"), String(localized: "Natural wood"), String(localized: "Bold & colorful"), String(localized: "Small spaces")]
        case .accessories:
            return [String(localized: "Bags"), String(localized: "Hats"), String(localized: "Jewelry"), String(localized: "Sunglasses"), String(localized: "Wallets"), String(localized: "Everyday"), String(localized: "Statement pieces"), String(localized: "Minimal")]
        case .collectibles:
            return [String(localized: "Trading cards"), String(localized: "Toys & figures"), String(localized: "Art & prints"), String(localized: "Vinyl & music"), String(localized: "Sports"), String(localized: "Vintage"), String(localized: "Limited drops")]
        case .other:
            return []
        }
    }

    /// Well-known brands to tap in setup. Scouts still find others; these are just a quick start.
    static func brands(_ c: Category) -> [String] {
        switch c {
        case .fragrance:
            return ["Dior", "Chanel", "Tom Ford", "Le Labo", "Byredo", "Maison Margiela", "Creed", "YSL", "Versace", "Jo Malone",
                    "Parfums de Marly", "Diptyque"]
        case .sneakers:
            return ["Nike", "Jordan", "Adidas", "New Balance", "Asics", "Salomon", "Converse", "Vans", "Puma", "On", "Hoka"]
        case .apparel:
            return ["Supreme", "Stüssy", "Carhartt WIP", "Fear of God", "Aimé Leon Dore", "Kith", "Palace", "Ralph Lauren",
                    "Arc'teryx", "Patagonia", "Uniqlo", "Bape"]
        case .watches:
            return ["Rolex", "Omega", "Seiko", "Tudor", "Cartier", "Casio G-Shock", "Tissot", "Hamilton", "Grand Seiko", "Apple"]
        case .cars:
            return ["Toyota", "Honda", "BMW", "Mercedes-Benz", "Porsche", "Tesla", "Ford", "Lexus", "Audi", "Jeep"]
        case .furniture:
            return ["Herman Miller", "Article", "West Elm", "CB2", "Restoration Hardware", "IKEA", "Knoll", "Vitra"]
        case .accessories:
            return ["Louis Vuitton", "Gucci", "Goyard", "Chrome Hearts", "Ray-Ban", "New Era", "Telfar", "Coach", "Tiffany & Co."]
        case .collectibles:
            return ["Pokémon", "Funko", "LEGO", "KAWS", "Bearbrick", "Hot Wheels", "Topps", "Panini"]
        case .other:
            return []
        }
    }

    /// The most someone usually spends on one item. 0 means no limit.
    static let budgets: [(label: String, cap: Int?)] = [
        ("Under $50", 50), (String(localized: "Up to $100"), 100), (String(localized: "Up to $250"), 250), (String(localized: "Up to $500"), 500), (String(localized: "Up to $1,000"), 1000), (String(localized: "No limit"), 0),
    ]
}
