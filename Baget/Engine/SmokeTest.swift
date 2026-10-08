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
        let pause: UInt64 = 1_500_000_000
        for tab in [AppTab.live, .finds, .squad, .friends, .live] {
            router.tab = tab
            try? await Task.sleep(nanoseconds: pause)
        }
        let firstAgent = store.state.agents.first?.id ?? "a1"
        for sheet in [ActiveSheet.agentIcon(firstAgent), .profile, .inbox, .spending, .checkout("smoke-find"), .customizeBar, .deploy] {
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
