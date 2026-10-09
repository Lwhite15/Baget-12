import SwiftUI
import PhotosUI

/// Your icon: a photo, an emoji or your initials on a colored tile.
struct AvatarView: View {
    @Environment(AppStore.self) private var store
    var size: CGFloat = 32

    var body: some View {
        let a = store.state.avatar
        ZStack {
            if a.style == .photo, let img = store.avatarImage {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                AvatarPalette.gradient(a.color)
                if a.style == .emoji {
                    Text(a.emoji).font(.system(size: size * 0.54))
                } else {
                    Text(store.initials)
                        .font(.system(size: size * 0.38, weight: .heavy))
                        .foregroundStyle(AvatarPalette.ink(a.color))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.line))
        .accessibilityHidden(true)
    }
}

/// Opened from your icon at the top left: your icon, name, handle, settings and account.
struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Avatar.Style = .initials
    @State private var pick: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var photoFailed = false
    @State private var customEmoji = ""
    @State private var name = ""
    @State private var nameError: String?

    private static let emojis = ["🔥", "👟", "🧢", "🕶️", "⌚️", "💎", "🖤", "🌊",
                                 "🌿", "🍸", "🏎️", "🛋️", "🎧", "📸", "🎨", "🧸",
                                 "🐉", "🦍", "👑", "⚡️", "🌙", "🍀", "🎯", "🛹"]

