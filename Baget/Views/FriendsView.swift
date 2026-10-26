import SwiftUI

/// The Friends tab's quieter look: headings in the system font, semibold (same as product titles).
private enum FriendsStyle {
    static func serif(_ size: CGFloat) -> Font { .system(size: size, weight: size >= 30 ? .bold : .semibold) }
    static let rule = Theme.line
}

private struct SectionHead: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(FriendsStyle.serif(21)).foregroundStyle(Theme.ink)
            Spacer()
            if let trailing { Text(trailing).font(.footnote).foregroundStyle(Theme.muted) }
        }
        .padding(.top, 6)
    }
}

/// A plain white pill: the one main action on a row.
private struct QuietPrimary: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.bg)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.8 : 0.95)))
    }
}

struct FriendsView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @State private var open: Friend?
    @State private var adding = false
    @State private var privacy = false
    @State private var matches: [String: Int] = [:]
    @State private var birthdays: [UpcomingBirthday] = []

    var body: some View {
        // Only suggestions you haven't acted on: adding saves it to Finds and passing dismisses it; either way it leaves.
        let suggestions = store.state.suggestions.filter { $0.status == .new }.sorted { $0.date > $1.date }
        let circle = store.state.friends.filter { !$0.isPending || !$0.incoming }
        let requests = store.state.friends.filter { $0.isPending && $0.incoming }
        let shares = store.state.shares.filter { Catalog.item($0.itemID) != nil }
        let accepted = circle.filter { !$0.isPending }

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Friends").font(FriendsStyle.serif(36)).foregroundStyle(Theme.ink)
                    Text("Hunting's better with people who get your taste.").font(.subheadline).foregroundStyle(Theme.muted)
                }
                .padding(.bottom, 4)

                ForEach(requests) { f in RequestRow(friend: f) }

                ForEach(birthdays) { b in
                    BirthdayCard(birthday: b, friend: accepted.first { $0.id == b.friendId }) {
                        open = accepted.first { $0.id == b.friendId }
                    }
                }

                if circle.isEmpty {
                    InviteHero(adding: $adding)
                } else {
                    SectionHead(title: String(localized: "Your circle"),
                                trailing: accepted.isEmpty ? nil : (accepted.count == 1 ? String(localized: "1 friend") : String(localized: "\(accepted.count) friends")))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(circle) { f in
                                Button { open = f } label: {
                                    CircleMember(friend: f, hasNew: suggestions.contains { $0.friendID == f.id }, match: matches[f.id])
                                }
                                .buttonStyle(.plain)
                            }
                            Button { adding = true } label: {
                                VStack(spacing: 7) {
                                    Circle().strokeBorder(Theme.cyan.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                                        .frame(width: 58, height: 58)
                                        .overlay(Image(systemName: "person.badge.plus").font(.title3).foregroundStyle(Theme.cyan))
                                    Text("Add").font(.caption.weight(.semibold)).foregroundStyle(Theme.cyan)
                                }
                                .frame(width: 62)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add a friend by username")
                        }
                        .padding(.vertical, 2)
                    }
                    if accepted.count < 8 { InviteBanner(adding: $adding) }
                }

                if store.isCloud { TasteCardsRow().padding(.top, 6) }

                SectionHead(title: String(localized: "Sent to you"), trailing: suggestions.isEmpty ? nil : String(localized: "\(suggestions.count) new"))
                if suggestions.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "tray.and.arrow.down.fill").font(.body).foregroundStyle(Theme.warn)
                            .frame(width: 40, height: 40)
                            .background(Theme.warn.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.state.friends.isEmpty ? String(localized: "Nothing here yet") : String(localized: "Nothing new right now"))
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                            Text("Friends' finds and picks for you land here.").font(.footnote).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
                }
                ForEach(suggestions) { s in SuggestionCard(suggestion: s) }

                if !shares.isEmpty {
                    SectionHead(title: String(localized: "You sent")).padding(.top, 8)
                    ForEach(shares) { sh in SentRow(share: sh) }
                }

                SharingCard(edit: { privacy = true }).padding(.top, 8)

                if !store.isCloud {
                    Text("Sample data: Dre, Maya and Sam are sample friends, and their replies are simulated.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .dismissKeyboardOnTap()
        .scrollIndicators(.hidden)
        .task(id: "\(accepted.count)-\(store.state.settings.shareTasteWithFriends)") {
            matches = await store.friendMatches()
            birthdays = await store.upcomingBirthdays()
            #if DEBUG
            if FriendPreview.enabled {
                birthdays = [UpcomingBirthday(friendId: store.state.friends.first?.id ?? "preview", name: "Hetty", handle: "hetty", birthday: "11-02", days: 7, shares: true)]
            }
            #endif
        }
        .sheet(item: $open) { f in
            Group {
                if f.isPending || f.isSample { FriendSheet(friend: f) } else { FriendProfileView(friend: f) }
            }
            .environment(store).environment(router)
                .presentationDetents(f.isPending || f.isSample ? [.medium, .large] : [.large]).presentationBackground(Theme.panel).preferredColorScheme(.dark)
        }
        .sheet(isPresented: $adding) {
            AddFriendSheet().environment(store).environment(router)
                .presentationDetents([.height(300)]).presentationBackground(Theme.panel).preferredColorScheme(.dark)
        }
        .sheet(isPresented: $privacy) {
            FriendsPrivacySheet().environment(store)
                .presentationDetents([.medium]).presentationBackground(Theme.panel).preferredColorScheme(.dark)
        }
    }
}

