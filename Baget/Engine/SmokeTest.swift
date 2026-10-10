#if DEBUG
import Foundation

/// Debug builds only. Launched with -BagetSmokeTest (by CI on the simulator), the app opens the sample tour,
/// adds a find whose price is unknown, then walks every tab and the main sheets. CI fails if the app crashes.
@MainActor
enum SmokeTest {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-BagetSmokeTest") }

    static func run(store: AppStore, router: Router) async {
        store.exploreSamples()
        // A listing with no price and no sizes, like the ones agents save from chat.
        let item = Item(id: "smoke-unpriced", title: "Smoke Test Eau de Parfum", brand: "Smoke Lab", category: .fragrance, sku: "",
                        price: 0, market: 0, source: "example.com", dropOffset: 0, soldOutAtStart: false, creator: nil,
                        traits: ["smoky"], tags: [], shoeSizes: nil, topSizes: nil,
                        url: "https://example.com/p", imageURL: "https://upload.wikimedia.org/wikipedia/commons/thumb/4/47/PNG_transparency_demonstration_1.png/280px-PNG_transparency_demonstration_1.png", priceKnown: false, isSample: false)
        Catalog.cloud[item.id] = item
        if let agent = store.state.agents.first {
            store.state.finds.insert(Find(id: "smoke-find", itemID: item.id, agentID: agent.id, score: 80, why: ["Smoke test"]), at: 0)
        }
        if let agent = store.state.agents.first {
            var icon = Avatar()
            icon.style = .emoji
            icon.emoji = "🦍"
            icon.color = 2
            store.setAgentIcon(agent.id, icon: icon, photo: nil)
            store.state.agents.indices.dropFirst().first.map { store.setAgentIcon(store.state.agents[$0].id, icon: nil, photo: nil) }
        }
        // Like, unlike and like again, plus a sample find passed for style: the learning paths.
        store.like("smoke-find"); store.unlike("smoke-find"); store.like("smoke-find")
        if let other = store.state.finds.first(where: { $0.id != "smoke-find" && $0.status == .open }) { store.pass(other.id, reason: .style) }
        // New screens and actions: watch, remove a taste, a deal verdict on an item with other stores' prices.
        store.toggleWatch("smoke-find")
        if let a = store.state.agents.first, let t = a.style.traits.first { store.removeTaste(a.id, t) }
        // Agent switches: off, quiet texts, back on.
        if var a = store.state.agents.first {
            store.setOff(a.id, true)
            a = store.agent(a.id) ?? a
            a.alertLevel = .quiet
            store.update(a)
            _ = store.sweep(quiet: true)
            store.setOff(a.id, false)
        }
        let priced = Item(id: "smoke-priced", title: "Smoke Test Sneaker", brand: "Smoke Lab", category: .sneakers, sku: "", price: 200, market: 260,
                      source: "Smoke Store", dropOffset: 0, soldOutAtStart: false, creator: nil, traits: [], tags: [], shoeSizes: nil, topSizes: nil,
                      url: "https://example.com/s", priceKnown: true, isSample: false,
                      offers: [Offer(store: "Other Store", price: 180)], lowPrice: 180, lowStore: "Other Store")
        Catalog.cloud[priced.id] = priced
        _ = DealVerdict.of(priced)
        let pause: UInt64 = 1_500_000_000
        // Tap a Live item: it opens in Finds.
        if let story = store.stories().first { router.openInFinds(story, store: store); try? await Task.sleep(nanoseconds: 1_500_000_000) }
        for tab in [AppTab.live, .finds, .squad, .friends, .live] {
            router.tab = tab
            try? await Task.sleep(nanoseconds: pause)
        }
        let firstAgent = store.state.agents.first?.id ?? "a1"
        for sheet in [ActiveSheet.swipe, .taste, .ask("smoke-find"), .agentIcon(firstAgent), .profile, .inbox, .checkout("smoke-find"), .customizeBar, .deploy] {
            router.sheet = sheet
            try? await Task.sleep(nanoseconds: pause)
            router.sheet = nil
            try? await Task.sleep(nanoseconds: pause / 2)
        }
        let marker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("smoke-ok")
        try? Data("ok".utf8).write(to: marker)
        print("BAGET SMOKE OK")
    }
}
#endif
