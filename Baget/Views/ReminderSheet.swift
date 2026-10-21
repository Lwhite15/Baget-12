import SwiftUI

/// "Remind me" on something that hasn't released yet: pick when the text should come.
struct ReminderSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let item: Item
    let findID: String?
    @State private var picking = false
    @State private var custom = Date.now

    /// A real listing with a release date still ahead.
    static func upcoming(_ item: Item) -> Bool {
        guard !item.isSample, let d = item.dropAt else { return false }
        return d > .now
    }

    static func fmt(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
    static func short(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened)
            : d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private let choices: [(String, Int)] = [("When it drops", 0), ("15 minutes before", 15), ("1 hour before", 60),
                                            ("1 day before", 1440), ("3 days before", 4320)]

    var body: some View {
        let drop = item.dropAt ?? .now
        let current = store.reminder(for: item)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text("Releases \(Self.fmt(drop)) at \(item.source)").font(.footnote).foregroundStyle(Theme.muted)
                            if item.tags.contains("limited") { Text("LIMITED").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Theme.hot) }
                        }
                    }
                    if let current {
                        HStack {
                            Image(systemName: "bell.fill").foregroundStyle(Theme.blue)
                            Text("You'll get a text \(Self.fmt(current.remindAt))").font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink)
                        }
                    }
                    Text("WHEN SHOULD I TEXT YOU?").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted)
                    VStack(spacing: 8) {
                        ForEach(choices.filter { drop.addingTimeInterval(-Double($0.1) * 60) > .now }, id: \.1) { c in
                            let on = current?.offsetMinutes == c.1
                            Button { set(offset: c.1) } label: {
                                HStack {
                                    Text(c.0).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(Self.short(drop.addingTimeInterval(-Double(c.1) * 60))).font(.caption).foregroundStyle(Theme.muted)
                                    if on { Image(systemName: "checkmark").foregroundStyle(Theme.blue) }
                                }
                                .foregroundStyle(Theme.ink)
                                .padding(12)
                                .background(on ? Theme.blue.opacity(0.16) : Theme.glass, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                        Button { withAnimation(.snappy) { picking.toggle() } } label: {
                            HStack {
                                Text("Pick a time").font(.subheadline.weight(.semibold))
                                Spacer()
                                if current != nil && current?.offsetMinutes == nil { Image(systemName: "checkmark").foregroundStyle(Theme.blue) }
                                Image(systemName: picking ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(Theme.muted)
                            }
                            .foregroundStyle(Theme.ink)
                            .padding(12)
                            .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        if picking {
                            DatePicker("Remind me at", selection: $custom, in: Date.now.addingTimeInterval(60)...max(drop, Date.now.addingTimeInterval(120)))
                                .datePickerStyle(.graphical)
                                .tint(Theme.blue)
                            Button { set(at: custom) } label: {
                                Text("Remind me \(Self.fmt(custom))").font(.subheadline.weight(.bold))
                                    .frame(maxWidth: .infinity).padding(12)
                                    .foregroundStyle(Theme.accentInk)
                                    .background(Theme.accent, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if current != nil {
                        Button(role: .destructive) {
                            store.removeReminder(item)
                            router.say("Reminder removed")
                            dismiss()
                        } label: { Text("Remove reminder").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity) }
                            .padding(.top, 4)
                    }
                    if let url = item.url.flatMap(URL.init(string:)) {
                        Button { openURL(url) } label: {
                            Label("See the release page", systemImage: "arrow.up.right").font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Remind me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear {
                let start = current?.offsetMinutes == nil ? current?.remindAt : nil
                custom = start ?? max(Date.now.addingTimeInterval(3600), drop.addingTimeInterval(-3600))
                if custom > drop { custom = drop }
            }
        }
    }

    private func set(offset: Int? = nil, at: Date? = nil) {
        if store.setReminder(item, findID: findID, offsetMinutes: offset, at: at) {
            Task { await Notifier.requestPermission() }
            router.say("I'll text you \(Self.short(offset.map { (item.dropAt ?? .now).addingTimeInterval(-Double($0) * 60) } ?? at ?? .now))")
            dismiss()
        } else {
            router.say("That time has already passed")
        }
    }
}
