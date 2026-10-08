import SwiftUI
import PhotosUI

/// An agent's icon: its photo, emoji or initials on a colored tile.
struct AgentAvatarView: View {
    @Environment(AppStore.self) private var store
    let agent: Agent?
    var size: CGFloat = 36
    /// While picking, show this instead of what's saved.
    var preview: Avatar? = nil
    var previewPhoto: UIImage? = nil
    var nameOverride: String? = nil

    var body: some View {
        let icon = preview ?? agent?.icon
        let name = nameOverride ?? agent?.name ?? "Agent"
        ZStack {
            if icon?.style == .photo, let img = previewPhoto ?? store.iconImage(icon?.photoID) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                AvatarPalette.gradient(icon?.color ?? 0)
                if icon?.style == .emoji, let e = icon?.emoji {
                    Text(e).font(.system(size: size * 0.54))
                } else {
                    Text(AppStore.initials(name))
                        .font(.system(size: size * 0.36, weight: .heavy))
                        .foregroundStyle(AvatarPalette.ink(icon?.color ?? 0))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(Theme.line))
        .accessibilityHidden(true)
    }
}

/// Style, emoji, color and photo controls for an icon. Goes inside a Form section.
struct IconPickerRows: View {
    @Binding var icon: Avatar
    @Binding var photo: UIImage?
    /// The photo already saved for this icon, if any.
    var hasSavedPhoto: Bool = false
    @State private var pick: PhotosPickerItem?
    @State private var loading = false
    @State private var failed = false
    @State private var custom = ""

    static let emojis = ["🔥", "👟", "🧢", "🕶️", "⌚️", "💎", "🖤", "🌊",
                         "🌿", "🍸", "🏎️", "🛋️", "🎧", "📸", "🎨", "🧸",
                         "🐉", "🦍", "👑", "⚡️", "🌙", "🍀", "🎯", "🕵️"]

    var body: some View {
        Picker("Icon style", selection: $icon.style) {
            Text("Initials").tag(Avatar.Style.initials)
            Text("Emoji").tag(Avatar.Style.emoji)
            Text("Photo").tag(Avatar.Style.photo)
        }
        .pickerStyle(.segmented)

        switch icon.style {
        case .initials:
            colors
        case .emoji:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 8) {
                ForEach(Self.emojis, id: \.self) { e in
                    Button { icon.emoji = e } label: {
                        Text(e).font(.system(size: 24))
                            .frame(width: 36, height: 36)
                            .background(icon.emoji == e ? Theme.accent.opacity(0.25) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use \(e)")
                }
            }
            .padding(.vertical, 4)
            HStack {
                TextField("Or type any emoji", text: $custom).onSubmit(useCustom)
                if Self.firstEmoji(custom) != nil { Button("Use", action: useCustom).bold() }
            }
            colors
        case .photo:
            PhotosPicker(selection: $pick, matching: .images, photoLibrary: .shared()) {
                HStack {
                    Label(photo != nil || hasSavedPhoto ? "Change photo" : "Choose a photo", systemImage: "photo.on.rectangle")
                    if loading { Spacer(); ProgressView() }
                }
            }
            .onChange(of: pick) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
            if failed { Text("Couldn't open that photo. Try another.").font(.footnote).foregroundStyle(Theme.hot) }
            if photo == nil && !hasSavedPhoto {
                Text("Pick a photo, or this agent keeps its initials.").font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    private var colors: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(AvatarPalette.all.indices, id: \.self) { i in
                    Button { icon.color = i } label: {
                        Circle().fill(AvatarPalette.gradient(i))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(Theme.ink, lineWidth: icon.color == i ? 2.5 : 0).padding(-4))
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Color \(i + 1)\(icon.color == i ? ", selected" : "")")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func useCustom() {
        guard let e = Self.firstEmoji(custom) else { return }
        icon.emoji = e
        custom = ""
    }

    static func firstEmoji(_ text: String) -> String? {
        text.first { ch in ch.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) } }
            .map(String.init)
    }

    private func load(_ item: PhotosPickerItem) async {
        loading = true; failed = false
        defer { loading = false; pick = nil }
        guard let data = try? await item.loadTransferable(type: Data.self), let ui = UIImage(data: data) else {
            failed = true
            return
        }
        photo = PhotoTaste.normalized(ui, maxSide: 1024)
    }
}

/// Change an agent's icon after it's deployed. Opened by tapping the icon on its card.
struct AgentIconView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let agentID: String
    @State private var icon = Avatar()
    @State private var photo: UIImage?

    var body: some View {
        let agent = store.agent(agentID)
        NavigationStack {
            Form {
                Section {
                    AgentAvatarView(agent: agent, size: 96, preview: icon, previewPhoto: photo)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .listRowBackground(Color.clear)
                Section {
                    IconPickerRows(icon: $icon, photo: $photo, hasSavedPhoto: agent?.icon?.photoID != nil)
                } header: { Text("\(agent?.name ?? "Agent")'s icon") } footer: {
                    Text("Shows on its card and on every text it sends you.")
                }
                if agent?.icon != nil {
                    Section {
                        Button("Use the default icon", role: .destructive) {
                            store.setAgentIcon(agentID, icon: nil, photo: nil)
                            dismiss()
                        }
                    }
                }
            }
            .tint(Theme.cyan)
            .scrollContentBackground(.hidden)
            .background(LitBackground())
            .navigationTitle("Agent icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // Photo style with no photo at all falls back to initials.
                        var chosen = icon
                        if chosen.style == .photo && photo == nil && agent?.icon?.photoID == nil { chosen.style = .initials }
                        store.setAgentIcon(agentID, icon: chosen, photo: chosen.style == .photo ? photo : nil)
                        dismiss()
                    }
                    .bold()
                }
            }
            .onAppear { icon = agent?.icon ?? Avatar() }
        }
    }
}