extension AppStore {
    /// Taste match % for each friend who shares taste (server: friend_matches), keyed by friend id.
    func friendMatches() async -> [String: Int] {
        guard isCloud else { return [:] }
        struct Row: Decodable { let friendId: String; let match: Int? }
        let rows: [Row] = (try? await api.rpc("friend_matches")) ?? []
        return Dictionary(rows.compactMap { r in r.match.map { (r.friendId, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// What the invite says: who you are on Baget and how to find you.
    var inviteMessage: String {
        let h = state.profile?.handle ?? ""
        return h.isEmpty ? String(localized: "I'm hunting on Baget. Add me so we can compare our taste.")
                         : String(localized: "I'm hunting on Baget. Add me, @\(h), so we can compare our taste.")
    }
}

/// Opens the share sheet with the invite (Messages, WhatsApp, Instagram...).
private struct InviteLink<Label: View>: View {
    @Environment(AppStore.self) private var store
    @ViewBuilder let label: () -> Label
    var body: some View {
        ShareLink(item: store.inviteMessage) { label() }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { Analytics.track(.friendInvited, ["via": "share"]) })
    }
}

/// The big invite card for someone with no friends on Baget yet.
private struct InviteHero: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Binding var adding: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: -12) {
                Text(String(([store.state.profile?.displayName, store.state.profile?.handle].compactMap { $0 }.first { !$0.isEmpty } ?? "Y").first ?? "Y").uppercased())
                    .font(.system(size: 18, weight: .heavy)).foregroundStyle(Theme.accentInk)
                    .frame(width: 46, height: 46).background(Circle().fill(Theme.gradient))
                    .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 3))
                ForEach(0..<3, id: \.self) { _ in
                    Image(systemName: "plus").font(.body.weight(.light)).foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                }
            }
            .padding(.bottom, 14)
            Text("Bring your crew.\nSee who shares your taste.").font(.system(size: 24, weight: .heavy)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("When a friend joins, Baget compares your taste and unlocks:").font(.subheadline).foregroundStyle(Theme.ink.opacity(0.75))
                .padding(.top, 6).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                perk("percent", Theme.green, "Your taste match", "how close your styles are")
                perk("rectangle.portrait.on.rectangle.portrait.angled.fill", Theme.hot, "Taste Cards", "swap your style ID")
                perk("gift.fill", Theme.warn, "Gift radar", "picks for their birthday")
                perk("paperplane.fill", Theme.cyan, "Send finds", "\"saw this and thought of you\"")
            }
            .padding(.top, 14)
            HStack(spacing: 10) {
                InviteLink {
                    Text("Invite friends").font(.subheadline.weight(.heavy)).foregroundStyle(Theme.accentInk)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                Button { adding = true } label: {
                    Text("Add by handle").font(.subheadline.weight(.heavy)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 16)
            if let h = store.state.profile?.handle, !h.isEmpty {
                HStack(spacing: 8) {
                    Text("Your handle").foregroundStyle(Theme.muted)
                    Text("@\(h)").fontWeight(.bold).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Color.black.opacity(0.25)))
                    Button("Copy") { UIPasteboard.general.string = "@\(h)"; router.say(String(localized: "Handle copied")) }
                        .fontWeight(.bold).foregroundStyle(Theme.cyan).buttonStyle(.plain)
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            }
        }
        .padding(20)
        .background {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [Theme.blue.opacity(0.30), Theme.cyan.opacity(0.16), Theme.hot.opacity(0.18)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(RadialGradient(colors: [Theme.green.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 110))
                    .frame(width: 220, height: 220).offset(x: 70, y: -80)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .padding(.top, 6)
    }

    private func perk(_ icon: String, _ tint: Color, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).font(.footnote.weight(.bold)).foregroundStyle(tint)
                .frame(width: 30, height: 30).background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            (Text(title).fontWeight(.bold).foregroundColor(Theme.ink) + Text(" ") + Text(detail).foregroundColor(Theme.ink.opacity(0.65)))
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A slim nudge to invite more people, once you have a few friends.
private struct InviteBanner: View {
    @Binding var adding: Bool
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Who else hunts like you?").font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                Text("Invite a friend and see your match.").font(.caption).foregroundStyle(Theme.ink.opacity(0.7))
            }
            Spacer(minLength: 8)
            InviteLink {
                Text("Invite").font(.subheadline.weight(.heavy)).foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 16).padding(.vertical, 9).background(Capsule().fill(Theme.gradient))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(LinearGradient(colors: [Theme.blue.opacity(0.22), Theme.green.opacity(0.14)], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .contextMenu { Button("Add by handle") { adding = true } }
    }
}

/// What friends can see, at a glance, with a nudge to share taste (it's what unlocks match % and Taste Cards).
private struct SharingCard: View {
    @Environment(AppStore.self) private var store
    let edit: () -> Void
    var body: some View {
        let taste = store.state.settings.shareTasteWithFriends
        let buys = store.state.settings.sharePurchasesWithFriends
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What friends see").font(.body.weight(.bold)).foregroundStyle(Theme.ink)
                Spacer()
                Button("Edit", action: edit).font(.subheadline.weight(.bold)).foregroundStyle(Theme.cyan).buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                pill("sparkles", String(localized: "Taste"), taste ? String(localized: "Shared") : String(localized: "Hidden"), on: taste)
                pill(buys ? "bag.fill" : "lock.fill", String(localized: "Purchases"), buys ? String(localized: "Shared") : String(localized: "Private"), on: buys)
            }
            if !taste {
                HStack(spacing: 10) {
                    Text("Share your taste to see match % and swap Taste Cards.").font(.footnote).foregroundStyle(Color(red: 1, green: 0.89, blue: 0.64))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Turn on") {
                        store.state.settings.shareTasteWithFriends = true
                        store.save()
                    }
                    .font(.footnote.weight(.heavy)).foregroundStyle(Color(red: 0.11, green: 0.08, blue: 0.02))
                    .padding(.horizontal, 12).padding(.vertical, 7).background(Capsule().fill(Theme.warn))
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(Theme.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.warn.opacity(0.28)))
            }
        }
        .padding(16)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line))
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
    }

    private func pill(_ icon: String, _ title: String, _ state: String, on: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.body).foregroundStyle(on ? Theme.green : Theme.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                Text(state).font(.caption).foregroundStyle(on ? Theme.green.opacity(0.9) : Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background((on ? Theme.green.opacity(0.08) : Color.black.opacity(0.18)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? Theme.green.opacity(0.4) : Theme.line))
    }
}

