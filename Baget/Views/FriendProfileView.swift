import SwiftUI

// MARK: - Data

/// One Taste Card: an AI-written archetype, signature brands, notes and a palette (server: taste_card).
struct TasteCard: Decodable, Hashable {
    var archetype: String
    var signature: [String] = []
    var notes: [String] = []
    var hunts: [String] = []
    var grail: String?
    var palette: [String] = []
    var number: Int?
    var friendId: String?
    var name: String?
    var handle: String?
}

/// Everything a friend's profile shows (server: friend_profile). Taste parts are there only when both share taste.
struct FriendProfile: Decodable {
    struct DNA: Decodable, Hashable { let label: String; let who: String; let strength: Double }
    struct Grail: Decodable { let listing: ListingRow; let tag: String }
    let friendId: String
    let handle: String?
    let name: String?
    let since: Date?
    let shares: Bool
    let theyShare: Bool?
    var match: Int?
    var dna: [DNA]?
    var bothLove: [String]?
    var theirWorld: [String]?
    var hunts: [String]?
    var grails: [Grail]?
    var twins: [ListingRow]?
    var gifts: [ListingRow]?
    var birthday: String?
    var card: TasteCard?
    var myCard: TasteCard?
}

extension AppStore {
    func friendProfile(_ id: String) async -> FriendProfile? {
        guard isCloud else { return nil }
        guard let p: FriendProfile = try? await api.rpc("friend_profile", ["p_friend": id]) else { return nil }
        for l in (p.grails ?? []).map(\.listing) + (p.twins ?? []) + (p.gifts ?? []) { Catalog.cloud[l.id] = l.item }
        return p
    }
    func myTasteCard() async -> TasteCard? {
        guard isCloud else { return nil }
        return try? await api.rpc("my_taste_card", as: TasteCard?.self)
    }
    func friendCards() async -> [TasteCard] {
        guard isCloud else { return [] }
        return (try? await api.rpc("friend_cards", as: [TasteCard].self)) ?? []
    }
    /// Month and day ("11-12") shown to friends who share taste, or nil to clear.
    func setBirthday(_ mmdd: String?) async {
        guard isCloud, let uid = api.userID else { return }
        try? await api.update("profiles", "id=eq.\(uid)", ["birthday": mmdd.map { $0 as Any } ?? NSNull()])
    }
    func myBirthday() async -> String? {
        guard isCloud, let uid = api.userID else { return nil }
        struct Row: Decodable { let birthday: String? }
        let rows: [Row] = (try? await api.select("profiles", "select=birthday&id=eq.\(uid)")) ?? []
        return rows.first?.birthday
    }
}

