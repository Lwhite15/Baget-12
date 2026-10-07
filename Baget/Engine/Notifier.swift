import Foundation
import UserNotifications
import BackgroundTasks

/// Real iOS notifications and background refresh.
enum Notifier {
    static let refreshTaskID = "app.baget.sweep"

    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Delivers a friend-style text right away (used by background sweeps).
    static func post(_ note: AppNote, title: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = note.body
        content.sound = .default
        content.userInfo = ["noteID": note.id]
        let req = UNNotificationRequest(identifier: note.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Quiet hours: holds a non-urgent text until 8am.
    static func postAtMorning(_ note: AppNote, title: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = note.body
        content.sound = .default
        content.userInfo = ["noteID": note.id]
        var at = DateComponents()
        at.hour = 8
        at.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: at, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: note.id, content: content, trigger: trigger))
    }

    /// Asks iOS to wake the app for a sweep. iOS decides the exact time, based on how you use the app.
    static func scheduleRefresh(everyMinutes: Int) {
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(max(15, everyMinutes) * 60))
        try? BGTaskScheduler.shared.submit(req)
    }

    static func setBadge(_ n: Int) {
        UNUserNotificationCenter.current().setBadgeCount(n)
    }
}

/// Shows notifications as banners even while the app is open, and handles taps.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
        // A push from the server means there's something new: refresh while it's on screen.
        if notification.request.trigger is UNPushNotificationTrigger {
            Task { @MainActor in await AppStore.shared.pull() }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["noteID"] as? String
        Task { @MainActor in
            if let id { AppStore.shared.openNoteFromSystem = id }
            completionHandler()
        }
    }
}
