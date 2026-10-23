import SwiftUI

/// The home screen: say what you want, see today's best picks, swipe the rest, then browse the feed.
struct TodayView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        let picks = store.todaysPicks()
        let queue = store.swipeQueue.count
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                greeting
                PlanStatusPill()
                if store.isCloud && !store.state.agents.isEmpty && store.state.finds.isEmpty { firstHuntCard }
                if queue > 0 { swipeCard(queue) }
                if !picks.isEmpty { todaysDrop(picks) }
                ForYouSection()
                HuntBox()
                VStack(alignment: .leading, spacing: 10) {
                    Text("LIVE FROM YOUR SQUAD").font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.muted)
                    LiveFeed()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .dismissKeyboardOnTap()
        .refreshable { await store.refreshNow(router: router) }
        .onAppear { Analytics.track(.todayViewed, ["picks": picks.count, "toSwipe": queue]) }
    }

    private var greeting: some View {
        let h = Calendar.current.component(.hour, from: .now)
        let hello = h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
        let name = store.state.profile?.displayName.split(separator: " ").first.map(String.init)
        return VStack(alignment: .leading, spacing: 3) {
            Text(name.map { "\(hello), \($0)" } ?? hello)
                .font(.system(size: 28, weight: .heavy)).tracking(-0.6).foregroundStyle(Theme.ink)
            Text("\(store.state.agents.count) agent\(store.state.agents.count == 1 ? "" : "s") hunting for you · \(Date.now.formatted(.dateTime.weekday(.wide).month().day()))")
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
            huntingCard.onAppear { if firstHuntStarted == 0 { firstHuntStarted = Date.now.timeIntervalSince1970 } }
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
                 ? "\(a.name) only flags \(a.mission.category == .sneakers ? "pairs" : "pieces") in stock in your size, and it doesn't know yours yet."
                 : "\(a.name) is being picky so you only see good matches. A brand, model or budget gives it much more to go on.")
                .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(noSize != nil ? "Add your size" : "Tell \(a.name) more") { router.sheet = .chat(a.id) }
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

    private func swipeCard(_ n: Int) -> some View {
        Button { router.sheet = .swipe } label: {
            HStack(spacing: 14) {
                ZStack {
                    ForEach(0..<min(3, n), id: \.self) { i in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(i == 0 ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.glass))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
                            .frame(width: 34, height: 44)
                            .rotationEffect(.degrees(Double(i) * -8))
                            .offset(x: CGFloat(i) * -4)
                            .zIndex(Double(3 - i))
                    }
                }
                .frame(width: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Swipe through \(n) new find\(n == 1 ? "" : "s")").font(.headline).foregroundStyle(Theme.ink)
                    Text("Right to like, left to pass, up to buy. Every swipe teaches your squad.")
                        .font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
            }
            .padding(14)
            .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.4)))
        }
        .buttonStyle(.plain)
    }

    private func todaysDrop(_ picks: [Find]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today's Drop").font(.title3.weight(.heavy)).foregroundStyle(Theme.ink)
                Spacer()
                Button("See all") { router.tab = .finds }.font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            Text("Your squad's best \(picks.count) right now.").font(.caption).foregroundStyle(Theme.muted)
            VStack(spacing: 8) {
                ForEach(Array(picks.enumerated()), id: \.element.id) { i, f in
                    if let item = Catalog.item(f.itemID) { pickRow(i + 1, f, item) }
                }
            }
        }
    }

    private func pickRow(_ rank: Int, _ f: Find, _ item: Item) -> some View {
        Button { router.focusFind = f.id; router.tab = .finds } label: {
            HStack(alignment: .top, spacing: 12) {
                Text("\(rank)").font(.system(size: 20, weight: .heavy)).gradientText().frame(width: 18)
                ProductThumb(item: item, size: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if let v = DealVerdict.of(item) { VerdictChip(verdict: v) }
                        Text([item.source, item.priceKnown && item.price > 0 ? item.priceLabel : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    if let why = f.why.first { Text(why).font(.caption).foregroundStyle(Theme.green.opacity(0.9)).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Theme.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
        }
        .buttonStyle(.plain)
    }
}

/// "For You": always-on personal picks. Ranked by what you like, refreshed daily, sharpened by every heart and X.
struct ForYouSection: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL
    @State private var limit = 24

    var body: some View {
        let picks = store.forYou.filter { Catalog.item($0.id) != nil }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("For You").font(.title3.weight(.heavy)).foregroundStyle(Theme.ink)
                Spacer()
            }
            Text("Picked from everything Baget's agents have found, ranked by your taste. Every ♥ and ✕ sharpens it.")
                .font(.caption).foregroundStyle(Theme.muted)
            if !store.tasteTop.isEmpty { tasteStrip }

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
                if picks.count >= limit - 2 && limit < 60 {
                    Button {
                        limit = min(60, limit + 24)
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
                Button { withAnimation(.snappy) { store.reactForYou(p, .dismiss) }; router.say("Got it, fewer like this") } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(Theme.glass, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.line))
                }
                .accessibilityLabel("Not for me")
                Button {
                    withAnimation(.snappy) { store.reactForYou(p, .like) }
                    router.say(store.state.agents.isEmpty ? "Liked. Baget will show more like this" : "Saved to Finds. More like this coming")
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
        guard let url = BuyLink.tracked(item, from: "for_you") else { router.say("No store page for this one yet"); return }
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

/// "What are you hunting?" Type or dictate one sentence; an agent is created and starts searching.
struct HuntBox: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @State private var text = ""
    @State private var working = false
    @State private var result: (agentID: String, intro: String)?
    @FocusState private var focused: Bool

    private static let examples = ["oud fragrances like Frederic Malle", "a 992 GT3 under $200k", "Supreme box logo in size L",
                                   "mid-century walnut credenza", "Jordan 1s in mocha, size 10.5", "vintage Rolex Explorer"]
    @State private var example = HuntBox.examples.randomElement()!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What are you hunting?").font(.headline).foregroundStyle(Theme.ink)
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Theme.cyan)
                TextField("e.g. \(example)", text: $text, axis: .vertical)
                    .lineLimit(1...3)
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit(go)
                    .disabled(working)
                    // Return starts the hunt (a multi-line field would otherwise just add a new line).
                    .onChange(of: text) { _, t in
                        if t.contains("\n") {
                            text = t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                            if text.count >= 2 { go() } else { focused = false }
                        }
                    }
                if working {
                    ProgressView().tint(Theme.cyan)
                } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: go) {
                        Image(systemName: "arrow.up").font(.subheadline.weight(.bold)).foregroundStyle(Theme.accentInk)
                            .frame(width: 32, height: 32).background(Theme.gradient, in: Circle())
                    }
                    .accessibilityLabel("Start hunting")
                }
            }
            .padding(12)
            .background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.line))
            if focused && !working {
                HStack {
                    Spacer()
                    Button("Cancel") { text = ""; focused = false }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            if let r = result, let a = store.agent(r.agentID) {
                HStack(alignment: .top, spacing: 10) {
                    AgentAvatarView(agent: a, size: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(a.name) is on it").font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                        Text(r.intro).font(.caption).foregroundStyle(Theme.muted)
                        Button("Tell it more") { router.sheet = .chat(a.id) }.font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                    Spacer(minLength: 0)
                    Button { result = nil } label: { Image(systemName: "xmark").font(.caption).foregroundStyle(Theme.muted) }
                        .accessibilityLabel("Dismiss")
                }
                .padding(10)
                .background(Theme.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text("Type or say it in your own words. Baget builds the right agent and it starts searching right away.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .glassCard()
    }

    private func go() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, !working else { return }
        focused = false
        working = true
        Task { @MainActor in
            defer { working = false }
            guard let r = await store.hunt(t) else { return }
            text = ""
            example = HuntBox.examples.randomElement()!
            withAnimation { result = (r.agentID, r.intro) }
            if r.needsSize { router.sheet = .chat(r.agentID) }   // its first question will be your size
        }
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
            router.say(res.found > 0 ? "\(res.found) new find\(res.found == 1 ? "" : "s")" : "Nothing new fits you right now")
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
