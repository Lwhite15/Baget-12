import SwiftUI

/// Today's finds as a swipe deck, right on Today: right to like, left to pass, or use the buttons. Tap a card for details.
/// Only sideways drags move a card, so scrolling the page over it still works.
struct TodayDeck: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL
    static let size = 12
    let ids: [String]
    @Binding var index: Int
    @State private var dx: CGFloat = 0
    @State private var swiping: Bool?
    @State private var liked = 0
    @State private var busy = false
    /// The Duo's inner display turned on its side: card and buttons side by side, so both fit above the tab bar.
    @Environment(\.duoWide) private var wide

    private func find(_ i: Int) -> (Find, Item)? {
        guard i < ids.count, let f = store.state.finds.first(where: { $0.id == ids[i] }), let item = Catalog.item(f.itemID) else { return nil }
        return (f, item)
    }

    var body: some View {
        if let (f, item) = find(index) {
            let layout = wide ? AnyLayout(HStackLayout(alignment: .center, spacing: 28)) : AnyLayout(VStackLayout(spacing: 12))
            VStack(spacing: 12) {
              layout {
                ZStack {
                    if let (nf, ni) = find(index + 1) {
                        card(nf, ni).scaleEffect(0.95).offset(y: 12).opacity(0.55).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    card(f, item)
                        .offset(x: dx)
                        .rotationEffect(.degrees(Double(dx / 24)))
                        .overlay(alignment: .topLeading) { stamp }
                        .onTapGesture { router.focusFind = f.id; router.tab = .finds }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 14)
                                .onChanged { v in
                                    if swiping == nil { swiping = abs(v.translation.width) > abs(v.translation.height) * 1.3 }
                                    guard swiping == true, !busy else { return }
                                    dx = v.translation.width
                                }
                                .onEnded { v in
                                    let horizontal = swiping == true
                                    swiping = nil
                                    guard horizontal, !busy else { return }
                                    if v.translation.width > 100 { act(.like, f, item) }
                                    else if v.translation.width < -100 { act(.pass, f, item) }
                                    else { withAnimation(.spring(response: 0.3)) { dx = 0 } }
                                }
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityAction(named: "Like") { act(.like, f, item) }
                        .accessibilityAction(named: "Pass") { act(.pass, f, item) }
                        .accessibilityAction(named: "Buy") { act(.buy, f, item) }
                }
                .duoCardWidth(wide ? 460 : 520)
                if wide {
                    VStack(spacing: 16) { passButton(f, item); likeButton(f, item); buyButton(f, item) }
                } else {
                    FoldRow(spacing: 16) {
                        passButton(f, item)
                    } trailing: {
                        likeButton(f, item)
                        buyButton(f, item)
                    }
                }
              }
                Text("Swipe right to like, left to pass. Tap for details.").font(.caption).foregroundStyle(Theme.muted)
            }
        } else {
            done
        }
    }

    private enum Action { case like, pass, buy }

    @ViewBuilder private var stamp: some View {
        if dx > 30 { label("LIKE", Theme.green).opacity(min(1, Double(dx) / 100)) }
        else if dx < -30 { label("PASS", Theme.hot).opacity(min(1, Double(-dx) / 100)) }
    }

    private func label(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 26, weight: .heavy)).tracking(2).foregroundStyle(c)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Theme.bg.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(c, lineWidth: 3))
            .rotationEffect(.degrees(-12))
            .padding(.top, 34).padding(.leading, 18)
    }

    private func card(_ f: Find, _ item: Item) -> some View {
        let agent = store.agent(f.agentID)
        return VStack(alignment: .leading, spacing: 0) {
            Plate(item: item, label: item.brand.isEmpty ? item.category.info.label : item.brand, height: wide ? 190 : 300, lead: true)
                .overlay(alignment: .topTrailing) {
                    Text("\(f.score)% match").font(.caption.weight(.heavy).monospacedDigit())
                        .foregroundStyle(f.score >= 80 ? Theme.green : Theme.accent)
                        .padding(.horizontal, 9).padding(.vertical, 5).background(Theme.bg.opacity(0.85), in: Capsule()).padding(10)
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(index + 1) of \(ids.count)").font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(Theme.muted)
                    Spacer()
                    if let a = agent { Text("from \(a.name)").font(.caption2.weight(.semibold)).foregroundStyle(Theme.muted).lineLimit(1) }
                }
                Text(item.title).font(.headline).foregroundStyle(Theme.ink).lineLimit(2).multilineTextAlignment(.leading)
                Text([item.priceKnown && item.price > 0 ? item.priceLabel : nil, item.source].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(Theme.muted).lineLimit(1)
                if let why = f.why.first(where: { !$0.hasPrefix("Discovery") && !$0.isEmpty }) ?? f.why.first {
                    Label(why, systemImage: "heart.fill").font(.caption).foregroundStyle(Theme.green.opacity(0.9)).lineLimit(1)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func passButton(_ f: Find, _ item: Item) -> some View {
        round("xmark", Theme.ink, String(localized: "Pass"), filled: false) { act(.pass, f, item) }
    }

    private func likeButton(_ f: Find, _ item: Item) -> some View {
        round("heart.fill", Theme.accentInk, String(localized: "Like"), filled: true, big: true) { act(.like, f, item) }
    }

    @ViewBuilder private func buyButton(_ f: Find, _ item: Item) -> some View {
        if BuyLink.url(item) != nil && !store.isSoldOut(item) {
            Button { act(.buy, f, item) } label: {
                Label(store.buyLabel(item, short: true), systemImage: "arrow.up.right").font(.subheadline.weight(.bold)).foregroundStyle(Theme.cyan)
                    .padding(.horizontal, 16).frame(height: 52)
                    .background(Theme.glass, in: Capsule()).overlay(Capsule().strokeBorder(Theme.line))
            }
            .buttonStyle(.plain)
        }
    }

    private func round(_ icon: String, _ tint: Color, _ name: String, filled: Bool, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: big ? 22 : 17, weight: .bold)).foregroundStyle(tint)
                .frame(width: big ? 60 : 52, height: big ? 60 : 52)
                .background { if filled { Circle().fill(Theme.gradient) } else { Circle().fill(Theme.glass) } }
                .overlay { if !filled { Circle().strokeBorder(Theme.line) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }

    private func act(_ a: Action, _ f: Find, _ item: Item) {
        guard !busy else { return }
        if a == .buy {
            if let link = BuyLink.url(item) {
                Analytics.track(.checkoutOpened, ["category": item.category.rawValue, "toStore": true, "from": "today_deck"])
                router.buyOpened = f.id
                openURL(BuyLink.tracked(item, from: "today_deck") ?? link)
            }
            return
        }
        busy = true
        if a == .like {
            if f.status != .liked { store.like(f.id) }
            liked += 1
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            store.pass(f.id, reason: .product)
        }
        Analytics.track(.swipe, ["action": a == .like ? "like" : "pass", "category": item.category.rawValue, "score": f.score, "from": "today"])
        withAnimation(.easeIn(duration: 0.2)) { dx = a == .like ? 520 : -520 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(210))
            dx = 0
            index += 1
            busy = false
        }
    }

    private var done: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(Theme.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(ids.isEmpty ? String(localized: "No new finds right now") : String(localized: "That's today's finds"))
                    .font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                Text(liked > 0 ? String(localized: "\(liked) liked. Your scouts just got sharper. More for you below.")
                               : String(localized: "Your scouts keep hunting. More for you below."))
                    .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.green.opacity(0.3)))
    }
}
