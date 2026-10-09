import SwiftUI
import UserNotifications

/// Receives the push-notification token from iOS and hands it to the server.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await AppStore.shared.registerDevice(token: hex) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in AppStore.shared.pushRegistered = false }
    }
}

@main
struct BagetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore.shared
    @State private var router = Router()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(router)
                .preferredColorScheme(.dark)
                .task {
                    #if DEBUG
                    if SmokeTest.enabled { await SmokeTest.run(store: store, router: router); return }
                    #endif
                    if store.isCloud { await store.registerForPush() } else { await Notifier.requestPermission() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Pick up what the squad found while the app was closed.
                let gone = Date.now.timeIntervalSince(store.state.lastSeen) / 60
                Task { @MainActor in
                    await store.cameBack(afterMinutes: gone)
                    store.state.lastSeen = .now
                    store.save()
                }
                Analytics.track(.appOpened, ["minutesAway": Int(gone), "signedIn": store.isCloud])
                Analytics.flush()
            case .background:
                store.state.lastSeen = .now
                store.save()
                Notifier.setBadge(store.unreadCount)
                Notifier.scheduleRefresh(everyMinutes: store.state.settings.sweepMinutes)
                Analytics.flush()
            default:
                break
            }
        }
        // iOS wakes the app here for a background sweep; finds arrive as real notifications.
        .backgroundTask(.appRefresh(Notifier.refreshTaskID)) {
            await AppStore.shared.backgroundRefresh()
            let minutes = await MainActor.run { AppStore.shared.state.settings.sweepMinutes }
            Notifier.scheduleRefresh(everyMinutes: minutes)
            await Analytics.flushNow()
        }
    }
}

/// Which sheet is open. One place, so any screen can open any sheet.
enum ActiveSheet: Identifiable, Hashable {
    case inbox, deploy, customizeBar, profile
    case checkout(String)
    case share(itemID: String, friendID: String?, suggestion: Bool)
    case suggestFor(String)
    case tastePhoto(String)
    case chat(String)
    case agentIcon(String)
    case swipe, taste
    case ask(String)

    var id: String {
        switch self {
        case .inbox: return "inbox"
        case .deploy: return "deploy"
        case .customizeBar: return "customize"
        case .profile: return "profile"
        case .checkout(let f): return "checkout-\(f)"
        case .share(let i, let f, let s): return "share-\(i)-\(f ?? "")-\(s)"
        case .suggestFor(let f): return "suggest-\(f)"
        case .tastePhoto(let a): return "photo-\(a)"
        case .chat(let a): return "chat-\(a)"
        case .agentIcon(let a): return "icon-\(a)"
        case .swipe: return "swipe"
        case .taste: return "taste"
        case .ask(let f): return "ask-\(f)"
        }
    }
}

enum AppTab: Hashable { case live, finds, squad, friends }

@Observable
final class Router {
    var tab: AppTab = .live
    var sheet: ActiveSheet?
    var deployPrefill: Mission?
    var toast: String?
    /// Set when Buy opens a store; when you come back, Baget asks whether you bought it.
    var buyOpened: String?
    var askBought: String?
    /// A find to scroll to and highlight on the Finds tab (from tapping an item on Live).
    var focusFind: String?

    /// Opens an item in Finds. If it isn't there yet, its agent adds it first.
    @MainActor func openInFinds(_ story: Story, store: AppStore) {
        var find = store.state.finds.first { $0.itemID == story.item.id }
        if find == nil, let aid = story.agentID, !(story.match?.notInSize ?? false) {
            find = store.ensureFind(agentID: aid, itemID: story.item.id)
            if find != nil { Analytics.track(.storySentToAgent, ["category": story.item.category.rawValue, "from": "tap"]) }
        }
        guard let f = find else {
            say(story.agentID == nil ? "Deploy a \(story.item.category.info.label.lowercased()) agent to track this" : "Not in your size, so it isn't in Finds")
            return
        }
        switch f.status {
        case .passed: store.undoPass(f.id)            // you went looking for it, so bring it back
        case .acquired: say("You bought this one"); return
        default: break
        }
        focusFind = f.id
        tab = .finds
    }

    @MainActor func say(_ text: String) {
        withAnimation { toast = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.6))
            if self.toast == text { withAnimation { self.toast = nil } }
        }
    }
}
