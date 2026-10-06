import Foundation
import CoreGraphics

public struct IslandWidthSettings: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        case adaptive, fixed
    }

    public static let range: ClosedRange<Double> = 360...900
    public var mode: Mode
    public var width: Double

    public init(mode: Mode = .adaptive, width: Double = 480) {
        self.mode = mode
        self.width = width
    }

    public var normalized: Self {
        Self(mode: mode, width: Self.clamp(width, to: Self.range, fallback: 480).rounded())
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(mode: defaults.string(forKey: "islandWidthMode").flatMap(Mode.init(rawValue:)) ?? .adaptive,
            width: (defaults.object(forKey: "specifiedIslandWidth") as? NSNumber)?.doubleValue ??
                (defaults.object(forKey: "expandedIslandWidth") as? NSNumber)?.doubleValue ?? 480).normalized
    }

    public func save(to defaults: UserDefaults = .standard) {
        let value = normalized
        defaults.set(value.mode.rawValue, forKey: "islandWidthMode")
        defaults.set(value.width, forKey: "specifiedIslandWidth")
        defaults.removeObject(forKey: "collapsedIslandWidth")
        defaults.removeObject(forKey: "expandedIslandWidth")
    }

    /// Hardware-notch headers need equal wings so the camera gap stays centered.
    public func desiredWidth(expanded: Bool, notchWidth: CGFloat, leading: CGFloat,
                             trailing: CGFloat, contentWidth: CGFloat = 0) -> CGFloat {
        let gap = notchWidth.isFinite ? max(0, notchWidth) : 0
        let left = leading.isFinite ? max(0, leading) : 80
        let right = trailing.isFinite ? max(0, trailing) : 65
        let natural = gap > 0 ? gap + 8 + 42 + 2 * max(left, right) : 52 + left + right
        let hardwareMinimum: CGFloat = gap > 0 ? gap + 200 : 180
        let settings = normalized
        if settings.mode == .fixed { return max(hardwareMinimum, CGFloat(settings.width)) }
        let collapsed = max(hardwareMinimum, ceil(natural) + 2)
        guard expanded else { return collapsed }
        let content = contentWidth.isFinite ? max(0, contentWidth) : 0
        let panel = min(680, max(440, content))
        return max(collapsed, panel)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}
