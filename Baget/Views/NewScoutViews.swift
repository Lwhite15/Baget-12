import SwiftUI

/// "Send a new scout": a button (not a search box), so nobody mistakes it for search. Tapping it opens a short sheet
/// that explains a scout hunts in the background for days. After sending, the card becomes the scout's confirmation.
struct NewScoutCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    /// Squad shows the short version.
    var compact = false

    var body: some View {
        if !compact, let sent = router.scoutSent, let a = store.agent(sent.agentID) {
            VStack(alignment: .leading, spacing: 10) {
                confirmation(a, intro: sent.intro)
                HStack {
                    Spacer()
                    Button { router.sheet = .newScout } label: { Label("Send another scout", systemImage: "plus") }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.cyan).buttonStyle(.plain)
                }
            }
        } else {
            Button { router.sheet = .newScout; Analytics.track(.huntStarted, ["from": compact ? "squad" : "today", "step": "open"]) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.title3.weight(.heavy)).foregroundStyle(Theme.accentInk)
                        .frame(width: 42, height: 42).background(Theme.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(compact ? String(localized: "New scout") : String(localized: "Send a new scout")).font(.headline).foregroundStyle(Theme.ink)
                        if !compact {
                            Text("Tell a scout what to hunt. It keeps looking for days and texts you what it finds.")
                                .font(.caption).foregroundStyle(Theme.ink.opacity(0.75)).multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(Theme.cyan)
                }
                .padding(14)
                .background(LinearGradient(colors: [Theme.blue.opacity(0.22), Theme.green.opacity(0.14)], startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.16)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens a short form to describe what your new scout should hunt")
        }
    }

    private func confirmation(_ a: Agent, intro: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                AgentAvatarView(agent: a, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(a.name) is on it").font(.headline).foregroundStyle(Theme.ink)
                    Text(intro).font(.footnote).foregroundStyle(Theme.ink.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                    Button("Tell it more") { router.sheet = .chat(a.id) }.font(.footnote.weight(.semibold)).foregroundStyle(Theme.cyan).buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Button { withAnimation { router.scoutSent = nil } } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Theme.muted) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss")
            }
            if store.isCloud {
                HStack(alignment: .top, spacing: 8) {
                    step("checkmark", Theme.green, String(localized: "READY"), String(localized: "Your scout knows what to look for"))
                    step("circle.fill", Theme.warn, String(localized: "HUNTING"), String(localized: "First finds in a few minutes"))
                    step("arrow.right", Theme.cyan, String(localized: "ONGOING"), String(localized: "Keeps hunting every few hours"))
                }
            }
        }
        .padding(14)
        .background(LinearGradient(colors: [Theme.green.opacity(0.14), Theme.blue.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.green.opacity(0.35)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func step(_ icon: String, _ tint: Color, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon).labelStyle(.titleAndIcon).font(.system(size: 10, weight: .heavy)).foregroundStyle(tint)
            Text(text).font(.caption2).foregroundStyle(Theme.ink.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// The short sheet behind "Send a new scout".
struct NewScoutSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var working = false
    @FocusState private var focused: Bool

    private static let examples: [(String, String)] = [
        ("eyeglasses", String(localized: "Black Dior men's sunglasses")),
        ("watch.analog", String(localized: "A vintage Rolex Explorer, any year")),
        ("shoe.fill", String(localized: "Jordan 1 Lows in my size, under $200")),
        ("drop.fill", String(localized: "Oud fragrances like Frédéric Malle")),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Spacer()
                    CloseButton { dismiss() }
                }
                Text("What should your new scout hunt?").font(.system(size: 24, weight: .heavy)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Describe it like you'd tell a friend. Your scout hunts in the background for days, across stores, resale and boutiques.")
                    .font(.subheadline).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                TextField("e.g. black Dior men's sunglasses, under $500", text: $text, axis: .vertical)
                    .lineLimit(3...5)
                    .focused($focused)
                    .submitLabel(.send)
                    .padding(14)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(focused ? Theme.cyan.opacity(0.7) : Theme.line, lineWidth: 1.5))
                    .onChange(of: text) { _, t in
                        if t.contains("\n") { text = t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces); send() }
                    }
                Text("OR START FROM ONE OF THESE").font(.caption.weight(.heavy)).tracking(1.1).foregroundStyle(Theme.muted).padding(.top, 2)
                VStack(spacing: 7) {
                    ForEach(Self.examples, id: \.1) { icon, ex in
                        Button { text = ex; focused = true } label: {
                            HStack(spacing: 10) {
                                Image(systemName: icon).foregroundStyle(Theme.cyan).frame(width: 20)
                                Text(ex).font(.subheadline).foregroundStyle(Theme.ink)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 8) {
                    how("binoculars.fill", String(localized: "Hunts the web for days"))
                    how("sparkles", String(localized: "New finds land in Finds"))
                    how("message.fill", String(localized: "Texts you the best ones"))
                }
                .padding(.top, 2)
                Button(action: send) {
                    HStack {
                        if working { ProgressView().tint(Theme.accentInk) }
                        Text(working ? String(localized: "Sending…") : String(localized: "Send scout"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButton())
                .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 ? 0.5 : 1)
                if let p = store.syncProblem, !working, p != "" {
                    Text(p).font(.footnote).foregroundStyle(Theme.hot)
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(LitBackground())
        .presentationDetents([.large])
        .onAppear { store.syncProblem = nil; focused = true }
    }

    private func how(_ icon: String, _ label: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.subheadline).foregroundStyle(Theme.cyan)
            Text(label).font(.caption2).foregroundStyle(Theme.ink.opacity(0.8)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(9)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, !working else { return }
        focused = false
        working = true
        Task { @MainActor in
            defer { working = false }
            guard let r = await store.hunt(t) else { return }   // the reason shows under the button
            withAnimation { router.scoutSent = (r.agentID, r.intro) }
            router.tab = .live
            dismiss()
            if r.needsSize {   // its first question will be your size
                try? await Task.sleep(for: .milliseconds(450))
                router.sheet = .chat(r.agentID)
            }
        }
    }
}

/// "See all" from Today's For You: the full ranked grid, with category filters.
struct ForYouScreen: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                ForYouSection(mode: .full).padding(.horizontal, 16).padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(LitBackground())
            .navigationTitle("For You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
