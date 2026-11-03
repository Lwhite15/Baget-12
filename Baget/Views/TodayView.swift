import SwiftUI

/// The home screen: today's finds as a swipe deck (or a grid, for people who'd rather tap), then an endless For You.
struct TodayView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    /// "cards" (the swipe deck) or "grid". Remembered on this phone.
    @AppStorage("baget.todayLayout") private var layout = "cards"
    /// Today's finds, fixed while you go through them so cards don't jump as likes and passes land.
    @State private var deckIDs: [String] = []
    @State private var deckIndex = 0
    @State private var showTop = false

    private func freshDeck() -> [String] {
        var seen = Set<String>()
        return (store.todaysPicks(TodayDeck.size) + store.swipeQueue).map(\.id).filter { seen.insert($0).inserted }.prefix(TodayDeck.size).map { $0 }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy, so the greeting's onDisappear tells us when to offer "back to top".
                LazyVStack(alignment: .leading, spacing: 20) {
                    header
                        .id("today-top")
                        .onAppear { withAnimation { showTop = false } }
                        .onDisappear { withAnimation { showTop = true } }
                    if store.plan?.pro != true { PlanStatusPill() }
                    // New scout sits above today's finds (the full confirmation right after sending one).
                    if router.scoutSent != nil { NewScoutCard() } else { NewScoutCard(compact: true) }
                    if store.isCloud && !store.state.agents.isEmpty && store.state.finds.isEmpty { firstHuntCard }
                    if !deckIDs.isEmpty {
                        if layout == "grid" { todayGrid } else { TodayDeck(ids: deckIDs, index: $deckIndex) }
                    }
                    ForYouSection(mode: .today, exclude: Set(deckIDs.compactMap { id in store.state.finds.first { $0.id == id }?.itemID }))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .dismissKeyboardOnTap()
            .refreshable { await store.refreshNow(router: router); deckIDs = freshDeck(); deckIndex = 0 }
            .overlay(alignment: .bottomTrailing) {
                if showTop {
                    Button { withAnimation(.snappy) { proxy.scrollTo("today-top", anchor: .top) } } label: {
                        Image(systemName: "arrow.up").font(.body.weight(.heavy)).foregroundStyle(Theme.accentInk)
                            .frame(width: 46, height: 46).background(Theme.gradient, in: Circle())
                            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 18).padding(.bottom, 14)
                    .accessibilityLabel("Back to top")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .onChange(of: router.todayTop) { withAnimation(.snappy) { proxy.scrollTo("today-top", anchor: .top) } }
        }
        .onAppear {
            if deckIDs.isEmpty || deckIndex >= deckIDs.count { deckIDs = freshDeck(); deckIndex = 0 }
            Analytics.track(.todayViewed, ["toSwipe": deckIDs.count, "layout": layout])
        }
        .onChange(of: store.state.finds.count) { if deckIDs.isEmpty { deckIDs = freshDeck(); deckIndex = 0 } }
    }

    /// The greeting, with the cards / grid switch beside it.
    private var header: some View {
        HStack(alignment: .bottom) {
            greeting
            Spacer(minLength: 8)
            if !deckIDs.isEmpty {
                HStack(spacing: 0) {
                    layoutButton("rectangle.portrait", "cards", String(localized: "Swipe cards"))
                    layoutButton("square.grid.2x2", "grid", String(localized: "Grid"))
                }
                .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                .padding(.bottom, 2)
            }
        }
    }

    private func layoutButton(_ icon: String, _ value: String, _ label: String) -> some View {
        let on = layout == value
        return Button {
            guard !on else { return }
            withAnimation(.snappy) { layout = value }
            Analytics.track(.todayLayout, ["layout": value])
        } label: {
            Image(systemName: icon).font(.footnote.weight(.semibold))
                .foregroundStyle(on ? Theme.cyan : Theme.muted)
                .frame(width: 36, height: 30)
                .background(on ? Theme.cyan.opacity(0.18) : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Grid mode: today's finds as tiles, with ♥ and ✕ on each. No swiping.
    private var todayGrid: some View {
        let finds = deckIDs.compactMap { id in store.state.finds.first { $0.id == id && ($0.status == .open || $0.status == .liked) } }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Today's finds").font(.title3.weight(.heavy)).foregroundStyle(Theme.ink)
            if finds.isEmpty {
                Text("You've been through today's finds. More for you below.").font(.footnote).foregroundStyle(Theme.muted)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(finds) { f in FindTile(find: f) { router.focusFind = f.id; router.tab = .finds } }
                }
            }
        }
    }

    private var greeting: some View {
        let h = Calendar.current.component(.hour, from: .now)
        let hello = h < 12 ? String(localized: "Good morning") : h < 17 ? String(localized: "Good afternoon") : String(localized: "Good evening")
        let name = store.state.profile?.displayName.split(separator: " ").first.map(String.init)
        return VStack(alignment: .leading, spacing: 3) {
            Text(name.map { "\(hello), \($0)" } ?? hello)
                .font(.system(size: 28, weight: .heavy)).tracking(-0.6).foregroundStyle(Theme.ink)
            Text("\(store.state.agents.count) \(store.state.agents.count == 1 ? String(localized: "scout") : String(localized: "scouts")) hunting for you · \(Date.now.formatted(.dateTime.weekday(.wide).month().day()))")
                .font(.footnote).foregroundStyle(Theme.muted)
        }
        .padding(.top, 4)
    }

    /// Until the first finds land: who's out hunting, so a new account never looks idle.
    /// When the first hunt started (kept on this phone), so a scout that's still empty after an hour says why.
    @AppStorage("baget.firstHuntStarted") private var firstHuntStarted: Double = 0

    @ViewBuilder private var firstHuntCard: some View {
        let waited = firstHuntStarted > 0 ? Date.now.timeIntervalSince1970 - firstHuntStarted : 0
        if waited > 3600, let a = store.state.agents.first(where: { !$0.isOff }) {
            emptyHuntCard(a)
        } else {
            huntingCard
                .onAppear { if firstHuntStarted == 0 { firstHuntStarted = Date.now.timeIntervalSince1970 } }
                // Check for the first finds on its own (every 10 seconds, up to 5 minutes), so the card goes away
                // the moment they land instead of waiting for a pull-down.
                .task {
                    for _ in 0..<30 {
                        try? await Task.sleep(for: .seconds(10))
                        if Task.isCancelled || !store.state.finds.isEmpty { break }
                        await store.pull()
                    }
                }
        }
    }

    /// Nothing yet after an hour: say why, with a one-tap fix, instead of an endless spinner.
    private func emptyHuntCard(_ first: Agent) -> some View {
        let noSize = store.state.agents.first { !$0.isOff && Sizes.required($0) && !Sizes.has($0) }
        let a = noSize ?? first
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentAvatarView(agent: a, size: 30)
                Text("Nothing worth showing you yet").font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
            }
            Text(noSize != nil
                 ? String(localized: "\(a.name) only flags \(a.mission.category == .sneakers ? "pairs" : "pieces") in stock in your size, and it doesn't know yours yet.")
                 : String(localized: "\(a.name) is being picky so you only see good matches. A brand, model or budget gives it much more to go on."))
                .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(noSize != nil ? String(localized: "Add your size") : String(localized: "Tell \(a.name) more")) { router.sheet = .chat(a.id) }
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.gradient, in: Capsule())
                Button("Hunt again now") { Task { await store.refreshNow(router: router) } }
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.warn.opacity(0.3)))
    }

    private var huntingCard: some View {
        HStack(spacing: 12) {
            HStack(spacing: -8) {
                ForEach(store.state.agents.prefix(4)) { a in AgentAvatarView(agent: a, size: 30).overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2)) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Your squad's first hunt is on").font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                Text("Finds usually land within a few minutes. Pull down to check.").font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            ProgressView().tint(Theme.cyan)
        }
        .padding(12)
        .background(Theme.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.green.opacity(0.3)))
    }

}

