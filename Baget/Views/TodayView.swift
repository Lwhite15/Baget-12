import SwiftUI

/// The home screen. It always has something for you: picks ranked by a taste model that learns from every
/// like, pass, buy, watch and tap, whether or not your squad has new finds right now.
struct TodayView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        let feed = store.forYouFeed()
        let queue = store.swipeQueue.count
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                greeting(feed)
                if let hero = feed.hero { HeroPick(pick: hero) }
                if queue > 0 { swipeCard(queue) }
                if !feed.picks.isEmpty { pickedForYou(feed.picks) }
                if feed.learning { learningCard(feed.signals) }
                ForEach(feed.shelves) { shelf in
                    PickShelf(title: shelf.title, picks: shelf.picks)
                }
                if !feed.radar.isEmpty { PickShelf(title: "On your radar", picks: feed.radar) }
                HuntBox()
                VStack(alignment: .leading, spacing: 10) {
                    Text("MORE FROM THE WEB").font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.muted)
                    LiveFeed()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .animation(.snappy, value: feed.hero?.id)
            .animation(.snappy, value: feed.picks.map(\.id))
        }
        .scrollIndicators(.hidden)
        .refreshable { await store.refreshNow(router: router) }
        .onAppear {
            store.bootstrapTasteIfNeeded()
            let f = store.forYouFeed()
            let ids = ([f.hero].compactMap { $0 } + f.picks + f.shelves.flatMap(\.picks)).map(\.id)
            store.noteTodayShown(ids)
            Analytics.track(.todayViewed, ["picks": ids.count, "toSwipe": queue, "signals": f.signals, "learning": f.learning])
        }
    }

    private func greeting(_ feed: ForYouFeed) -> some View {
        let h = Calendar.current.component(.hour, from: .now)
        let hello = h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
        let name = store.state.profile?.displayName.split(separator: " ").first.map(String.init)
        let agents = store.state.agents.count
        let sub = agents == 0 ? "Picked for your taste" : "\(agents) agent\(agents == 1 ? "" : "s") hunting for you"
        return VStack(alignment: .leading, spacing: 3) {
            Text(name.map { "\(hello), \($0)" } ?? hello)
                .font(.system(size: 28, weight: .heavy)).tracking(-0.6).foregroundStyle(Theme.ink)
            Text("\(sub) · \(Date.now.formatted(.dateTime.weekday(.wide).month().day()))")
                .font(.footnote).foregroundStyle(Theme.muted)
        }
        .padding(.top, 4)
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
                    Text("Right to like, left to pass, up to buy. Every swipe sharpens Today.")
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

    private func pickedForYou(_ picks: [ForYouPick]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Picked for you").font(.title3.weight(.heavy)).foregroundStyle(Theme.ink)
                Spacer()
                Button("All finds") { router.tab = .finds }.font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            Text("Ranked by what you like. Changes as you do.").font(.caption).foregroundStyle(Theme.muted)
            VStack(spacing: 8) {
                ForEach(picks) { PickRow(pick: $0) }
            }
        }
    }

    private func learningCard(_ signals: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "brain.head.profile").font(.title3).foregroundStyle(Theme.cyan)
            VStack(alignment: .leading, spacing: 4) {
                Text("Still learning your taste").font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                Text("Tap ♥ or ✕ on a few picks. Each one teaches Baget what to put here tomorrow.")
                    .font(.caption).foregroundStyle(Theme.muted)
                ProgressView(value: Double(min(signals, 6)), total: 6).tint(Theme.cyan)
            }
        }
        .glassCard()
    }
}

// MARK: - Pick views

