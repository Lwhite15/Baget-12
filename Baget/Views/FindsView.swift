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
    // In the order the filter row shows them.
    case new = "New", liked = "Liked", watching = "Watching", intel = "Intel", all = "All"
    var id: String { rawValue }
}

struct FindsView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @State private var show: FindsShow = .new
    @State private var collapsed: Set<String> = []
    @State private var expanded: String?
    @State private var highlighted: String?
    @State private var sweeping = false
    @State private var confirmClear = false
    /// First-run tips: 0-2 showing, 3 done. Shown once, on your first real finds.
    @AppStorage("baget.findsTips") private var tipStep = 0

    /// Passed and bought finds leave the screen; the agents still learn from them and never show them again.
    private var visible: [Find] {
        store.state.finds.filter { f in
            guard f.status == .open || f.status == .liked, Catalog.item(f.itemID)?.showsInFinds == true else { return false }
            switch show {
            case .all: return true
            case .new: return f.status == .open
            case .liked: return f.status == .liked
            case .watching: return f.watching
            case .intel: return Catalog.item(f.itemID)?.isProduct == false
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
        let newTotal = store.state.finds.filter { $0.status == .open && Catalog.item($0.itemID)?.showsInFinds == true }.count
        let likedTotal = store.state.finds.filter { $0.status == .liked && Catalog.item($0.itemID)?.showsInFinds == true }.count
        let watchingTotal = store.state.finds.filter { ($0.status == .open || $0.status == .liked) && $0.watching && Catalog.item($0.itemID)?.showsInFinds == true }.count
        let intelTotal = store.state.finds.filter { ($0.status == .open || $0.status == .liked) && Catalog.item($0.itemID).map { !$0.isProduct && $0.showsInFinds } == true }.count

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(newTotal: newTotal, likedTotal: likedTotal)

                    filterRow(counts: [.new: newTotal, .liked: likedTotal, .watching: watchingTotal, .intel: intelTotal])

                    if groups.isEmpty {
                        EmptyCard(text: emptyText)
                    }

                    if tipStep < FindsTip.all.count && !visible.isEmpty {
                        FindsTipCard(step: $tipStep)
                            .transition(.opacity.combined(with: .move(edge: .top)))
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
            .confirmationDialog(clearLabel + "?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("\(clearLabel) (\(visible.count))", role: .destructive) {
                    let n = visible.count
                    store.removeFinds(visible.map(\.id))
                    router.say(n == 1 ? "Cleared 1 find" : "Cleared \(n) finds")
                }
            } message: {
                Text("They leave Finds and your scouts won't show them again. What your scouts learned about your taste stays.")
            }
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

    /// New, Liked, Watching, Intel, All: one tap each, with counts. Scrolls sideways on small phones.
    private func filterRow(counts: [FindsShow: Int]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(FindsShow.allCases) { f in
                    let n = counts[f] ?? 0
                    let label: String = {
                        switch f {
                        case .liked: return n > 0 ? "♥ Liked · \(n)" : "♥ Liked"
                        case .watching: return n > 0 ? "Watching · \(n)" : "Watching"
                        case .all: return "All"
                        default: return n > 0 ? "\(f.rawValue) · \(n)" : f.rawValue
                        }
                    }()
                    let on = show == f
                    Button { withAnimation(.snappy) { show = f } } label: {
                        Text(label)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(on ? Theme.accentInk : Theme.ink)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background { if on { Capsule().fill(Theme.gradient) } else { Capsule().fill(Theme.glass) } }
                            .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.line))
                    }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(show == f ? .isSelected : [])
                }
            }
        }
    }

    private var clearLabel: String {
        switch show {
        case .all: return "Clear all"
        case .new: return "Clear new"
        case .liked: return "Clear liked"
        case .watching: return "Clear watching"
        case .intel: return "Clear intel"
        }
    }

    private var emptyText: String {
        if store.state.agents.isEmpty { return "Set up a scout first, then tap Hunt now." }
        switch show {
        case .new: return "You're all caught up. Your squad keeps hunting in the background."
        case .liked: return "Nothing liked yet. Tap ♥ on a find you love and your scouts will find more like it."
        case .all: return "Nothing here yet. Tap Hunt now, or pull down on Today."
        case .watching: return "Nothing on watch. Tap Watch it for me on a find, or Notify me on something sold out, and it shows up here."
        case .intel: return "No intel right now. Droplists, release calendars and news your scouts come across land here."
        }
    }

    private func header(newTotal: Int, likedTotal: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Finds").font(.system(size: 30, weight: .heavy)).tracking(-0.8).foregroundStyle(Theme.ink)
                Text("\(store.state.agents.count) scout\(store.state.agents.count == 1 ? "" : "s") hunting · \(newTotal) new · \(likedTotal) liked")
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
                if sweeping { ProgressView().tint(Theme.accent) } else { IconText(icon: "arrow.clockwise", text: "Hunt now") }
            }
            .buttonStyle(GhostButton())
            .frame(width: 118)
            .disabled(sweeping)
            .accessibilityHint("Your scouts search again right now")
            // Clearing lives behind this menu (and asks first), so it can't be hit by accident.
            Menu {
                Section("Long-press a find, or tap its trash, to remove one") {
                    Button(role: .destructive) { confirmClear = true } label: { Label("\(clearLabel)…", systemImage: "trash") }
                        .disabled(visible.isEmpty)
                }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40).background(Theme.glass, in: Circle())
            }
            .accessibilityLabel("More")
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
                if item.isProduct {
                    Text(item.brand.split(separator: " ").compactMap { $0.first }.prefix(2).map { String($0) }.joined().uppercased())
                        .font(.system(size: size * 0.3, weight: .heavy)).foregroundStyle(Theme.ink)
                } else {
                    Image(systemName: item.isIntel ? "newspaper.fill" : "list.bullet.rectangle.fill")
                        .font(.system(size: size * 0.32, weight: .semibold)).foregroundStyle(Theme.cyan)
                }
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
    @State private var reminding = false
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
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contextMenu {
                Button(role: .destructive) { remove() } label: { Label("Remove", systemImage: "trash") }
            }
            .sheet(isPresented: $reminding) {
                ReminderSheet(item: item, findID: find.id)
                    .environment(store).environment(router)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Theme.panel)
                    .preferredColorScheme(.dark)
            }
            .confirmationDialog("What was off? \(agent?.name ?? "Your scout") will learn from it.", isPresented: $askingWhy, titleVisibility: .visible) {
                ForEach(AppStore.PassReason.allCases) { r in
                    Button(r.rawValue) {
                        store.pass(find.id, reason: r)
                        Analytics.track(.findPassed, ["reason": r.rawValue, "category": item.category.rawValue])
                        router.say(r == .later ? "Passed" : "Passed. \(agent?.name ?? "Your scout") is learning from that")
                    }
                }
            }
        }
    }

    private func remove() {
        withAnimation(.snappy) { store.removeFinds([find.id]) }
        router.say("Removed")
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
                    if item.tags.contains("limited") { badge("LIMITED", Theme.hot) }
                    if find.why.contains(where: { $0.hasPrefix("Discovery") }) { badge("NEW TO YOU", Theme.cyan) }
                    if item.isIntel { badge("INTEL", Theme.cyan) }
                    if item.isSearchLink { badge("SEARCH", Theme.cyan) }
                    if store.reminder(for: item) != nil { Image(systemName: "bell.fill").font(.caption2).foregroundStyle(Theme.blue).accessibilityLabel("Reminder set") }
                    if find.status == .liked { Image(systemName: "heart.fill").font(.caption).foregroundStyle(Theme.hot) }
                    Spacer(minLength: 0)
                    Text("\(find.score)% match")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(find.score >= 80 ? Theme.green : find.score >= 60 ? Theme.accent : Theme.muted)
                }
                Text(item.title)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if let v = DealVerdict.of(item) { VerdictChip(verdict: v) }
                    Text([item.source, known ? item.priceLabel : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    if find.watching { Image(systemName: "eye.fill").font(.caption2).foregroundStyle(Theme.warn).accessibilityLabel("Watching") }
                }
                if AboutBlock.has(item, brand: expanded) { AboutBlock(item: item, brand: expanded, lines: expanded ? 6 : 2) }
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
            .font(.system(size: 9, weight: .bold).monospacedDigit())
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
            if ReminderSheet.upcoming(item) { releaseRow(item) }
            if !item.isProduct { infoRow(item) }
            if item.isProduct, let v = DealVerdict.of(item) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(v.emoji)
                    Text(v.title).font(.subheadline.weight(.bold)).foregroundStyle(v.tint)
                    Text(v.detail).font(.footnote).foregroundStyle(Theme.ink)
                }
            }
            if item.isProduct, let offers = item.offers, !offers.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("OTHER STORES").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted)
                    ForEach(offers.prefix(4), id: \.self) { o in
                        HStack {
                            Text(o.store).font(.footnote).foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer()
                            Text(Fmt.money(o.price)).font(.footnote.monospacedDigit()).foregroundStyle(known && o.price < item.price ? Theme.green : Theme.muted)
                        }
                    }
                }
            }
            if item.isProduct, let local = item.localPriceLabel {
                Label("\(local). Ships from outside the US, so duties or import fees may apply.", systemImage: "globe")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            if item.isProduct {
            HStack {
                priceCell("PRICE", known ? item.priceLabel : "See store", nil)
                priceCell("MARKET", known && item.market > 0 ? Fmt.money(item.market) : "—", nil)
                priceCell("SPREAD", known && item.market > 0 ? "\(diff > 0 ? "+" : "")\(pct)%" : "—", diff > 0 ? Theme.green : diff < 0 ? Theme.hot : nil)
            }
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Divider().overlay(Theme.line) }
            .overlay(alignment: .bottom) { Divider().overlay(Theme.line) }
            }

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
            HStack(spacing: 8) {
                chip(find.watching ? "eye.fill" : "eye", find.watching ? "Watching" : "Watch it for me", tint: find.watching ? Theme.warn : nil) {
                    store.toggleWatch(find.id)
                    if !find.watching { router.say("\(agent?.name ?? "Your scout") will text you on a price drop, restock or release") }
                }
                chip("bubble.left.and.text.bubble.right", "Ask about this") { router.sheet = .ask(find.id) }
            }
            if find.watching {
                Text("\(agent?.name ?? "Your scout") checks the price twice a day and texts you if it drops\(store.isSoldOut(item) ? ", or the moment it restocks" : !store.isLive(item) ? ", and at release" : "").")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Intel or a results page: what it is, and a way to read it.
    private func infoRow(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.isIntel ? "Intel from \(item.source): worth knowing, not a product to buy" : "A page of listings on \(item.source), not a single item",
                  systemImage: item.isIntel ? "newspaper" : "list.bullet.rectangle")
                .font(.footnote).foregroundStyle(Theme.ink)
            if let url = item.url.flatMap(URL.init(string:)) {
                chip("arrow.up.right", item.isIntel ? "Read it" : "See listings") { openURL(url) }
                    .accessibilityLabel(item.isIntel ? "Read it on \(item.source)" : "See the listings on \(item.source)")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Not out yet: when it releases, and a reminder you time yourself.
    private func releaseRow(_ item: Item) -> some View {
        let r = store.reminder(for: item)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "calendar").foregroundStyle(Theme.blue)
                Text("Releases \(ReminderSheet.fmt(item.dropAt!))").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                if item.tags.contains("limited") { Text("· Limited").font(.footnote.weight(.semibold)).foregroundStyle(Theme.hot) }
            }
            chip(r == nil ? "bell" : "bell.fill", r == nil ? "Remind me" : "Reminder · \(ReminderSheet.short(r!.remindAt))",
                 primary: r == nil, tint: r == nil ? nil : Theme.blue) { reminding = true }
                .accessibilityLabel(r == nil ? "Set a release reminder" : "Release reminder set. Tap to change")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func priceCell(_ label: String, _ value: String, _ tint: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(tint ?? Theme.ink)
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
                    router.say("\(agent?.name ?? "Your scout") will find more like this")
                }
                chip("xmark", "Pass") { askingWhy = true }
            }
            if item.isProduct && store.isSoldOut(item) && !item.isSample {
                // Sold out: offer to watch the store's page and text when it's back.
                let on = find.watching
                chip(on ? "bell.fill" : "bell", on ? "Watching" : "Notify me", tint: on ? Theme.warn : nil) {
                    store.toggleWatch(find.id)
                    router.say(on ? "Stopped watching this one" : "I'll check \(item.source) and text you the moment it's back")
                }
                .accessibilityLabel(on ? "Watching for a restock. Tap to stop" : "Notify me when it's back in stock")
            } else if ReminderSheet.upcoming(item) {
                let r = store.reminder(for: item)
                chip(r == nil ? "bell" : "bell.fill", r == nil ? "Remind me" : "Reminder set", tint: r == nil ? nil : Theme.blue) { reminding = true }
                    .accessibilityLabel(r == nil ? "Set a release reminder" : "Release reminder set. Tap to change")
            } else if !item.isProduct, let url = item.url.flatMap(URL.init(string:)) {
                chip("arrow.up.right", item.isIntel ? "Read" : "See listings") { openURL(url) }
                    .accessibilityLabel(item.isIntel ? "Read it on \(item.source)" : "See the listings on \(item.source)")
            } else if let link {
                chip("arrow.up.right", "Buy") {
                    Analytics.track(.checkoutOpened, ["category": item.category.rawValue, "toStore": true, "from": "find"])
                    router.buyOpened = find.id
                    openURL(BuyLink.tracked(item, from: "find") ?? link)
                }
                .accessibilityLabel("Buy at \(item.source)")
            }
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "trash").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .frame(width: 34, height: 34)
                    .background(Theme.glass, in: Circle())
            }
            .accessibilityLabel("Remove from Finds")
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
    /// The link to open: through Baget's "go" redirect when signed in (logs the tap and adds affiliate tracking
    /// when it's set up), else the store page itself. Only ever leads to the listing's own page.
    @MainActor static func tracked(_ item: Item, from source: String) -> URL? {
        guard let direct = url(item) else { return nil }
        let api = Backend.shared
        guard api.isSignedIn, let base = api.baseURL,
              item.id.range(of: #"^[0-9a-fA-F-]{36}$"#, options: .regularExpression) != nil,
              var c = URLComponents(url: base.appendingPathComponent("functions/v1/go"), resolvingAgainstBaseURL: false) else { return direct }
        c.queryItems = [URLQueryItem(name: "l", value: item.id), URLQueryItem(name: "s", value: source)]
            + (api.userID.map { [URLQueryItem(name: "u", value: $0)] } ?? [])
        return c.url ?? direct
    }

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
                if AboutBlock.has(item) { AboutBlock(item: item).glassCard() }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow { cell("Price", item.priceKnown ? item.priceLabel : "Not listed"); cell("Scout", a?.name ?? "—") }
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
                            openURL(BuyLink.tracked(item, from: "checkout") ?? link)
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
                            router.say(soldOut ? "Restock watch on" : "Got it. Your scout will ping you at release.")
                            dismiss()
                        }.buttonStyle(PrimaryButton())
                    } else if cloud {
                        Button("I bought it") {
                            let amount = item.priceKnown ? item.price : Double(amountText.replacingOccurrences(of: ",", with: "")) ?? 0
                            store.confirmPurchase(findID, amount: amount)
                            Analytics.track(.purchaseConfirmed, ["amount": amount, "category": item.category.rawValue, "score": f.score, "agentMode": a?.mode.rawValue ?? ""])
                            router.say("Logged and off your list. \(a?.name ?? "Your scout") will learn from it.")
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
        return caution + "You buy it at \(item.source); Baget never charges you. Tap \"I bought it\" afterwards so your scout learns from it."
    }

    private func blockReason(item: Item, agent a: Agent?, live: Bool, soldOut: Bool) -> String? {
        let name = a?.name ?? "Your scout"
        if soldOut { return "Sold out right now. \(name) will watch for a restock and tell you the moment it's back." }
        if !live { return "This isn't available yet. Your scout will hold your spot and ask again at release." }
        _ = a
        return nil
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.ink)
        }
    }
}


