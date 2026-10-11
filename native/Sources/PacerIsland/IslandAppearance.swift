import PacerCore
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

/// Liquid Glass uses the regular variant, which Apple recommends for text-heavy
/// components over changing backgrounds, without a tint so color keeps its
/// provider and alert meanings. Its clarity follows the system's Liquid Glass
/// look (System Settings → Appearance). Over bright content the glass turns
/// light, so a fixed dark wash keeps the island's light text legible: about
/// 3:1 for secondary text over a white page, more with Increase Contrast.
/// Reduce Transparency shows the solid surface.
struct IslandSurface: ViewModifier {
    let appearance: IslandAppearance
    let attached: Bool
    let expanded: Bool
    var progress: Double?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: UnevenRoundedRectangle {
        let fraction = progress ?? (expanded ? 1 : 0)
        let bottom = 19 + 8 * fraction
        let top = attached ? 0 : bottom
        return UnevenRoundedRectangle(topLeadingRadius: top,
            bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top)
    }

    func body(content: Content) -> some View {
        content.background { material }.clipShape(shape)
    }

    // Keep native glass on a stable background view. Putting it around the
    // conditional content lets teardown of that content rebuild the material.
    @ViewBuilder private var material: some View {
        if appearance == .liquidGlass, !reduceTransparency {
            if #available(macOS 26.0, *) {
                shape.fill(.black.opacity(contrast == .increased ? 0.75 : 0.55))
                    .glassEffect(.regular, in: shape)
            } else { solid }
        } else { solid }
    }

    private var solid: some View {
        shape.fill(Color(red: 0.045, green: 0.047, blue: 0.056))
    }
}
