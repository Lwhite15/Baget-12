import Foundation
import UIKit
import UserNotifications

// MARK: - Rows as the server sends them (snake_case keys are converted automatically)

struct ListingRow: Decodable {
    let id: String
    let title: String
    let brand: String
    let category: String
    let sku: String
    let price: Double?
    let market: Double?
    let source: String
    let url: String?
    let imageUrl: String?
    let dropAt: Date?
    let soldOut: Bool
    let creator: String?
    let traits: [String]
    let tags: [String]
    let sizesInStock: [String]?
    let firstSeenAt: Date?

    var item: Item {
        let cat = Category(rawValue: category) ?? .other
        let sizes = sizesInStock ?? []
        return Item(id: id, title: title, brand: brand, category: cat, sku: sku, price: price ?? 0, market: market ?? price ?? 0,
                    source: source, dropOffset: 0, soldOutAtStart: soldOut, creator: creator, traits: traits, tags: tags,
                    shoeSizes: cat == .sneakers && !sizes.isEmpty ? sizes.compactMap(Sizes.shoeUS) : nil,
                    topSizes: cat == .apparel && !sizes.isEmpty ? sizes.compactMap(Sizes.topSize) : nil,
                    url: url, imageURL: imageUrl, dropAt: dropAt, firstSeen: firstSeenAt, priceKnown: price != nil, isSample: false)
    }
}

struct AgentRow: Decodable {
    let id: String
    let name: String
    let missionCategory: String?
    let missionCustom: String?
    let keywords: [String]
    let traits: [String]
    let makers: [String]
    let creators: [String]
    let size: String
    let maxPerItem: Double
    let monthlyLimit: Double
    let mode: String
    let voice: String
    let learned: [String: Int]
    let priceNote: Double
    let icon: IconRow?
}

/// An icon as stored in jsonb. Empty ({}) means the default.
struct IconRow: Decodable {
    let style: String?
    let emoji: String?
    let color: Int?
    let photoID: String?

    var avatar: Avatar? {
        guard let s = style, let st = Avatar.Style(rawValue: s) else { return nil }
        var a = Avatar()
        a.style = st
        if let emoji { a.emoji = emoji }
        if let color { a.color = color }
        a.photoID = photoID
        return a
    }
}

struct TastePhotoRow: Decodable {
    let id: String
    let agentId: String
    let storagePath: String
    let tags: [String]
    let summary: String
    let createdAt: Date
}

struct FindRow: Decodable {
    let id: String
    let listingId: String
    let agentId: String?
    let score: Int
    let why: [String]
    let status: String
    let passReason: String?
    let watching: Bool
    let createdAt: Date
    let listing: ListingRow?
}

struct PurchaseRow: Decodable {
    let id: String
    let listingId: String?
    let agentId: String?
    let agentName: String
    let title: String
    let amount: Double
    let category: String
    let purchasedAt: Date
}

struct NoteRow: Decodable {
    let id: String
    let agentId: String?
    let friendId: String?
    let senderName: String
    let kind: String
    let body: String
    let findId: String?
    let read: Bool
    let heldForMorning: Bool
    let createdAt: Date
}

struct FriendRow: Decodable {
    let friendshipId: String
    let friendId: String
    let handle: String
    let displayName: String
    let status: String
    let direction: String
    let hunts: [String]
    let likes: [String]
}

struct SuggestionRow: Decodable {
    let id: String
    let shareId: String?
    let fromUser: String
    let listingId: String
    let note: String
    let status: String
    let createdAt: Date
    let listing: ListingRow?
}

struct ReplyRow: Decodable {
    let fromUser: String
    let body: String
    let createdAt: Date
}

struct ShareRow: Decodable {
    let id: String
    let listingId: String
    let toUsers: [String]
    let note: String
    let isSuggestion: Bool
    let createdAt: Date
    let listing: ListingRow?
    let replies: [ReplyRow]?
}

/// The app's settings as kept on the server (profiles.settings).
struct SettingsBlob: Codable {
    var sweepMinutes: Int?
    var quietHours: Bool?
    var groups: [String]?
    var liveTabs: [LiveTab]?
    var avatar: Avatar?
}

private struct SweepReply: Decodable { let swept: Int?; let found: Int?; let message: String? }
private struct ChatReply: Decodable {
    struct Action: Decodable { let type: String; let findId: String?; let title: String? }
    let reply: String
    let actions: [Action]
}
private struct PhotoReply: Decodable { let summary: String; let traits: [String]; let makers: [String]; let creators: [String] }
private struct FriendResult: Decodable { let status: String }

