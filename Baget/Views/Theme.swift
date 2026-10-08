import SwiftUI

/// Deep navy lit with blue, cyan and green, glass panels, gradient actions. Same look as the web prototype.
enum Theme {
    static let bg = Color(red: 0.02, green: 0.04, blue: 0.09)
    static let panel = Color(red: 0.05, green: 0.08, blue: 0.15)
    static let ink = Color(red: 0.92, green: 0.95, blue: 1.0)
    static let muted = Color(red: 0.55, green: 0.62, blue: 0.73)
    static let line = Color(red: 0.58, green: 0.75, blue: 1.0).opacity(0.14)
    static let glass = Color(red: 0.58, green: 0.75, blue: 1.0).opacity(0.06)
    static let blue = Color(red: 0.23, green: 0.51, blue: 1.0)
    static let cyan = Color(red: 0.13, green: 0.83, blue: 0.93)
    static let green = Color(red: 0.20, green: 0.90, blue: 0.65)
    static let accent = Color(red: 0.31, green: 0.76, blue: 1.0)
    static let accentInk = Color(red: 0.01, green: 0.07, blue: 0.11)
    static let warn = Color(red: 1.0, green: 0.78, blue: 0.34)
    static let hot = Color(red: 1.0, green: 0.36, blue: 0.49)

    static let gradient = LinearGradient(colors: [blue, cyan, green], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let barGradient = LinearGradient(colors: [blue, cyan, green], startPoint: .bottom, endPoint: .top)
}

/// The lit background behind every screen.
struct LitBackground: View {
    var body: some View {
        ZStack {
            Theme.bg
            RadialGradient(colors: [Theme.blue.opacity(0.30), .clear], center: .init(x: -0.1, y: 0.15), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Theme.cyan.opacity(0.22), .clear], center: .init(x: 0.95, y: -0.05), startRadius: 0, endRadius: 480)
            RadialGradient(colors: [Theme.green.opacity(0.16), .clear], center: .init(x: 0.6, y: 1.1), startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

struct GlassCard: ViewModifier {
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.glass.opacity(1.3), Theme.glass.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(highlighted ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.line), lineWidth: 1)
            )
    }
}

extension View {
    func glassCard(highlighted: Bool = false) -> some View { modifier(GlassCard(highlighted: highlighted)) }
    func gradientText() -> some View { foregroundStyle(Theme.gradient) }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Theme.accentInk)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .shadow(color: Theme.cyan.opacity(0.35), radius: 10, y: 4)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Theme.glass, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.line))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct Pill: View {
    let text: String
    var selected = false
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selected ? Theme.accentInk : Theme.ink)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background {
                if selected { Capsule().fill(Theme.gradient) } else { Capsule().fill(Theme.glass) }
            }
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.line))
    }
}

struct Tag: View {
    let text: String
    var tint: Color? = nil
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint ?? Theme.ink)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill((tint ?? Theme.accent).opacity(tint == nil ? 0.10 : 0.14)))
    }
}

/// Wrapping row of tags.
struct FlowRow<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: () -> Content
    var body: some View {
        FlowLayout(spacing: spacing) { content() }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

struct Meter: View {
    let value: Double   // 0...1
    var tint: AnyShapeStyle = AnyShapeStyle(Theme.gradient)
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.glass.opacity(1.6))
                Capsule().fill(tint).frame(width: max(4, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 6)
    }
}

/// Gradient tile with the maker's initials, standing in for product photos.
struct Plate: View {
    let item: Item
    let label: String
    var live = false
    var height: CGFloat = 120
    var lead = false
    @State private var photo: ProductPhoto?

    private var photoURL: URL? {
        guard let s = item.imageURL, s.hasPrefix("https://") else { return nil }
        return URL(string: s)
    }
    private var radius: CGFloat { lead ? 22 : 18 }
    /// A photo that couldn't be cut out shows on white, the way stores shoot products.
    private var onWhite: Bool { photo.map { !$0.lifted } ?? false }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            if let photo {
                Image(uiImage: photo.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .shadow(color: photo.lifted ? .black.opacity(0.45) : .clear, radius: 14, y: 8)
                    .padding(.horizontal, photo.lifted ? 18 : 10)
                    .padding(.top, 30)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(item.title)
                    .transition(.opacity)
            }
            VStack(alignment: .leading) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(live ? .white : (photo != nil ? Theme.ink : (lead ? Theme.accentInk : Theme.ink)))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(live ? Theme.hot : (photo != nil ? Theme.bg.opacity(0.85) : (lead ? Color.white.opacity(0.25) : Theme.bg.opacity(0.6)))))
                Spacer()
                if photo == nil {
                    Text(initials)
                        .font(.system(size: lead ? 84 : 40, weight: .heavy))
                        .tracking(-2)
                        .foregroundStyle(lead ? Theme.accentInk : Theme.ink)
                }
                Text(item.sku.isEmpty ? item.source : "\(item.sku) · \(item.source)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(onWhite ? Color.black.opacity(0.5) : (photo != nil ? Theme.muted : (lead ? Theme.accentInk.opacity(0.7) : Theme.muted)))
                    .lineLimit(1)
            }
            .padding(12)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: photoURL) {
            guard let url = photoURL else { photo = nil; return }
            if let hit = ImageCache.shared.cached(url) { photo = hit; return }
            let p = await ImageCache.shared.load(url)
            withAnimation(.easeOut(duration: 0.25)) { photo = p }
        }
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if onWhite {
            shape.fill(Color.white)
        } else if photo != nil {
            // Cut-out product on a soft spotlight.
            shape.fill(Theme.panel)
            shape.fill(RadialGradient(colors: [Theme.cyan.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: height * 0.8))
            shape.strokeBorder(Theme.line)
        } else if lead {
            shape.fill(Theme.gradient)
        } else {
            shape.fill(Theme.glass)
            shape.fill(RadialGradient(colors: [Theme.blue.opacity(0.4), .clear], center: .topLeading, startRadius: 0, endRadius: 220))
            shape.fill(RadialGradient(colors: [Theme.green.opacity(0.28), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 220))
        }
    }

    var initials: String { item.brand.split(separator: " ").compactMap { $0.first }.prefix(3).map { String($0) }.joined().uppercased() }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.title3.weight(.bold))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyCard: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(28)
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [5])))
    }
}
