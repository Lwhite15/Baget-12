import SwiftUI
import PhotosUI

/// "What Baget knows about you": everything each agent has been told or has learned, as chips you can remove.
struct TasteView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Tap ✕ on anything that isn't you. Scouts stop using it on their next search. Like, pass and chat to teach them more.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                    if store.state.agents.isEmpty { EmptyCard(text: "No scouts yet. Tell Baget what you're hunting on Today.") }
                    ForEach(store.state.agents) { a in agentCard(a) }
                }
                .padding(16)
            }
            .background(LitBackground())
            .navigationTitle("What Baget knows")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func agentCard(_ a: Agent) -> some View {
        let likes = uniq(a.style.makers + a.style.creators + a.keywords + a.style.traits
                         + a.learned.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.map(\.key))
        let dislikes = a.learned.filter { $0.value < 0 }.sorted { $0.value < $1.value }.map(\.key)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentAvatarView(agent: a, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.name).font(.headline).foregroundStyle(Theme.ink)
                    Text(a.mission.label.capitalizedFirst).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                Button("Teach more") { router.sheet = .chat(a.id) }.font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            if !a.size.isEmpty { group("Size", [a.size], a.id, tint: Theme.accent) }
            if a.priceNote > 0 { group("Price", ["Prefers under \(Fmt.money(a.priceNote))"], a.id, tint: Theme.warn, keys: ["__price"]) }
            if !likes.isEmpty { group("Into", likes, a.id, tint: Theme.green) }
            if !dislikes.isEmpty { group("Not into", dislikes, a.id, tint: Theme.hot) }
            if likes.isEmpty && dislikes.isEmpty && a.size.isEmpty {
                Text("Nothing yet. Like or pass a few finds, or tell it what you love.").font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .glassCard()
    }

    private func group(_ title: String, _ values: [String], _ agentID: String, tint: Color, keys: [String]? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Theme.muted)
            FlowRow {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    Button { withAnimation { store.removeTaste(agentID, keys?[i] ?? v) } } label: {
                        HStack(spacing: 5) {
                            Text(v).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(tint.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(v)")
                }
            }
        }
    }

    private func uniq(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert(TextMatch.norm($0)).inserted }.prefix(24).map { $0 }
    }
}

