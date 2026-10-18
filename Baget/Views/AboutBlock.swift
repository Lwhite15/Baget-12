import SwiftUI

/// Who the brand is, then what the product is, in plain words. Shown wherever people decide on a product.
struct AboutBlock: View {
    let item: Item
    var brand = true
    var lines: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if brand, let b = item.brandAbout, !item.brand.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ABOUT \(item.brand.uppercased())").font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(Theme.accent)
                    Text(b).font(.footnote).foregroundStyle(Theme.ink.opacity(0.85)).lineLimit(lines)
                }
                .accessibilityElement(children: .combine)
            }
            if let a = item.about {
                Text(a).font(.footnote).foregroundStyle(Theme.ink.opacity(0.85)).lineLimit(lines)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }

    static func has(_ item: Item, brand: Bool = true) -> Bool { item.about != nil || (brand && item.brandAbout != nil && !item.brand.isEmpty) }
}