enum Birthday {
    /// "11-12" → "Nov 12".
    static func label(_ mmdd: String?) -> String? {
        guard let mmdd, mmdd.count == 5, let m = Int(mmdd.prefix(2)), let d = Int(mmdd.suffix(2)) else { return nil }
        var c = DateComponents(); c.year = 2000; c.month = m; c.day = d
        guard let date = Calendar.current.date(from: c) else { return nil }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

extension Color {
    init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

// MARK: - Friend profile

/// A friend's profile: taste match, taste DNA, what you both love, their world, grails, twin finds and gift radar.
struct FriendProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    let friend: Friend
    /// Debug screenshots only: show this instead of loading.
    var preview: FriendProfile? = nil
    @State private var profile: FriendProfile?
    @State private var loading = true
    @State private var confirmRemove = false
    @State private var showCards = false
    @State private var hunting: String?

    private var first: String { friend.name.split(separator: " ").first.map(String.init) ?? friend.name }
    private static let themGradient = LinearGradient(colors: [Color(red: 1, green: 0.54, blue: 0.36), Theme.hot], startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                if loading {
                    HStack { Spacer(); ProgressView().tint(Theme.cyan); Spacer() }.padding(.vertical, 30)
                } else if let p = profile, p.shares {
                    if let m = p.match { matchCard(m, p) }
                    if let dna = p.dna, !dna.isEmpty { dnaCard(dna) }
                    if let both = p.bothLove, !both.isEmpty { chips(String(localized: "You both love"), both, style: .both) }
                    if let world = p.theirWorld, !world.isEmpty { theirWorld(world) }
                    if let g = p.grails, !g.isEmpty { grails(g) }
                    if let t = p.twins, !t.isEmpty { twins(t) }
                    if let gifts = p.gifts, !gifts.isEmpty { giftRadar(gifts, birthday: p.birthday) }
                } else {
                    notSharing
                }
                sentRecently
                actions
            }
            .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .topTrailing) { CloseButton { dismiss() }.padding(.top, 14).padding(.trailing, 16) }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showCards) {
            TasteCardSwapView(friendName: friend.name, theirs: profile?.card, mine: profile?.myCard, match: profile?.match)
                .presentationBackground(Theme.bg)
        }
        .confirmationDialog("Remove \(friend.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { store.removeFriend(friend.id); router.say(String(localized: "Removed \(friend.name)")); dismiss() }
        }
        .confirmationDialog(hunting.map { String(localized: "Start a scout for \($0)?") } ?? "", isPresented: Binding(get: { hunting != nil }, set: { if !$0 { hunting = nil } }), titleVisibility: .visible) {
            Button("Start hunting") {
                guard let h = hunting else { return }
                hunting = nil
                Task { @MainActor in
                    if let r = await store.hunt(h) { router.say(r.intro) } else if let p = store.syncProblem { router.say(p) }
                }
            }
        } message: {
            Text("A new scout hunts it for you, the way \(first) loves it.")
        }
    }

    private func load() async {
        if let preview { profile = preview; loading = false; return }
        if friend.isSample { loading = false; return }
        profile = await store.friendProfile(friend.id)
        loading = false
    }

    // MARK: sections

    private var hero: some View {
        VStack(spacing: 8) {
            HStack(spacing: -14) {
                avatar(String(friend.name.first ?? "?").uppercased(), Self.themGradient).zIndex(1)
                avatar(String((store.state.profile?.displayName ?? "Y").first ?? "Y").uppercased(), Theme.gradient)
            }
            Text(friend.name).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.ink).padding(.top, 4)
            Text(sinceLine).font(.subheadline).foregroundStyle(Theme.muted)
            if let a = profile?.card?.archetype {
                Text("✦ \(a)").font(.footnote.weight(.bold)).foregroundStyle(Color(red: 1, green: 0.62, blue: 0.69))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.hot.opacity(0.12), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var sinceLine: String {
        guard let since = profile?.since else { return friend.handle }
        return String(localized: "\(friend.handle) · friends since \(since.formatted(.dateTime.month(.abbreviated).day()))")
    }

    private func avatar(_ letter: String, _ fill: some ShapeStyle) -> some View {
        Text(letter).font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.ink)
            .frame(width: 76, height: 76).background(Circle().fill(fill))
            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 3))
    }

    private func matchCard(_ m: Int, _ p: FriendProfile) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 9)
                Circle().trim(from: 0, to: CGFloat(m) / 100).stroke(Theme.gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(m)%").font(.system(size: 21, weight: .heavy)).foregroundStyle(Theme.ink)
            }
            .frame(width: 80, height: 80)
            VStack(alignment: .leading, spacing: 4) {
                Text(matchTitle(m)).font(.headline).foregroundStyle(Theme.ink)
                Text(matchLine(p)).font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14).glassCard()
        .accessibilityElement(children: .combine)
    }

    private func matchTitle(_ m: Int) -> String {
        m >= 80 ? String(localized: "Taste match: twins") : m >= 60 ? String(localized: "Taste match: really close")
            : m >= 40 ? String(localized: "Taste match: some overlap") : String(localized: "Taste match: different worlds")
    }

    private func matchLine(_ p: FriendProfile) -> String {
        let both = (p.bothLove ?? []).prefix(2).joined(separator: ", ")
        let theirs = (p.dna ?? []).first { $0.who == "them" }?.label
        switch (both.isEmpty, theirs) {
        case (false, let t?): return String(localized: "You both go for \(both). \(first) leans more \(t) than you.")
        case (false, nil): return String(localized: "You both go for \(both).")
        case (true, let t?): return String(localized: "\(first) is into \(t). A good way to find something new.")
        default: return String(localized: "Like and pass a few more finds and this gets sharper.")
        }
    }

    private func dnaCard(_ dna: [FriendProfile.DNA]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(String(localized: "Taste DNA"))
            VStack(spacing: 9) {
                ForEach(dna, id: \.self) { d in
                    HStack(spacing: 10) {
                        Text(d.label).font(.subheadline).foregroundStyle(Theme.ink).lineLimit(1).frame(width: 110, alignment: .leading)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule().fill(fill(d.who)).frame(width: max(10, g.size.width * min(1, max(0.12, d.strength))))
                            }
                        }
                        .frame(height: 8)
                        Text(whoLabel(d.who)).font(.caption).foregroundStyle(Theme.muted).frame(width: 52, alignment: .trailing)
                    }
                }
                HStack(spacing: 14) {
                    legend(String(localized: "You both"), Theme.green)
                    legend(String(localized: "Mostly \(first)"), Theme.hot)
                    legend(String(localized: "Mostly you"), Theme.blue)
                }
                .padding(.top, 2)
            }
            .padding(14).glassCard()
        }
    }

    private func fill(_ who: String) -> AnyShapeStyle {
        switch who {
        case "both": return AnyShapeStyle(Theme.gradient)
        case "them": return AnyShapeStyle(Self.themGradient)
        default: return AnyShapeStyle(Theme.blue)
        }
    }
    private func whoLabel(_ who: String) -> String { who == "both" ? String(localized: "both") : who == "them" ? first : String(localized: "you") }
    private func legend(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(c).frame(width: 7, height: 7); Text(t).font(.caption2).foregroundStyle(Theme.muted) }
    }

    private enum ChipStyle { case both, world }
    private func chips(_ title: String, _ items: [String], style: ChipStyle, action: ((String) -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(title, trailing: action == nil ? nil : String(localized: "Tap one to hunt it"))
            FlowRow {
                ForEach(items, id: \.self) { t in
                    let tint = style == .both ? Theme.green : Theme.cyan
                    let chip = Text(t).font(.footnote).foregroundStyle(tint.opacity(0.95))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(tint.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(tint.opacity(0.45)))
                    if let action { Button { action(t) } label: { chip }.buttonStyle(.plain) } else { chip }
                }
            }
        }
    }

    private func theirWorld(_ items: [String]) -> some View {
        chips(String(localized: "From \(first)'s world"), items, style: .world) { hunting = $0 }
    }

    private func grails(_ g: [FriendProfile.Grail]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(String(localized: "\(first)'s grails"))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(g, id: \.listing.id) { x in
                        tile(x.listing.item, tag: x.tag == "watching" ? String(localized: "WATCHING") : x.tag == "got" ? String(localized: "GOT IT") : String(localized: "LIKED"))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func twins(_ t: [ListingRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(String(localized: "Twin finds"))
            ForEach(t, id: \.id) { l in
                Button { open(l.item) } label: {
                    HStack(spacing: 12) {
                        ProductThumb(item: l.item, size: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(l.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2).multilineTextAlignment(.leading)
                            Text([l.item.priceKnown ? l.item.priceLabel : nil, l.source].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.muted)
                            Label("Both your scouts found this", systemImage: "circle.fill").font(.caption2.weight(.semibold)).foregroundStyle(Theme.green)
                                .labelStyle(TightDot())
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12).glassCard()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func giftRadar(_ gifts: [ListingRow], birthday: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Gift radar", systemImage: "gift.fill").font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                if let b = Birthday.label(birthday) {
                    Text("Birthday · \(b)").font(.caption.weight(.semibold)).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.54))
                        .padding(.horizontal, 9).padding(.vertical, 5).background(Theme.warn.opacity(0.14), in: Capsule())
                }
            }
            Text("Picked for \(first)'s taste by your scouts, under $150.").font(.footnote).foregroundStyle(Theme.muted)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) { ForEach(gifts, id: \.id) { tile($0.item, tag: nil) } }
            }
            .scrollIndicators(.hidden)
        }
        .padding(14)
        .background(LinearGradient(colors: [Theme.warn.opacity(0.12), Theme.hot.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.warn.opacity(0.3)))
    }

    private var notSharing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Taste match is waiting", systemImage: "lock.fill").font(.headline).foregroundStyle(Theme.ink)
            Text(profile?.theyShare == false
                 ? String(localized: "\(first) keeps their taste private. When you both share taste, you'll see your match, their grails, gift ideas and swap Taste Cards.")
                 : String(localized: "Turn on sharing your taste (Friends, then What friends can see) to see your match, \(first)'s grails, gift ideas and swap Taste Cards."))
                .font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }

    @ViewBuilder private var sentRecently: some View {
        let sent = store.state.suggestions.filter { $0.friendID == friend.id }.sorted { $0.date > $1.date }.compactMap { Catalog.item($0.itemID) }.prefix(6)
        if !sent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header(String(localized: "Recently sent you"))
                ScrollView(.horizontal) { HStack(alignment: .top, spacing: 10) { ForEach(Array(sent)) { tile($0, tag: nil) } } }.scrollIndicators(.hidden)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if profile?.shares == true {
                Button { showCards = true } label: { Label("Swap Taste Cards", systemImage: "rectangle.stack.fill") }
                    .buttonStyle(PrimaryButton())
            }
            Button("Suggest something for \(first)") { dismiss(); router.sheet = .suggestFor(friend.id) }
                .font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(Theme.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
            Button("Remove friend") { confirmRemove = true }
                .font(.footnote).foregroundStyle(Theme.muted).padding(.top, 4)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    // MARK: pieces

    private func header(_ t: String, trailing: String? = nil) -> some View {
        HStack {
            Text(t.uppercased()).font(.caption.weight(.semibold)).tracking(1.6).foregroundStyle(Theme.muted)
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(Theme.cyan) }
        }
    }

    private func tile(_ item: Item, tag: String?) -> some View {
        Button { open(item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ProductThumb(item: item, size: 118)
                    .overlay(alignment: .topLeading) {
                        if let tag {
                            Text(tag).font(.system(size: 9, weight: .heavy)).tracking(0.6).foregroundStyle(Theme.warn)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Theme.bg.opacity(0.85), in: RoundedRectangle(cornerRadius: 6)).padding(7)
                        }
                    }
                Text(item.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2).multilineTextAlignment(.leading)
                Text([item.brand.isEmpty ? nil : item.brand, item.priceKnown ? item.priceLabel : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(width: 118, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func open(_ item: Item) {
        guard let url = BuyLink.url(item) else { return }
        UIApplication.shared.open(url)
    }
}

private struct TightDot: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.font(.system(size: 6)); configuration.title }
    }
}

private extension View {
    func glassCard() -> some View {
        background(Theme.glass, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
    }
}

// MARK: - Taste Cards

/// One collectible card. Used in the swap sheet, the Friends collection and the share image.
struct TasteCardView: View {
    let card: TasteCard
    let name: String
    var match: Int?
    var width: CGFloat = 310

    private var colors: [Color] {
        let p = card.palette.compactMap { Color(hex: $0) }
        let base = [Color(red: 1, green: 0.54, blue: 0.36), Theme.hot, Color(red: 0.48, green: 0.24, blue: 1)]
        // The card's own palette tints the gradient's top so every card looks like its owner.
        return p.count >= 2 ? [p[0].mix(with: base[0], by: 0.55), base[1], base[2]] : base
    }

    var body: some View {
        let s = width / 310
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("BAGET · TASTE CARD").font(.system(size: 10.5 * s, weight: .heavy)).tracking(1.4)
                Spacer()
                if let n = card.number { Text("No. \(String(format: "%04d", n))").font(.system(size: 10.5 * s, weight: .heavy)).tracking(1.4) }
            }
            .opacity(0.9)
            Text(String(name.first ?? "?").uppercased()).font(.system(size: 26 * s, weight: .heavy))
                .frame(width: 62 * s, height: 62 * s).background(Circle().fill(Color.white.opacity(0.22)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 2)).padding(.top, 20 * s)
            Text(name).font(.system(size: 27 * s, weight: .black)).lineLimit(1).minimumScaleFactor(0.6).padding(.top, 10 * s)
            Text("✦ \(card.archetype)").font(.system(size: 14.5 * s, weight: .bold)).lineLimit(2).padding(.top, 4 * s)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 9 * s), GridItem(.flexible(), spacing: 9 * s)], spacing: 9 * s) {
                stat(String(localized: "SIGNATURE"), card.signature.joined(separator: ", "), s)
                stat(String(localized: "NOTES"), card.notes.joined(separator: ", "), s)
                stat(String(localized: "HUNTS"), card.hunts.joined(separator: ", "), s)
                stat(String(localized: "GRAIL"), card.grail ?? "—", s)
            }
            .padding(.top, 16 * s)
            HStack(spacing: 6 * s) {
                ForEach(Array(card.palette.prefix(5).enumerated()), id: \.offset) { _, hex in
                    RoundedRectangle(cornerRadius: 7 * s).fill(Color(hex: hex) ?? .gray).frame(height: 20 * s)
                        .overlay(RoundedRectangle(cornerRadius: 7 * s).strokeBorder(Color.white.opacity(0.4)))
                }
            }
            .padding(.top, 14 * s)
            Spacer(minLength: 10 * s)
            HStack {
                if let match { Text("\(match)% match with you") }
                Spacer()
                Text(Date.now.formatted(.dateTime.month(.abbreviated).year()))
            }
            .font(.system(size: 11 * s, weight: .bold)).opacity(0.9)
        }
        .foregroundStyle(.white)
        .padding(18 * s)
        .frame(width: width, height: width * 1.5)
        .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1)).allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 26 * s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26 * s, style: .continuous).strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.45), radius: 24 * s, y: 18 * s)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ label: String, _ value: String, _ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4 * s) {
            Text(label).font(.system(size: 9 * s, weight: .heavy)).tracking(1.1).opacity(0.85)
            Text(value.isEmpty ? "—" : value).font(.system(size: 13.5 * s, weight: .bold)).lineLimit(2).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 58 * s, alignment: .topLeading)
        .padding(10 * s)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 13 * s, style: .continuous))
    }
}

