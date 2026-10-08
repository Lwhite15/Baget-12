import SwiftUI

struct FindsView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @State private var filter: Category? = nil
    @State private var likedOnly = false
    @State private var sweeping = false

    private func rank(_ f: Find) -> Int { (f.status == .open ? 1000 : f.status == .liked ? 500 : 0) + f.score }

    var body: some View {
        let present = Category.allCases.filter { c in store.state.finds.contains { Catalog.item($0.itemID)?.category == c } }
        let finds = store.state.finds
            .filter { f in filter == nil || Catalog.item(f.itemID)?.category == filter }
            .filter { f in !likedOnly || f.status == .liked || f.status == .acquired }
            .sorted { rank($0) > rank($1) }

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "What your squad found")
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        Button { filter = nil; likedOnly = false } label: { Pill(text: "All", selected: filter == nil && !likedOnly) }
                        if store.state.finds.contains(where: { $0.status == .liked || $0.status == .acquired }) {
                            Button { likedOnly.toggle() } label: { Pill(text: "♥ Liked", selected: likedOnly) }
                        }
                        ForEach(present) { c in
                            Button { filter = c } label: { Pill(text: c.info.label, selected: filter == c) }
                        }
                    }
                }
                .scrollIndicators(.hidden)

                HStack(spacing: 10) {
                    Circle().fill(Theme.green).frame(width: 8, height: 8)
                    Text("\(store.state.agents.count) agents hunting · \(store.state.finds.filter { $0.status == .open }.count) finds waiting on you")
                        .font(.footnote).foregroundStyle(Theme.muted)
                    Spacer()
                    Button(sweeping ? "Searching…" : "Sweep now") {
                        if store.isCloud {
                            sweeping = true
                            Task { @MainActor in
                                let msg = await store.cloudSweep()
                                sweeping = false
                                if let msg { router.say(msg) }
                            }
                        } else {
                            let res = store.sweep()
                            Analytics.track(.sweepRun, ["found": res.found, "manual": true])
                            if res.found == 0 { router.say("Nothing new fits you right now") }
                        }
                    }
                    .disabled(sweeping)
                    .font(.footnote.weight(.bold)).foregroundStyle(Theme.accent)
                }
                .glassCard()

                if finds.isEmpty {
                    EmptyCard(text: store.state.agents.isEmpty ? "Deploy an agent first, then run a sweep." : "Nothing here yet. Pull down on Live or tap Sweep now.")
                }
                LazyVStack(spacing: 14) {
                    ForEach(finds) { f in FindCard(find: f) }
                }
                if !store.isCloud {
                    Text("Sample data: listings, prices and drop times are illustrative, and nothing is purchased.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }
}

struct FindCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let find: Find
    @State private var askingWhy = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let item = Catalog.item(find.itemID) {
            let agent = store.agent(find.agentID)
            let known = item.priceKnown && item.price > 0
            let diff = known && item.market > 0 ? item.market - item.price : 0
            let pct = known && item.market > 0 ? Int(safe: (diff / item.price * 100).rounded()) : 0
            VStack(alignment: .leading, spacing: 12) {
                Plate(item: item, label: store.whenLabel(item), live: store.isLive(item), height: 120)
                Text(item.title).font(.headline).foregroundStyle(Theme.ink)
                FlowRow {
                    Tag(text: item.category.info.label)
                    if let agent, item.category.info.sizeRequired, !agent.size.isEmpty { Tag(text: agent.size) }
                }
                Text((item.traits + (item.creator.map { [$0] } ?? [])).joined(separator: " · "))
                    .font(.caption).italic().foregroundStyle(Theme.muted)
                HStack {
                    priceCell("PRICE", known ? Fmt.money(item.price) : "See store", nil)
                    priceCell("MARKET", known && item.market > 0 ? Fmt.money(item.market) : "—", nil)
                    priceCell("SPREAD", known && item.market > 0 ? "\(diff > 0 ? "+" : "")\(pct)%" : "—", diff > 0 ? Theme.green : diff < 0 ? Theme.hot : nil)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Divider().overlay(Theme.line) }
                .overlay(alignment: .bottom) { Divider().overlay(Theme.line) }

                if let agent {
                    Text("Why \(agent.name) picked this:").font(.footnote).foregroundStyle(Theme.muted)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(find.why, id: \.self) { w in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Circle().fill(Theme.accent).frame(width: 5, height: 5)
                                Text(w).font(.footnote).foregroundStyle(Theme.ink)
                            }
                        }
                    }
                    if find.status == .open {
                        let take = store.take(agent, item)
                        (Text("\(agent.name): ").bold().foregroundStyle(take.caution ? Theme.warn : Theme.accent) + Text(take.text).foregroundStyle(Theme.ink))
                            .font(.footnote)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background((take.caution ? Theme.warn : Theme.accent).opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                HStack(spacing: 8) {
                    Text("\(find.score)%").font(.caption.monospaced()).foregroundStyle(Theme.ink)
                    Meter(value: Double(find.score) / 100)
                    Text("match").font(.caption).foregroundStyle(Theme.muted)
                }
                actions(item: item, agent: agent)
            }
            .glassCard()
            .confirmationDialog("What was off? \(agent?.name ?? "Your agent") will learn from it.", isPresented: $askingWhy, titleVisibility: .visible) {
                ForEach(AppStore.PassReason.allCases) { r in
                    Button(r.rawValue) {
                        store.pass(find.id, reason: r)
                        Analytics.track(.findPassed, ["reason": r.rawValue, "category": item.category.rawValue])
                        if r != .later { router.say("\(agent?.name ?? "Your agent") is learning from that") }
                    }
                }
            }
        }
    }

    private func priceCell(_ label: String, _ value: String, _ tint: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted)
            Text(value).font(.system(.subheadline, design: .monospaced).weight(.semibold)).foregroundStyle(tint ?? Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func actions(item: Item, agent: Agent?) -> some View {
        let link = BuyLink.url(item)
        switch find.status {
        case .acquired:
            Label("You bought this", systemImage: "checkmark.seal.fill")
                .font(.footnote.weight(.bold)).foregroundStyle(Theme.green)
                .frame(maxWidth: .infinity).padding(10)
                .background(Theme.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        case .passed:
            HStack {
                Text("Passed\(find.passReason.map { " · \($0)" } ?? "")").font(.footnote).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                Button("Undo") { store.undoPass(find.id) }.buttonStyle(GhostButton())
            }
        case .liked:
            HStack(spacing: 8) {
                Button { store.unlike(find.id) } label: { Label("Liked", systemImage: "heart.fill") }
                    .buttonStyle(GhostButton()).tint(Theme.hot)
                    .accessibilityHint("Tap to unlike")
                if let link { buyButton(item, link) }
                shareButton(item)
            }
            if find.watching && (store.isSoldOut(item) || !store.isLive(item)) {
                Text(store.isSoldOut(item) ? "\(agent?.name ?? "Your agent") will text you if it restocks." : "\(agent?.name ?? "Your agent") will text you at release.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        case .open:
            HStack(spacing: 8) {
                Button {
                    store.like(find.id)
                    router.say("\(agent?.name ?? "Your agent") will find more like this")
                } label: { Label("Like", systemImage: "heart") }
                    .buttonStyle(PrimaryButton())
                Button("Pass") { askingWhy = true }.buttonStyle(GhostButton())
                if let link { buyButton(item, link) }
                shareButton(item)
            }
        }
    }

    private func buyButton(_ item: Item, _ link: URL) -> some View {
        Button {
            Analytics.track(.checkoutOpened, ["category": item.category.rawValue, "toStore": true, "from": "find"])
            router.buyOpened = find.id
            openURL(link)
        } label: { Label("Buy", systemImage: "arrow.up.right") }
            .buttonStyle(GhostButton())
            .frame(width: 92)
            .accessibilityLabel("Buy at \(item.source)")
    }

    private func shareButton(_ item: Item) -> some View {
        Button { router.sheet = .share(itemID: item.id, friendID: nil, suggestion: false) } label: {
            Image(systemName: "square.and.arrow.up")
        }.buttonStyle(GhostButton()).frame(width: 54).accessibilityLabel("Share with friends")
    }
}

/// Where an item can actually be bought: its own https page, never a search page.
enum BuyLink {
    static func url(_ item: Item) -> URL? {
        guard !item.isSample, let s = item.url, s.hasPrefix("https://"), let u = URL(string: s), let host = u.host else { return nil }
        let q = (u.query ?? "").lowercased()
        let path = u.path.lowercased()
        if ["_nkw=", "q=", "query=", "keyword=", "k=", "search="].contains(where: { q.hasPrefix($0) || q.contains("&" + $0) }) { return nil }
        if path.contains("/search") || path.contains("/sch/") || path.isEmpty || path == "/" { return nil }
        if host.contains("ebay.") && !path.hasPrefix("/itm/") { return nil }
        return u
    }
}

struct CheckoutView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let findID: String
    @State private var amountText = ""

    var body: some View {
        if let f = store.state.finds.first(where: { $0.id == findID }), let item = Catalog.item(f.itemID) {
            let a = store.agent(f.agentID)
            let live = store.isLive(item)
            let soldOut = store.isSoldOut(item)
            let block = blockReason(item: item, agent: a, live: live, soldOut: soldOut)
            let cloud = store.isCloud && !item.isSample

            VStack(alignment: .leading, spacing: 16) {
                Text(item.title).font(.title2.weight(.heavy)).foregroundStyle(Theme.ink)
                Text([item.source, item.sku].filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.muted)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow { cell("Price", item.priceKnown ? Fmt.money(item.price) : "Not listed"); cell("Agent", a?.name ?? "—") }
                    GridRow {
                        cell(item.category.info.sizeRequired ? (item.category.info.sizeLabel ?? "Size") : "Category",
                             item.category.info.sizeRequired ? (a?.size.isEmpty == false ? a!.size : "Any") : item.category.info.label)
                        cell("Store", item.source.isEmpty ? "—" : item.source)
                    }
                }
                .glassCard()

                if cloud {
                    Text(cloudNote(item: item, block: block, soldOut: soldOut, live: live))
                        .font(.subheadline).foregroundStyle(Theme.muted)
                    if let link = BuyLink.url(item), !soldOut {
                        Button {
                            Analytics.track(.checkoutOpened, ["category": item.category.rawValue, "toStore": true])
                            router.buyOpened = findID
                            openURL(link)
                        } label: { Label("Open at \(item.source)", systemImage: "arrow.up.right.square") }
                            .buttonStyle(PrimaryButton())
                    }
                    if !item.priceKnown && live && !soldOut {
                        TextField("What did you pay? (USD)", text: $amountText)
                            .keyboardType(.decimalPad)
                            .padding(10).background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
                    }
                } else {
                    Text(block ?? "Sample checkout. No card is charged.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                }
                Spacer()
                HStack {
                    Button("Cancel") { dismiss() }.buttonStyle(GhostButton())
                    if soldOut || !live {
                        Button(soldOut ? "Watch for restock" : "Remind me at release") {
                            store.watch(findID)
                            Analytics.track(.findWatched, ["category": item.category.rawValue])
                            router.say(soldOut ? "Restock watch on" : "Got it. Your agent will ping you at release.")
                            dismiss()
                        }.buttonStyle(PrimaryButton())
                    } else if cloud {
                        Button("I bought it") {
                            let amount = item.priceKnown ? item.price : Double(amountText.replacingOccurrences(of: ",", with: "")) ?? 0
                            store.confirmPurchase(findID, amount: amount)
                            Analytics.track(.purchaseConfirmed, ["amount": amount, "category": item.category.rawValue, "score": f.score, "agentMode": a?.mode.rawValue ?? ""])
                            router.say("Logged. \(a?.name ?? "Your agent") will learn from it.")
                            dismiss()
                        }
                        .buttonStyle(GhostButton())
                        .disabled(!item.priceKnown && (Double(amountText.replacingOccurrences(of: ",", with: "")) ?? 0) <= 0)
                    } else if block == nil {
                        Button("Confirm purchase") {
                            store.confirmPurchase(findID)
                            Analytics.track(.purchaseConfirmed, ["amount": item.price, "category": item.category.rawValue, "score": f.score, "agentMode": a?.mode.rawValue ?? ""])
                            router.say("Bought")
                            dismiss()
                        }.buttonStyle(PrimaryButton())
                    }
                }
            }
            .padding(20)
            .presentationDetents([.medium, .large])
            .onAppear { Analytics.track(.checkoutOpened, ["category": item.category.rawValue, "blocked": block != nil]) }
        }
    }

    private func cloudNote(item: Item, block: String?, soldOut: Bool, live: Bool) -> String {
        if soldOut || !live { return block ?? "" }
        let caution = block.map { "Heads up: \($0) " } ?? ""
        return caution + "You buy it at \(item.source); Baget never charges you. Tap \"I bought it\" afterwards so your agent learns from it."
    }

    private func blockReason(item: Item, agent a: Agent?, live: Bool, soldOut: Bool) -> String? {
        let name = a?.name ?? "Your agent"
        if soldOut { return "Sold out right now. \(name) will watch for a restock and tell you the moment it's back." }
        if !live { return "This isn't available yet. Your agent will hold your spot and ask again at release." }
        _ = a
        return nil
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted)
            Text(value).font(.system(.subheadline, design: .monospaced).weight(.semibold)).foregroundStyle(Theme.ink)
        }
    }
}
