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

    func loadPlan() async {
        guard isCloud else { plan = nil; return }
        if let p: PlanInfo = try? await api.rpc("my_plan") { plan = p }
    }

    func loadProProducts() async {
        guard proProducts.isEmpty else { return }
        let products = (try? await Product.products(for: Self.proProductIDs)) ?? []
        proProducts = products.sorted { ($0.subscription?.subscriptionPeriod.unit == .month ? 0 : 1) < ($1.subscription?.subscriptionPeriod.unit == .month ? 0 : 1) }
    }

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
