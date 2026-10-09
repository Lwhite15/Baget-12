import SwiftUI

/// One mission's finds: "Fragrance", "Cars", or a custom mission like "high-rise apartments in McLean".
private struct FindGroup: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let agent: Agent?
    var finds: [Find]
    var newCount: Int { finds.filter { $0.status == .open }.count }
}

enum FindsShow: String, CaseIterable, Identifiable {
    case all = "All", new = "New", liked = "Liked"
    var id: String { rawValue }
}

struct FindsView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @State private var show: FindsShow = .all
    @State private var collapsed: Set<String> = []
    @State private var expanded: String?
    @State private var highlighted: String?
    @State private var sweeping = false

    /// Passed and bought finds leave the screen; the agents still learn from them and never show them again.
    private var visible: [Find] {
        store.state.finds.filter { f in
            guard f.status == .open || f.status == .liked, Catalog.item(f.itemID) != nil else { return false }
            switch show {
            case .all: return true
            case .new: return f.status == .open
            case .liked: return f.status == .liked
            }
        }
    }

    private var groups: [FindGroup] {
        var byKey: [String: FindGroup] = [:]
        for f in visible {
            guard let item = Catalog.item(f.itemID) else { continue }
            let agent = store.agent(f.agentID)
            let mission = agent?.mission
            let key: String
            let title: String
            let symbol: String
            if case .custom(let text)? = mission {
                key = "custom-" + (agent?.id ?? text)
                title = text.capitalizedFirst
                symbol = customMissionInfo.symbol
            } else {
                let c = mission?.category ?? item.category
                key = c.rawValue
                title = c.info.label
                symbol = c.info.symbol
            }
            byKey[key, default: FindGroup(id: key, title: title, symbol: symbol, agent: agent, finds: [])].finds.append(f)
        }
        return byKey.values
            .map { g in
                var g = g
                // New first, then liked; strongest match first; newest first on ties.
                g.finds.sort { a, b in
                    if (a.status == .open) != (b.status == .open) { return a.status == .open }
                    if a.score != b.score { return a.score > b.score }
                    return a.foundAt > b.foundAt
                }
                return g
            }
            .sorted { a, b in
                if a.newCount != b.newCount { return a.newCount > b.newCount }
                return a.title < b.title
            }
    }

    var body: some View {
        let groups = self.groups
        let newTotal = store.state.finds.filter { $0.status == .open }.count
        let likedTotal = store.state.finds.filter { $0.status == .liked }.count

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(newTotal: newTotal, likedTotal: likedTotal)

                    Picker("Show", selection: $show) {
                        Text("All").tag(FindsShow.all)
                        Text(newTotal > 0 ? "New · \(newTotal)" : "New").tag(FindsShow.new)
                        Text(likedTotal > 0 ? "♥ Liked · \(likedTotal)" : "♥ Liked").tag(FindsShow.liked)
                    }
                    .pickerStyle(.segmented)

                    if groups.isEmpty {
                        EmptyCard(text: emptyText)
                    }

                    ForEach(groups) { g in
                        section(g)
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
            .onChange(of: router.focusFind, initial: true) { _, id in
                guard let id else { return }
                // Make sure it's visible: show everything, open its section and the card, then scroll to it.
                show = .all
                if let g = self.groups.first(where: { $0.finds.contains { $0.id == id } }) { collapsed.remove(g.id) }
                expanded = id
                router.focusFind = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .top) }
                    withAnimation { highlighted = id }
                    try? await Task.sleep(for: .seconds(2.2))
                    withAnimation(.easeOut(duration: 0.6)) { if highlighted == id { highlighted = nil } }
                }
            }
        }
    }

    private var emptyText: String {
        if store.state.agents.isEmpty { return "Deploy an agent first, then run a sweep." }
        switch show {
        case .new: return "You're all caught up. Your squad keeps hunting in the background."
        case .liked: return "Nothing liked yet. Tap ♥ on a find you love and your agents will find more like it."
        case .all: return "Nothing here yet. Tap Sweep now, or pull down on Live."
        }
    }

    private func header(newTotal: Int, likedTotal: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Finds").font(.system(size: 30, weight: .heavy)).tracking(-0.8).foregroundStyle(Theme.ink)
                Text("\(store.state.agents.count) agents hunting · \(newTotal) new · \(likedTotal) liked")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button {
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
            } label: {
                if sweeping { ProgressView().tint(Theme.accent) } else { IconText(icon: "arrow.clockwise", text: "Sweep") }
            }
            .buttonStyle(GhostButton())
            .frame(width: 100)
            .disabled(sweeping)
        }
        .padding(.top, 4)
    }

    @ViewBuilder private func section(_ g: FindGroup) -> some View {
        let isCollapsed = collapsed.contains(g.id)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { if isCollapsed { collapsed.remove(g.id) } else { collapsed.insert(g.id) } }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: g.symbol)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.accentInk)
                        .frame(width: 30, height: 30)
                        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(g.title).font(.headline).foregroundStyle(Theme.ink).lineLimit(1)
                        Text([g.agent?.name, "\(g.finds.count) find\(g.finds.count == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer()
                    if g.newCount > 0 {
                        Text("\(g.newCount) new")
                            .font(.caption2.weight(.bold)).foregroundStyle(Theme.accentInk)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.gradient))
                    }
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.bold)).foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(g.title), \(g.finds.count) finds, \(g.newCount) new")
            .accessibilityHint(isCollapsed ? "Expands the section" : "Collapses the section")

            if !isCollapsed {
                VStack(spacing: 10) {
                    ForEach(g.finds) { f in
                        FindCard(find: f, highlighted: highlighted == f.id,
                                 expanded: Binding(get: { expanded == f.id },
                                                   set: { open in withAnimation(.snappy) { expanded = open ? f.id : nil } }))
                            .id(f.id)
                    }
                }
            }
        }
    }
}

