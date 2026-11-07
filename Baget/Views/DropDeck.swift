import SwiftUI

/// Today's swipe deck: payoffs from what your scouts watch, releases with countdowns, then the day's picks
/// (and after the drop, "Keep swiping"). Right = like (and your scout watches it), left = pass, up = watch or remind.
struct DropDeckView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL
    let cards: [DeckCard]
    @Binding var index: Int
    @State private var drag: CGSize = .zero
    @State private var busy = false

    private enum Swipe { case right, left, up }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { g in
                ZStack {
                    if index + 1 < cards.count {
                        card(cards[index + 1], height: g.size.height)
                            .scaleEffect(0.95).offset(y: 12).opacity(0.5)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    if index < cards.count {
                        let c = cards[index]
                        card(c, height: g.size.height)
                            .offset(drag)
                            .rotationEffect(.degrees(Double(drag.width / 24)))
                            .overlay(alignment: .top) { stamp(c) }
                            .onTapGesture { open(c) }
                            .gesture(
                                DragGesture(minimumDistance: 12)
                                    .onChanged { v in if !busy { drag = v.translation } }
                                    .onEnded { v in
                                        guard !busy else { return }
                                        let t = v.translation
                                        if t.width > 100 { act(.right, c) }
                                        else if t.width < -100 { act(.left, c) }
                                        else if t.height < -110 && abs(t.width) < 90 { act(.up, c) }
                                        else { withAnimation(.spring(response: 0.3)) { drag = .zero } }
                                    }
                            )
                            .accessibilityElement(children: .combine)
                            .accessibilityAction(named: rightName(c)) { act(.right, c) }
                            .accessibilityAction(named: leftName(c)) { act(.left, c) }
                            .accessibilityAction(named: upName(c)) { act(.up, c) }
                            .id(c.id)
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
            }
            if index < cards.count { buttons(cards[index]) }
        }
    }

    // MARK: Cards

    @ViewBuilder private func card(_ c: DeckCard, height: CGFloat) -> some View {
        // The photo takes whatever room the words leave, so the card never has a blank bottom half.
        switch c {
        case .payoff(let p): payoffCard(p, plate: max(100, height - 290))
        case .release(let f, let item, let at): releaseCard(f, item, at, plate: max(100, height - 300))
        case .pick(let f): if let item = Catalog.item(f.itemID) { pickCard(f, item, plate: max(120, height - 200)) }
        case .more(let m): if let item = Catalog.item(m.id) { moreCard(m, item, plate: max(120, height - 190)) }
        }
    }

    private func shell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func banner(_ icon: String, _ title: String, _ tint: Color, _ who: String?) -> some View {
        HStack {
            Label(title, systemImage: icon).font(.caption.weight(.heavy)).tracking(0.8)
            Spacer()
            if let who { Text(who).font(.caption.weight(.bold)).lineLimit(1) }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(tint.opacity(0.14))
    }

    private func payoffCard(_ p: Payoff, plate: CGFloat) -> some View {
        let agent = store.agent(p.find.agentID)
        let (icon, title, tint): (String, String, Color) = switch p.note.kind {
        case .restock: ("arrow.clockwise", String(localized: "BACK IN STOCK"), Theme.accent)
        case .dated: ("calendar.badge.clock", p.tag == String(localized: "Moved") ? String(localized: "RELEASE MOVED") : String(localized: "RELEASE DATE"), Theme.warn)
        default: ("arrow.down", String(localized: "PRICE DROP"), Theme.green)
        }
        return shell {
            banner(icon, title, tint, agent?.name)
            Plate(item: p.item, label: p.item.brand.isEmpty ? p.item.category.info.label : p.item.brand, height: plate)
            VStack(alignment: .leading, spacing: 5) {
                Text(p.item.title).font(.headline).foregroundStyle(Theme.ink).lineLimit(2)
                if p.note.kind == .drop {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Fmt.money(p.item.lowPrice ?? p.item.price)).font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.ink)
                        Text(p.tag).font(.subheadline.weight(.heavy)).foregroundStyle(Theme.green)
                        if let s = p.item.lowStore { Text("at \(s)").font(.footnote).foregroundStyle(Theme.muted).lineLimit(1) }
                    }
                } else {
                    Text(p.line).font(.subheadline.weight(.bold)).foregroundStyle(tint)
                }
                Text(p.note.body).font(.footnote).foregroundStyle(Theme.ink.opacity(0.85)).lineLimit(3)
                if let c = p.item.checkedAt {
                    Label(String(localized: "\(agent?.name ?? "Your scout") checked \(c.formatted(.relative(presentation: .named)))"), systemImage: "checkmark")
                        .font(.caption2).foregroundStyle(Theme.muted)
                }
            }
            .padding(14)
        }
    }

    private func releaseCard(_ f: Find, _ item: Item, _ at: Date, plate: CGFloat) -> some View {
        let agent = store.agent(f.agentID)
        let rumored = item.tags.contains("rumored")
        let host = item.url.flatMap { URL(string: $0)?.host?.replacingOccurrences(of: "www.", with: "") }
        return shell {
            banner("timer", String(localized: "RELEASING"), Theme.warn, agent?.name)
            Plate(item: item, label: item.brand.isEmpty ? item.category.info.label : item.brand, height: plate)
            VStack(alignment: .leading, spacing: 7) {
                Text(item.title).font(.headline).foregroundStyle(Theme.ink).lineLimit(2)
                Text([ReminderSheet.fmt(at), item.priceKnown && item.price > 0 ? item.priceLabel : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(Theme.muted).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in countdown(to: at, now: ctx.date) }
                HStack(spacing: 6) {
                    Label(rumored ? String(localized: "Rumored") : String(localized: "Confirmed"), systemImage: rumored ? "questionmark.circle" : "checkmark.seal.fill")
                        .font(.caption.weight(.heavy)).foregroundStyle(rumored ? Theme.warn : Theme.green)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background((rumored ? Theme.warn : Theme.green).opacity(0.13), in: Capsule())
                    if let host { Text(host).font(.caption).foregroundStyle(Theme.muted).lineLimit(1) }
                    Spacer(minLength: 0)
                    if store.reminder(for: item) != nil {
                        Label("Reminder set", systemImage: "bell.fill").font(.caption.weight(.bold)).foregroundStyle(Theme.warn)
                    }
                }
            }
            .padding(14)
        }
    }

    private func countdown(to at: Date, now: Date) -> some View {
        let s = max(0, Int(at.timeIntervalSince(now)))
        let parts = [(s / 86400, String(localized: "days")), ((s % 86400) / 3600, String(localized: "hrs")), ((s % 3600) / 60, String(localized: "min"))]
        return HStack(spacing: 8) {
            ForEach(parts.indices, id: \.self) { i in
                VStack(spacing: 1) {
                    Text("\(parts[i].0)").font(.title3.weight(.heavy).monospacedDigit()).foregroundStyle(Theme.ink)
                    Text(parts[i].1).font(.caption2.weight(.bold)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
            }
        }
    }

    private func pickCard(_ f: Find, _ item: Item, plate: CGFloat) -> some View {
        let agent = store.agent(f.agentID)
        return shell {
            Plate(item: item, label: item.brand.isEmpty ? item.category.info.label : item.brand, height: plate, lead: true)
                .overlay(alignment: .topTrailing) { matchChip(f.score) }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let a = agent { Text(a.name).font(.caption2.weight(.semibold)).foregroundStyle(Theme.muted).lineLimit(1) }
                    Spacer()
                    Text(item.source).font(.caption2.weight(.semibold)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Text(item.title).font(.headline).foregroundStyle(Theme.ink).lineLimit(2)
                Text(priceLine(item)).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(1)
                if let friends = store.friendSignals[f.itemID]?.line.nilIfEmpty {
                    Label(friends, systemImage: "person.2.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent).lineLimit(1)
                }
                if let why = f.why.first(where: { !$0.hasPrefix("Discovery") && !$0.isEmpty }) ?? f.why.first {
                    Label(why, systemImage: "heart.fill").font(.caption).foregroundStyle(Theme.green.opacity(0.9)).lineLimit(2)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    private func moreCard(_ m: ForYouItem, _ item: Item, plate: CGFloat) -> some View {
        shell {
            Plate(item: item, label: item.brand.isEmpty ? item.category.info.label : item.brand, height: plate, lead: true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(m.kind == "explore" ? String(localized: "Something new") : String(localized: "Picked for you"),
                          systemImage: m.kind == "explore" ? "sparkles" : "wand.and.stars")
                        .font(.caption2.weight(.semibold)).foregroundStyle(m.kind == "explore" ? Theme.cyan : Theme.muted)
                    Spacer()
                    Text(item.source).font(.caption2.weight(.semibold)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Text(item.title).font(.headline).foregroundStyle(Theme.ink).lineLimit(2)
                Text(priceLine(item)).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(1)
                Label(m.reason, systemImage: "heart.fill").font(.caption).foregroundStyle(Theme.green.opacity(0.9)).lineLimit(2)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    private func priceLine(_ item: Item) -> String {
        var parts: [String] = []
        if item.priceKnown && item.price > 0 { parts.append(item.priceLabel) }
        if let d = item.dropAt, d > .now { parts.append(String(localized: "Releasing \(ReminderSheet.short(d))")) }
        return parts.isEmpty ? item.source : parts.joined(separator: " · ")
    }

    private func matchChip(_ score: Int) -> some View {
        Text("\(score)% match").font(.caption.weight(.heavy).monospacedDigit())
            .foregroundStyle(score >= 80 ? Theme.green : Theme.accent)
            .padding(.horizontal, 9).padding(.vertical, 5).background(Theme.bg.opacity(0.85), in: Capsule()).padding(10)
    }

    // MARK: Gestures and buttons

    private func rightName(_ c: DeckCard) -> String {
        if case .payoff = c { return String(localized: "Keep watching") }
        return String(localized: "Like")
    }
    private func leftName(_ c: DeckCard) -> String {
        if case .payoff = c { return String(localized: "Stop watching") }
        return String(localized: "Pass")
    }
    private func upName(_ c: DeckCard) -> String {
        switch c {
        case .payoff: return String(localized: "Open at the store")
        case .release: return String(localized: "Remind me")
        default: return String(localized: "Watch")
        }
    }

    @ViewBuilder private func stamp(_ c: DeckCard) -> some View {
        if drag.width > 30 {
            label(rightName(c).uppercased(), Theme.green).opacity(min(1, Double(drag.width) / 100)).frame(maxWidth: .infinity, alignment: .leading)
        } else if drag.width < -30 {
            label(leftName(c).uppercased(), Theme.hot).opacity(min(1, Double(-drag.width) / 100)).frame(maxWidth: .infinity, alignment: .trailing)
        } else if drag.height < -40 {
            label(upName(c).uppercased(), Theme.warn).opacity(min(1, Double(-drag.height) / 110))
        }
    }

    private func label(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 24, weight: .heavy)).tracking(1.5).foregroundStyle(c)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Theme.bg.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(c, lineWidth: 3))
            .rotationEffect(.degrees(-10))
            .padding(.top, 40).padding(.horizontal, 18)
    }

    private func buttons(_ c: DeckCard) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 16) {
                round("xmark", Theme.hot, leftName(c)) { act(.left, c) }
                round(upIcon(c), Theme.warn, upName(c)) { act(.up, c) }
                if let item = item(of: c), BuyLink.url(item) != nil {
                    round("arrow.up.right", Theme.accent, String(localized: "Buy")) { buy(c) }
                }
                round("heart.fill", Theme.green, rightName(c), big: true) { act(.right, c) }
            }
            HStack {
                Text("← \(leftName(c).lowercased())")
                Spacer()
                Text("↑ \(upName(c).lowercased())")
                Spacer()
                Text("\(rightName(c).lowercased()) →")
            }
            .font(.caption2.weight(.semibold)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 6)
        }
    }

    private func upIcon(_ c: DeckCard) -> String {
        switch c {
        case .payoff: return "bag"
        case .release: return "bell"
        default: return "eye"
        }
    }

    private func round(_ icon: String, _ tint: Color, _ name: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: big ? 22 : 17, weight: .bold)).foregroundStyle(tint)
                .frame(width: big ? 62 : 50, height: big ? 62 : 50)
                .background(Theme.glass, in: Circle())
                .overlay(Circle().strokeBorder(tint.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }

    private func item(of c: DeckCard) -> Item? {
        switch c {
        case .payoff(let p): return p.item
        case .release(_, let item, _): return item
        case .pick(let f): return Catalog.item(f.itemID)
        case .more(let m): return Catalog.item(m.id)
        }
    }

    private func findID(of c: DeckCard) -> String? {
        switch c {
        case .payoff(let p): return p.find.id
        case .release(let f, _, _): return f.id
        case .pick(let f): return f.id
        case .more(let m): return m.findID
        }
    }

    private func open(_ c: DeckCard) {
        if let fid = findID(of: c) { router.focusFind = fid; router.tab = .finds }
        else if case .more(let m) = c, let item = Catalog.item(m.id), let url = BuyLink.tracked(item, from: "keep_swiping") {
            store.reactForYou(m, .open)
            openURL(url)
        }
    }

    private func buy(_ c: DeckCard) {
        guard let item = item(of: c), let link = BuyLink.url(item) else { return }
        Analytics.track(.checkoutOpened, ["category": item.category.rawValue, "toStore": true, "from": "today_deck"])
        if let fid = findID(of: c) { router.buyOpened = fid }
        if case .more(let m) = c { store.reactForYou(m, .open) }
        openURL(BuyLink.tracked(item, from: "today_deck") ?? link)
    }

    private func act(_ s: Swipe, _ c: DeckCard) {
        guard !busy else { return }
        let scout = findID(of: c).flatMap { id in store.state.finds.first { $0.id == id } }.flatMap { store.agent($0.agentID)?.name } ?? String(localized: "Your scout")
        switch (c, s) {
        case (.payoff, .up):
            // No store link: put the card back instead of leaving it stuck halfway up.
            guard let item = item(of: c), BuyLink.url(item) != nil else {
                withAnimation(.spring(response: 0.3)) { drag = .zero }
                router.say(String(localized: "No store link for this one yet"))
                return
            }
            buy(c)   // then the card flies off like any other swipe, so the deck never freezes
        case (.payoff(let p), .left):
            if p.find.watching { store.toggleWatch(p.find.id) }
            router.say(String(localized: "Stopped watching"))
        case (.payoff, _):
            break
        case (.release(let f, let item, _), .up):
            if store.reminder(for: item) != nil || store.setReminder(item, findID: f.id, offsetMinutes: 15) {
                router.say(String(localized: "I'll remind you 15 minutes before it drops"))
            } else {
                router.say(String(localized: "It's dropping too soon for a reminder"))
            }
        case (.release(let f, _, _), .right), (.pick(let f), .right):
            if f.status != .liked { store.like(f.id) }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            router.say(String(localized: "\(scout) is watching this. You'll hear if the price drops or it sells out."))
        case (.release(let f, _, _), .left), (.pick(let f), .left):
            store.pass(f.id, reason: .product)
        case (.pick(let f), .up):
            if !f.watching { store.watch(f.id) }
            router.say(String(localized: "Watching. \(scout) will tell you about price drops, restocks and release dates."))
        case (.more(let m), .left):
            store.reactForYou(m, .dismiss)
        case (.more(let m), _):
            store.reactForYou(m, .like)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            router.say(String(localized: "Saved to Finds. Your scout is watching it."))
        }
        if let item = item(of: c) {
            Analytics.track(.swipe, ["action": s == .right ? "like" : s == .left ? "pass" : "up", "category": item.category.rawValue, "from": "today"])
        }
        busy = true
        let out: CGSize = switch s {
        case .right: CGSize(width: 560, height: drag.height)
        case .left: CGSize(width: -560, height: drag.height)
        case .up: CGSize(width: 0, height: -900)
        }
        withAnimation(.easeIn(duration: 0.2)) { drag = out }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(210))
            drag = .zero
            index += 1
            busy = false
        }
    }
}

/// After the last card of the drop: the tally, what your scouts are watching, and "Keep swiping".
struct DropFinishedCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let liked: Int
    let passed: Int
    let reminders: Int
    let morePicks: Int
    let keepSwiping: () -> Void

    var body: some View {
        let w = store.watchSummary()
        let h = store.drop?.hour ?? store.state.settings.dropHour ?? 9
        let time = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now)?.formatted(date: .omitted, time: .shortened) ?? "9 AM"
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "checkmark").font(.system(size: 26, weight: .heavy)).foregroundStyle(Theme.green)
                    .frame(width: 60, height: 60).background(Theme.green.opacity(0.14), in: Circle())
                Text("You finished today's drop").font(.title2.weight(.heavy)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    stat(liked, String(localized: "liked"))
                    stat(passed, String(localized: "passed"))
                    stat(reminders, String(localized: "reminders"))
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("YOUR SCOUTS ARE WATCHING").font(.caption.weight(.heavy)).tracking(1.2).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        Circle().fill(Theme.green).frame(width: 9, height: 9).shadow(color: Theme.green, radius: 4)
                        Text(watchLine(w)).font(.footnote).foregroundStyle(Theme.ink)
                    }
                    if !w.upcoming.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(w.upcoming, id: \.item.id) { u in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ReminderSheet.short(u.at).uppercased()).font(.caption2.weight(.heavy)).foregroundStyle(Theme.warn).lineLimit(1)
                                    Text(u.item.title).font(.caption2.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                                }
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.warn.opacity(0.25)))
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
                Button(action: keepSwiping) {
                    VStack(spacing: 2) {
                        Text("Keep swiping →").font(.headline.weight(.heavy))
                        Text(morePicks > 0 ? String(localized: "\(morePicks) more picks ranked by your taste") : String(localized: "Picks ranked by your taste"))
                            .font(.caption.weight(.semibold)).opacity(0.75)
                    }
                    .foregroundStyle(Theme.accentInk)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                Button("See what you liked") { router.tab = .finds }
                    .font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent)
                Text("Next drop tomorrow at \(time)").font(.caption).foregroundStyle(Theme.muted)
            }
            .padding(18)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.line))
        }
        .scrollIndicators(.hidden)
    }

    private func watchLine(_ w: WatchSummary) -> String {
        var parts = [w.count == 1 ? String(localized: "1 item") : String(localized: "\(w.count) items")]
        if let c = w.checked { parts.append(String(localized: "checked \(c.formatted(.relative(presentation: .named)))")) }
        parts.append(w.changes == 1 ? String(localized: "1 change this week") : String(localized: "\(w.changes) changes this week"))
        return parts.joined(separator: " · ")
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.title3.weight(.heavy)).foregroundStyle(Theme.ink)
            Text(label).font(.caption.weight(.bold)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
    }
}
