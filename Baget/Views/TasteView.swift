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

    var body: some View {
        ZStack {
            LitBackground()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    ForEach(0..<3) { i in Capsule().fill(i <= step ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.glass)).frame(height: 4) }
                }
                switch step {
                case 0: interests
                case 1: photoStep
                default: finished
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

    private var interests: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What are you into?").font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.ink)
            Text("Pick a few. You'll get an agent for each.").font(.subheadline).foregroundStyle(Theme.muted)
            FlowRow {
                ForEach(Category.allCases.filter { $0 != .other }) { c in
                    Button {
                        if picked.contains(c) { picked.remove(c) } else { picked.insert(c) }
                    } label: { Pill(text: c.info.label, selected: picked.contains(c)) }
                        .buttonStyle(.plain)
                }
            }
            TextField("Anything specific? e.g. oud like Frederic Malle, size 10.5", text: $text, axis: .vertical)
                .lineLimit(1...3)
                .padding(12)
                .background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
            Spacer()
            Button("Next") { withAnimation { step = 1 } }
                .buttonStyle(PrimaryButton())
                .disabled(picked.isEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Skip setup") { finish() }.font(.footnote).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
        }
    }

    private var photoStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Show me 3 things you love").font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.ink)
            Text("Optional. Screenshots or photos of pieces you own or want. Your agents read your taste from them.")
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

    private var finished: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your squad is hunting").font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.ink)
            Text(made > 0 ? "\(made) agent\(made == 1 ? "" : "s") are searching the web for you right now. They'll text you when they find something, and Today fills up as they go."
                          : "Tell Baget what you're hunting on Today and an agent starts right away.")
                .font(.subheadline).foregroundStyle(Theme.muted)
            FlowRow { ForEach(store.state.agents) { a in HStack(spacing: 6) { AgentAvatarView(agent: a, size: 24); Text(a.name).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink) }.padding(6).background(Theme.glass, in: Capsule()) } }
            Spacer()
            Button("Let's go") { finish() }.buttonStyle(PrimaryButton())
        }
    }

    private func build() {
        working = true
        Task { @MainActor in
            let ids = await store.onboard(categories: Array(picked), text: text.trimmingCharacters(in: .whitespacesAndNewlines), photos: photos)
            working = false
            made = ids.count
            withAnimation { step = 2 }
        }
    }

    private func finish() {
        onboarded = true
        dismiss()
    }
}
