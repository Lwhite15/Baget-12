import SwiftUI

/// One scout's finds (or a category's, for finds whose scout is gone).
private struct FindGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
    let agent: Agent?
    var finds: [Find]
    var newCount: Int { finds.filter { $0.status == .open }.count }
}

enum FindsShow: String, CaseIterable, Identifiable {
    // In the order the filter row shows them.
    case new = "New", saved = "Saved", upcoming = "Coming soon", all = "All"
    var id: String { rawValue }
}

enum FindsSort: String, CaseIterable, Identifiable {
    case best, newest, priceLow, priceHigh, scout
    var id: String { rawValue }
    var label: String {
        switch self {
        case .best: String(localized: "Best match")
        case .newest: String(localized: "Newest")
        case .priceLow: String(localized: "Price: low to high")
        case .priceHigh: String(localized: "Price: high to low")
        case .scout: String(localized: "By scout")
        }
    }
}

struct FindsView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @State private var show: FindsShow = .new
    @State private var collapsed: Set<String> = []
    @State private var highlighted: String?
    @State private var opened: String?
    @State private var sweeping = false
    @State private var confirmClear = false
    @AppStorage("baget.findsSort") private var sortRaw = FindsSort.best.rawValue
    @AppStorage("baget.findsGrid") private var grid = false
    /// The one-line tip: shown until dismissed (any value of 3 or more means done).
    @AppStorage("baget.findsTips") private var tipStep = 0

    private var sort: FindsSort { FindsSort(rawValue: sortRaw) ?? .best }

    /// A product that hasn't dropped yet (it has a release date still to come).
    static func comingSoon(_ item: Item) -> Bool { item.isProduct && (item.dropAt.map { $0 > .now } ?? false) }

    /// Passed and bought finds leave the screen; the agents still learn from them and never show them again.
    private var visible: [Find] { Self.filter(store.state.finds, show) }

    private static func filter(_ finds: [Find], _ show: FindsShow) -> [Find] {
        finds.filter { f in
            guard f.status == .open || f.status == .liked, Catalog.item(f.itemID)?.showsInFinds == true else { return false }
            switch show {
            case .all: return true
            case .new: return f.status == .open
            case .saved: return f.status == .liked || f.watching
            case .upcoming: return Catalog.item(f.itemID).map(comingSoon) == true
            }
        }
    }

    private func sorted(_ finds: [Find]) -> [Find] {
        func price(_ f: Find) -> Double? { Catalog.item(f.itemID).flatMap { $0.priceKnown && $0.price > 0 ? $0.price : nil } }
        return finds.sorted { a, b in
            switch sort {
            case .newest: return a.foundAt > b.foundAt
            case .priceLow, .priceHigh:
                switch (price(a), price(b)) {
                case let (x?, y?): return sort == .priceLow ? x < y : x > y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.score > b.score
                }
            case .best, .scout:
                // New first, then liked; strongest match first; newest first on ties.
                if (a.status == .open) != (b.status == .open) { return a.status == .open }
                if a.score != b.score { return a.score > b.score }
                return a.foundAt > b.foundAt
            }
        }
    }

    private var groups: [FindGroup] { groups(visible) }

    private func groups(_ visible: [Find]) -> [FindGroup] {
        var byKey: [String: FindGroup] = [:]
        var agents: [String: Agent] = [:]
        for a in store.state.agents { agents[a.id] = a }
        for f in visible {
            guard let item = Catalog.item(f.itemID) else { continue }
            let agent = agents[f.agentID]
            let key: String
            if let agent {
                key = agent.id
                byKey[key, default: FindGroup(id: key, title: agent.name, subtitle: agent.mission.label.capitalizedFirst,
                                              symbol: agent.mission.category?.info.symbol ?? customMissionInfo.symbol, agent: agent, finds: [])].finds.append(f)
            } else {
                key = item.category.rawValue
                byKey[key, default: FindGroup(id: key, title: item.category.info.label, subtitle: nil, symbol: item.category.info.symbol,
                                              agent: nil, finds: [])].finds.append(f)
            }
        }
        return byKey.values
            .map { g in var g = g; g.finds = sorted(g.finds); return g }
            .sorted { a, b in a.newCount != b.newCount ? a.newCount > b.newCount : a.title < b.title }
    }

    var body: some View {
        // One pass for the counts, one filter, one sort: the body runs whenever anything in the store changes.
        var newTotal = 0, savedTotal = 0, upcomingTotal = 0
        for f in store.state.finds where f.status == .open || f.status == .liked {
            guard let item = Catalog.item(f.itemID), item.showsInFinds else { continue }
            if f.status == .open { newTotal += 1 }
            if f.status == .liked || f.watching { savedTotal += 1 }
            if Self.comingSoon(item) { upcomingTotal += 1 }
        }
        let visible = self.visible
        // Grouped by scout for "Best match" and "By scout" in the list; one flat list otherwise, and always in the grid.
        let grouped = !grid && (sort == .best || sort == .scout)
        let flat = grouped ? [] : sorted(visible)
        let groups = grouped ? self.groups(visible) : []

        ScrollViewReader { proxy in
            ScrollView {
                // Lazy, so only the rows on screen are built, even with hundreds of finds.
                LazyVStack(alignment: .leading, spacing: 14) {
                    header(newTotal: newTotal)
                    filterRow(counts: [.new: newTotal, .saved: savedTotal, .upcoming: upcomingTotal])
                    toolsRow

                    if visible.isEmpty {
                        EmptyCard(text: emptyText)
                    } else if tipStep < 3 {
                        tip
                    }

                    if grid {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(flat) { f in FindTile(find: f) { opened = f.id }.id(f.id) }
                        }
                    } else if grouped {
                        ForEach(groups) { g in
                            sectionHeader(g)
                            if !collapsed.contains(g.id) {
                                ForEach(g.finds) { f in
                                    FindListRow(find: f, agent: g.agent, highlighted: highlighted == f.id) { opened = f.id }
                                        .id(f.id).padding(.top, -6)
                                }
                            }
                        }
                    } else {
                        ForEach(flat) { f in
                            FindListRow(find: f, highlighted: highlighted == f.id) { opened = f.id }.id(f.id).padding(.top, -6)
                        }
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
            .sheet(item: Binding(get: { opened.map { IdentifiedFind(id: $0) } }, set: { opened = $0?.id })) { x in
                FindDetailView(findID: x.id)
                    .environment(store).environment(router)
                    .presentationDetents([.large])
                    .presentationBackground(Theme.panel)
                    .preferredColorScheme(.dark)
            }
            .confirmationDialog(clearLabel + "?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("\(clearLabel) (\(self.visible.count))", role: .destructive) {
                    let gone = self.visible
                    let n = gone.count
                    store.removeFinds(gone.map(\.id))
                    router.say(n == 1 ? String(localized: "Cleared 1 find") : String(localized: "Cleared \(n) finds"))
                }
            } message: {
                Text("They leave Finds and your scouts won't show them again. What your scouts learned about your taste stays.")
            }
            .onChange(of: router.focusFind, initial: true) { _, id in
                guard let id else { return }
                // Show it: everything, its section open, scrolled to and opened.
                show = .all
                if let g = self.groups.first(where: { $0.finds.contains { $0.id == id } }) { collapsed.remove(g.id) }
                router.focusFind = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .top) }
                    withAnimation { highlighted = id }
                    opened = id
                    try? await Task.sleep(for: .seconds(2.2))
                    withAnimation(.easeOut(duration: 0.6)) { if highlighted == id { highlighted = nil } }
                }
            }
        }
    }

    /// New, Saved, Coming soon, All: one tap each, with counts.
    private func filterRow(counts: [FindsShow: Int]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(FindsShow.allCases) { f in
                    let n = counts[f] ?? 0
                    let label: String = {
                        switch f {
                        case .saved: return n > 0 ? String(localized: "♥ Saved · \(n)") : String(localized: "♥ Saved")
                        case .all: return String(localized: "All")
                        case .new: return n > 0 ? String(localized: "New · \(n)") : String(localized: "New")
                        case .upcoming: return n > 0 ? String(localized: "Coming soon · \(n)") : String(localized: "Coming soon")
                        }
                    }()
                    let on = show == f
                    Button { withAnimation(.snappy) { show = f } } label: {
                        Text(label)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(on ? Theme.accentInk : Theme.ink)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background { if on { Capsule().fill(Theme.gradient) } else { Capsule().fill(Theme.glass) } }
                            .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(show == f ? .isSelected : [])
                }
            }
        }
    }

    /// Sort, and list or grid.
    private var toolsRow: some View {
        HStack {
            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(FindsSort.allCases) { s in Text(s.label).tag(s.rawValue) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Sort:").foregroundStyle(Theme.muted)
                    Text(sort.label).fontWeight(.semibold).foregroundStyle(Theme.ink)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Theme.muted)
                }
                .font(.footnote)
            }
            Spacer()
            HStack(spacing: 0) {
                viewButton("list.bullet", on: !grid) { grid = false }
                viewButton("square.grid.2x2", on: grid) { grid = true }
            }
            .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
        }
    }

    private func viewButton(_ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            Image(systemName: icon).font(.footnote.weight(.semibold))
                .foregroundStyle(on ? Theme.cyan : Theme.muted)
                .frame(width: 36, height: 30)
                .background(on ? Theme.cyan.opacity(0.18) : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon == "list.bullet" ? String(localized: "List") : String(localized: "Grid"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var tip: some View {
        HStack(spacing: 8) {
            Image(systemName: "heart.fill").font(.caption).foregroundStyle(Theme.hot)
            Text("Tap the heart (or swipe right) to teach your scout").font(.footnote).foregroundStyle(Theme.ink.opacity(0.9))
            Spacer(minLength: 4)
            Button { withAnimation(.snappy) { tipStep = 3 } } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Theme.muted) }
                .buttonStyle(.plain).accessibilityLabel("Dismiss tip")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.hot.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hot.opacity(0.25)))
    }

    private var clearLabel: String {
        switch show {
        case .all: return String(localized: "Clear all")
        case .new: return String(localized: "Clear new")
        case .saved: return String(localized: "Clear saved")
        case .upcoming: return String(localized: "Clear coming soon")
        }
    }

    private var emptyText: String {
        if store.state.agents.isEmpty { return String(localized: "Set up a scout first, then tap Hunt now.") }
        switch show {
        case .new: return String(localized: "You're all caught up. Your squad keeps hunting in the background.")
        case .saved: return String(localized: "Nothing saved yet. Tap ♥ on a find you love, or watch one for price drops, and it shows up here.")
        case .all: return String(localized: "Nothing here yet. Tap Hunt now, or pull down on Today.")
        case .upcoming: return String(localized: "No drops coming up yet. When your scouts spot a release with a date, it lands here, and you can set a reminder for it.")
        }
    }

    private func header(newTotal: Int) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Finds").font(.system(size: 30, weight: .heavy)).tracking(-0.8).foregroundStyle(Theme.ink)
                Text("\(newTotal) new · \(store.state.agents.count) \(store.state.agents.count == 1 ? String(localized: "scout") : String(localized: "scouts")) hunting")
                    .font(.footnote).foregroundStyle(Theme.muted).lineLimit(1)
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
                    if res.found == 0 { router.say(String(localized: "Nothing new fits you right now")) }
                }
            } label: {
                Group {
                    if sweeping { ProgressView().tint(Theme.cyan) } else { Image(systemName: "arrow.clockwise").font(.body.weight(.semibold)).foregroundStyle(Theme.ink) }
                }
                .frame(width: 40, height: 40).background(Theme.glass, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
            }
            .buttonStyle(.plain)
            .disabled(sweeping)
            .accessibilityLabel("Hunt now")
            .accessibilityHint("Your scouts search again right now")
            // Clearing lives behind this menu (and asks first), so it can't be hit by accident.
            Menu {
                Section("Swipe a find left, or tap ✕, to pass on one") {
                    Button(role: .destructive) { confirmClear = true } label: { Label("\(clearLabel)…", systemImage: "trash") }
                        .disabled(visible.isEmpty)
                }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40).background(Theme.glass, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
            }
            .accessibilityLabel("More")
        }
        .padding(.top, 4)
    }

    private func sectionHeader(_ g: FindGroup) -> some View {
        let isCollapsed = collapsed.contains(g.id)
        return Button {
                withAnimation(.snappy) { if isCollapsed { collapsed.remove(g.id) } else { collapsed.insert(g.id) } }
            } label: {
                HStack(spacing: 10) {
                    Group {
                        if let a = g.agent { AgentAvatarView(agent: a, size: 30) }
                        else {
                            Image(systemName: g.symbol).font(.subheadline.weight(.bold)).foregroundStyle(Theme.accentInk)
                                .frame(width: 30, height: 30).background(Theme.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(g.title).font(.headline).foregroundStyle(Theme.ink).lineLimit(1)
                        if let s = g.subtitle { Text(s).font(.caption).foregroundStyle(Theme.muted).lineLimit(1) }
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
            .padding(.top, 6)
            .accessibilityLabel("\(g.title), \(g.finds.count) finds, \(g.newCount) new")
            .accessibilityHint(isCollapsed ? String(localized: "Expands the section") : String(localized: "Collapses the section"))
    }
}

private struct IdentifiedFind: Identifiable { let id: String }

/// What a find shows at a glance: price · store · match, and its state (sold out, drops soon, watching, reminder).
@MainActor private func findMeta(_ store: AppStore, _ find: Find, _ item: Item) -> Text {
    let known = item.priceKnown && item.price > 0
    var parts: [String] = [item.source]
    if known { parts.append(item.priceLabel) }
    var t = Text(parts.joined(separator: " · ")).foregroundColor(Theme.muted)
    t = t + Text(" · ").foregroundColor(Theme.muted)
        + Text("\(find.score)% match").foregroundColor(find.score >= 80 ? Theme.green : find.score >= 60 ? Theme.accent : Theme.muted).fontWeight(.semibold)
    if store.isSoldOut(item) { t = t + Text(" · ") .foregroundColor(Theme.muted) + Text("Sold out").foregroundColor(Theme.warn) }
    else if !store.isLive(item) { t = t + Text(" · ").foregroundColor(Theme.muted) + Text(store.whenLabel(item)).foregroundColor(Theme.blue) }
    return t
}

/// One find in the list: photo, title, price · store · match, one line on why; ♥ and ✕. Swipe right to like, left to pass.
struct FindListRow: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let find: Find
    /// Passed in when the list already knows it, so a row doesn't search the store while scrolling.
    var agent: Agent? = nil
    var highlighted = false
    let open: () -> Void
    @State private var dx: CGFloat = 0
    @State private var askingWhy = false
    /// Which way this drag is going, decided once at its start: a vertical one belongs to the scroll and is ignored.
    @State private var swiping: Bool?

    var body: some View {
        if let item = Catalog.item(find.itemID) {
            let agent = self.agent ?? store.agent(find.agentID)
            let discovery = find.why.contains { $0.hasPrefix("Discovery") }
            HStack(alignment: .center, spacing: 11) {
                ProductThumb(item: item, size: 66)
                    .overlay(alignment: .topLeading) {
                        if discovery { Circle().fill(Theme.cyan).frame(width: 11, height: 11).overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2)).offset(x: -3, y: -3).accessibilityLabel("New to you") }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2).multilineTextAlignment(.leading)
                    findMeta(store, find, item).font(.caption).lineLimit(1)
                    if let reason = find.why.first(where: { !$0.hasPrefix("Discovery") && !$0.isEmpty }) ?? find.why.first {
                        Text(reason).font(.caption).foregroundStyle(Theme.green.opacity(0.9)).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 6) {
                    if find.status == .liked {
                        roundButton("heart.fill", filled: false, tint: Theme.hot, label: String(localized: "Liked. Tap to unlike")) { store.unlike(find.id) }
                    } else {
                        roundButton("heart.fill", filled: true, tint: Theme.accentInk, label: String(localized: "Like")) { like(agent) }
                        roundButton("xmark", filled: false, tint: Theme.muted, label: String(localized: "Pass")) { askingWhy = true }
                    }
                    if find.watching { Image(systemName: "eye.fill").font(.caption2).foregroundStyle(Theme.warn).accessibilityLabel("Watching") }
                }
            }
            .padding(10)
            .background {
                ZStack(alignment: dx > 0 ? .leading : .trailing) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(highlighted ? Theme.accent.opacity(0.12) : Theme.glass)
                    if dx != 0 {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient(colors: [(dx > 0 ? Theme.green : Theme.hot).opacity(min(0.45, Double(abs(dx)) / 220)), .clear],
                                                 startPoint: dx > 0 ? .leading : .trailing, endPoint: dx > 0 ? .trailing : .leading))
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(highlighted ? Theme.accent.opacity(0.6) : Theme.line))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .offset(x: dx)
            .onTapGesture(perform: open)
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { v in
                        if swiping == nil { swiping = abs(v.translation.width) > abs(v.translation.height) * 1.6 }
                        guard swiping == true else { return }
                        dx = v.translation.width * 0.85
                    }
                    .onEnded { v in
                        let horizontal = swiping == true
                        swiping = nil
                        guard horizontal else { return }
                        let w = v.translation.width
                        if abs(w) > abs(v.translation.height) * 1.4, w > 100, find.status != .liked {
                            withAnimation(.snappy) { dx = 0 }
                            like(agent)
                        } else if abs(w) > abs(v.translation.height) * 1.4, w < -100 {
                            withAnimation(.easeIn(duration: 0.2)) { dx = -500 }
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(200))
                                store.pass(find.id, reason: .style)
                                Analytics.track(.findPassed, ["reason": "swipe", "category": item.category.rawValue])
                                router.say(String(localized: "Passed. \(agent?.name ?? "Your scout") is learning from that"))
                                dx = 0
                            }
                        } else {
                            withAnimation(.snappy) { dx = 0 }
                        }
                    }
            )
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Like") { like(agent) }
            .accessibilityAction(named: "Pass") { askingWhy = true }
            .confirmationDialog("What was off? \(agent?.name ?? "Your scout") will learn from it.", isPresented: $askingWhy, titleVisibility: .visible) {
                ForEach(AppStore.PassReason.allCases) { r in
                    Button(r.label) {
                        withAnimation(.snappy) { store.pass(find.id, reason: r) }
                        Analytics.track(.findPassed, ["reason": r.rawValue, "category": item.category.rawValue])
                        router.say(r == .later ? String(localized: "Passed") : String(localized: "Passed. \(agent?.name ?? "Your scout") is learning from that"))
                    }
                }
            }
        }
    }

    private func like(_ agent: Agent?) {
        withAnimation(.snappy) { store.like(find.id) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        router.say(String(localized: "\(agent?.name ?? "Your scout") will find more like this"))
    }

    private func roundButton(_ icon: String, filled: Bool, tint: Color, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.footnote.weight(.bold)).foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background { if filled { Circle().fill(Theme.gradient) } else { Circle().fill(Theme.glass) } }
                .overlay { if !filled { Circle().strokeBorder(Theme.line) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// One find in the grid: a big photo with its match, title, price · store, ♥ and ✕.
struct FindTile: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let find: Find
    let open: () -> Void
    @State private var askingWhy = false

    var body: some View {
        if let item = Catalog.item(find.itemID) {
            let agent = store.agent(find.agentID)
            VStack(alignment: .leading, spacing: 6) {
                Button(action: open) {
                    Plate(item: item, label: item.brand.isEmpty ? item.category.info.label : item.brand, height: 140)
                        .overlay(alignment: .topTrailing) {
                            Text("\(find.score)%").font(.caption2.weight(.heavy).monospacedDigit()).foregroundStyle(find.score >= 80 ? Theme.green : Theme.accent)
                                .padding(.horizontal, 6).padding(.vertical, 3).background(Theme.bg.opacity(0.85), in: Capsule()).padding(7)
                        }
                }
                .buttonStyle(.plain)
                Text(item.title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                Text([item.source, item.priceKnown && item.price > 0 ? item.priceLabel : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
                HStack(spacing: 6) {
                    if find.status == .liked {
                        pill("heart.fill", filled: false, tint: Theme.hot) { store.unlike(find.id) }.accessibilityLabel("Liked. Tap to unlike")
                    } else {
                        pill("heart.fill", filled: true, tint: Theme.accentInk) {
                            withAnimation(.snappy) { store.like(find.id) }
                            router.say(String(localized: "\(agent?.name ?? "Your scout") will find more like this"))
                        }.accessibilityLabel("Like")
                        pill("xmark", filled: false, tint: Theme.muted) { askingWhy = true }.accessibilityLabel("Pass")
                    }
                }
            }
            .confirmationDialog("What was off? \(agent?.name ?? "Your scout") will learn from it.", isPresented: $askingWhy, titleVisibility: .visible) {
                ForEach(AppStore.PassReason.allCases) { r in
                    Button(r.label) {
                        withAnimation(.snappy) { store.pass(find.id, reason: r) }
                        Analytics.track(.findPassed, ["reason": r.rawValue, "category": item.category.rawValue])
                    }
                }
            }
        }
    }

    private func pill(_ icon: String, filled: Bool, tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.footnote.weight(.bold)).foregroundStyle(tint)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background { if filled { Capsule().fill(Theme.gradient) } else { Capsule().fill(Theme.glass) } }
                .overlay { if !filled { Capsule().strokeBorder(Theme.line) } }
        }
        .buttonStyle(.plain)
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

/// A find on its own page: a big photo, why it's for you, what it is, prices, Buy, and everything else you can do.
struct FindDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    let findID: String
    @State private var askingWhy = false
    @State private var reminding = false
    @Environment(\.openURL) private var openURL

    private var find: Find? { store.state.finds.first { $0.id == findID } }

    var body: some View {
        if let find, let item = Catalog.item(find.itemID) {
            let agent = store.agent(find.agentID)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Spacer(); CloseButton { dismiss() } }
                    Plate(item: item, label: item.brand.isEmpty ? item.category.info.label : item.brand, height: 290)
                        .overlay(alignment: .topTrailing) {
                            Text("\(find.score)% MATCH").font(.caption2.weight(.heavy)).tracking(0.6)
                                .foregroundStyle(find.score >= 80 ? Theme.green : Theme.accent)
                                .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.bg.opacity(0.85), in: Capsule()).padding(10)
                        }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.title3.weight(.heavy)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                        (Text(item.priceKnown && item.price > 0 ? item.priceLabel : String(localized: "Price at store")).font(.headline).foregroundColor(Theme.ink)
                         + Text(" · \(item.source)\(agent.map { " · " + String(localized: "from \($0.name)") } ?? "")").font(.subheadline).foregroundColor(Theme.muted))
                    }
                    if let reason = find.why.first, !reason.isEmpty {
                        Label { Text(reason).font(.subheadline).foregroundStyle(Theme.green.opacity(0.95)).fixedSize(horizontal: false, vertical: true) } icon: {
                            Image(systemName: "heart.fill").foregroundStyle(Theme.green)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.green.opacity(0.25)))
                    }
                    if AboutBlock.has(item, brand: true) { AboutBlock(item: item, brand: true) }
                    actions(find, item: item, agent: agent)
                    details(find, item, agent: agent)
                }
                .padding(.horizontal, 18).padding(.bottom, 30).padding(.top, 10)
            }
            .scrollIndicators(.hidden)
            .sheet(isPresented: $reminding) {
                ReminderSheet(item: item, findID: findID)
                    .environment(store).environment(router)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Theme.panel)
                    .preferredColorScheme(.dark)
            }
            .confirmationDialog("What was off? \(agent?.name ?? "Your scout") will learn from it.", isPresented: $askingWhy, titleVisibility: .visible) {
                ForEach(AppStore.PassReason.allCases) { r in
                    Button(r.label) {
                        store.pass(findID, reason: r)
                        Analytics.track(.findPassed, ["reason": r.rawValue, "category": item.category.rawValue])
                        router.say(r == .later ? String(localized: "Passed") : String(localized: "Passed. \(agent?.name ?? "Your scout") is learning from that"))
                        dismiss()
                    }
                }
            }
        } else {
            VStack(spacing: 12) {
                HStack { Spacer(); CloseButton { dismiss() } }
                Spacer()
                Text("This find isn't here anymore.").foregroundStyle(Theme.muted)
                Spacer()
            }
            .padding(18)
        }
    }

    // MARK: Expanded details

    @ViewBuilder private func details(_ find: Find, _ item: Item, agent: Agent?) -> some View {
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
                priceCell("PRICE", known ? item.priceLabel : String(localized: "See store"), nil)
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
                        Text("WHY YOUR SCOUT PICKED IT").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted)
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
            if find.watching {
                Text("\(agent?.name ?? "Your scout") checks the price twice a day and texts you if it drops\(store.isSoldOut(item) ? ", or the moment it restocks" : !store.isLive(item) ? ", and at release" : "").")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    /// Intel or a results page: what it is, and a way to read it.
    private func infoRow(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.isIntel ? String(localized: "Intel from \(item.source): worth knowing, not a product to buy") : String(localized: "A page of listings on \(item.source), not a single item"),
                  systemImage: item.isIntel ? "newspaper" : "list.bullet.rectangle")
                .font(.footnote).foregroundStyle(Theme.ink)
            if let url = item.url.flatMap(URL.init(string:)) {
                chip("arrow.up.right", item.isIntel ? "Read it" : "See listings") { openURL(url) }
                    .accessibilityLabel(item.isIntel ? String(localized: "Read it on \(item.source)") : String(localized: "See the listings on \(item.source)"))
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
            chip(r == nil ? "bell" : "bell.fill", r == nil ? String(localized: "Remind me") : "Reminder · \(ReminderSheet.short(r!.remindAt))",
                 primary: r == nil, tint: r == nil ? nil : Theme.blue) { reminding = true }
                .accessibilityLabel(r == nil ? String(localized: "Set a release reminder") : String(localized: "Release reminder set. Tap to change"))
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

    @ViewBuilder private func actions(_ find: Find, item: Item, agent: Agent?) -> some View {
        let link = BuyLink.url(item)
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if item.isProduct && store.isSoldOut(item) && !item.isSample {
                    // Sold out: watch the store's page and get a text when it's back.
                    let on = find.watching
                    bigButton(on ? "bell.fill" : "bell", on ? String(localized: "Watching for a restock") : String(localized: "Notify me when it's back"), primary: !on) {
                        store.toggleWatch(find.id)
                        router.say(on ? String(localized: "Stopped watching this one") : String(localized: "I'll check \(item.source) and text you the moment it's back"))
                    }
                } else if ReminderSheet.upcoming(item) {
                    let r = store.reminder(for: item)
                    bigButton(r == nil ? "bell" : "bell.fill", r == nil ? String(localized: "Remind me") : String(localized: "Reminder set"), primary: r == nil) { reminding = true }
                } else if let link {
                    bigButton("arrow.up.right", String(localized: "Buy at \(item.source)"), primary: true) {
                        Analytics.track(.checkoutOpened, ["category": item.category.rawValue, "toStore": true, "from": "find"])
                        router.buyOpened = find.id
                        openURL(BuyLink.tracked(item, from: "find") ?? link)
                    }
                }
                if find.status == .liked {
                    bigButton("heart.fill", String(localized: "Liked"), primary: false, tint: Theme.hot) { store.unlike(find.id) }
                } else {
                    bigButton("heart", String(localized: "Like"), primary: link == nil && !ReminderSheet.upcoming(item)) {
                        store.like(find.id)
                        router.say(String(localized: "\(agent?.name ?? "Your scout") will find more like this"))
                    }
                }
            }
            HStack(spacing: 0) {
                small(find.watching ? "eye.fill" : "eye", find.watching ? String(localized: "Watching") : String(localized: "Watch price"), tint: find.watching ? Theme.warn : nil) {
                    store.toggleWatch(find.id)
                    if !find.watching { router.say(String(localized: "\(agent?.name ?? "Your scout") will text you on a price drop, restock or release")) }
                }
                small("bubble.left.and.text.bubble.right", String(localized: "Ask scout")) { router.sheet = .ask(find.id) }
                small("square.and.arrow.up", String(localized: "Share")) { router.sheet = .share(itemID: item.id, friendID: nil, suggestion: false) }
                if find.status == .open { small("xmark", String(localized: "Pass")) { askingWhy = true } }
                else { small("trash", String(localized: "Remove")) { withAnimation { store.removeFinds([find.id]) }; router.say(String(localized: "Removed")); dismiss() } }
            }
            if find.watching {
                Text("\(agent?.name ?? "Your scout") checks the price twice a day and texts you if it drops\(store.isSoldOut(item) ? ", or the moment it restocks" : !store.isLive(item) ? ", and at release" : "").")
                    .font(.caption).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func bigButton(_ icon: String, _ text: String, primary: Bool, tint: Color? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: icon).labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.heavy)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(primary ? Theme.accentInk : (tint ?? Theme.ink))
                .frame(maxWidth: .infinity).frame(height: 48)
                .background { if primary { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.gradient) } else { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.glass) } }
                .overlay { if !primary { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line) } }
        }
        .buttonStyle(.plain)
    }

    private func small(_ icon: String, _ text: String, tint: Color? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.subheadline)
                Text(text).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint ?? Theme.muted)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
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
                    GridRow { cell(String(localized: "Price"), item.priceKnown ? item.priceLabel : String(localized: "Not listed")); cell(String(localized: "Scout"), a?.name ?? "—") }
                    GridRow {
                        cell(item.category.info.sizeRequired ? (item.category.info.sizeLabel ?? String(localized: "Size")) : String(localized: "Category"),
                             item.category.info.sizeRequired ? (a?.size.isEmpty == false ? a!.size : String(localized: "Any")) : item.category.info.label)
                        cell(String(localized: "Store"), item.source.isEmpty ? "—" : item.source)
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
                    Text(block ?? String(localized: "Sample checkout. No card is charged."))
                        .font(.subheadline).foregroundStyle(Theme.muted)
                }
                Spacer()
                HStack {
                    Button("Cancel") { dismiss() }.buttonStyle(GhostButton())
                    if soldOut || !live {
                        Button(soldOut ? String(localized: "Watch for restock") : String(localized: "Remind me at release")) {
                            store.watch(findID)
                            Analytics.track(.findWatched, ["category": item.category.rawValue])
                            router.say(soldOut ? String(localized: "Restock watch on") : String(localized: "Got it. Your scout will ping you at release."))
                            dismiss()
                        }.buttonStyle(PrimaryButton())
                    } else if cloud {
                        Button("I bought it") {
                            let amount = item.priceKnown ? item.price : Double(amountText.replacingOccurrences(of: ",", with: "")) ?? 0
                            store.confirmPurchase(findID, amount: amount)
                            Analytics.track(.purchaseConfirmed, ["amount": amount, "category": item.category.rawValue, "score": f.score, "agentMode": a?.mode.rawValue ?? ""])
                            router.say(String(localized: "Logged and off your list. \(a?.name ?? "Your scout") will learn from it."))
                            dismiss()
                        }
                        .buttonStyle(GhostButton())
                        .disabled(!item.priceKnown && (Double(amountText.replacingOccurrences(of: ",", with: "")) ?? 0) <= 0)
                    } else if block == nil {
                        Button("Confirm purchase") {
                            store.confirmPurchase(findID)
                            Analytics.track(.purchaseConfirmed, ["amount": item.price, "category": item.category.rawValue, "score": f.score, "agentMode": a?.mode.rawValue ?? ""])
                            router.say(String(localized: "Bought. It's off your list."))
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
        let caution = block.map { String(localized: "Heads up: \($0) ") } ?? ""
        return caution + String(localized: "You buy it at \(item.source); Baget never charges you. Tap \"I bought it\" afterwards so your scout learns from it.")
    }

    private func blockReason(item: Item, agent a: Agent?, live: Bool, soldOut: Bool) -> String? {
        let name = a?.name ?? String(localized: "Your scout")
        if soldOut { return String(localized: "Sold out right now. \(name) will watch for a restock and tell you the moment it's back.") }
        if !live { return String(localized: "This isn't available yet. Your scout will hold your spot and ask again at release.") }
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
        FindsTip(icon: "heart.fill", tint: Theme.hot, title: String(localized: "Like teaches your scout"),
                 body: String(localized: "Tap Like on anything that's your taste. Your scout leans into that brand and style and finds more like it.")),
        FindsTip(icon: "xmark", tint: Theme.accent, title: String(localized: "Pass, and say why"),
                 body: String(localized: "Too pricey, wrong style, not your brand: every reason sharpens the next hunt. The more you react, the better it gets.")),
        FindsTip(icon: "bell.fill", tint: Theme.warn, title: String(localized: "Never miss a drop"),
                 body: String(localized: "On something not out yet, tap Remind me and pick when. On something sold out, tap Notify me and you'll get a text when it's back.")),
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
                Button(last ? String(localized: "Got it") : String(localized: "Next")) { withAnimation(.snappy) { step = i + 1 } }
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
