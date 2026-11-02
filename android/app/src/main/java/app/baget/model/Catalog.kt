package app.baget.model

/**
 * Listings the app knows about.
 *  * Signed out: a sample catalog with real product names and illustrative prices and timings.
 *  * Signed in: real listings the squad found on the web, synced from the server.
 */
object Catalog {
    /** Real listings from the server, by id. Empty when signed out. */
    var cloud: MutableMap<String, Item> = mutableMapOf()
    var useCloud = false

    /** Everything the current mode can show. */
    val all: List<Item>
        get() = if (useCloud) cloud.values.sortedByDescending { it.firstSeen ?: Long.MIN_VALUE } else items

    fun item(id: String?): Item? {
        if (id == null) return null
        return cloud[id] ?: sampleByID[id]
    }

    const val PHOTO_BASE = "https://mzefxjyqiqgsblrsbrit.supabase.co/storage/v1/object/public/product-photos/"

    val items: List<Item> by lazy { buildSamples() }
    private val sampleByID: Map<String, Item> by lazy { items.associateBy { it.id } }

    private fun buildSamples(): List<Item> {
        val list = mutableListOf<Item>()
        fun add(title: String, brand: String, cat: Category, sku: String, price: Double, market: Double, source: String, drop: Double,
                soldOut: Boolean = false, creator: String? = null, traits: List<String>, tags: List<String> = emptyList(),
                shoes: List<Double>? = null, tops: List<String>? = null, photo: String) {
            list.add(Item(id = "s${list.size}", title = title, brand = brand, category = cat, sku = sku, price = price, market = market,
                source = source, dropOffset = drop, soldOutAtStart = soldOut, creator = creator, traits = traits, tags = tags,
                shoeSizes = shoes, topSizes = tops, imageURL = PHOTO_BASE + photo))
        }
        val S = Category.SNEAKERS; val A = Category.APPAREL; val F = Category.FRAGRANCE; val W = Category.WATCHES
        val C = Category.CARS; val U = Category.FURNITURE; val X = Category.ACCESSORIES; val K = Category.COLLECTIBLES
        // Real products Baget's scouts have found (with their photos); prices and timings are illustrative.
        // Sneakers
        add("Air Jordan 1 Retro High OG 'Red Suede'", "Jordan", S, "555088-606", 180.0, 260.0, "Nike SNKRS", -20.0,
            traits = listOf("jordan 1", "high top", "suede", "red"), tags = listOf("retro", "aj1"), shoes = listOf(8.0, 9.0, 10.0, 10.5, 11.0, 12.0), photo = "50f893b3af5d7dfb9a2289afbe83aae1.jpg")
        add("Air Jordan 1 Mid 'Black Gum'", "Jordan", S, "FQ1925-001", 140.0, 175.0, "Nike SNKRS", 1440.0,
            traits = listOf("jordan 1", "suede", "gum sole", "black"), tags = listOf("aj1", "retro"), shoes = listOf(7.0, 8.0, 9.0, 10.0, 11.0, 12.0), photo = "238c8208f70578f124bfa1290988eb41.webp")
        add("New Balance 990v6 Made in USA", "New Balance", S, "M990GL6", 200.0, 215.0, "Kith", 180.0,
            traits = listOf("990", "grey", "suede", "made in usa"), shoes = listOf(7.0, 8.0, 9.0, 10.0, 10.5, 11.0, 12.0, 13.0), photo = "72cde59b33feb2b388b5a77818d5e503.webp")
        add("ASICS GEL-Kayano 14", "ASICS", S, "1201A019", 160.0, 190.0, "JD Sports", -1.0,
            traits = listOf("retro runner", "mesh", "suede", "silver"), shoes = listOf(8.0, 9.0, 9.5, 10.0, 11.0), photo = "6ec71a47196e0a1c141cc412d315ae1b.jpg")
        add("Saucony Shadow 5000", "Saucony", S, "S70665", 110.0, 110.0, "Saucony", -1.0,
            traits = listOf("suede", "mesh", "retro", "grey"), shoes = listOf(8.0, 9.0, 10.0, 10.5, 11.0, 12.0), photo = "4167759ad5890d4bff3e35b83659c78f.jpg")
        add("Nike Air Bakin High SP 'Black and Varsity Red'", "Nike", S, "HF4334-001", 170.0, 230.0, "Nike SNKRS", 4320.0,
            traits = listOf("high top", "black", "varsity red", "retro"), tags = listOf("limited"), shoes = listOf(8.0, 9.0, 10.0, 11.0), photo = "836d85c210a2023a65442112dc99bd8c.jpg")
        // Clothing
        add("Supreme Small Box Logo Hooded Sweatshirt", "Supreme", A, "SS22-SW", 168.0, 260.0, "Supreme webstore", 2040.0,
            traits = listOf("hoodie", "heavyweight fleece", "box logo"), tags = listOf("bogo"), tops = listOf("S", "M", "L", "XL"), photo = "50e9a2ceb531e57c9429cc8f212d2d31.jpg")
        add("Stüssy 8 Ball Zip Hoodie", "Stüssy", A, "STU-8B-ZIP", 150.0, 190.0, "Stüssy", -1.0,
            traits = listOf("zip hoodie", "heavyweight fleece", "8 ball"), tops = listOf("M", "L", "XL"), photo = "f1abdc3e51cbc1bf10a4b317bfd896cf.webp")
        add("Fear of God ESSENTIALS Nylon High Neck Jacket", "Fear of God", A, "FOG-ESS-NJ", 180.0, 220.0, "SSENSE", -1.0,
            traits = listOf("jacket", "nylon", "outerwear", "black"), tops = listOf("S", "M", "L"), photo = "80f3d8d075833feed08228055109a1ff.jpg")
        add("Gramicci WR Cargo Pant", "Gramicci", A, "G4FU-P004", 170.0, 170.0, "END.", -1.0,
            traits = listOf("cargo", "water-repellent", "wide fit", "black"), tops = listOf("S", "M", "L", "XL"), photo = "b29932fae40ff656747416b850a30ef2.jpg")
        add("Fjällräven Vidda Pro Ventilated Trousers", "Fjällräven", A, "F81160", 190.0, 190.0, "Fjällräven", -1.0,
            traits = listOf("g-1000", "outerwear", "trekking"), tops = listOf("M", "L", "XL"), photo = "cdf024c7dc0b56a6a9a0881d52790f77.webp")
        // Fragrance
        add("Frédéric Malle Portrait of a Lady, Limited Edition", "Frédéric Malle", F, "FM-POAL-LE", 470.0, 470.0, "Frédéric Malle", 300.0,
            creator = "Dominique Ropion", traits = listOf("turkish rose", "patchouli", "incense", "sandalwood"), tags = listOf("niche", "limited"), photo = "a85a942cda9427594c1f216a7e02ee93.webp")
        add("Maison Francis Kurkdjian Oud Satin Mood Extrait, 70ml", "Maison Francis Kurkdjian", F, "MFK-OSM-EX", 425.0, 495.0, "Jomashop", -10.0,
            creator = "Francis Kurkdjian", traits = listOf("oud", "rose", "vanilla", "violet"), tags = listOf("mfk"), photo = "266ebbc35345b1ad4bc15404e0672618.jpg")
        add("Parfums de Marly Herod", "Parfums de Marly", F, "PDM-HEROD-125", 290.0, 290.0, "Parfums de Marly", -15.0,
            traits = listOf("tobacco", "incense", "smoky", "warm"), photo = "8ad676935da4cfafc85cd4ce5065e897.webp")
        add("Ormonde Jayne Nawab of Oudh Intensivo", "Ormonde Jayne", F, "OJ-NOO-INT", 365.0, 365.0, "Luckyscent", -60.0,
            traits = listOf("oud", "amber", "rose", "saffron"), tags = listOf("niche"), photo = "733a5d3b463fd5d96b351db6d3cc5521.jpg")
        add("Amouage Outlands, 100ml", "Amouage", F, "AMG-OUT-100", 404.0, 404.0, "Twisted Lily", 2880.0,
            traits = listOf("oud", "incense", "amber", "patchouli"), tags = listOf("new release"), photo = "2b9d10862fbbe737fe854bddb1584fd6.jpg")
        add("Goldfield & Banks Pacific Rock Moss", "Goldfield & Banks", F, "GB-PRM", 160.0, 160.0, "Twisted Lily", -1.0, soldOut = true,
            traits = listOf("aquatic", "sea spray", "sage", "cedarwood"), photo = "b98634cf8c8d1f1d24b84ea9b23aaf6d.webp")
        // Watches
        add("Tudor Black Bay 58, 39mm", "Tudor", W, "M79030N", 3900.0, 4100.0, "1stDibs", -1.0,
            traits = listOf("diver", "steel", "39mm", "black dial"), tags = listOf("bb58"), photo = "e63deaed251d63047ffab25bc202185a.webp")
        add("Longines HydroConquest 41mm, Sunray Black", "Longines", W, "L3.790.4.56.6", 1600.0, 1600.0, "Longines", -1.0,
            traits = listOf("diver", "steel", "41mm", "black dial", "automatic"), photo = "8b74dae80c7ae1fff26f2d8c38c7e422.webp")
        add("Seiko 5 Sports Field SRPG37", "Seiko", W, "SRPG37", 315.0, 315.0, "Seiko", -1.0,
            traits = listOf("field watch", "automatic", "39mm", "black dial"), photo = "9dd22d78a18c2d26d11b4890af3d9a2f.jpg")
        add("Weiss Standard Issue Field Watch 38mm", "Weiss", W, "W-SI-38", 3500.0, 3500.0, "Stag Provisions", -1.0, soldOut = true,
            traits = listOf("field watch", "automatic", "38mm", "made in usa"), photo = "9f04eb4481ef2bede4fe62897b96b81e.webp")
        // Cars
        add("Porsche 911 Spirit 70", "Porsche", C, "992-SPIRIT70", 254300.0, 300000.0, "Porsche USA", 2700.0,
            traits = listOf("coupe", "limited edition", "heritage design"), tags = listOf("911"), photo = "4d600a3872ca076b69607038a9c695b8.webp")
        add("2011 BMW 1M Coupe, 6-speed manual", "BMW M", C, "LOT E82-1M", 64993.0, 70000.0, "Classic.com", -1.0,
            traits = listOf("manual", "coupe", "inline-six", "2010s"), tags = listOf("1m"), photo = "72dc4757c937caad7c41c6ccb1b71349.webp")
        add("1996 Dodge Viper GTS", "Dodge", C, "LOT VIPER-GTS", 94800.0, 98000.0, "Vegas Auto Gallery", 1300.0,
            traits = listOf("manual", "coupe", "v10", "90s"), photo = "bae61893bc1fcac3cf3485f2965ebc04.jpg")
        add("1990 Mazda Miata, 30k-mile survivor", "Mazda", C, "LOT NA-MIATA", 14000.0, 16500.0, "Barn Finds", -1.0,
            traits = listOf("manual", "convertible", "90s", "all original"), photo = "a59c3f33803c1348955773bf57cfe695.jpg")
        // Furniture
        add("Eames Lounge Chair and Ottoman, Walnut", "Herman Miller", U, "ES670-671", 4100.0, 7495.0, "eBay", -1.0, creator = "Charles and Ray Eames",
            traits = listOf("mid-century", "walnut", "leather"), tags = listOf("eames lounge"), photo = "7c75b0be178a5314d3d26340c37371a9.webp")
        add("Eames Molded Plywood Lounge Chair, Walnut", "Herman Miller", U, "LCW-WAL", 2285.0, 2285.0, "Design Warehouse", -1.0, creator = "Charles and Ray Eames",
            traits = listOf("mid-century", "walnut", "molded plywood"), photo = "46a2070b4459d0f6eb98b941b5a15ba7.jpg")
        add("Paul McCobb Planner Group Credenza with Hutch", "Planner Group", U, "PM-PG-CH", 3400.0, 3900.0, "Mid Century Møbler", 900.0, creator = "Paul McCobb",
            traits = listOf("mid-century", "walnut", "1950s"), tags = listOf("vintage"), photo = "5ade99c8c95f73ebffec689abee403ae.jpg")
        add("Jens Risom Walnut Lounge Chairs, Pair", "Jens Risom", U, "JR-LC-PR", 2795.0, 3200.0, "Midcentury Warehouse", -1.0, creator = "Jens Risom",
            traits = listOf("mid-century", "walnut", "vintage"), tags = listOf("vintage"), photo = "1bf77681478708fa4859cea817633097.jpg")
        // Accessories
        add("Bottega Veneta Small Leather Pouch Crossbody", "Bottega Veneta", X, "BV-POUCH-S", 1850.0, 1850.0, "Bergdorf Goodman", -1.0,
            traits = listOf("leather", "intrecciato", "crossbody"), photo = "6185bd2b37daec095af02b796c791868.jpg")
        add("Lemaire Mini Soft Gear Bag, Black", "Lemaire", X, "LEM-SG-MINI", 1680.0, 1680.0, "SSENSE", -1.0,
            traits = listOf("lambskin", "crossbody", "black"), photo = "8273bec68b158f981d25bed90aee73c2.webp")
        add("Hender Scheme Shoulder Bag, Black", "Hender Scheme", X, "HS-SB-BLK", 235.0, 235.0, "HAVEN", -1.0,
            traits = listOf("leather", "made in japan", "black"), photo = "2040cb90896178b11498e4561d6337ee.webp")
        add("Bottega Veneta Aviator Sunglasses", "Bottega Veneta", X, "BV1196S", 775.0, 775.0, "Net-a-Porter", -1.0,
            traits = listOf("acetate", "aviator", "made in italy"), photo = "9d7cbdfa0f3c6b2b88a57cb2997fbee0.webp")
        // Collectibles
        add("Takashi Murakami Kaikai & Kiki Set, Signed Edition of 100", "Takashi Murakami", K, "TM-KK-2026", 10000.0, 12000.0, "Artsy", -1.0,
            traits = listOf("signed", "limited edition", "pvc figure"), tags = listOf("art toy"), photo = "0c4925c4a6621428a08dfbd2b4a0cb69.jpg")
        add("KAWS Holiday Space Figure, Black", "KAWS", K, "KAWS-HS-BLK", 1500.0, 1700.0, "eBay", -1.0, creator = "KAWS",
            traits = listOf("vinyl figure", "deadstock"), tags = listOf("art toy"), photo = "053a2e568078fd4567299979ba52d292.jpg")
        add("Topps × KAWS MLB Hobby Box, Sealed", "Topps", K, "TOPPS-KAWS-26", 720.0, 900.0, "eBay", 1800.0, creator = "KAWS",
            traits = listOf("sealed", "trading cards", "limited print run"), tags = listOf("trading cards", "limited"), photo = "90c094e38e2f74150ce956b37cb1022c.jpg")
        add("BE@RBRICK Coca-Cola Georgia Green 100% & 400%", "Medicom Toy", K, "BB-COKE-GG", 94.0, 120.0, "BAIT", -1.0,
            traits = listOf("bearbrick", "vinyl", "collab"), tags = listOf("art toy"), photo = "7727da4309f051f264ea4d3b474d6aad.webp")
        return list
    }
}

