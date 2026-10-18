import SwiftUI
import StoreKit

/// Baget Pro: what you get, the plans, buy, restore, and the fine print Apple requires.
struct PaywallView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String = "baget.pro.yearly"
    @State private var message: String?

    /// CI takes the App Review screenshot in the simulator, where the App Store isn't reachable: show the list prices.
    static var screenshotMode: Bool { ProcessInfo.processInfo.arguments.contains("-BagetPaywallShot") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    compare
                    plans
                    if let message { Text(message).font(.footnote).foregroundStyle(Theme.warn) }
                    buyButton
                    HStack {
                        Button("Restore purchases") { Task { message = await store.restorePro() } }
                        Spacer()
                        Link("Terms", destination: AppStore.termsURL)
                        Text("·").foregroundStyle(Theme.muted)
                        Link("Privacy", destination: AppStore.privacyURL)
                    }
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                    Text("Subscriptions renew automatically until canceled. Cancel any time in Settings → your name → Subscriptions at least 24 hours before renewal. Payment is charged to your Apple ID.")
                        .font(.caption2).foregroundStyle(Theme.muted)
                }
                .padding(20)
            }
            .background(LitBackground())
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task { await store.loadProProducts() }
        .onChange(of: store.isPro) { _, pro in if pro { router.say("You're Pro. Your scouts hunt around the clock now."); dismiss() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text("Baget ").foregroundStyle(Theme.ink)
                Text("Pro").gradientText()
            }
            .font(.system(size: 36, weight: .heavy)).tracking(-1)
            Text("Your scouts never clock out and dig deeper every time: more searches, more stores, and they open the product page to check price and stock before telling you.")
                .font(.subheadline).foregroundStyle(Theme.muted)
        }
    }

    private var compare: some View {
        VStack(spacing: 0) {
            row("", "Free", "Pro", head: true)
            row("Scouts", "2", "Up to 5")
            row("Hunting", "4 hours a day", "Around the clock")
            row("When", store.plan?.windowLabel ?? "9am to 1pm", "Any time")
            row("Hunts", "1 a day each", "Every 6 hours")
            row("Search depth", "Standard", "Deep: 12 searches, checks each page")
            row("Everything else", "Included", "Included")
        }
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
    }

    private func row(_ label: String, _ free: String, _ pro: String, head: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(Theme.muted)
            Text(free).frame(width: 92, alignment: .leading).foregroundStyle(head ? Theme.muted : Theme.ink)
            Text(pro).frame(width: 96, alignment: .leading).foregroundStyle(head ? Theme.green : Theme.green).bold()
        }
        .font(head ? .caption.weight(.bold) : .caption)
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private struct PlanOption: Identifiable { let id: String; let title: String; let price: String; let note: String? }

    private var options: [PlanOption] {
        let monthly = store.proProducts.first { $0.id == "baget.pro.monthly" }
        let yearly = store.proProducts.first { $0.id == "baget.pro.yearly" }
        if monthly == nil && yearly == nil {
            guard Self.screenshotMode else { return [] }
            return [PlanOption(id: "baget.pro.yearly", title: "Yearly", price: "$99.99 / year", note: "Save 44%"),
                    PlanOption(id: "baget.pro.monthly", title: "Monthly", price: "$14.99 / month", note: nil)]
        }
        var out: [PlanOption] = []
        if let y = yearly {
            var save: String?
            if let m = monthly, m.price > 0 {
                let pct = Int(((1 - (y.price as NSDecimalNumber).doubleValue / ((m.price as NSDecimalNumber).doubleValue * 12)) * 100).rounded())
                if pct > 0 { save = "Save \(pct)%" }
            }
            out.append(PlanOption(id: y.id, title: "Yearly", price: "\(y.displayPrice) / year", note: save))
        }
        if let m = monthly { out.append(PlanOption(id: m.id, title: "Monthly", price: "\(m.displayPrice) / month", note: nil)) }
        return out
    }

    @ViewBuilder private var plans: some View {
        if options.isEmpty {
            HStack { ProgressView().tint(Theme.cyan); Text("Loading plans…").font(.footnote).foregroundStyle(Theme.muted) }
        } else {
            VStack(spacing: 10) {
                ForEach(options) { o in
                    Button { selected = o.id } label: {
                        HStack {
                            Image(systemName: selected == o.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected == o.id ? Theme.green : Theme.muted)
                            Text(o.title).font(.headline).foregroundStyle(Theme.ink)
                            if let n = o.note { Tag(text: n, tint: Theme.green) }
                            Spacer()
                            Text(o.price).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.ink)
                        }
                        .padding(14)
                        .background(selected == o.id ? Theme.green.opacity(0.10) : Theme.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected == o.id ? Theme.green.opacity(0.6) : Theme.line))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var buyButton: some View {
        Button {
            guard let product = store.proProducts.first(where: { $0.id == selected }) ?? store.proProducts.first else {
                message = "Plans aren't available right now. Try again in a minute."
                return
            }
            Task { message = await store.buyPro(product) }
        } label: {
            if store.purchasing { ProgressView().tint(Theme.accentInk) } else { Text("Go Pro") }
        }
        .buttonStyle(PrimaryButton())
        .disabled(store.purchasing || store.isPro)
    }
}

/// Under the greeting on Today: Pro, or (Free) whether the scouts are hunting and when that changes.
struct PlanStatusPill: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        if store.isCloud, let p = store.plan {
            Button { if !p.pro { router.sheet = .pro } } label: {
                HStack(spacing: 6) {
                    Circle().fill(p.huntingNow ? Theme.green : Theme.muted).frame(width: 7, height: 7)
                    Text(text(p)).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
                    if !p.pro {
                        Text("Go 24/7").font(.caption.weight(.bold)).foregroundStyle(Theme.accentInk)
                            .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.gradient, in: Capsule())
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.glass, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line))
            }
            .buttonStyle(.plain)
        }
    }

    private func text(_ p: PlanInfo) -> String {
        if p.pro { return "Pro · hunting around the clock" }
        let m = p.minutesToChange()
        let left = m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
        return p.huntingNow ? "Hunting now · \(left) left today" : "Scouts resting · back at \(PlanInfo.hourLabel(p.huntStart))"
    }
}

/// Settings: your plan, and for Free, when the daily window runs.
struct PlanSettingsRows: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        if store.isCloud {
            Button { router.sheet = .pro } label: {
                HStack {
                    Label(store.isPro ? "Baget Pro" : "Go Pro: hunt around the clock", systemImage: "bolt.fill")
                    Spacer()
                    if store.isPro { Text("Active").font(.footnote).foregroundStyle(Theme.green) }
                }
            }
            .disabled(store.isPro && store.plan?.plan == "comp")
            if !store.isPro {
                Picker(selection: Binding(get: { store.plan?.huntStart ?? store.state.settings.huntStart ?? 9 },
                                          set: { store.setHuntStart($0) })) {
                    ForEach(0..<24, id: \.self) { h in Text("\(PlanInfo.hourLabel(h)) to \(PlanInfo.hourLabel((h + 4) % 24))").tag(h) }
                } label: {
                    Label("Hunting window", systemImage: "clock")
                }
            }
        }
    }
}
