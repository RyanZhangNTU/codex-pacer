import SwiftUI

enum IslandAppearance: String, CaseIterable {
    case classic
    case liquidGlass

    static var supportsLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static var stored: Self {
        let saved = UserDefaults.standard.string(forKey: "islandAppearance")
        let selected = saved.flatMap(Self.init(rawValue:)) ?? (supportsLiquidGlass ? .liquidGlass : .classic)
        return supportsLiquidGlass ? selected : .classic
    }
}

struct IslandSurface: ViewModifier {
    let appearance: IslandAppearance
    let attached: Bool
    let expanded: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: attached ? 0 : 25,
            bottomLeadingRadius: expanded ? 27 : 19,
            bottomTrailingRadius: expanded ? 27 : 19,
            topTrailingRadius: attached ? 0 : 25)
    }

    @ViewBuilder func body(content: Content) -> some View {
        if appearance == .liquidGlass, !reduceTransparency {
            if #available(macOS 26.0, *) {
                content.background(.black.opacity(0.5), in: shape)
                    .glassEffect(.regular.tint(.black.opacity(0.12)), in: shape)
                    .clipShape(shape)
            } else { solid(content) }
        } else { solid(content) }
    }

    private func solid(_ content: Content) -> some View {
        content.background(Color(red: 0.045, green: 0.047, blue: 0.056), in: shape)
            .clipShape(shape)
    }
}
