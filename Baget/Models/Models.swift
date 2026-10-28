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
            return CategoryInfo(label: String(localized: "Sneakers"), symbol: "shoe.fill", sizeRequired: true, sizeLabel: String(localized: "Shoe size"),
                                traitsLabel: String(localized: "Silhouettes, colorways, materials"), traitsPlaceholder: String(localized: "Jordan 1, suede, low top"),
                                makersLabel: String(localized: "Brands"), makersPlaceholder: String(localized: "Jordan, New Balance"),
                                creatorsLabel: String(localized: "Collabs and designers"), creatorsPlaceholder: String(localized: "Travis Scott, Aimé Leon Dore"),
                                traitNoun: String(localized: "details"), makerNoun: String(localized: "brand"), creatorVerb: String(localized: "Made with"), creatorNoun: String(localized: "a collaborator"))
        case .apparel:
            return CategoryInfo(label: String(localized: "Clothing"), symbol: "tshirt.fill", sizeRequired: true, sizeLabel: String(localized: "Clothing size"),
                                traitsLabel: String(localized: "Fits, fabrics, pieces"), traitsPlaceholder: "boxy, heavyweight fleece, outerwear",
                                makersLabel: String(localized: "Labels"), makersPlaceholder: String(localized: "Supreme, Stüssy"),
                                creatorsLabel: String(localized: "Collabs and designers"), creatorsPlaceholder: String(localized: "The North Face"),
                                traitNoun: String(localized: "details"), makerNoun: String(localized: "label"), creatorVerb: String(localized: "Made with"), creatorNoun: String(localized: "a collaborator"))
        case .fragrance:
            return CategoryInfo(label: String(localized: "Fragrance"), symbol: "drop.fill", sizeRequired: false, sizeLabel: String(localized: "Bottle size"),
                                traitsLabel: String(localized: "Notes you love"), traitsPlaceholder: "oud, rose, saffron, incense",
                                makersLabel: String(localized: "Houses"), makersPlaceholder: String(localized: "Frédéric Malle, MFK"),
                                creatorsLabel: String(localized: "Perfumers"), creatorsPlaceholder: String(localized: "Dominique Ropion"),
                                traitNoun: String(localized: "notes"), makerNoun: String(localized: "house"), creatorVerb: String(localized: "Composed by"), creatorNoun: String(localized: "a perfumer"))
        case .watches:
            return CategoryInfo(label: String(localized: "Watches"), symbol: "watch.analog", sizeRequired: false, sizeLabel: String(localized: "Case size"),
                                traitsLabel: String(localized: "Styles and specs"), traitsPlaceholder: "integrated bracelet, steel, diver",
                                makersLabel: String(localized: "Manufactures"), makersPlaceholder: String(localized: "Audemars Piguet, Tudor"),
                                creatorsLabel: String(localized: "Designers"), creatorsPlaceholder: String(localized: "Gérald Genta"),
                                traitNoun: String(localized: "specs"), makerNoun: String(localized: "manufacture"), creatorVerb: String(localized: "Designed by"), creatorNoun: String(localized: "a designer"))
        case .cars:
            return CategoryInfo(label: String(localized: "Cars"), symbol: "car.fill", sizeRequired: false, sizeLabel: nil,
                                traitsLabel: String(localized: "Eras, body styles, specs"), traitsPlaceholder: "air-cooled, manual, coupe",
                                makersLabel: String(localized: "Makes"), makersPlaceholder: String(localized: "Porsche, BMW M"),
                                creatorsLabel: String(localized: "Tuners and builders"), creatorsPlaceholder: String(localized: "Singer, RUF"),
                                traitNoun: String(localized: "specs"), makerNoun: String(localized: "make"), creatorVerb: String(localized: "Built by"), creatorNoun: String(localized: "a builder"))
        case .furniture:
            return CategoryInfo(label: String(localized: "Furniture"), symbol: "sofa.fill", sizeRequired: false, sizeLabel: nil,
                                traitsLabel: String(localized: "Periods, materials, forms"), traitsPlaceholder: "mid-century, walnut, cane",
                                makersLabel: String(localized: "Makers"), makersPlaceholder: String(localized: "Herman Miller, Cassina"),
                                creatorsLabel: String(localized: "Designers"), creatorsPlaceholder: String(localized: "Pierre Jeanneret, Eames"),
                                traitNoun: String(localized: "details"), makerNoun: String(localized: "maker"), creatorVerb: String(localized: "Designed by"), creatorNoun: String(localized: "a designer"))
        case .accessories:
            return CategoryInfo(label: String(localized: "Accessories"), symbol: "bag.fill", sizeRequired: false, sizeLabel: nil,
                                traitsLabel: String(localized: "Materials and pieces"), traitsPlaceholder: "sterling silver, leather, rings",
                                makersLabel: String(localized: "Makers"), makersPlaceholder: String(localized: "Chrome Hearts, Goyard"),
                                creatorsLabel: String(localized: "Designers"), creatorsPlaceholder: String(localized: "Richard Stark"),
                                traitNoun: String(localized: "details"), makerNoun: String(localized: "maker"), creatorVerb: String(localized: "Designed by"), creatorNoun: String(localized: "a designer"))
        case .other:
            return CategoryInfo(label: String(localized: "Other"), symbol: "sparkles", sizeRequired: false, sizeLabel: nil,
                                traitsLabel: String(localized: "Traits"), traitsPlaceholder: "", makersLabel: String(localized: "Makers"), makersPlaceholder: "",
                                creatorsLabel: String(localized: "Creators"), creatorsPlaceholder: "",
                                traitNoun: String(localized: "traits"), makerNoun: String(localized: "maker"), creatorVerb: String(localized: "By"), creatorNoun: String(localized: "a creator"))
        case .collectibles:
            return CategoryInfo(label: String(localized: "Collectibles"), symbol: "star.square.fill", sizeRequired: false, sizeLabel: nil,
                                traitsLabel: String(localized: "Sets, grades, formats"), traitsPlaceholder: String(localized: "Base Set, PSA 9, first press"),
                                makersLabel: String(localized: "Brands and labels"), makersPlaceholder: String(localized: "Pokémon, Medicom"),
                                creatorsLabel: String(localized: "Artists"), creatorsPlaceholder: String(localized: "KAWS, Daft Punk"),
                                traitNoun: String(localized: "details"), makerNoun: String(localized: "brand"), creatorVerb: String(localized: "By"), creatorNoun: String(localized: "an artist"))
        }
    }
}

