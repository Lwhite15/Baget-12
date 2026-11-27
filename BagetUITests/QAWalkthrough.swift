import XCTest

/// A new customer's first session, end to end, on the real backend. Run by the "QA walkthrough" workflow only.
/// Creates a brand-new email account, goes through setup, waits for the first hunt, then tours every screen.
/// Each step saves a screenshot and the screen's accessibility tree, and never stops the run if something is missing:
/// a missing button is itself a finding, logged in steps.txt.
final class QAWalkthrough: XCTestCase {
    private var app: XCUIApplication!
    private var out: URL!
    private var n = 0
    private var log = ""

    override func setUp() {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        out = URL(fileURLWithPath: env["QA_OUT"] ?? NSTemporaryDirectory()).appendingPathComponent("qa")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        app = XCUIApplication()
    }

    // MARK: helpers

    private func note(_ s: String) {
        let line = "[\(String(format: "%02d", n))] \(s)"
        log += line + "\n"
        print("QA: " + line)
        try? log.write(to: out.appendingPathComponent("steps.txt"), atomically: true, encoding: .utf8)
    }

    private func snap(_ name: String, wait: Double = 2) {
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        n += 1
        let base = String(format: "%02d-%@", n, name)
        let shot = XCUIScreen.main.screenshot()
        try? shot.pngRepresentation.write(to: out.appendingPathComponent(base + ".png"))
        let a = XCTAttachment(screenshot: shot); a.name = base; a.lifetime = .keepAlways; add(a)
        try? app.debugDescription.write(to: out.appendingPathComponent(base + ".txt"), atomically: true, encoding: .utf8)
        note("snap \(base)")
    }

    /// Taps the first hittable element with this label (buttons first, then anything). Returns false and logs if missing.
    @discardableResult
    private func tap(_ label: String, timeout: Double = 8, last: Bool = false) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for q in [app.buttons, app.staticTexts, app.descendants(matching: .any)] {
                let m = q.matching(NSPredicate(format: "label == %@", label))
                let found = (0..<min(m.count, 20)).map { m.element(boundBy: $0) }.filter { $0.exists && $0.frame.width > 0 }
                let all = found.filter { $0.isHittable }
                if let e = last ? all.last : all.first { e.tap(); note("tap \(label)"); return true }
                // On screen but covered (a keyboard, a glass bar): tap its middle anyway.
                if let e = last ? found.last : found.first, Date().addingTimeInterval(2) > deadline {
                    e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); note("tap (forced) \(label)"); return true
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        note("MISSING \(label)")
        return false
    }

