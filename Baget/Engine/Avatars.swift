import SwiftUI
import UIKit

/// Your icon: kept on this phone, and in your account so it follows you to a new phone.
extension AppStore {
    private static let avatarDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("avatar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func avatarURL(_ id: String) -> URL { Self.avatarDir.appendingPathComponent("\(id).jpg") }
    private func avatarPath(_ id: String, uid: String) -> String { "\(uid)/avatars/\(id).jpg" }

    /// Initials for the icon: from your name, else your handle, else "B".
    var initials: String {
        let name = state.profile?.displayName.trimmingCharacters(in: .whitespaces) ?? ""
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        if words.count >= 2 { return (String(words[0].prefix(1)) + String(words[words.count - 1].prefix(1))).uppercased() }
        if let w = words.first { return String(w.prefix(2)).uppercased() }
        if let h = state.profile?.handle, !h.isEmpty { return String(h.prefix(2)).uppercased() }
        return "B"
    }

    var avatarImage: UIImage? {
        guard state.avatar.style == .photo else { return nil }
        return iconImage(state.avatar.photoID)
    }

    // MARK: Icon photos (yours and your agents')

    /// A cached icon photo, downloaded from your account the first time this phone needs it.
    func iconImage(_ photoID: String?) -> UIImage? {
        _ = avatarVersion
        guard let id = photoID else { return nil }
        if let img = UIImage(contentsOfFile: avatarURL(id).path) { return img }
        fetchAvatarIfNeeded(id)
        return nil
    }

    /// Crops to a square and keeps a small copy on this phone. Returns its id and bytes for uploading.
    func storeIconPhoto(_ image: UIImage) -> (id: String, jpeg: Data)? {
        let square = Self.squareCrop(PhotoTaste.normalized(image, maxSide: 1024))
        guard let jpeg = PhotoTaste.normalized(square, maxSide: 512).jpegData(compressionQuality: 0.82) else { return nil }
        let id = UUID().uuidString.lowercased()
        try? jpeg.write(to: avatarURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        avatarVersion += 1
        return (id, jpeg)
    }

    /// Uploads an icon photo, then runs `then` (so other devices only hear about photos that exist).
    func uploadIconPhoto(id: String, jpeg: Data, replacing old: String? = nil, then: (@MainActor (Backend) async throws -> Void)? = nil) {
        guard isCloud, let uid = api.userID else { return }
        let path = avatarPath(id, uid: uid)
        let oldPath = old.map { avatarPath($0, uid: uid) }
        push { api in
            try await api.upload(bucket: "taste-photos", path: path, jpeg: jpeg)
            if let then { try await then(api) }
            if let oldPath { try? await api.removeFile(bucket: "taste-photos", path: oldPath) }
        }
    }

    func deleteIconPhoto(_ id: String?) {
        guard let id else { return }
        try? FileManager.default.removeItem(at: avatarURL(id))
        avatarVersion += 1
        if isCloud, let uid = api.userID {
            let path = avatarPath(id, uid: uid)
            push { api in try? await api.removeFile(bucket: "taste-photos", path: path) }
        }
    }

    // MARK: Your icon

    func setAvatarStyle(_ style: Avatar.Style) {
        guard state.avatar.style != style else { return }
        state.avatar.style = style
        save()
    }

    func setAvatarEmoji(_ emoji: String) {
        state.avatar.emoji = emoji
        state.avatar.style = .emoji
        save()
    }

    func setAvatarColor(_ index: Int) {
        state.avatar.color = index
        if state.avatar.style == .photo { state.avatar.style = .initials }
        save()
    }

    func setAvatarPhoto(_ image: UIImage) {
        guard let (id, jpeg) = storeIconPhoto(image) else { return }
        let old = state.avatar.photoID
        if let old { try? FileManager.default.removeItem(at: avatarURL(old)) }
        state.avatar.photoID = id
        state.avatar.style = .photo
        if isCloud {
            // Shown here right away; the settings sync (which tells other devices) waits for the upload.
            uploadIconPhoto(id: id, jpeg: jpeg, replacing: old) { _ in self.save() }
        } else {
            save()
        }
        Analytics.track(.avatarChanged, ["style": "photo", "who": "you"])
    }

    func removeAvatarPhoto() {
        guard let id = state.avatar.photoID else { return }
        state.avatar.photoID = nil
        state.avatar.style = .initials
        save()
        deleteIconPhoto(id)
    }

    // MARK: Agent icons

    /// Sets an agent's icon. A new photo is kept on the phone, uploaded, then saved to the agent.
    func setAgentIcon(_ agentID: String, icon: Avatar?, photo: UIImage?) {
        guard let i = agentIndex(agentID) else { return }
        let oldPhoto = state.agents[i].icon?.photoID
        var icon = icon
        var upload: (id: String, jpeg: Data)?
        if let photo, let stored = storeIconPhoto(photo) {
            upload = stored
            var a = icon ?? Avatar()
            a.style = .photo
            a.photoID = stored.id
            icon = a
        }
        if icon?.style != .photo { icon?.photoID = nil }
        state.agents[i].icon = icon
        save()
        let keepsOld = icon?.photoID == oldPhoto
        if !keepsOld, let oldPhoto, upload == nil { deleteIconPhoto(oldPhoto) }
        let field = ["icon": Self.iconJSON(icon)]
        if let upload {
            uploadIconPhoto(id: upload.id, jpeg: upload.jpeg, replacing: keepsOld ? nil : oldPhoto) { api in
                try await api.update("agents", "id=eq.\(agentID)", field)
            }
            if !isCloud, let oldPhoto, !keepsOld { try? FileManager.default.removeItem(at: avatarURL(oldPhoto)) }
        } else {
            push { api in try await api.update("agents", "id=eq.\(agentID)", field) }
        }
        Analytics.track(.avatarChanged, ["style": icon?.style.rawValue ?? "default", "who": "agent"])
    }

    /// Two letters for an agent: "Grail Hunter" -> "GH".
    static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        if words.count >= 2 { return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased() }
        return String(words.first?.prefix(2) ?? "A").uppercased()
    }

    private func fetchAvatarIfNeeded(_ id: String) {
        guard isCloud, let uid = api.userID, !downloading.contains("avatar-\(id)") else { return }
        downloading.insert("avatar-\(id)")
        let path = avatarPath(id, uid: uid)
        Task { @MainActor in
            defer { self.downloading.remove("avatar-\(id)") }
            if let data = try? await self.api.download(bucket: "taste-photos", path: path) {
                try? data.write(to: self.avatarURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                self.avatarVersion += 1
            }
        }
    }

    func updateDisplayName(_ raw: String) async -> String? {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        if !isCloud {
            state.profile = Profile(handle: state.profile?.handle ?? "", displayName: name)
            save()
            return nil
        }
        guard let uid = api.userID else { return BackendError.notSignedIn.message }
        do {
            try await api.update("profiles", "id=eq.\(uid)", ["display_name": name])
            state.profile?.displayName = name
            save()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Couldn't save your name. Try again."
        }
    }

    private static func squareCrop(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        let origin = CGPoint(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(at: CGPoint(x: -origin.x, y: -origin.y))
        }
    }
}

/// Tile colors for initials and emoji icons.
enum AvatarPalette {
    static let all: [LinearGradient] = [
        Theme.gradient,
        LinearGradient(colors: [Color(red: 0.23, green: 0.51, blue: 1.0), Color(red: 0.55, green: 0.36, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(red: 1.0, green: 0.36, blue: 0.49), Color(red: 1.0, green: 0.62, blue: 0.30)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(red: 1.0, green: 0.78, blue: 0.34), Color(red: 0.98, green: 0.52, blue: 0.20)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(red: 0.20, green: 0.90, blue: 0.65), Color(red: 0.05, green: 0.55, blue: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(red: 0.86, green: 0.40, blue: 0.95), Color(red: 0.45, green: 0.25, blue: 0.85)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(red: 0.40, green: 0.45, blue: 0.55), Color(red: 0.16, green: 0.19, blue: 0.26)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(red: 0.96, green: 0.96, blue: 0.98), Color(red: 0.72, green: 0.78, blue: 0.86)], startPoint: .topLeading, endPoint: .bottomTrailing),
    ]
    /// Dark text on the light tiles, white on the rest.
    static func ink(_ i: Int) -> Color { [0, 3, 4, 7].contains(i) ? Theme.accentInk : .white }
    static func gradient(_ i: Int) -> LinearGradient { all[(i % all.count + all.count) % all.count] }
}