/// A product photo (or brand letters) in a small rounded square.
struct ProductThumb: View {
    let item: Item
    var size: CGFloat = 76
    @State private var photo: ProductPhoto?

    private var photoURL: URL? {
        guard let s = item.imageURL, s.hasPrefix("https://") else { return nil }
        return URL(string: s)
    }

    var body: some View {
        ZStack {
            if let photo {
                Rectangle().fill(photo.lifted ? AnyShapeStyle(Theme.panel) : AnyShapeStyle(Color.white))
                Image(uiImage: photo.image).resizable().interpolation(.high).scaledToFit().padding(photo.lifted ? 8 : 4)
            } else {
                Theme.glass
                RadialGradient(colors: [Theme.blue.opacity(0.35), .clear], center: .topLeading, startRadius: 0, endRadius: size)
                Text(item.brand.split(separator: " ").compactMap { $0.first }.prefix(2).map { String($0) }.joined().uppercased())
                    .font(.system(size: size * 0.3, weight: .heavy)).foregroundStyle(Theme.ink)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
        .task(id: photoURL) {
            guard let url = photoURL else { photo = nil; return }
            if let hit = ImageCache.shared.cached(url) { photo = hit; return }
            photo = await ImageCache.shared.load(url)
        }
        .accessibilityHidden(true)
    }
}

struct FindCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let find: Find
    var highlighted = false
    @Binding var expanded: Bool
    @State private var askingWhy = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let item = Catalog.item(find.itemID) {
            let agent = store.agent(find.agentID)
            VStack(alignment: .leading, spacing: 10) {
                Button { expanded.toggle() } label: { summary(item) }
                    .buttonStyle(.plain)
                    .accessibilityHint(expanded ? "Hides details" : "Shows details")
                if expanded { details(item, agent: agent) }
                actions(item: item, agent: agent)
            }
            .padding(12)
            .background(highlighted ? Theme.accent.opacity(0.12) : Theme.glass, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(highlighted ? Theme.accent.opacity(0.6) : Theme.line))
            .confirmationDialog("What was off? \(agent?.name ?? "Your agent") will learn from it.", isPresented: $askingWhy, titleVisibility: .visible) {
                ForEach(AppStore.PassReason.allCases) { r in
                    Button(r.rawValue) {
                        store.pass(find.id, reason: r)
                        Analytics.track(.findPassed, ["reason": r.rawValue, "category": item.category.rawValue])
                        router.say(r == .later ? "Passed" : "Passed. \(agent?.name ?? "Your agent") is learning from that")
                    }
                }
            }
        }
    }

    // MARK: Collapsed row