/// First run: what you're into, optionally three photos of things you love, and your squad is built and hunting.
struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("baget.onboarded") private var onboarded = false
    @State private var step = 0
    @State private var picked: Set<Category> = []
    @State private var extras: Set<String> = []
    @State private var text = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var tileMenu: Int?
    @State private var replacing: Int?
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var photos: [UIImage] = []
    @State private var working = false
    @State private var made = 0
    // Taste check
    @State private var quiz: [Item] = []
    @State private var quizIndex = 0
    @State private var quizLoading = false
    @State private var liked: [String] = []
    @State private var passed: [String] = []
    // Vibes and budget, in plain words
    @State private var vibes: [Category: Set<String>] = [:]
    @State private var budget: Int? = nil
    @State private var brands: [Category: Set<String>] = [:]
    @State private var sizes: [Category: String] = [:]
    @State private var editingWords = false
    // First hunt
    @State private var pushOn = false
    @State private var watching = false
    @State private var showPro = false

    private let steps = 5

    var body: some View {
        ZStack {
            LitBackground()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    ForEach(0..<steps, id: \.self) { i in Capsule().fill(i <= step ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.glass)).frame(height: 4) }
                }
                switch step {
                case 0: interests
                case 1: vibeStep
                case 2: tasteCheck
                case 3: photoStep
                default: firstHunt
                }
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $editingWords) {
            OwnWordsEditor(text: $text).presentationDetents([.large]).presentationBackground(Theme.panel)
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { @MainActor in
                for it in items.prefix(3) {
                    if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d) { addPhoto(img) }
                }
                pickerItems = []
            }
        }
    }

    // MARK: 1. Interests

    /// Interests beyond the built-in categories. Each becomes its own scout with a custom mission.
    static let moreInterests = ["Tech & gadgets", "Home decor", "Bags", "Jewelry", "Beauty & skincare", "Vinyl & music",
                                "Art & prints", "Outdoor gear", "Toys & games", "Books", "Vintage", "Gifts"]

    private var pickedCount: Int { picked.count + extras.count }
    private var full: Bool { pickedCount >= store.scoutLimit }

    private var interests: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What are you into?").font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.ink)
            Text(store.scoutLimit >= 5 ? "Pick a few. You'll get a personal scout for each, hunting drops, restocks and deals."
                                       : "Pick up to \(store.scoutLimit). You'll get a personal scout for each, hunting drops, restocks and deals.")
                .font(.subheadline).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FlowRow {
                        ForEach(Category.allCases.filter { $0 != .other }) { c in
                            Button {
                                if picked.contains(c) { picked.remove(c) }
                                else if !full { picked.insert(c) }
                            } label: { Pill(text: c.info.label, selected: picked.contains(c)) }
                                .opacity(!picked.contains(c) && full ? 0.4 : 1)
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(picked.contains(c) ? .isSelected : [])
                        }
                        ForEach(Self.moreInterests, id: \.self) { i in
                            Button {
                                if extras.contains(i) { extras.remove(i) }
                                else if !full { extras.insert(i) }
                            } label: { Pill(text: i, selected: extras.contains(i)) }
                                .opacity(!extras.contains(i) && full ? 0.4 : 1)
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(extras.contains(i) ? .isSelected : [])
                        }
                    }
                    if full && store.isCloud && !store.isPro {
                        Text("Free includes 2 scouts. You can go Pro any time for up to 5, hunting around the clock.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tell your scouts in your own words")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        Text("The more you share, the better Baget gets. Be as descriptive as you like: brands you love, styles, colors, materials, sizes, your budget, what you're hunting for and why. Anything not listed above, just describe it and your scouts will find it.")
                            .font(.caption).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "sparkles").font(.caption2).foregroundStyle(Theme.cyan)
                            Text("“Vintage Rolex Datejust 36, champagne dial, under $6k” finds far more than “watches.”")
                                .font(.caption.italic()).foregroundStyle(Theme.ink.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // Opens a full-height editor, so what you write stays readable while you type.
                        Button { editingWords = true } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text(text.isEmpty ? "Describe what you love and what you're looking for" : text)
                                    .font(.body).foregroundStyle(text.isEmpty ? Theme.muted : Theme.ink)
                                    .multilineTextAlignment(.leading).lineLimit(6)
                                    .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
                                Image(systemName: text.isEmpty ? "square.and.pencil" : "pencil").foregroundStyle(Theme.accent)
                            }
                            .padding(12)
                            .background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(text.isEmpty ? "Describe what you love and what you're looking for" : "Your description: \(text)")
                    }
                    .padding(.top, 4)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            Button("Next") { if picked.isEmpty { startQuiz() } else { withAnimation { step = 1 } } }
                .buttonStyle(PrimaryButton())
                .disabled(pickedCount == 0 && text.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Skip setup") { finish() }.font(.footnote).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
        }
    }

    // MARK: 2. Your vibe, in plain words (no brand knowledge needed)

    private var vibeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your taste").font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.ink)
            Text("Tap the brands you love and the vibe you're after. New to a brand? Your scouts will tell you about every one they find.")
                .font(.subheadline).foregroundStyle(Theme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Category.allCases.filter { picked.contains($0) }) { c in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(c.info.label, systemImage: c.info.symbol)
                                .font(.headline).foregroundStyle(Theme.ink)
                            Text("Brands you like").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                            FlowRow {
                                ForEach(Vibes.brands(c), id: \.self) { b in
                                    let on = brands[c, default: []].contains(b)
                                    Button {
                                        if on { brands[c, default: []].remove(b) } else { brands[c, default: []].insert(b) }
                                    } label: { Pill(text: b, selected: on) }
                                        .buttonStyle(.plain)
                                        .accessibilityAddTraits(on ? .isSelected : [])
                                }
                            }
                            if let options = Vibes.sizes(c) {
                                // Sneaker and clothing scouts only flag what's in stock in your size, so ask here.
                                Text(c == .sneakers ? "Your shoe size (US men's)" : "Your size").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted).padding(.top, 4)
                                ScrollView(.horizontal) {
                                    HStack(spacing: 8) {
                                        ForEach(options, id: \.self) { z in
                                            let on = sizes[c] == z
                                            Button { sizes[c] = on ? nil : z } label: { Pill(text: z, selected: on) }
                                                .buttonStyle(.plain)
                                                .accessibilityLabel("Size \(z)")
                                                .accessibilityAddTraits(on ? .isSelected : [])
                                        }
                                    }
                                }
                                .scrollIndicators(.hidden)
                                if sizes[c] == nil {
                                    Text(c == .sneakers ? "Women's or EU? Put it in your own words on the first screen." : "Pants or a specific fit? Put it in your own words on the first screen.")
                                        .font(.caption2).foregroundStyle(Theme.muted)
                                }
                            }
                            Text(Vibes.question(c)).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted).padding(.top, 4)
                            FlowRow {
                                ForEach(Vibes.options(c), id: \.self) { v in
                                    let on = vibes[c, default: []].contains(v)
                                    Button {
                                        if on { vibes[c, default: []].remove(v) } else { vibes[c, default: []].insert(v) }
                                    } label: { Pill(text: v, selected: on) }
                                        .buttonStyle(.plain)
                                        .accessibilityAddTraits(on ? .isSelected : [])
                                }
                            }
                        }
                    }
                    if picked.contains(where: { $0 != .cars }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("How much do you usually spend on one thing?", systemImage: "dollarsign.circle")
                            .font(.headline).foregroundStyle(Theme.ink)
                        FlowRow {
                            ForEach(Vibes.budgets, id: \.label) { b in
                                Button { budget = budget == b.cap ? nil : b.cap } label: { Pill(text: b.label, selected: budget == b.cap) }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(budget == b.cap ? .isSelected : [])
                            }
                        }
                    }
                    }
                }
                .padding(.bottom, 8)
            }
            Button(vibes.values.allSatisfy(\.isEmpty) && brands.values.allSatisfy(\.isEmpty) && budget == nil && sizes.isEmpty ? "Skip" : "Next") { startQuiz() }
                .buttonStyle(PrimaryButton())
            Button("Back") { withAnimation { step = 0 } }.font(.footnote).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
        }
    }

    // MARK: 3. Quick taste check

    private func startQuiz() {
        withAnimation { step = 2 }
        quizLoading = true
        Task { @MainActor in
            quiz = await store.tasteQuiz(Array(picked), brands: brands.values.flatMap { Array($0) })
            quizIndex = 0
            quizLoading = false
            if quiz.isEmpty { withAnimation { step = 3 } }   // nothing to rate yet: go straight on
        }
    }

    private var tasteCheck: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick taste check").font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.ink)
            Text("Heart what you'd wear or buy, ✕ what you wouldn't. Your scouts start from your answers.")
                .font(.subheadline).foregroundStyle(Theme.muted)
            if quizLoading {
                HStack { Spacer(); ProgressView().tint(Theme.cyan); Spacer() }.frame(maxHeight: .infinity)
            } else if quizIndex < quiz.count {
                let item = quiz[quizIndex]
                VStack(alignment: .leading, spacing: 8) {
                    Plate(item: item, label: item.brand.isEmpty ? item.category.info.label : item.brand, height: 300, lead: true)
                        .id(item.id)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                    Text(item.title).font(.headline).foregroundStyle(Theme.ink).lineLimit(2)
                    Text([item.priceKnown && item.price > 0 ? item.priceLabel : nil, item.source].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.muted)
                    if AboutBlock.has(item) { AboutBlock(item: item, lines: 3) }
                }
                Spacer(minLength: 0)
                HStack(spacing: 18) {
                    Button { answer(item, liked: false) } label: {
                        Image(systemName: "xmark").font(.title2.weight(.bold)).foregroundStyle(Theme.hot)
                            .frame(maxWidth: .infinity).frame(height: 60)
                            .background(Theme.glass, in: Capsule()).overlay(Capsule().strokeBorder(Theme.hot.opacity(0.5)))
                    }
                    .accessibilityLabel("Not for me")
                    Button { answer(item, liked: true) } label: {
                        Image(systemName: "heart.fill").font(.title2.weight(.bold)).foregroundStyle(Theme.accentInk)
                            .frame(maxWidth: .infinity).frame(height: 60)
                            .background(Theme.gradient, in: Capsule())
                    }
                    .accessibilityLabel("Love it")
                }
                .buttonStyle(.plain)
                HStack {
                    Text("\(quizIndex + 1) of \(quiz.count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Done") { withAnimation { step = 3 } }.font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            } else {
                Spacer()
                Text(liked.isEmpty ? "Got it." : "Nice taste. \(liked.count) noted.").font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
                Spacer()
                Button("Next") { withAnimation { step = 3 } }.buttonStyle(PrimaryButton())
            }
        }
    }

    private func answer(_ item: Item, liked like: Bool) {
        store.rateInQuiz(item, liked: like)
        let name = [item.brand, item.title.hasPrefix(item.brand) ? String(item.title.dropFirst(item.brand.count)).trimmingCharacters(in: .whitespaces) : item.title]
            .filter { !$0.isEmpty }.joined(separator: " ")
        if like { liked.append(name) } else { passed.append(name) }
        withAnimation(.snappy) {
            quizIndex += 1
            if quizIndex >= quiz.count { step = 3 }
        }
    }

    // MARK: 4. Photos (optional)

    private var photoStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Got photos of things you love?").font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.ink)
            }
            Tag(text: "Optional", tint: Theme.muted)
            Text("Add up to 3 screenshots or photos of pieces you own or want and your scouts read your taste from them. No photos? Skip it.")
                .font(.subheadline).foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    Button { tileMenu = i } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16).fill(Theme.glass)
                            if i < photos.count {
                                Image(uiImage: photos[i]).resizable().scaledToFill()
                            } else {
                                VStack(spacing: 4) {
                                    Image(systemName: i == photos.count ? "camera.fill" : "plus").font(.title3)
                                    if i == photos.count { Text("Add").font(.caption2.weight(.semibold)) }
                                }
                                .foregroundStyle(i == photos.count ? Theme.accent : Theme.muted)
                            }
                        }
                        .frame(maxWidth: .infinity).frame(height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(i == photos.count ? Theme.accent.opacity(0.5) : Theme.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(i < photos.count ? "Photo \(i + 1)" : "Add a photo")
                }
            }
            .confirmationDialog("Photo", isPresented: Binding(get: { tileMenu != nil }, set: { if !$0 { tileMenu = nil } }), titleVisibility: .hidden) {
                let i = tileMenu ?? 0
                if CameraPicker.available {
                    Button(i < photos.count ? "Retake photo" : "Take a photo") { replacing = i < photos.count ? i : nil; showCamera = true }
                }
                Button(i < photos.count ? "Replace from library" : "Choose from library") { replacing = i < photos.count ? i : nil; showLibrary = true }
                if i < photos.count { Button("Remove", role: .destructive) { photos.remove(at: i) } }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { img in addPhoto(img) }.ignoresSafeArea()
            }
            .photosPicker(isPresented: $showLibrary, selection: $pickerItems, maxSelectionCount: replacing == nil ? max(1, 3 - photos.count) : 1,
                          matching: .images, photoLibrary: .shared())
            Spacer()
            if working {
                HStack { Spacer(); ProgressView().tint(Theme.cyan); Text("Building your squad…").foregroundStyle(Theme.muted); Spacer() }
            } else {
                Button(photos.isEmpty ? "Skip and build my squad" : "Build my squad with these") { build() }.buttonStyle(PrimaryButton())
                if !photos.isEmpty {
                    Button("Build without photos") { photos = []; pickerItems = []; build() }
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent).frame(maxWidth: .infinity)
                }
                Button("Back") { withAnimation { step = picked.isEmpty ? 0 : 1 } }.font(.footnote).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
            }
        }
    }

    /// Fills the next empty tile, or replaces the one being changed.
    private func addPhoto(_ img: UIImage) {
        let small = PhotoTaste.normalized(img, maxSide: 1400)
        if let r = replacing, r < photos.count { photos[r] = small; replacing = nil }
        else if photos.count < 3 { photos.append(small) }
    }

    private func build() {
        working = true
        Task { @MainActor in
            let ids = await store.onboard(categories: Array(picked), text: text.trimmingCharacters(in: .whitespacesAndNewlines), photos: photos,
                                          liked: liked, passed: passed,
                                          vibes: vibes.mapValues { Array($0) }, budget: budget.flatMap { $0 > 0 ? $0 : nil },
                                          brands: brands.mapValues { Array($0) }, interests: Array(extras), sizes: sizes)
            working = false
            made = ids.count
            pushOn = await store.pushAllowed
            withAnimation { step = 4 }
            Task { await store.loadForYou() }
            Task { await store.loadProProducts() }
            watchFirstHunt()
        }
    }

    // MARK: 5. The first hunt, live

    private var firstHunt: some View {
        let newest = store.state.finds.filter { $0.status == .open }.sorted { $0.foundAt > $1.foundAt }.prefix(3)
        return VStack(alignment: .leading, spacing: 14) {
            Text(newest.isEmpty ? "Your squad is hunting" : "First finds are in").font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.ink)
            Text(made > 0 ? "They're searching stores, release calendars and resale sites for you right now."
                          : "Tell Baget what you're hunting on Today and a scout starts right away.")
                .font(.subheadline).foregroundStyle(Theme.muted)
            ViewThatFits(in: .vertical) {
                scoutList
                ScrollView { scoutList }.scrollIndicators(.hidden)
            }
            if made > 0 { whatsNext }
            if made > 0, store.isCloud, !store.isPro, let t = store.proTrial { trialCard(t) }
            if !newest.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(newest)) { f in if let item = Catalog.item(f.itemID) { ProductThumb(item: item, size: 70) } }
                }
                .transition(.opacity.combined(with: .scale))
            }
            Spacer()
            if store.isCloud && !pushOn {
                Button {
                    Task { @MainActor in
                        await store.registerForPush()
                        pushOn = await store.pushAllowed
                    }
                } label: { Label("Text me when they find something", systemImage: "bell.badge.fill") }
                    .buttonStyle(PrimaryButton())
                Text("Like a friend texting you a photo of the thing. You choose how often in Settings.")
                    .font(.caption).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                Button(newest.isEmpty ? "Not now, show me Today" : "Not now, see my finds") { finish() }
                    .font(.footnote).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
            } else {
                if pushOn { Label("Texts are on", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Theme.green) }
                Button(newest.isEmpty ? "Show me Today" : "See my finds") { finish() }.buttonStyle(PrimaryButton())
            }
        }
    }

    private var scoutList: some View {
        VStack(spacing: 8) {
            ForEach(store.state.agents) { a in
                    let n = store.state.finds.filter { $0.agentID == a.id }.count
                    HStack(spacing: 10) {
                        AgentAvatarView(agent: a, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                            (Text(n > 0 ? "Found \(n)" : "Searching").foregroundStyle(n > 0 ? Theme.green : Theme.cyan)
                             + Text(" · \(a.mission.label.lowercased())").foregroundStyle(Theme.muted))
                                .font(.caption).lineLimit(1)
                        }
                        Spacer()
                        if n > 0 { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green) }
                        else { ProgressView().controlSize(.small).tint(Theme.cyan) }
                    }
                    .padding(10)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
    }

    /// End of setup: the free trial, for people who can still take it.
    private func trialCard(_ t: String) -> some View {
        Button { showPro = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accentInk)
                    .frame(width: 34, height: 34).background(Theme.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Try Pro free for \(AppStore.spoken(t))").font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                    Text("Up to 5 scouts, hunting every 6 hours and twice as deep").font(.caption).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
            }
            .padding(12)
            .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPro) {
            PaywallView().environment(store).environment(Router())
                .preferredColorScheme(.dark).presentationBackground(Theme.panel)
        }
    }

    /// What happens from here, so the wait for the first finds feels like part of the plan.
    private var whatsNext: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT HAPPENS NEXT").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted)
            nextRow("clock", "First finds land in a few minutes, right in Finds")
            nextRow("arrow.triangle.2.circlepath", store.isPro ? "Then they hunt every 6 hours, around the clock" : "Then they hunt every day and keep your finds fresh")
            nextRow("heart", "Like or pass what they bring, and they learn your taste fast")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func nextRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(Theme.accent).frame(width: 16)
            Text(text).font(.footnote).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Checks for the first finds every few seconds while this screen is up (up to 3 minutes).
    private func watchFirstHunt() {
        guard store.isCloud, !watching else { return }
        watching = true
        Task { @MainActor in
            for _ in 0..<22 {
                try? await Task.sleep(for: .seconds(8))
                guard step == 4, !onboarded else { break }
                await store.pull()
                if store.state.finds.contains(where: { $0.status == .open }) && store.state.agents.allSatisfy({ a in store.state.finds.contains { $0.agentID == a.id } }) { break }
            }
            watching = false
        }
    }

    private func finish() {
        onboarded = true
        dismiss()
    }
}

/// Setup's "in your own words" box, full height so a long description stays readable while you type.
private struct OwnWordsEditor: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Brands you love, styles, colors, materials, sizes, your budget, what you're hunting for and why.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("e.g. New Balance 990s in grey or earth tones, size 10.5, under $200. Also hunting a vintage Carhartt chore coat.")
                            .font(.body).foregroundStyle(Theme.muted.opacity(0.7))
                            .padding(.horizontal, 5).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(.body).foregroundStyle(Theme.ink)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                }
                .padding(8)
                .frame(maxHeight: .infinity)
                .background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
                Text("\(text.count)/1200").font(.caption2).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(16)
            .navigationTitle("In your own words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.bold() } }
            .onChange(of: text) { _, t in if t.count > 1200 { text = String(t.prefix(1200)) } }
            .onAppear { focused = true }
        }
        .preferredColorScheme(.dark)
    }
}
