import SwiftUI

/// "How Baget works": a short swipe-through (the drop, watching, Scouts, Finds, friends) shown once, right after setup and before Today. Also in Settings.
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
        Page(id: 0, icon: "sun.max.fill", tint: Theme.warn, title: "Every morning, a drop",
             body: "At 9 AM your scouts bring their best finds to Today as a deck of cards. You'll get one text when it lands.",
             tips: ["Swipe right to like, left to pass", "Swipe up to watch it, or get a reminder for a release", "Change the time in Settings, under Notifications"]),
        Page(id: 1, icon: "eye.fill", tint: Theme.green, title: "Your scouts watch what you like",
             body: "Everything you like, your scout keeps an eye on: price drops, restocks and release dates. What changed shows up first in tomorrow's drop.",
             tips: ["Release cards count down to the drop, marked Confirmed or Rumored", "Swipe up on a release to get a reminder 15 minutes before", "Finish the drop, then tap Keep swiping for more picks"]),
        Page(id: 2, icon: "binoculars.fill", tint: Theme.cyan, title: "Build and tune your scouts",
             body: "Each scout hunts one thing for you. In Scouts, tap Tune on any scout to change what it hunts and skips, its size and budget.",
             tips: ["Tap Build a scout in Scouts to add one. It starts hunting right away", "Or just tell a scout what you want, in plain words", "Turn a scout off or delete it from Tune"]),
        Page(id: 3, icon: "sparkles", tint: Theme.accent, title: "Finds keeps everything",
             body: "Every find lives in Finds, with the price, the store and why your scout picked it.",
             tips: ["Like it, or Pass and say why", "Buy takes you straight to the store's page", "Today has a List view too, if you'd rather tap than swipe"]),
        Page(id: 4, icon: "heart.circle.fill", tint: Theme.hot, title: "Hunt with friends",
             body: "Add friends and see how your taste compares. When a friend likes something in your drop, the card says so.",
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