let customMissionInfo = CategoryInfo(label: String(localized: "Custom"), symbol: "sparkle.magnifyingglass", sizeRequired: false, sizeLabel: String(localized: "Sizes or specs"),
                                      traitsLabel: String(localized: "Traits you want"), traitsPlaceholder: "condition, era, color, material",
                                      makersLabel: String(localized: "Brands or makers"), makersPlaceholder: String(localized: "Any you trust"),
                                      creatorsLabel: String(localized: "Creators or designers"), creatorsPlaceholder: String(localized: "Anyone you follow"),
                                      traitNoun: String(localized: "traits"), makerNoun: String(localized: "maker"), creatorVerb: String(localized: "By"), creatorNoun: String(localized: "a creator"))

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
    /// What other stores charge for the same product (Google Shopping), cheapest first.
    var offers: [Offer]? = nil
    var lowPrice: Double? = nil
    var lowStore: String? = nil
    /// Plain-language description: what it is (for fragrance, what it smells like). Written by the scout.
    var about: String? = nil
    /// Who the brand is, in a sentence or two. Shared by every product from that brand.
    var brandAbout: String? = nil
    /// Stores outside the US: the price in the store's own currency (`price` is converted to US dollars).
    var origPrice: Double? = nil
    var origCurrency: String? = nil
}

struct Offer: Codable, Hashable {
    let store: String
    let price: Double
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
        case .alert: return String(localized: "Alert only")
        case .ask: return String(localized: "Ask before buying")
        case .auto: return String(localized: "Auto-buy (beta)")
        }
    }
    var short: String {
        switch self {
        case .alert: return String(localized: "Alert only")
        case .ask: return String(localized: "Asks to buy")
        case .auto: return String(localized: "Auto-buy")
        }
    }
}

