import SwiftUI

// MARK: - Rings

/// A ring around someone's icon. Owned rings come from the server (my_rings / friend_icons); the app only draws them.
enum Ring: String, CaseIterable, Identifiable {
    case creator, founding, firstLike = "first_like", crew3 = "crew_3", streak7 = "streak_7", firstBuy = "first_buy", proGlow = "pro_glow"
    var id: String { rawValue }

    /// The order rings are listed in.
    static let listed: [Ring] = [.creator, .founding, .firstLike, .crew3, .streak7, .firstBuy, .proGlow]
    /// Rings anyone can earn by using Baget (creator and founding are given, never earned).
    static let earnable: [Ring] = [.firstLike, .crew3, .streak7, .firstBuy]

    var name: String {
        switch self {
        case .creator: String(localized: "Creator · 1 of 1")
        case .founding: String(localized: "Founding tester")
        case .firstLike: String(localized: "First like")
        case .crew3: String(localized: "Crew of 3")
        case .streak7: String(localized: "7-day streak")
        case .firstBuy: String(localized: "First buy")
        case .proGlow: String(localized: "Pro glow")
        }
    }
    var short: String {
        switch self {
        case .creator: String(localized: "Creator")
        case .founding: String(localized: "Founding")
        default: name
        }
    }
    var detail: String {
        switch self {
        case .creator: String(localized: "The one and only. Worn by Baget's creator.")
        case .founding: String(localized: "Gold and silver, for Baget's founding testers. Given, never earned, so no one else can ever get it.")
        case .firstLike: String(localized: "Heart your first find.")
        case .crew3: String(localized: "Add three friends.")
        case .streak7: String(localized: "Like or pass finds 7 days in a row.")
        case .firstBuy: String(localized: "Buy something your scout found.")
        case .proGlow: String(localized: "A ring that shimmers. Pro members only.")
        }
    }

    /// The ring's colors. Gold and silver belong to Founding tester alone; black and gold to Creator alone.
    var colors: [Color] {
        switch self {
        case .creator: [Color(red: 0.06, green: 0.06, blue: 0.07), Color(red: 0.96, green: 0.82, blue: 0.48), Color(red: 0.10, green: 0.09, blue: 0.08),
                        Color(red: 0.91, green: 0.71, blue: 0.63), Color(red: 0.05, green: 0.05, blue: 0.06), Color(red: 1.0, green: 0.88, blue: 0.55),
                        Color(red: 0.06, green: 0.06, blue: 0.07)]
        case .founding: [Color(red: 0.97, green: 0.91, blue: 0.66), Color(red: 0.83, green: 0.65, blue: 0.22), Color(red: 1.0, green: 0.96, blue: 0.84),
                         Color(red: 0.79, green: 0.81, blue: 0.84), Color(red: 0.56, green: 0.59, blue: 0.64), Color(red: 0.93, green: 0.95, blue: 0.96),
                         Color(red: 0.73, green: 0.54, blue: 0.16), Color(red: 0.97, green: 0.91, blue: 0.66)]
        case .firstLike: [Theme.green, Color(red: 0.62, green: 0.96, blue: 0.81), Theme.green]
        case .crew3: [Theme.hot, Color(red: 0.55, green: 0.36, blue: 0.96), Theme.hot]
        case .streak7: [Color(red: 1, green: 0.54, blue: 0.36), Theme.hot, Theme.warn, Color(red: 1, green: 0.54, blue: 0.36)]
        case .firstBuy: [Theme.blue, Theme.cyan, Theme.green, Color(red: 0.55, green: 0.36, blue: 0.96), Theme.blue]
        case .proGlow: [Theme.blue, Theme.cyan, Theme.green, Theme.warn, Theme.hot, Color(red: 0.55, green: 0.36, blue: 0.96), Theme.blue]
        }
    }
    /// The little seal on the ring's edge (only the two rings that can't be earned have one).
    var seal: String? {
        switch self {
        case .creator: "crown.fill"
        case .founding: "star.fill"
        default: nil
        }
    }
    var glow: Color? {
        switch self {
        case .creator: Color(red: 0.96, green: 0.80, blue: 0.40)
        case .founding: Color(red: 0.94, green: 0.80, blue: 0.45)
        case .proGlow: Theme.cyan
        default: nil
        }
    }
}

/// Your rings, as the server sees them.
struct RingState: Decodable, Equatable {
    struct Owned: Decodable, Equatable { let ring: String; let earnedAt: Date? }
    let owned: [Owned]
    let new: [String]
    let wearing: String?
    let pro: Bool
    let streak: Int
    let friends: Int
    let palette: [String]?

    func owns(_ r: Ring) -> Bool { r == .proGlow ? pro : owned.contains { $0.ring == r.rawValue } }
}

extension AppStore {
    /// Fetches your rings (awarding any you've just earned).
    func refreshRings() async {
        guard isCloud, let r: RingState = try? await api.rpc("my_rings") else { return }
        rings = r
        if let fresh = r.new.first { ringEarned = fresh }
    }

    /// Wear a ring you own (nil takes it off). The server refuses rings you don't own.
    func wearRing(_ ring: Ring?) async -> Bool {
        guard isCloud, let uid = api.userID else { return false }
        do {
            let value: Any = ring.map { $0.rawValue as Any } ?? NSNull()
            try await api.update("profiles", "id=eq.\(uid)", ["ring": value])
            await refreshRings()
            Analytics.track(.avatarChanged, ["ring": ring?.rawValue ?? "none"])
            return true
        } catch { return false }
    }

    /// Your Taste Card's palette, when it has one.
    var myPalette: [String] { rings?.palette ?? [] }
}

