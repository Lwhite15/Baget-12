import Foundation

// MARK: - Categories ("missions")

enum Category: String, Codable, CaseIterable, Identifiable, Hashable {
    case sneakers, apparel, fragrance, watches, cars, furniture, accessories, collectibles
    /// Listings found for custom missions ("first-press vinyl"). Never offered as a mission or a section.
    case other
    var id: String { rawValue }
    /// The missions people can pick. `.other` is deliberately left out.
    static var allCases: [Category] { [.sneakers, .apparel, .fragrance, .watches, .cars, .furniture, .accessories, .collectibles] }
}

/// Each mission speaks its own language: what a "trait", a "maker" and a "creator" mean there.
struct CategoryInfo {
    let label: String
    let symbol: String
    let sizeRequired: Bool
    let sizeLabel: String?
    let traitsLabel: String
    let traitsPlaceholder: String
    let makersLabel: String
    let makersPlaceholder: String
    let creatorsLabel: String
    let creatorsPlaceholder: String
    let traitNoun: String
    let makerNoun: String
    let creatorVerb: String
    let creatorNoun: String
}

extension Category {
    var info: CategoryInfo {
        switch self {
        case .sneakers:
            return CategoryInfo(label: "Sneakers", symbol: "shoe.fill", sizeRequired: true, sizeLabel: "Shoe size",
                                traitsLabel: "Silhouettes, colorways, materials", traitsPlaceholder: "Jordan 1, suede, low top",
                                makersLabel: "Brands", makersPlaceholder: "Jordan, New Balance",
                                creatorsLabel: "Collabs and designers", creatorsPlaceholder: "Travis Scott, Aimé Leon Dore",
                                traitNoun: "details", makerNoun: "brand", creatorVerb: "Made with", creatorNoun: "a collaborator")
        case .apparel:
            return CategoryInfo(label: "Clothing", symbol: "tshirt.fill", sizeRequired: true, sizeLabel: "Clothing size",
                                traitsLabel: "Fits, fabrics, pieces", traitsPlaceholder: "boxy, heavyweight fleece, outerwear",
                                makersLabel: "Labels", makersPlaceholder: "Supreme, Stüssy",
                                creatorsLabel: "Collabs and designers", creatorsPlaceholder: "The North Face",
                                traitNoun: "details", makerNoun: "label", creatorVerb: "Made with", creatorNoun: "a collaborator")
        case .fragrance:
            return CategoryInfo(label: "Fragrance", symbol: "drop.fill", sizeRequired: false, sizeLabel: "Bottle size",
                                traitsLabel: "Notes you love", traitsPlaceholder: "oud, rose, saffron, incense",
                                makersLabel: "Houses", makersPlaceholder: "Frédéric Malle, MFK",
                                creatorsLabel: "Perfumers", creatorsPlaceholder: "Dominique Ropion",
                                traitNoun: "notes", makerNoun: "house", creatorVerb: "Composed by", creatorNoun: "a perfumer")
        case .watches:
            return CategoryInfo(label: "Watches", symbol: "watch.analog", sizeRequired: false, sizeLabel: "Case size",
                                traitsLabel: "Styles and specs", traitsPlaceholder: "integrated bracelet, steel, diver",
                                makersLabel: "Manufactures", makersPlaceholder: "Audemars Piguet, Tudor",
                                creatorsLabel: "Designers", creatorsPlaceholder: "Gérald Genta",
                                traitNoun: "specs", makerNoun: "manufacture", creatorVerb: "Designed by", creatorNoun: "a designer")
        case .cars:
            return CategoryInfo(label: "Cars", symbol: "car.fill", sizeRequired: false, sizeLabel: nil,
                                traitsLabel: "Eras, body styles, specs", traitsPlaceholder: "air-cooled, manual, coupe",
                                makersLabel: "Makes", makersPlaceholder: "Porsche, BMW M",
                                creatorsLabel: "Tuners and builders", creatorsPlaceholder: "Singer, RUF",
                                traitNoun: "specs", makerNoun: "make", creatorVerb: "Built by", creatorNoun: "a builder")
        case .furniture:
            return CategoryInfo(label: "Furniture", symbol: "sofa.fill", sizeRequired: false, sizeLabel: nil,
                                traitsLabel: "Periods, materials, forms", traitsPlaceholder: "mid-century, walnut, cane",
                                makersLabel: "Makers", makersPlaceholder: "Herman Miller, Cassina",
                                creatorsLabel: "Designers", creatorsPlaceholder: "Pierre Jeanneret, Eames",
                                traitNoun: "details", makerNoun: "maker", creatorVerb: "Designed by", creatorNoun: "a designer")
        case .accessories:
            return CategoryInfo(label: "Accessories", symbol: "bag.fill", sizeRequired: false, sizeLabel: nil,
                                traitsLabel: "Materials and pieces", traitsPlaceholder: "sterling silver, leather, rings",
                                makersLabel: "Makers", makersPlaceholder: "Chrome Hearts, Goyard",
                                creatorsLabel: "Designers", creatorsPlaceholder: "Richard Stark",
                                traitNoun: "details", makerNoun: "maker", creatorVerb: "Designed by", creatorNoun: "a designer")
        case .other:
            return CategoryInfo(label: "Other", symbol: "sparkles", sizeRequired: false, sizeLabel: nil,
                                traitsLabel: "Traits", traitsPlaceholder: "", makersLabel: "Makers", makersPlaceholder: "",
                                creatorsLabel: "Creators", creatorsPlaceholder: "",
                                traitNoun: "traits", makerNoun: "maker", creatorVerb: "By", creatorNoun: "a creator")
        case .collectibles:
            return CategoryInfo(label: "Collectibles", symbol: "star.square.fill", sizeRequired: false, sizeLabel: nil,
                                traitsLabel: "Sets, grades, formats", traitsPlaceholder: "Base Set, PSA 9, first press",
                                makersLabel: "Brands and labels", makersPlaceholder: "Pokémon, Medicom",
                                creatorsLabel: "Artists", creatorsPlaceholder: "KAWS, Daft Punk",
                                traitNoun: "details", makerNoun: "brand", creatorVerb: "By", creatorNoun: "an artist")
        }
    }
}

