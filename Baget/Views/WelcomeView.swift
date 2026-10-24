import SwiftUI
import AuthenticationServices

/// First screen when Baget is connected to a server: sign in, or look around with sample data.
struct WelcomeView: View {
    @Environment(AppStore.self) private var store
    @State private var nonce = Backend.makeNonce()
    @State private var working = false
    @State private var error: String?
    @State private var showEmail = false

    var body: some View {
        ZStack {
            LitBackground()
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 24)
                        brand
                        Spacer(minLength: 28)
                        features
                        Spacer(minLength: 28)
                        actions
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showEmail) { EmailSignInView().presentationDetents([.large]) }
    }

    private var brand: some View {
        VStack(spacing: 14) {
            AppIcon(size: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: AppIcon.ground.opacity(0.45), radius: 22, y: 8)
            HStack(spacing: 0) {
                Text("Baget").foregroundStyle(Theme.ink)
                Text(".").gradientText()
            }
            .font(.system(size: 48, weight: .heavy)).tracking(-1.5)
            Text("Never miss what you'd love.")
                .font(.title2.weight(.bold)).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text("Baget gives you personal scouts that learn your taste, hunt the web and tell you when they find something worth buying.")
                .font(.body).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var features: some View {
        VStack(spacing: 10) {
            feature("sparkle.magnifyingglass", String(localized: "Whatever you're into, they find it"),
                    String(localized: "Rare vinyl, a vintage chair, the perfect gift or your next car. Name it, and your scouts search stores, resale sites and small shops for you."))
            feature("heart.text.square", String(localized: "They learn your taste"),
                    String(localized: "Every like and pass makes their next picks sharper."))
            feature("bell.badge", String(localized: "They tell you first"),
                    String(localized: "A heads-up when something you'd love drops, restocks or goes on sale."))
        }
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.semibold)).foregroundStyle(Theme.cyan)
                .frame(width: 36, height: 36)
                .background(Theme.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(.footnote).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
        .accessibilityElement(children: .combine)
    }

    /// "By continuing, you agree to the Terms of Use and Privacy Policy", both as links.
    private static let legal: AttributedString = {
        let md = String(localized: "By continuing, you agree to the [Terms of Use](\(AppStore.termsURL.absoluteString)) and [Privacy Policy](\(AppStore.privacyURL.absoluteString)).")
        return (try? AttributedString(markdown: md)) ?? AttributedString(String(localized: "By continuing, you agree to the Terms of Use and Privacy Policy."))
    }()

    private var actions: some View {
        VStack(spacing: 12) {
            if working {
                ProgressView().tint(Theme.cyan).frame(height: 52)
            } else {
                SignInWithAppleButton(.continue) { req in
                    nonce = Backend.makeNonce()
                    req.requestedScopes = [.fullName]
                    req.nonce = Backend.sha256(nonce)
                } onCompletion: { result in
                    Task { await handle(result) }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Button { showEmail = true } label: {
                    Label("Continue with email", systemImage: "envelope.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(Theme.ink)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.ink.opacity(0.35), lineWidth: 1))
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.hot).multilineTextAlignment(.center) }
            Button("Take a look first") { store.exploreSamples() }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                .padding(.top, 4)
            Text(Self.legal)
                .font(.caption).foregroundStyle(Theme.muted).tint(Theme.accent)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }

    @MainActor private func handle(_ result: Result<ASAuthorization, Error>) async {
        error = nil
        switch result {
        case .failure(let e):
            if (e as? ASAuthorizationError)?.code != .canceled { error = String(localized: "Sign in with Apple didn't finish. Try again.") }
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
                error = String(localized: "Apple didn't send a sign-in token. Try again.")
                return
            }
            working = true
            defer { working = false }
            do {
                try await Backend.shared.signInWithApple(idToken: token, nonce: nonce)
                let name = [cred.fullName?.givenName, cred.fullName?.familyName].compactMap { $0 }.joined(separator: " ")
                await store.didSignIn(fullName: name.isEmpty ? nil : name)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn't sign in. Try again.")
            }
        }
    }
}

/// Sign in or create an account with an email address and password.
struct EmailSignInView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    private var valid: Bool {
        email.contains("@") && email.contains(".") && password.count >= (creating ? 8 : 1)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $creating) {
                    Text("Sign in").tag(false)
                    Text("Create account").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                Section {
                    if creating {
                        TextField("Your name", text: $name).textContentType(.name)
                    }
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(creating ? String(localized: "Password (8 or more characters)") : String(localized: "Password"), text: $password)
                        .textContentType(creating ? .newPassword : .password)
                } footer: {
                    if let error { Text(error).foregroundStyle(Theme.hot) }
                }
                Section {
                    Button { Task { await submit() } } label: {
                        HStack {
                            Spacer()
                            if working { ProgressView() } else { Text(creating ? String(localized: "Create account") : String(localized: "Sign in")).bold() }
                            Spacer()
                        }
                    }
                    .disabled(!valid || working)
                }
            }
            .navigationTitle(creating ? String(localized: "Create account") : String(localized: "Sign in with email"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: creating) { error = nil }
        }
    }

    @MainActor private func submit() async {
        error = nil
        working = true
        defer { working = false }
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        let fullName = name.trimmingCharacters(in: .whitespaces)
        do {
            if creating {
                try await Backend.shared.signUpWithEmail(email: address, password: password, name: fullName)
            } else {
                try await Backend.shared.signInWithEmail(email: address, password: password)
            }
            dismiss()
            await store.didSignIn(fullName: creating && !fullName.isEmpty ? fullName : nil)
        } catch {
            let m = (error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn't sign in. Try again.")
            if m.localizedCaseInsensitiveContains("invalid login") {
                self.error = String(localized: "That email and password don't match. Check them, or switch to Create account.")
            } else if m.localizedCaseInsensitiveContains("already registered") {
                self.error = String(localized: "There's already an account with that email. Switch to Sign in.")
            } else {
                self.error = m
            }
        }
    }
}

/// Talk to an agent. It learns from the conversation, searches the web, and can flag finds or line up checkout.
/// "Ask about this" when there's no scout left to ask.
struct NoScoutView: View {
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 40)).foregroundStyle(Theme.muted)
            Text("Set up a scout to ask about this").font(.headline).foregroundStyle(Theme.ink)
            Text("The scout that found it is gone. Add a scout and you can ask it anything about your finds.")
                .font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Button("Set up a scout") { dismiss(); router.sheet = .deploy }.buttonStyle(PrimaryButton())
        }
        .padding(28)
    }
}