/// Like and pass buttons for a pick. Pass asks why, like everywhere else in the app.
struct PickActions: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let pick: ForYouPick
    var compact = false
    @State private var askingWhy = false

    var body: some View {
        HStack(spacing: 8) {
            Button { askingWhy = true } label: {
                Image(systemName: "xmark").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                    .frame(width: compact ? 30 : 38, height: compact ? 30 : 38)
                    .background(Theme.glass, in: Circle()).overlay(Circle().strokeBorder(Theme.line))
            }
            .accessibilityLabel("Pass")
            Button {
                withAnimation(.snappy) { store.forYouLike(pick.item) }
                router.say("Liked. Today will lean into that")
            } label: {
                Image(systemName: "heart.fill").font(.subheadline.weight(.bold)).foregroundStyle(Theme.accentInk)
                    .frame(width: compact ? 30 : 38, height: compact ? 30 : 38)
                    .background(Theme.gradient, in: Circle())
            }
            .accessibilityLabel("Like")
        }
        .buttonStyle(.plain)
        .confirmationDialog("What was off? Baget will learn from it.", isPresented: $askingWhy, titleVisibility: .visible) {
            ForEach(AppStore.PassReason.allCases) { r in
                Button(r.rawValue) {
                    withAnimation(.snappy) { store.forYouPass(pick.item, reason: r) }
                    router.say(r == .later ? "Passed" : "Passed. Learning from that")
                }
            }
        }
    }
}

private struct PickMeta: View {
    let pick: ForYouPick

    /// Store and price. An example's price is illustrative, so it isn't shown.
    private var line: String {
        let item = pick.item
        var parts = [item.source]
        if !pick.isExample && item.priceKnown && item.price > 0 { parts.append(Fmt.money(item.price)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let item = pick.item
        HStack(spacing: 6) {
            if pick.isExample {
                Text("EXAMPLE").font(.system(size: 9, weight: .heavy)).tracking(0.6).foregroundStyle(Theme.warn)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.warn.opacity(0.14), in: Capsule())
            } else if let v = DealVerdict.of(item) {
                VerdictChip(verdict: v)
            }
            Text(line).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
        }
    }
}

private struct ReasonLine: View {
    let pick: ForYouPick
    var body: some View {
        Label(pick.reason, systemImage: pick.isExplore ? "safari" : "sparkles")
            .font(.caption).foregroundStyle(pick.isExplore ? Theme.cyan : Theme.green.opacity(0.9)).lineLimit(1)
    }
}

/// The top pick, big.
struct HeroPick: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let pick: ForYouPick

    private var availability: String {
        if store.isSoldOut(pick.item) { return "Sold out · restocks get watched" }
        if store.dropDate(pick.item) > .now { return "Drops \(store.whenText(pick.item))" }
        return "Available now"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YOUR TOP PICK TODAY").font(.caption.weight(.heavy)).tracking(1).gradientText()
                Spacer()
                Text(pick.item.category.info.label).font(.caption2.weight(.semibold)).foregroundStyle(Theme.muted)
            }
            Button { store.forYouOpen(pick.item, router: router) } label: {
                HStack(alignment: .top, spacing: 14) {
                    ProductThumb(item: pick.item, size: 128)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pick.item.title).font(.headline).foregroundStyle(Theme.ink).lineLimit(3).multilineTextAlignment(.leading)
                        Text(pick.item.brand).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(1)
                        PickMeta(pick: pick)
                        Text(availability).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            HStack {
                ReasonLine(pick: pick)
                Spacer(minLength: 8)
                PickActions(pick: pick)
            }
        }
        .glassCard(highlighted: true)
        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.96))))
    }
}

struct PickRow: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let pick: ForYouPick

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { store.forYouOpen(pick.item, router: router) } label: {
                HStack(alignment: .top, spacing: 12) {
                    ProductThumb(item: pick.item, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pick.item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        PickMeta(pick: pick)
                        ReasonLine(pick: pick)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            PickActions(pick: pick, compact: true)
        }
        .padding(10)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }
}

/// A horizontal row of picks under one heading ("Because you like suede", "On your radar").
struct PickShelf: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let title: String
    let picks: [ForYouPick]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.heavy)).foregroundStyle(Theme.ink).lineLimit(1)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(picks) { p in
                        Button { store.forYouOpen(p.item, router: router) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ProductThumb(item: p.item, size: 132)
                                Text(p.item.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                    .frame(width: 132, alignment: .leading)
                                Text(p.isExample ? "Example" : p.reason).font(.caption2).foregroundStyle(Theme.muted)
                                    .lineLimit(1).frame(width: 132, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
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
        if isCloud {
            await pull()
        } else {
            let res = sweep()
            Analytics.track(.sweepRun, ["found": res.found, "manual": true])
            router.say(res.found > 0 ? "\(res.found) new find\(res.found == 1 ? "" : "s")" : "Nothing new fits you right now")
        }
    }
}
