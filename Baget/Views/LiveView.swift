import SwiftUI

/// The stories feed on its own (section bar, lead story, rows, trending), embedded in Today.
struct LiveFeed: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @State private var selected: String = "foryou"
    @State private var shown = 10

    var body: some View {
        let tabs = store.state.liveTabs
        let tab = tabs.first { $0.id == selected } ?? tabs.first
        let list = tab.map { store.stories(for: $0) } ?? []
        let forYouCount = store.stories().filter(\.forYou).count

            VStack(alignment: .leading, spacing: 18) {
                sectionBar(tabs: tabs, current: tab, forYouCount: forYouCount)
                if let r = store.state.awayReport { AwayCard(report: r) }

                if let tab, list.isEmpty {
                    emptyState(tab)
                } else if tab == nil {
                    VStack(spacing: 12) {
                        EmptyCard(text: "Your bar is empty.")
                        Button("Add sections") { router.sheet = .customizeBar }.buttonStyle(PrimaryButton())
                    }
                } else if let lead = list.first {
                    LeadStoryView(story: lead)
                    ForEach(list.dropFirst().prefix(shown)) { s in
                        StoryRow(story: s)
                        Divider().overlay(Theme.line)
                    }
                    if list.count - 1 > shown {
                        Button("Load more stories") { shown += 10 }.buttonStyle(GhostButton())
                    }
                }
                TrendingView()
                if !store.isCloud {
                    Text("Sample data. Sign in to have your squad search the real web.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
        .onAppear { if !tabs.contains(where: { $0.id == selected }) { selected = tabs.first?.id ?? "" } }
    }

    private func sectionBar(tabs: [LiveTab], current: LiveTab?, forYouCount: Int) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(tabs) { t in
                    Button {
                        selected = t.id; shown = 10
                        Analytics.track(.liveSectionViewed, ["section": t.label])
                    } label: {
                        Pill(text: t.kind == .forYou && forYouCount > 0 ? "For you · \(forYouCount)" : t.label, selected: t.id == current?.id)
                    }
                }
                Button { router.sheet = .customizeBar } label: {
                    Label("Customize", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4])))
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private func emptyState(_ tab: LiveTab) -> some View {
        switch tab.kind {
        case .custom(let q):
            VStack(spacing: 12) {
                EmptyCard(text: "Nothing in today's stories matches “\(q)” yet.")
                Button("Deploy an agent to hunt \(tab.label)") {
                    router.deployPrefill = .custom(q)
                    router.sheet = .deploy
                }.buttonStyle(PrimaryButton())
            }
        case .forYou:
            EmptyCard(text: "Your squad hasn't picked anything yet. Brief an agent or rate a few finds and this fills up.")
        default:
            EmptyCard(text: "No stories here yet.")
        }
    }
}

struct Kicker: View {
    let story: Story
    var body: some View {
        HStack(spacing: 8) {
            Text(story.item.category.info.label.uppercased()).foregroundStyle(Theme.cyan)
            Text(story.kind.uppercased()).foregroundStyle(story.kind == "Release" || story.kind == "Market" ? Theme.hot : Theme.muted)
            Text("\(story.minutesAgo < 60 ? "\(story.minutesAgo) MIN" : "\(story.minutesAgo / 60) HR") AGO").foregroundStyle(Theme.muted)
            if story.forYou {
                Text("FOR YOU · \(story.score)%")
                    .foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.gradient))
            }
        }
        .font(.system(size: 10.5, weight: .bold))
        .tracking(0.8)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

struct StoryActions: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let story: Story

    var body: some View {
        let tracked = store.state.finds.contains { $0.itemID == story.item.id }
        let agent = store.agent(story.agentID)
        HStack(spacing: 8) {
            if let agent, !(story.match?.notInSize ?? false) {
                if tracked {
                    Button { router.openInFinds(story, store: store) } label: {
                        IconText(icon: "chevron.right", text: "View in Finds", trailing: true)
                    }
                    .buttonStyle(GhostButton())
                    .tint(Theme.green)
                } else {
                    Button("Send to \(agent.name)") {
                        store.ensureFind(agentID: agent.id, itemID: story.item.id)
                        store.log("You sent \(story.item.title) to \(agent.name)")
                        Analytics.track(.storySentToAgent, ["category": story.item.category.rawValue])
                        router.say("Sent to \(agent.name). It's in your Finds.")
                    }.buttonStyle(PrimaryButton())
                }
            } else if story.agentID == nil {
                Button("Deploy a \(story.item.category.info.label.lowercased()) agent") {
                    router.deployPrefill = .category(story.item.category)
                    router.sheet = .deploy
                }.buttonStyle(GhostButton())
            }
            Button {
                router.sheet = .share(itemID: story.item.id, friendID: nil, suggestion: false)
            } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(GhostButton()).frame(width: 54)
                .accessibilityLabel("Share with friends")
        }
    }
}