struct ChatView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    let agentID: String
    /// Set when opened from "Ask about this" on a find: the chat is about that item.
    var aboutFindID: String? = nil
    @State private var draft = ""
    @State private var sentContext = false

    private var aboutItem: Item? {
        guard let id = aboutFindID, let f = store.state.finds.first(where: { $0.id == id }) else { return nil }
        return Catalog.item(f.itemID)
    }

    var body: some View {
        let a = store.agent(agentID)
        let turns = store.state.chats[agentID] ?? []
        let busy = store.chatBusy == agentID
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if let item = aboutItem {
                                HStack(spacing: 10) {
                                    ProductThumb(item: item, size: 48)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Asking about").font(.caption2.weight(.bold)).foregroundStyle(Theme.muted)
                                        Text(item.title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                                    }
                                }
                                .padding(10)
                                .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14))
                            }
                            bubble(text: aboutItem != nil ? String(localized: "What do you want to know about it?") : greeting(a), mine: false)
                            ForEach(turns) { t in
                                bubble(text: t.text, mine: t.role == "user")
                                ForEach(Array(t.actions.enumerated()), id: \.offset) { _, act in actionChip(act) }
                            }
                            if busy {
                                HStack(spacing: 8) { ProgressView().tint(Theme.cyan); Text("Thinking…").foregroundStyle(Theme.muted) }
                                    .font(.subheadline).id("busy")
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(16)
                    }
                    .onChange(of: turns.count) { _, _ in withAnimation { proxy.scrollTo("end") } }
                    .onChange(of: busy) { _, _ in withAnimation { proxy.scrollTo("end") } }
                }
                if turns.isEmpty || (aboutItem != nil && !sentContext) {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(aboutItem != nil ? [String(localized: "Is this a good price?"), String(localized: "Find it cheaper"), String(localized: "Will it restock in my size?"), String(localized: "Show me similar")]
                                                     : [String(localized: "Find me something new"), String(localized: "What have you learned about me?"), String(localized: "Anything worth buying this week?")], id: \.self) { s in
                                Button { send(s) } label: { Pill(text: s) }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 16)
                    }.scrollIndicators(.hidden).padding(.bottom, 8)
                }
                HStack(spacing: 8) {
                    TextField("Tell me what you're into, or ask me to find something", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(10).background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
                    Button { send(draft) } label: { Image(systemName: "arrow.up").font(.headline) }
                        .buttonStyle(PrimaryButton()).frame(width: 54)
                        .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send")
                }
                .padding(12)
                .background(.ultraThinMaterial)
            }
            .background(LitBackground())
            .navigationTitle(a?.name ?? String(localized: "Scout"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func greeting(_ a: Agent?) -> String {
        guard let a else { return String(localized: "Hi.") }
        if Sizes.required(a) && !Sizes.has(a) {
            return String(localized: "Hey, I'm \(a.name). First thing: what size are you? I only hunt \(a.mission.category == .sneakers ? "pairs" : "pieces") that are in stock in your size.")
        }
        return String(localized: "Hey, I'm \(a.name). Tell me what you've been into lately, what you can't stand, or what you're hunting for, and I'll remember it.")
    }

    private func send(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, store.chatBusy == nil else { return }
        draft = ""
        if let item = aboutItem, !sentContext {
            // The first question carries the item, so the agent knows exactly what we're talking about.
            let price = item.priceKnown && item.price > 0 ? Fmt.money(item.price) : "price not listed"
            t = String(localized: "About the \(item.title) (\(price) at \(item.source)\(item.url.map { ", \($0)" } ?? "")): \(t)")
            sentContext = true
            Analytics.track(.askAbout, ["category": item.category.rawValue])
        }
        let message = t
        Task { await store.sendChat(agentID: agentID, text: message) }
    }

    private func bubble(text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(mine ? Theme.accentInk : Theme.ink)
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background {
                    if mine { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.gradient) }
                    else { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.glass.opacity(1.6)) }
                }
                .textSelection(.enabled)
            if !mine { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder private func actionChip(_ act: ChatAction) -> some View {
        switch act.type {
        case "profile_updated":
            Label("Updated your profile", systemImage: "person.crop.circle.badge.checkmark")
                .font(.caption).foregroundStyle(Theme.muted)
        case "find":
            Label("Flagged \(act.title ?? "a find") in your Finds", systemImage: "sparkles")
                .font(.caption).foregroundStyle(Theme.green)
        case "checkout":
            if let fid = act.findID {
                Button { router.sheet = .checkout(fid) } label: { Label("Review \(act.title ?? "checkout")", systemImage: "cart") }
                    .buttonStyle(GhostButton()).frame(maxWidth: 280)
            }
        default:
            EmptyView()
        }
    }
}

/// Handle, name, sign out and account deletion.
struct AccountSection: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @State private var handle = ""
    @State private var handleError: String?
    @State private var handleSave: SaveState = .idle
    @FocusState private var handleFocused: Bool
    @State private var confirmDelete = false
    @State private var deleting = false

    var body: some View {
        if store.isCloud {
            Section {
                HStack {
                    Text("@").foregroundStyle(Theme.muted)
                    TextField("handle", text: $handle)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($handleFocused)
                        .onSubmit(saveHandle)
                        // Handles are lowercase letters, numbers, dots and underscores: show exactly what will be saved.
                        .onChange(of: handle) { _, v in
                            let clean = String(v.lowercased().filter { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "." || $0 == "_" }.prefix(24))
                            if clean != v { handle = clean }
                            if handleSave == .saved && clean != store.state.profile?.handle { handleSave = .idle }
                        }
                    InlineSave(state: handleSave, dirty: handle != store.state.profile?.handle && !handle.isEmpty, action: saveHandle)
                }
                if let handleError { Text(handleError).font(.footnote).foregroundStyle(Theme.hot) }
                Button("Sign out") { Task { await store.signOut() } }
                Button(deleting ? String(localized: "Deleting…") : String(localized: "Delete my account"), role: .destructive) { confirmDelete = true }
                    .disabled(deleting)
            } header: { Text("Account") } footer: {
                Text("Friends add you by your handle. Deleting your account permanently removes your scouts, finds, purchases, photos and friends.")
            }
            .onAppear { handle = store.state.profile?.handle ?? "" }
            .confirmationDialog("Delete your Baget account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) {
                    deleting = true
                    Task { @MainActor in
                        do { try await store.deleteAccount() } catch {
                            router.say((error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn't delete your account. Try again."))
                        }
                        deleting = false
                    }
                }
            } message: { Text("This can't be undone.") }
        } else if Backend.shared.isConfigured {
            Section {
                Button("Sign in to start hunting for real") { store.resetToWelcome() }
            } header: { Text("Account") } footer: {
                Text("You're looking at sample data. Signing in lets your scouts search the real web, sync across your devices and connect with friends.")
            }
        }
    }

    private func saveHandle() {
        guard handle != store.state.profile?.handle, !handle.isEmpty else { return }
        handleFocused = false
        withAnimation { handleSave = .saving }
        Task { @MainActor in
            handleError = await store.updateHandle(handle)
            if handleError == nil {
                handle = store.state.profile?.handle ?? handle
                withAnimation { handleSave = .saved }
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation { if handleSave == .saved { handleSave = .idle } }
            } else {
                withAnimation { handleSave = .idle }
            }
        }
    }
}
