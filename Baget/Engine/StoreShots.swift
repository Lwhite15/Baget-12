#if DEBUG
import Foundation

/// Debug builds only. Launched with -BagetStoreShots by the "Store screenshots" workflow on the large iPhone simulator:
/// signs into the screenshots account (credentials come from the workflow, never stored in the app), then shows each
/// screen and writes Documents/shot-<name>. The workflow takes the screenshot and answers with Documents/taken-<name>.
@MainActor
enum StoreShots {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-BagetStoreShots") }

    private static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private static func mark(_ name: String, _ text: String = "") { FileManager.default.createFile(atPath: docs.appendingPathComponent(name).path, contents: Data(text.utf8)) }
    private static func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: docs.appendingPathComponent(name).path) }

    static func run(store: AppStore, router: Router) async {
        Analytics.enabled = false
        UserDefaults.standard.set(true, forKey: "baget.onboarded")
        let env = ProcessInfo.processInfo.environment
        guard let email = env["BAGET_SHOT_EMAIL"], let password = env["BAGET_SHOT_PASSWORD"] else { mark("shots-error", "no credentials in the launch environment"); return }
        do {
            try await Backend.shared.signInWithEmail(email: email, password: password)
            // What didSignIn does, minus the notification permission prompt (nobody is there to tap it).
            guard let uid = Backend.shared.userID else { mark("shots-error", "signed in but no user id"); return }
            store.state = AppState()
            store.state.accountID = uid
            Catalog.cloud = [:]
            Catalog.useCloud = true
            store.save()
            mark("stage-signed-in")
        } catch { mark("shots-error", "sign-in: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))"); return }
        await store.pull()
        mark("stage-pulled")
        await store.loadPlan()
        await store.loadForYou()
        mark("stage-loaded")
        try? await Task.sleep(for: .seconds(3))

        await shot("1-today", router) { router.sheet = nil; router.tab = .live }
        await shot("2-finds", router) { router.sheet = nil; router.tab = .finds }
        await shot("3-swipe", router) { router.sheet = .swipe }
        await shot("4-texts", router) { router.sheet = .inbox }
        await shot("5-squad", router) { router.sheet = nil; router.tab = .squad }
        await shot("6-pro", router) { router.sheet = .pro }
        mark("shots-done")
    }

    /// Shows a screen, lets photos load, then waits (up to a minute) for the workflow to take the picture.
    private static func shot(_ name: String, _ router: Router, _ show: () -> Void) async {
        if router.sheet != nil { router.sheet = nil; try? await Task.sleep(for: .seconds(1.2)) }
        show()
        try? await Task.sleep(for: .seconds(6))
        mark("shot-\(name)")
        for _ in 0..<120 {
            if exists("taken-\(name)") { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
#endif
