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
                HuntBox()
                if queue > 0 { swipeCard(queue) }
                if !picks.isEmpty { todaysDrop(picks) }
                VStack(alignment: .leading, spacing: 10) {
                    Text("MORE FOR YOU").font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.muted)
                    LiveFeed()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
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
                        Text([item.source, item.priceKnown && item.price > 0 ? Fmt.money(item.price) : nil].compactMap { $0 }.joined(separator: " · "))
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
