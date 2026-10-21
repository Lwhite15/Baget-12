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

    static let photoBase = "https://mzefxjyqiqgsblrsbrit.supabase.co/storage/v1/object/public/product-photos/"

    static let items: [Item] = {
        var list: [Item] = []
        func add(_ title: String, _ brand: String, _ cat: Category, _ sku: String, _ price: Double, _ market: Double,
                 _ source: String, _ drop: Double, soldOut: Bool = false, creator: String? = nil,
                 traits: [String], tags: [String] = [], shoes: [Double]? = nil, tops: [String]? = nil, photo: String) {
            var item = Item(id: "s\(list.count)", title: title, brand: brand, category: cat, sku: sku, price: price, market: market,
                            source: source, dropOffset: drop, soldOutAtStart: soldOut, creator: creator,
                            traits: traits, tags: tags, shoeSizes: shoes, topSizes: tops)
            item.imageURL = Catalog.photoBase + photo
            list.append(item)
        }
        // Real products Baget's scouts have found (with their photos); prices and timings are illustrative.
        // Sneakers
        add("Air Jordan 1 Retro High OG 'Red Suede'", "Jordan", .sneakers, "555088-606", 180, 260, "Nike SNKRS", -20,
            traits: ["jordan 1", "high top", "suede", "red"], tags: ["retro", "aj1"], shoes: [8, 9, 10, 10.5, 11, 12], photo: "50f893b3af5d7dfb9a2289afbe83aae1.jpg")
        add("Air Jordan 1 Mid 'Black Gum'", "Jordan", .sneakers, "FQ1925-001", 140, 175, "Nike SNKRS", 1440,
            traits: ["jordan 1", "suede", "gum sole", "black"], tags: ["aj1", "retro"], shoes: [7, 8, 9, 10, 11, 12], photo: "238c8208f70578f124bfa1290988eb41.webp")
        add("New Balance 990v6 Made in USA", "New Balance", .sneakers, "M990GL6", 200, 215, "Kith", 180,
            traits: ["990", "grey", "suede", "made in usa"], shoes: [7, 8, 9, 10, 10.5, 11, 12, 13], photo: "72cde59b33feb2b388b5a77818d5e503.webp")
        add("ASICS GEL-Kayano 14", "ASICS", .sneakers, "1201A019", 160, 190, "JD Sports", -1,
            traits: ["retro runner", "mesh", "suede", "silver"], shoes: [8, 9, 9.5, 10, 11], photo: "6ec71a47196e0a1c141cc412d315ae1b.jpg")
        add("Saucony Shadow 5000", "Saucony", .sneakers, "S70665", 110, 110, "Saucony", -1,
            traits: ["suede", "mesh", "retro", "grey"], shoes: [8, 9, 10, 10.5, 11, 12], photo: "4167759ad5890d4bff3e35b83659c78f.jpg")
        add("Nike Air Bakin High SP 'Black and Varsity Red'", "Nike", .sneakers, "HF4334-001", 170, 230, "Nike SNKRS", 4320,
            traits: ["high top", "black", "varsity red", "retro"], tags: ["limited"], shoes: [8, 9, 10, 11], photo: "836d85c210a2023a65442112dc99bd8c.jpg")
        // Clothing
        add("Supreme Small Box Logo Hooded Sweatshirt", "Supreme", .apparel, "SS22-SW", 168, 260, "Supreme webstore", 2040,
            traits: ["hoodie", "heavyweight fleece", "box logo"], tags: ["bogo"], tops: ["S", "M", "L", "XL"], photo: "50e9a2ceb531e57c9429cc8f212d2d31.jpg")
        add("Stüssy 8 Ball Zip Hoodie", "Stüssy", .apparel, "STU-8B-ZIP", 150, 190, "Stüssy", -1,
            traits: ["zip hoodie", "heavyweight fleece", "8 ball"], tops: ["M", "L", "XL"], photo: "f1abdc3e51cbc1bf10a4b317bfd896cf.webp")
        add("Fear of God ESSENTIALS Nylon High Neck Jacket", "Fear of God", .apparel, "FOG-ESS-NJ", 180, 220, "SSENSE", -1,
            traits: ["jacket", "nylon", "outerwear", "black"], tops: ["S", "M", "L"], photo: "80f3d8d075833feed08228055109a1ff.jpg")
        add("Gramicci WR Cargo Pant", "Gramicci", .apparel, "G4FU-P004", 170, 170, "END.", -1,
            traits: ["cargo", "water-repellent", "wide fit", "black"], tops: ["S", "M", "L", "XL"], photo: "b29932fae40ff656747416b850a30ef2.jpg")
        add("Fjällräven Vidda Pro Ventilated Trousers", "Fjällräven", .apparel, "F81160", 190, 190, "Fjällräven", -1,
            traits: ["g-1000", "outerwear", "trekking"], tops: ["M", "L", "XL"], photo: "cdf024c7dc0b56a6a9a0881d52790f77.webp")
        // Fragrance
        add("Frédéric Malle Portrait of a Lady, Limited Edition", "Frédéric Malle", .fragrance, "FM-POAL-LE", 470, 470, "Frédéric Malle", 300,
            creator: "Dominique Ropion", traits: ["turkish rose", "patchouli", "incense", "sandalwood"], tags: ["niche", "limited"], photo: "a85a942cda9427594c1f216a7e02ee93.webp")
        add("Maison Francis Kurkdjian Oud Satin Mood Extrait, 70ml", "Maison Francis Kurkdjian", .fragrance, "MFK-OSM-EX", 425, 495, "Jomashop", -10,
            creator: "Francis Kurkdjian", traits: ["oud", "rose", "vanilla", "violet"], tags: ["mfk"], photo: "266ebbc35345b1ad4bc15404e0672618.jpg")
        add("Parfums de Marly Herod", "Parfums de Marly", .fragrance, "PDM-HEROD-125", 290, 290, "Parfums de Marly", -15,
            traits: ["tobacco", "incense", "smoky", "warm"], photo: "8ad676935da4cfafc85cd4ce5065e897.webp")
        add("Ormonde Jayne Nawab of Oudh Intensivo", "Ormonde Jayne", .fragrance, "OJ-NOO-INT", 365, 365, "Luckyscent", -60,
            traits: ["oud", "amber", "rose", "saffron"], tags: ["niche"], photo: "733a5d3b463fd5d96b351db6d3cc5521.jpg")
        add("Amouage Outlands, 100ml", "Amouage", .fragrance, "AMG-OUT-100", 404, 404, "Twisted Lily", 2880,
            traits: ["oud", "incense", "amber", "patchouli"], tags: ["new release"], photo: "2b9d10862fbbe737fe854bddb1584fd6.jpg")
        add("Goldfield & Banks Pacific Rock Moss", "Goldfield & Banks", .fragrance, "GB-PRM", 160, 160, "Twisted Lily", -1, soldOut: true,
            traits: ["aquatic", "sea spray", "sage", "cedarwood"], photo: "b98634cf8c8d1f1d24b84ea9b23aaf6d.webp")
        // Watches
        add("Tudor Black Bay 58, 39mm", "Tudor", .watches, "M79030N", 3900, 4100, "1stDibs", -1,
            traits: ["diver", "steel", "39mm", "black dial"], tags: ["bb58"], photo: "e63deaed251d63047ffab25bc202185a.webp")
        add("Longines HydroConquest 41mm, Sunray Black", "Longines", .watches, "L3.790.4.56.6", 1600, 1600, "Longines", -1,
            traits: ["diver", "steel", "41mm", "black dial", "automatic"], photo: "8b74dae80c7ae1fff26f2d8c38c7e422.webp")
        add("Seiko 5 Sports Field SRPG37", "Seiko", .watches, "SRPG37", 315, 315, "Seiko", -1,
            traits: ["field watch", "automatic", "39mm", "black dial"], photo: "9dd22d78a18c2d26d11b4890af3d9a2f.jpg")
        add("Weiss Standard Issue Field Watch 38mm", "Weiss", .watches, "W-SI-38", 3500, 3500, "Stag Provisions", -1, soldOut: true,
            traits: ["field watch", "automatic", "38mm", "made in usa"], photo: "9f04eb4481ef2bede4fe62897b96b81e.webp")
        // Cars
        add("Porsche 911 Spirit 70", "Porsche", .cars, "992-SPIRIT70", 254300, 300000, "Porsche USA", 2700,
            traits: ["coupe", "limited edition", "heritage design"], tags: ["911"], photo: "4d600a3872ca076b69607038a9c695b8.webp")
        add("2011 BMW 1M Coupe, 6-speed manual", "BMW M", .cars, "LOT E82-1M", 64993, 70000, "Classic.com", -1,
            traits: ["manual", "coupe", "inline-six", "2010s"], tags: ["1m"], photo: "72dc4757c937caad7c41c6ccb1b71349.webp")
        add("1996 Dodge Viper GTS", "Dodge", .cars, "LOT VIPER-GTS", 94800, 98000, "Vegas Auto Gallery", 1300,
            traits: ["manual", "coupe", "v10", "90s"], photo: "bae61893bc1fcac3cf3485f2965ebc04.jpg")
        add("1990 Mazda Miata, 30k-mile survivor", "Mazda", .cars, "LOT NA-MIATA", 14000, 16500, "Barn Finds", -1,
            traits: ["manual", "convertible", "90s", "all original"], photo: "a59c3f33803c1348955773bf57cfe695.jpg")
        // Furniture
        add("Eames Lounge Chair and Ottoman, Walnut", "Herman Miller", .furniture, "ES670-671", 4100, 7495, "eBay", -1, creator: "Charles and Ray Eames",
            traits: ["mid-century", "walnut", "leather"], tags: ["eames lounge"], photo: "7c75b0be178a5314d3d26340c37371a9.webp")
        add("Eames Molded Plywood Lounge Chair, Walnut", "Herman Miller", .furniture, "LCW-WAL", 2285, 2285, "Design Warehouse", -1, creator: "Charles and Ray Eames",
            traits: ["mid-century", "walnut", "molded plywood"], photo: "46a2070b4459d0f6eb98b941b5a15ba7.jpg")
        add("Paul McCobb Planner Group Credenza with Hutch", "Planner Group", .furniture, "PM-PG-CH", 3400, 3900, "Mid Century Møbler", 900, creator: "Paul McCobb",
            traits: ["mid-century", "walnut", "1950s"], tags: ["vintage"], photo: "5ade99c8c95f73ebffec689abee403ae.jpg")
        add("Jens Risom Walnut Lounge Chairs, Pair", "Jens Risom", .furniture, "JR-LC-PR", 2795, 3200, "Midcentury Warehouse", -1, creator: "Jens Risom",
            traits: ["mid-century", "walnut", "vintage"], tags: ["vintage"], photo: "1bf77681478708fa4859cea817633097.jpg")
        // Accessories
        add("Bottega Veneta Small Leather Pouch Crossbody", "Bottega Veneta", .accessories, "BV-POUCH-S", 1850, 1850, "Bergdorf Goodman", -1,
            traits: ["leather", "intrecciato", "crossbody"], photo: "6185bd2b37daec095af02b796c791868.jpg")
        add("Lemaire Mini Soft Gear Bag, Black", "Lemaire", .accessories, "LEM-SG-MINI", 1680, 1680, "SSENSE", -1,
            traits: ["lambskin", "crossbody", "black"], photo: "8273bec68b158f981d25bed90aee73c2.webp")
        add("Hender Scheme Shoulder Bag, Black", "Hender Scheme", .accessories, "HS-SB-BLK", 235, 235, "HAVEN", -1,
            traits: ["leather", "made in japan", "black"], photo: "2040cb90896178b11498e4561d6337ee.webp")
        add("Bottega Veneta Aviator Sunglasses", "Bottega Veneta", .accessories, "BV1196S", 775, 775, "Net-a-Porter", -1,
            traits: ["acetate", "aviator", "made in italy"], photo: "9d7cbdfa0f3c6b2b88a57cb2997fbee0.webp")
        // Collectibles
        add("Takashi Murakami Kaikai & Kiki Set, Signed Edition of 100", "Takashi Murakami", .collectibles, "TM-KK-2026", 10000, 12000, "Artsy", -1,
            traits: ["signed", "limited edition", "pvc figure"], tags: ["art toy"], photo: "0c4925c4a6621428a08dfbd2b4a0cb69.jpg")
        add("KAWS Holiday Space Figure, Black", "KAWS", .collectibles, "KAWS-HS-BLK", 1500, 1700, "eBay", -1, creator: "KAWS",
            traits: ["vinyl figure", "deadstock"], tags: ["art toy"], photo: "053a2e568078fd4567299979ba52d292.jpg")
        add("Topps × KAWS MLB Hobby Box, Sealed", "Topps", .collectibles, "TOPPS-KAWS-26", 720, 900, "eBay", 1800, creator: "KAWS",
            traits: ["sealed", "trading cards", "limited print run"], tags: ["trading cards", "limited"], photo: "90c094e38e2f74150ce956b37cb1022c.jpg")
        add("BE@RBRICK Coca-Cola Georgia Green 100% & 400%", "Medicom Toy", .collectibles, "BB-COKE-GG", 94, 120, "BAIT", -1,
            traits: ["bearbrick", "vinyl", "collab"], tags: ["art toy"], photo: "7727da4309f051f264ea4d3b474d6aad.webp")
        return list
    }()

}
