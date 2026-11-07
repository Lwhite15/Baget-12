import SwiftUI

/// The Scouts tab: build scouts, see what each one is doing right now, and tune them.
struct SquadView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your scouts").font(.system(size: 28, weight: .heavy)).tracking(-0.6).foregroundStyle(Theme.ink)
                    Text("They hunt, watch prices and track release dates around the clock.").font(.footnote).foregroundStyle(Theme.muted)
                }
                .padding(.top, 4)
                Button { router.sheet = .newScout; Analytics.track(.huntStarted, ["from": "scouts", "step": "open"]) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus").font(.title2.weight(.heavy))
                            .frame(width: 42, height: 42).background(Theme.accentInk.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Build a scout").font(.headline.weight(.heavy))
                            Text("Tell it what you're into. Takes 30 seconds.").font(.caption.weight(.semibold)).opacity(0.8)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.accentInk)
                    .padding(14)
                    .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                HuntDoneCard()
                ForEach(store.state.agents) { a in ScoutSummaryCard(agent: a) }
                Button { router.sheet = .newScout } label: {
                    VStack(spacing: 3) {
                        Text(store.state.agents.isEmpty ? String(localized: "+ Your first scout") : String(localized: "+ Add another scout"))
                            .font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                        Text("Vintage watches? Vinyl? A grail you can't find?").font(.caption).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity).padding(16)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                }
                .buttonStyle(.plain)
                HStack(spacing: 8) {
                    Button { router.sheet = .taste } label: { IconText(icon: "brain.head.profile", text: String(localized: "What Baget knows")) }
                        .buttonStyle(GhostButton())
                    Button { router.deployPrefill = nil; router.sheet = .deploy } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "slider.horizontal.3").imageScale(.small)
                            Text("Detailed hunt setup").lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    .buttonStyle(GhostButton())
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("SCOUT ACTIVITY").font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.muted)
                    if store.state.log.isEmpty { Text("No activity yet.").font(.footnote).foregroundStyle(Theme.muted) }
                    // The newest few only; older events roll off as new ones arrive.
                    ForEach(store.state.log.prefix(6)) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Fmt.ago(l.date)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.muted).frame(width: 64, alignment: .leading)
                            Text(l.text).font(.footnote).foregroundStyle(Theme.ink).lineLimit(2)
                        }
                    }
                }
                .glassCard()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .dismissKeyboardOnTap()
    }
}

/// One scout on the Scouts tab: what it's doing right now, what it hunts, its next release, and Tune.
struct ScoutSummaryCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let agent: Agent

    var body: some View {
        let mine = store.state.finds.filter { $0.agentID == agent.id }
        let watching = mine.filter { $0.watching && ($0.status == .open || $0.status == .liked) }.count
        let today = Set(store.drop?.ids ?? [])
        let picks = mine.filter { today.contains($0.id) }.count
        let next = mine.filter { $0.status == .open || $0.status == .liked || $0.watching }
            .compactMap { f in Catalog.item(f.itemID).flatMap { i in i.dropAt.flatMap { $0 > .now ? (item: i, at: $0) : nil } } }
            .min { $0.at < $1.at }
        let chips = ScoutChips.huntsFor(agent)
        Button { router.sheet = .tune(agent.id) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 11) {
                    AgentAvatarView(agent: agent, size: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.name).font(.headline.weight(.heavy)).foregroundStyle(Theme.ink).lineLimit(2).multilineTextAlignment(.leading)
                        Text(agent.mission.label).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text("Tune").font(.footnote.weight(.heavy)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.5)))
                }
                HStack(spacing: 12) {
                    if agent.isOff {
                        Label("Off", systemImage: "moon.zzz.fill").foregroundStyle(Theme.muted)
                    } else {
                        stat("\(watching)", String(localized: "watching"))
                        stat("\(picks)", picks == 1 ? String(localized: "pick today") : String(localized: "picks today"))
                        stat("\(mine.filter { $0.status != .removed }.count)", String(localized: "finds"))
                    }
                }
                .font(.caption.weight(.semibold))
                if !chips.isEmpty || (Sizes.required(agent) && !Sizes.has(agent)) {
                    FlowRow {
                        ForEach(chips.prefix(6), id: \.self) { Tag(text: $0) }
                        if Sizes.required(agent) && !Sizes.has(agent) { Tag(text: String(localized: "+ Add your size"), tint: Theme.warn) }
                        else if !agent.size.isEmpty { Tag(text: agent.size) }
                    }
                }
                if let n = next {
                    Label("\(n.item.title) · \(ReminderSheet.short(n.at))", systemImage: "timer")
                        .font(.caption.weight(.bold)).foregroundStyle(Theme.warn).lineLimit(1)
                }
            }
            .padding(13)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
            .opacity(agent.isOff ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Tune \(agent.name)")
    }

    private func stat(_ n: String, _ label: String) -> some View {
        (Text(n).foregroundStyle(Theme.ink).bold() + Text(" \(label)").foregroundStyle(Theme.muted))
    }
}