let customMissionInfo = CategoryInfo(label: "Custom", symbol: "sparkle.magnifyingglass", sizeRequired: false, sizeLabel: "Sizes or specs",
                                      traitsLabel: "Traits you want", traitsPlaceholder: "condition, era, color, material",
                                      makersLabel: "Brands or makers", makersPlaceholder: "Any you trust",
                                      creatorsLabel: "Creators or designers", creatorsPlaceholder: "Anyone you follow",
                                      traitNoun: "traits", makerNoun: "maker", creatorVerb: "By", creatorNoun: "a creator")

// MARK: - Catalog items

struct Item: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let brand: String
    let category: Category
    let sku: String
    /// 0 when the store doesn't show a price yet (see `priceKnown`).
    let price: Double
    /// Typical resale or secondhand price. Equals `price` when unknown.
    let market: Double
    let source: String
    /// Sample listings only: minutes after the catalog start when this goes live. Zero or less means available now.
    let dropOffset: Double
    let soldOutAtStart: Bool
    let creator: String?
    let traits: [String]
    let tags: [String]
    /// US men's sizes in stock (sneakers).
    let shoeSizes: [Double]?
    /// Letter sizes in stock (clothing).
    let topSizes: [String]?
    // Real listings found by the server
    var url: String? = nil
    var imageURL: String? = nil
    var dropAt: Date? = nil
    var firstSeen: Date? = nil
    var priceKnown: Bool = true
    var isSample: Bool = true
}

// MARK: - Agents

enum Mission: Codable, Hashable {
    case category(Category)
    case custom(String)

    var label: String {
        switch self {
        case .category(let c): return c.info.label
        case .custom(let text): return text
        }
    }
    var info: CategoryInfo {
        switch self {
        case .category(let c): return c.info
        case .custom: return customMissionInfo
        }
    }
    var category: Category? {
        if case .category(let c) = self { return c }
        return nil
    }
}

enum BuyMode: String, Codable, CaseIterable, Identifiable {
    case alert, ask, auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .alert: return "Alert only"
        case .ask: return "Ask before buying"
        case .auto: return "Auto-buy (beta)"
        }
    }
    var short: String {
        switch self {
        case .alert: return "Alert only"
        case .ask: return "Asks to buy"
        case .auto: return "Auto-buy"
        }
    }
}

enum Voice: String, Codable, CaseIterable, Identifiable {
    case hype, chill, straight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hype: return "Hype friend"
        case .chill: return "Chill friend"
        case .straight: return "Straight shooter"
        }
    }
    var blurb: String {
        switch self {
        case .hype: return "Excited, never lets you miss a drop"
        case .chill: return "Easygoing, gives you the gist"
        case .straight: return "Just the facts and the price"
        }
    }
}