/// "For You": always-on personal picks. Ranked by what you like, refreshed daily, sharpened by every heart and X.
enum ForYouMode { case today, full }

struct ForYouSection: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL
    @State private var limit = 24
    @State private var category: Category?
    /// Today: a short preview (6, nothing already in Today's Drop) with "See all". Full: everything, with filters.
    var mode: ForYouMode = .full
    var exclude: Set<String> = []

    var body: some View {
        let all = store.forYou.filter { Catalog.item($0.id) != nil && !exclude.contains($0.id) }
        let cats = Array(Set(all.compactMap { Catalog.item($0.id)?.category })).sorted { $0.info.label < $1.info.label }
        let filtered = all.filter { p in category.map { Catalog.item(p.id)?.category == $0 } ?? true }
        let picks = filtered
        VStack(alignment: .leading, spacing: 12) {
            if mode == .today {
                // Today: one endless feed, filters at the top, more loading as you reach the bottom.
                Text("More for you").font(.title3.weight(.heavy)).foregroundStyle(Theme.ink)
                Text("Ranked by your taste. Every ♥ and ✕ sharpens it.").font(.caption).foregroundStyle(Theme.muted)
                if cats.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            filterChip(nil, String(localized: "All"))
                            ForEach(cats, id: \.self) { c in filterChip(c, c.info.label) }
                        }
                    }
                }
            } else {
                Text("Picked from everything Baget's scouts have found, ranked by your taste. Every ♥ and ✕ sharpens it.")
                    .font(.caption).foregroundStyle(Theme.muted)
                if !store.tasteTop.isEmpty { tasteStrip }
                if cats.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            filterChip(nil, String(localized: "All"))
                            ForEach(cats, id: \.self) { c in filterChip(c, c.info.label) }
                        }
                    }
                }
            }

            if picks.isEmpty {
                if store.forYouLoadedAt == nil {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.glass).frame(height: 230)
                        }
                    }
                } else {
                    starter
                }
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(picks) { p in
                        if let item = Catalog.item(p.id) { card(p, item) }
                    }
                }
                if mode == .today {
                    // Reaching the bottom loads the next batch, until there's nothing more for now.
                    if store.forYou.count >= limit - 4 && limit < Self.maxToday {
                        HStack(spacing: 8) { ProgressView().tint(Theme.cyan); Text("Loading more picks…").font(.caption).foregroundStyle(Theme.muted) }
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            // A task (not onAppear) so it waits out a load already running, then loads the next batch.
                            .task(id: limit) {
                                while store.forYouLoading { try? await Task.sleep(for: .milliseconds(300)) }
                                guard !Task.isCancelled, store.forYou.count >= limit - 4, limit < Self.maxToday else { return }
                                limit = min(Self.maxToday, limit + 24)
                                await store.loadForYou(limit: limit)
                            }
                    } else {
                        Text("That's everything for now. Pull down any time to check for more.")
                            .font(.caption).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.top, 4)
                    }
                } else if store.forYou.count >= limit - 2 && limit < 120 {
                    Button {
                        limit = min(120, limit + 24)
                        Task { await store.loadForYou(limit: limit) }
                    } label: { Text("Show more").frame(maxWidth: .infinity) }
                    .buttonStyle(GhostButton())
                }
            }
        }
        .task {
            if store.forYouLoadedAt == nil || store.forYouLoadedAt! < .now.addingTimeInterval(-180) || store.forYou.isEmpty {
                await store.loadForYou(limit: limit)
            }
        }
        .onChange(of: store.state.accountID) { Task { await store.loadForYou(limit: limit) } }
    }

    private var columns: [GridItem] { [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)] }
    /// How far Today's endless feed goes (the server's cap).
    static let maxToday = 200

    private func filterChip(_ c: Category?, _ label: String) -> some View {
        let on = category == c
        return Button { withAnimation(.snappy) { category = c } } label: {
            Text(label).font(.footnote.weight(.semibold))
                .foregroundStyle(on ? Theme.accentInk : Theme.ink)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background { if on { Capsule().fill(Theme.gradient) } else { Capsule().fill(Theme.glass) } }
                .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.line))
        }
        .buttonStyle(.plain)
    }

    /// What the ranking has learned, strongest first. Tap to see and edit everything Baget knows.
    private var tasteStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.tasteTop) { t in
                    Button { router.sheet = .taste } label: {
                        HStack(spacing: 4) {
                            Image(systemName: t.likes ? "heart.fill" : "xmark").font(.system(size: 9, weight: .bold))
                            Text(t.label).font(.caption.weight(.medium)).lineLimit(1)
                        }
                        .foregroundStyle(t.likes ? Theme.green : Theme.hot)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill((t.likes ? Theme.green : Theme.hot).opacity(0.13)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .accessibilityLabel("What Baget has learned about your taste")
    }

    private func card(_ p: ForYouItem, _ item: Item) -> some View {
        let known = item.priceKnown && item.price > 0
        return VStack(alignment: .leading, spacing: 6) {
            Button { open(p, item) } label: {
                Plate(item: item, label: item.brand.isEmpty ? item.category.info.label : item.brand, height: 150)
            }
            .buttonStyle(.plain)
            Text(item.title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink)
                .lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            Text([known ? item.priceLabel : nil, item.source].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
            Text(item.about ?? " ").font(.caption2).foregroundStyle(Theme.ink.opacity(0.8))
                .lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 26, alignment: .topLeading)
                .accessibilityHidden(item.about == nil)
            HStack(spacing: 4) {
                Image(systemName: p.kind == "explore" ? "sparkles" : p.kind == "yours" ? "tray.full" : "wand.and.stars")
                    .font(.system(size: 9, weight: .bold))
                Text(p.reason).lineLimit(1)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(p.kind == "explore" ? Theme.cyan : Theme.green)
            HStack(spacing: 8) {
                // ✕ left, ♥ right: the same way you swipe.
                Button { withAnimation(.snappy) { store.reactForYou(p, .dismiss) }; router.say(String(localized: "Got it, fewer like this")) } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(Theme.glass, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.line))
                }
                .accessibilityLabel("Not for me")
                Button {
                    withAnimation(.snappy) { store.reactForYou(p, .like) }
                    router.say(store.state.agents.isEmpty ? String(localized: "Liked. Baget will show more like this") : String(localized: "Saved to Finds. More like this coming"))
                } label: {
                    Image(systemName: "heart.fill").font(.footnote.weight(.bold)).foregroundStyle(Theme.accentInk)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(Theme.gradient, in: Capsule())
                }
                .accessibilityLabel("Like")
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button { store.reactForYou(p, .like) } label: { Label("Like", systemImage: "heart") }
            if BuyLink.url(item) != nil { Button { open(p, item) } label: { Label("Open at \(item.source)", systemImage: "arrow.up.right") } }
            Button(role: .destructive) { store.reactForYou(p, .dismiss) } label: { Label("Not for me", systemImage: "xmark") }
        }
    }

    private func open(_ p: ForYouItem, _ item: Item) {
        if let fid = p.findID { router.focusFind = fid; router.tab = .finds; return }
        guard let url = BuyLink.tracked(item, from: "for_you") else { router.say(String(localized: "No store page for this one yet")); return }
        store.reactForYou(p, .open)
        openURL(url)
    }

    /// Only when Baget has nothing at all to show yet (a brand-new account before any agent has searched).
    private var starter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tell Baget what you're into and this fills up with picks for you.")
                .font(.subheadline).foregroundStyle(Theme.ink)
            FlowRow {
                ForEach([Category.sneakers, .fragrance, .watches, .apparel, .furniture, .cars], id: \.self) { c in
                    Button { router.deployPrefill = .category(c); router.sheet = .deploy } label: { Tag(text: c.info.label, tint: Theme.accent) }
                        .buttonStyle(.plain)
                }
            }
        }
        .glassCard()
    }
}

extension AppStore {
    /// Pull to refresh: re-sync (signed in) or run a sample sweep.
    func refreshNow(router: Router) async {
        defer { Task { await loadForYou() } }
        if isCloud {
            await pull()
        } else {
            let res = sweep()
            Analytics.track(.sweepRun, ["found": res.found, "manual": true])
            router.say(res.found > 0 ? String(localized: "\(res.found) new \(res.found == 1 ? String(localized: "find") : String(localized: "finds"))") : String(localized: "Nothing new fits you right now"))
        }
    }
}


extension View {
    /// Scrolling, or a tap anywhere outside a text field, puts the keyboard away.
    func dismissKeyboardOnTap() -> some View {
        self.scrollDismissesKeyboard(.immediately)
            .simultaneousGesture(TapGesture().onEnded {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            })
    }
}
