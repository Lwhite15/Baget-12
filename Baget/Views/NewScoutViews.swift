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
                            Text("Tell a scout what you're into. It keeps hunting for weeks and texts you what it finds.")
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
                    HStack(spacing: 6) {
                        Text("\(a.name) is on it").font(.headline).foregroundStyle(Theme.ink)
                        FocusTag(specific: a.isSpecific)
                    }
                    Text(intro).font(.footnote).foregroundStyle(Theme.ink.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                    Button("Tell it more") { router.sheet = .chat(a.id) }.font(.footnote.weight(.semibold)).foregroundStyle(Theme.cyan).buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Button { withAnimation { router.scoutSent = nil } } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Theme.muted) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss")
            }
            if !a.isSpecific, !ScoutLanes.lanes(a).isEmpty {
                ScoutLanes(agent: a)
            } else if store.isCloud {
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

/// The short sheet behind "Send a new scout". Starts from what you're into (the scout hunts that whole world for weeks);
/// "Hunting one specific thing?" switches to a tight hunt for one item.
struct NewScoutSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var specific = false
    @State private var working = false
    @State private var starters: [String] = []
    @FocusState private var focused: Bool

    /// Interests to start from, well beyond fashion. A fresh mix each time the sheet opens.
    private static let interests: [String] = [
        String(localized: "Retro Jordans"), String(localized: "Vintage workwear"), String(localized: "Indie perfume houses"),
        String(localized: "Fly fishing gear"), String(localized: "Road bike gear"), String(localized: "Mid-century lamps"),
        String(localized: "Tool watches"), String(localized: "Vinyl records"), String(localized: "Camping gear"),
        String(localized: "Golf clubs"), String(localized: "Mechanical keyboards"), String(localized: "Film cameras"),
        String(localized: "Trading cards"), String(localized: "Japanese kitchen knives"), String(localized: "Trail running shoes"),
        String(localized: "Quiet luxury basics"), String(localized: "Bass fishing lures"), String(localized: "Mountain bike parts"),
        String(localized: "Streetwear drops"), String(localized: "Coffee gear"), String(localized: "Home gym equipment"),
        String(localized: "Vintage denim"), String(localized: "Board games"), String(localized: "Ski and snowboard gear"),
    ]

    private static let examples: [(String, String)] = [
        ("eyeglasses", String(localized: "Black Dior men's sunglasses")),
        ("watch.analog", String(localized: "A vintage Rolex Explorer, any year")),
        ("shoe.fill", String(localized: "Jordan 1 Lows in my size, under $200")),
        ("bicycle", String(localized: "A used Specialized Tarmac, 56cm")),
    ]

    private var ready: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    if specific {
                        Button { withAnimation(.snappy) { specific = false; text = "" } } label: { Label("Back", systemImage: "chevron.left") }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.cyan).buttonStyle(.plain)
                    }
                    Spacer()
                    CloseButton { dismiss() }
                }
                Text(specific ? String(localized: "What are you hunting?") : String(localized: "What are you into?"))
                    .font(.system(size: 24, weight: .heavy)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(specific
                     ? String(localized: "One specific thing: a grail, a size, a price. Your scout tracks just that, across stores, resale and boutiques.")
                     : String(localized: "Describe your taste, not one item. Your scout keeps hunting for weeks and brings you things you didn't know to look for."))
                    .font(.subheadline).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                TextField(specific ? String(localized: "e.g. black Dior men's sunglasses, under $500")
                                   : String(localized: "e.g. indie perfume houses, citrus and green scents, nothing too sweet"),
                          text: $text, axis: .vertical)
                    .lineLimit(3...5)
                    .focused($focused)
                    .submitLabel(.send)
                    .padding(14)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(focused ? Theme.cyan.opacity(0.7) : Theme.line, lineWidth: 1.5))
                    .onChange(of: text) { _, t in
                        if t.contains("\n") { text = t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces); send() }
                    }
                if specific { examplesList } else { startersGrid }
                Button(action: send) {
                    HStack {
                        if working { ProgressView().tint(Theme.accentInk) }
                        Text(working ? String(localized: "Sending…") : String(localized: "Send scout"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButton())
                .disabled(working || !ready)
                .opacity(ready ? 1 : 0.5)
                if let p = store.syncProblem, !working, p != "" {
                    Text(p).font(.footnote).foregroundStyle(Theme.hot)
                }
                if !specific {
                    Button { withAnimation(.snappy) { specific = true; text = ""; focused = true } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "scope").font(.title3).foregroundStyle(Theme.hot)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Hunting one specific thing?").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                Text("A grail, a size, a price. Your scout tracks just that.").font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(Theme.cyan)
                        }
                        .padding(12)
                        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(LitBackground())
        .presentationDetents([.large])
        .onAppear {
            store.syncProblem = nil
            if starters.isEmpty { starters = Array(Self.interests.shuffled().prefix(12)) }
        }
    }

    private var startersGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OR START FROM ONE OF THESE").font(.caption.weight(.heavy)).tracking(1.1).foregroundStyle(Theme.muted).padding(.top, 2)
            FlowRow {
                ForEach(starters, id: \.self) { s in
                    let on = text.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(s) == .orderedSame
                    Button { text = on ? "" : s } label: {
                        Text(s).font(.footnote.weight(on ? .bold : .regular))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 11).padding(.vertical, 8)
                            .background(Capsule().fill(on ? Theme.cyan.opacity(0.16) : Theme.glass))
                            .overlay(Capsule().strokeBorder(on ? Theme.cyan.opacity(0.6) : Theme.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private var examplesList: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("FOR EXAMPLE").font(.caption.weight(.heavy)).tracking(1.1).foregroundStyle(Theme.muted).padding(.top, 2)
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
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, !working else { return }
        focused = false
        working = true
        Task { @MainActor in
            defer { working = false }
            guard let r = await store.hunt(t, specific: specific) else { return }   // the reason shows under the button
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

/// What an interest scout will hunt, in four short boxes: makers, styles, what it skips, what it's after.
struct ScoutLanes: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let agent: Agent

    static func lanes(_ a: Agent) -> [(String, String)] {
        let fragrance = a.mission.category == .fragrance
        let skips = a.learned.filter { $0.value < 0 }.sorted { $0.value < $1.value }.map(\.key)
        return [
            (fragrance ? String(localized: "HOUSES") : String(localized: "BRANDS"), (a.style.makers + a.style.creators).prefix(4).map(\.brandCased).joined(separator: ", ")),
            (fragrance ? String(localized: "NOTES") : String(localized: "STYLE"), a.style.traits.prefix(4).joined(separator: ", ")),
            (String(localized: "LOOKING FOR"), a.keywords.prefix(4).joined(separator: ", ")),
            (String(localized: "SKIPS"), skips.prefix(4).joined(separator: ", ")),
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        let lanes = Self.lanes(agent)
        if !lanes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], alignment: .leading, spacing: 7) {
                    ForEach(lanes, id: \.0) { title, value in
                        Button { if store.isCloud { router.sheet = .chat(agent.id) } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title).font(.system(size: 10, weight: .heavy)).tracking(0.6).foregroundStyle(Theme.cyan)
                                Text(value.capitalizedFirst).font(.caption).foregroundStyle(Theme.ink.opacity(0.85)).lineLimit(2).multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                            .padding(8)
                            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Tap a box to tell your scout what to change. Liking and passing finds sharpens it too.")
                    .font(.caption2).foregroundStyle(Theme.muted)
            }
        }
    }
}

/// A small label: what you're into, or one specific hunt.
struct FocusTag: View {
    let specific: Bool
    var body: some View {
        Text(specific ? String(localized: "SPECIFIC") : String(localized: "INTEREST"))
            .font(.system(size: 9, weight: .heavy)).tracking(0.6)
            .foregroundStyle(specific ? Theme.warn : Theme.green)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background((specific ? Theme.warn : Theme.green).opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// A specific hunt that's done (you bought it): keep the scout going on what you're into, or retire it.
struct HuntDoneCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @AppStorage("baget.huntsDone") private var dismissedRaw = ""
    @State private var working: String?
    @State private var confirmRetire: Agent?

    private var done: [(Agent, Purchase)] {
        let dismissed = Set(dismissedRaw.split(separator: ",").map(String.init))
        return store.state.agents.compactMap { a in
            guard a.isSpecific, !dismissed.contains(a.id),
                  let p = store.state.purchases.filter({ $0.agentID == a.id }).max(by: { $0.date < $1.date }) else { return nil }
            return (a, p)
        }
    }

    var body: some View {
        ForEach(done, id: \.0.id) { a, p in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "scope").foregroundStyle(Theme.warn)
                    Text("\(a.name) found your grail").font(.headline).foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    Button { dismiss(a.id) } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Theme.muted) }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss")
                }
                Text("You bought \(p.title). Want this scout to keep going on what you're into instead?")
                    .font(.footnote).foregroundStyle(Theme.ink.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        working = a.id
                        Task { @MainActor in
                            defer { working = nil }
                            if let name = await store.broaden(a.id) {
                                dismiss(a.id)
                                router.say(String(localized: "\(name) is hunting the wider world of it now"))
                            }
                        }
                    } label: {
                        HStack { if working == a.id { ProgressView().tint(Theme.accentInk) }; Text("Keep hunting this kind of thing") }
                            .font(.footnote.weight(.heavy)).frame(maxWidth: .infinity).padding(.vertical, 10)
                            .foregroundStyle(Theme.accentInk).background(Theme.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain).disabled(working != nil)
                    Button { confirmRetire = a } label: {
                        Text("Retire scout").font(.footnote.weight(.heavy)).frame(maxWidth: .infinity).padding(.vertical, 10)
                            .foregroundStyle(Theme.ink).background(Theme.glass, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
                    }
                    .buttonStyle(.plain).disabled(working != nil)
                }
            }
            .padding(14)
            .background(LinearGradient(colors: [Theme.warn.opacity(0.14), Theme.blue.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.warn.opacity(0.4)))
        }
        .confirmationDialog("Retire \(confirmRetire?.name ?? "")?", isPresented: Binding(get: { confirmRetire != nil }, set: { if !$0 { confirmRetire = nil } }), titleVisibility: .visible) {
            Button("Retire", role: .destructive) { if let a = confirmRetire { store.retire(a.id); router.say(String(localized: "\(a.name) retired")) } }
        } message: { Text("It stops hunting. Your finds and what it learned about your taste stay.") }
    }

    private func dismiss(_ id: String) {
        var xs = dismissedRaw.split(separator: ",").map(String.init)
        if !xs.contains(id) { xs.append(id) }
        withAnimation { dismissedRaw = xs.suffix(30).joined(separator: ",") }
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

extension String {
    /// Brand names saved in lowercase ("seiko", "audio-technica") shown as names ("Seiko", "Audio-Technica"); mixed case is kept.
    var brandCased: String { self == lowercased() ? capitalized : self }
}