    private func tapContaining(_ text: String, timeout: Double = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let m = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            for i in 0..<min(m.count, 20) where m.element(boundBy: i).isHittable { m.element(boundBy: i).tap(); note("tap ~\(text)"); return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        note("MISSING ~\(text)")
        return false
    }

    private func type(into field: XCUIElement, _ text: String) {
        guard field.waitForExistence(timeout: 6) else { note("MISSING field \(field)"); return }
        field.tap(); field.typeText(text)
    }

    private func closeSheet() {
        for l in ["Done", "Close", "Cancel"] where app.buttons[l].exists && app.buttons[l].isHittable { app.buttons[l].tap(); note("close via \(l)"); return }
        app.swipeDown(velocity: .fast); note("close via swipe")
    }

    private func timed(_ what: String, _ start: Date) { note(String(format: "TIME %@ %.1fs", what, Date().timeIntervalSince(start))) }

    // MARK: the session

    func testNewCustomer() {
        let env = ProcessInfo.processInfo.environment
        let email = env["QA_EMAIL"] ?? "qa@example.com", password = env["QA_PASSWORD"] ?? "change-me-123"
        let t0 = Date()
        app.launch()
        snap("welcome", wait: 3)
        app.swipeUp(); snap("welcome-scrolled", wait: 1)

        // Sign in with email. The workflow made the account through the same sign-up API the app uses; the simulator's
        // strong-password sheet (invisible to screenshots) blocks the in-app Create account button under automation.
        tap("Continue with email")
        snap("email-sheet")
        type(into: app.textFields["Email"], email)
        type(into: app.secureTextFields.firstMatch, password)
        app.staticTexts["Sign in with email"].firstMatch.tap()
        snap("email-filled", wait: 0.5)
        // The form's button is the lowest "Sign in" on screen (the other is the segmented control at the top).
        let submit = app.buttons.matching(NSPredicate(format: "label == 'Sign in'")).allElementsBoundByIndex
        if let b = submit.max(by: { $0.frame.minY < $1.frame.minY }), b.frame.minY > 300 {
            note("submit at y=\(Int(b.frame.minY)) enabled=\(b.isEnabled)")
            b.tap(); Thread.sleep(forTimeInterval: 1)
            if app.buttons.matching(NSPredicate(format: "label == 'Sign in'")).count > 1 { b.tap(); note("tapped submit twice (first tap only closed the keyboard)") }
        } else { note("MISSING submit button: \(submit.map { Int($0.frame.minY) })") }
        Thread.sleep(forTimeInterval: 3)
        snap("after-submit", wait: 0)
        let signed = Date()
        _ = app.staticTexts["What are you into?"].waitForExistence(timeout: 25)
        timed("sign-up to setup", signed)
        snap("setup-1-interests")

        // 1. Interests: one built-in category, one custom interest, plus my own words.
        // `last`: Today's For You chips ("Sneakers") sit behind the setup screen; the setup's own pill comes later in the tree.
        tap("Sneakers", last: true); tap("Vinyl & music", last: true)
        snap("setup-1-picked", wait: 0.5)
        tap("Watches", last: true)   // over the free limit: should be blocked
        snap("setup-1-third-pick", wait: 0.5)
        if tap("Describe your taste in your own words", timeout: 4) {
            snap("setup-1-editor", wait: 1)
            let editor = app.textViews.firstMatch
            if editor.waitForExistence(timeout: 4) { editor.typeText("New Balance 990s and Salomon trail runners in earth tones, size 10.5. I also collect 90s hip hop vinyl, original pressings under $80.") }
            snap("setup-1-editor-typed", wait: 0.5)
            tap("Done")
        }
        snap("setup-1-typed", wait: 0.5)
        if app.keyboards.count > 0 { app.swipeDown() }
        tap("Next")
        snap("setup-2-vibe")
        // Pick a couple of whatever pills are on screen.
        for l in ["New Balance", "Salomon", "Size 10.5", "Running & retro", "Up to $250"] { _ = tap(l, timeout: 1) }
        snap("setup-2-picked", wait: 0.5)
        if !tap("Next", timeout: 2) { tap("Skip") }
        let quizStart = Date()
        snap("setup-3-taste-check", wait: 4)
        timed("taste check load", quizStart)
        for i in 0..<6 { if !tap(i % 3 == 2 ? "Not for me" : "Love it", timeout: 4) { break }; if i == 1 { snap("setup-3-mid", wait: 1) } }
        snap("setup-3-after")
        if !tap("Next", timeout: 3) { tap("Done", timeout: 3) }
        snap("setup-4-photos")
        let build = Date()
        if !tap("Skip and build my scouts", timeout: 4) { tap("Build without photos") }
        snap("setup-5-building", wait: 1)
        _ = app.staticTexts["Your scouts are hunting"].waitForExistence(timeout: 60) || app.staticTexts["First finds are in"].exists
        timed("build squad", build)
        snap("setup-5-first-hunt", wait: 1)
        // Watch the first hunt like a customer would.
        for s in [45, 90, 150] {
            Thread.sleep(forTimeInterval: Double(s) - Date().timeIntervalSince(build))
            if app.staticTexts["First finds are in"].exists { timed("first finds appeared", build); break }
            snap("setup-5-wait-\(s)s", wait: 0)
        }
        snap("setup-5-end", wait: 1)
        if !tap("Not now, see my finds", timeout: 3) && !tap("Not now, show me Today", timeout: 3) { _ = tap("See my finds", timeout: 2) || tap("Show me Today", timeout: 2) }

        // How Baget works, right after setup.
        if app.staticTexts["How Baget works"].waitForExistence(timeout: 6) {
            for i in 1...5 { snap("howto-\(i)", wait: 1.2); if i < 5 { tap("Next", timeout: 2) } }
            tap("Start exploring", timeout: 3)
        } else { note("MISSING how-to after setup") }

        // Today.
        snap("today", wait: 4)
        app.swipeUp(); snap("today-scroll-1", wait: 2)
        app.swipeUp(); snap("today-scroll-2", wait: 2)
        app.swipeUp(); snap("today-scroll-3", wait: 2)
        // The bottom of Today: the Load more / Check for new picks button must work without going back to the top.
        let bottomStart = Date()
        let footer = NSPredicate(format: "label IN %@", ["Load more picks", "Check for new picks"])
        var swipes = 0
        while swipes < 60, !(app.buttons.matching(footer).firstMatch.exists && app.buttons.matching(footer).firstMatch.isHittable) {
            app.swipeUp(velocity: .fast); swipes += 1
        }
        timed("scroll to bottom of Today (\(swipes) swipes)", bottomStart)
        let btn = app.buttons.matching(footer).firstMatch
        if btn.exists && btn.isHittable {
            let label = btn.label
            note("bottom button: \(label)")
            snap("today-bottom", wait: 1)
            let tapped = Date(); btn.tap(); note("tap \(label)")
            snap("today-bottom-loading", wait: 0.5)
            // Wait for it to finish (the button comes back), then make sure we're still down here, not at the top.
            _ = app.buttons.matching(footer).firstMatch.waitForExistence(timeout: 40)
            timed("bottom button finished", tapped)
            let stayed = app.buttons["Back to top"].exists
            note(stayed ? "stayed at the bottom after the button" : "PROBLEM: jumped back to the top after the button")
            snap("today-bottom-after", wait: 0.5)
            app.swipeUp(); snap("today-bottom-more", wait: 1.5)
            // Pulling up past the end does the same.
            let pull = Date(); app.swipeUp(velocity: .fast); app.swipeUp(velocity: .fast)
            snap("today-pull-up", wait: 0.5)
            _ = app.buttons.matching(footer).firstMatch.waitForExistence(timeout: 40)
            timed("pull-up finished", pull)
            note(app.buttons["Back to top"].exists ? "still at the bottom after pull-up" : "PROBLEM: jumped to the top after pull-up")
        } else { note("MISSING Load more / Check for new picks button at the bottom of Today") }
        // Re-tapping the Today tab goes back to the top.
        tap("Today", timeout: 2); snap("today-back-top", wait: 1.5)
        // Send a new scout: the button opens its sheet.
        if tap("Send a new scout", timeout: 3) {
            snap("new-scout-sheet", wait: 2)
            if tap("Hunting one specific thing?", timeout: 3) { snap("new-scout-specific", wait: 1) } else { note("MISSING specific hunt option") }
            closeSheet()
        } else { note("MISSING Send a new scout") }
        if tap("See all", timeout: 2) { snap("for-you-all", wait: 3); tap("Done", timeout: 2) }

        // Finds.
        tap("Finds"); snap("finds", wait: 3)
        // The filter chips themselves ("New · 8", "♥ Saved"), not a section's "8 new" badge.
        for f in ["New", "♥ Saved", "Coming soon", "All"] {
            let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", f)).firstMatch
            if chip.waitForExistence(timeout: 2) && chip.isHittable { chip.tap(); snap("finds-\(f.lowercased())", wait: 1.5) }
        }
        // Grid view, then back to the list.
        if tap("Grid", timeout: 2) { snap("finds-grid", wait: 2); _ = tap("List", timeout: 2) }
        _ = tap("New", timeout: 2)
        // Open the first product card.
        let card = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "% match")).firstMatch
        if card.waitForExistence(timeout: 4) && card.isHittable { card.tap(); snap("find-detail", wait: 3); app.swipeUp(); snap("find-detail-scroll", wait: 1.5); closeSheet() }
        else { note("MISSING product card image") }
        snap("finds-after-detail", wait: 1)
        // Pass with "Not my size": a scout without a size asks for one.
        if tap("Pass", timeout: 3) {
            snap("pass-reasons", wait: 1)
            if tap("Not my size", timeout: 3) {
                let field = app.alerts.textFields.firstMatch
                if field.waitForExistence(timeout: 4) {
                    snap("size-ask", wait: 0.5)
                    field.tap(); field.typeText("M")
                    tap("Save", timeout: 2)
                    snap("size-saved", wait: 1)
                } else { note("no size question (the scout already has a size)"); snap("size-pass", wait: 1) }
            } else { note("MISSING Not my size (this find may not be clothing or shoes)"); closeSheet() }
        }