private extension Color {
    func mix(with other: Color, by t: Double) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var (r1, g1, b1, a1, r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0, 0, 0, 0, 0)
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1); b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t)
    }
}

/// "Swap Taste Cards": their card and yours, flip between them, share either as an image.
struct TasteCardSwapView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let friendName: String
    let theirs: TasteCard?
    let mine: TasteCard?
    let match: Int?
    @State private var showingMine = false

    var body: some View {
        VStack(spacing: 18) {
            Text(showingMine ? String(localized: "YOUR TASTE CARD") : String(localized: "\(friendName.uppercased())'S TASTE CARD"))
                .font(.caption.weight(.bold)).tracking(2).foregroundStyle(Theme.muted).padding(.top, 28)
            ZStack {
                if let c = showingMine ? mine : theirs {
                    TasteCardView(card: c, name: showingMine ? (store.state.profile?.displayName ?? String(localized: "You")) : friendName, match: showingMine ? nil : match)
                        .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity))
                        .id(showingMine)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles.rectangle.stack").font(.system(size: 34)).foregroundStyle(Theme.cyan)
                        Text("This card is being made").font(.headline).foregroundStyle(Theme.ink)
                        Text("Baget writes a Taste Card from what someone likes and passes on. Check back after a few more likes.")
                            .font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    }
                    .frame(width: 310, height: 465).background(Theme.glass, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
            }
            .onTapGesture { withAnimation(.snappy) { showingMine.toggle() } }
            HStack(spacing: 10) {
                Button(showingMine ? String(localized: "See \(friendName.split(separator: " ").first.map(String.init) ?? friendName)'s") : String(localized: "See mine")) {
                    withAnimation(.snappy) { showingMine.toggle() }
                }
                .font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
                if let c = showingMine ? mine : theirs, let image = shareImage(c) {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview(String(localized: "Taste Card"), image: Image(uiImage: image))) {
                        Label("Share", systemImage: "square.and.arrow.up").font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .foregroundStyle(Theme.accentInk)
                            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(width: 310)
            Text("Cards swap when you both share taste, and they update as your taste changes. Tap the card to flip.")
                .font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(width: 290)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) { CloseButton { dismiss() }.padding(.top, 14).padding(.trailing, 16) }
        .background(LitBackground())
        .preferredColorScheme(.dark)
    }

    @MainActor private func shareImage(_ c: TasteCard) -> UIImage? {
        let r = ImageRenderer(content: TasteCardView(card: c, name: showingMine ? (store.state.profile?.displayName ?? "") : friendName, match: showingMine ? nil : match)
            .padding(30).background(Theme.bg))
        r.scale = 3
        return r.uiImage
    }
}

