import Foundation

extension AppStore {
    /// First-launch state: a sample squad, sample friends and a few months of sample purchases,
    /// all marked as samples so they're easy to tell apart from your own data.
    func seed() {
        state.catalogStart = .now
        state.agents = [
            Agent(id: "a1", name: "Jumpman Scout", mission: .category(.sneakers), keywords: ["aj1", "retro"],
                  style: StyleProfile(traits: ["jordan 1", "suede", "low top"], makers: ["Jordan"], creators: ["Travis Scott"]),
                  size: "US M 10.5", mode: .ask, voice: .hype),
            Agent(id: "a2", name: "Thursday Drop Desk", mission: .category(.apparel), keywords: ["box logo"],
                  style: StyleProfile(traits: ["heavyweight fleece", "outerwear"], makers: ["Supreme", "Stüssy"], creators: ["The North Face"]),
                  size: "L", mode: .alert, voice: .hype),
            Agent(id: "a3", name: "Knightsbridge Nose", mission: .category(.fragrance), keywords: ["harrods exclusive"],
                  style: StyleProfile(traits: ["oud", "rose", "saffron", "incense"], makers: ["Frédéric Malle", "Maison Francis Kurkdjian"], creators: ["Dominique Ropion"]),
                  size: "50ml or 100ml", mode: .ask, voice: .chill),
            Agent(id: "a4", name: "Air-Cooled Desk", mission: .category(.cars), keywords: ["911"],
                  style: StyleProfile(traits: ["air-cooled", "manual", "coupe"], makers: ["Porsche", "BMW M"], creators: []),
                  size: "", mode: .alert, voice: .straight),
            Agent(id: "a5", name: "Studio Hunter", mission: .category(.furniture), keywords: [],
                  style: StyleProfile(traits: ["mid-century", "walnut", "teak", "cane"], makers: ["Herman Miller"], creators: ["Pierre Jeanneret", "Eames"]),
                  size: "", mode: .ask, voice: .chill),
        ]

        let cal = Calendar.current
        func daysIntoMonth(_ monthsAgo: Int, _ day: Int) -> Date {
            let start = cal.date(from: cal.dateComponents([.year, .month], from: .now)) ?? .now
            let month = cal.date(byAdding: .month, value: -monthsAgo, to: start) ?? start
            return cal.date(byAdding: DateComponents(day: day - 1, hour: 15), to: month) ?? month
        }
        func p(_ monthsAgo: Int, _ day: Int, _ title: String, _ amt: Double, _ agent: String, _ cat: Category) -> Purchase {
            Purchase(date: daysIntoMonth(monthsAgo, day), title: title, amount: amt, agentID: agent, category: cat, isSample: true)
        }
        state.purchases = [
            p(3, 12, "New Balance 9060", 150, "a1", .sneakers), p(3, 25, "Stüssy Basic Tee", 50, "a2", .apparel),
            p(3, 28, "Byredo Bal d'Afrique, 50ml", 205, "a3", .fragrance),
            p(2, 3, "Air Jordan 4 Retro", 215, "a1", .sneakers), p(2, 14, "Le Labo Santal 33, 50ml", 220, "a3", .fragrance),
            p(2, 21, "Supreme Tee", 54, "a2", .apparel), p(2, 27, "Vitra Eames Elephant", 245, "a5", .furniture),
            p(1, 9, "Maison Margiela Replica Jazz Club, 100ml", 160, "a3", .fragrance), p(1, 18, "Supreme Box Logo Crewneck", 168, "a2", .apparel),
            p(1, 22, "Nike Dunk Low", 115, "a1", .sneakers), p(1, 27, "Herman Miller Eames Molded Plastic Side Chair", 495, "a5", .furniture),
            p(0, 1, "Air Jordan 1 Retro Low OG", 185, "a1", .sneakers),
        ]

        state.friends = [
            Friend(id: "u1", name: "Dre Johnson", handle: "@dre.kicks", hunts: [.sneakers, .apparel], likes: ["jordan 1", "suede", "fleece", "outerwear"],
                   replies: ["W. Cop it before it's gone.", "Yo that's hard. What size you grabbing?", "Saw that this morning, it's even better in person."]),
            Friend(id: "u2", name: "Maya Chen", handle: "@mayac", hunts: [.fragrance, .furniture], likes: ["rose", "oud", "mid-century", "walnut"],
                   replies: ["Okay obsessed. Send me your thoughts after you try it.", "This is so you. Do it.", "Ooh, adding that to my list too."]),
            Friend(id: "u3", name: "Sam Patel", handle: "@samp", hunts: [.watches, .cars], likes: ["manual", "air-cooled", "steel", "integrated bracelet"],
                   replies: ["That's a forever piece. Respect.", "Check the service history before you commit.", "Absolute grail. Keep me posted."]),
        ]
        func itemID(_ prefix: String) -> String? { Catalog.items.first { $0.title.hasPrefix(prefix) }?.id }
        let hour: TimeInterval = 3600
        state.suggestions = [
            itemID("Travis Scott").map { Suggestion(id: "s1", friendID: "u1", itemID: $0, note: "Your size is still showing on SNKRS. Don't sleep on these.", date: Date.now - 1.5 * hour) },
            itemID("Armani Privé Rose").map { Suggestion(id: "s2", friendID: "u2", itemID: $0, note: "Rose and oud together. Literally your whole thing.", date: Date.now - 5 * hour) },
            itemID("1995 Porsche 911").map { Suggestion(id: "s3", friendID: "u3", itemID: $0, note: "Air-cooled, manual, coupe. You know you want it.", date: Date.now - 20 * hour) },
        ].compactMap { $0 }

        state.liveTabs = LiveTab.presets
        state.lastSeen = .now
        sweep(quiet: true)
    }
}