enum ScoutChips {
    /// What a scout hunts for, as people would say it ("season:aw26" shows as "aw26"), without repeats.
    static func huntsFor(_ a: Agent) -> [String] {
        (a.keywords + a.style.makers + a.style.traits + a.style.creators).map { t in
            t.split(separator: ":", maxSplits: 1).count == 2 ? String(t.split(separator: ":", maxSplits: 1)[1]) : t
        }.reduce(into: [String]()) { out, t in if !out.contains(where: { $0.lowercased() == t.lowercased() }) { out.append(t) } }
    }
}

/// Tune a scout in one place: what it hunts for and skips, size, budget, what it watches, and its settings.
struct TuneScoutView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    let agentID: String
    @State private var adding = ""
    @State private var skipping = ""
    @State private var size = ""
    @State private var budget: Double = 0

    var body: some View {
        NavigationStack {
            if let agent = store.agent(agentID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 11) {
                            AgentAvatarView(agent: agent, size: 44)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.name).font(.headline.weight(.heavy)).foregroundStyle(Theme.ink)
                                Text("Changes apply on its next hunt").font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                        section(String(localized: "HUNTS FOR")) {
                            FlowRow {
                                ForEach(ScoutChips.huntsFor(agent), id: \.self) { t in chip(t, Theme.green) { remove(t, from: agent) } }
                            }
                            addField(String(localized: "Add a brand, model, color, material…"), text: $adding) { add(adding, to: agent); adding = "" }
                        }
                        section(String(localized: "SKIPS")) {
                            // What you clearly said no to (a skip you added, or "Not into the brand"), not every small pass signal.
                            let skips = agent.learned.filter { $0.value <= -3 }.sorted { $0.value < $1.value }.map(\.key)
                            if skips.isEmpty { Text("Nothing yet. Passing on cards teaches it what to skip.").font(.caption).foregroundStyle(Theme.muted) }
                            FlowRow { ForEach(skips, id: \.self) { k in chip(k, Theme.hot) { store.unlearn(agent.id, key: k) } } }
                            addField(String(localized: "Add something to skip"), text: $skipping) { skip(skipping, agent); skipping = "" }
                        }
                        if agent.mission.info.sizeRequired {
                            section((agent.mission.info.sizeLabel ?? String(localized: "Size")).uppercased()) {
                                addField(String(localized: "e.g. M, 32x30, 10.5"), text: $size, button: String(localized: "Save")) {
                                    store.setSize(agent.id, size); router.say(String(localized: "\(agent.name) will stick to size \(size)"))
                                }
                            }
                        }
                        section(budget > 0 ? String(localized: "BUDGET · UP TO \(Fmt.money(budget))") : String(localized: "BUDGET · ANY PRICE")) {
                            Slider(value: $budget, in: 0...2000, step: 25, onEditingChanged: { editing in
                                if !editing { var a = agent; a.priceNote = budget; store.update(a) }
                            })
                            .tint(Theme.cyan)
                            Text("Slide to 0 for any price.").font(.caption2).foregroundStyle(Theme.muted)
                        }
                        section(String(localized: "WATCHES FOR")) {
                            FlowRow {
                                ForEach([String(localized: "Price drops"), String(localized: "Restocks"), String(localized: "Release dates")], id: \.self) { Tag(text: $0, tint: Theme.green) }
                            }
                            Text("On everything you like or watch. Swipe right on a card, or up to watch without liking.")
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                        Button { router.sheet = .chat(agent.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                                Text("Or just tell it: ").bold() + Text("\"more vintage, less new season\"").foregroundStyle(Theme.muted)
                                Spacer(minLength: 0)
                            }
                            .font(.footnote).foregroundStyle(Theme.ink)
                            .padding(12)
                            .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
                        }
                        .buttonStyle(.plain)
                        Text("MORE SETTINGS").font(.caption.weight(.heavy)).tracking(1.2).foregroundStyle(Theme.muted)
                        AgentCard(agent: agent, inTune: true)
                    }
                    .padding(16)
                }
                .background(LitBackground())
                .navigationTitle("Tune")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .onAppear { size = agent.size; budget = agent.priceNote }
            } else {
                Text("This scout was deleted.").foregroundStyle(Theme.muted).onAppear { dismiss() }
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.heavy)).tracking(1.2).foregroundStyle(Theme.muted)
            content()
        }
    }

    private func chip(_ t: String, _ tint: Color, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Text(t).font(.footnote.weight(.semibold))
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .accessibilityLabel("Remove \(t)")
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(tint.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
    }

    private func addField(_ prompt: String, text: Binding<String>, button: String = String(localized: "Add"), action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            TextField(prompt, text: text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
                .onSubmit { if !text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty { action() } }
            Button(button) { if !text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty { action() } }
                .font(.footnote.weight(.bold)).foregroundStyle(Theme.accent)
        }
    }

    private func add(_ raw: String, to agent: Agent) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !ScoutChips.huntsFor(agent).contains(where: { $0.lowercased() == t.lowercased() }) else { return }
        var a = agent
        a.keywords.append(String(t.prefix(40)))
        a.learned[t.lowercased()] = nil
        store.update(a)
        Analytics.track(.agentSettingChanged, ["setting": "hunts_for"])
    }

    private func remove(_ t: String, from agent: Agent) {
        var a = agent
        let match: (String) -> Bool = { k in
            let shown = k.split(separator: ":", maxSplits: 1).count == 2 ? String(k.split(separator: ":", maxSplits: 1)[1]) : k
            return shown.lowercased() == t.lowercased()
        }
        a.keywords.removeAll(where: match)
        a.style.makers.removeAll(where: match)
        a.style.traits.removeAll(where: match)
        a.style.creators.removeAll(where: match)
        store.update(a)
        Analytics.track(.agentSettingChanged, ["setting": "hunts_for_removed"])
    }

    private func skip(_ raw: String, _ agent: Agent) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return }
        var a = agent
        a.learned[String(t.prefix(40))] = -3
        store.update(a)
        Analytics.track(.agentSettingChanged, ["setting": "skips"])
    }
}

