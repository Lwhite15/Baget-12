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

    val items: List<Item> by lazy { buildSamples() }
    private val sampleByID: Map<String, Item> by lazy { items.associateBy { it.id } }

    private fun buildSamples(): List<Item> {
        val list = mutableListOf<Item>()
        fun add(title: String, brand: String, cat: Category, sku: String, price: Double, market: Double, source: String, drop: Double,
                soldOut: Boolean = false, creator: String? = null, traits: List<String>, tags: List<String> = emptyList(),
                shoes: List<Double>? = null, tops: List<String>? = null) {
            list.add(Item(id = "s${list.size}", title = title, brand = brand, category = cat, sku = sku, price = price, market = market,
                source = source, dropOffset = drop, soldOutAtStart = soldOut, creator = creator, traits = traits, tags = tags,
                shoeSizes = shoes, topSizes = tops))
        }
        val S = Category.SNEAKERS; val A = Category.APPAREL; val F = Category.FRAGRANCE; val W = Category.WATCHES
        val C = Category.CARS; val U = Category.FURNITURE; val X = Category.ACCESSORIES; val K = Category.COLLECTIBLES
        // Sneakers
        add("Air Jordan 4 Retro OG", "Jordan", S, "FV5029-006", 215.0, 340.0, "Nike SNKRS", 95.0,
            traits = listOf("jordan 4", "black/red", "leather"), tags = listOf("retro", "aj4"), shoes = listOf(8.0, 8.5, 9.0, 9.5, 11.0, 12.0))
        add("Air Jordan 1 Retro High OG", "Jordan", S, "DZ5485-610", 185.0, 265.0, "Nike SNKRS", -20.0,
            traits = listOf("jordan 1", "high top", "leather"), tags = listOf("retro", "aj1"), shoes = listOf(9.0, 10.0, 10.5, 11.0, 12.0))
        add("Air Jordan 11 Retro Low", "Jordan", S, "FV5104-101", 190.0, 230.0, "END. Launches", 1440.0,
            traits = listOf("jordan 11", "patent leather", "low top"), tags = listOf("retro"), shoes = listOf(7.0, 8.0, 10.5, 11.0, 13.0))
        add("Travis Scott × Jordan 1 Low OG", "Jordan", S, "DM7866-140", 150.0, 610.0, "Nike SNKRS", 4320.0, creator = "Travis Scott",
            traits = listOf("jordan 1", "low top", "suede", "reverse swoosh"), tags = listOf("aj1", "collab"), shoes = listOf(8.0, 9.0, 10.5, 11.5))
        add("New Balance 990v6 Made in USA", "New Balance", S, "U990GR6", 200.0, 215.0, "Kith", 180.0,
            traits = listOf("990", "grey", "suede", "made in usa"), shoes = listOf(7.0, 8.0, 9.0, 10.0, 10.5, 11.0, 12.0, 13.0))
        add("Aimé Leon Dore × New Balance 860v2", "New Balance", S, "ML860AL2", 160.0, 290.0, "Size?", 720.0, creator = "Aimé Leon Dore",
            traits = listOf("860", "suede", "mesh"), tags = listOf("collab"), shoes = listOf(9.0, 9.5, 10.0, 11.0))
        add("Comme des Garçons PLAY × Converse Chuck 70", "Converse", S, "A08793C", 150.0, 150.0, "Dover Street Market", -1.0, creator = "Comme des Garçons",
            traits = listOf("chuck 70", "canvas", "high top"), tags = listOf("collab"), shoes = listOf(6.0, 7.0, 8.0, 9.0, 10.0, 10.5, 11.0, 12.0))
        // Clothing
        add("Supreme Box Logo Hooded Sweatshirt FW26", "Supreme", A, "FW26-SW1", 178.0, 420.0, "Supreme webstore", 2040.0,
            traits = listOf("hoodie", "heavyweight fleece", "box logo"), tags = listOf("bogo"), tops = listOf("S", "M", "L", "XL"))
        add("Supreme × The North Face Mountain Jacket", "Supreme", A, "FW26-J7", 448.0, 690.0, "Supreme webstore", 2040.0, creator = "The North Face",
            traits = listOf("jacket", "gore-tex", "outerwear"), tags = listOf("collab", "tnf"), tops = listOf("S", "M", "XL"))
        add("Stüssy 8 Ball Fleece Jacket", "Stüssy", A, "STU-8B-FL", 220.0, 300.0, "END. Launches", 2900.0,
            traits = listOf("jacket", "sherpa fleece", "outerwear"), tops = listOf("M", "L", "XL"))
        add("Palace Tri-Ferg Crew", "Palace", A, "P26-TF-CR", 138.0, 170.0, "Palace", 1500.0,
            traits = listOf("crewneck", "fleece"), tags = listOf("tri-ferg"), tops = listOf("S", "M", "L"))
        add("Kith Classic Logo Hoodie", "Kith", A, "KH-CL-26", 165.0, 190.0, "Kith", 60.0,
            traits = listOf("hoodie", "fleece", "box logo"), tops = listOf("XS", "S", "M"))
        // Fragrance
        add("Frédéric Malle The Night, 100ml", "Frédéric Malle", F, "FM-NIGHT-100", 1650.0, 1900.0, "Les Senteurs", -1.0, soldOut = true,
            creator = "Dominique Ropion", traits = listOf("saffron", "turkish rose", "frankincense", "sandalwood", "oud"), tags = listOf("niche"))
        add("Frédéric Malle Portrait of a Lady, 50ml", "Frédéric Malle", F, "FM-POAL-50", 395.0, 395.0, "Frédéric Malle boutique", -30.0,
            creator = "Dominique Ropion", traits = listOf("turkish rose", "patchouli", "incense", "sandalwood", "cinnamon"), tags = listOf("niche"))
        add("Maison Francis Kurkdjian Oud Satin Mood, 70ml", "Maison Francis Kurkdjian", F, "MFK-OSM-70", 375.0, 375.0, "Neiman Marcus", -10.0,
            creator = "Francis Kurkdjian", traits = listOf("rose", "oud", "vanilla", "benzoin", "violet"), tags = listOf("mfk"))
        add("Armani Privé Rose d'Arabie, 100ml", "Armani Privé", F, "AP-RDA-100", 340.0, 340.0, "Saks", -15.0,
            traits = listOf("rose", "oud", "incense", "amber"))
        add("Serge Lutens Sa Majesté la Rose, 50ml", "Serge Lutens", F, "SL-SMLR-50", 160.0, 160.0, "Serge Lutens", -60.0,
            traits = listOf("rose", "musk", "clove"))
        add("Maison Yusif The Beast", "Maison Yusif", F, "MY-BEAST", 290.0, 290.0, "Maison Yusif", 2880.0,
            traits = listOf("oud", "spices", "aromatics"), tags = listOf("new release"))
        add("Harrods Salon de Parfums Exclusive Extrait, 50ml", "Harrods", F, "HRD-SDP-50", 395.0, 395.0, "Harrods", 300.0,
            traits = listOf("leather", "iris", "musk"), tags = listOf("harrods exclusive", "niche"))
        // Watches
        add("Audemars Piguet Royal Oak 15510ST", "Audemars Piguet", W, "15510ST.OO.1320ST", 42500.0, 45000.0, "Chrono24", -1.0, creator = "Gérald Genta",
            traits = listOf("integrated bracelet", "steel", "41mm", "blue dial"), tags = listOf("royal oak"))
        add("Tudor Black Bay 58, 39mm", "Tudor", W, "M79030N", 4100.0, 3900.0, "Tudor boutique", -1.0,
            traits = listOf("diver", "steel", "39mm"), tags = listOf("bb58"))
        add("Cartier Santos de Cartier, Medium", "Cartier", W, "WSSA0029", 7350.0, 6900.0, "Cartier", 600.0,
            traits = listOf("integrated bracelet", "steel", "square case"), tags = listOf("santos"))
        // Cars
        add("1995 Porsche 911 Carrera (993) Coupe, 6-speed", "Porsche", C, "LOT 993-C2", 128000.0, 135000.0, "Bring a Trailer", 2700.0,
            traits = listOf("air-cooled", "manual", "coupe", "90s"), tags = listOf("911", "993"))
        add("2004 BMW M3 (E46) Coupe, 6-speed manual", "BMW M", C, "LOT E46-M3", 38500.0, 42000.0, "Cars & Bids", 1300.0,
            traits = listOf("manual", "coupe", "inline-six", "2000s"), tags = listOf("m3", "e46"))
        add("1990 Mercedes-Benz 190E 2.5-16 Evolution II", "Mercedes-Benz", C, "LOT W201-EVO2", 215000.0, 230000.0, "RM Sotheby's", 5000.0,
            traits = listOf("manual", "sedan", "homologation", "90s"), tags = listOf("evo ii", "190e"))
        // Furniture
        add("Pierre Jeanneret Office Cane Chair, Chandigarh", "Chandigarh", U, "PJ-SI-28", 9500.0, 11000.0, "1stDibs", -1.0, creator = "Pierre Jeanneret",
            traits = listOf("mid-century", "teak", "cane"), tags = listOf("vintage"))
        add("Eames Lounge Chair and Ottoman", "Herman Miller", U, "ES670-671", 7495.0, 7495.0, "Design Within Reach", -1.0, creator = "Charles and Ray Eames",
            traits = listOf("mid-century", "walnut", "leather"), tags = listOf("eames lounge"))
        add("Mario Bellini Camaleonda Sofa, 3 modules", "B&B Italia", U, "CAM-3M", 18000.0, 21000.0, "1stDibs", 900.0, creator = "Mario Bellini",
            traits = listOf("modular", "bouclé", "1970s"), tags = listOf("vintage"))
        // Accessories
        add("Chrome Hearts Cemetery Cross Ring", "Chrome Hearts", X, "CH-CCR", 895.0, 1100.0, "GOAT", -1.0,
            traits = listOf("sterling silver", "cross", "ring"), tags = listOf("jewelry"))
        add("Supreme Leather Camp Cap", "Supreme", X, "FW26-H3", 68.0, 120.0, "Supreme webstore", 2040.0,
            traits = listOf("leather", "cap"))
        // Collectibles
        add("1999 Pokémon Base Set Charizard Holo, PSA 8", "Pokémon", K, "PSA 8 #4/102", 5200.0, 5600.0, "eBay", 1800.0,
            traits = listOf("base set", "holo", "psa 8", "1999"), tags = listOf("trading cards", "charizard"))
        add("KAWS Companion Open Edition, Grey", "Medicom", K, "KAWS-COMP-OE", 450.0, 520.0, "StockX", -1.0, creator = "KAWS",
            traits = listOf("vinyl figure", "open edition"), tags = listOf("art toy"))
        add("Daft Punk Discovery, 2001 first press 2xLP", "Virgin", K, "V2940", 180.0, 180.0, "Discogs", -1.0, creator = "Daft Punk",
            traits = listOf("vinyl", "first press", "2xlp"), tags = listOf("records", "vinyl records"))
        return list
    }
}

/** Plain-language taste choices for setup, so nobody needs to know brand names to get good picks. */
object Vibes {
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
