import SwiftUI
import PhotosUI

/// Pick a photo, see what the agent picks up from it, keep what's right, teach the agent.
struct TastePhotoView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    let agentID: String

    @State private var pick: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var reading: PhotoReading?
    @State private var kept: Set<String> = []
    @State private var extra: [String] = []
    @State private var own = ""
    @State private var loading = false
    @State private var failed = false

    private var brandTags: [String] { (reading?.makers ?? []) + (reading?.creators ?? []) }
    private var allTags: [String] { (reading?.traits ?? []) + brandTags + extra }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let a = store.agent(agentID) {
                        if let image {
                            Image(uiImage: image)
                                .resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 340)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        PhotosPicker(selection: $pick, matching: .images, photoLibrary: .shared()) {
                            Label(image == nil ? "Choose a photo" : "Choose a different photo", systemImage: "photo.on.rectangle.angled")
                        }
                        .buttonStyle(image == nil ? AnyButtonStyle(PrimaryButton()) : AnyButtonStyle(GhostButton()))

                        if image == nil {
                            Text(store.isCloud
                                 ? "Show \(a.name) something you love, like a fit, a shelf, a car or a room. It reads the style and hunts for more of it. The photo is saved privately to your account."
                                 : "Show \(a.name) something you love, like a fit, a shelf, a car or a room. It reads the style and hunts for more of it. The photo stays on your phone.")
                                .font(.footnote).foregroundStyle(Theme.muted)
                        }
                        if loading {
                            HStack(spacing: 10) { ProgressView(); Text("Taking a look…").foregroundStyle(Theme.muted) }
                        }
                        if failed {
                            Text("That image couldn't be opened. Try another one.").font(.footnote).foregroundStyle(Theme.hot)
                        }
                        if let reading {
                            Text(reading.summary)
                                .font(.subheadline).foregroundStyle(Theme.ink)
                                .padding(12)
                                .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14))

                            if !allTags.isEmpty {
                                Text("WHAT I PICKED UP · TAP TO DROP").font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.muted)
                                FlowRow {
                                    ForEach(allTags, id: \.self) { t in
                                        Button {
                                            if kept.contains(t) { kept.remove(t) } else { kept.insert(t) }
                                        } label: { Pill(text: t, selected: kept.contains(t)) }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            HStack {
                                TextField(allTags.isEmpty ? "What do you love about it? e.g. suede, earth tones" : "Anything it missed", text: $own)
                                    .textInputAutocapitalization(.never)
                                    .padding(10).background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
                                    .onSubmit(addOwn)
                                Button("Add", action: addOwn).buttonStyle(GhostButton()).frame(width: 80)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(LitBackground())
            .navigationTitle("Teach with a photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(kept.isEmpty ? "Teach" : "Teach \(kept.count)") { teach() }
                        .bold().disabled(kept.isEmpty || image == nil)
                }
            }
            .onChange(of: pick) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
        }
    }

    private func load(_ item: PhotosPickerItem) async {
        loading = true; failed = false; reading = nil; kept = []; extra = []
        defer { loading = false }
        guard let data = try? await item.loadTransferable(type: Data.self), let ui = UIImage(data: data),
              let a = store.agent(agentID) else { failed = true; return }
        image = PhotoTaste.normalized(ui, maxSide: 1400)
        // Signed in, Claude reads the photo; otherwise (or if that fails) the phone reads it on its own.
        var r: PhotoReading
        if let cloud = await store.readPhotoCloud(agentID: a.id, image: ui), !(cloud.traits.isEmpty && cloud.makers.isEmpty) {
            r = cloud
        } else {
            r = await PhotoTaste.read(ui, for: a)
        }
        // the photo's palette helps either way
        for c in PhotoTaste.dominantColors(PhotoTaste.normalized(ui, maxSide: 256)) where !r.traits.contains(where: { $0.contains(c) }) {
            r.traits.append(c)
        }
        r.traits = Array(r.traits.prefix(8))
        reading = r
        kept = Set(r.traits + r.makers + r.creators)
    }

    private func addOwn() {
        for t in TextMatch.list(own).map({ $0.lowercased() }) where !allTags.contains(t) {
            extra.append(t)
            kept.insert(t)
        }
        own = ""
    }

    private func teach() {
        guard let image, let a = store.agent(agentID) else { return }
        let makers = (reading?.makers ?? []).filter { kept.contains($0) }
        let creators = (reading?.creators ?? []).filter { kept.contains($0) }
        let tags = allTags.filter { kept.contains($0) && !makers.contains($0) && !creators.contains($0) }
        store.addTastePhoto(agentID: agentID, image: image, tags: tags, makers: makers, creators: creators, summary: reading?.summary ?? "")
        router.say("\(a.name) learned from your photo")
        dismiss()
    }
}

/// Lets one button switch between the two button styles.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// The taste board on an agent's card.
struct TasteBoardRow: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let agent: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TASTE BOARD\(agent.tasteBoard.isEmpty ? "" : " · \(agent.tasteBoard.count)")")
                    .font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.muted)
                Spacer()
                Button {
                    router.sheet = .tastePhoto(agent.id)
                } label: { Label("Add a photo", systemImage: "plus") }
                    .font(.caption.weight(.semibold))
                    .disabled(agent.tasteBoard.count >= AppStore.maxTastePhotos)
            }
            if agent.tasteBoard.isEmpty {
                Text("Show me photos of things you love, like a fit, a shelf, a car or a room. I'll pick up the style and hunt for more of it.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(agent.tasteBoard) { p in
                        ZStack(alignment: .bottomLeading) {
                            Group {
                                if let ui = store.image(for: p) {
                                    Image(uiImage: ui).resizable().scaledToFill()
                                } else {
                                    Theme.glass
                                }
                            }
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .accessibilityLabel("Taste photo: \(p.tags.joined(separator: ", "))")
                            LinearGradient(colors: [.clear, Theme.bg.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                            Text(p.tags.prefix(3).joined(separator: " · "))
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                                .lineLimit(1).padding(6)
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                store.removeTastePhoto(agentID: agent.id, photoID: p.id)
                                router.say("Photo removed")
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 22, height: 22).background(Circle().fill(Theme.bg.opacity(0.75)))
                            }
                            .padding(4)
                            .accessibilityLabel("Remove this photo")
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
    }
}
