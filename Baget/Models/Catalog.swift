import Foundation

/// Listings the app knows about.
/// * Signed out: a sample catalog with real product names and illustrative prices and timings.
/// * Signed in: real listings the squad found on the web, synced from the server.
@MainActor
enum Catalog {
    /// Real listings from the server, by id. Empty when signed out.
    static var cloud: [String: Item] = [:]
    static var useCloud = false

    /// Everything the current mode can show.
    static var all: [Item] {
        useCloud ? cloud.values.sorted { ($0.firstSeen ?? .distantPast) > ($1.firstSeen ?? .distantPast) } : items
    }

    static func item(_ id: String) -> Item? {
        if let c = cloud[id] { return c }
        return sampleByID[id]
    }

    private static let sampleByID: [String: Item] = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

    static let items: [Item] = {
        var list: [Item] = []
        func add(_ title: String, _ brand: String, _ cat: Category, _ sku: String, _ price: Double, _ market: Double,
                 _ source: String, _ drop: Double, soldOut: Bool = false, creator: String? = nil,
                 traits: [String], tags: [String] = [], shoes: [Double]? = nil, tops: [String]? = nil) {
            list.append(Item(id: "s\(list.count)", title: title, brand: brand, category: cat, sku: sku, price: price, market: market,
                             source: source, dropOffset: drop, soldOutAtStart: soldOut, creator: creator,
                             traits: traits, tags: tags, shoeSizes: shoes, topSizes: tops))
        }
        // Sneakers
        add("Air Jordan 4 Retro OG", "Jordan", .sneakers, "FV5029-006", 215, 340, "Nike SNKRS", 95,
            traits: ["jordan 4", "black/red", "leather"], tags: ["retro", "aj4"], shoes: [8, 8.5, 9, 9.5, 11, 12])
        add("Air Jordan 1 Retro High OG", "Jordan", .sneakers, "DZ5485-610", 185, 265, "Nike SNKRS", -20,
            traits: ["jordan 1", "high top", "leather"], tags: ["retro", "aj1"], shoes: [9, 10, 10.5, 11, 12])
        add("Air Jordan 11 Retro Low", "Jordan", .sneakers, "FV5104-101", 190, 230, "END. Launches", 1440,
            traits: ["jordan 11", "patent leather", "low top"], tags: ["retro"], shoes: [7, 8, 10.5, 11, 13])
        add("Travis Scott × Jordan 1 Low OG", "Jordan", .sneakers, "DM7866-140", 150, 610, "Nike SNKRS", 4320, creator: "Travis Scott",
            traits: ["jordan 1", "low top", "suede", "reverse swoosh"], tags: ["aj1", "collab"], shoes: [8, 9, 10.5, 11.5])
        add("New Balance 990v6 Made in USA", "New Balance", .sneakers, "U990GR6", 200, 215, "Kith", 180,
            traits: ["990", "grey", "suede", "made in usa"], shoes: [7, 8, 9, 10, 10.5, 11, 12, 13])
        add("Aimé Leon Dore × New Balance 860v2", "New Balance", .sneakers, "ML860AL2", 160, 290, "Size?", 720, creator: "Aimé Leon Dore",
            traits: ["860", "suede", "mesh"], tags: ["collab"], shoes: [9, 9.5, 10, 11])
        add("Comme des Garçons PLAY × Converse Chuck 70", "Converse", .sneakers, "A08793C", 150, 150, "Dover Street Market", -1, creator: "Comme des Garçons",
            traits: ["chuck 70", "canvas", "high top"], tags: ["collab"], shoes: [6, 7, 8, 9, 10, 10.5, 11, 12])
        // Clothing
        add("Supreme Box Logo Hooded Sweatshirt FW26", "Supreme", .apparel, "FW26-SW1", 178, 420, "Supreme webstore", 2040,
            traits: ["hoodie", "heavyweight fleece", "box logo"], tags: ["bogo"], tops: ["S", "M", "L", "XL"])
        add("Supreme × The North Face Mountain Jacket", "Supreme", .apparel, "FW26-J7", 448, 690, "Supreme webstore", 2040, creator: "The North Face",
            traits: ["jacket", "gore-tex", "outerwear"], tags: ["collab", "tnf"], tops: ["S", "M", "XL"])
        add("Stüssy 8 Ball Fleece Jacket", "Stüssy", .apparel, "STU-8B-FL", 220, 300, "END. Launches", 2900,
            traits: ["jacket", "sherpa fleece", "outerwear"], tops: ["M", "L", "XL"])
        add("Palace Tri-Ferg Crew", "Palace", .apparel, "P26-TF-CR", 138, 170, "Palace", 1500,
            traits: ["crewneck", "fleece"], tags: ["tri-ferg"], tops: ["S", "M", "L"])
        add("Kith Classic Logo Hoodie", "Kith", .apparel, "KH-CL-26", 165, 190, "Kith", 60,
            traits: ["hoodie", "fleece", "box logo"], tops: ["XS", "S", "M"])
        // Fragrance
        add("Frédéric Malle The Night, 100ml", "Frédéric Malle", .fragrance, "FM-NIGHT-100", 1650, 1900, "Les Senteurs", -1, soldOut: true,
            creator: "Dominique Ropion", traits: ["saffron", "turkish rose", "frankincense", "sandalwood", "oud"], tags: ["niche"])
        add("Frédéric Malle Portrait of a Lady, 50ml", "Frédéric Malle", .fragrance, "FM-POAL-50", 395, 395, "Frédéric Malle boutique", -30,
            creator: "Dominique Ropion", traits: ["turkish rose", "patchouli", "incense", "sandalwood", "cinnamon"], tags: ["niche"])
        add("Maison Francis Kurkdjian Oud Satin Mood, 70ml", "Maison Francis Kurkdjian", .fragrance, "MFK-OSM-70", 375, 375, "Neiman Marcus", -10,
            creator: "Francis Kurkdjian", traits: ["rose", "oud", "vanilla", "benzoin", "violet"], tags: ["mfk"])
        add("Armani Privé Rose d'Arabie, 100ml", "Armani Privé", .fragrance, "AP-RDA-100", 340, 340, "Saks", -15,
            traits: ["rose", "oud", "incense", "amber"])
        add("Serge Lutens Sa Majesté la Rose, 50ml", "Serge Lutens", .fragrance, "SL-SMLR-50", 160, 160, "Serge Lutens", -60,
            traits: ["rose", "musk", "clove"])
        add("Maison Yusif The Beast", "Maison Yusif", .fragrance, "MY-BEAST", 290, 290, "Maison Yusif", 2880,
            traits: ["oud", "spices", "aromatics"], tags: ["new release"])
        add("Harrods Salon de Parfums Exclusive Extrait, 50ml", "Harrods", .fragrance, "HRD-SDP-50", 395, 395, "Harrods", 300,
            traits: ["leather", "iris", "musk"], tags: ["harrods exclusive", "niche"])
        // Watches
        add("Audemars Piguet Royal Oak 15510ST", "Audemars Piguet", .watches, "15510ST.OO.1320ST", 42500, 45000, "Chrono24", -1, creator: "Gérald Genta",
            traits: ["integrated bracelet", "steel", "41mm", "blue dial"], tags: ["royal oak"])
        add("Tudor Black Bay 58, 39mm", "Tudor", .watches, "M79030N", 4100, 3900, "Tudor boutique", -1,
            traits: ["diver", "steel", "39mm"], tags: ["bb58"])
        add("Cartier Santos de Cartier, Medium", "Cartier", .watches, "WSSA0029", 7350, 6900, "Cartier", 600,
            traits: ["integrated bracelet", "steel", "square case"], tags: ["santos"])
        // Cars
        add("1995 Porsche 911 Carrera (993) Coupe, 6-speed", "Porsche", .cars, "LOT 993-C2", 128000, 135000, "Bring a Trailer", 2700,
            traits: ["air-cooled", "manual", "coupe", "90s"], tags: ["911", "993"])
        add("2004 BMW M3 (E46) Coupe, 6-speed manual", "BMW M", .cars, "LOT E46-M3", 38500, 42000, "Cars & Bids", 1300,
            traits: ["manual", "coupe", "inline-six", "2000s"], tags: ["m3", "e46"])
        add("1990 Mercedes-Benz 190E 2.5-16 Evolution II", "Mercedes-Benz", .cars, "LOT W201-EVO2", 215000, 230000, "RM Sotheby's", 5000,
            traits: ["manual", "sedan", "homologation", "90s"], tags: ["evo ii", "190e"])
        // Furniture
        add("Pierre Jeanneret Office Cane Chair, Chandigarh", "Chandigarh", .furniture, "PJ-SI-28", 9500, 11000, "1stDibs", -1, creator: "Pierre Jeanneret",
            traits: ["mid-century", "teak", "cane"], tags: ["vintage"])
        add("Eames Lounge Chair and Ottoman", "Herman Miller", .furniture, "ES670-671", 7495, 7495, "Design Within Reach", -1, creator: "Charles and Ray Eames",
            traits: ["mid-century", "walnut", "leather"], tags: ["eames lounge"])
        add("Mario Bellini Camaleonda Sofa, 3 modules", "B&B Italia", .furniture, "CAM-3M", 18000, 21000, "1stDibs", 900, creator: "Mario Bellini",
            traits: ["modular", "bouclé", "1970s"], tags: ["vintage"])
        // Accessories
        add("Chrome Hearts Cemetery Cross Ring", "Chrome Hearts", .accessories, "CH-CCR", 895, 1100, "GOAT", -1,
            traits: ["sterling silver", "cross", "ring"], tags: ["jewelry"])
        add("Supreme Leather Camp Cap", "Supreme", .accessories, "FW26-H3", 68, 120, "Supreme webstore", 2040,
            traits: ["leather", "cap"])
        // Collectibles
        add("1999 Pokémon Base Set Charizard Holo, PSA 8", "Pokémon", .collectibles, "PSA 8 #4/102", 5200, 5600, "eBay", 1800,
            traits: ["base set", "holo", "psa 8", "1999"], tags: ["trading cards", "charizard"])
        add("KAWS Companion Open Edition, Grey", "Medicom", .collectibles, "KAWS-COMP-OE", 450, 520, "StockX", -1, creator: "KAWS",
            traits: ["vinyl figure", "open edition"], tags: ["art toy"])
        add("Daft Punk Discovery, 2001 first press 2xLP", "Virgin", .collectibles, "V2940", 180, 180, "Discogs", -1, creator: "Daft Punk",
            traits: ["vinyl", "first press", "2xlp"], tags: ["records", "vinyl records"])
        return list
    }()

}
