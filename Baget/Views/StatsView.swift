import SwiftUI
import Charts

/// The owner's dashboard: users, activity, what people do with finds, and what Claude costs.
/// Only accounts on the server's admin list can load it; everyone else gets "not allowed" from the server.
struct AdminStats: Decodable {
    struct Users: Decodable { let total, today, week, month: Int }
    struct Active: Decodable { let day, week, month: Int }
    struct Retention: Decodable { let day1Base, day1, day7Base, day7: Int }
    struct Day: Decodable, Identifiable {
        let day: String
        let signups, active: Int
        let cost: Double
        var id: String { day }
        var date: Date { Self.parser.date(from: day) ?? .now }
        static let parser: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()
    }
    struct Agents: Decodable { let total, on, withAgents: Int }
    struct Finds: Decodable { let total, week, liked, passed, bought: Int }
    struct Shopping: Decodable { let buyTapsWeek, purchases: Int; let purchaseTotal: Double }
    struct Engagement: Decodable { let chatsWeek, swipesWeek, textsWeek, quietWeek, openedWeek: Int }
    struct ClaudeSpend: Decodable {
        let today, week, month, cacheSavedWeek: Double
        let callsWeek, sweepsDay, failedDay: Int
        let byFeature: [String: Double]
        let lastError: String?
    }
    let users: Users
    let active: Active
    let retention: Retention
    let daily: [Day]
    let agents: Agents
    let finds: Finds
    let shopping: Shopping
    let engagement: Engagement
    let claude: ClaudeSpend
}

struct StatsView: View {
    @State private var stats: AdminStats?
    @State private var error: String?
    @State private var loading = false
    @State private var chart = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let s = stats {
                    content(s)
                } else if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.hot).glassCard()
                } else {
                    HStack { Spacer(); ProgressView().tint(Theme.cyan); Spacer() }.padding(.top, 60)
                }
                Text("Downloads and App Store page views are in the App Store Connect app (Trends). Usage counts come from devices with analytics on; spend uses Claude list prices.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            .padding(16)
        }
        .background(LitBackground())
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    @MainActor private func load() async {
        loading = true
        defer { loading = false }
        do {
            stats = try await Backend.shared.rpc("admin_stats", as: AdminStats.self)
            error = nil
        } catch {
            self.error = "Couldn't load stats. \((error as? LocalizedError)?.errorDescription ?? "")"
        }
    }

    @ViewBuilder private func content(_ s: AdminStats) -> some View {
        section("People") {
            grid([
                ("Users", "\(s.users.total)", nil),
                ("New today", "\(s.users.today)", nil),
                ("New this week", "\(s.users.week)", nil),
                ("New this month", "\(s.users.month)", nil),
            ])
            grid([
                ("Active today", "\(s.active.day)", nil),
                ("Active this week", "\(s.active.week)", nil),
                ("Came back next day", pct(s.retention.day1, of: s.retention.day1Base), "of \(s.retention.day1Base)"),
                ("Still here after a week", pct(s.retention.day7, of: s.retention.day7Base), "of \(s.retention.day7Base)"),
            ])
        }

        section("Last 14 days") {
            Picker("", selection: $chart) {
                Text("Sign-ups").tag(0)
                Text("Active").tag(1)
                Text("Claude $").tag(2)
            }
            .pickerStyle(.segmented)
            Chart(s.daily) { d in
                BarMark(x: .value("Day", d.date, unit: .day),
                        y: .value(chart == 0 ? "Sign-ups" : chart == 1 ? "Active" : "Dollars",
                                  chart == 0 ? Double(d.signups) : chart == 1 ? Double(d.active) : d.cost))
                    .foregroundStyle(Theme.barGradient)
                    .cornerRadius(3)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 3)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .frame(height: 170)
        }

        section("Agents and finds") {
            grid([
                ("Agents", "\(s.agents.total)", "\(s.agents.on) on"),
                ("People with agents", "\(s.agents.withAgents)", nil),
                ("Finds", "\(s.finds.total)", "\(s.finds.week) this week"),
                ("Like rate", pct(s.finds.liked, of: s.finds.liked + s.finds.passed), "\(s.finds.liked) liked · \(s.finds.passed) passed"),
            ])
            grid([
                ("Buy taps (week)", "\(s.shopping.buyTapsWeek)", nil),
                ("Purchases", "\(s.shopping.purchases)", s.shopping.purchaseTotal > 0 ? Fmt.money(s.shopping.purchaseTotal) : nil),
                ("Chats (week)", "\(s.engagement.chatsWeek)", nil),
                ("Likes and passes (week)", "\(s.engagement.swipesWeek)", nil),
            ])
        }

        section("Notifications this week") {
            grid([
                ("Texts sent", "\(s.engagement.textsWeek)", nil),
                ("Opened", "\(s.engagement.openedWeek)", pct(s.engagement.openedWeek, of: s.engagement.textsWeek)),
                ("Kept quiet", "\(s.engagement.quietWeek)", "by texting settings"),
            ])
        }

        section("Claude spend") {
            grid([
                ("Today", money(s.claude.today), nil),
                ("This week", money(s.claude.week), "\(s.claude.callsWeek) calls"),
                ("Last 30 days", money(s.claude.month), nil),
                ("Saved by caching", money(s.claude.cacheSavedWeek), "this week"),
            ])
            if !s.claude.byFeature.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("THIS WEEK BY FEATURE").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted)
                    ForEach(s.claude.byFeature.sorted { $0.value > $1.value }, id: \.key) { k, v in
                        HStack {
                            Text(k.capitalized).font(.subheadline).foregroundStyle(Theme.ink)
                            Spacer()
                            Text(money(v)).font(.subheadline.monospaced()).foregroundStyle(Theme.ink)
                        }
                    }
                }
            }
            let failed = s.claude.failedDay
            HStack(spacing: 6) {
                Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(failed == 0 ? Theme.green : Theme.warn)
                Text(failed == 0 ? "\(s.claude.sweepsDay) sweeps in the last 24h, all fine"
                                 : "\(failed) of \(s.claude.sweepsDay) sweeps failed in the last 24h")
                    .font(.footnote).foregroundStyle(Theme.ink)
            }
            if failed > 0, let e = s.claude.lastError { Text(e).font(.caption).foregroundStyle(Theme.muted) }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(Theme.ink)
            body()
        }
        .glassCard()
    }

    private func grid(_ cells: [(String, String, String?)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], spacing: 12) {
            ForEach(cells, id: \.0) { label, value, sub in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(value).font(.title2.weight(.heavy).monospacedDigit()).foregroundStyle(Theme.ink)
                    if let sub { Text(sub).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1) }
                }
            }
        }
    }

    private func pct(_ n: Int, of d: Int) -> String { d == 0 ? "–" : "\(Int((Double(n) / Double(d) * 100).rounded()))%" }
    private func money(_ v: Double) -> String { v < 10 ? String(format: "$%.2f", v) : String(format: "$%.0f", v) }
}
