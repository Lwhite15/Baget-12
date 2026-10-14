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
                    Text("Tap ✕ on anything that isn't you. Agents stop using it on their next search. Like, pass and chat to teach them more.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                    if store.state.agents.isEmpty { EmptyCard(text: "No agents yet. Tell Baget what you're hunting on Today.") }
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
    @State private var text = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var photos: [UIImage] = []
    @State private var working = false
    @State private var made = 0
    // Taste check
    @State private var quiz: [Item] = []
    @State private var quizIndex = 0
    @State private var quizLoading = false
    @State private var liked: [String] = []
    @State private var passed: [String] = []
    // First hunt
    @State private var pushOn = false
    @State private var watching = false

    private let steps = 4

    var body: some View {
        ZStack {
            LitBackground()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    ForEach(0..<steps, id: \.self) { i in Capsule().fill(i <= step ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.glass)).frame(height: 4) }
                }
                switch step {
                case 0: interests
                case 1: tasteCheck
                case 2: photoStep
                default: firstHunt
                }
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .onChange(of: pickerItems) { _, items in
            Task { @MainActor in
                var out: [UIImage] = []
                for it in items.prefix(3) {
                    if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d) { out.append(img) }
                }
                photos = out
            }
        }
    }

    // MARK: 1. Interests

    private var interests: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What are you into?").font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.ink)
            Text("Pick a few. You'll get a personal scout for each, hunting drops, restocks and deals.").font(.subheadline).foregroundStyle(Theme.muted)
            FlowRow {
                ForEach(Category.allCases.filter { $0 != .other }) { c in
                    Button {
                        if picked.contains(c) { picked.remove(c) } else { picked.insert(c) }
                    } label: { Pill(text: c.info.label, selected: picked.contains(c)) }
                        .buttonStyle(.plain)
                }
            }
            TextField("Anything specific? e.g. Jordan 1s in mocha, size 10.5", text: $text, axis: .vertical)
                .lineLimit(1...3)
                .padding(12)
                .background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
            Spacer()
            Button("Next") { startQuiz() }
                .buttonStyle(PrimaryButton())
                .disabled(picked.isEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Skip setup") { finish() }.font(.footnote).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
        }
    }

    // MARK: 2. Quick taste check

    private func startQuiz() {
        withAnimation { step = 1 }
        quizLoading = true
        Task { @MainActor in
            quiz = await store.tasteQuiz(Array(picked))
            quizIndex = 0
            quizLoading = false
            if quiz.isEmpty { withAnimation { step = 2 } }   // nothing to rate yet: go straight on
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
                    Text([item.priceKnown && item.price > 0 ? Fmt.money(item.price) : nil, item.source].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.muted)
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
                    Text("\(quizIndex + 1) of \(quiz.count)").font(.caption.monospaced()).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Done") { withAnimation { step = 2 } }.font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            } else {
                Spacer()
                Text(liked.isEmpty ? "Got it." : "Nice taste. \(liked.count) noted.").font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
                Spacer()
                Button("Next") { withAnimation { step = 2 } }.buttonStyle(PrimaryButton())
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
            if quizIndex >= quiz.count { step = 2 }
        }
    }

    // MARK: 3. Photos (optional)

    private var photoStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Show me 3 things you love").font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.ink)
            Text("Optional. Screenshots or photos of pieces you own or want. Your scouts read your taste from them.")
                .font(.subheadline).foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                ForEach(0..<3) { i in
                    ZStack {
                        RoundedRectangle(cornerRadius: 16).fill(Theme.glass)
                        if i < photos.count {
                            Image(uiImage: photos[i]).resizable().scaledToFill()
                        } else {
                            Image(systemName: "plus").foregroundStyle(Theme.muted)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line))
                }
            }
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 3, matching: .images, photoLibrary: .shared()) {
                Label(photos.isEmpty ? "Choose photos" : "Change photos", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GhostButton())
            Spacer()
            if working {
                HStack { Spacer(); ProgressView().tint(Theme.cyan); Text("Building your squad…").foregroundStyle(Theme.muted); Spacer() }
            } else {
                Button(photos.isEmpty ? "Build my squad" : "Build my squad with these") { build() }.buttonStyle(PrimaryButton())
                Button("Back") { withAnimation { step = 0 } }.font(.footnote).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
            }
        }
    }

    private func build() {
        working = true
        Task { @MainActor in
            let ids = await store.onboard(categories: Array(picked), text: text.trimmingCharacters(in: .whitespacesAndNewlines), photos: photos,
                                          liked: liked, passed: passed)
            working = false
            made = ids.count
            pushOn = await store.pushAllowed
            withAnimation { step = 3 }
            Task { await store.loadForYou() }
            watchFirstHunt()
        }
    }

    // MARK: 4. The first hunt, live

    private var firstHunt: some View {
        let newest = store.state.finds.filter { $0.status == .open }.sorted { $0.foundAt > $1.foundAt }.prefix(3)
        return VStack(alignment: .leading, spacing: 14) {
            Text(newest.isEmpty ? "Your squad is hunting" : "First finds are in").font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.ink)
            Text(made > 0 ? "They're searching stores, release calendars and resale sites for you right now. First finds usually land in a few minutes."
                          : "Tell Baget what you're hunting on Today and a scout starts right away.")
                .font(.subheadline).foregroundStyle(Theme.muted)
            VStack(spacing: 8) {
                ForEach(store.state.agents) { a in
                    let n = store.state.finds.filter { $0.agentID == a.id }.count
                    HStack(spacing: 10) {
                        AgentAvatarView(agent: a, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                            Text(n > 0 ? "Found \(n)" : "Searching…").font(.caption).foregroundStyle(n > 0 ? Theme.green : Theme.muted)
                        }
                        Spacer()
                        if n > 0 { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green) }
                        else { ProgressView().controlSize(.small).tint(Theme.cyan) }
                    }
                    .padding(10)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
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

    /// Checks for the first finds every few seconds while this screen is up (up to 3 minutes).
    private func watchFirstHunt() {
        guard store.isCloud, !watching else { return }
        watching = true
        Task { @MainActor in
            for _ in 0..<22 {
                try? await Task.sleep(for: .seconds(8))
                guard step == 3, !onboarded else { break }
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
