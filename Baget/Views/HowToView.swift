import SwiftUI

/// "How Baget works": a short swipe-through shown once, right after setup and before Today. Also in Settings.
struct HowToView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Page: Identifiable {
        let id: Int
        let icon: String
        let tint: Color
        let title: LocalizedStringKey
        let body: LocalizedStringKey
        let tips: [LocalizedStringKey]
    }

    private let pages: [Page] = [
        Page(id: 0, icon: "sun.max.fill", tint: Theme.warn, title: "Today is your daily feed",
             body: "Every day your scouts' best finds land at the top, with more picks for you below.",
             tips: ["Tap ♥ on what you love, ✕ on what you don't", "Every tap teaches your scouts your taste", "Pull down any time to check for new finds"]),
        Page(id: 1, icon: "sparkles", tint: Theme.cyan, title: "Finds is everything they found",
             body: "Each find shows the price, the store and why your scout picked it.",
             tips: ["Like it, or Pass and say why", "Watch it and get a text when the price drops or it restocks", "Buy takes you straight to the store's page"]),
        Page(id: 2, icon: "person.3.fill", tint: Theme.green, title: "Your squad does the hunting",
             body: "Each scout hunts one thing for you, and every one is yours to shape. Change what it hunts, its brands, styles, size and budget, or how often it texts you, any time.",
             tips: ["Talk to a scout or open Detailed hunt setup to fine-tune it", "Pause a scout, or delete it from its card in Squad", "Send a new scout any time from Today, and it starts hunting right away", "Tap Hunt now in Finds when you can't wait"]),
        Page(id: 3, icon: "bell.badge.fill", tint: Theme.hot, title: "They text you like a friend",
             body: "When something great turns up, your scout texts you a photo and why it's worth a look.",
             tips: ["Only the best ones, a few a day at most", "Change how often in Settings, under Notifications", "Your icon at the top left opens Settings"]),
        Page(id: 4, icon: "heart.circle.fill", tint: Theme.accent, title: "Hunt with friends",
             body: "Add friends and see how your taste compares.",
             tips: ["Tap Add in Your circle and type their @username. Set yours in Settings", "Share your taste to see your taste match and swap Taste Cards",
                    "Add your birthday in Settings, and friends get gift ideas for your taste", "Send a friend a find, and tap what they send you to see it at the store"]),
    ]

    var body: some View {
        ZStack {
            LitBackground()
            VStack(spacing: 18) {
                HStack {
                    Text("How Baget works").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    Spacer()
                    if page < pages.count - 1 {
                        Button("Skip") { finish() }.font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    }
                }
                TabView(selection: $page) {
                    ForEach(pages) { p in card(p).tag(p.id) }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                HStack(spacing: 6) {
                    ForEach(pages) { p in
                        Capsule().fill(p.id == page ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.line))
                            .frame(width: p.id == page ? 18 : 6, height: 6)
                    }
                }
                .accessibilityHidden(true)
                Button(page == pages.count - 1 ? "Start exploring" : "Next") {
                    if page == pages.count - 1 { finish() } else { withAnimation(.snappy) { page += 1 } }
                }
                .buttonStyle(PrimaryButton())
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
    }

    private func card(_ p: Page) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: p.icon)
                .font(.system(size: 30, weight: .bold)).foregroundStyle(p.tint)
                .frame(width: 72, height: 72)
                .background(p.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(p.title).font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(p.body).font(.body).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(p.tips.enumerated()), id: \.offset) { _, tip in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").font(.subheadline).foregroundStyle(p.tint)
                        Text(tip).font(.subheadline).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.glass, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private func finish() {
        Analytics.track(.howToDone, ["page": page])
        dismiss()
    }
}