    var body: some View {
        NavigationStack {
            Form {
                header
                iconSection
                if store.isCloud { nameSection }
                AccountSection()
                settingsSection
                Section {} footer: {
                    Text("Baget \(Self.version)").frame(maxWidth: .infinity)
                }
            }
            .tint(Theme.cyan)
            .scrollContentBackground(.hidden)
            .background(LitBackground())
            .navigationTitle("You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                editing = store.state.avatar.style
                name = store.state.profile?.displayName ?? ""
                Analytics.track(.profileOpened, [:])
            }
            .onChange(of: pick) { _, item in
                guard let item else { return }
                Task { await loadPhoto(item) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        Section {
            VStack(spacing: 10) {
                AvatarView(size: 96)
                    .overlay { if loadingPhoto { ProgressView().tint(.white) } }
                Text(displayTitle).font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
                if let h = store.state.profile?.handle, !h.isEmpty, store.isCloud {
                    Text("@\(h)").font(.subheadline).foregroundStyle(Theme.muted)
                } else if !store.isCloud {
                    Text("Sample tour").font(.subheadline).foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .listRowBackground(Color.clear)
    }

    private var displayTitle: String {
        let n = store.state.profile?.displayName.trimmingCharacters(in: .whitespaces) ?? ""
        if !n.isEmpty { return n }
        if let h = store.state.profile?.handle, !h.isEmpty { return "@\(h)" }
        return "You"
    }

    // MARK: Icon

    private var iconSection: some View {
        Section {
            Picker("Icon style", selection: $editing) {
                Text("Initials").tag(Avatar.Style.initials)
                Text("Emoji").tag(Avatar.Style.emoji)
                Text("Photo").tag(Avatar.Style.photo)
            }
            .pickerStyle(.segmented)
            .onChange(of: editing) { _, style in
                // Photo only takes effect once there's a photo.
                if style != .photo || store.state.avatar.photoID != nil {
                    store.setAvatarStyle(style)
                    Analytics.track(.avatarChanged, ["style": style.rawValue])
                }
            }

            switch editing {
            case .initials:
                colorRow
            case .emoji:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 8) {
                    ForEach(Self.emojis, id: \.self) { e in
                        Button { chooseEmoji(e) } label: {
                            Text(e).font(.system(size: 24))
                                .frame(width: 36, height: 36)
                                .background(store.state.avatar.emoji == e && store.state.avatar.style == .emoji ? Theme.accent.opacity(0.25) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use \(e)")
                    }
                }
                .padding(.vertical, 4)
                HStack {
                    TextField("Or type any emoji", text: $customEmoji)
                        .onSubmit(useCustomEmoji)
                    if firstEmoji(customEmoji) != nil { Button("Use", action: useCustomEmoji).bold() }
                }
                colorRow
            case .photo:
                PhotosPicker(selection: $pick, matching: .images, photoLibrary: .shared()) {
                    Label(store.state.avatar.photoID == nil ? "Choose a photo" : "Change photo", systemImage: "photo.on.rectangle")
                }
                if photoFailed {
                    Text("Couldn't open that photo. Try another.").font(.footnote).foregroundStyle(Theme.hot)
                }
                if store.state.avatar.photoID != nil {
                    Button("Remove photo", role: .destructive) {
                        store.removeAvatarPhoto()
                        editing = .initials
                    }
                }
            }
        } header: { Text("Your icon") } footer: {
            Text(editing == .photo
                 ? "Cropped to a circle. It's kept private in your account, so it follows you to a new phone."
                 : "Shows at the top left of every screen.")
        }
    }

    private var colorRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(AvatarPalette.all.indices, id: \.self) { i in
                    Button {
                        store.setAvatarColor(i)
                        if editing == .emoji { store.setAvatarStyle(.emoji) }
                        Analytics.track(.avatarChanged, ["style": editing.rawValue, "color": i])
                    } label: {
                        Circle().fill(AvatarPalette.gradient(i))
                            .frame(width: 32, height: 32)
                            .overlay(Circle().strokeBorder(Theme.ink, lineWidth: store.state.avatar.color == i ? 2.5 : 0).padding(-4))
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Color \(i + 1)\(store.state.avatar.color == i ? ", selected" : "")")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func chooseEmoji(_ e: String) {
        store.setAvatarEmoji(e)
        Analytics.track(.avatarChanged, ["style": "emoji"])
    }

    private func useCustomEmoji() {
        guard let e = firstEmoji(customEmoji) else { return }
        chooseEmoji(e)
        customEmoji = ""
    }

    /// The first emoji in the text, so typing a word doesn't become your icon.
    private func firstEmoji(_ text: String) -> String? {
        text.first { ch in ch.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) } }
            .map(String.init)
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        loadingPhoto = true; photoFailed = false
        defer { loadingPhoto = false; pick = nil }
        guard let data = try? await item.loadTransferable(type: Data.self), let ui = UIImage(data: data) else {
            photoFailed = true
            return
        }
        store.setAvatarPhoto(ui)
        editing = .photo
    }

    // MARK: Name

    private var nameSection: some View {
        Section {
            HStack {
                TextField("Your name", text: $name)
                    .textContentType(.name)
                    .onSubmit(saveName)
                if name != (store.state.profile?.displayName ?? "") { Button("Save", action: saveName).bold() }
            }
            if let nameError { Text(nameError).font(.footnote).foregroundStyle(Theme.hot) }
        } header: { Text("Name") } footer: {
            Text("What friends see next to your handle.")
        }
    }

    private func saveName() {
        Task { @MainActor in
            nameError = await store.updateDisplayName(name)
            if nameError == nil { router.say("Saved") }
        }
    }

    // MARK: Settings

    private var settingsSection: some View {
        Section("Settings") {
            Button { router.sheet = .taste } label: {
                Label("What Baget knows about you", systemImage: "brain.head.profile")
            }
            NavigationLink {
                AlertSettingsForm()
                    .background(LitBackground())
                    .navigationTitle("Notifications")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label("Notifications and background", systemImage: "bell.badge")
            }
            NavigationLink {
                FriendsPrivacyForm()
                    .background(LitBackground())
                    .navigationTitle("Friends and privacy")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label("Friends and privacy", systemImage: "hand.raised")
            }
            Button { router.sheet = .customizeBar } label: {
                Label("Customize the Live bar", systemImage: "slider.horizontal.3")
            }
        }
        .foregroundStyle(Theme.ink)
    }

    private static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }
}

/// What friends can see.
struct FriendsPrivacyForm: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        return Form {
            Section {
                Toggle(isOn: $store.state.settings.shareTasteWithFriends) {
                    VStack(alignment: .leading) {
                        Text("My taste profile")
                        Text("The styles, makers and creators your agents hunt, so suggestions land better.").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                Toggle(isOn: $store.state.settings.sharePurchasesWithFriends) {
                    VStack(alignment: .leading) {
                        Text("What I buy")
                        Text("Off by default. Purchases and prices stay private unless you turn this on.").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            } header: { Text("What friends can see") } footer: {
                if let h = store.state.profile?.handle, store.isCloud {
                    Text("Friends add you by your handle, @\(h).")
                }
            }
        }
        .tint(Theme.cyan)
        .scrollContentBackground(.hidden)
        .onChange(of: store.state.settings) { _, _ in store.save() }
    }
}