/// Friends tab: the Taste Cards your friends have swapped with you.
struct TasteCardsRow: View {
    @Environment(AppStore.self) private var store
    @State private var cards: [TasteCard] = []
    @State private var mine: TasteCard?
    @State private var open: TasteCard?

    var body: some View {
        Group {
            if !cards.isEmpty || mine != nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "TASTE CARDS")).font(.caption.weight(.semibold)).tracking(1.6).foregroundStyle(Theme.muted)
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            if let mine {
                                Button { open = mine } label: { mini(mine, store.state.profile?.displayName ?? String(localized: "You"), String(localized: "You")) }
                            }
                            ForEach(cards, id: \.self) { c in
                                Button { open = c } label: { mini(c, c.name ?? c.handle ?? "", c.name ?? "") }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .scrollIndicators(.hidden)
                    .buttonStyle(.plain)
                }
            }
        }
        .task { mine = await store.myTasteCard(); cards = await store.friendCards() }
        .sheet(item: Binding(get: { open.map { IdentifiedCard(card: $0) } }, set: { open = $0?.card })) { x in
            VStack {
                TasteCardView(card: x.card, name: x.card.name ?? store.state.profile?.displayName ?? "").padding(.top, 40)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) { CloseButton { open = nil }.padding(.top, 14).padding(.trailing, 16) }
            .background(LitBackground()).presentationDetents([.large])
        }
    }

    private func mini(_ c: TasteCard, _ name: String, _ caption: String) -> some View {
        VStack(spacing: 6) {
            TasteCardView(card: c, name: name, width: 110).shadow(radius: 0)
            Text(caption).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 110)
        }
    }
}