struct LeadStoryView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let story: Story
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Plate(item: story.item, label: story.isLive ? "AVAILABLE NOW" : store.whenLabel(story.item), height: 230, lead: true)
                    .shadow(color: Theme.cyan.opacity(0.35), radius: 24, y: 12)
                Kicker(story: story)
                Text(story.headline)
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-0.8)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(story.dek).font(.callout).foregroundStyle(Theme.muted)
            }
            .contentShape(Rectangle())
            .onTapGesture { router.openInFinds(story, store: store) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens it in Finds")
            if story.forYou, let why = story.match?.why.first {
                (Text("Why it's here: ").foregroundStyle(Theme.muted) + Text(why).foregroundStyle(Theme.ink).bold()).font(.footnote)
            }
            StoryActions(story: story)
        }
        .padding(.bottom, 8)
    }
}

struct StoryRow: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let story: Story
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Plate(item: story.item, label: story.isLive ? "NOW" : store.whenLabel(story.item), live: story.isLive, height: 104)
                .frame(width: 104)
                .contentShape(Rectangle())
                .onTapGesture { router.openInFinds(story, store: store) }
            VStack(alignment: .leading, spacing: 7) {
                VStack(alignment: .leading, spacing: 7) {
                    Kicker(story: story)
                    Text(story.headline).font(.headline).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    Text(story.dek).font(.footnote).foregroundStyle(Theme.muted).lineLimit(3)
                    if story.forYou, let why = story.match?.why.first {
                        Text(why).font(.caption.weight(.semibold)).foregroundStyle(Theme.green).lineLimit(2)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { router.openInFinds(story, store: store) }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens it in Finds")
                StoryActions(story: story)
            }
        }
        .padding(.vertical, 4)
    }
}

struct TrendingView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        let trending = Catalog.all
            .filter { !store.isSoldOut($0) && $0.priceKnown && $0.price > 0 && $0.market > $0.price }
            .sorted { $0.market / $0.price > $1.market / $1.price }
            .prefix(5)
        VStack(alignment: .leading, spacing: 10) {
            Text("TRENDING BY MARKET HEAT").font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.muted)
            ForEach(Array(trending.enumerated()), id: \.element.id) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(i + 1)").font(.system(size: 24, weight: .heavy)).gradientText().frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        Text("+\(Int(safe: ((item.market / item.price - 1) * 100).rounded()))% vs asking · \(item.category.info.label)")
                            .font(.caption.monospaced()).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .glassCard()
    }
}

struct AwayCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let report: AwayReport
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHILE YOU WERE AWAY · \(report.minutes >= 90 ? "\(Int(safe: (Double(report.minutes) / 60).rounded())) HOURS" : "\(report.minutes) MINUTES")")
                .font(.caption.weight(.bold)).tracking(1).gradientText()
            Text(report.sweeps > 0
                 ? "Your squad ran \(report.sweeps) sweep\(report.sweeps == 1 ? "" : "s"), checked about \(report.checked) listings and found \(report.found) new thing\(report.found == 1 ? "" : "s") for you.\(report.restocks > 0 ? " One of your watched items restocked." : "")\(report.bought > 0 ? " Auto-buy landed \(report.bought)." : "")"
                 : "Your squad kept searching the web and found \(report.found) new thing\(report.found == 1 ? "" : "s") for you.\(report.restocks > 0 ? " Something you're watching restocked." : "")")
                .font(.subheadline).foregroundStyle(Theme.ink)
            HStack {
                Button("\(report.notes) notification\(report.notes == 1 ? "" : "s")") { router.sheet = .inbox }.buttonStyle(PrimaryButton())
                Button("Dismiss") { store.state.awayReport = nil; store.save() }.buttonStyle(GhostButton())
            }
        }
        .glassCard(highlighted: true)
    }
}
