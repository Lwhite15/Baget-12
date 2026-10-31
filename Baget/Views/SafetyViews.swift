import SwiftUI

/// Report and block (App Store guideline 1.2). A block ends the friendship, removes what they sent you, and stops them
/// finding, adding or sending you anything, both ways. Reports go to the Baget team, reviewed within 24 hours.
extension AppStore {
    enum ReportReason: String, CaseIterable, Identifiable {
        case spam, inappropriate, harassment, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .spam: return String(localized: "Spam or scams")
            case .inappropriate: return String(localized: "Inappropriate photo or name")
            case .harassment: return String(localized: "Harassment or hateful messages")
            case .other: return String(localized: "Something else")
            }
        }
    }

    func blockUser(_ id: String) async -> Bool {
        guard isCloud else { return false }
        do {
            try await api.rpcVoid("block_user", ["p_user": id])
            state.friends.removeAll { $0.id == id }
            state.suggestions.removeAll { $0.friendID == id }
            save()
            return true
        } catch { syncProblem = String(localized: "Couldn't block right now. Try again."); return false }
    }

    func unblockUser(_ id: String) async {
        try? await api.rpcVoid("unblock_user", ["p_user": id])
    }

    func reportUser(_ id: String, reason: ReportReason, detail: String, suggestionID: String?) async -> Bool {
        guard isCloud else { return false }
        var args: [String: Any] = ["p_user": id, "p_reason": reason.rawValue, "p_detail": detail]
        if let suggestionID { args["p_suggestion"] = suggestionID }
        do { try await api.rpcVoid("report_user", args); return true }
        catch { syncProblem = String(localized: "Couldn't send the report. Try again."); return false }
    }

    struct BlockedPerson: Decodable, Identifiable {
        let userId: String; let handle: String; let displayName: String
        var id: String { userId }
    }

    func blockedPeople() async -> [BlockedPerson] {
        (try? await api.rpc("my_blocks")) ?? []
    }
}

/// Who's being reported or blocked.
struct SafetyTarget: Identifiable, Equatable {
    let userID: String
    let name: String
    let handle: String
    var suggestionID: String? = nil
    var id: String { userID + (suggestionID ?? "") }
    var label: String { handle.isEmpty ? name : handle }

    init(_ f: Friend, suggestionID: String? = nil) {
        userID = f.id; name = f.name; handle = f.handle; self.suggestionID = suggestionID
    }
}

/// "Report @name": pick a reason, optionally block too.
struct ReportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    let target: SafetyTarget
    var onBlocked: () -> Void = {}
    @State private var reason: AppStore.ReportReason?
    @State private var detail = ""
    @State private var alsoBlock = true
    @State private var sending = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Report \(target.label)").font(.title3.weight(.heavy)).foregroundStyle(Theme.ink)
                    Spacer()
                    CloseButton { dismiss() }
                }
                Text("The Baget team reviews every report within 24 hours. They won't know you reported them.")
                    .font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                ForEach(AppStore.ReportReason.allCases) { r in
                    Button { reason = r } label: {
                        HStack {
                            Text(r.label).font(.subheadline).foregroundStyle(Theme.ink)
                            Spacer()
                            Image(systemName: reason == r ? "checkmark.circle.fill" : "circle").foregroundStyle(reason == r ? Theme.cyan : Theme.muted)
                        }
                        .padding(13)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(reason == r ? Theme.cyan.opacity(0.6) : Theme.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(reason == r ? .isSelected : [])
                }
                TextField("Anything to add? (optional)", text: $detail, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(12)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                Toggle(isOn: $alsoBlock) { Text("Also block \(target.label)").font(.subheadline).foregroundStyle(Theme.ink) }
                    .tint(Theme.hot)
                Button {
                    guard let reason else { return }
                    sending = true
                    Task { @MainActor in
                        defer { sending = false }
                        guard await store.reportUser(target.userID, reason: reason, detail: detail, suggestionID: target.suggestionID) else {
                            if let p = store.syncProblem { router.say(p) }
                            return
                        }
                        var blocked = false
                        if alsoBlock { blocked = await store.blockUser(target.userID) }
                        router.say(blocked ? String(localized: "Reported and blocked. Thanks for telling us.") : String(localized: "Reported. Thanks for telling us."))
                        dismiss()
                        if blocked { onBlocked() }
                    }
                } label: {
                    HStack { if sending { ProgressView().tint(.white) }; Text("Send report") }
                        .font(.body.weight(.heavy)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(LinearGradient(colors: [Color(red: 1, green: 0.54, blue: 0.36), Theme.hot], startPoint: .leading, endPoint: .trailing),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(reason == nil || sending)
                .opacity(reason == nil ? 0.5 : 1)
            }
            .padding(20)
        }
        .background(Theme.panel)
        .presentationDetents([.large])
    }
}

/// Report and Block, wherever someone appears: confirms a block before doing it.
struct SafetyActions: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Binding var reporting: SafetyTarget?
    @Binding var blocking: SafetyTarget?
    var onBlocked: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .sheet(item: $reporting) { t in
                ReportSheet(target: t, onBlocked: onBlocked).environment(store).environment(router).preferredColorScheme(.dark)
            }
            .confirmationDialog(blocking.map { String(localized: "Block \($0.label)?") } ?? "",
                                isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }), titleVisibility: .visible) {
                Button("Block", role: .destructive) {
                    guard let t = blocking else { return }
                    blocking = nil
                    Task { @MainActor in
                        if await store.blockUser(t.userID) { router.say(String(localized: "Blocked \(t.label)")); onBlocked() }
                        else if let p = store.syncProblem { router.say(p) }
                    }
                }
            } message: {
                Text("They won't be able to find you, add you or send you anything, and you won't see them. They aren't told. Unblock any time in Settings.")
            }
    }
}

extension View {
    func safetyActions(reporting: Binding<SafetyTarget?>, blocking: Binding<SafetyTarget?>, onBlocked: @escaping () -> Void = {}) -> some View {
        modifier(SafetyActions(reporting: reporting, blocking: blocking, onBlocked: onBlocked))
    }
}

/// Settings > Blocked people: everyone you've blocked, with Unblock.
struct BlockedPeopleView: View {
    @Environment(AppStore.self) private var store
    @State private var people: [AppStore.BlockedPerson] = []
    @State private var loading = true

    var body: some View {
        Form {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if people.isEmpty {
                Text("You haven't blocked anyone.").foregroundStyle(Theme.muted)
            } else {
                Section {
                    ForEach(people) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.displayName.isEmpty ? "@\(p.handle)" : p.displayName)
                                Text("@\(p.handle)").font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button("Unblock") {
                                Task { @MainActor in
                                    await store.unblockUser(p.userId)
                                    withAnimation { people.removeAll { $0.id == p.id } }
                                }
                            }
                            .buttonStyle(.borderless).foregroundStyle(Theme.cyan)
                        }
                    }
                } footer: {
                    Text("Blocked people can't find you, add you or send you anything. Unblocking doesn't make you friends again.")
                }
            }
        }
        .navigationTitle("Blocked people")
        .task { people = await store.blockedPeople(); loading = false }
    }
}