/** Plain-language taste choices for setup, so nobody needs to know brand names to get good picks. */
object Vibes {
    /** Sizes to tap in setup, for the categories whose scouts only flag what's in stock in your size. */
    fun sizes(c: Category, women: Boolean = false): List<String>? {
        fun half(a: Double, b: Double): List<String> {
            val out = mutableListOf<String>()
            var x = a
            while (x <= b + 1e-9) { out.add(if (x == Math.rint(x)) x.toInt().toString() else x.toString()); x += 0.5 }
            return out
        }
        return when (c) {
            Category.SNEAKERS -> if (women) half(5.0, 12.0) else half(6.0, 14.0) + "15"
            Category.APPAREL -> listOf("XS", "S", "M", "L", "XL", "XXL")
            else -> null
        }
    }

    /**
     * How a tapped size is saved on the scout. Women's shoes say "US W 8" (read as US men's 6.5 when checking stock);
     * women's clothing keeps the letter size and says womenswear, so the scout hunts the right department.
     */
    fun sizeValue(c: Category, size: String, women: Boolean): String {
        if (!women) return size
        return if (c == Category.SNEAKERS) "US W $size" else "$size (womenswear)"
    }
    fun question(c: Category): String = when (c) {
        Category.FRAGRANCE -> "What do you like to smell like?"
        Category.SNEAKERS -> "What kind of sneakers?"
        Category.APPAREL -> "What's your style?"
        Category.WATCHES -> "What kind of watch?"
        Category.CARS -> "What kind of car?"
        Category.FURNITURE -> "What's your home like?"
        Category.ACCESSORIES -> "What kind of accessories?"
        Category.COLLECTIBLES -> "What do you collect?"
        Category.OTHER -> "What are you into?"
    }