struct AgentCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let agent: Agent
    /// Inside Tune: what it hunts and skips are edited above, so they aren't repeated here.
    var inTune = false
    @State private var confirmRetire = false

    /// Over the Free limit: the server only sends the first scouts (oldest first, among those switched on), the rest wait.
    private var resting: Bool {
        guard store.isCloud, !store.isPro, store.plan != nil, !agent.isOff else { return false }
        let on = store.state.agents.filter { !$0.isOff }
        guard let i = on.firstIndex(where: { $0.id == agent.id }) else { return false }
        return i >= store.scoutLimit
    }

    var body: some View {
        let k = Matcher.intel(agent)
        let finds = store.state.finds.filter { $0.agentID == agent.id }.count
        let learned = agent.learned.filter { $0.value != 0 }.sorted { abs($0.value) > abs($1.value) }.prefix(8)
            .map { Learned(key: $0.key, weight: $0.value) }
        // Show "season:aw26" as "aw26": the part before the colon is for the scout, not for people.
        let styleTags = (agent.style.traits + agent.style.makers + agent.style.creators).map { t in
            t.split(separator: ":", maxSplits: 1).count == 2 ? String(t.split(separator: ":", maxSplits: 1)[1]) : t
        }.reduce(into: [String]()) { out, t in if !out.contains(t) { out.append(t) } }

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button { router.sheet = .agentIcon(agent.id) } label: { AgentAvatarView(agent: agent, size: 46) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Change \(agent.name)'s icon")
                VStack(alignment: .leading, spacing: 2) {
                    // The full name, on up to two lines; the Interest / Specific tag moves under it.
                    Text(agent.name).font(.title3.weight(.heavy)).foregroundStyle(Theme.ink)
                        .lineLimit(2).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        FocusTag(specific: agent.isSpecific)
                        Text("\(agent.mission.label) · \(finds) \(finds == 1 ? String(localized: "find") : String(localized: "finds"))")
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                Spacer()
                // Change or delete it, right from the top of its card.
                Menu {
                    Button { if store.isCloud { router.sheet = .chat(agent.id) } } label: { Label("Change what it hunts", systemImage: "pencil") }
                    Button { store.setOff(agent.id, !agent.isOff) } label: {
                        Label(agent.isOff ? String(localized: "Turn on") : String(localized: "Turn off"), systemImage: agent.isOff ? "play.fill" : "pause.fill")
                    }
                    Button(role: .destructive) { confirmRetire = true } label: { Label("Delete scout…", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.bold)).foregroundStyle(Theme.muted)
                        .frame(width: 34, height: 34).background(Theme.glass, in: Circle()).contentShape(Circle())
                }
                .accessibilityLabel("Change or delete \(agent.name)")
                VStack(alignment: .trailing, spacing: 2) {
                    Toggle("", isOn: Binding(get: { !agent.isOff }, set: { on in
                        store.setOff(agent.id, !on)
                        Analytics.track(.agentSettingChanged, ["setting": "on"])
                        router.say(on ? String(localized: "\(agent.name) is back on the hunt") : String(localized: "\(agent.name) is off. No searching, no texts."))
                    }))
                    .labelsHidden().tint(Theme.green)
                    .accessibilityLabel(agent.isOff ? String(localized: "Turn \(agent.name) on") : String(localized: "Turn \(agent.name) off"))
                    Text(agent.isOff ? "OFF" : "ON").font(.system(size: 9, weight: .bold)).tracking(1)
                        .foregroundStyle(agent.isOff ? Theme.muted : Theme.green)
                }
            }
            if resting {
                Button { router.sheet = .pro } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bed.double.fill").foregroundStyle(Theme.warn)
                        Text("Resting on Free, which includes \(store.scoutLimit) scouts. ").foregroundStyle(Theme.ink)
                            + Text(store.proTrial.map { String(localized: "Try Pro free for \(AppStore.spoken($0)) to wake it") } ?? String(localized: "Go Pro to wake it")).foregroundStyle(Theme.accent).bold()
                    }
                    .font(.footnote)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            if agent.isOff {
                Label("Off. Not searching or texting until you switch it back on.", systemImage: "moon.zzz.fill")
                    .font(.footnote).foregroundStyle(Theme.muted)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12))
            }

            if !inTune && !agent.keywords.isEmpty {
                FlowRow { ForEach(agent.keywords, id: \.self) { Tag(text: $0) } }
            }
            if !inTune && !styleTags.isEmpty {
                FlowRow { ForEach(styleTags, id: \.self) { Tag(text: $0, tint: Theme.green) } }
            }
            TasteBoardRow(agent: agent)
            Button {
                if store.isCloud { router.sheet = .chat(agent.id) } else { router.say(String(localized: "Sign in to talk to your scouts. They need the internet to search.")) }
            } label: { Label("Talk to \(agent.name)", systemImage: "bubble.left.and.text.bubble.right.fill") }
                .buttonStyle(PrimaryButton())
            if Sizes.required(agent) && !Sizes.has(agent) {
                (Text("Needs your size. ").bold().foregroundStyle(Theme.warn) + Text("I won't flag anything until I know it, so you only see things that fit.").foregroundStyle(Theme.ink))
                    .font(.footnote).padding(10)
                    .background(Theme.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }

            HStack {
                stat(agent.mission.info.sizeRequired ? (agent.mission.info.sizeLabel ?? String(localized: "Size")) : String(localized: "Mission"),
                     agent.mission.info.sizeRequired ? (agent.size.isEmpty ? String(localized: "Any") : agent.size) : agent.mission.label)
                stat(String(localized: "When it finds something"), agent.mode.short)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Taste profile \(k)% complete\(k < 70 ? " · rate finds so I learn faster" : "")").font(.caption).foregroundStyle(Theme.muted)
                Meter(value: Double(k) / 100)
            }

            if inTune {
                EmptyView()
            } else if learned.isEmpty && agent.priceNote == 0 {
                Text("Nothing learned yet. Buy, watch or pass on finds and I'll pick up your taste.").font(.footnote).foregroundStyle(Theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What I've learned about you").font(.caption).foregroundStyle(Theme.muted)
                    FlowRow {
                        ForEach(learned) { l in
                            learnedChip(text: "\(l.weight > 0 ? "Likes" : "Not into") \(l.key)", like: l.weight > 0) { store.unlearn(agent.id, key: l.key) }
                        }
                        if agent.priceNote > 0 {
                            learnedChip(text: String(localized: "Prefers under \(Fmt.money(agent.priceNote))"), like: nil) { store.unlearn(agent.id, key: "__price") }
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
                Menu {
                    Picker("Texts from \(agent.name)", selection: binding(\.alertLevel, name: "alerts")) {
                        ForEach(AgentAlerts.allCases) { l in
                            Label { Text(l.label); Text(l.blurb) } icon: { Image(systemName: l.icon) }.tag(l)
                        }
                    }
                } label: { menuLabel(agent.alertLevel.short, icon: agent.alertLevel.icon) }
            }
            Button(role: .destructive) { confirmRetire = true } label: {
                Label("Delete \(agent.name)", systemImage: "trash").font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.hot).frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain).padding(.top, 2)
        }
        .glassCard()
        .opacity(agent.isOff ? 0.75 : 1)
        .confirmationDialog("Delete \(agent.name)?", isPresented: $confirmRetire, titleVisibility: .visible) {
            let mine = store.state.finds.filter { $0.agentID == agent.id && ($0.status == .open || $0.status == .liked) }.map(\.id)
            if !mine.isEmpty {
                Button("Delete it and clear its \(mine.count) finds", role: .destructive) {
                    store.removeFinds(mine)
                    store.retire(agent.id)
                    Analytics.track(.agentRetired, ["mission": agent.mission.label, "cleared": mine.count])
                    router.say(String(localized: "\(agent.name) and its finds are gone"))
                }
            }
            Button(mine.isEmpty ? String(localized: "Delete") : String(localized: "Delete it, keep its finds"), role: .destructive) {
                store.retire(agent.id)
                Analytics.track(.agentRetired, ["mission": agent.mission.label])
                router.say("\(agent.name) deleted")
            }
            if !agent.isOff {
                Button("Just turn it off") { store.setOff(agent.id, true); router.say(String(localized: "\(agent.name) is off")) }
            }
        } message: { Text("It stops hunting for good and what it learned is lost. You can clear its finds too, or keep them in Finds.") }
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
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.ink)
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
