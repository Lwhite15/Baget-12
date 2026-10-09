import Foundation
import Observation
import SwiftUI
import UIKit

struct Story: Identifiable, Hashable {
    var id: String { item.id }
    let item: Item
    let kind: String
    let headline: String
    let dek: String
    let minutesAgo: Int
    let agentID: String?
    let match: Match?
    let isLive: Bool
    var forYou: Bool { (match?.score ?? 0) >= 60 && !(match?.notInSize ?? false) }
    var score: Int { match?.score ?? 12 }
}

struct FriendTake { let text: String; let caution: Bool }

@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    var state: AppState
    /// In-app banner (the phone-style notification shown while the app is open).
    var banner: AppNote?
    /// Set when you tap a system notification; the root view opens it.
    var openNoteFromSystem: String?
    /// A sync problem to tell the person about (shown as a toast, then cleared).
    var syncProblem: String?
    /// The agent whose chat is waiting on a reply.
    var chatBusy: String?
    /// Bumped when a taste photo finishes downloading, so boards redraw.
    var photoVersion = 0
    /// Bumped when your icon photo changes or finishes downloading.
    var avatarVersion = 0
    var pushRegistered = false
    @ObservationIgnored var pulling = false
    @ObservationIgnored var lastSettingsSnapshot: Data?
    @ObservationIgnored var downloading: Set<String> = []

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("baget-state.json")
    }()

    init() {
        let saved = (try? Data(contentsOf: Self.fileURL)).flatMap { try? JSONDecoder().decode(AppState.self, from: $0) }
        state = saved ?? AppState()
        let backend = Backend.shared
        if backend.isSignedIn {
            if state.accountID != backend.userID {
                // Signed in, but this saved data belongs to someone else or to the sample tour: start clean.
                state = AppState()
                state.accountID = backend.userID
            }
            Catalog.cloud = Dictionary(state.listings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            Catalog.useCloud = true
        } else {
            if state.accountID != nil { state = AppState() }      // session ended
            Catalog.useCloud = false
            if !backend.isConfigured { state.exploringSamples = true }   // no server yet: the sample tour is the app
            if state.exploringSamples && state.agents.isEmpty && state.purchases.isEmpty { seed() }
        }
        lastSettingsSnapshot = settingsSnapshot()
    }

    /// Whether to show the welcome screen (sign in, or look around with samples).
    var needsWelcome: Bool { Backend.shared.isConfigured && !isCloud && !state.exploringSamples }

    func save() {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        syncSettingsIfChanged()
    }

    // MARK: - Availability

    func dropDate(_ item: Item) -> Date { item.dropAt ?? state.catalogStart.addingTimeInterval(item.dropOffset * 60) }
    func isSoldOut(_ item: Item) -> Bool { item.soldOutAtStart && !state.restockedItemIDs.contains(item.id) }
    func isLive(_ item: Item) -> Bool { !isSoldOut(item) && dropDate(item) <= .now }

    func whenLabel(_ item: Item) -> String {
        if isSoldOut(item) { return "RESTOCK WATCH" }
        let m = dropDate(item).timeIntervalSinceNow / 60
        if m <= 0 { return "AVAILABLE" }
        if m < 60 { return "IN \(Int(m.rounded(.up)))M" }
        if m < 1440 { return "IN \(Int(m / 60))H \(Int(m.truncatingRemainder(dividingBy: 60)))M" }
        return "IN \(Int(safe: (m / 1440).rounded()))D"
    }

    func whenText(_ item: Item) -> String {
        let m = dropDate(item).timeIntervalSinceNow / 60
        if m <= 0 { return "right now" }
        if m < 60 { return "in \(Int(m.rounded(.up))) minutes" }
        if m < 1440 { return "in about \(Int(safe: (m / 60).rounded())) hours" }
        return m < 2880 ? "tomorrow" : "this week"
    }

    // MARK: - Agents and money

    func agent(_ id: String?) -> Agent? { state.agents.first { $0.id == id } }
    func agentIndex(_ id: String) -> Int? { state.agents.firstIndex { $0.id == id } }

    func best(for item: Item) -> (agent: Agent, match: Match)? {
        var best: (agent: Agent, match: Match)?
        for a in state.agents {
            if let m = Matcher.match(a, item), m.score > (best?.match.score ?? -1) { best = (agent: a, match: m) }
        }
        return best
    }


    func owned(by a: Agent) -> [Item] {
        state.finds.filter { $0.agentID == a.id && $0.status == .acquired }.compactMap { Catalog.item($0.itemID) }
    }

    /// The honest friend's take on a find.
    func take(_ a: Agent, _ item: Item) -> FriendTake {
        let twin = owned(by: a).first { $0.id != item.id && $0.brand == item.brand && Set($0.traits).intersection(item.traits).count >= 2 }
        if isSoldOut(item) { return FriendTake(text: "Sold out at the source. I'll watch for a restock and won't let you overpay resale.", caution: false) }
        if let twin { return FriendTake(text: "You already picked up the \(twin.title). This is close. Sure you want both?", caution: true) }
        if a.priceNote > 0 && item.price > a.priceNote { return FriendTake(text: "You've passed on things at this price before. Flagging it anyway because it fits you so well.", caution: true) }
        if item.market < item.price * 0.97 { return FriendTake(text: "Market's below the asking price right now. I'd wait or buy it secondhand.", caution: true) }
        if item.price > 0 && item.market > item.price * 1.25 { return FriendTake(text: "Asking is \(Int(safe: ((item.market / item.price - 1) * 100).rounded()))% under market. If you love it, this is the moment.", caution: false) }
        return FriendTake(text: "Fair price, right in your lane.", caution: false)
    }

    // MARK: - Sweeps

    func kindFor(_ item: Item) -> NoteKind {
        if isSoldOut(item) { return .watch }
        if dropDate(item) > .now { return .release }
        if item.market > item.price * 1.2 { return .steal }
        return .available
    }

    @discardableResult
    func sweep(background: Bool = false, quiet: Bool = false) -> (found: Int, bought: Int, notes: Int) {
        let unseen = Catalog.items.filter { !state.seenItemIDs.contains($0.id) }
        let avgIntel = state.agents.isEmpty ? 0 : Double(state.agents.map(Matcher.intel).reduce(0, +)) / Double(state.agents.count)
        let quota = background ? max(2, Int(safe: (1 + Double(state.agents.count) * 0.6).rounded()))
                               : Int(safe: (2 + Double(state.agents.count) * 1.2 + avgIntel / 25).rounded())
        var found = 0, bought = 0
        var notes: [AppNote] = []
        for item in unseen {
            if found >= quota { break }
            guard let b = best(for: item) else { continue }       // nobody covers it yet; a future agent might
            state.seenItemIDs.insert(item.id)
            guard b.match.score >= 45 else { continue }
            var find = Find(id: UUID().uuidString, itemID: item.id, agentID: b.agent.id, score: b.match.score, why: b.match.why)
            found += 1
            Analytics.track(.findCreated, ["category": item.category.rawValue, "mission": b.agent.mission.category?.rawValue ?? "custom",
                                           "score": find.score, "mode": b.agent.mode.rawValue, "background": background,
                                           "fromLearning": b.match.why.contains { $0.hasPrefix("You've gone for") }])
            let a = b.agent
            if a.mode == .auto && find.score >= 80 && !isSoldOut(item) && item.priceKnown && isLive(item) {
                find.status = .acquired
                state.finds.insert(find, at: 0)
                record(a, item)
                Analytics.track(.autoPurchased, ["amount": item.price, "category": item.category.rawValue, "score": find.score])
                log("\(a.name) auto-bought \(item.title) for \(Fmt.money(item.price))")
                bought += 1
                if let n = notify(a, .bought, item, findID: find.id) { notes.append(n) }
            } else {
                state.finds.insert(find, at: 0)
                log("\(a.name) flagged \(item.title) (\(find.score)% match)")
                if let n = notify(a, kindFor(item), item, findID: find.id, extra: "\(find.score)") { notes.append(n) }
            }
        }
        save()
        if background {
            notes.filter { !$0.heldForMorning }.forEach { Notifier.post($0, title: agent($0.agentID)?.name ?? "Baget") }
            notes.filter { $0.heldForMorning }.forEach { Notifier.postAtMorning($0, title: agent($0.agentID)?.name ?? "Baget") }
        } else if !quiet, let first = notes.first {
            showBanner(first)
        }
        return (found, bought, notes.count)
    }

    /// Runs when iOS wakes the app in the background, and catches up when you reopen it.
    func catchUp(minutes: Double) {
        guard !isCloud else { return }
        let every = Double(max(15, state.settings.sweepMinutes))
        let runs = min(4, Int(minutes / every))
        guard runs > 0, !state.agents.isEmpty else { return }
        var found = 0, bought = 0, notes = 0, restocks = 0
        for r in 0..<runs {
            if r == runs - 1, let w = state.finds.first(where: { f in
                guard let it = Catalog.item(f.itemID) else { return false }
                return isSoldOut(it) && f.watching
            }), let it = Catalog.item(w.itemID), let a = agent(w.agentID) {
                state.restockedItemIDs.insert(it.id)
                restocks += 1
                if notify(a, .restock, it, findID: w.id) != nil { notes += 1 }
            }
            let res = sweep(background: false, quiet: true)
            found += res.found; bought += res.bought; notes += res.notes
        }
        state.awayReport = AwayReport(date: .now, minutes: Int(minutes), sweeps: runs, checked: runs * Catalog.items.count * 3,
                                      found: found, bought: bought, notes: notes, restocks: restocks)
        log("Background: \(runs) sweep\(runs > 1 ? "s" : "") while you were away, \(found) new find\(found == 1 ? "" : "s")")
        save()
    }

    func backgroundRefresh() async {
        if isCloud {
            // The server sweeps on its own schedule. Here we pick up what it found, and if this phone
            // can't get push notifications, raise them locally instead.
            let hadSynced = state.lastSynced != nil
            let before = Set(state.notes.map(\.id))
            await pull()
            if hadSynced && !pushRegistered {
                for n in state.notes where !before.contains(n.id) && !n.read && !n.heldForMorning { Notifier.post(n, title: noteSender(n)) }
            }
            state.lastSeen = .now
            save()
            return
        }
        let res = sweep(background: true)
        if res.found > 0 { log("Background sweep found \(res.found)") }
        state.lastSeen = .now
        save()
    }

    /// When the app opens: the sample tour simulates missed sweeps; signed in, it pulls what the server found.
    func cameBack(afterMinutes gone: Double) async {
        if isCloud {
            let since = state.lastSeen
            await pull()
            let found = state.finds.filter { $0.foundAt > since }.count
            let notes = state.notes.filter { $0.date > since }.count
            if gone >= 15 && (found > 0 || notes > 0) {
                state.awayReport = AwayReport(date: .now, minutes: Int(gone), sweeps: 0, checked: 0, found: found, bought: 0, notes: notes,
                                              restocks: state.notes.filter { $0.date > since && $0.kind == .restock }.count)
                save()
            }
        } else if gone >= 15 {
            catchUp(minutes: gone)
        }
    }

    // MARK: - Notifications

    private func inQuietHours() -> Bool {
        let h = Calendar.current.component(.hour, from: .now)
        return h >= 22 || h < 8
    }

    @discardableResult
    func notify(_ a: Agent, _ kind: NoteKind, _ item: Item?, findID: String? = nil, extra: String = "") -> AppNote? {
        if let g = kind.group, !state.settings.groups.contains(g) { return nil }
        let urgent = kind == .restock || kind == .bought || (kind == .release && (item.map { dropDate($0).timeIntervalSinceNow < 90 * 60 } ?? false))
        let body = FriendVoice.line(agent: a, kind: kind, item: item, extra: extra, when: item.map { whenText($0) } ?? "")
        let note = AppNote(id: UUID().uuidString.lowercased(), agentID: a.id, kind: kind, body: body, findID: findID,
                           heldForMorning: state.settings.quietHours && inQuietHours() && !urgent, senderName: a.name)
        state.notes.insert(note, at: 0)
        if kind == .learned {
            let row: [String: Any] = ["id": note.id, "agent_id": a.id, "kind": "learned", "body": String(body.prefix(500)), "sender_name": a.name]
            push { api in try await api.insert("notes", row) }
        }
        Analytics.track(.notificationSent, ["kind": kind.rawValue, "voice": a.voice.rawValue, "heldForMorning": note.heldForMorning])
        if state.notes.count > 100 { state.notes.removeLast(state.notes.count - 100) }
        return note
    }

    func showBanner(_ note: AppNote) {
        withAnimation(.spring(duration: 0.35)) { banner = note }
        let id = note.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if self.banner?.id == id { withAnimation { self.banner = nil } }
        }
    }

    var unreadCount: Int { state.notes.filter { !$0.read }.count }

    func noteSender(_ n: AppNote) -> String {
        if let f = n.friendID { return state.friends.first { $0.id == f }?.name ?? "A friend" }
        return agent(n.agentID)?.name ?? "Retired agent"
    }

    // MARK: - Learning

    func learn(_ agentID: String, from item: Item, delta: Int, note: String? = nil) {
        guard let i = agentIndex(agentID) else { return }
        var gained: [String] = []
        for k in item.traits + [item.brand] where Self.isTaste(k) {
            let n = TextMatch.norm(k)
            let before = state.agents[i].learned[n] ?? 0
            state.agents[i].learned[n] = max(-3, min(5, before + delta))
            // a taste that keeps coming up becomes part of the brief
            if delta > 0 && before < 2 && (state.agents[i].learned[n] ?? 0) >= 2 {
                if k == item.brand {
                    if !state.agents[i].style.makers.contains(where: { TextMatch.norm($0) == n }) { state.agents[i].style.makers.append(k); gained.append(k) }
                } else if !state.agents[i].style.traits.contains(where: { TextMatch.norm($0) == n }) {
                    state.agents[i].style.traits.append(n); gained.append(n)
                }
            }
        }
        let a = state.agents[i]
        if !gained.isEmpty {
            log("\(a.name) learned you like \(gained.joined(separator: ", "))")
            Analytics.track(.agentLearned, ["mission": a.mission.category?.rawValue ?? "custom", "count": gained.count])
            if let n = notify(a, .learned, nil, extra: gained.joined(separator: ", ")) { showBanner(n) }
        } else if let note { log("\(a.name) noted: \(note)") }
        save()
        pushAgent(agentID)
    }

    /// A real taste word, not a price, sale tag, size, SKU or season code.
    static func isTaste(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.count <= 40 else { return false }
        if t.range(of: #"[$£€¥]|\b(sale|price|off|usd|gbp|eur)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        let digits = t.filter(\.isNumber).count
        if digits * 2 >= t.count { return false }                      // mostly numbers: 2023, 818989, 10.5
        if t.range(of: #"^(ss|fw|aw)\d{2}$|^size\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return true
    }

    func unlearn(_ agentID: String, key: String) {
        guard let i = agentIndex(agentID) else { return }
        if key == "__price" { state.agents[i].priceNote = 0 } else {
            state.agents[i].learned.removeValue(forKey: key)
            state.agents[i].style.traits.removeAll { TextMatch.norm($0) == key }
            state.agents[i].style.makers.removeAll { TextMatch.norm($0) == key }
        }
        log("\(state.agents[i].name) forgot \(key == "__price" ? "your price preference" : key)")
        save()
        pushAgent(agentID)
    }

    // MARK: - Actions on finds

    @discardableResult
    func record(_ a: Agent, _ item: Item, amount: Double? = nil) -> Purchase {
        let p = Purchase(id: UUID().uuidString.lowercased(), date: .now, title: item.title, amount: amount ?? item.price, agentID: a.id,
                         category: item.category, listingID: item.isSample ? nil : item.id, agentName: a.name)
        state.purchases.append(p)
        return p
    }

    /// Signed in, this records a purchase you made at the store. In the sample tour it simulates one.
    func confirmPurchase(_ findID: String, amount: Double? = nil) {
        guard let fi = state.finds.firstIndex(where: { $0.id == findID }), let item = Catalog.item(state.finds[fi].itemID),
              let a = agent(state.finds[fi].agentID) ?? state.agents.first(where: { Matcher.covers($0, item) }) else { return }
        state.finds[fi].status = .acquired
        let p = record(a, item, amount: amount)
        log("You bought \(item.title) via \(a.name) (\(Fmt.money(p.amount)))")
        let row: [String: Any] = ["id": p.id, "title": p.title, "amount": p.amount, "category": p.category.rawValue,
                                  "agent_id": a.id, "agent_name": a.name, "listing_id": p.listingID.map { $0 as Any } ?? NSNull()]
        push { api in
            try await api.update("finds", "id=eq.\(findID)", ["status": "acquired"])
            try await api.insert("purchases", row)
        }
        learn(a.id, from: item, delta: 2)
        save()
    }

    func watch(_ findID: String) {
        guard let fi = state.finds.firstIndex(where: { $0.id == findID }), let item = Catalog.item(state.finds[fi].itemID) else { return }
        state.finds[fi].watching = true
        push { api in try await api.update("finds", "id=eq.\(findID)", ["watching": true]) }
        log("\(agent(state.finds[fi].agentID)?.name ?? "Agent") is watching \(item.title)")
        learn(state.finds[fi].agentID, from: item, delta: 1)
        save()
    }

    /// You like it: the agent leans into its brand and traits, and keeps an eye on it if it isn't buyable yet.
    func like(_ findID: String) {
        guard let fi = state.finds.firstIndex(where: { $0.id == findID }), let item = Catalog.item(state.finds[fi].itemID) else { return }
        guard state.finds[fi].status != .liked else { return }
        state.finds[fi].status = .liked
        state.finds[fi].passReason = nil
        let watchIt = isSoldOut(item) || !isLive(item)
        if watchIt { state.finds[fi].watching = true }
        var patch: [String: Any] = ["status": "liked", "pass_reason": NSNull()]
        if watchIt { patch["watching"] = true }
        push { api in try await api.update("finds", "id=eq.\(findID)", patch) }
        log("You liked \(item.title)")
        learn(state.finds[fi].agentID, from: item, delta: 2)
        Analytics.track(.findLiked, ["category": item.category.rawValue, "score": state.finds[fi].score, "watching": watchIt])
        save()
    }

    func unlike(_ findID: String) {
        guard let fi = state.finds.firstIndex(where: { $0.id == findID }), state.finds[fi].status == .liked,
              let item = Catalog.item(state.finds[fi].itemID) else { return }
        state.finds[fi].status = .open
        push { api in try await api.update("finds", "id=eq.\(findID)", ["status": "open"]) }
        learn(state.finds[fi].agentID, from: item, delta: -2)
        Analytics.track(.findUnliked, ["category": item.category.rawValue])
        save()
    }

    enum PassReason: String, CaseIterable, Identifiable {
        case style = "Not my style", price = "Too pricey", own = "Have one like it", later = "Just not now"
        var id: String { rawValue }
    }

    func pass(_ findID: String, reason: PassReason) {
        guard let fi = state.finds.firstIndex(where: { $0.id == findID }), let item = Catalog.item(state.finds[fi].itemID) else { return }
        if state.finds[fi].status == .liked { learn(state.finds[fi].agentID, from: item, delta: -2) }
        state.finds[fi].status = .passed
        state.finds[fi].passReason = reason.rawValue.lowercased()
        let reasonText = reason.rawValue.lowercased()
        push { api in try await api.update("finds", "id=eq.\(findID)", ["status": "passed", "pass_reason": reasonText]) }
        let aid = state.finds[fi].agentID
        switch reason {
        case .style: learn(aid, from: item, delta: -2, note: "you're not into \(item.traits.prefix(2).joined(separator: ", "))")
        case .price:
            // Only a real price can set a price preference ("under $0" is nonsense).
            if item.priceKnown, item.price > 0, let i = agentIndex(aid) {
                let current = state.agents[i].priceNote > 0 ? state.agents[i].priceNote : .infinity
                state.agents[i].priceNote = (min(current, item.price * 0.85)).rounded()
                log("\(state.agents[i].name) noted you prefer things under \(Fmt.money(state.agents[i].priceNote))")
                pushAgent(aid)
            }
        case .own: log("\(agent(aid)?.name ?? "Agent") will skip near-duplicates of \(item.title)")
        case .later: break
        }
        save()
    }

    func undoPass(_ findID: String) {
        guard let fi = state.finds.firstIndex(where: { $0.id == findID }) else { return }
        state.finds[fi].status = .open
        state.finds[fi].passReason = nil
        push { api in try await api.update("finds", "id=eq.\(findID)", ["status": "open", "pass_reason": NSNull()]) }
        save()
    }

    /// Puts a listing in Finds for an agent (from Live, a friend, or chat).
    @discardableResult
    func ensureFind(agentID: String, itemID: String, why extra: String? = nil) -> Find? {
        if let f = state.finds.first(where: { $0.itemID == itemID }) { return f }
        guard let a = agent(agentID), let item = Catalog.item(itemID) else { return nil }
        let m = Matcher.match(a, item) ?? Match(score: 50, why: [])
        let why = Array(((extra.map { [$0] } ?? []) + m.why).prefix(6))
        let f = Find(id: UUID().uuidString.lowercased(), itemID: itemID, agentID: agentID, score: max(0, min(100, m.score)), why: why)
        state.finds.insert(f, at: 0)
        state.seenItemIDs.insert(itemID)
        let row: [String: Any] = ["id": f.id, "listing_id": itemID, "agent_id": agentID, "score": f.score, "why": why]
        push { api in try await api.insert("finds", row) }
        save()
        return f
    }

    func markRead(_ ids: [String]) {
        let set = Set(ids)
        var changed: [String] = []
        for i in state.notes.indices where set.contains(state.notes[i].id) && !state.notes[i].read {
            state.notes[i].read = true
            changed.append(state.notes[i].id)
        }
        guard !changed.isEmpty else { return }
        save()
        Notifier.setBadge(unreadCount)
        push { api in try await api.update("notes", "id=in.(\(changed.joined(separator: ",")))", ["read": true]) }
    }

    // MARK: - Squad

    /// Adds the agent. In the sample tour it sweeps at once; signed in, call `cloudDeploy` to save it and start the hunt.
    func deploy(_ a: Agent) {
        state.agents.append(a)
        log("\(a.name) deployed on \(a.mission.label)")
        if isCloud { save() } else { sweep(quiet: false) }
    }

    func retire(_ id: String) {
        guard let a = agent(id) else { return }
        state.agents.removeAll { $0.id == id }
        log("\(a.name) retired")
        push { api in try await api.delete("agents", "id=eq.\(id)") }
        save()
    }

    // MARK: - Taste photos

    static let maxTastePhotos = 6

    private static let photoDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("taste", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func photoURL(_ id: String) -> URL { Self.photoDir.appendingPathComponent("\(id).jpg") }

    func image(for photo: TastePhoto) -> UIImage? {
        _ = photoVersion   // redraw when a download lands
        if let img = UIImage(contentsOfFile: photoURL(photo.id).path) { return img }
        fetchPhotoIfNeeded(photo)
        return nil
    }

    func cacheTastePhoto(id: String, data: Data) {
        try? data.write(to: photoURL(id), options: [.atomic, .completeFileProtection])
    }

    /// Saves the photo on the phone (and your account, when signed in) and teaches the agent what you kept.
    func addTastePhoto(agentID: String, image: UIImage, tags: [String], makers: [String] = [], creators: [String] = [], summary: String) {
        guard let i = agentIndex(agentID), !(tags.isEmpty && makers.isEmpty && creators.isEmpty) else { return }
        let photo = TastePhoto(id: UUID().uuidString.lowercased(), tags: (tags.map { $0.lowercased() } + makers + creators).prefix(12).map { $0 }, summary: summary)
        let small = PhotoTaste.normalized(image, maxSide: 720)
        let jpeg = small.jpegData(compressionQuality: 0.8)
        if let jpeg { cacheTastePhoto(id: photo.id, data: jpeg) }
        for m in makers where !state.agents[i].style.makers.contains(where: { TextMatch.norm($0) == TextMatch.norm(m) }) {
            state.agents[i].style.makers.append(m)
        }
        for c in creators where !state.agents[i].style.creators.contains(where: { TextMatch.norm($0) == TextMatch.norm(c) }) {
            state.agents[i].style.creators.append(c)
        }
        state.agents[i].tasteBoard.insert(photo, at: 0)
        while state.agents[i].tasteBoard.count > Self.maxTastePhotos {
            let old = state.agents[i].tasteBoard.removeLast()
            try? FileManager.default.removeItem(at: photoURL(old.id))
        }
        for t in tags.map({ $0.lowercased() }) {
            if !state.agents[i].style.traits.contains(where: { TextMatch.norm($0) == TextMatch.norm(t) }) { state.agents[i].style.traits.append(t) }
            // what you choose to show is a strong signal
            state.agents[i].learned[TextMatch.norm(t)] = max(state.agents[i].learned[TextMatch.norm(t)] ?? 0, 1)
        }
        let a = state.agents[i]
        log("\(a.name) learned from your photo: \(photo.tags.prefix(4).joined(separator: ", "))")
        Analytics.track(.tastePhotoAdded, ["mission": a.mission.category?.rawValue ?? "custom", "tags": photo.tags.count,
                                            "boardSize": a.tasteBoard.count])
        if let n = notify(a, .learned, nil, extra: photo.tags.prefix(3).joined(separator: ", ")) { showBanner(n) }
        if let jpeg, isCloud { uploadTastePhoto(agentID: agentID, photo: photo, jpeg: jpeg) }
        save()
    }

    /// Removes a photo, and forgets tags that only came from it.
    func removeTastePhoto(agentID: String, photoID: String) {
        guard let i = agentIndex(agentID), let p = state.agents[i].tasteBoard.first(where: { $0.id == photoID }) else { return }
        state.agents[i].tasteBoard.removeAll { $0.id == photoID }
        try? FileManager.default.removeItem(at: photoURL(photoID))
        let still = Set(state.agents[i].tasteBoard.flatMap { $0.tags.map(TextMatch.norm) })
        let drop = Set(p.tags.map(TextMatch.norm)).subtracting(still)
        state.agents[i].style.traits.removeAll { drop.contains(TextMatch.norm($0)) }
        for k in drop where state.agents[i].learned[k] == 1 { state.agents[i].learned.removeValue(forKey: k) }
        log("\(state.agents[i].name) forgot a taste photo")
        save()
        deleteTastePhotoCloud(photo: p, agentID: agentID)
    }

    func update(_ a: Agent) {
        guard let i = agentIndex(a.id) else { return }
        state.agents[i] = a
        save()
        pushAgent(a.id)
    }

    func log(_ text: String) {
        // Same line twice in a row (for example two quick passes) is one event.
        if let last = state.log.first, last.text == text, Date.now.timeIntervalSince(last.date) < 600 { return }
        state.log.insert(LogLine(text: text), at: 0)
        if state.log.count > 60 { state.log.removeLast(state.log.count - 60) }
    }

    // MARK: - Live

    func stories() -> [Story] {
        Catalog.all.map { (item: Item) -> Story in
            let pct = item.price > 0 ? Int(safe: ((item.market / item.price - 1) * 100).rounded()) : 0
            let drop = dropDate(item).timeIntervalSinceNow / 60
            let kind: String, head: String
            if isSoldOut(item) { kind = "Restock watch"; head = "\(item.title) Sold Out Fast. Here's the Restock Play" }
            else if drop > 0 { kind = "Release"; head = "\(item.title) \(drop < 1440 ? "Drops Today" : drop < 2880 ? "Drops Tomorrow" : "Lands This Week") at \(item.source)" }
            else if pct >= 20 { kind = "Market"; head = "\(item.title) Is Trading \(pct)% Above Asking" }
            else if pct <= -3 { kind = "Price watch"; head = "The Market Is Cooling on the \(item.title)" }
            else { kind = "Available now"; head = "\(item.title) Is Available Now via \(item.source)" }
            let info = item.category.info
            var dek = item.creator.map { "\(info.creatorVerb) \($0). " } ?? ""
            dek += item.traits.prefix(3).joined(separator: ", ").capitalizedFirst + ". "
            dek += item.priceKnown ? "\(Fmt.money(item.price)) at \(item.source)" : "Price TBA at \(item.source)"
            if item.priceKnown && item.market != item.price { dek += ", \(Fmt.money(item.market)) on the market" }
            dek += "."
            let b = best(for: item)
            return Story(item: item, kind: kind, headline: head, dek: dek, minutesAgo: minutesAgo(item),
                         agentID: b?.agent.id, match: b?.match, isLive: isLive(item))
        }
    }

    private func minutesAgo(_ item: Item) -> Int {
        if let seen = item.firstSeen { return max(1, Int(Date.now.timeIntervalSince(seen) / 60)) }
        return item.id.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 997 } % 170 + 3   // sample stories: stable spread
    }

    func stories(for tab: LiveTab) -> [Story] {
        let all = stories()
        switch tab.kind {
        case .forYou: return all.filter(\.forYou).sorted { ($0.score, -$0.minutesAgo) > ($1.score, -$1.minutesAgo) }
        case .latest: return all.sorted { $0.minutesAgo < $1.minutesAgo }
        case .category(let c): return all.filter { $0.item.category == c }.sorted { $0.score > $1.score }
        case .custom(let q): return all.filter { TextMatch.matches($0.item, query: q) }.sorted { $0.score > $1.score }
        }
    }

    // MARK: - Friends

    func friend(_ id: String) -> Friend? { state.friends.first { $0.id == id } }

    func acceptSuggestion(_ id: String) {
        guard let si = state.suggestions.firstIndex(where: { $0.id == id }) else { return }
        let s = state.suggestions[si]
        state.suggestions[si].status = .sent
        push { api in try await api.update("suggestions", "id=eq.\(id)", ["status": "sent"]) }
        guard let item = Catalog.item(s.itemID), let f = friend(s.friendID) else { save(); return }
        let target = best(for: item)?.agent ?? state.agents.first { Matcher.covers($0, item) }
        let credit = "\(f.name) suggested it: “\(s.note)”"
        if let a = target, let find = ensureFind(agentID: a.id, itemID: item.id, why: credit), let fi = state.finds.firstIndex(where: { $0.id == find.id }) {
            state.finds[fi].why = [credit] + state.finds[fi].why.filter { !$0.contains("suggested it") }
            if state.finds[fi].status != .acquired { state.finds[fi].status = .open }
            learn(a.id, from: item, delta: 1, note: "your friend \(f.name) thinks you'd like \(item.title)")
        }
        log("You took \(f.name)'s suggestion: \(item.title)")
        save()
    }

    func passSuggestion(_ id: String) {
        guard let si = state.suggestions.firstIndex(where: { $0.id == id }) else { return }
        state.suggestions[si].status = .passed
        push { api in try await api.update("suggestions", "id=eq.\(id)", ["status": "passed"]) }
        save()
    }

    func share(itemID: String, to: [String], note: String, isSuggestion: Bool) {
        let sh = Share(itemID: itemID, to: to, note: note, isSuggestion: isSuggestion)
        state.shares.insert(sh, at: 0)
        let names = to.compactMap { friend($0)?.name }.joined(separator: ", ")
        log("You \(isSuggestion ? "suggested" : "shared") \(Catalog.item(itemID)?.title ?? "an item") with \(names)")
        save()
        if isCloud {
            push { api in
                try await api.rpcVoid("share_listing", ["p_listing": itemID, "p_to": to, "p_note": note, "p_is_suggestion": isSuggestion])
                await self.pull()
            }
            return
        }
        // Prototype: sample friends reply a few seconds later.
        for (k, fid) in to.enumerated() {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3.5 + Double(k) * 2.5))
                guard let f = self.friend(fid), let si = self.state.shares.firstIndex(where: { $0.id == sh.id }) else { return }
                let text = f.replies[(itemID.count + k) % max(1, f.replies.count)]
                self.state.shares[si].replies.append(ShareReply(friendID: fid, text: text, date: .now))
                let n = AppNote(friendID: fid, kind: .friend, body: text)
                self.state.notes.insert(n, at: 0)
                self.save()
                self.showBanner(n)
            }
        }
    }

    func addFriend(_ raw: String) -> String? {
        let h = raw.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return "Enter a handle like @maya or an email address." }
        let handle = (h.contains("@") && !h.hasPrefix("@")) ? h.lowercased() : (h.hasPrefix("@") ? h : "@" + h).lowercased()
        if state.friends.contains(where: { $0.handle.lowercased() == handle }) { return "You've already added them." }
        let base = handle.replacingOccurrences(of: "@", with: " ").split(whereSeparator: { " ._".contains($0) }).first.map(String.init) ?? "friend"
        let id = "u" + UUID().uuidString.prefix(6)
        state.friends.append(Friend(id: id, name: base.capitalized, handle: handle, hunts: [], likes: [], isPending: true,
                                    replies: ["Love that. Thanks for thinking of me.", "Ooh, good find.", "Adding it to my list."]))
        log("Friend invite sent to \(handle)")
        save()
        // Prototype: the invite is accepted a few seconds later.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard let i = self.state.friends.firstIndex(where: { $0.id == id }), self.state.friends[i].isPending else { return }
            self.state.friends[i].isPending = false
            self.state.friends[i].hunts = [.sneakers, .fragrance]
            self.state.friends[i].likes = ["suede", "rose"]
            let n = AppNote(friendID: id, kind: .friend, body: "\(self.state.friends[i].name) accepted your friend request. You can now swap suggestions.")
            self.state.notes.insert(n, at: 0)
            self.save()
            self.showBanner(n)
        }
        return nil
    }

    func removeFriend(_ id: String) {
        let fid = friend(id)?.friendshipID
        state.friends.removeAll { $0.id == id }
        save()
        if let fid { push { api in try await api.delete("friendships", "id=eq.\(fid)") } }
    }

    func friendPicks(_ f: Friend) -> [Item] {
        Catalog.all.map { item -> (Item, Int) in
            guard f.hunts.contains(item.category) else { return (item, 0) }
            return (item, 30 + item.traits.filter { t in f.likes.contains { TextMatch.loose($0, t) } }.count * 20)
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(6).map { $0.0 }
    }

    func sharedTaste(_ f: Friend) -> [String] {
        let mine = state.agents.flatMap(\.style.traits)
        return f.likes.filter { l in mine.contains { TextMatch.loose($0, l) } }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
