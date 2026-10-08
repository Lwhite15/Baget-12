import SwiftUI
import Charts

struct SpendingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Date = .now

    private struct MonthTotal: Identifiable {
        let month: Date
        let total: Double
        var id: Date { month }
    }

    var body: some View {
        let months = store.lastMonths(6).map { MonthTotal(month: $0, total: store.monthTotal(Fmt.monthKey($0))) }
        let key = Fmt.monthKey(selected)
        let list = store.state.purchases.filter { Fmt.monthKey($0.date) == key }.sorted { $0.date > $1.date }
        let total = list.reduce(0) { $0 + $1.amount }
        let idx = months.firstIndex { Fmt.monthKey($0.month) == key }
        let prev = idx.flatMap { $0 > 0 ? months[$0 - 1].total : nil }
        let isNow = key == Fmt.monthKey(.now)
        let limits = store.state.agents.reduce(0) { $0 + $1.monthlyLimit }

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(selected.formatted(.dateTime.month(.wide).year()).uppercased())\(isNow ? " · SO FAR" : "")")
                            .font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.muted)
                        Text(Fmt.money(total)).font(.system(size: 44, weight: .semibold, design: .monospaced)).gradientText()
                        Text(subtitle(count: list.count, total: total, prev: prev, prevMonth: idx.flatMap { $0 > 0 ? months[$0 - 1].month : nil }, isNow: isNow, limits: limits))
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }

                    Chart(months) { m in
                        BarMark(x: .value("Month", m.month, unit: .month), y: .value("Spent", m.total), width: .ratio(0.55))
                            .foregroundStyle(Theme.barGradient)
                            .opacity(Fmt.monthKey(m.month) == key ? 1 : 0.4)
                            .cornerRadius(6)
                            .annotation(position: .top) {
                                if Fmt.monthKey(m.month) == key {
                                    Text(Fmt.money(m.total)).font(.caption2.monospaced()).foregroundStyle(Theme.ink)
                                }
                            }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .month)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated)).foregroundStyle(Theme.muted)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { v in
                            AxisGridLine().foregroundStyle(Theme.line)
                            AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.money(d)).foregroundStyle(Theme.muted) } }
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { g in
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .onTapGesture { p in
                                    guard let plot = proxy.plotFrame else { return }
                                    let x = p.x - g[plot].origin.x
                                    if let d: Date = proxy.value(atX: x) {
                                        let target = Fmt.monthKey(d)
                                        if let m = months.first(where: { Fmt.monthKey($0.month) == target }) { selected = m.month }
                                    }
                                }
                        }
                    }
                    .frame(height: 190)
                    .accessibilityLabel("Spending for the last six months")

                    Picker("Month", selection: Binding(get: { key }, set: { k in if let m = months.first(where: { Fmt.monthKey($0.month) == k }) { selected = m.month } })) {
                        ForEach(months) { m in Text(m.month.formatted(.dateTime.month(.abbreviated))).tag(Fmt.monthKey(m.month)) }
                    }
                    .pickerStyle(.segmented)

                    if list.isEmpty {
                        EmptyCard(text: "No purchases in \(selected.formatted(.dateTime.month(.wide))).")
                    } else {
                        breakdown(title: "BY AGENT", rows: group(list) { store.agent($0.agentID)?.name ?? "Retired agent" }, total: total)
                        breakdown(title: "BY CATEGORY", rows: group(list) { $0.category.info.label }, total: total)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("PURCHASES").font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.muted).padding(.bottom, 6)
                            ForEach(list) { p in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(p.date.formatted(.dateTime.month(.abbreviated).day())).font(.caption.monospaced()).foregroundStyle(Theme.muted).frame(width: 50, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(p.title).font(.subheadline).foregroundStyle(Theme.ink)
                                        Text("\(store.agent(p.agentID)?.name ?? (p.agentName.isEmpty ? "Retired agent" : p.agentName))\(p.isSample ? " · sample history" : "")").font(.caption).foregroundStyle(Theme.muted)
                                    }
                                    Spacer()
                                    Text(Fmt.money(p.amount)).font(.subheadline.monospaced().weight(.semibold)).foregroundStyle(Theme.ink)
                                }
                                .padding(.vertical, 9)
                                Divider().overlay(Theme.line)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(LitBackground())
            .navigationTitle("Monthly spending")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { Analytics.track(.spendingViewed, [:]) }
        }
    }

    private func subtitle(count: Int, total: Double, prev: Double?, prevMonth: Date?, isNow: Bool, limits: Double) -> String {
        var s = "\(count) purchase\(count == 1 ? "" : "s")"
        if let prev, prev > 0, let prevMonth {
            let d = Int(safe: ((total / prev - 1) * 100).rounded())
            s += " · \(d > 0 ? "+" : "")\(d)% vs \(prevMonth.formatted(.dateTime.month(.abbreviated)))"
        }
        if isNow && limits > 0 { s += " · \(Int(safe: (total / limits * 100).rounded()))% of your squad's combined \(Fmt.money(limits)) limit" }
        return s
    }

    private func group(_ list: [Purchase], by key: (Purchase) -> String) -> [Row] {
        Dictionary(grouping: list, by: key).map { Row(name: $0.key, amount: $0.value.reduce(0) { $0 + $1.amount }) }.sorted { $0.amount > $1.amount }
    }

    private struct Row: Identifiable {
        let name: String
        let amount: Double
        var id: String { name }
    }

    private func breakdown(title: String, rows: [Row], total: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.muted)
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Text(row.name).font(.footnote).foregroundStyle(Theme.ink).frame(width: 130, alignment: .leading).lineLimit(1)
                    Meter(value: total > 0 ? row.amount / total : 0)
                    Text(Fmt.money(row.amount)).font(.footnote.monospaced().weight(.semibold)).foregroundStyle(Theme.ink)
                }
            }
        }
    }
}
