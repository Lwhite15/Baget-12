import SwiftUI
import PhotosUI

/// Your icon: a photo, an emoji or your initials on a colored tile.
struct AvatarView: View {
    @Environment(AppStore.self) private var store
    var size: CGFloat = 32
    /// Your ring around it (off where a ring would be too small or out of place).
    var showRing = true
    /// While picking in Settings: show this instead of what's saved.
    var preview: Avatar? = nil

    var body: some View {
        let a = preview ?? store.state.avatar
        let ring = showRing ? store.rings?.wearing.flatMap(Ring.init(rawValue:)) : nil
        RingFrame(ring: ring, size: size) { s in
            ZStack {
                if a.style == .photo, let img = store.avatarImage {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Rectangle().fill(AvatarFill.style(a.color, palette: store.myPalette))
                    switch a.style {
                    case .emoji: Text(a.emoji).font(.system(size: s * 0.54))
                    case .baget: Image(systemName: a.glyph ?? "sparkles").font(.system(size: s * 0.44, weight: .semibold)).foregroundStyle(AvatarFill.ink(a.color))
                    default:
                        Text(store.initials)
                            .font(.system(size: s * 0.38, weight: .heavy))
                            .foregroundStyle(AvatarFill.ink(a.color))
                    }
                }
            }
            .frame(width: s, height: s)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Theme.line))
        }
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
    @State private var showHowTo = false
    @State private var photoFailed = false
    @State private var customEmoji = ""
    @State private var name = ""
    @State private var nameError: String?

    private static let emojis = ["🔥", "👟", "🧢", "🕶️", "⌚️", "💎", "🖤", "🌊",
                                 "🌿", "🍸", "🏎️", "🛋️", "🎧", "📸", "🎨", "🧸",
                                 "🐉", "🦍", "👑", "⚡️", "🌙", "🍀", "🎯", "🛹"]

    @State private var nameSave: SaveState = .idle
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                header
                iconSection
                if store.isCloud { ringSection }
                if store.isCloud { nameSection }
                if store.isCloud { UsernameSection() }
                if store.isCloud {
                    Section {
                        BirthdayRow(showsCaption: false)
                    } header: { Text("Birthday") } footer: {
                        Text("Month and day only. Friends get a heads-up a week before, with gift ideas for your taste when you both share taste.")
                    }
                }
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
        return String(localized: "You")
    }

    // MARK: Icon

    private var iconSection: some View {
        Section {
            Picker("Icon style", selection: $editing) {
                Text("Initials").tag(Avatar.Style.initials)
                Text("Emoji").tag(Avatar.Style.emoji)
                Text("Baget").tag(Avatar.Style.baget)
                Text("Photo").tag(Avatar.Style.photo)
            }
            .pickerStyle(.segmented)
            .onChange(of: editing) { _, style in
                if style == .baget {
                    store.setAvatarGlyph(store.state.avatar.glyph ?? BagetGlyph.available.first ?? "sparkles")
                    Analytics.track(.avatarChanged, ["style": "baget"])
                    return
                }
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
            case .baget:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 10) {
                    ForEach(BagetGlyph.available, id: \.self) { g in
                        let on = store.state.avatar.style == .baget && store.state.avatar.glyph == g
                        Button {
                            store.setAvatarGlyph(g)
                            Analytics.track(.avatarChanged, ["style": "baget", "glyph": g])
                        } label: {
                            Image(systemName: g).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.gradient)
                                .frame(maxWidth: .infinity).frame(height: 52)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.ink, lineWidth: on ? 2.5 : 0))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(g.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
                    }
                }
                .padding(.vertical, 4)
                colorRow
            case .photo:
                PhotosPicker(selection: $pick, matching: .images, photoLibrary: .shared()) {
                    Label(store.state.avatar.photoID == nil ? String(localized: "Choose a photo") : String(localized: "Change photo"), systemImage: "photo.on.rectangle")
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
                 ? String(localized: "Cropped to a circle. It's kept private in your account, so it follows you to a new phone.")
                 : String(localized: "Shows at the top left of every screen."))
        }
    }

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 6) {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                // Your Taste Card's own colors, once you have a card.
                if store.myPalette.count >= 2 {
                    Button {
                        store.setAvatarColor(AvatarPalette.taste)
                        if editing == .emoji { store.setAvatarStyle(.emoji) }
                        if editing == .baget { store.setAvatarStyle(.baget) }
                        Analytics.track(.avatarChanged, ["style": editing.rawValue, "color": "taste"])
                    } label: {
                        Circle().fill(AvatarFill.style(AvatarPalette.taste, palette: store.myPalette))
                            .overlay(Image(systemName: "sparkle").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).shadow(radius: 2))
                            .frame(width: 32, height: 32)
                            .overlay(Circle().strokeBorder(Theme.ink, lineWidth: store.state.avatar.color == AvatarPalette.taste ? 2.5 : 0).padding(-4))
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Your taste palette\(store.state.avatar.color == AvatarPalette.taste ? ", selected" : "")")
                }
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
            if store.myPalette.count >= 2 {
                Label("The first color is your taste palette, from your Taste Card", systemImage: "sparkle")
                    .font(.caption).foregroundStyle(Theme.green)
            }
        }
    }

    // MARK: Ring

    private var ringSection: some View {
        let state = store.rings
        let owned = Ring.listed.filter { state?.owns($0) ?? false }
        return Section {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ringChoice(nil, label: String(localized: "None"), on: state?.wearing == nil)
                    ForEach(owned) { r in ringChoice(r, label: r.short, on: state?.wearing == r.rawValue) }
                    ForEach(Ring.earnable.filter { !(state?.owns($0) ?? false) }) { r in
                        VStack(spacing: 6) {
                            RingFrame(ring: r, size: 52) { inner in Circle().fill(Color.white.opacity(0.06)).frame(width: inner, height: inner) }
                                .opacity(0.35)
                                .overlay(Image(systemName: "lock.fill").font(.caption).foregroundStyle(Theme.muted))
                            Text(r.short).font(.caption2).foregroundStyle(Theme.muted).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .frame(width: 64)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            NavigationLink {
                RingsView()
            } label: {
                HStack {
                    Label("Your rings", systemImage: "circle.circle")
                    Spacer()
                    Text("\(owned.filter { $0 != .proGlow }.count) earned").foregroundStyle(Theme.muted)
                }
            }
        } header: { Text("Ring") } footer: {
            Text("A ring around your icon that friends see. Earn more by using Baget.")
        }
        .task { await store.refreshRings() }
    }

    private func ringChoice(_ r: Ring?, label: String, on: Bool) -> some View {
        Button {
            Task { _ = await store.wearRing(r) }
        } label: {
            VStack(spacing: 6) {
                RingFrame(ring: r, size: 52) { inner in
                    Circle().fill(Color.white.opacity(0.06)).frame(width: inner, height: inner)
                        .overlay { if r == nil { Image(systemName: "nosign").foregroundStyle(Theme.muted) } }
                }
                .padding(3)
                .overlay(Circle().strokeBorder(Theme.ink, lineWidth: on ? 2 : 0))
                Text(label).font(.caption2.weight(on ? .bold : .regular)).foregroundStyle(on ? Theme.ink : Theme.muted)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(r?.name ?? String(localized: "No ring"))
        .accessibilityAddTraits(on ? .isSelected : [])
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
                    .focused($nameFocused)
                    .onSubmit(saveName)
                    .onChange(of: name) { _, v in if nameSave == .saved && v != store.state.profile?.displayName { nameSave = .idle } }
                InlineSave(state: nameSave, dirty: name != (store.state.profile?.displayName ?? ""), action: saveName)
            }
            if let nameError { Text(nameError).font(.footnote).foregroundStyle(Theme.hot) }
        } header: { Text("Name") } footer: {
            Text("What friends see next to your handle.")
        }
    }

    private func saveName() {
        guard name != (store.state.profile?.displayName ?? "") else { return }
        nameFocused = false
        withAnimation { nameSave = .saving }
        Task { @MainActor in
            nameError = await store.updateDisplayName(name)
            if nameError == nil {
                name = store.state.profile?.displayName ?? name
                withAnimation { nameSave = .saved }
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation { if nameSave == .saved { nameSave = .idle } }
            } else {
                withAnimation { nameSave = .idle }
            }
        }
    }

    // MARK: Settings

    private var settingsSection: some View {
        Section("Settings") {
            Button { router.sheet = .feedback } label: {
                Label("Send feedback", systemImage: "bubble.left.and.exclamationmark.bubble.right")
            }
            Link(destination: URL(string: "mailto:bagetsupport@gmail.com?subject=Baget%20support")!) {
                Label("Contact support", systemImage: "envelope")
            }
            PlanSettingsRows()
            Button { router.sheet = .taste } label: {
                Label("What Baget knows about you", systemImage: "brain.head.profile")
            }
            Button { showHowTo = true } label: {
                Label("How Baget works", systemImage: "questionmark.circle")
            }
            .fullScreenCover(isPresented: $showHowTo) { HowToView() }
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
            // iOS keeps each app's language in Settings; this opens Baget's page there, where Language is the first row.
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                HStack {
                    Label("Language", systemImage: "globe")
                    Spacer()
                    Text(Self.languageName).foregroundStyle(Theme.muted)
                    Image(systemName: "arrow.up.forward.app").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .accessibilityHint("Opens Baget's settings, where you can pick its language")
            if store.isAdmin {
                NavigationLink { StatsView() } label: {
                    Label("Stats", systemImage: "chart.bar.xaxis")
                }
            }
        }
        .foregroundStyle(Theme.ink)
    }

    /// The language Baget is showing, in that language ("Español").
    private static var languageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: code).localizedString(forLanguageCode: code)?.capitalized(with: Locale(identifier: code)) ?? code
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
                        Text("The styles, makers and creators your scouts hunt, so suggestions land better.").font(.caption).foregroundStyle(Theme.muted)
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

/// Your @username: how friends add you. Usernames are unique, so this checks as you type and only saves a free one.
struct UsernameSection: View {
    @Environment(AppStore.self) private var store
    @State private var text = ""
    @State private var status: String?          // invalid, yours, taken, available
    @State private var error: String?
    @State private var save: SaveState = .idle
    @FocusState private var focused: Bool

    private var current: String { store.state.profile?.handle ?? "" }
    private var cleaned: String { text.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased() }

    var body: some View {
        Section {
            HStack(spacing: 4) {
                Text("@").foregroundStyle(Theme.muted)
                TextField("username", text: $text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textContentType(.username)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(commit)
                InlineSave(state: save, dirty: cleaned != current && status == "available", action: commit)
            }
            if let line = statusLine {
                Label(line.text, systemImage: line.icon).font(.footnote).foregroundStyle(line.color)
            }
        } header: { Text("Username") } footer: {
            Text("Friends add you by your username. No two people can have the same one.")
        }
        .onAppear { if text.isEmpty { text = current } }
        .task(id: cleaned) {
            error = nil
            guard cleaned != current else { status = cleaned.isEmpty ? nil : "yours"; return }
            guard cleaned.range(of: "^[a-z0-9._]{3,24}$", options: .regularExpression) != nil else { status = cleaned.isEmpty ? nil : "invalid"; return }
            status = nil
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            status = await store.handleAvailability(cleaned)
        }
    }

    private var statusLine: (text: String, icon: String, color: Color)? {
        if let error { return (error, "exclamationmark.circle.fill", Theme.hot) }
        switch status {
        case "invalid": return (String(localized: "Use 3 to 24 lowercase letters, numbers, dots or underscores."), "info.circle", Theme.muted)
        case "taken": return (String(localized: "@\(cleaned) is taken. Try another."), "xmark.circle.fill", Theme.hot)
        case "available": return (String(localized: "@\(cleaned) is available"), "checkmark.circle.fill", Theme.green)
        default: return nil
        }
    }

    private func commit() {
        guard cleaned != current, status == "available" else { return }
        focused = false
        withAnimation { save = .saving }
        Task { @MainActor in
            error = await store.updateHandle(cleaned)
            if error == nil {
                text = current; status = "yours"
                withAnimation { save = .saved }
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation { if save == .saved { save = .idle } }
            } else {
                withAnimation { save = .idle }
            }
        }
    }
}

extension AppStore {
    /// "available", "taken", "yours" or "invalid" for a username (server: handle_available).
    func handleAvailability(_ handle: String) async -> String? {
        guard isCloud else { return nil }
        return try? await api.rpc("handle_available", ["p_handle": handle], as: String.self)
    }
}
