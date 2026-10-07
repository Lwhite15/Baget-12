import Foundation

/// Product events. Names match the backend's metric views (see backend/schema.sql).
enum AnalyticsEvent: String {
    // engagement
    case appOpened = "app_opened"
    case liveSectionViewed = "live_section_viewed"
    case customSectionAdded = "custom_section_added"
    case spendingViewed = "spending_viewed"
    case backgroundSimulated = "background_simulated"
    // agents
    case agentDeployed = "agent_deployed"
    case agentRetired = "agent_retired"
    case agentSettingChanged = "agent_setting_changed"
    case agentLearned = "agent_learned"
    case tastePhotoAdded = "taste_photo_added"
    case signedIn = "signed_in"
    case chatSent = "chat_sent"
    case sweepRun = "sweep_run"
    // finds funnel
    case findCreated = "find_created"
    case storySentToAgent = "story_sent_to_agent"
    case checkoutOpened = "checkout_opened"
    case purchaseConfirmed = "purchase_confirmed"
    case autoPurchased = "auto_purchased"
    case findWatched = "find_watched"
    case findPassed = "find_passed"
    // notifications
    case notificationSent = "notification_sent"
    case notificationOpened = "notification_opened"
    // friends
    case friendInvited = "friend_invited"
    case itemShared = "item_shared"
    case suggestionSent = "suggestion_sent"
    case suggestionAccepted = "suggestion_accepted"
    case suggestionPassed = "suggestion_passed"
}

/// Batches events on the device and sends them to the backend.
/// - Identity: a random install ID. No name, email, handle or device identifier is ever sent.
/// - Delivery: events queue on disk (survive restarts and offline use) and go out in batches of 100.
/// - Backend: Supabase REST insert into `events`. The app can write events but cannot read any back.
/// - Opt-out: `Analytics.enabled = false` stops collection and clears the queue.
enum Analytics {
    private static let lock = NSLock()
    private static var buffer: [[String: Any]] = load()
    private static let sessionID = UUID().uuidString
    private static let maxQueued = 2000

    static let installID: String = {
        if let id = UserDefaults.standard.string(forKey: "baget.installID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "baget.installID")
        return id
    }()

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "baget.analyticsEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "baget.analyticsEnabled")
            if !newValue { lock.lock(); buffer.removeAll(); persistLocked(); lock.unlock() }
        }
    }

    private struct Config { let base: URL; let key: String }
    private static let config: Config? = {
        guard let url = Bundle.main.object(forInfoDictionaryKey: "BagetSupabaseURL") as? String,
              let key = Bundle.main.object(forInfoDictionaryKey: "BagetSupabaseAnonKey") as? String,
              url.hasPrefix("https://"), !key.isEmpty, let base = URL(string: url) else { return nil }
        return Config(base: base, key: key)
    }()

    private static let version: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }()

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("baget-analytics-queue.json")
    }()

    static func track(_ event: AnalyticsEvent, _ props: [String: Any] = [:]) {
        guard enabled else { return }
        let clean = props.filter { JSONSerialization.isValidJSONObject(["v": $0.value]) }
        let row: [String: Any] = [
            "id": UUID().uuidString,
            "install_id": installID,
            "session_id": sessionID,
            "name": event.rawValue,
            "occurred_at": ISO8601DateFormatter().string(from: Date()),
            "app_version": version,
            "props": clean,
        ]
        lock.lock()
        buffer.append(row)
        if buffer.count > maxQueued { buffer.removeFirst(buffer.count - maxQueued) }
        persistLocked()
        lock.unlock()
    }

    static func flush() {
        Task.detached(priority: .utility) { await flushNow() }
    }

    /// Sends queued events. Safe to call often; does nothing without a configured backend.
    static func flushNow() async {
        guard enabled, let config else { return }
        dropStale()
        for _ in 0..<20 {   // at most 2,000 events per flush
            lock.lock()
            let batch = Array(buffer.prefix(100))
            lock.unlock()
            guard !batch.isEmpty, let body = try? JSONSerialization.data(withJSONObject: batch) else { return }

            var req = URLRequest(url: config.base.appendingPathComponent("rest/v1/events"))
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(config.key, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
            // Duplicate IDs (a retried batch) are ignored instead of failing the whole batch.
            req.setValue("return=minimal,resolution=ignore-duplicates", forHTTPHeaderField: "Prefer")
            req.httpBody = body

            guard let result = try? await URLSession.shared.data(for: req),
                  let http = result.1 as? HTTPURLResponse else { return }   // offline: keep the queue, try later
            let ok = (200..<300).contains(http.statusCode)
            // A batch the server rejects (4xx other than auth or rate limit) would fail forever; drop it.
            let poison = (400..<500).contains(http.statusCode) && http.statusCode != 401 && http.statusCode != 429
            guard ok || poison else { return }

            let sent = Set(batch.compactMap { $0["id"] as? String })
            lock.lock()
            buffer.removeAll { sent.contains($0["id"] as? String ?? "") }
            persistLocked()
            lock.unlock()
        }
    }

    static var configured: Bool { config != nil }
    static var queuedCount: Int { lock.lock(); defer { lock.unlock() }; return buffer.count }

    /// The backend only accepts events from the last 30 days.
    private static func dropStale() {
        let cutoff = Date().addingTimeInterval(-29 * 24 * 3600)
        let f = ISO8601DateFormatter()
        lock.lock()
        buffer.removeAll { row in
            guard let s = row["occurred_at"] as? String, let d = f.date(from: s) else { return true }
            return d < cutoff
        }
        persistLocked()
        lock.unlock()
    }

    private static func load() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: fileURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr
    }

    private static func persistLocked() {
        if let data = try? JSONSerialization.data(withJSONObject: buffer) {
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
