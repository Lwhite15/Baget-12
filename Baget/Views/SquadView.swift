import SwiftUI

struct SquadView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionTitle(text: "Your squad")
                    Button {
                        router.deployPrefill = nil
                        router.sheet = .deploy
                    } label: { Label("Deploy", systemImage: "plus") }
                        .buttonStyle(PrimaryButton()).frame(width: 120)
                }
                if store.state.agents.isEmpty {
                    EmptyCard(text: "No agents yet. Deploy one to start hunting.")
                }
                ForEach(store.state.agents) { a in AgentCard(agent: a) }

                VStack(alignment: .leading, spacing: 8) {
                    Text("SQUAD ACTIVITY").font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.muted)
                    if store.state.log.isEmpty { Text("No activity yet.").font(.footnote).foregroundStyle(Theme.muted) }
                    ForEach(store.state.log.prefix(20)) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(l.date.formatted(date: .omitted, time: .shortened)).font(.caption2.monospaced()).foregroundStyle(Theme.muted)
                            Text(l.text).font(.footnote).foregroundStyle(Theme.ink)
                        }
                    }
                }
                .glassCard()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }
}

struct AgentCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let agent: Agent
    @State private var confirmRetire = false

    var body: some View {
        let spent = store.spentThisMonth(agent)
        let used = agent.monthlyLimit > 0 ? spent / agent.monthlyLimit : 0
        let k = Matcher.intel(agent)
        let finds = store.state.finds.filter { $0.agentID == agent.id }.count
        let learned = agent.learned.filter { $0.value != 0 }.sorted { abs($0.value) > abs($1.value) }.prefix(8)
            .map { Learned(key: $0.key, weight: $0.value) }
        let styleTags = agent.style.traits + agent.style.makers + agent.style.creators

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(.title3.weight(.heavy)).foregroundStyle(Theme.ink)
                    Text("\(agent.mission.label) · \(finds) find\(finds == 1 ? "" : "s")").font(.caption.monospaced()).foregroundStyle(Theme.muted)
                }
                Spacer()
                Tag(text: agent.mode.short, tint: agent.mode == .auto ? Theme.warn : agent.mode == .ask ? Theme.accent : Theme.muted)
            }

            if !agent.keywords.isEmpty {
                FlowRow { ForEach(agent.keywords, id: \.self) { Tag(text: $0) } }
            }
            if !styleTags.isEmpty {
                FlowRow { ForEach(styleTags, id: \.self) { Tag(text: $0, tint: Theme.green) } }
            }
            TasteBoardRow(agent: agent)
            Button {
                if store.isCloud { router.sheet = .chat(agent.id) } else { router.say("Sign in to talk to your agents. They need the internet to search.") }
            } label: { Label("Talk to \(agent.name)", systemImage: "bubble.left.and.text.bubble.right.fill") }
                .buttonStyle(PrimaryButton())
            if Sizes.required(agent) && !Sizes.has(agent) {
                (Text("Needs your size. ").bold().foregroundStyle(Theme.warn) + Text("I won't flag anything until I know it, so you only see things that fit.").foregroundStyle(Theme.ink))
                    .font(.footnote).padding(10)
                    .background(Theme.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }

            HStack {
                stat(agent.mission.info.sizeRequired ? (agent.mission.info.sizeLabel ?? "Size") : "Mission",
                     agent.mission.info.sizeRequired ? (agent.size.isEmpty ? "Any" : agent.size) : agent.mission.label)
                stat("Max per item", agent.maxPerItem > 0 ? Fmt.money(agent.maxPerItem) : "None")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(Fmt.money(spent)) of \(Fmt.money(agent.monthlyLimit)) this month").font(.caption).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("\(Fmt.money(store.remaining(agent))) left").font(.caption.monospaced()).foregroundStyle(Theme.muted)
                }
                Meter(value: used, tint: AnyShapeStyle(used >= 1 ? Theme.hot : used >= 0.75 ? Theme.warn : Theme.green))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Taste profile \(k)% complete\(k < 70 ? " · rate finds so I learn faster" : "")").font(.caption).foregroundStyle(Theme.muted)
                Meter(value: Double(k) / 100)
            }

            if learned.isEmpty && agent.priceNote == 0 {
                Text("Nothing learned yet. Buy, watch or pass on finds and I'll pick up your taste.").font(.footnote).foregroundStyle(Theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What I've learned about you").font(.caption).foregroundStyle(Theme.muted)
                    FlowRow {
                        ForEach(learned) { l in
                            learnedChip(text: "\(l.weight > 0 ? "Likes" : "Not into") \(l.key)", like: l.weight > 0) { store.unlearn(agent.id, key: l.key) }
                        }
                        if agent.priceNote > 0 {
                            learnedChip(text: "Prefers under \(Fmt.money(agent.priceNote))", like: nil) { store.unlearn(agent.id, key: "__price") }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Menu {
                    Picker("Texting style", selection: binding(\.voice, name: "voice")) {
                        ForEach(Voice.allCases) { v in Text(v.label).tag(v) }
                    }
                } label: { menuLabel(agent.voice.label, icon: "message.fill") }
                Menu {
                    Picker("When it finds something", selection: binding(\.mode, name: "mode")) {
                        ForEach(BuyMode.allCases) { m in Text(m.label).tag(m) }
                    }
                } label: { menuLabel(agent.mode.short, icon: "cart.fill") }
                Button(role: .destructive) { confirmRetire = true } label: {
                    Image(systemName: "trash")
                }.buttonStyle(GhostButton()).frame(width: 54).accessibilityLabel("Retire \(agent.name)")
            }
        }
        .glassCard()
        .confirmationDialog("Retire \(agent.name)?", isPresented: $confirmRetire, titleVisibility: .visible) {
            Button("Retire", role: .destructive) {
                store.retire(agent.id)
                Analytics.track(.agentRetired, ["mission": agent.mission.label])
                router.say("\(agent.name) retired")
            }
        } message: { Text("Its finds stay in your Finds. Purchases stay in your spending history.") }
    }

    private func binding<T>(_ kp: WritableKeyPath<Agent, T>, name: String) -> Binding<T> {
        Binding(get: { agent[keyPath: kp] }, set: { new in
            var a = agent
            a[keyPath: kp] = new
            store.update(a)
            Analytics.track(.agentSettingChanged, ["setting": name])
        })
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted)
            Text(value).font(.system(.subheadline, design: .monospaced).weight(.semibold)).foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func menuLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink)
            .lineLimit(1)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(Theme.glass, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Theme.line))
    }

    private func learnedChip(text: String, like: Bool?, forget: @escaping () -> Void) -> some View {
        let tint = like == nil ? Theme.muted : (like! ? Theme.green : Theme.hot)
        return HStack(spacing: 4) {
            Text(text).font(.caption.weight(.medium))
            Button(action: forget) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .accessibilityLabel("Forget \(text)")
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.14)))
    }
}

private struct Learned: Identifiable {
    let key: String
    let weight: Int
    var id: String { key }
}