/// Draws an icon inside its ring, keeping the same overall size. No ring: just the icon.
struct RingFrame<Content: View>: View {
    let ring: Ring?
    let size: CGFloat
    @ViewBuilder let content: (CGFloat) -> Content
    @State private var spin = false

    var body: some View {
        if let ring {
            let width = max(2, size * 0.075)
            ZStack {
                content(size - width * 2.6)
                Circle()
                    .strokeBorder(AngularGradient(colors: ring.colors, center: .center), lineWidth: width)
                    .rotationEffect(.degrees(ring == .proGlow && spin ? 360 : 0))
                    .animation(ring == .proGlow ? .linear(duration: 6).repeatForever(autoreverses: false) : nil, value: spin)
                    .shadow(color: (ring.glow ?? .clear).opacity(0.55), radius: size * 0.08)
                if ring == .founding || ring == .creator {
                    // A sheen across the metal.
                    Circle().strokeBorder(LinearGradient(colors: [.clear, .white.opacity(0.75), .clear], startPoint: UnitPoint(x: 0.15, y: 0.1), endPoint: UnitPoint(x: 0.85, y: 0.9)),
                                          lineWidth: width * 0.6)
                        .blendMode(.overlay)
                }
                if let seal = ring.seal, size >= 30 {
                    Image(systemName: seal)
                        .font(.system(size: size * 0.13, weight: .heavy))
                        .foregroundStyle(ring == .creator ? Color(red: 1, green: 0.86, blue: 0.5) : Color(red: 0.23, green: 0.16, blue: 0.02))
                        .frame(width: size * 0.28, height: size * 0.28)
                        .background(Circle().fill(ring == .creator
                            ? AnyShapeStyle(Color(red: 0.06, green: 0.06, blue: 0.07))
                            : AnyShapeStyle(AngularGradient(colors: Ring.founding.colors, center: .center))))
                        .overlay(Circle().strokeBorder(ring == .creator ? Color(red: 1, green: 0.86, blue: 0.5) : Theme.bg, lineWidth: max(1, size * 0.02)))
                        .offset(x: size * 0.35, y: size * 0.35)
                }
            }
            .frame(width: size, height: size)
            .onAppear { spin = true }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(ring.name)
        } else {
            content(size)
        }
    }
}

// MARK: - Baget icons

/// Icons drawn for Baget (SF Symbols, shown in white on your color). Only symbols this phone has are offered.
enum BagetGlyph {
    static let all: [String] = ["shoe.fill", "tshirt.fill", "drop.fill", "watch.analog", "binoculars.fill", "bag.fill", "handbag.fill",
                                "car.fill", "tag.fill", "crown.fill", "sunglasses.fill", "diamond.fill", "flame.fill", "headphones",
                                "camera.fill", "skateboard.fill", "basketball.fill", "sofa.fill", "gift.fill", "sparkles"]
    static let available: [String] = all.filter { UIImage(systemName: $0) != nil }
}

/// The fill behind an initials, emoji or Baget icon: a palette color, or your Taste Card's colors.
enum AvatarFill {
    static func style(_ color: Int, palette: [String]?) -> AnyShapeStyle {
        if color == AvatarPalette.taste, let p = palette?.compactMap({ Color(hex: $0) }), p.count >= 2 {
            return AnyShapeStyle(AngularGradient(colors: p + [p[0]], center: .center))
        }
        return AnyShapeStyle(AvatarPalette.gradient(color == AvatarPalette.taste ? 0 : color))
    }
    static func ink(_ color: Int) -> Color { color == AvatarPalette.taste ? .white : AvatarPalette.ink(color) }
}

// MARK: - Your rings

struct RingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @State private var working: Ring?

    var body: some View {
        let state = store.rings
        let shown = Ring.listed.filter { r in r == .creator || r == .founding ? (state?.owns(r) ?? false) : true }
        List {
            Section {
                ForEach(shown) { r in row(r, state) }
            } footer: {
                Text("Wear one around your icon. Friends see it in Your circle and on your profile.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(LitBackground())
        .navigationTitle("Your rings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refreshRings() }
    }

    private func row(_ r: Ring, _ s: RingState?) -> some View {
        let owned = s?.owns(r) ?? false
        let wearing = s?.wearing == r.rawValue
        return HStack(spacing: 13) {
            RingFrame(ring: r, size: 50) { inner in Circle().fill(Theme.panel).frame(width: inner, height: inner) }
                .opacity(owned ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.name).font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                Text(r.detail).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if r == .streak7, !owned, let n = s?.streak {
                    ProgressView(value: Double(min(n, 7)), total: 7).tint(Theme.cyan)
                    Text("\(min(n, 7)) of 7 days").font(.caption2).foregroundStyle(Theme.muted)
                } else if r == .crew3, !owned, let n = s?.friends {
                    Text("\(min(n, 3)) of 3 friends").font(.caption2).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 6)
            if wearing {
                Button { Task { working = r; _ = await store.wearRing(nil); working = nil } } label: {
                    Text("Wearing").font(.caption.weight(.heavy)).foregroundStyle(Theme.bg)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Tap to take it off")
            } else if owned {
                Button { Task { working = r; if await store.wearRing(r) { router.say(String(localized: "Wearing \(r.short)")) }; working = nil } } label: {
                    Text(working == r ? "…" : String(localized: "Wear")).font(.caption.weight(.heavy)).foregroundStyle(Theme.green)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(Theme.green.opacity(0.15)))
                }
                .buttonStyle(.plain)
            } else {
                Text(r == .proGlow ? String(localized: "Pro") : String(localized: "Locked")).font(.caption.weight(.heavy)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(Color.white.opacity(0.07)))
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Theme.glass)
    }
}