// MARK: - First-run tips

struct FindsTip {
    let icon: String
    let tint: Color
    let title: String
    let body: String
    static let all: [FindsTip] = [
        FindsTip(icon: "heart.fill", tint: Theme.hot, title: "Like teaches your scout",
                 body: "Tap Like on anything that's your taste. Your scout leans into that brand and style and finds more like it."),
        FindsTip(icon: "xmark", tint: Theme.accent, title: "Pass, and say why",
                 body: "Too pricey, wrong style, not your brand: every reason sharpens the next hunt. The more you react, the better it gets."),
        FindsTip(icon: "bell.fill", tint: Theme.warn, title: "Never miss a drop",
                 body: "On something not out yet, tap Remind me and pick when. On something sold out, tap Notify me and you'll get a text when it's back."),
    ]
}

/// Three quick tips above your first finds, one at a time.
struct FindsTipCard: View {
    @Binding var step: Int

    var body: some View {
        let i = min(step, FindsTip.all.count - 1)
        let tip = FindsTip.all[i]
        let last = i == FindsTip.all.count - 1
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: tip.icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(tip.tint)
                    .frame(width: 38, height: 38)
                    .background(tip.tint.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(tip.title).font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                    Text(tip.body).font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                ForEach(0..<FindsTip.all.count, id: \.self) { d in
                    Capsule().fill(d == i ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.line)).frame(width: d == i ? 16 : 6, height: 6)
                }
                Spacer()
                if !last {
                    Button("Skip") { withAnimation(.snappy) { step = FindsTip.all.count } }
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
                Button(last ? "Got it" : "Next") { withAnimation(.snappy) { step = i + 1 } }
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Theme.accent, in: Capsule())
            }
            if i < 2 {
                Label("Try it on a find below", systemImage: "arrow.down").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(14)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tip \(i + 1) of \(FindsTip.all.count): \(tip.title)")
    }
}