struct StyleProfile: Codable, Hashable {
    var traits: [String] = []
    var makers: [String] = []
    var creators: [String] = []
}

struct Agent: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var mission: Mission
    var keywords: [String]
    var style: StyleProfile
    var size: String
    var maxPerItem: Double
    var monthlyLimit: Double
    var mode: BuyMode
    var voice: Voice
    /// What the agent picked up from your buys and passes: positive = likes, negative = not into.
    var learned: [String: Int] = [:]
    /// Set when you pass on things for being too pricey.
    var priceNote: Double = 0
    /// Photos you showed the agent to teach it your taste (newest first, up to 6).
    var tasteBoard: [TastePhoto] = []
}

struct TastePhoto: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var addedAt: Date = .now
    /// What the agent kept from the photo, after you reviewed it.
    var tags: [String]
    var summary: String
    /// Where the photo lives in cloud storage (signed in only).
    var storagePath: String? = nil
}

// MARK: - Finds, purchases, notifications

enum FindStatus: String, Codable { case open, passed, acquired }

struct Find: Codable, Identifiable, Hashable {
    var id: String
    var itemID: String
    var agentID: String
    var score: Int
    var why: [String]
    var status: FindStatus = .open
    var passReason: String? = nil
    var watching: Bool = false
    var foundAt: Date = .now
}

struct Purchase: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var date: Date
    var title: String
    var amount: Double
    var agentID: String
    var category: Category
    var isSample: Bool = false
    var listingID: String? = nil
    var agentName: String = ""
}

enum NoteKind: String, Codable {
    case release, available, steal, watch, restock, bought, budget, learned, friend
}

enum NoteGroup: String, Codable, CaseIterable, Identifiable {
    case finds, restocks, steals, money, learning
    var id: String { rawValue }
    var label: String {
        switch self {
        case .finds: return "New finds and drops"
        case .restocks: return "Restocks"
        case .steals: return "Prices well under market"
        case .money: return "Purchases and budget"
        case .learning: return "What my agents learn"
        }
    }
}

extension NoteKind {
    var group: NoteGroup? {
        switch self {
        case .release, .available: return .finds
        case .watch, .restock: return .restocks
        case .steal: return .steals
        case .bought, .budget: return .money
        case .learned: return .learning
        case .friend: return nil
        }
    }
}

struct AppNote: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var date: Date = .now
    var agentID: String?
    var friendID: String?
    var kind: NoteKind
    var body: String
    var findID: String?
    var read: Bool = false
    var heldForMorning: Bool = false
    var senderName: String = ""
}

// MARK: - Friends

struct Friend: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var handle: String
    var hunts: [Category]
    var likes: [String]
    var isPending: Bool = false
    var isSample: Bool = true
    var replies: [String]
    /// Signed in: the friendship row, and who asked whom while it's pending.
    var friendshipID: String? = nil
    var incoming: Bool = false
}

enum SuggestionStatus: String, Codable { case new, sent, passed }

struct Suggestion: Codable, Identifiable, Hashable {
    var id: String
    var friendID: String
    var itemID: String
    var note: String
    var date: Date
    var status: SuggestionStatus = .new
    var shareID: String? = nil
}

struct ShareReply: Codable, Hashable {
    var friendID: String
    var text: String
    var date: Date
}

struct Share: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var itemID: String
    var to: [String]
    var note: String
    var date: Date = .now
    var isSuggestion: Bool = false
    var replies: [ShareReply] = []
}

// MARK: - Live bar and settings

enum LiveTabKind: Codable, Hashable {
    case forYou, latest
    case category(Category)
    case custom(String)
}

struct LiveTab: Codable, Identifiable, Hashable {
    var id: String
    var kind: LiveTabKind
    var label: String

    static var presets: [LiveTab] {
        [LiveTab(id: "foryou", kind: .forYou, label: "For you"),
         LiveTab(id: "latest", kind: .latest, label: "Latest")]
        + Category.allCases.map { LiveTab(id: $0.rawValue, kind: .category($0), label: $0.info.label) }
    }
}

struct Settings: Codable, Hashable {
    var sweepMinutes: Int = 360
    var quietHours: Bool = true
    var groups: Set<NoteGroup> = Set(NoteGroup.allCases)
    var shareTasteWithFriends: Bool = true
    var sharePurchasesWithFriends: Bool = false
}