        // Squad.
        tap("Scouts"); snap("squad", wait: 3)
        app.swipeUp(); snap("squad-scroll", wait: 1.5)
        app.swipeDown()

        // Friends.
        tap("Friends"); snap("friends", wait: 3)

        // Notifications.
        if tapContaining("Notifications") { snap("inbox", wait: 3); closeSheet() }

        // Profile / settings.
        tap("You: icon, settings and account"); snap("profile", wait: 3)
        let bagetTab = app.segmentedControls.buttons["Baget"]
        if bagetTab.waitForExistence(timeout: 3) { bagetTab.tap(); snap("profile-baget-icons", wait: 1.5) }
        app.swipeUp(); snap("profile-scroll-1", wait: 1.5)
        app.swipeUp(); snap("profile-scroll-2", wait: 1.5)
        closeSheet()

        // Pro.
        tap("Scouts")
        if tapContaining("Go Pro") || tapContaining("Pro") { snap("paywall", wait: 3); app.swipeUp(); snap("paywall-scroll", wait: 1.5); closeSheet() }

        // A second look at Today/Finds after a few more minutes of hunting.
        Thread.sleep(forTimeInterval: 60)
        tap("Today"); app.swipeDown(); snap("today-later", wait: 5)
        tap("Finds"); snap("finds-later", wait: 3)
        timed("whole session", t0)
    }

    /// Language check: the sample tour in another language (QA_LANG, e.g. "ko"), tapping by position so it works in any
    /// language. Screenshots of the welcome screen, every tab and settings.
    func testLanguageTour() throws {
        let env = ProcessInfo.processInfo.environment
        guard let lang = env["QA_LANG"], !lang.isEmpty else { throw XCTSkip("no QA_LANG") }
        app.launchArguments += ["-AppleLanguages", "(\(lang))", "-AppleLocale", "\(lang)_US"]
        app.launch()
        snap("\(lang)-welcome", wait: 3)
        app.swipeUp(); snap("\(lang)-welcome-scrolled", wait: 1)
        // "Take a look first" is the last button on the welcome screen.
        if let look = app.buttons.allElementsBoundByIndex.filter({ $0.isHittable }).last { look.tap(); note("tap sample tour") }
        Thread.sleep(forTimeInterval: 3)
        let tabs = app.tabBars.buttons
        for i in 0..<max(tabs.count, 1) {
            if tabs.count > i { tabs.element(boundBy: i).tap() }
            snap("\(lang)-tab\(i)", wait: 2.5)
            app.swipeUp(); snap("\(lang)-tab\(i)-scrolled", wait: 1.5)
            app.swipeDown(); app.swipeDown()
        }
        // Settings: the icon at the top left.
        if tabs.count > 0 { tabs.element(boundBy: 0).tap() }
        let you = app.navigationBars.buttons.firstMatch
        if you.waitForExistence(timeout: 3) { you.tap(); snap("\(lang)-you", wait: 2); app.swipeUp(); snap("\(lang)-you-scrolled", wait: 1.5) }
    }

    /// Friend profile and Taste Card with sample data (QA_FRIENDS=1).
    func testFriendPreview() throws {
        guard ProcessInfo.processInfo.environment["QA_FRIENDS"] == "1" else { throw XCTSkip("no QA_FRIENDS") }
        app.launchArguments += ["-BagetFriendPreview"]
        app.launch()
        if let look = app.buttons.allElementsBoundByIndex.filter({ $0.isHittable }).last { look.tap() }   // sample tour
        Thread.sleep(forTimeInterval: 3)
        snap("friend-1", wait: 2)
        for i in 2...6 { app.swipeUp(); snap("friend-\(i)", wait: 1.2) }
        if tap("Swap Taste Cards", timeout: 3) { snap("card-theirs", wait: 2); tap("See mine", timeout: 2); snap("card-mine", wait: 1.5); tap("Close", timeout: 2) }
        // The ✕ closes the profile; then the Friends tab with a birthday coming up, and Settings' birthday row.
        if tap("Close", timeout: 3) { snap("friend-closed", wait: 1.5) }
        if tap("Friends", timeout: 3) { snap("friends-birthday", wait: 2) }
    }

    // MARK: Demo reel

    /// Marks where a scene starts, by wall clock, so the workflow can cut the screen recording into clips.
    private func scene(_ name: String) { note(String(format: "SCENE %@ %.2f", name, Date().timeIntervalSince1970)) }

    /// Types like a person: a few characters at a time.
    private func typeSlowly(_ el: XCUIElement, _ text: String) {
        var chunk = ""
        for ch in text {
            chunk.append(ch)
            if chunk.count >= 3 || ch == " " { el.typeText(chunk); chunk = ""; Thread.sleep(forTimeInterval: 0.05) }
        }
        if !chunk.isEmpty { el.typeText(chunk) }
    }

    private func slowScroll(_ times: Int, pause: Double = 1.6) {
        for _ in 0..<times { app.swipeUp(velocity: .slow); Thread.sleep(forTimeInterval: pause) }
    }

    /// Footage for Instagram (DEMO=1): a brand-new customer asks for esoteric, niche scents, the scout hunts, and we walk
    /// through the real finds (price, store, in stock), a find up close, and a chat with the scout. Paced for a viewer;
    /// the workflow records the screen and cuts it at the SCENE marks.
    func testDemoReel() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_DEMO"] == "1" else { throw XCTSkip("no QA_DEMO") }
        let email = env["QA_EMAIL"] ?? "", password = env["QA_PASSWORD"] ?? ""
        let pill = env["QA_PILL"] ?? "Fragrance"
        let ask = env["QA_PROMPT"] ?? "Esoteric niche scents nobody else wears. Smoky incense, resinous oud, green fig, indie perfume houses. Nothing mainstream or sweet."
        let followUp = env["QA_FOLLOWUP"] ?? "Go deeper. Rarer houses, small batches, under $150."
        app.launch()
        scene("welcome"); Thread.sleep(forTimeInterval: 3)
        tap("Continue with email")
        type(into: app.textFields["Email"], email)
        type(into: app.secureTextFields.firstMatch, password)
        app.staticTexts["Sign in with email"].firstMatch.tap()
        let submit = app.buttons.matching(NSPredicate(format: "label == 'Sign in'")).allElementsBoundByIndex
        if let b = submit.max(by: { $0.frame.minY < $1.frame.minY }), b.frame.minY > 300 {
            b.tap(); Thread.sleep(forTimeInterval: 1)
            if app.buttons.matching(NSPredicate(format: "label == 'Sign in'")).count > 1 { b.tap() }
        }
        _ = app.staticTexts["What are you into?"].waitForExistence(timeout: 25)

        scene("ask"); Thread.sleep(forTimeInterval: 1.5)
        tap(pill, timeout: 3, last: true); Thread.sleep(forTimeInterval: 0.8)
        // The words box sits below the category pills: bring it on screen first.
        app.swipeUp(velocity: .slow); Thread.sleep(forTimeInterval: 0.8)
        if tap("Describe your taste in your own words", timeout: 4) {
            let editor = app.textViews.firstMatch
            if editor.waitForExistence(timeout: 4) {
                Thread.sleep(forTimeInterval: 0.6)
                scene("typing")
                typeSlowly(editor, ask)
            }
            Thread.sleep(forTimeInterval: 1.5)
            tap("Done")
        }
        if app.keyboards.count > 0 { app.swipeDown() }
        Thread.sleep(forTimeInterval: 1)
        tap("Next")
        scene("vibe"); Thread.sleep(forTimeInterval: 2)
        Thread.sleep(forTimeInterval: 1)
        if !tap("Next", timeout: 2) { tap("Skip") }

        scene("quiz"); Thread.sleep(forTimeInterval: 3)
        for i in 0..<6 { if !tap(i % 3 == 2 ? "Not for me" : "Love it", timeout: 4) { break }; Thread.sleep(forTimeInterval: 1.1) }
        if !tap("Next", timeout: 3) { tap("Done", timeout: 3) }
        Thread.sleep(forTimeInterval: 1.5)
        if !tap("Skip and build my scouts", timeout: 4) { tap("Build without photos") }

        scene("hunting")
        _ = app.staticTexts["First finds are in"].waitForExistence(timeout: 300)
        scene("found"); Thread.sleep(forTimeInterval: 3)
        if !tap("Not now, see my finds", timeout: 3) && !tap("Not now, show me Today", timeout: 3) { _ = tap("See my finds", timeout: 2) || tap("Show me Today", timeout: 2) }
        if app.staticTexts["How Baget works"].waitForExistence(timeout: 6) {
            for _ in 1...4 { tap("Next", timeout: 2) }
            tap("Start exploring", timeout: 3)
        }

        scene("today"); Thread.sleep(forTimeInterval: 4)
        slowScroll(3)
        app.swipeDown(); app.swipeDown(); Thread.sleep(forTimeInterval: 1)

        tap("Finds"); scene("finds"); Thread.sleep(forTimeInterval: 3.5)
        slowScroll(3, pause: 2)
        app.swipeDown(); app.swipeDown(); Thread.sleep(forTimeInterval: 1.2)

        let cards = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "% match"))
        for i in 0..<2 {
            let card = cards.element(boundBy: i)
            guard card.waitForExistence(timeout: 4), card.isHittable else { break }
            card.tap(); scene("detail\(i + 1)"); Thread.sleep(forTimeInterval: 4)
            app.swipeUp(velocity: .slow); Thread.sleep(forTimeInterval: 3)
            closeSheet(); Thread.sleep(forTimeInterval: 1.5)
        }

        tap("Scouts"); scene("scouts"); Thread.sleep(forTimeInterval: 3)
        if tapContaining("Talk to") {
            scene("chat"); Thread.sleep(forTimeInterval: 2)
            let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
            if field.waitForExistence(timeout: 4) {
                field.tap(); Thread.sleep(forTimeInterval: 0.6)
                typeSlowly(field, followUp)
                Thread.sleep(forTimeInterval: 1)
                tap("Send", timeout: 3)
                Thread.sleep(forTimeInterval: 25)
            }
            closeSheet(); Thread.sleep(forTimeInterval: 1)
        }
        if tapContaining("Notifications") { scene("inbox"); Thread.sleep(forTimeInterval: 3); slowScroll(2); closeSheet() }
        scene("end"); Thread.sleep(forTimeInterval: 2)
    }

    /// Footage for Instagram (QA_LONGTERM=1): the demo account that has had scouts hunting every day for weeks. Shows
    /// Today, the scouts, weeks of texts, the pile of finds, what's coming soon, and one find up close.
    func testLongTermReel() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_LONGTERM"] == "1" else { throw XCTSkip("no QA_LONGTERM") }
        app.launchArguments += ["-BagetDemoSignedIn"]
        app.launchEnvironment["BAGET_SHOT_EMAIL"] = env["QA_SHOT_EMAIL"] ?? ""
        app.launchEnvironment["BAGET_SHOT_PASSWORD"] = env["QA_SHOT_PASSWORD"] ?? ""
        app.launch()
        _ = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Good '")).firstMatch.waitForExistence(timeout: 60)
        Thread.sleep(forTimeInterval: 4)
        scene("today"); Thread.sleep(forTimeInterval: 3.5)
        slowScroll(2, pause: 2)
        app.swipeDown(); app.swipeDown(); Thread.sleep(forTimeInterval: 1)

        tap("Scouts"); scene("scouts"); Thread.sleep(forTimeInterval: 3.5)
        slowScroll(3, pause: 2)
        app.swipeDown(); app.swipeDown(); app.swipeDown(); Thread.sleep(forTimeInterval: 1)

        if tapContaining("Notifications") { scene("inbox"); Thread.sleep(forTimeInterval: 3.5); slowScroll(4, pause: 1.8); closeSheet(); Thread.sleep(forTimeInterval: 1) }

        tap("Finds"); scene("finds"); Thread.sleep(forTimeInterval: 3.5)
        slowScroll(3, pause: 1.8)
        app.swipeDown(); app.swipeDown(); app.swipeDown(); Thread.sleep(forTimeInterval: 1)
        if tap("Coming soon", timeout: 3) { scene("coming"); Thread.sleep(forTimeInterval: 3.5); slowScroll(2, pause: 2); app.swipeDown(); app.swipeDown(); Thread.sleep(forTimeInterval: 1) }
        if tap("All", timeout: 3) { scene("all"); Thread.sleep(forTimeInterval: 2.5) }

        let card = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "% match")).firstMatch
        if card.waitForExistence(timeout: 4), card.isHittable {
            card.tap(); scene("detail"); Thread.sleep(forTimeInterval: 4.5)
            app.swipeUp(velocity: .slow); Thread.sleep(forTimeInterval: 3)
            closeSheet(); Thread.sleep(forTimeInterval: 1)
        }
        scene("end"); Thread.sleep(forTimeInterval: 2)
    }

    // MARK: Feature reels (one part of the app per day, on the long-running demo account)

    /// Signs in to the long-running demo account (weeks of hunting) and waits for Today.
    private func launchDemoAccount(extra: [String] = []) {
        let env = ProcessInfo.processInfo.environment
        app.launchArguments += ["-BagetDemoSignedIn"] + extra
        app.launchEnvironment["BAGET_SHOT_EMAIL"] = env["QA_SHOT_EMAIL"] ?? ""
        app.launchEnvironment["BAGET_SHOT_PASSWORD"] = env["QA_SHOT_PASSWORD"] ?? ""
        app.launch()
        _ = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Good '")).firstMatch.waitForExistence(timeout: 60)
        Thread.sleep(forTimeInterval: 3)
    }

    /// Footage for the Friends reel (QA_FEATURE=friends): a friend's profile with sample data (taste match, shared taste
    /// DNA, their grails, twin finds, gift radar for their birthday), then swapping Taste Cards.
    func testFriendsReel() throws {
        guard ProcessInfo.processInfo.environment["QA_FEATURE"] == "friends" else { throw XCTSkip("no QA_FEATURE=friends") }
        launchDemoAccount(extra: ["-BagetFriendPreview"])
        _ = app.staticTexts["Taste DNA"].waitForExistence(timeout: 15)
        scene("profile"); Thread.sleep(forTimeInterval: 3.5)
        for i in 1...5 { app.swipeUp(velocity: .slow); scene("scroll\(i)"); Thread.sleep(forTimeInterval: 2.2) }
        for _ in 0..<6 { app.swipeDown(velocity: .fast) }
        Thread.sleep(forTimeInterval: 1)
        if !tap("Swap Taste Cards", timeout: 3) { for _ in 0..<6 { app.swipeUp() }; tap("Swap Taste Cards", timeout: 3) }
        scene("card"); Thread.sleep(forTimeInterval: 3.5)
        if tap("See mine", timeout: 3) { scene("mine"); Thread.sleep(forTimeInterval: 3) }
        closeSheet(); Thread.sleep(forTimeInterval: 1)
        closeSheet(); Thread.sleep(forTimeInterval: 1)
        if tap("Friends", timeout: 3) { scene("friends"); Thread.sleep(forTimeInterval: 3.5); slowScroll(1, pause: 2) }
        scene("end"); Thread.sleep(forTimeInterval: 2)
    }

    /// Footage for the Chat reel (QA_FEATURE=chat): the scouts, then asking one for something in plain words and its reply.
    func testChatReel() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_FEATURE"] == "chat" else { throw XCTSkip("no QA_FEATURE=chat") }
        let ask = env["QA_PROMPT"] ?? "Find me something like this but under $200, in stock in my size."
        launchDemoAccount()
        tap("Scouts"); scene("scouts"); Thread.sleep(forTimeInterval: 3.5)
        slowScroll(1, pause: 2); app.swipeDown(); app.swipeDown(); Thread.sleep(forTimeInterval: 1)
        if tapContaining("Talk to") {
            scene("chat"); Thread.sleep(forTimeInterval: 2.5)
            let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
            if field.waitForExistence(timeout: 4) {
                field.tap(); Thread.sleep(forTimeInterval: 0.6)
                typeSlowly(field, ask)
                Thread.sleep(forTimeInterval: 1)
                tap("Send", timeout: 3)
                scene("reply"); Thread.sleep(forTimeInterval: 30)
                slowScroll(1, pause: 3)
            }
            closeSheet(); Thread.sleep(forTimeInterval: 1)
        }
        tap("Finds"); scene("finds"); Thread.sleep(forTimeInterval: 3.5); slowScroll(1, pause: 2)
        scene("end"); Thread.sleep(forTimeInterval: 2)
    }

    /// Footage for the Drops reel (QA_FEATURE=drops): what's coming soon, the texts (restocks, price drops, new drops),
    /// and one find up close with its price and stock.
    func testDropsReel() throws {
        guard ProcessInfo.processInfo.environment["QA_FEATURE"] == "drops" else { throw XCTSkip("no QA_FEATURE=drops") }
        launchDemoAccount()
        tap("Finds"); Thread.sleep(forTimeInterval: 2)
        if tap("Coming soon", timeout: 4) { scene("coming"); Thread.sleep(forTimeInterval: 3.5); slowScroll(2, pause: 2); app.swipeDown(); app.swipeDown(); Thread.sleep(forTimeInterval: 1) }
        if tapContaining("Notifications") { scene("inbox"); Thread.sleep(forTimeInterval: 3.5); slowScroll(3, pause: 1.8); closeSheet(); Thread.sleep(forTimeInterval: 1) }
        if tap("All", timeout: 3) { Thread.sleep(forTimeInterval: 2) }
        let card = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "% match")).firstMatch
        if card.waitForExistence(timeout: 4), card.isHittable {
            card.tap(); scene("detail"); Thread.sleep(forTimeInterval: 4.5)
            app.swipeUp(velocity: .slow); Thread.sleep(forTimeInterval: 3)
            closeSheet(); Thread.sleep(forTimeInterval: 1)
        }
        scene("end"); Thread.sleep(forTimeInterval: 2)
    }
}