private struct IdentifiedCard: Identifiable { let card: TasteCard; var id: String { (card.friendId ?? "me") + card.archetype } }

/// Friends privacy: your birthday (month and day), so friends' gift radar can mention it.
/// Your birthday (month and day). Friends see it when it's coming up, with gift ideas for your taste if you both share taste.
struct BirthdayRow: View {
    @Environment(AppStore.self) private var store
    @State private var on = false
    @State private var month = Calendar.current.component(.month, from: .now)
    @State private var day = Calendar.current.component(.day, from: .now)
    @State private var loaded = false
    var showsCaption = true

    private static let months: [String] = {
        let f = DateFormatter(); f.locale = .current
        return f.standaloneMonthSymbols ?? f.monthSymbols ?? (1...12).map(String.init)
    }()
    private var daysIn: Int { [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][max(0, min(11, month - 1))] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $on) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("My birthday", systemImage: "gift").foregroundStyle(Theme.ink)
                    if showsCaption {
                        Text("Month and day only. Friends get a heads-up when it's coming up, with gift ideas for your taste.")
                            .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .disabled(!loaded)
            if on {
                HStack(spacing: 10) {
                    Picker("Month", selection: $month) {
                        ForEach(1...12, id: \.self) { m in Text(Self.months[m - 1]).tag(m) }
                    }
                    Picker("Day", selection: $day) {
                        ForEach(1...daysIn, id: \.self) { d in Text("\(d)").tag(d) }
                    }
                    Spacer()
                }
                .pickerStyle(.menu)
                .tint(Theme.cyan)
            }
        }
        .task {
            if let b = await store.myBirthday(), b.count == 5, let m = Int(b.prefix(2)), let d = Int(b.suffix(2)) {
                month = m; day = d; on = true
            }
            loaded = true
        }
        .onChange(of: on) { _, _ in save() }
        .onChange(of: month) { _, _ in
            if day > daysIn { day = daysIn }
            save()
        }
        .onChange(of: day) { _, _ in save() }
    }

    private func save() {
        guard loaded else { return }
        let value = on ? String(format: "%02d-%02d", month, min(day, daysIn)) : nil
        Task { await store.setBirthday(value) }
    }
}