// MARK: - Root state (saved as JSON)

struct AppState: Codable {
    var catalogStart: Date = .now
    var agents: [Agent] = []
    var finds: [Find] = []
    var seenItemIDs: Set<String> = []
    var restockedItemIDs: Set<String> = []
    var purchases: [Purchase] = []
    var notes: [AppNote] = []
    var log: [LogLine] = []
    var friends: [Friend] = []
    var suggestions: [Suggestion] = []
    var shares: [Share] = []
    var liveTabs: [LiveTab] = LiveTab.presets
    var settings = Settings()
    var lastSeen: Date = .now
    var awayReport: AwayReport? = nil
    // Signed in
    var accountID: String? = nil
    var profile: Profile? = nil
    var listings: [Item] = []
    var chats: [String: [ChatTurn]] = [:]
    var lastSynced: Date? = nil
    /// The person chose to look around with sample data instead of signing in.
    var exploringSamples = false
    var avatar = Avatar()

    init() {}

    // Tolerant decoding: anything missing from an older save falls back to its default instead of failing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppState()
        catalogStart = (try? c.decode(Date.self, forKey: .catalogStart)) ?? d.catalogStart
        agents = (try? c.decode([Agent].self, forKey: .agents)) ?? []
        finds = (try? c.decode([Find].self, forKey: .finds)) ?? []
        seenItemIDs = (try? c.decode(Set<String>.self, forKey: .seenItemIDs)) ?? []
        restockedItemIDs = (try? c.decode(Set<String>.self, forKey: .restockedItemIDs)) ?? []
        purchases = (try? c.decode([Purchase].self, forKey: .purchases)) ?? []
        notes = (try? c.decode([AppNote].self, forKey: .notes)) ?? []
        log = (try? c.decode([LogLine].self, forKey: .log)) ?? []
        friends = (try? c.decode([Friend].self, forKey: .friends)) ?? []
        suggestions = (try? c.decode([Suggestion].self, forKey: .suggestions)) ?? []
        shares = (try? c.decode([Share].self, forKey: .shares)) ?? []
        liveTabs = (try? c.decode([LiveTab].self, forKey: .liveTabs)) ?? d.liveTabs
        settings = (try? c.decode(Settings.self, forKey: .settings)) ?? d.settings
        lastSeen = (try? c.decode(Date.self, forKey: .lastSeen)) ?? d.lastSeen
        awayReport = try? c.decode(AwayReport.self, forKey: .awayReport)
        accountID = try? c.decode(String.self, forKey: .accountID)
        profile = try? c.decode(Profile.self, forKey: .profile)
        listings = (try? c.decode([Item].self, forKey: .listings)) ?? []
        chats = (try? c.decode([String: [ChatTurn]].self, forKey: .chats)) ?? [:]
        lastSynced = try? c.decode(Date.self, forKey: .lastSynced)
        exploringSamples = (try? c.decode(Bool.self, forKey: .exploringSamples)) ?? false
        avatar = (try? c.decode(Avatar.self, forKey: .avatar)) ?? Avatar()
    }
}

/// Your icon: initials or an emoji on a colored tile, or a photo.
struct Avatar: Codable, Hashable {
    enum Style: String, Codable, CaseIterable { case initials, emoji, photo }
    var style: Style = .initials
    var emoji: String = "🔥"
    var color: Int = 0
    /// The photo's id: its file on this phone, and avatars/<id>.jpg in your account's photo folder.
    var photoID: String? = nil

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? c.decode(Style.self, forKey: .style)) ?? .initials
        emoji = (try? c.decode(String.self, forKey: .emoji)) ?? "🔥"
        color = (try? c.decode(Int.self, forKey: .color)) ?? 0
        photoID = try? c.decode(String.self, forKey: .photoID)
    }
}

struct Profile: Codable, Hashable {
    var handle: String
    var displayName: String
}

/// One message in a chat with an agent.
struct ChatTurn: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var role: String          // "user" or "assistant"
    var text: String
    var actions: [ChatAction] = []
}

struct ChatAction: Codable, Hashable {
    var type: String          // profile_updated, find, checkout
    var findID: String? = nil
    var title: String? = nil
}

struct LogLine: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var date: Date = .now
    var text: String
}

struct AwayReport: Codable, Hashable {
    var date: Date
    var minutes: Int
    var sweeps: Int
    var checked: Int
    var found: Int
    var bought: Int
    var notes: Int
    var restocks: Int
}
