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

    /// A text from a scout wakes the app in the background for a moment: it syncs and prepares the photos,
    /// so the find is already there when the person opens Baget.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            await AppStore.shared.backgroundRefresh()
            completionHandler(.newData)
        }
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
                    if StoreShots.enabled { await StoreShots.run(store: store, router: router); return }
                    if PaywallView.screenshotMode { router.sheet = .pro; return }
                    #endif
                    // New accounts are asked during setup, when it means something ("text me when they find something").
                    if store.isCloud { await store.registerForPushIfAsked() } else { await Notifier.requestPermission() }
                    store.listenForProUpdates()
                    await store.syncProEntitlements()
                    await store.loadProProducts()
                    await store.loadPlan()
                    // While the app is open, keep everything fresh in the background, every 3 minutes.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(180))
                        if UIApplication.shared.applicationState == .active { await store.refreshQuietly() }
                    }
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
                store.saveNow()
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
    case pro
    case feedback

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
        case .pro: return "pro"
        case .feedback: return "feedback"
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
            say(story.agentID == nil ? "Set up a \(story.item.category.info.label.lowercased()) scout to track this" : "Not in your size, so it isn't in Finds")
            return
        }
        switch f.status {
        case .passed: store.undoPass(f.id)            // you went looking for it, so bring it back
        case .removed: store.restoreFind(f.id)
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