    fun options(c: Category): List<String> = when (c) {
        Category.FRAGRANCE -> listOf("Fresh & clean", "Citrus & bright", "Sweet & cozy", "Vanilla", "Woody & warm", "Spicy", "Floral",
            "Smoky & leather", "Beachy & salty", "Earthy & green", "Every day", "Office", "Date night", "Summer", "Gift")
        Category.SNEAKERS -> listOf("Everyday & comfy", "Classic & clean", "Bold colors", "Running & retro", "Basketball", "Skate",
            "Rare & hyped", "Under the radar")
        Category.APPAREL -> listOf("Streetwear", "Minimal & clean", "Vintage", "Outdoor & workwear", "Smart casual", "Athletic",
            "Bold & loud", "Cozy basics")
        Category.WATCHES -> listOf("Everyday", "Dressy", "Sporty & tough", "Dive", "Vintage", "Small & slim", "Big & bold", "Smart features")
        Category.CARS -> listOf("Daily driver", "Sporty", "Luxury", "Classic", "Off-road", "Family & roomy", "Electric", "Good on gas")
        Category.FURNITURE -> listOf("Cozy", "Modern & minimal", "Mid-century", "Vintage", "Natural wood", "Bold & colorful", "Small spaces")
        Category.ACCESSORIES -> listOf("Bags", "Hats", "Jewelry", "Sunglasses", "Wallets", "Everyday", "Statement pieces", "Minimal")
        Category.COLLECTIBLES -> listOf("Trading cards", "Toys & figures", "Art & prints", "Vinyl & music", "Sports", "Vintage", "Limited drops")
        Category.OTHER -> emptyList()
    }