enum Voice: String, Codable, CaseIterable, Identifiable {
    case hype, chill, straight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hype: return String(localized: "Hype friend")
        case .chill: return String(localized: "Chill friend")
        case .straight: return String(localized: "Straight shooter")
        }
    }
    var blurb: String {
        switch self {
        case .hype: return String(localized: "Excited, never lets you miss a drop")
        case .chill: return String(localized: "Easygoing, gives you the gist")
        case .straight: return String(localized: "Just the facts and the price")
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
    var mode: BuyMode
    var voice: Voice
    /// What the agent picked up from your buys and passes: positive = likes, negative = not into.
    var learned: [String: Int] = [:]
    /// Set when you pass on things for being too pricey.
    var priceNote: Double = 0
    /// Photos you showed the agent to teach it your taste (newest first, up to 6).
    var tasteBoard: [TastePhoto] = []
    /// The agent's icon. Nil shows its initials on the house gradient.
    var icon: Avatar? = nil
    /// Turned off: no searching and no texts. Nil (older saves) means on.
    var paused: Bool? = nil
    /// How much this agent texts you. Nil means normal.
    var alerts: AgentAlerts? = nil

    var isOff: Bool {
        get { paused ?? false }
        set { paused = newValue }
    }
    var alertLevel: AgentAlerts {
        get { alerts ?? .normal }
        set { alerts = newValue }
    }
}

/// Per-agent texting, on top of the account's "How often Baget texts you".
enum AgentAlerts: String, Codable, CaseIterable, Identifiable {
    case normal, quiet, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: return String(localized: "Normal texts")
        case .quiet: return String(localized: "Only the very best")
        case .off: return String(localized: "No texts")
        }
    }
    var short: String {
        switch self {
        case .normal: return String(localized: "Texts")
        case .quiet: return String(localized: "Quiet")
        case .off: return String(localized: "Muted")
        }
    }
    var icon: String {
        switch self {
        case .normal: return "bell.fill"
        case .quiet: return "bell.badge"
        case .off: return "bell.slash.fill"
        }
    }
    var blurb: String {
        switch self {
        case .normal: return String(localized: "Follows your texting setting")
        case .quiet: return String(localized: "Only standout finds buzz your phone")
        case .off: return String(localized: "Finds still show up in the app, silently")
        }
    }
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

enum FindStatus: String, Codable {
    case open, liked, passed, acquired
    /// Cleared from Finds without a pass: no learning, and the agent won't show it again.
    case removed
}

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
    /// The 8am "Today's Drop" text, and a price drop on something you're watching.
    case digest, drop
    /// A tester sent feedback (owner accounts only).
    case feedback
    /// A release reminder the person set on an upcoming find.
    case reminder
}

/// "Remind me" on an upcoming release: some minutes before the drop (follows the date if it moves), or an exact time.
struct ReleaseReminder: Codable, Hashable {
    var remindAt: Date
    var offsetMinutes: Int?
}

enum NoteGroup: String, Codable, CaseIterable, Identifiable {
    case finds, restocks, steals, money, learning
    var id: String { rawValue }
    var label: String {
        switch self {
        case .finds: return String(localized: "New finds and drops")
        case .restocks: return String(localized: "Restocks")
        case .steals: return String(localized: "Prices well under market")
        case .money: return String(localized: "Purchases")
        case .learning: return String(localized: "What my scouts learn")
        }
    }
}