/// A friend's monogram: a serif initial in a thin ring.
struct FriendAvatar: View {
    let friend: Friend
    var size: CGFloat = 32
    var body: some View {
        Text(friend.isPending && !friend.incoming ? "?" : String(friend.name.first ?? "?").uppercased())
            .font(FriendsStyle.serif(size * 0.4))
            .foregroundStyle(Theme.ink)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(0.04)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
    }
}

private struct CircleMember: View {
    let friend: Friend
    let hasNew: Bool
    var match: Int? = nil
    private static let palettes: [[Color]] = [
        [Color(red: 1, green: 0.54, blue: 0.36), Theme.hot], [Color(red: 0.48, green: 0.24, blue: 1), Theme.cyan],
        [Theme.warn, Color(red: 1, green: 0.54, blue: 0.36)], [Theme.blue, Theme.green], [Theme.hot, Color(red: 0.48, green: 0.24, blue: 1)],
    ]
    var body: some View {
        let colors = Self.palettes[abs(friend.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % Self.palettes.count]
        VStack(spacing: 5) {
            Text(friend.isPending && !friend.incoming ? "?" : String(friend.name.first ?? "?").uppercased())
                .font(.system(size: 22, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(Circle().fill(LinearGradient(colors: friend.isPending ? [Theme.glass, Theme.glass] : colors,
                                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(Circle().strokeBorder(Color.white.opacity(friend.isPending ? 0.3 : 0), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .overlay(alignment: .topTrailing) {
                    if hasNew { Circle().fill(Theme.warn).frame(width: 12, height: 12).overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2)) }
                }
            Text(friend.isPending ? String(localized: "Invited") : (friend.name.split(separator: " ").first.map(String.init) ?? friend.name))
                .font(.caption).foregroundStyle(friend.isPending ? Theme.muted : Theme.ink.opacity(0.9))
                .lineLimit(1)
            if let match {
                Text("\(match)%").font(.system(size: 10.5, weight: .heavy)).foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(match >= 85 ? Theme.cyan : Theme.green))
            }
        }
        .frame(width: 62)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(friend.isPending ? String(localized: "Request sent to \(friend.handle)")
                            : (match.map { String(localized: "\(friend.name), \($0)% taste match") } ?? friend.name))
    }
}

private struct RequestRow: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let friend: Friend
    var body: some View {
        HStack(spacing: 12) {
            FriendAvatar(friend: friend, size: 34)
            (Text(friend.name).bold() + Text(" wants to connect")).font(.subheadline).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 8)
            Button("Accept") { store.respondToFriend(friend, accept: true); router.say(String(localized: "You and \(friend.name) are now friends")) }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
            Button("Decline") { store.respondToFriend(friend, accept: false) }
                .font(.subheadline).foregroundStyle(Theme.muted)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Divider().overlay(FriendsStyle.rule) }
        .overlay(alignment: .bottom) { Divider().overlay(FriendsStyle.rule) }
    }
}

struct SuggestionCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let suggestion: Suggestion
    @State private var reply = ""
    @State private var replying = false
    @State private var replied = false

    var body: some View {
        if let f = store.friend(suggestion.friendID), let item = Catalog.item(suggestion.itemID) {
            let best = store.best(for: item)
            let notInSize = best?.match.notInSize ?? false
            let note = suggestion.note.trimmingCharacters(in: .whitespacesAndNewlines)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    FriendAvatar(friend: f, size: 24)
                    (Text(f.name).bold().foregroundStyle(Theme.ink) + Text(" · \(Fmt.ago(suggestion.date))").foregroundStyle(Theme.muted))
                        .font(.footnote)
                }
                HStack(alignment: .center, spacing: 16) {
                    ProductThumb(item: item, size: 104)
                    VStack(alignment: .leading, spacing: 3) {
                        if !item.brand.isEmpty { Text(item.brand).font(FriendsStyle.serif(16)).foregroundStyle(Theme.ink) }
                        Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(3)
                        Text([item.priceKnown && item.price > 0 ? item.priceLabel : nil, item.source, notInSize ? "not in your size" : nil]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(Theme.muted).padding(.top, 2)
                    }
                }
                if !note.isEmpty {
                    Text(note)
                        .font(.system(size: 16).italic()).foregroundStyle(Theme.ink.opacity(0.9))
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.25)).frame(width: 2) }
                }
                HStack(spacing: 18) {
                    Button("Add to Finds") {
                        withAnimation(.snappy) { store.acceptSuggestion(suggestion.id) }
                        Analytics.track(.suggestionAccepted, ["category": item.category.rawValue])
                        router.say(best != nil && !notInSize ? String(localized: "Saved to Finds. \(best!.agent.name) learned from it.") : String(localized: "Saved to your Finds"))
                    }
                    .buttonStyle(QuietPrimary())
                    Button("Not for me") {
                        withAnimation(.snappy) { store.passSuggestion(suggestion.id) }
                        router.say(String(localized: "Passed"))
                        Analytics.track(.suggestionPassed, ["category": item.category.rawValue])
                    }
                    .font(.subheadline).foregroundStyle(Theme.ink.opacity(0.8)).buttonStyle(.plain)
                    Spacer()
                    if store.isCloud && suggestion.shareID != nil && !replied {
                        Button(replying ? String(localized: "Cancel") : String(localized: "Reply")) { withAnimation(.snappy) { replying.toggle() } }
                            .font(.subheadline).foregroundStyle(Theme.muted).buttonStyle(.plain)
                    }
                }
                if replied {
                    Text("Reply sent to \(f.name)").font(.caption).foregroundStyle(Theme.muted)
                } else if replying {
                    HStack {
                        TextField("Reply to \(f.name.split(separator: " ").first.map(String.init) ?? f.name)", text: $reply)
                            .submitLabel(.send).onSubmit(send)
                            .padding(10).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        Button("Send", action: send)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).buttonStyle(.plain)
                            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.vertical, 18)
            .overlay(alignment: .top) { Divider().overlay(FriendsStyle.rule) }
        }
    }

    private func send() {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.replyToSuggestion(suggestion, text: t)
        reply = ""; replied = true; replying = false
    }
}