// MARK: - Upcoming birthdays (Friends tab)

struct UpcomingBirthday: Decodable, Identifiable, Hashable {
    let friendId: String
    let name: String?
    let handle: String?
    let birthday: String
    let days: Int
    let shares: Bool
    var id: String { friendId }
    var first: String {
        let n = (name ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "@\(handle ?? "")" : (n.split(separator: " ").first.map(String.init) ?? n)
    }
    var when: String {
        switch days {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Tomorrow")
        default: return String(localized: "In \(days) days")
        }
    }
}

extension AppStore {
    /// Friends whose birthday is within the next three weeks, soonest first.
    func upcomingBirthdays() async -> [UpcomingBirthday] {
        guard isCloud else { return [] }
        return (try? await api.rpc("upcoming_birthdays", ["p_days": 21])) ?? []
    }
}

/// A friend's birthday coming up: when it is, gift picks for their taste, and a way to send them something.
struct BirthdayCard: View {
    @Environment(AppStore.self) private var store
    let birthday: UpcomingBirthday
    let friend: Friend?
    let openProfile: () -> Void
    @State private var gifts: [Item] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(birthday.days == 0 ? "🎂" : "🎁").font(.system(size: 24))
                    .frame(width: 46, height: 46)
                    .background(Theme.warn.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(birthday.days == 0 ? String(localized: "It's \(birthday.first)'s birthday!") : String(localized: "\(birthday.first)'s birthday is coming up"))
                        .font(.headline).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    Text("\(birthday.when) · \(Birthday.label(birthday.birthday) ?? "")")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.54))
                }
                Spacer(minLength: 0)
            }
            if !gifts.isEmpty {
                Text("Picked for \(birthday.first)'s taste by your scouts:").font(.footnote).foregroundStyle(Theme.muted)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(gifts) { item in
                            Button { if let url = BuyLink.url(item) { UIApplication.shared.open(url) } } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    ProductThumb(item: item, size: 104)
                                    Text(item.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2).multilineTextAlignment(.leading)
                                    Text([item.brand.isEmpty ? nil : item.brand, item.priceKnown ? item.priceLabel : nil].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                                .frame(width: 104, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            } else if !birthday.shares {
                Text("When you both share taste, your scouts pick gift ideas for \(birthday.first) here.")
                    .font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if friend != nil {
                    Button(action: openProfile) {
                        Text(birthday.shares ? String(localized: "More gift ideas") : String(localized: "See \(birthday.first)'s profile"))
                            .font(.subheadline.weight(.heavy)).foregroundStyle(Color(red: 0.11, green: 0.08, blue: 0.02))
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Theme.warn, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(LinearGradient(colors: [Theme.warn.opacity(0.14), Theme.hot.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.warn.opacity(0.32)))
        .task(id: birthday.id) {
            #if DEBUG
            if FriendPreview.enabled { gifts = (FriendPreview.profile.gifts ?? []).map(\.item); return }
            #endif
            guard birthday.shares, let p = await store.friendProfile(birthday.friendId) else { return }
            gifts = (p.gifts ?? []).prefix(6).map(\.item)
        }
    }
}

#if DEBUG
/// Launched with -BagetFriendPreview (QA walkthrough): the friend profile and Taste Card with sample data.
enum FriendPreview {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-BagetFriendPreview") }
    static let friend = Friend(id: "preview", name: "Hetty", handle: "@hetty", hunts: [.fragrance, .cars], likes: [], isSample: false, replies: [])
    static func listing(_ id: String, _ title: String, _ brand: String, _ price: Double, _ source: String) -> ListingRow {
        ListingRow(id: id, title: title, brand: brand, category: "fragrance", sku: "", price: price, market: nil, source: source, url: "https://example.com/\(id)",
                   imageUrl: nil, dropAt: nil, soldOut: false, creator: nil, traits: [], tags: [], sizesInStock: nil, firstSeenAt: nil, offers: nil,
                   lowPrice: nil, lowStore: nil, about: nil, brandAbout: nil)
    }
    static var card: TasteCard { TasteCard(archetype: "The Fresh Minimalist", signature: ["Le Labo", "Frédéric Malle"], notes: ["vetiver", "lime", "sandalwood"],
                                           hunts: ["Fragrance", "Cars"], grail: "Vetiver Extraordinaire", palette: ["#d9e8c4", "#9fb88a", "#e9dcc3", "#6f5a43", "#f4f1ea"], number: 42) }
    static var profile: FriendProfile {
        var p = FriendProfile(friendId: "preview", handle: "hetty", name: "Hetty", since: Calendar.current.date(byAdding: .day, value: -8, to: .now), shares: true, theyShare: true)
        p.match = 78
        p.dna = [.init(label: "Woody", who: "both", strength: 0.9), .init(label: "Niche", who: "both", strength: 0.75),
                 .init(label: "Citrus", who: "them", strength: 0.82), .init(label: "Le Labo", who: "them", strength: 0.7), .init(label: "Oud", who: "you", strength: 0.9)]
        p.bothLove = ["Extrait", "Le Labo", "Sandalwood", "Vetiver", "Long lasting"]
        p.theirWorld = ["Vetiver Extraordinaire", "Limette 37", "Frédéric Malle", "BMW X5 PHEV"]
        p.hunts = ["fragrance", "cars"]
        p.grails = [.init(listing: listing("g1", "Vetiver Extraordinaire", "Frédéric Malle", 310, "Twisted Lily"), tag: "watching"),
                    .init(listing: listing("g2", "Limette 37", "Le Labo", 335, "Le Labo"), tag: "liked")]
        p.twins = [listing("t1", "Cologne Indélébile", "Frédéric Malle", 285, "Frédéric Malle")]
        p.gifts = [listing("x1", "Santal 26 Candle", "Le Labo", 92, "Le Labo"), listing("x2", "Vetiver Discovery Set", "Maison Crivelli", 48, "Luckyscent"),
                   listing("x3", "Hinoki Body Wash", "Aesop", 45, "Aesop")]
        p.birthday = "11-12"
        p.card = card
        p.myCard = TasteCard(archetype: "The Oud Collector", signature: ["Amouage", "Roja"], notes: ["oud", "amber", "leather"], hunts: ["Fragrance"],
                             grail: "Amouage Interlude Man", palette: ["#3a2418", "#8c5a2b", "#c9a46a", "#1d1a17", "#e8dcc4"], number: 1)
        return p
    }
}
#endif


/// The round ✕ in the top corner of a sheet.
struct CloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}
