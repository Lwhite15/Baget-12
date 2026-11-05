import SwiftUI
import UIKit

// iPhone Duo (the foldable). Closed, Baget runs on the outer display like any iPhone. Open, the inner display
// reports a regular-width size class and has a fold down the middle. Baget is iPhone-only and portrait-locked,
// so on a phone, regular width means the Duo's inner display.
//
// What this file does there:
//  * Grids go from 2 to 4 columns, with the middle gap widened to clear the fold, so no tile sits in the crease.
//  * Button rows (Like / Pass / Buy) split around the fold, so no button sits in it.
//
// The fold's real position comes from Apple's reserved-regions API in the iOS 27.1 SDK. The cloud build turns on
// the DUO_SDK flag only when it builds with that SDK; without it, Baget assumes a centered fold of the standard width.

enum Duo {
    /// This phone is an iPhone Duo. Its two displays have their own native sizes (outer 1398×2034, inner 2007×2853
    /// pixels), unlike any other iPhone. Used for the few things that are about the device rather than the space
    /// (the brand bar, bar buttons); layout itself goes by size class and the fold. Set by detect() at launch.
    nonisolated(unsafe) private(set) static var isDuo = false

    @MainActor @discardableResult static func detect() -> Bool {
        let screens = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }
        let sizes: [(CGFloat, CGFloat)] = [(1398, 2034), (2007, 2853)]
        isDuo = screens.contains { s in
            let n = s.nativeBounds.size
            let (a, b) = (min(n.width, n.height), max(n.width, n.height))
            return sizes.contains { $0.0 == a && $0.1 == b }
        }
        return isDuo
    }

    /// The fold's frame is 40 pt wide (margins included). A little extra keeps tile edges off it.
    static let foldGap: CGFloat = 44

    /// Where the fold crosses a view, in that view's own coordinates.
    struct Fold: Equatable {
        var minX: CGFloat
        var maxX: CGFloat
        var width: CGFloat { maxX - minX }
        /// The fold sits in the middle of this view, give or take a few points.
        func isCentered(in width: CGFloat) -> Bool { abs((minX + maxX) / 2 - width / 2) < 6 }
    }

    /// The vertical fold crossing this view, if the SDK can report one. Includes the fold while it's inactive,
    /// so the layout plans around it and doesn't jump as the hinge moves.
    static func fold(in proxy: GeometryProxy) -> Fold? {
        #if DUO_SDK && !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let band = proxy.reservedRegions(kind: .division, options: .includeInactive)
                .map(\.frame)
                .first { $0.height > $0.width && $0.intersects(bounds) }
            if let b = band { return Fold(minX: max(0, b.minX), maxX: min(proxy.size.width, b.maxX)) }
        }
        #endif
        return nil
    }

    /// Grid columns: 2 on a regular phone screen; 4 on the Duo's inner display, with the middle gap clearing the fold.
    static func columns(wide: Bool, spacing: CGFloat, fold: Fold?, width: CGFloat) -> [GridItem] {
        guard wide else { return [GridItem(.flexible(), spacing: spacing), GridItem(.flexible(), spacing: spacing)] }
        // A fold that isn't in the middle (an asymmetric inset, say) can't line up with a column gap: keep it even.
        let middle: CGFloat
        if let f = fold { middle = f.isCentered(in: width) ? max(spacing, f.width + 4) : spacing }
        else { middle = foldGap }
        return [
            GridItem(.flexible(), spacing: spacing),
            GridItem(.flexible(), spacing: middle),
            GridItem(.flexible(), spacing: spacing),
            GridItem(.flexible(), spacing: spacing),
        ]
    }
}

/// A grid of tiles that uses the Duo's inner display: 2 columns on a phone, 4 when open, none in the fold.
struct FoldGrid<Content: View>: View {
    var spacing: CGFloat = 10
    var alignment: HorizontalAlignment = .center
    @ViewBuilder var content: Content
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var fold: Duo.Fold?
    @State private var width: CGFloat = 0

    var body: some View {
        LazyVGrid(columns: Duo.columns(wide: hSize == .regular, spacing: spacing, fold: fold, width: width),
                  alignment: alignment, spacing: spacing) {
            content
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onGeometryChange(for: Duo.Fold?.self) { Duo.fold(in: $0) } action: { fold = $0 }
    }
}

/// A row of buttons. On a phone it's a plain centered row. On the Duo's inner display the leading buttons sit left
/// of the fold and the trailing ones right of it, so nothing you tap is in the crease.
struct FoldRow<Leading: View, Trailing: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var fold: Duo.Fold?
    @State private var width: CGFloat = 0

    var body: some View {
        if hSize == .regular {
            let gap = fold?.width ?? Duo.foldGap
            HStack(spacing: 0) {
                HStack(spacing: spacing) { leading }
                    .padding(.trailing, spacing / 2)
                    .frame(width: max(0, fold?.minX ?? (width - gap) / 2), alignment: .trailing)
                Color.clear.frame(width: gap, height: 1).accessibilityHidden(true)
                HStack(spacing: spacing) { trailing }
                    .padding(.leading, spacing / 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onGeometryChange(for: Duo.Fold?.self) { Duo.fold(in: $0) } action: { fold = $0 }
        } else {
            HStack(spacing: spacing) { leading; trailing }
        }
    }
}

extension View {
    /// Keeps a full-width card at a sensible size on the Duo's inner display (unchanged on a regular phone).
    func duoCardWidth(_ max: CGFloat = 520) -> some View { modifier(DuoCardWidth(max: max)) }
}

private struct DuoCardWidth: ViewModifier {
    let max: CGFloat
    @Environment(\.horizontalSizeClass) private var hSize
    func body(content: Content) -> some View {
        content.frame(maxWidth: hSize == .regular ? max : .infinity)
    }
}

/// Bar buttons (Done, Cancel, Close). Text on a regular iPhone, as always. On the Duo, title and symbol, so the bar
/// can move to the side of the inner display and show the symbol there (a text-only item can't).
struct DuoBarLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        if Duo.isDuo { Label { configuration.title } icon: { configuration.icon } }
        else { configuration.title }
    }
}

/// The app's window is wider than it is tall. Baget is portrait-locked on every other iPhone, so this only happens on
/// the Duo's inner display turned on its side. RootView sets it from the window's size.
private struct DuoWideKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var duoWide: Bool {
        get { self[DuoWideKey.self] }
        set { self[DuoWideKey.self] = newValue }
    }
}
