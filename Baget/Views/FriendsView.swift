import SwiftUI

struct FriendsView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @State private var handle = ""
    @State private var addError: String?
    @State private var adding = false

    private func invite() {
        if store.isCloud {
            adding = true
            Task { @MainActor in
                let r = await store.addFriendCloud(handle)
                adding = false
                if r.ok { addError = nil; handle = ""; router.say(r.message) } else { addError = r.message }
            }
        } else {
            addError = store.addFriend(handle)
            if addError == nil {
                Analytics.track(.friendInvited, [:])
                router.say("Invite sent")
                handle = ""
            }
        }
    }

    var body: some View {
        @Bindable var store = store
        let suggestions = store.state.suggestions.sorted { ($0.status == .new ? 0 : 1, -$0.date.timeIntervalSince1970) < ($1.status == .new ? 0 : 1, -$1.date.timeIntervalSince1970) }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(text: "Suggested by friends")
                if suggestions.isEmpty { EmptyCard(text: "No suggestions yet. When friends spot something for you, it shows up here.") }
                ForEach(suggestions) { s in SuggestionCard(suggestion: s) }

                SectionTitle(text: "Your friends")
                if store.state.friends.isEmpty { EmptyCard(text: "No friends yet. Add someone by their Baget handle.") }
                ForEach(store.state.friends) { f in FriendCard(friend: f) }

                VStack(alignment: .leading, spacing: 10) {
                    Text("ADD A FRIEND").font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.muted)
                    HStack {
                        TextField(store.isCloud ? "@handle" : "@handle or email", text: $handle)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(10).background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
                        Button(adding ? "…" : "Add") { invite() }
                            .buttonStyle(PrimaryButton()).frame(width: 96)
                            .disabled(adding)
                    }
                    if let addError { Text(addError).font(.footnote).foregroundStyle(Theme.hot) }
                    Text("Your handle is @\(store.state.profile?.handle ?? "you"). Friends on Baget can suggest things for you and see what you share.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                .glassCard()

                SectionTitle(text: "Shared with friends")
                if store.state.shares.isEmpty { EmptyCard(text: "Nothing shared yet. Use Share on any find or story.") }
                ForEach(store.state.shares) { sh in ShareCard(share: sh) }

                VStack(alignment: .leading, spacing: 4) {
                    Text("WHAT FRIENDS CAN SEE").font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.muted)
                    Toggle(isOn: $store.state.settings.shareTasteWithFriends) {
                        VStack(alignment: .leading) {
                            Text("My taste profile").foregroundStyle(Theme.ink)
                            Text("The styles, makers and creators your agents hunt, so suggestions land better.").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    Toggle(isOn: $store.state.settings.sharePurchasesWithFriends) {
                        VStack(alignment: .leading) {
                            Text("What I buy").foregroundStyle(Theme.ink)
                            Text("Off by default. Purchases and prices stay private unless you turn this on.").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                }
                .tint(Theme.cyan)
                .glassCard()
                .onChange(of: store.state.settings) { _, _ in store.save() }

                if !store.isCloud {
                    Text("Sample data: Dre, Maya and Sam are sample friends, and their replies are simulated.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }
}

struct FriendAvatar: View {
    let friend: Friend
    var size: CGFloat = 32
    var body: some View {
        Text(friend.isPending ? "?" : friend.name.split(separator: " ").compactMap { $0.first }.prefix(2).map { String($0) }.joined().uppercased())
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(Theme.accentInk)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.gradient))
    }
}

struct SuggestionCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let suggestion: Suggestion
    @State private var reply = ""
    @State private var replied = false

    var body: some View {
        if let f = store.friend(suggestion.friendID), let item = Catalog.item(suggestion.itemID) {
            let best = store.best(for: item)
            let notInSize = best?.match.notInSize ?? false
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    FriendAvatar(friend: f)
                    (Text(f.name).bold().foregroundStyle(Theme.ink) + Text(" suggested for you · \(Fmt.ago(suggestion.date))").foregroundStyle(Theme.muted))
                        .font(.footnote)
                }
                Text("“\(suggestion.note)”").font(.body.italic()).foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("\(item.category.info.label) · \(Fmt.money(item.price)) at \(item.source)\(notInSize ? " · not in your size" : "")")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12))

                switch suggestion.status {
                case .new:
                    HStack {
                        Button(best != nil && !notInSize ? "Send to \(best!.agent.name)" : "Save to my Finds") {
                            store.acceptSuggestion(suggestion.id)
                            Analytics.track(.suggestionAccepted, ["category": item.category.rawValue])
                            router.say("Saved to your Finds. Your agent learned from it.")
                        }.buttonStyle(PrimaryButton())
                        Button("Not for me") {
                            store.passSuggestion(suggestion.id)
                            Analytics.track(.suggestionPassed, ["category": item.category.rawValue])
                        }.buttonStyle(GhostButton())
                    }
                case .sent:
                    Text("Saved to your Finds. Your agent learned from it.").font(.footnote).foregroundStyle(Theme.green)
                case .passed:
                    Text("You passed. Your agent won't count it.").font(.footnote).foregroundStyle(Theme.muted)
                }
                if store.isCloud && suggestion.shareID != nil {
                    if replied {
                        Text("Reply sent to \(f.name)").font(.caption).foregroundStyle(Theme.muted)
                    } else {
                        HStack {
                            TextField("Reply to \(f.name.split(separator: " ").first.map(String.init) ?? f.name)", text: $reply)
                                .padding(9).background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
                            Button("Send") {
                                store.replyToSuggestion(suggestion, text: reply.trimmingCharacters(in: .whitespacesAndNewlines))
                                reply = ""; replied = true
                            }
                            .buttonStyle(GhostButton()).frame(width: 80)
                            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            .glassCard(highlighted: suggestion.status == .new)
        }
    }
}

struct FriendCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    let friend: Friend

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                FriendAvatar(friend: friend, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.isPending && !friend.incoming ? friend.handle : friend.name).font(.headline).foregroundStyle(Theme.ink)
                    Text(friend.isPending
                         ? (friend.incoming ? "\(friend.handle) wants to be friends" : "Request sent · waiting for them to accept")
                         : "\(friend.handle)\(friend.isSample ? " · sample friend" : "")")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            if friend.isPending && friend.incoming {
                HStack {
                    Button("Accept") { store.respondToFriend(friend, accept: true); router.say("You and \(friend.name) are now friends") }
                        .buttonStyle(PrimaryButton())
                    Button("Decline") { store.respondToFriend(friend, accept: false) }.buttonStyle(GhostButton())
                }
            } else if friend.isPending && !friend.isSample {
                Button("Cancel request") { store.removeFriend(friend.id) }.buttonStyle(GhostButton())
            }
            if !friend.isPending {
                FlowRow { ForEach(friend.hunts) { Tag(text: $0.info.label) } }
                let both = store.sharedTaste(friend)
                if !both.isEmpty {
                    (Text("You both like ").foregroundStyle(Theme.muted) + Text(both.prefix(3).joined(separator: ", ")).bold().foregroundStyle(Theme.ink)).font(.footnote)
                }
                HStack {
                    Button("Suggest something") { router.sheet = .suggestFor(friend.id) }.buttonStyle(PrimaryButton())
                    Button("Remove") { store.removeFriend(friend.id); router.say("Removed \(friend.name)") }.buttonStyle(GhostButton())
                }
            }
        }
        .glassCard()
    }
}

