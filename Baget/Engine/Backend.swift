import Foundation
import Security
import CryptoKit

/// Errors shown to people. Messages are written for the screen.
struct BackendError: LocalizedError {
    let message: String
    var status: Int = 0
    var errorDescription: String? { message }
    static let notSignedIn = BackendError(message: "Sign in to use this.")
    static let offline = BackendError(message: "You're offline. Check your connection and try again.")
}

/// A minimal Supabase client: Sign in with Apple, database (PostgREST), RPC, edge functions and storage.
/// No third-party packages. The session lives in the Keychain, never in plain files.
@MainActor
final class Backend {
    static let shared = Backend()

    struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var userID: String
    }

    let baseURL: URL?
    let apiKey: String
    private(set) var session: Session?
    private var refreshing: Task<Void, Error>?

    var isConfigured: Bool { baseURL != nil && !apiKey.isEmpty }
    var isSignedIn: Bool { session != nil }
    var userID: String? { session?.userID }

    private init() {
        let url = Bundle.main.object(forInfoDictionaryKey: "BagetSupabaseURL") as? String ?? ""
        apiKey = Bundle.main.object(forInfoDictionaryKey: "BagetSupabaseAnonKey") as? String ?? ""
        baseURL = url.hasPrefix("https://") ? URL(string: url) : nil
        session = Keychain.load()
    }

    // MARK: - Auth

    /// A random nonce. Apple gets its SHA-256; Supabase gets the original to check against it.
    nonisolated static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func signInWithApple(idToken: String, nonce: String) async throws {
        let data = try await raw("POST", "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "id_token")],
                                 json: ["provider": "apple", "id_token": idToken, "nonce": nonce], authorized: false)
        try store(sessionFrom: data)
    }

    func signOut() async {
        if session != nil { _ = try? await raw("POST", "/auth/v1/logout", json: [:]) }
        session = nil
        Keychain.clear()
    }

    func forgetSession() {
        session = nil
        Keychain.clear()
    }

    private func store(sessionFrom data: Data) throws {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String, let refresh = obj["refresh_token"] as? String,
              let user = obj["user"] as? [String: Any], let uid = user["id"] as? String else {
            throw BackendError(message: "Sign-in didn't complete. Try again.")
        }
        let expiresIn = (obj["expires_in"] as? Double) ?? 3600
        let s = Session(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expiresIn - 60), userID: uid)
        session = s
        Keychain.save(s)
    }

    private func refreshIfNeeded() async throws {
        guard let s = session else { throw BackendError.notSignedIn }
        guard s.expiresAt < Date() else { return }
        if let refreshing { return try await refreshing.value }
        let task = Task { @MainActor in
            defer { self.refreshing = nil }
            do {
                let data = try await self.raw("POST", "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                              json: ["refresh_token": s.refreshToken], authorized: false)
                try self.store(sessionFrom: data)
            } catch let e as BackendError where e.status == 400 || e.status == 401 {
                self.forgetSession()
                throw BackendError(message: "Your session expired. Sign in again.", status: 401)
            }
        }
        refreshing = task
        try await task.value
    }

    // MARK: - Requests

    @discardableResult
    func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil, body: Data? = nil,
             contentType: String? = nil, prefer: String? = nil, authorized: Bool = true) async throws -> Data {
        guard let baseURL else { throw BackendError(message: "Baget isn't connected to a server yet.") }
        if authorized { try await refreshIfNeeded() }
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.percentEncodedQuery = query.map { "\($0.name)=\(($0.value ?? "").addingPercentEncoding(withAllowedCharacters: .pgrst) ?? "")" }.joined(separator: "&") }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = path.hasPrefix("/functions/") ? 120 : 30
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        if authorized, let token = session?.accessToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            req.httpBody = body
            req.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let result: (Data, URLResponse)
        do { result = try await URLSession.shared.data(for: req) } catch { throw BackendError.offline }
        let (data, resp) = result
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401, authorized { forgetSession() }
            throw BackendError(message: Self.message(from: data, status: status), status: status)
        }
        return data
    }

    private static func message(from data: Data, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error", "message", "msg", "error_description"] {
                if let m = obj[key] as? String, !m.isEmpty, !m.contains("violates"), m.count < 200 { return m }
            }
        }
        switch status {
        case 401: return "Your session expired. Sign in again."
        case 409: return "That's already taken."
        case 429, 503: return "Busy right now. Try again in a minute."
        default: return "Something went wrong (\(status)). Try again."
        }
    }

    func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = Self.parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }

    /// Postgres timestamps: "2026-10-07T15:00:00.123456+00:00" (any number of fraction digits, or none).
    nonisolated static func parseDate(_ s: String) -> Date? {
        var t = s.replacingOccurrences(of: " ", with: "T")
        if let dot = t.firstIndex(of: ".") {
            let afterDot = t[t.index(after: dot)...]
            let digits = afterDot.prefix { $0.isNumber }
            t.replaceSubrange(dot..<t.index(dot, offsetBy: digits.count + 1), with: digits.isEmpty ? "" : "." + digits.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        if t.hasSuffix("+00") { t += ":00" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: t) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: t)
    }

    func select<T: Decodable>(_ table: String, _ query: String) async throws -> [T] {
        let data = try await raw("GET", "/rest/v1/\(table)", query: Self.items(query))
        return try decoder().decode([T].self, from: data)
    }

    func insert(_ table: String, _ rows: Any) async throws {
        try await raw("POST", "/rest/v1/\(table)", json: rows, prefer: "return=minimal")
    }

    func update(_ table: String, _ filter: String, _ patch: [String: Any]) async throws {
        try await raw("PATCH", "/rest/v1/\(table)", query: Self.items(filter), json: patch, prefer: "return=minimal")
    }

    func delete(_ table: String, _ filter: String) async throws {
        try await raw("DELETE", "/rest/v1/\(table)", query: Self.items(filter), prefer: "return=minimal")
    }

    func rpc<T: Decodable>(_ fn: String, _ args: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
        let data = try await raw("POST", "/rest/v1/rpc/\(fn)", json: args)
        return try decoder().decode(T.self, from: data.isEmpty ? Data("null".utf8) : data)
    }

    func rpcVoid(_ fn: String, _ args: [String: Any] = [:]) async throws {
        try await raw("POST", "/rest/v1/rpc/\(fn)", json: args)
    }

    func function<T: Decodable>(_ name: String, _ body: [String: Any], as type: T.Type = T.self) async throws -> T {
        let data = try await raw("POST", "/functions/v1/\(name)", json: body)
        return try decoder().decode(T.self, from: data)
    }

    func upload(bucket: String, path: String, jpeg: Data) async throws {
        try await raw("POST", "/storage/v1/object/\(bucket)/\(path)", body: jpeg, contentType: "image/jpeg")
    }

    func download(bucket: String, path: String) async throws -> Data {
        try await raw("GET", "/storage/v1/object/authenticated/\(bucket)/\(path)")
    }

    func removeFile(bucket: String, path: String) async throws {
        try await raw("DELETE", "/storage/v1/object/\(bucket)", json: ["prefixes": [path]])
    }

    /// "select=*&user_id=eq.x" -> query items, keeping PostgREST's syntax intact.
    private static func items(_ q: String) -> [URLQueryItem] {
        q.split(separator: "&").map { part in
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            return URLQueryItem(name: kv[0], value: kv.count > 1 ? kv[1] : "")
        }
    }
}

extension CharacterSet {
    /// Characters PostgREST filters use that must stay literal in a query value.
    static let pgrst: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~*,():!\"")
        return s
    }()
}

/// Stores the session in the Keychain, only readable on this device after first unlock.
enum Keychain {
    private static let service = "app.baget.session"

    static func save(_ s: Backend.Session) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        clear()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, kSecValueData as String: data]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load() -> Backend.Session? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Backend.Session.self, from: data)
    }

    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
