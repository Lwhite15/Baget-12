import SwiftUI

/// Finds as a card stack: right to like, left to pass, up to buy. The fastest way to teach the squad.
struct SwipeDeckView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var ids: [String] = []
    @State private var index = 0
    @State private var drag: CGSize = .zero
    @State private var liked = 0
    @State private var passed = 0
    @State private var watchStamp = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if index < ids.count, let f = store.state.finds.first(where: { $0.id == ids[index] }), let item = Catalog.item(f.itemID) {
                    Text("\(index + 1) of \(ids.count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                    ZStack {
                        if index + 1 < ids.count, let next = store.state.finds.first(where: { $0.id == ids[index + 1] }), let ni = Catalog.item(next.itemID) {
                            card(next, ni).scaleEffect(0.95).offset(y: 14).opacity(0.6).allowsHitTesting(false)
                        }
                        card(f, item)
                            .offset(drag)
                            .rotationEffect(.degrees(Double(drag.width / 22)))
                            .overlay(alignment: .top) { stamp }
                            .gesture(
                                DragGesture()
                                    .onChanged { drag = $0.translation }
                                    .onEnded { v in
                                        if v.translation.width > 110 { act(.like, f, item) }
                                        else if v.translation.width < -110 { act(.pass, f, item) }
                                        else if v.translation.height < -130, BuyLink.url(item) != nil { act(.buy, f, item) }
                                        else { withAnimation(.spring(response: 0.3)) { drag = .zero } }
                                    }
                            )
                    }
                    buttons(f, item)
                } else {
                    done
                }
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(LitBackground())
            .navigationTitle("Swipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { if ids.isEmpty { ids = store.swipeQueue.map(\.id) } }
        }
    }

    private enum Action { case like, pass, buy, watch }

    @ViewBuilder private var stamp: some View {
        if watchStamp {
            VStack(spacing: 8) {
                label(String(localized: "NOW WATCHING"), Theme.warn)
                Text("We'll text you if the price drops or it restocks.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.bg.opacity(0.85), in: Capsule())
            }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else if drag.width > 40 {
            label("LIKE", Theme.green).opacity(min(1, Double(drag.width) / 110))
        } else if drag.width < -40 {
            label("PASS", Theme.hot).opacity(min(1, Double(-drag.width) / 110))
        } else if drag.height < -50 {
            label("BUY", Theme.accent).opacity(min(1, Double(-drag.height) / 130))
        }
    }

    private func label(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 28, weight: .heavy)).tracking(2).foregroundStyle(c)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(c, lineWidth: 3))
            .rotationEffect(.degrees(-10))
            .padding(.top, 24)
    }

    private func card(_ f: Find, _ item: Item) -> some View {
        let agent = store.agent(f.agentID)
        return VStack(alignment: .leading, spacing: 10) {
            Plate(item: item, label: store.whenLabel(item), live: store.isLive(item), height: 280)
            HStack(spacing: 6) {
                if let a = agent { AgentAvatarView(agent: a, size: 22); Text(a.name).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted) }
                Spacer()
                Text("\(f.score)% match").font(.caption.monospacedDigit().weight(.bold)).foregroundStyle(f.score >= 80 ? Theme.green : Theme.accent)
            }
            Text(item.title).font(.title3.weight(.heavy)).foregroundStyle(Theme.ink).lineLimit(3)
            Text([item.source, item.priceKnown && item.price > 0 ? item.priceLabel : String(localized: "Price at store")].joined(separator: " · "))
                .font(.subheadline).foregroundStyle(Theme.muted)
            if AboutBlock.has(item) { AboutBlock(item: item, lines: 3) }
            if let v = DealVerdict.of(item) { VerdictChip(verdict: v, showDetail: true) }
            if let why = f.why.first { Text(why).font(.footnote).foregroundStyle(Theme.green.opacity(0.9)).lineLimit(3) }
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    }

    private func buttons(_ f: Find, _ item: Item) -> some View {
        HStack(spacing: 18) {
            round("xmark", Theme.hot, String(localized: "Pass")) { act(.pass, f, item) }
            if BuyLink.url(item) != nil { round("arrow.up.right", Theme.accent, String(localized: "Buy")) { act(.buy, f, item) } }
            round(f.watching ? "eye.fill" : "eye", Theme.warn, f.watching ? String(localized: "Watching") : String(localized: "Watch")) { act(.watch, f, item) }
            round("heart.fill", Theme.green, String(localized: "Like"), big: true) { act(.like, f, item) }
        }
    }

    private func round(_ icon: String, _ tint: Color, _ name: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: big ? 24 : 18, weight: .bold)).foregroundStyle(tint)
                .frame(width: big ? 66 : 54, height: big ? 66 : 54)
                .background(Theme.glass, in: Circle())
                .overlay(Circle().strokeBorder(tint.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }

    private func act(_ a: Action, _ f: Find, _ item: Item) {
        guard !busy else { return }
        if a == .watch {
            // Already watching: stop, and stay on this card.
            if f.watching { store.toggleWatch(f.id); router.say(String(localized: "Stopped watching")); return }
            store.toggleWatch(f.id)
            Analytics.track(.swipe, ["action": "watch", "category": item.category.rawValue, "score": f.score])
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            busy = true
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { watchStamp = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                withAnimation(.easeIn(duration: 0.22)) { drag = CGSize(width: 0, height: 900) }
                try? await Task.sleep(for: .milliseconds(230))
                watchStamp = false
                drag = .zero
                index += 1
                busy = false
            }
            return
        }
        let out: CGSize
        switch a {
        case .watch: return
        case .like:
            store.like(f.id); liked += 1; out = CGSize(width: 600, height: drag.height)
        case .pass:
            store.pass(f.id, reason: .style); passed += 1; out = CGSize(width: -600, height: drag.height)
        case .buy:
            out = CGSize(width: 0, height: -900)
            if let link = BuyLink.url(item) {
                Analytics.track(.checkoutOpened, ["category": item.category.rawValue, "toStore": true, "from": "swipe"])
                router.buyOpened = f.id
                openURL(BuyLink.tracked(item, from: "swipe") ?? link)
            }
        }
        Analytics.track(.swipe, ["action": "\(a)", "category": item.category.rawValue, "score": f.score])
        withAnimation(.easeIn(duration: 0.22)) { drag = out }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(230))
            drag = .zero
            index += 1
        }
    }

    private var done: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 40)
            Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(Theme.green)
            Text(ids.isEmpty ? String(localized: "No new finds right now") : String(localized: "All caught up")).font(.title2.weight(.heavy)).foregroundStyle(Theme.ink)
            Text(ids.isEmpty ? String(localized: "Your squad keeps hunting in the background and will text you.") :
                    String(localized: "\(liked) liked, \(passed) passed. Your squad just got sharper; their next search uses it."))
                .font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Button("Back to Today") { dismiss() }.buttonStyle(PrimaryButton()).frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity)
    }
}