/// Something you sent, with your friends' replies underneath.
private struct SentRow: View {
    @Environment(AppStore.self) private var store
    let share: Share
    private var recipients: String {
        share.to.compactMap { store.friend($0)?.name }.map { n in n.split(separator: " ").first.map(String.init) ?? n }.joined(separator: ", ")
    }
    var body: some View {
        if let item = Catalog.item(share.itemID) {
            HStack(alignment: .top, spacing: 12) {
                ProductThumb(item: item, size: 50)
                VStack(alignment: .leading, spacing: 6) {
                    (Text(item.title).foregroundStyle(Theme.ink)
                     + Text(" to \(recipients) · \(Fmt.ago(share.date))").foregroundStyle(Theme.muted))
                        .font(.subheadline).lineLimit(2)
                    ForEach(share.replies, id: \.self) { r in
                        if let f = store.friend(r.friendID) {
                            (Text(f.name.split(separator: " ").first.map(String.init) ?? f.name).bold() + Text("  \(r.text)"))
                                .font(.footnote).foregroundStyle(Theme.ink)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Divider().overlay(FriendsStyle.rule) }
        }
    }
}

/// A friend's page: what you share in taste, what they hunt, what they've sent you, and suggesting something back.
private struct FriendSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    let friend: Friend
    @State private var confirmRemove = false

    var body: some View {
        let first = friend.name.split(separator: " ").first.map(String.init) ?? friend.name
        let both = store.sharedTaste(friend)
        let sent = store.state.suggestions.filter { $0.friendID == friend.id }.sorted { $0.date > $1.date }.compactMap { Catalog.item($0.itemID) }.prefix(4)
        ScrollView {
            VStack(spacing: 0) {
                HStack { Spacer(); CloseButton { dismiss() } }.padding(.top, 14)
                FriendAvatar(friend: friend, size: 84).padding(.top, 2)
                Text(friend.isPending ? friend.handle : friend.name).font(FriendsStyle.serif(26)).foregroundStyle(Theme.ink).padding(.top, 12)
                Text(friend.isPending ? String(localized: "Request sent · waiting for them to accept") : friend.handle)
                    .font(.subheadline).foregroundStyle(Theme.muted).padding(.top, 4)

                VStack(alignment: .leading, spacing: 18) {
                    if !both.isEmpty { chips(String(localized: "You both like"), Array(both.prefix(6))) }
                    if !friend.hunts.isEmpty { chips("\(first) hunts", friend.hunts.map(\.info.label)) }
                    if !sent.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            label(String(localized: "Recently sent you"))
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                                ForEach(Array(sent)) { item in ProductThumb(item: item, size: 150) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 24)

                if friend.isPending {
                    Button("Cancel request") { store.removeFriend(friend.id); dismiss() }
                        .font(.subheadline).foregroundStyle(Theme.muted).buttonStyle(.plain).padding(.top, 28)
                } else {
                    Button("Suggest something for \(first)") { dismiss(); router.sheet = .suggestFor(friend.id) }
                        .buttonStyle(QuietPrimary()).padding(.top, 28)
                    Button("Remove friend") { confirmRemove = true }
                        .font(.footnote).foregroundStyle(Theme.muted).buttonStyle(.plain).padding(.top, 16)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
        .confirmationDialog("Remove \(friend.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { store.removeFriend(friend.id); router.say("Removed \(friend.name)"); dismiss() }
        }
    }

    private func label(_ t: String) -> some View {
        Text(t.uppercased()).font(.caption.weight(.semibold)).tracking(1.6).foregroundStyle(Theme.muted)
    }
    private func chips(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            label(title)
            FlowRow {
                ForEach(items, id: \.self) { t in
                    Text(t).font(.footnote).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
                }
            }
        }
    }
}

private struct AddFriendSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var handle = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a friend").font(FriendsStyle.serif(24)).foregroundStyle(Theme.ink)
            Text("Type their username. Yours is @\(store.state.profile?.handle ?? "you"), and you can change it in Settings.")
                .font(.footnote).foregroundStyle(Theme.muted)
            HStack {
                TextField(store.isCloud ? "@username" : "@username or email", text: $handle)
                    .focused($fieldFocused)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.go).onSubmit(add)
                    .padding(12).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                Button(working ? "…" : String(localized: "Add"), action: add).buttonStyle(QuietPrimary()).disabled(working || handle.isEmpty)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.hot) }
            Spacer()
        }
        .padding(24)
        .onAppear { fieldFocused = true }
    }

