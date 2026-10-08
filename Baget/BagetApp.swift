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
    case inbox, spending, deploy, customizeBar, profile
    case checkout(String)
    case share(itemID: String, friendID: String?, suggestion: Bool)
    case suggestFor(String)
    case tastePhoto(String)
    case chat(String)

    var id: String {
        switch self {
        case .inbox: return "inbox"
        case .spending: return "spending"
        case .deploy: return "deploy"
        case .customizeBar: return "customize"
        case .profile: return "profile"
        case .checkout(let f): return "checkout-\(f)"
        case .share(let i, let f, let s): return "share-\(i)-\(f ?? "")-\(s)"
        case .suggestFor(let f): return "suggest-\(f)"
        case .tastePhoto(let a): return "photo-\(a)"
        case .chat(let a): return "chat-\(a)"
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

    @MainActor func say(_ text: String) {
        withAnimation { toast = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.6))
            if self.toast == text { withAnimation { self.toast = nil } }
        }
    }
}
