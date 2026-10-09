import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("baget.onboarded") private var onboarded = false

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            screen(TodayView()).tabItem { Label("Today", systemImage: "sun.max.fill") }.tag(AppTab.live)
            screen(FindsView()).tabItem { Label("Finds", systemImage: "sparkles") }.tag(AppTab.finds)
                .badge(store.state.finds.filter { $0.status == .open }.count)
            screen(SquadView()).tabItem { Label("Squad", systemImage: "person.3.fill") }.tag(AppTab.squad)
            screen(FriendsView()).tabItem { Label("Friends", systemImage: "heart.circle.fill") }.tag(AppTab.friends)
                .badge(store.state.suggestions.filter { $0.status == .new }.count)
        }
        .tint(Theme.accent)
        .overlay(alignment: .top) { bannerView }
        .overlay(alignment: .bottom) { toastView }
        .sheet(item: $router.sheet) { sheet in
            Group {
                switch sheet {
                case .inbox: InboxView()
                case .deploy: DeployAgentView(prefill: router.deployPrefill)
                case .customizeBar: CustomizeBarView()
                case .profile: ProfileView()
                case .checkout(let id): CheckoutView(findID: id)
                case .share(let itemID, let friendID, let suggestion): ShareView(itemID: itemID, preselect: friendID, isSuggestion: suggestion)
                case .suggestFor(let fid): SuggestForView(friendID: fid)
                case .tastePhoto(let aid): TastePhotoView(agentID: aid)
                case .chat(let aid): ChatView(agentID: aid)
                case .agentIcon(let aid): AgentIconView(agentID: aid)
                case .swipe: SwipeDeckView()
                case .taste: TasteView()
                case .ask(let fid):
                    if let f = store.state.finds.first(where: { $0.id == fid }) { ChatView(agentID: f.agentID, aboutFindID: fid) }
                }
            }
            .environment(store)
            .environment(router)
            .preferredColorScheme(.dark)
            .presentationBackground(Theme.panel)
        }
        .onChange(of: store.openNoteFromSystem) { _, id in
            guard let id else { return }
            store.openNoteFromSystem = nil
            Task { @MainActor in
                if store.isCloud && !store.state.notes.contains(where: { $0.id == id }) { await store.pull() }
                open(noteID: id)
            }
        }
        .onChange(of: store.syncProblem) { _, problem in
            guard let problem else { return }
            store.syncProblem = nil
            router.say(problem)
        }
        // Back from a store after tapping Buy: did you buy it? A yes is logged and teaches the agent.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let id = router.buyOpened else { return }
            router.buyOpened = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                if store.state.finds.contains(where: { $0.id == id && $0.status != .acquired }) { router.askBought = id }
            }
        }
        .alert(boughtTitle, isPresented: Binding(get: { router.askBought != nil }, set: { if !$0 { router.askBought = nil } })) {
            Button("Yes, I bought it") {
                if let id = router.askBought, let f = store.state.finds.first(where: { $0.id == id }), let item = Catalog.item(f.itemID) {
                    let amount = item.priceKnown ? item.price : 0
                    store.confirmPurchase(id, amount: amount)
                    Analytics.track(.purchaseConfirmed, ["amount": amount, "category": item.category.rawValue, "score": f.score, "from": "buy"])
                    router.say("Nice. It's off your list, and \(store.agent(f.agentID)?.name ?? "your agent") will find more like it.")
                }
                router.askBought = nil
            }
            Button("Not yet", role: .cancel) { router.askBought = nil }
        } message: {
            Text("Your agent learns the most from what you actually buy.")
        }
        // First run after signing in with no agents yet: the 30-second setup.
        .fullScreenCover(isPresented: Binding(get: { !store.needsWelcome && store.isCloud && store.state.agents.isEmpty && !onboarded && store.state.lastSynced != nil },
                                              set: { if !$0 { onboarded = true } })) {
            OnboardingView().environment(store)
        }
        .fullScreenCover(isPresented: Binding(get: { store.needsWelcome }, set: { _ in })) {
            WelcomeView().environment(store)
        }
    }

    private func screen<V: View>(_ content: V) -> some View {
        NavigationStack {
            ZStack {
                LitBackground()
                content
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { router.sheet = .profile } label: { AvatarView(size: 30) }
                        .accessibilityLabel("You: icon, settings and account")
                }
                // The name sits in the middle; on iOS 26 a leading text item gets squeezed into a glass bubble.
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 0) {
                        Text("Baget").foregroundStyle(Theme.ink)
                        Text(".").gradientText()
                    }
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(-0.8)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { router.sheet = .inbox } label: {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(Theme.ink)
                            .overlay(alignment: .topTrailing) {
                                if store.unreadCount > 0 {
                                    Text(store.unreadCount > 9 ? "9+" : "\(store.unreadCount)")
                                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                        .padding(3).background(Circle().fill(Theme.hot)).offset(x: 9, y: -8)
                                }
                            }
                    }
                    .accessibilityLabel("Notifications, \(store.unreadCount) unread")
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
    }


    private var boughtTitle: String {
        guard let id = router.askBought, let f = store.state.finds.first(where: { $0.id == id }),
              let item = Catalog.item(f.itemID) else { return "Did you buy it?" }
        return "Did you buy the \(item.title)?"
    }

    @ViewBuilder private var bannerView: some View {
        if let n = store.banner {
            Button {
                store.banner = nil
                router.sheet = .inbox
            } label: {
                HStack(alignment: .top, spacing: 11) {
                    NoteIcon(note: n)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(store.noteSender(n)).font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink)
                            Spacer()
                            Text("now").font(.caption2).foregroundStyle(Theme.muted)
                        }
                        Text(n.body).font(.subheadline).foregroundStyle(Theme.ink).multilineTextAlignment(.leading).lineLimit(3)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line))
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder private var toastView: some View {
        if let t = router.toast {
            Text(t)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(Theme.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line))
                .padding(.bottom, 64)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func open(noteID: String) {
        guard let n = store.state.notes.first(where: { $0.id == noteID }) else { return }
        store.markRead([noteID])
        Analytics.track(.notificationOpened, ["kind": n.kind.rawValue])
        if n.friendID != nil { router.tab = .friends; return }
        if n.kind == .digest { router.tab = .live; return }   // Today's Drop
        if let fid = n.findID, store.state.finds.contains(where: { $0.id == fid }) {
            router.focusFind = fid
            router.tab = .finds
        } else {
            router.tab = n.kind == .learned ? .squad : .finds
        }
    }
}

struct AppIcon: View {
    var size: CGFloat = 36
    var body: some View {
        Text("B")
            .font(.system(size: size * 0.5, weight: .heavy))
            .foregroundStyle(Theme.accentInk)
            .frame(width: size, height: size)
            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// The sender's icon on a notification: the agent's own icon, or Baget's.
struct NoteIcon: View {
    @Environment(AppStore.self) private var store
    let note: AppNote
    var body: some View {
        if note.friendID == nil, let id = note.agentID, let a = store.agent(id) {
            AgentAvatarView(agent: a, size: 36)
        } else {
            AppIcon()
        }
    }
}