// MARK: - Sync

extension AppStore {
    var api: Backend { Backend.shared }

    /// Signed in and this saved state belongs to the signed-in account.
    var isCloud: Bool { api.isSignedIn && state.accountID == api.userID && state.accountID != nil }

    /// Runs a server write in the background. On failure, says so and re-syncs so the screen shows the truth.
    func push(_ work: @escaping @MainActor (Backend) async throws -> Void) {
        guard isCloud else { return }
        Task { @MainActor in
            do { try await work(self.api) } catch {
                self.syncProblem = (error as? LocalizedError)?.errorDescription ?? "Couldn't save that. Check your connection."
                await self.pull()
            }
        }
    }

    // MARK: Sign in / out

    func didSignIn(fullName: String?) async {
        guard let uid = api.userID else { return }
        state = AppState()
        state.accountID = uid
        Catalog.cloud = [:]
        Catalog.useCloud = true
        save()
        if let name = fullName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            try? await api.update("profiles", "id=eq.\(uid)", ["display_name": String(name.prefix(60))])
        }
        try? await api.update("profiles", "id=eq.\(uid)", ["tz": TimeZone.current.identifier])
        await pull()
        Analytics.track(.signedIn, ["newAccount": state.agents.isEmpty])
        await registerForPush()
    }

    func signOut() async {
        if let token = UserDefaults.standard.string(forKey: "baget.deviceToken") {
            try? await api.rpcVoid("unregister_device", ["p_token": token])
        }
        await api.signOut()
        resetToWelcome()
    }

    func deleteAccount() async throws {
        struct Deleted: Decodable { let deleted: Bool }
        let _: Deleted = try await api.function("delete-account", [:])
        api.forgetSession()
        resetToWelcome()
    }

    func resetToWelcome() {
        state = AppState()
        Catalog.cloud = [:]
        Catalog.useCloud = false
        save()
    }

    func exploreSamples() {
        state = AppState()
        state.exploringSamples = true
        Catalog.useCloud = false
        seed()
        save()
    }

    // MARK: Pull everything

    func pull() async {
        guard isCloud, let uid = api.userID, !pulling else { return }
        pulling = true
        defer { pulling = false }
        do {
            async let agentsQ: [AgentRow] = api.select("agents", "select=*&order=created_at.asc")
            async let photosQ: [TastePhotoRow] = api.select("taste_photos", "select=*&order=created_at.desc")
            async let findsQ: [FindRow] = api.select("finds", "select=*,listing:listings(*)&order=created_at.desc&limit=300")
            async let purchasesQ: [PurchaseRow] = api.select("purchases", "select=*&order=purchased_at.desc&limit=500")
            async let notesQ: [NoteRow] = api.select("notes", "select=*&order=created_at.desc&limit=100")
            async let friendsQ: [FriendRow] = api.rpc("my_friends")
            async let suggestionsQ: [SuggestionRow] = api.select("suggestions", "select=*,listing:listings(*)&to_user=eq.\(uid)&order=created_at.desc&limit=100")
            async let sharesQ: [ShareRow] = api.select("shares", "select=*,listing:listings(*),replies:share_replies(*)&from_user=eq.\(uid)&order=created_at.desc&limit=100")
            async let listingsQ: [ListingRow] = api.select("listings", "select=*&order=last_seen_at.desc&limit=150")
            async let profileQ: Data = api.raw("GET", "/rest/v1/profiles", query: [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "id", value: "eq.\(uid)")])

            let (agents, photos, finds, purchases, notes) = try await (agentsQ, photosQ, findsQ, purchasesQ, notesQ)
            let (friends, suggestions, shares, listings, profileData) = try await (friendsQ, suggestionsQ, sharesQ, listingsQ, profileQ)
            guard isCloud else { return }   // signed out while loading

            var catalog: [String: Item] = [:]
            for l in listings { catalog[l.id] = l.item }
            for f in finds { if let l = f.listing { catalog[l.id] = l.item } }
            for s in suggestions { if let l = s.listing { catalog[l.id] = l.item } }
            for s in shares { if let l = s.listing { catalog[l.id] = l.item } }
            Catalog.cloud = catalog
            Catalog.useCloud = true
            state.listings = Array(catalog.values)

            let board = Dictionary(grouping: photos, by: { $0.agentId })
            state.agents = agents.map { r in
                Agent(id: r.id, name: r.name,
                      mission: r.missionCategory.flatMap { Category(rawValue: $0) }.map { Mission.category($0) } ?? Mission.custom(r.missionCustom ?? ""),
                      keywords: r.keywords, style: StyleProfile(traits: r.traits, makers: r.makers, creators: r.creators),
                      size: r.size, maxPerItem: r.maxPerItem, monthlyLimit: r.monthlyLimit,
                      mode: BuyMode(rawValue: r.mode) ?? .ask, voice: Voice(rawValue: r.voice) ?? .chill,
                      learned: r.learned, priceNote: r.priceNote,
                      tasteBoard: (board[r.id] ?? []).map { TastePhoto(id: $0.id, addedAt: $0.createdAt, tags: $0.tags, summary: $0.summary, storagePath: $0.storagePath) },
                      icon: r.icon?.avatar)
            }
            state.finds = finds.map { f in
                Find(id: f.id, itemID: f.listingId, agentID: f.agentId ?? "", score: f.score, why: f.why,
                     status: FindStatus(rawValue: f.status) ?? .open, passReason: f.passReason, watching: f.watching, foundAt: f.createdAt)
            }
            state.purchases = purchases.map { p in
                Purchase(id: p.id, date: p.purchasedAt, title: p.title, amount: p.amount, agentID: p.agentId ?? "",
                         category: Category(rawValue: p.category) ?? .other, isSample: false, listingID: p.listingId, agentName: p.agentName)
            }
            state.notes = notes.map { n in
                AppNote(id: n.id, date: n.createdAt, agentID: n.agentId, friendID: n.friendId, kind: NoteKind(rawValue: n.kind) ?? .available,
                        body: n.body, findID: n.findId, read: n.read, heldForMorning: n.heldForMorning, senderName: n.senderName)
            }
            state.friends = friends.map { f in
                Friend(id: f.friendId, name: f.displayName.isEmpty ? "@\(f.handle)" : f.displayName, handle: "@\(f.handle)",
                       hunts: f.hunts.compactMap { Category(rawValue: $0) }, likes: f.likes, isPending: f.status != "accepted",
                       isSample: false, replies: [], friendshipID: f.friendshipId, incoming: f.direction == "incoming")
            }
            state.suggestions = suggestions.map { s in
                Suggestion(id: s.id, friendID: s.fromUser, itemID: s.listingId, note: s.note, date: s.createdAt,
                           status: SuggestionStatus(rawValue: s.status) ?? .new, shareID: s.shareId)
            }
            state.shares = shares.map { s in
                Share(id: s.id, itemID: s.listingId, to: s.toUsers, note: s.note, date: s.createdAt, isSuggestion: s.isSuggestion,
                      replies: (s.replies ?? []).sorted { $0.createdAt < $1.createdAt }.map { ShareReply(friendID: $0.fromUser, text: $0.body, date: $0.createdAt) })
            }
            applyProfile(profileData)
            state.lastSynced = .now
            save()
        } catch {
            if !api.isSignedIn { resetToWelcome(); return }
            syncProblem = (error as? LocalizedError)?.errorDescription ?? "Couldn't refresh. Check your connection."
        }
    }

    private func applyProfile(_ data: Data) {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let p = rows.first else { return }
        state.profile = Profile(handle: p["handle"] as? String ?? "", displayName: p["display_name"] as? String ?? "")
        state.settings.shareTasteWithFriends = p["share_taste"] as? Bool ?? true
        state.settings.sharePurchasesWithFriends = p["share_purchases"] as? Bool ?? false
        if let raw = p["settings"], let blobData = try? JSONSerialization.data(withJSONObject: raw),
           let blob = try? JSONDecoder().decode(SettingsBlob.self, from: blobData) {
            if let m = blob.sweepMinutes { state.settings.sweepMinutes = m }
            if let q = blob.quietHours { state.settings.quietHours = q }
            if let g = blob.groups { state.settings.groups = Set(g.compactMap { NoteGroup(rawValue: $0) }) }
            if let tabs = blob.liveTabs, !tabs.isEmpty { state.liveTabs = tabs }
            if let a = blob.avatar { state.avatar = a }
        }
        lastSettingsSnapshot = settingsSnapshot()
    }

    /// What the server should hold for settings; compared on every save so any screen's change syncs.
    func settingsSnapshot() -> Data? {
        let blob = SettingsBlob(sweepMinutes: state.settings.sweepMinutes, quietHours: state.settings.quietHours,
                                groups: state.settings.groups.map(\.rawValue).sorted(), liveTabs: state.liveTabs,
                                avatar: state.avatar)
        var obj: [String: Any] = [:]
        if let d = try? JSONEncoder().encode(blob), let j = try? JSONSerialization.jsonObject(with: d) { obj["settings"] = j }
        obj["share_taste"] = state.settings.shareTasteWithFriends
        obj["share_purchases"] = state.settings.sharePurchasesWithFriends
        return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    func syncSettingsIfChanged() {
        guard isCloud, let uid = api.userID, let snap = settingsSnapshot(), snap != lastSettingsSnapshot else { return }
        lastSettingsSnapshot = snap
        guard let obj = try? JSONSerialization.jsonObject(with: snap) as? [String: Any] else { return }
        push { api in try await api.update("profiles", "id=eq.\(uid)", obj) }
    }

    func updateHandle(_ raw: String) async -> String? {
        let h = raw.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased()
        guard h.range(of: "^[a-z0-9._]{3,24}$", options: .regularExpression) != nil else {
            return "Use 3 to 24 letters, numbers, dots or underscores."
        }
        guard let uid = api.userID else { return BackendError.notSignedIn.message }
        do {
            try await api.update("profiles", "id=eq.\(uid)", ["handle": h])
            state.profile?.handle = h
            save()
            return nil
        } catch let e as BackendError where e.status == 409 {
            return "@\(h) is taken. Try another."
        } catch {
            return (error as? LocalizedError)?.errorDescription
        }
    }

    // MARK: Agents

    func agentFields(_ a: Agent) -> [String: Any] {
        ["name": a.name, "keywords": a.keywords, "traits": a.style.traits, "makers": a.style.makers, "creators": a.style.creators,
         "size": a.size, "max_per_item": a.maxPerItem, "monthly_limit": a.monthlyLimit, "mode": a.mode.rawValue,
         "voice": a.voice.rawValue, "learned": a.learned, "price_note": a.priceNote, "icon": Self.iconJSON(a.icon)]
    }

    static func iconJSON(_ icon: Avatar?) -> [String: Any] {
        guard let icon, let d = try? JSONEncoder().encode(icon),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return obj
    }

    func pushAgent(_ id: String) {
        guard let a = agent(id) else { return }
        let fields = agentFields(a)
        push { api in try await api.update("agents", "id=eq.\(id)", fields) }
    }

    func cloudDeploy(_ a: Agent) async -> String {
        var row = agentFields(a)
        row["id"] = a.id
        switch a.mission {
        case .category(let c): row["mission_category"] = c.rawValue
        case .custom(let t): row["mission_custom"] = String(t.prefix(80))
        }
        do {
            try await api.insert("agents", row)
        } catch {
            state.agents.removeAll { $0.id == a.id }
            save()
            let msg = (error as? LocalizedError)?.errorDescription ?? ""
            return msg.contains("agent_limit") ? "A squad can have up to 12 agents." : "Couldn't deploy \(a.name). \(msg)"
        }
        return await cloudSweep(agentID: a.id, quietIfNone: true) ?? "\(a.name) is out hunting. Finds land here as it spots them."
    }

    /// Asks the server to sweep now. Returns what to tell the person.
    @discardableResult
    func cloudSweep(agentID: String? = nil, quietIfNone: Bool = false) async -> String? {
        do {
            var body: [String: Any] = [:]
            if let agentID { body["agent_id"] = agentID }
            let r: SweepReply = try await api.function("sweep", body)
            await pull()
            if let m = r.message { return m }
            let n = r.found ?? 0
            if n == 0 && quietIfNone { return nil }
            return n > 0 ? "\(n) new find\(n == 1 ? "" : "s")" : "Your squad looked. Nothing new fits you right now."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Your squad couldn't reach the web just now."
        }
    }

    // MARK: Taste photos

    func readPhotoCloud(agentID: String, image: UIImage) async -> PhotoReading? {
        guard isCloud, let jpeg = PhotoTaste.normalized(image, maxSide: 768).jpegData(compressionQuality: 0.7) else { return nil }
        do {
            let r: PhotoReply = try await api.function("read-photo", ["agent_id": agentID, "image_base64": jpeg.base64EncodedString(), "media_type": "image/jpeg"])
            return PhotoReading(summary: r.summary, traits: r.traits, makers: r.makers, creators: r.creators, byClaude: true)
        } catch {
            return nil
        }
    }

    func uploadTastePhoto(agentID: String, photo: TastePhoto, jpeg: Data) {
        guard let uid = api.userID else { return }
        let path = "\(uid)/\(photo.id).jpg"
        if let i = agentIndex(agentID), let j = state.agents[i].tasteBoard.firstIndex(where: { $0.id == photo.id }) {
            state.agents[i].tasteBoard[j].storagePath = path
        }
        let fields = agent(agentID).map { agentFields($0) }
        push { api in
            try await api.upload(bucket: "taste-photos", path: path, jpeg: jpeg)
            try await api.insert("taste_photos", ["id": photo.id, "agent_id": agentID, "storage_path": path, "tags": photo.tags, "summary": photo.summary])
            if let fields { try await api.update("agents", "id=eq.\(agentID)", fields) }
        }
    }

    func deleteTastePhotoCloud(photo: TastePhoto, agentID: String) {
        let fields = agent(agentID).map { agentFields($0) }
        push { api in
            try await api.delete("taste_photos", "id=eq.\(photo.id)")
            if let path = photo.storagePath { try? await api.removeFile(bucket: "taste-photos", path: path) }
            if let fields { try await api.update("agents", "id=eq.\(agentID)", fields) }
        }
    }

    /// Photos added on another device are fetched once and kept on this phone.
    func fetchPhotoIfNeeded(_ photo: TastePhoto) {
        guard isCloud, let path = photo.storagePath, !downloading.contains(photo.id) else { return }
        downloading.insert(photo.id)
        Task { @MainActor in
            defer { self.downloading.remove(photo.id) }
            if let data = try? await self.api.download(bucket: "taste-photos", path: path) {
                self.cacheTastePhoto(id: photo.id, data: data)
                self.photoVersion += 1
            }
        }
    }

    // MARK: Chat

    func sendChat(agentID: String, text: String) async {
        var turns = state.chats[agentID] ?? []
        turns.append(ChatTurn(role: "user", text: text))
        state.chats[agentID] = turns
        chatBusy = agentID
        defer { chatBusy = nil }
        let history = turns.suffix(14).map { ["role": $0.role, "content": $0.text] }
        do {
            let r: ChatReply = try await api.function("chat", ["agent_id": agentID, "messages": Array(history)])
            let actions = r.actions.map { ChatAction(type: $0.type, findID: $0.findId, title: $0.title) }
            state.chats[agentID, default: []].append(ChatTurn(role: "assistant", text: r.reply, actions: actions))
            Analytics.track(.chatSent, ["actions": actions.count])
            if !actions.isEmpty { await pull() }
        } catch {
            state.chats[agentID, default: []].append(ChatTurn(role: "assistant", text: (error as? LocalizedError)?.errorDescription ?? "I lost the connection there. Send that again?"))
        }
        if (state.chats[agentID]?.count ?? 0) > 60 { state.chats[agentID]?.removeFirst((state.chats[agentID]?.count ?? 0) - 60) }
        save()
    }

    // MARK: Friends

    func addFriendCloud(_ raw: String) async -> (ok: Bool, message: String) {
        let h = raw.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased()
        guard !h.isEmpty else { return (false, "Enter a friend's handle, like @maya.") }
        do {
            let r: FriendResult = try await api.rpc("request_friend", ["p_handle": h])
            await pull()
            switch r.status {
            case "requested": Analytics.track(.friendInvited, [:]); return (true, "Request sent to @\(h)")
            case "accepted": return (true, "You and @\(h) are now friends")
            case "exists": return (false, "You've already added @\(h).")
            case "self": return (false, "That's your own handle.")
            default: return (false, "No one on Baget goes by @\(h). Check the spelling.")
            }
        } catch {
            return (false, (error as? LocalizedError)?.errorDescription ?? "Couldn't send that request.")
        }
    }

    func respondToFriend(_ friend: Friend, accept: Bool) {
        guard let fid = friend.friendshipID else { return }
        if accept, let i = state.friends.firstIndex(where: { $0.id == friend.id }) { state.friends[i].isPending = false }
        if !accept { state.friends.removeAll { $0.id == friend.id } }
        save()
        push { api in
            try await api.rpcVoid("respond_friend", ["p_id": fid, "p_accept": accept])
            await self.pull()
        }
    }

    func replyToSuggestion(_ s: Suggestion, text: String) {
        guard let shareID = s.shareID else { return }
        push { api in try await api.insert("share_replies", ["share_id": shareID, "body": String(text.prefix(280))]) }
    }

    // MARK: Push registration

    func registerForPush() async {
        await Notifier.requestPermission()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func registerDevice(token: String) async {
        guard isCloud else { return }
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif
        do {
            try await api.rpcVoid("register_device", ["p_token": token, "p_env": env])
            UserDefaults.standard.set(token, forKey: "baget.deviceToken")
            pushRegistered = true
        } catch {
            pushRegistered = false
        }
    }
}
