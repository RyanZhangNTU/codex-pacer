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

struct IslandGlassSettings {
    enum Style: String, CaseIterable {
        case regular, clear
        var label: String { self == .regular ? "标准" : "清透" }
    }
    enum Tint: String, CaseIterable {
        case neutral, cool, warm
        var label: String {
            switch self { case .neutral: return "中性"; case .cool: return "冷色"; case .warm: return "暖色" }
        }
        var color: Color {
            switch self {
            case .neutral: return .black
            case .cool: return Color(red: 0.08, green: 0.16, blue: 0.22)
            case .warm: return Color(red: 0.22, green: 0.13, blue: 0.08)
            }
        }
    }

    var style: Style = .regular
    var transparency: Double = 0.5
    var tint: Tint = .neutral
    var cornerRadius: Double = 27

    static var stored: Self {
        let defaults = UserDefaults.standard
        var settings = Self()
        settings.style = defaults.string(forKey: "glassStyle").flatMap(Style.init(rawValue:)) ?? .regular
        settings.tint = defaults.string(forKey: "glassTint").flatMap(Tint.init(rawValue:)) ?? .neutral
        settings.transparency = bounded(defaults.object(forKey: "glassTransparency") as? Double, in: 0...1, fallback: 0.5)
        settings.cornerRadius = bounded(defaults.object(forKey: "glassCornerRadius") as? Double, in: 12...36, fallback: 27)
        return settings
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(style.rawValue, forKey: "glassStyle")
        defaults.set(tint.rawValue, forKey: "glassTint")
        defaults.set(Self.bounded(transparency, in: 0...1, fallback: 0.5), forKey: "glassTransparency")
        defaults.set(Self.bounded(cornerRadius, in: 12...36, fallback: 27), forKey: "glassCornerRadius")
    }

    private static func bounded(_ value: Double?, in range: ClosedRange<Double>, fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

struct IslandSurface: ViewModifier {
    let appearance: IslandAppearance
    let attached: Bool
    let expanded: Bool
    var settings: IslandGlassSettings = .stored
    var progress: Double?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: UnevenRoundedRectangle {
        let radius = appearance == .liquidGlass ? settings.cornerRadius : 27
        let top = attached ? 0 : (appearance == .classic ? 25 : radius)
        let fraction = progress ?? (expanded ? 1 : 0)
        let bottom = min(radius, 19) + (radius - min(radius, 19)) * fraction
        return UnevenRoundedRectangle(topLeadingRadius: top,
            bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top)
    }

    @ViewBuilder func body(content: Content) -> some View {
        if appearance == .liquidGlass, !reduceTransparency {
            if #available(macOS 26.0, *) {
                content.background(.black.opacity(0.9 - settings.transparency * 0.4), in: shape)
                    .glassEffect((settings.style == .regular ? Glass.regular : Glass.clear)
                        .tint(settings.tint.color.opacity(0.12)), in: shape)
                    .clipShape(shape)
            } else { solid(content) }
        } else { solid(content) }
    }

    private func solid(_ content: Content) -> some View {
        content.background(Color(red: 0.045, green: 0.047, blue: 0.056), in: shape)
            .clipShape(shape)
    }
}
