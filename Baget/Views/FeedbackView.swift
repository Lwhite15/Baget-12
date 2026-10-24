import SwiftUI
import PhotosUI
import UIKit

/// Testers tell you what's broken, what they want, or what they love. Shake the phone anywhere to open it with a
/// screenshot of what was on screen. Goes straight to the owner as a text, and to the Stats screen.
struct FeedbackView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "bug"
    @State private var text = ""
    @State private var photo: UIImage? = FeedbackCapture.pending
    @State private var pick: PhotosPickerItem?
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $kind) {
                    Text("🐞 Bug").tag("bug")
                    Text("💡 Idea").tag("idea")
                    Text("❤️ Love it").tag("love")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                Section {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(4...10)
                        .focused($focused)
                } footer: {
                    Text("Sends with \(FeedbackCapture.version) · \(FeedbackCapture.device) · iOS \(UIDevice.current.systemVersion)")
                }
                Section("Screenshot") {
                    if let photo {
                        HStack {
                            Image(uiImage: photo).resizable().scaledToFit().frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 10))
                            Spacer()
                            Button("Remove", role: .destructive) { self.photo = nil }
                        }
                    }
                    PhotosPicker(selection: $pick, matching: .screenshots) {
                        Label(photo == nil ? String(localized: "Add a screenshot") : String(localized: "Use a different one"), systemImage: "photo")
                    }
                }
                if let error { Text(error).foregroundStyle(Theme.hot).font(.footnote) }
                Section {
                    Button { Task { await send() } } label: {
                        HStack { Spacer(); if sending { ProgressView() } else { Text("Send").bold() }; Spacer() }
                    }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { FeedbackCapture.pending = nil; focused = true }
            .onChange(of: pick) { _, item in
                Task { @MainActor in
                    if let d = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: d) { photo = img }
                }
            }
        }
    }

    private var placeholder: String {
        switch kind {
        case "bug": return String(localized: "What happened, and what did you expect?")
        case "idea": return String(localized: "What would make Baget better for you?")
        default: return String(localized: "What do you love about it?")
        }
    }

    @MainActor private func send() async {
        guard store.isCloud, let uid = store.api.userID else { error = "Sign in to send feedback."; return }
        sending = true
        defer { sending = false }
        var row: [String: Any] = [
            "kind": kind, "body": String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)),
            "app_version": FeedbackCapture.version, "device": FeedbackCapture.device, "screen": "\(router.tab)",
        ]
        do {
            if let photo, let jpg = PhotoTaste.normalized(photo, maxSide: 1600).jpegData(compressionQuality: 0.7) {
                let path = "\(uid.lowercased())/\(UUID().uuidString.lowercased()).jpg"
                try await store.api.upload(bucket: "feedback", path: path, jpeg: jpg)
                row["photo_path"] = path
            }
            try await store.api.insert("feedback", row)
            Analytics.track(.profileOpened, ["feedback": kind])
            router.say(String(localized: "Thanks! Sent straight to the Baget team."))
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn't send. Try again.")
        }
    }
}

/// Shake to send feedback, with a screenshot of what was on screen.
enum FeedbackCapture {
    static var pending: UIImage?
    static let shake = Notification.Name("BagetDeviceShaken")

    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Baget \(v) (\(b))"
    }

    static var device: String {
        var sys = utsname()
        uname(&sys)
        let id = withUnsafeBytes(of: &sys.machine) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return id.isEmpty ? UIDevice.current.model : id
    }

    @MainActor static func snapshot() -> UIImage? {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { return nil }
        let r = UIGraphicsImageRenderer(bounds: window.bounds)
        return r.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
    }
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake { NotificationCenter.default.post(name: FeedbackCapture.shake, object: nil) }
    }
}

/// Owner only: what testers sent, newest first, with screenshots. Tap Done to clear one.
struct FeedbackInbox: View {
    @Environment(AppStore.self) private var store
    @State private var items: [Item] = []
    @State private var photos: [String: UIImage] = [:]

    struct Item: Decodable, Identifiable {
        let id: String
        let kind: String
        let body: String
        let who: String
        let appVersion: String
        let device: String
        let screen: String
        let photoPath: String?
        let status: String
        let createdAt: Date
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tester feedback").font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(items.filter { $0.status != "done" }.count) open").font(.caption).foregroundStyle(Theme.muted)
            }
            if items.isEmpty {
                Text("Nothing yet. Testers can shake their phone or use Settings → Send feedback.").font(.caption).foregroundStyle(Theme.muted)
            }
            ForEach(items.prefix(30)) { f in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(f.kind == "bug" ? "🐞" : f.kind == "idea" ? "💡" : f.kind == "love" ? "❤️" : "💬")
                        Text(f.who).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        Text(Fmt.ago(f.createdAt)).font(.caption2).foregroundStyle(Theme.muted)
                        Spacer()
                        if f.status == "done" {
                            Text("Done").font(.caption2.weight(.bold)).foregroundStyle(Theme.green)
                        } else {
                            Button("Done") { mark(f.id) }.font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                    Text(f.body).font(.footnote).foregroundStyle(Theme.ink)
                    if let img = photos[f.id] {
                        Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Text([f.appVersion, f.device, f.screen.isEmpty ? nil : "on \(f.screen)"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(Theme.muted)
                }
                .padding(10)
                .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12))
                .opacity(f.status == "done" ? 0.55 : 1)
            }
        }
        .glassCard()
        .task { await load() }
    }

    @MainActor private func load() async {
        items = (try? await store.api.rpc("admin_feedback", ["p_limit": 50])) ?? []
        for f in items.prefix(30) where photos[f.id] == nil {
            if let p = f.photoPath, let d = try? await store.api.download(bucket: "feedback", path: p), let img = UIImage(data: d) { photos[f.id] = img }
        }
    }

    private func mark(_ id: String) {
        Task { @MainActor in
            try? await store.api.rpcVoid("admin_mark_feedback", ["p_id": id, "p_status": "done"])
            await load()
        }
    }
}
