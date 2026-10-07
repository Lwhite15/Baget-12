import SwiftUI
import AuthenticationServices

/// First screen when Baget is connected to a server: sign in, or look around with sample data.
struct WelcomeView: View {
    @Environment(AppStore.self) private var store
    @State private var nonce = Backend.makeNonce()
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ZStack {
            LitBackground()
            VStack(alignment: .leading, spacing: 22) {
                Spacer()
                HStack(spacing: 0) {
                    Text("Baget").foregroundStyle(Theme.ink)
                    Text(".").gradientText()
                }
                .font(.system(size: 56, weight: .heavy))
                .tracking(-2)
                Text("Your own personal squad that learns your taste and makes recommendations for you to purchase.")
                    .font(.title3).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 12) {
                    point("sparkle.magnifyingglass", "Agents search the web for sneakers, fragrance, watches, cars, furniture or anything you name.")
                    point("heart.text.square", "They learn from what you buy, pass on and show them in photos.")
                    point("bell.badge", "They text you like a friend when something you'd love drops.")
                }
                .padding(.vertical, 6)
                Spacer()
                if working {
                    HStack { Spacer(); ProgressView().tint(Theme.cyan); Spacer() }.frame(height: 52)
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
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.hot) }
                Button("Look around with sample data first") { store.exploreSamples() }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                Text("Signing in creates your Baget account. You can delete it any time in Notifications > Account.")
                    .font(.caption).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.cyan).frame(width: 24)
            Text(text).font(.subheadline).foregroundStyle(Theme.ink)
        }
    }

    @MainActor private func handle(_ result: Result<ASAuthorization, Error>) async {
        error = nil
        switch result {
        case .failure(let e):
            if (e as? ASAuthorizationError)?.code != .canceled { error = "Sign in with Apple didn't finish. Try again." }
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
                error = "Apple didn't send a sign-in token. Try again."
                return
            }
            working = true
            defer { working = false }
            do {
                try await Backend.shared.signInWithApple(idToken: token, nonce: nonce)
                let name = [cred.fullName?.givenName, cred.fullName?.familyName].compactMap { $0 }.joined(separator: " ")
                await store.didSignIn(fullName: name.isEmpty ? nil : name)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't sign in. Try again."
            }
        }
    }
}

/// Talk to an agent. It learns from the conversation, searches the web, and can flag finds or line up checkout.
struct ChatView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    let agentID: String
    @State private var draft = ""

    var body: some View {
        let a = store.agent(agentID)
        let turns = store.state.chats[agentID] ?? []
        let busy = store.chatBusy == agentID
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            bubble(text: greeting(a), mine: false)
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
                if turns.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(["Find me something new", "What have you learned about me?", "Anything worth buying this week?"], id: \.self) { s in
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
            .navigationTitle(a?.name ?? "Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func greeting(_ a: Agent?) -> String {
        guard let a else { return "Hi." }
        if Sizes.required(a) && !Sizes.has(a) {
            return "Hey, I'm \(a.name). First thing: what size are you? I only hunt \(a.mission.category == .sneakers ? "pairs" : "pieces") that are in stock in your size."
        }
        return "Hey, I'm \(a.name). Tell me what you've been into lately, what you can't stand, or what you're hunting for, and I'll remember it."
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, store.chatBusy == nil else { return }
        draft = ""
        Task { await store.sendChat(agentID: agentID, text: t) }
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
    @State private var confirmDelete = false
    @State private var deleting = false

    var body: some View {
        if store.isCloud {
            Section {
                HStack {
                    Text("@").foregroundStyle(Theme.muted)
                    TextField("handle", text: $handle)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit(saveHandle)
                    if handle != store.state.profile?.handle && !handle.isEmpty { Button("Save", action: saveHandle).bold() }
                }
                if let handleError { Text(handleError).font(.footnote).foregroundStyle(Theme.hot) }
                Button("Sign out") { Task { await store.signOut() } }
                Button(deleting ? "Deleting…" : "Delete my account", role: .destructive) { confirmDelete = true }
                    .disabled(deleting)
            } header: { Text("Account") } footer: {
                Text("Friends add you by your handle. Deleting your account permanently removes your agents, finds, purchases, photos and friends.")
            }
            .onAppear { handle = store.state.profile?.handle ?? "" }
            .confirmationDialog("Delete your Baget account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) {
                    deleting = true
                    Task { @MainActor in
                        do { try await store.deleteAccount() } catch {
                            router.say((error as? LocalizedError)?.errorDescription ?? "Couldn't delete your account. Try again.")
                        }
                        deleting = false
                    }
                }
            } message: { Text("This can't be undone.") }
        } else if Backend.shared.isConfigured {
            Section {
                Button("Sign in to start hunting for real") { store.resetToWelcome() }
            } header: { Text("Account") } footer: {
                Text("You're looking at sample data. Signing in lets your agents search the real web, sync across your devices and connect with friends.")
            }
        }
    }

    private func saveHandle() {
        Task { @MainActor in
            handleError = await store.updateHandle(handle)
            if handleError == nil { router.say("Your handle is now @\(store.state.profile?.handle ?? handle)") }
        }
    }
}