struct ShareCard: View {
    @Environment(AppStore.self) private var store
    let share: Share
    var body: some View {
        if let item = Catalog.item(share.itemID) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(share.isSuggestion ? "You suggested" : "You shared") \(item.title)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text("to \(share.to.compactMap { store.friend($0)?.name }.joined(separator: ", ")) · \(Fmt.ago(share.date))").font(.caption).foregroundStyle(Theme.muted)
                if !share.note.isEmpty { Text("“\(share.note)”").font(.footnote.italic()).foregroundStyle(Theme.ink) }
                ForEach(share.replies, id: \.self) { r in
                    if let f = store.friend(r.friendID) {
                        HStack(alignment: .top, spacing: 8) {
                            FriendAvatar(friend: f, size: 26)
                            (Text(f.name).bold() + Text(" \(r.text)"))
                                .font(.footnote).foregroundStyle(Theme.ink)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
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
                            Text("\(item.category.info.label) · \(Fmt.money(item.price)) at \(item.source)").font(.caption).foregroundStyle(Theme.muted)
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
                    TextField(isSuggestion ? "Why it's perfect for them" : "What do you think?", text: $note)
                }
            }
            .scrollContentBackground(.hidden)
            .background(LitBackground())
            .navigationTitle(isSuggestion ? "Suggest" : "Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        store.share(itemID: itemID, to: Array(picked), note: note.trimmingCharacters(in: .whitespaces), isSuggestion: isSuggestion)
                        Analytics.track(isSuggestion ? .suggestionSent : .itemShared, ["friends": picked.count, "hasNote": !note.isEmpty])
                        router.say("Sent")
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
                                Text("\(item.category.info.label) · \(Fmt.money(item.price))").font(.caption).foregroundStyle(Theme.muted)
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