    fun brands(c: Category): List<String> = when (c) {
        Category.FRAGRANCE -> listOf("Dior", "Chanel", "Tom Ford", "Le Labo", "Byredo", "Maison Margiela", "Creed", "YSL", "Versace", "Jo Malone",
            "Parfums de Marly", "Diptyque")
        Category.SNEAKERS -> listOf("Nike", "Jordan", "Adidas", "New Balance", "Asics", "Salomon", "Converse", "Vans", "Puma", "On", "Hoka")
        Category.APPAREL -> listOf("Supreme", "Stüssy", "Carhartt WIP", "Fear of God", "Aimé Leon Dore", "Kith", "Palace", "Ralph Lauren",
            "Arc'teryx", "Patagonia", "Uniqlo", "Bape")
        Category.WATCHES -> listOf("Rolex", "Omega", "Seiko", "Tudor", "Cartier", "Casio G-Shock", "Tissot", "Hamilton", "Grand Seiko", "Apple")
        Category.CARS -> listOf("Toyota", "Honda", "BMW", "Mercedes-Benz", "Porsche", "Tesla", "Ford", "Lexus", "Audi", "Jeep")
        Category.FURNITURE -> listOf("Herman Miller", "Article", "West Elm", "CB2", "Restoration Hardware", "IKEA", "Knoll", "Vitra")
        Category.ACCESSORIES -> listOf("Louis Vuitton", "Gucci", "Goyard", "Chrome Hearts", "Ray-Ban", "New Era", "Telfar", "Coach", "Tiffany & Co.")
        Category.COLLECTIBLES -> listOf("Pokémon", "Funko", "LEGO", "KAWS", "Bearbrick", "Hot Wheels", "Topps", "Panini")
        Category.OTHER -> emptyList()
    }

    /** The most someone usually spends on one item. 0 means no limit. */
    val budgets: List<Pair<String, Int>> = listOf(
        "Under $50" to 50, "Up to $100" to 100, "Up to $250" to 250, "Up to $500" to 500, "Up to $1,000" to 1000, "No limit" to 0,
    )
}