extension NoteKind {
    var group: NoteGroup? {
        switch self {
        case .release, .available, .reminder: return .finds
        case .watch, .restock: return .restocks
        case .steal, .drop: return .steals
        case .digest: return .finds
        case .bought, .budget: return .money
        case .learned: return .learning
        case .friend, .feedback: return nil
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
        [LiveTab(id: "foryou", kind: .forYou, label: String(localized: "For you")),
         LiveTab(id: "latest", kind: .latest, label: String(localized: "Latest"))]
        + Category.allCases.map { LiveTab(id: $0.rawValue, kind: .category($0), label: $0.info.label) }
    }
}

struct Settings: Codable, Hashable {
    var sweepMinutes: Int = 180
    var quietHours: Bool = true
    var groups: Set<NoteGroup> = Set(NoteGroup.allCases)
    var shareTasteWithFriends: Bool = true
    var sharePurchasesWithFriends: Bool = false
    /// How often Baget texts you. Nil means the default, `.best`.
    var pushLevel: PushLevel? = nil
    /// Free plan: the local hour the daily 4-hour hunting window starts. Nil means 9am.
    var huntStart: Int? = nil
}

enum PushLevel: String, Codable, CaseIterable, Identifiable {
    case best, all, daily
    var id: String { rawValue }
    var label: String {
        switch self {
        case .best: return String(localized: "Only the best")
        case .all: return String(localized: "Everything")
        case .daily: return String(localized: "Daily only")
        }
    }
    var blurb: String {
        switch self {
        case .best: return String(localized: "Texts for strong matches (85%+) only, at most 6 a day, plus price drops, restocks, Today's Drop and friends.")
        case .all: return String(localized: "Every find, as it happens.")
        case .daily: return String(localized: "Just the 8am Today's Drop, plus price drops and restocks on things you're watching.")
        }
    }
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
    /// The last For You feed and when it loaded, so Today shows it instantly on open and refreshes quietly.
    var forYou: [ForYouItem] = []
    var forYouAt: Date? = nil
    /// Release reminders you've set, by listing id.
    var reminders: [String: ReleaseReminder] = [:]

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
        forYou = (try? c.decode([ForYouItem].self, forKey: .forYou)) ?? []
        forYouAt = try? c.decode(Date.self, forKey: .forYouAt)
        reminders = (try? c.decode([String: ReleaseReminder].self, forKey: .reminders)) ?? [:]
    }
}

/// Your icon: initials or an emoji on a colored tile, or a photo.
struct Avatar: Codable, Hashable {
    enum Style: String, Codable, CaseIterable { case initials, emoji, photo, baget }
    var style: Style = .initials
    var emoji: String = "🔥"
    /// A palette index, or AvatarPalette.taste for your Taste Card's colors.
    var color: Int = 0
    /// The photo's id: its file on this phone, and avatars/<id>.jpg in your account's photo folder.
    var photoID: String? = nil
    /// A Baget icon (style .baget): one of BagetGlyph's symbol names.
    var glyph: String? = nil

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? c.decode(Style.self, forKey: .style)) ?? .initials
        emoji = (try? c.decode(String.self, forKey: .emoji)) ?? "🔥"
        color = (try? c.decode(Int.self, forKey: .color)) ?? 0
        photoID = try? c.decode(String.self, forKey: .photoID)
        glyph = try? c.decode(String.self, forKey: .glyph)
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

extension Item {
    /// Shown in Finds, Swipe and Today's Drop only once Baget has its real photo (the sample tour has none, so it always shows).
    var showable: Bool { isSample || (imageURL?.hasPrefix("https://") ?? false) }
    /// Not one product: "intel" (a droplist, release calendar, news or reference page) or "search" (a results page).
    var isIntel: Bool { tags.contains("intel") }
    var isSearchLink: Bool { tags.contains("search") }
    var isProduct: Bool { !isIntel && !isSearchLink }
    /// Sold by a store outside the US (priced in another currency, ships from abroad).
    var isIntl: Bool { origCurrency.map { $0 != "USD" } ?? false }
    /// "$212", or "≈ $212" when converted from another currency.
    var priceLabel: String { (isIntl ? "≈ " : "") + Fmt.money(price) }
    /// "€195 at the store" for stores outside the US.
    var localPriceLabel: String? {
        guard isIntl, let p = origPrice, let c = origCurrency else { return nil }
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = c; f.maximumFractionDigits = p.rounded() == p ? 0 : 2
        return "\(f.string(from: NSNumber(value: p)) ?? "\(c) \(p)") at the store"
    }
    /// Today's Drop and the swipe deck: products with a photo.
    var showsInDeals: Bool { showable && isProduct }
    /// Finds: products with a photo, and intel and searches (which may not have one).
    var showsInFinds: Bool { showable || (!isProduct && url != nil) }
}
