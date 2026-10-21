import Foundation
import StoreKit

/// Your plan, as the server sees it.
struct PlanInfo: Decodable, Equatable {
    let plan: String          // free, pro, comp
    let pro: Bool
    let proUntil: Date?
    let huntStart: Int
    let hours: Int
    let huntingNow: Bool
    /// How many scouts the plan includes (Free 2, Pro 5).
    var scouts: Int?

    /// "9am to 1pm"
    var windowLabel: String { "\(Self.hourLabel(huntStart)) to \(Self.hourLabel((huntStart + hours) % 24))" }

    static func hourLabel(_ h: Int) -> String {
        let x = ((h % 24) + 24) % 24
        return "\(x % 12 == 0 ? 12 : x % 12)\(x < 12 ? "am" : "pm")"
    }

    /// Minutes until the window opens (when resting) or closes (when hunting), in local time.
    func minutesToChange(now: Date = .now) -> Int {
        let cal = Calendar.current
        let h = cal.component(.hour, from: now), m = cal.component(.minute, from: now)
        let sinceStart = ((h - huntStart) % 24 + 24) % 24 * 60 + m
        return huntingNow ? max(0, hours * 60 - sinceStart) : max(0, 24 * 60 - sinceStart)
    }
}

private struct SubscriptionReply: Decodable { let applied: Bool?; let pro: Bool? }

extension AppStore {
    static let proProductIDs = ["baget.pro.monthly", "baget.pro.yearly"]
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://github.com/Lwhite15/Baget-12/blob/main/PRIVACY.md")!

    var isPro: Bool { plan?.pro ?? false }

    /// How many scouts this account may have: Free 2, Pro 5 (the sample tour: no limit to speak of).
    var scoutLimit: Int { isCloud ? (plan?.scouts ?? (isPro ? 5 : 2)) : 12 }
    var squadFull: Bool { state.agents.count >= scoutLimit }
    var scoutLimitMessage: String { isPro ? "Pro includes up to \(scoutLimit) scouts. Retire one to add another." : "Free includes 2 scouts. Go Pro for up to 5." }

    func loadPlan() async {
        guard isCloud else { plan = nil; return }
        if let p: PlanInfo = try? await api.rpc("my_plan") { plan = p }
    }

    func loadProProducts() async {
        if proProducts.isEmpty {
            let products = (try? await Product.products(for: Self.proProductIDs)) ?? []
            proProducts = products.sorted { ($0.subscription?.subscriptionPeriod.unit == .month ? 0 : 1) < ($1.subscription?.subscriptionPeriod.unit == .month ? 0 : 1) }
        }
        if let sub = proProducts.first?.subscription { proTrialEligible = await sub.isEligibleForIntroOffer }
    }

    /// "7-day" when this product has a free trial this person can still start; nil otherwise.
    func trialLength(_ product: Product?) -> String? {
        guard proTrialEligible, !isPro, let o = product?.subscription?.introductoryOffer, o.paymentMode == .freeTrial else { return nil }
        let n = o.period.value * o.periodCount
        switch o.period.unit {
        case .day: return "\(n)-day"
        case .week: return "\(n * 7)-day"
        case .month: return n == 1 ? "1-month" : "\(n)-month"
        case .year: return "1-year"
        @unknown default: return nil
        }
    }

    /// "7-day" → "7 days", "1-month" → "1 month".
    static func spoken(_ t: String) -> String {
        let parts = t.split(separator: "-")
        guard parts.count == 2, let n = Int(parts[0]) else { return t }
        return "\(n) \(parts[1])\(n == 1 ? "" : "s")"
    }

    /// The trial on offer for the yearly plan (what the setup screen and badges talk about).
    var proTrial: String? { trialLength(proProducts.first { $0.id == "baget.pro.yearly" } ?? proProducts.first) }

    /// Buys Pro. The purchase is tied to this Baget account, checked by the server with Apple, then Pro turns on.
    @discardableResult
    func buyPro(_ product: Product) async -> String? {
        guard isCloud, let uid = api.userID else { return "Sign in to go Pro." }
        purchasing = true
        defer { purchasing = false }
        var options: Set<Product.PurchaseOption> = []
        if let token = UUID(uuidString: uid) { options.insert(.appAccountToken(token)) }
        do {
            switch try await product.purchase(options: options) {
            case .success(let result):
                guard case .verified(let tx) = result else { return "Apple couldn't verify that purchase." }
                let msg = await sendToServer(result.jwsRepresentation)
                await tx.finish()
                await loadPlan()
                Analytics.track(.purchaseConfirmed, ["pro": product.id])
                return msg
            case .userCancelled: return nil
            case .pending: return "Your purchase is waiting for approval."
            @unknown default: return nil
            }
        } catch {
            return "The purchase didn't go through. \((error as? LocalizedError)?.errorDescription ?? "")"
        }
    }

    /// Restore: asks the App Store for your purchases, then re-checks them with the server.
    func restorePro() async -> String {
        try? await StoreKit.AppStore.sync()
        await syncProEntitlements()
        await loadPlan()
        return isPro ? "Pro restored." : "No Baget Pro subscription found for this Apple ID."
    }

    /// On launch and after any change: sends your current subscriptions to the server, so renewals,
    /// cancellations and refunds keep Pro accurate.
    func syncProEntitlements() async {
        guard isCloud else { return }
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result, Self.proProductIDs.contains(tx.productID) else { continue }
            _ = await sendToServer(result.jwsRepresentation)
        }
    }

    /// Listens for purchases that finish outside the app's purchase sheet (renewals, Ask to Buy, other devices).
    func listenForProUpdates() {
        let ids = Self.proProductIDs
        Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let tx) = result else { continue }
                if ids.contains(tx.productID) {
                    _ = await self?.sendToServer(result.jwsRepresentation)
                    await self?.loadPlan()
                }
                await tx.finish()
            }
        }
    }

    private func sendToServer(_ jws: String) async -> String? {
        do {
            let r: SubscriptionReply = try await api.function("subscription", ["signed_transaction": jws])
            return r.pro == true ? nil : "That subscription has ended."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Couldn't confirm the purchase. Try Restore in a minute."
        }
    }

    /// Free plan: when the daily 4-hour hunting window starts (local hour).
    func setHuntStart(_ hour: Int) {
        state.settings.huntStart = ((hour % 24) + 24) % 24
        save()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))   // let the settings sync land first
            await loadPlan()
        }
    }
}
