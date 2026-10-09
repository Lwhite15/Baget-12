import SwiftUI
import UserNotifications

struct InboxView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Inbox").tag(0)
                    Text("Background and alerts").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 10)
                if tab == 0 { inbox } else { settings }
            }
            .background(LitBackground())
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if tab == 0 && store.unreadCount > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Mark all read") {
                            store.markRead(store.state.notes.filter { !$0.read }.map(\.id))
                            Notifier.setBadge(0)
                        }
                    }
                }
            }
        }
    }

    private var inbox: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if store.state.notes.isEmpty {
                    EmptyCard(text: "Nothing yet. When your squad finds something, it'll text you here.")
                }
                ForEach(store.state.notes) { n in
                    Button { open(n) } label: {
                        HStack(alignment: .top, spacing: 11) {
                            NoteIcon(note: n)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(store.noteSender(n)).font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink)
                                    Spacer()
                                    Text("\(Fmt.ago(n.date))\(n.heldForMorning ? " · held for morning" : "")").font(.caption2).foregroundStyle(Theme.muted)
                                }
                                Text(n.body).font(.subheadline).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                            }
                        }
                        .padding(12)
                        .background(n.read ? Theme.glass : Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(n.read ? Theme.line : Theme.accent.opacity(0.45)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
    }

    private var settings: some View {
        AlertSettingsForm(onSimulate: { tab = 0 })
    }

    private func open(_ n: AppNote) {
        store.markRead([n.id])
        Analytics.track(.notificationOpened, ["kind": n.kind.rawValue, "inApp": true])
        if n.friendID != nil { router.tab = .friends; dismiss(); return }
        if n.kind == .digest { router.tab = .live; dismiss(); return }   // Today's Drop
        if let fid = n.findID, store.state.finds.contains(where: { $0.id == fid }) {
            router.focusFind = fid
            router.tab = .finds
        } else {
            router.tab = n.kind == .learned ? .squad : .finds
        }
        dismiss()
    }
}

/// How often agents search, quiet hours, what they text you about, and metrics.
struct AlertSettingsForm: View {
    @Environment(AppStore.self) private var store
    var onSimulate: () -> Void = {}
    @State private var permission: UNAuthorizationStatus = .notDetermined
    @AppStorage("baget.analyticsEnabled") private var metricsOn = true

    var body: some View {
        @Bindable var store = store
        return Form {
            if permission == .denied {
                Section {
                    Text("Notifications are off for Baget. Turn them on in iPhone Settings so your squad can text you.").font(.footnote)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
            Section {
                Picker("Each agent searches the web", selection: $store.state.settings.sweepMinutes) {
                    Text("Every hour").tag(60)
                    Text("Every 3 hours").tag(180)
                    Text("Every 6 hours").tag(360)
                    Text("Twice a day").tag(720)
                    Text("Once a day").tag(1440)
                }
            } footer: {
                Text(store.isCloud
                     ? "Your squad searches on our servers even when your phone is off. Each search costs a little, so less often is cheaper. You can always pull down on Live to check now."
                     : "In the sample tour, sweeps are simulated each time you come back to the app.")
            }
            Section {
                Toggle(isOn: $store.state.settings.quietHours) {
                    VStack(alignment: .leading) {
                        Text("Quiet hours, 10pm to 8am")
                        Text("Non-urgent texts wait for morning. Restocks, purchases and drops starting within 90 minutes still come through.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
            Section("Text me about") {
                ForEach(NoteGroup.allCases) { g in
                    Toggle(g.label, isOn: Binding(
                        get: { store.state.settings.groups.contains(g) },
                        set: { on in
                            if on { store.state.settings.groups.insert(g) } else { store.state.settings.groups.remove(g) }
                        }))
                }
            }
            Section {
                Toggle(isOn: $metricsOn) {
                    VStack(alignment: .leading) {
                        Text("Share anonymous usage metrics")
                        Text(Analytics.configured ? "Sent with a random install ID, never your name or email." : "No backend set up yet, so metrics stay on this phone.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            } header: { Text("Privacy") }
            if !store.isCloud {
                Section {
                    Button("Simulate 3 hours away") {
                        store.catchUp(minutes: 180)
                        Analytics.track(.backgroundSimulated, [:])
                        onSimulate()
                    }
                } header: { Text("Try it") } footer: {
                    Text("Fast-forwards three hours of background sweeps so you can see what your squad does while you're gone. Each agent's texting style is set on its card in Squad.")
                }
            }
        }
        .tint(Theme.cyan)
        .scrollContentBackground(.hidden)
        .onChange(of: store.state.settings) { _, _ in store.save() }
        .onChange(of: metricsOn) { _, on in Analytics.enabled = on }
        .task { permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    }
}

struct CustomizeBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var newSection = ""
    @State private var error: String?

    var body: some View {
        @Bindable var store = store
        let hidden = LiveTab.presets.filter { p in !store.state.liveTabs.contains { $0.id == p.id } }
        NavigationStack {
            List {
                Section {
                    ForEach(store.state.liveTabs) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.label).font(.body.weight(.semibold))
                            Text(describe(t)).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    .onMove { from, to in store.state.liveTabs.move(fromOffsets: from, toOffset: to); store.save() }
                    .onDelete { idx in
                        guard store.state.liveTabs.count > idx.count else { return }
                        store.state.liveTabs.remove(atOffsets: idx); store.save()
                    }
                } header: { Text("Your sections, in your order") } footer: {
                    Text("Drag the handles to reorder. Swipe left to remove. Don't care about shoes or clothes? Remove them.")
                }

                Section {
                    HStack {
                        TextField("Anything: vinyl, Porsche, Chrome Hearts", text: $newSection)
                            .textInputAutocapitalization(.never)
                        Button("Add") { add() }.bold()
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(Theme.hot) }
                } header: { Text("Add your own section") } footer: {
                    Text("It shows every story that matches, with your agents' picks first.")
                }

                if !hidden.isEmpty {
                    Section("Add back") {
                        ForEach(hidden) { p in
                            Button { store.state.liveTabs.append(p); store.save() } label: { Label(p.label, systemImage: "plus.circle.fill") }
                        }
                    }
                }
                Section {
                    Button("Restore the default bar") { store.state.liveTabs = LiveTab.presets; store.save() }
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(LitBackground())
            .navigationTitle("Customize your bar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func describe(_ t: LiveTab) -> String {
        switch t.kind {
        case .forYou: return "Ranked by what your squad knows you like"
        case .latest: return "Everything, newest first"
        case .category: return "Category"
        case .custom(let q): return "Your section · matches “\(q)”"
        }
    }

    private func add() {
        let q = newSection.trimmingCharacters(in: .whitespaces)
        guard !TextMatch.words(q).isEmpty else { error = "Type what this section should show, like “vinyl” or “Porsche”."; return }
        guard !store.state.liveTabs.contains(where: { TextMatch.norm($0.label) == TextMatch.norm(q) }) else { error = "You already have that section."; return }
        error = nil
        let label = q.capitalized
        store.state.liveTabs.append(LiveTab(id: "c" + UUID().uuidString.prefix(6), kind: .custom(q), label: label))
        store.save()
        Analytics.track(.customSectionAdded, ["words": TextMatch.words(q).count])
        let n = Catalog.all.filter { TextMatch.matches($0, query: q) }.count
        router.say(n > 0 ? "Added \(label) · \(n) stor\(n == 1 ? "y" : "ies") today" : "Added \(label). Deploy an agent to hunt it.")
        newSection = ""
    }
}
