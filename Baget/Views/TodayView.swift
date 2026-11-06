import SwiftUI

/// The home screen: the morning drop. What changed on things you watched, what's releasing today,
/// then each scout's 3 best of the day. It ends, so it feels done; everything else lives in Finds.
struct TodayView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @State private var showTop = false
    /// "cards" (swipe through the drop) or "list" (each scout's picks in rows). Remembered on this phone.
    @AppStorage("baget.todayLayout") private var layout = "cards"
    /// The deck, fixed while you go through it (new picks join at the end).
    @State private var deck: [DeckCard] = []
    @State private var deckIndex = 0
    /// After the drop: "Keep swiping" through more picks.
    @State private var endless = false
    @State private var more: [DeckCard] = []
    @State private var moreIndex = 0
    @AppStorage("baget.likedToday") private var likedToday = ""

    private var cardsMode: Bool {
        layout == "cards" && router.scoutSent == nil && !(store.isCloud && !store.state.agents.isEmpty && store.state.finds.isEmpty)
    }

    var body: some View {
        Group {
            if cardsMode { cardsBody } else { listBody }
        }
        .task { await store.loadDrop() }
        .onAppear { syncDeck() }
        .onChange(of: store.drop) { syncDeck() }
        .onChange(of: store.state.finds.count) { if deck.isEmpty { syncDeck() } }
        // Coming back to the app after the drop time: today's drop appears without a pull-down.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await store.loadDrop() }
        }
        .onAppear {
            Analytics.track(.todayViewed, ["toSwipe": deck.count, "layout": layout])
        }
    }

    /// Swipe cards: open the app and you're swiping. Payoffs, releases, the day's picks, then Keep swiping.
    private var cardsBody: some View {
        let dropFinds = deck.compactMap { c -> Find? in
            switch c { case .pick(let f), .release(let f, _, _): return store.state.finds.first { $0.id == f.id }; default: return nil }
        }
        let reminders = deck.compactMap { c -> Item? in if case .release(_, let i, _) = c { return i }; return nil }.filter { store.reminder(for: $0) != nil }.count
        return VStack(alignment: .leading, spacing: 10) {
            greeting
            HStack(spacing: 8) {
                modeChip
                Spacer(minLength: 6)
                Text(endless ? String(localized: "♥ \(likedCount) today")
                     : deckIndex < deck.count ? String(localized: "\(deckIndex + 1) of \(deck.count)") : "")
                    .font(.footnote.weight(.bold).monospacedDigit()).foregroundStyle(Theme.muted)
                layoutSwitch
            }
            if !endless && !deck.isEmpty { progressBar(Double(min(deckIndex, deck.count)) / Double(max(1, deck.count))) }
            if endless {
                if moreIndex < more.count {
                    DropDeckView(cards: more, index: $moreIndex)
                        .onChange(of: moreIndex) { _, i in
                            countLike()
                            if more.count - i < 6 { Task { await store.loadForYou(limit: min(200, store.forYou.count + 40)); topUpMore() } }
                        }
                } else {
                    outOfPicks
                }
            } else if deckIndex < deck.count {
                DropDeckView(cards: deck, index: $deckIndex)
            } else if deck.isEmpty {
                waitingCard
                Spacer(minLength: 0)
            } else {
                DropFinishedCard(liked: dropFinds.filter { $0.status == .liked }.count,
                                 passed: dropFinds.filter { $0.status == .passed }.count,
                                 reminders: reminders,
                                 morePicks: store.keepSwipingPool(excluding: Set(dropFinds.map(\.itemID))).count) { startEndless() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .task { if store.forYou.isEmpty { await store.loadForYou(limit: 60) } }
    }

    private var modeChip: some View {
        Label(endless ? String(localized: "KEEP SWIPING") : String(localized: "TODAY'S DROP"), systemImage: endless ? "infinity" : "sun.max.fill")
            .font(.caption.weight(.heavy))
            .foregroundStyle(endless ? Theme.accent : Theme.warn)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background((endless ? Theme.accent : Theme.warn).opacity(0.14), in: Capsule())
            .onTapGesture { if endless { withAnimation(.snappy) { endless = false } } }
    }

    private var layoutSwitch: some View {
        HStack(spacing: 0) {
            layoutButton("rectangle.portrait", "cards", String(localized: "Swipe cards"))
            layoutButton("list.bullet", "list", String(localized: "List"))
        }
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
    }

    private func progressBar(_ f: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.glass)
                Capsule().fill(Theme.gradient).frame(width: max(6, g.size.width * f))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    /// No drop yet (no finds, or before the first one is made).
    private var waitingCard: some View {
        let h = store.drop?.hour ?? store.state.settings.dropHour ?? 9
        let time = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now)?.formatted(date: .omitted, time: .shortened) ?? "9 AM"
        return VStack(spacing: 10) {
            Image(systemName: "sun.horizon.fill").font(.system(size: 36)).foregroundStyle(Theme.green)
            Text("Your next drop is on its way").font(.title3.weight(.heavy)).foregroundStyle(Theme.ink)
            Text("Every morning at \(time) your scouts bring their best finds here. They're hunting and watching prices now.")
                .font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Button { startEndless() } label: {
                Text("Swipe picks while you wait").font(.subheadline.weight(.bold)).foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 18).padding(.vertical, 11).background(Theme.gradient, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(22).frame(maxWidth: .infinity)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line))
    }

    /// The end of Keep swiping: no filler, just an honest "that's the good stuff for now".
    private var outOfPicks: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "binoculars.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text("You've seen the good stuff").font(.title3.weight(.heavy)).foregroundStyle(Theme.ink)
            Text("Your scouts are hunting for more. New picks show up here as they find them.")
                .font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Button { Task { await store.refreshNow(router: router); topUpMore() } } label: {
                Text("Check for new picks").font(.subheadline.weight(.bold)).foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 18).padding(.vertical, 11).background(Theme.gradient, in: Capsule())
            }
            .buttonStyle(.plain)
            Button("Back to today's drop") { withAnimation(.snappy) { endless = false } }
                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var likedCount: Int {
        let parts = likedToday.split(separator: ":")
        let today = Date.now.formatted(.iso8601.year().month().day())
        return parts.count == 2 && String(parts[0]) == today ? Int(parts[1]) ?? 0 : 0
    }

    /// Counts likes in Keep swiping ("♥ 8 today"), from the card that just left.
    private func countLike() {
        guard moreIndex > 0, moreIndex - 1 < more.count, case .more(let m) = more[moreIndex - 1] else { return }
        let liked = store.state.finds.contains { $0.itemID == m.id && $0.status == .liked }
        guard liked else { return }
        let today = Date.now.formatted(.iso8601.year().month().day())
        likedToday = "\(today):\(likedCount + 1)"
    }

    private func startEndless() {
        let inDrop = Set(deck.compactMap { c -> String? in
            switch c { case .pick(let f), .release(let f, _, _): return f.itemID; default: return nil }
        })
        more = store.keepSwipingPool(excluding: inDrop).map(DeckCard.more)
        moreIndex = 0
        withAnimation(.snappy) { endless = true }
        if more.count < 10 { Task { await store.loadForYou(limit: 80); topUpMore() } }
    }

    /// New picks join the end of Keep swiping.
    private func topUpMore() {
        let have = Set(more.map(\.id))
        let inDrop = Set(deck.compactMap { c -> String? in
            switch c { case .pick(let f), .release(let f, _, _): return f.itemID; default: return nil }
        })
        more += store.keepSwipingPool(excluding: inDrop).map(DeckCard.more).filter { !have.contains($0.id) }
    }

    /// A new drop starts the deck over; picks added to today's drop join the end.
    private func syncDeck() {
        let fresh = store.dropDeck()
        if deck.isEmpty || Set(fresh.map(\.id)).isDisjoint(with: deck.map(\.id)) {
            deck = fresh; deckIndex = 0; endless = false; return
        }
        let have = Set(deck.map(\.id))
        deck += fresh.filter { !have.contains($0.id) }
    }

    /// List view: payoffs, releases, then each scout's picks as rows.
    private var listBody: some View {
        let groups = store.dropGroups()
        let payoffs = store.payoffs()
        let releases = store.droppingToday()
        return ScrollViewReader { proxy in
            ScrollView {
                // Lazy, so the greeting's onDisappear tells us when to offer "back to top".
                LazyVStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        greeting
                        if !groups.isEmpty { dropProgress(groups) } else { HStack { Spacer(); layoutSwitch } }
                    }
                    .id("today-top")
                    .onAppear { withAnimation { showTop = false } }
                    .onDisappear { withAnimation { showTop = true } }
                    if store.plan?.pro != true { PlanStatusPill() }
                    if router.scoutSent != nil { NewScoutCard() }
                    if store.isCloud && !store.state.agents.isEmpty && store.state.finds.isEmpty { firstHuntCard }
                    if !payoffs.isEmpty { sinceYesterday(payoffs) }
                    if !releases.isEmpty { droppingToday(releases) }
                    ForEach(groups, id: \.agent.id) { g in scoutDrop(g.agent, g.finds) }
                    if !store.state.finds.isEmpty { endCard(groups) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .animation(.snappy, value: store.state.finds.map(\.status))
            }
            .scrollIndicators(.hidden)
            .dismissKeyboardOnTap()
            .refreshable { await store.refreshNow(router: router); await store.loadDrop() }
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

    /// "Today's drop · 9 picks from 3 scouts", the cards / list switch, and a bar that fills as you go through them.
    private func dropProgress(_ groups: [(agent: Agent, finds: [Find])]) -> some View {
        let all = groups.flatMap(\.finds)
        let done = all.filter { $0.status != .open }.count
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(groups.count == 1
                     ? String(localized: "Today's drop · \(all.count) picks from \(groups[0].agent.name)")
                     : String(localized: "Today's drop · \(all.count) picks from \(groups.count) scouts"))
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    layoutButton("rectangle.portrait", "cards", String(localized: "Swipe cards"))
                    layoutButton("list.bullet", "list", String(localized: "List"))
                }
                .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.glass)
                    Capsule().fill(Theme.gradient).frame(width: max(6, g.size.width * CGFloat(done) / CGFloat(max(1, all.count))))
                }
            }
            .frame(height: 5)
            .accessibilityElement()
            .accessibilityLabel("\(done) of \(all.count) seen")
        }
    }

    private func sectionHead(_ title: String, _ trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(.caption.weight(.heavy)).tracking(1.3).foregroundStyle(Theme.muted)
            Spacer()
            if let trailing { Text(trailing).font(.caption.weight(.bold)).foregroundStyle(Theme.accent) }
        }
    }

    /// Price drops and restocks on things you watched: the payoff for coming back.
    private func sinceYesterday(_ items: [Payoff]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHead(String(localized: "Since yesterday"), items.count == 1 ? String(localized: "1 update") : String(localized: "\(items.count) updates"))
            ForEach(items) { p in
                Button { router.focusFind = p.find.id; router.tab = .finds } label: {
                    HStack(spacing: 11) {
                        ProductThumb(item: p.item, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.item.title).font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink).lineLimit(2).multilineTextAlignment(.leading)
                            Text(p.line).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(p.tag).font(.caption.weight(.heavy))
                            .foregroundStyle(p.note.kind == .restock ? Theme.accent : Theme.green)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background((p.note.kind == .restock ? Theme.accent : Theme.green).opacity(0.13), in: Capsule())
                    }
                    .padding(10)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Releases from your finds in the next day or so, each with its time.
    private func droppingToday(_ items: [(find: Find, item: Item, at: Date)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHead(String(localized: "Dropping today"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(items, id: \.find.id) { r in
                        Button { router.focusFind = r.find.id; router.tab = .finds } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ProductThumb(item: r.item, size: 128)
                                    .overlay(alignment: .topLeading) {
                                        Text(clock(r.at)).font(.caption2.weight(.heavy)).foregroundStyle(Theme.warn)
                                            .padding(.horizontal, 7).padding(.vertical, 3)
                                            .background(Theme.bg.opacity(0.8), in: Capsule()).padding(6)
                                    }
                                Text(r.item.title).font(.caption.weight(.bold)).foregroundStyle(Theme.ink)
                                    .lineLimit(2).multilineTextAlignment(.leading).frame(width: 128, height: 32, alignment: .topLeading)
                                Text(r.item.priceKnown && r.item.price > 0 ? String(localized: "Release · \(r.item.priceLabel)") : String(localized: "Release"))
                                    .font(.caption2).foregroundStyle(Theme.muted)
                            }
                            .padding(8)
                            .background(Theme.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func clock(_ d: Date) -> String {
        if d < .now { return String(localized: "Live now") }
        let t = d.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(d) ? t : String(localized: "Tomorrow \(t)")
    }

    /// One scout's picks for today, with friends' likes on them.
    private func scoutDrop(_ agent: Agent, _ finds: [Find]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                AgentAvatarView(agent: agent, size: 30)
                Text(agent.name).font(.subheadline.weight(.heavy)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
                Text(finds.count == 1 ? String(localized: "1 pick") : String(localized: "\(finds.count) picks"))
                    .font(.caption.weight(.bold)).foregroundStyle(Theme.muted)
            }
            ForEach(finds) { f in
                if f.status == .passed {
                    EmptyView()
                } else {
                    FindListRow(find: f, agent: agent, friends: store.friendSignals[f.itemID]?.line.nilIfEmpty) {
                        router.focusFind = f.id; router.tab = .finds
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
        }
    }

    /// The end of the drop: it's finished, and when the next one lands.
    private func endCard(_ groups: [(agent: Agent, finds: [Find])]) -> some View {
        let h = store.drop?.hour ?? store.state.settings.dropHour ?? 9
        let time = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now)?.formatted(date: .omitted, time: .shortened) ?? "9 AM"
        let left = groups.flatMap(\.finds).filter { $0.status == .open }.count
        return VStack(spacing: 8) {
            Image(systemName: left == 0 && !groups.isEmpty ? "checkmark.seal.fill" : "sun.horizon.fill")
                .font(.system(size: 34)).foregroundStyle(Theme.green)
            Text(groups.isEmpty ? String(localized: "Your next drop is on its way") : left == 0 ? String(localized: "That's today's drop") : String(localized: "\(left) left in today's drop"))
                .font(.title3.weight(.heavy)).foregroundStyle(Theme.ink)
            Text(String(localized: "Your scouts keep hunting. Next drop tomorrow at \(time). Anything you skip stays in Finds."))
                .font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Button { router.tab = .finds } label: {
                Label("Browse all finds", systemImage: "arrow.right").labelStyle(.titleOnly)
                    .font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Theme.glass, in: Capsule()).overlay(Capsule().strokeBorder(Theme.line))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.vertical, 22).padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line))
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
    /// Today's "pull up at the bottom" count (see PullUpAtBottom).
    var pullUp = 0
    @State private var checking = false

    var body: some View {
        // The same product from several stores shows once, with "Also at N more stores".
        let folded = ProductMatch.dedupe(store.forYou.filter { Catalog.item($0.id) != nil && !exclude.contains($0.id) })
        let all = folded.picks
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
                    FoldGrid(spacing: 12) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.glass).frame(height: 230)
                        }
                    }
                } else {
                    starter
                }
            } else {
                FoldGrid(spacing: 12) {
                    ForEach(picks) { p in
                        if let item = Catalog.item(p.id) { card(p, item) }
                    }
                }
                if mode == .today {
                    // Reaching the bottom loads the next batch, until there's nothing more for now.
                    let more = store.forYou.count >= limit - 4 && limit < Self.maxToday
                    let busy = store.forYouLoading || checking
                    // A button that always works (pulling up past the end does the same).
                    Button { Task { await loadMoreOrCheck() } } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().tint(Theme.accentInk) }
                            else { Image(systemName: more ? "arrow.down" : "arrow.clockwise").font(.footnote.weight(.bold)) }
                            Text(busy ? String(localized: "Loading…") : more ? String(localized: "Load more picks") : String(localized: "Check for new picks"))
                                .font(.subheadline.weight(.bold))
                        }
                        .foregroundStyle(Theme.accentInk)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .padding(.top, 6)
                    // Reaching the bottom loads the next batch once (not batch after batch while you sit there).
                    if more {
                        Color.clear.frame(height: 1).onAppear { if !busy { Task { await loadMoreOrCheck() } } }
                    }
                    if !more {
                        Text("That's everything for now.").font(.caption).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
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
        .onChange(of: pullUp) {
            guard mode == .today else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { await loadMoreOrCheck() }
        }
    }


    /// The next batch of picks; at the end, a check for new ones right here (no trip back to the top).
    @MainActor private func loadMoreOrCheck() async {
        guard !store.forYouLoading, !checking else { return }
        if store.forYou.count >= limit - 4 && limit < Self.maxToday {
            limit = min(Self.maxToday, limit + 24)
            await store.loadForYou(limit: limit)
        } else {
            checking = true
            defer { checking = false }
            await store.refreshNow(router: router)
            await store.loadForYou(limit: limit)
        }
    }
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

/// Pulling up past the bottom of a scroll view (like pull-to-refresh, at the other end). Fires once per pull.
struct PullUpAtBottom: ViewModifier {
    let action: () -> Void
    @State private var fired = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { g in
                g.contentOffset.y + g.containerSize.height - g.contentInsets.bottom - g.contentSize.height
            } action: { _, over in
                if over > 70 && !fired { fired = true; action() }
                else if over < 10 { fired = false }
            }
        } else {
            content   // iOS 17: more picks still load on their own as you reach the bottom
        }
    }
}