    private func add() {
        guard !handle.isEmpty else { return }
        if store.isCloud {
            working = true
            Task { @MainActor in
                let r = await store.addFriendCloud(handle)
                working = false
                if r.ok { router.say(r.message); dismiss() } else { error = r.message }
            }
        } else {
            error = store.addFriend(handle)
            if error == nil { Analytics.track(.friendInvited, [:]); router.say("Invite sent"); dismiss() }
        }
    }
}

private struct FriendsPrivacySheet: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 18) {
            Text("What friends can see").font(FriendsStyle.serif(24)).foregroundStyle(Theme.ink)
            Toggle(isOn: $store.state.settings.shareTasteWithFriends) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("My taste").foregroundStyle(Theme.ink)
                    Text("The styles, brands and creators your scouts hunt, so what friends send you lands better.").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            BirthdayRow()
            Toggle(isOn: $store.state.settings.sharePurchasesWithFriends) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("What I buy").foregroundStyle(Theme.ink)
                    Text("Off by default. Purchases and prices stay private unless you turn this on.").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
        }
        .tint(Theme.green)
        .padding(24)
        .onChange(of: store.state.settings) { _, _ in store.save() }
    }
}

struct ShareView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    let itemID: String
    let preselect: String?
    let isSuggestion: Bool
    @State private var picked: Set<String> = []
    @State private var note = ""

    var body: some View {
        let friends = store.state.friends.filter { !$0.isPending }
        NavigationStack {
            Form {
                if let item = Catalog.item(itemID) {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.headline)
                            Text("\(item.category.info.label) · \(item.priceLabel) at \(item.source)").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                }
                Section("Send to") {
                    if friends.isEmpty { Text("Add a friend first, on the Friends tab.").foregroundStyle(Theme.muted) }
                    ForEach(friends) { f in
                        Button {
                            if picked.contains(f.id) { picked.remove(f.id) } else { picked.insert(f.id) }
                        } label: {
                            HStack {
                                FriendAvatar(friend: f, size: 28)
                                VStack(alignment: .leading) {
                                    Text(f.name).foregroundStyle(Theme.ink)
                                    Text(f.handle).font(.caption).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Image(systemName: picked.contains(f.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                Section("Add a note") {
                    TextField(isSuggestion ? String(localized: "Why it's perfect for them") : String(localized: "What do you think?"), text: $note)
                }
            }
            .scrollContentBackground(.hidden)
            .background(LitBackground())
            .navigationTitle(isSuggestion ? String(localized: "Suggest") : String(localized: "Share"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        store.share(itemID: itemID, to: Array(picked), note: note.trimmingCharacters(in: .whitespaces), isSuggestion: isSuggestion)
                        Analytics.track(isSuggestion ? .suggestionSent : .itemShared, ["friends": picked.count, "hasNote": !note.isEmpty])
                        router.say(String(localized: "Sent"))
                        dismiss()
                    }.bold().disabled(picked.isEmpty)
                }
            }
            .onAppear {
                if let preselect { picked = [preselect] } else if friends.count == 1 { picked = [friends[0].id] }
            }
        }
    }
}

struct SuggestForView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    let friendID: String

    var body: some View {
        NavigationStack {
            List {
                if let f = store.friend(friendID) {
                    Section {
                        Text("Picked from today's listings that match what \(f.name.split(separator: " ").first.map(String.init) ?? f.name) hunts\(f.likes.isEmpty ? "" : ": \(f.likes.joined(separator: ", "))").")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                    let picks = store.friendPicks(f)
                    if picks.isEmpty { Text("Nothing matches their taste right now.").foregroundStyle(Theme.muted) }
                    ForEach(picks) { item in
                        Button {
                            router.sheet = .share(itemID: item.id, friendID: f.id, suggestion: true)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).foregroundStyle(Theme.ink)
                                Text("\(item.category.info.label) · \(item.priceLabel)").font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(LitBackground())
            .navigationTitle("Suggest something")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