    private func summary(_ item: Item) -> some View {
        let known = item.priceKnown && item.price > 0
        let isNew = find.status == .open && find.foundAt > Date.now.addingTimeInterval(-24 * 3600)
        return HStack(alignment: .top, spacing: 12) {
            ProductThumb(item: item)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isNew { badge("NEW", Theme.accent) }
                    if store.isSoldOut(item) { badge("SOLD OUT", Theme.warn) }
                    else if !store.isLive(item) { badge(store.whenLabel(item), Theme.blue) }
                    if find.status == .liked { Image(systemName: "heart.fill").font(.caption).foregroundStyle(Theme.hot) }
                    Spacer(minLength: 0)
                    Text("\(find.score)%")
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(find.score >= 80 ? Theme.green : find.score >= 60 ? Theme.accent : Theme.muted)
                }
                Text(item.title)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Text([item.source, known ? Fmt.money(item.price) : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                if let reason = find.why.first, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(Theme.green.opacity(0.9)).lineLimit(expanded ? 4 : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private func badge(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .lineLimit(1)
    }

    // MARK: Expanded details

    @ViewBuilder private func details(_ item: Item, agent: Agent?) -> some View {
        let known = item.priceKnown && item.price > 0
        let diff = known && item.market > 0 ? item.market - item.price : 0
        let pct = known && item.market > 0 ? Int(safe: (diff / item.price * 100).rounded()) : 0
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                priceCell("PRICE", known ? Fmt.money(item.price) : "See store", nil)
                priceCell("MARKET", known && item.market > 0 ? Fmt.money(item.market) : "—", nil)
                priceCell("SPREAD", known && item.market > 0 ? "\(diff > 0 ? "+" : "")\(pct)%" : "—", diff > 0 ? Theme.green : diff < 0 ? Theme.hot : nil)
            }
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Divider().overlay(Theme.line) }
            .overlay(alignment: .bottom) { Divider().overlay(Theme.line) }

            let traits = item.traits + (item.creator.map { [$0] } ?? [])
            if !traits.isEmpty {
                Text(traits.joined(separator: " · ")).font(.caption).italic().foregroundStyle(Theme.muted)
            }
            if let agent {
                if find.why.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(find.why.dropFirst(), id: \.self) { w in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Circle().fill(Theme.accent).frame(width: 5, height: 5)
                                Text(w).font(.footnote).foregroundStyle(Theme.ink)
                            }
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
            if find.watching && (store.isSoldOut(item) || !store.isLive(item)) {
                Text(store.isSoldOut(item) ? "\(agent?.name ?? "Your agent") will text you if it restocks." : "\(agent?.name ?? "Your agent") will text you at release.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func priceCell(_ label: String, _ value: String, _ tint: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted)
            Text(value).font(.system(.subheadline, design: .monospaced).weight(.semibold)).foregroundStyle(tint ?? Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    @ViewBuilder private func actions(item: Item, agent: Agent?) -> some View {
        let link = BuyLink.url(item)
        HStack(spacing: 8) {
            if find.status == .liked {
                chip("heart.fill", "Liked", tint: Theme.hot) { store.unlike(find.id) }
                    .accessibilityHint("Tap to unlike")
            } else {
                chip("heart", "Like", primary: true) {
                    store.like(find.id)
                    router.say("\(agent?.name ?? "Your agent") will find more like this")
                }
                chip("xmark", "Pass") { askingWhy = true }
            }
            if let link {
                chip("arrow.up.right", "Buy") {
                    Analytics.track(.checkoutOpened, ["category": item.category.rawValue, "toStore": true, "from": "find"])
                    router.buyOpened = find.id
                    openURL(link)
                }
                .accessibilityLabel("Buy at \(item.source)")
            }
            Spacer(minLength: 0)
            Button { router.sheet = .share(itemID: item.id, friendID: nil, suggestion: false) } label: {
                Image(systemName: "square.and.arrow.up").font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink)
                    .frame(width: 34, height: 34)
                    .background(Theme.glass, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.line))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share with friends")
        }
    }

    private func chip(_ icon: String, _ text: String, primary: Bool = false, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).imageScale(.small)
                Text(text).fixedSize()
            }
            .font(.footnote.weight(.bold))
            .foregroundStyle(primary ? Theme.accentInk : (tint ?? Theme.ink))
            .padding(.horizontal, 12).frame(height: 34)
            .background {
                if primary { Capsule().fill(Theme.gradient) } else { Capsule().fill(Theme.glass) }
            }
            .overlay { if !primary { Capsule().strokeBorder(Theme.line) } }
        }
        .buttonStyle(.plain)
    }
}

/// An icon and a word, tight together, never wrapping.
struct IconText: View {
    let icon: String
    let text: String
    var trailing = false
    var body: some View {
        HStack(spacing: 5) {
            if !trailing { Image(systemName: icon).imageScale(.small) }
            Text(text).fixedSize()
            if trailing { Image(systemName: icon).imageScale(.small) }
        }
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
                            router.say("Logged and off your list. \(a?.name ?? "Your agent") will learn from it.")
                            dismiss()
                        }
                        .buttonStyle(GhostButton())
                        .disabled(!item.priceKnown && (Double(amountText.replacingOccurrences(of: ",", with: "")) ?? 0) <= 0)
                    } else if block == nil {
                        Button("Confirm purchase") {
                            store.confirmPurchase(findID)
                            Analytics.track(.purchaseConfirmed, ["amount": item.price, "category": item.category.rawValue, "score": f.score, "agentMode": a?.mode.rawValue ?? ""])
                            router.say("Bought. It's off your list.")
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
