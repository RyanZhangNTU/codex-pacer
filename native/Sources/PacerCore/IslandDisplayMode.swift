import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Settings offers Notch and Custom (`floating`, placed by `IslandPosition`).
/// `automatic` remains only as the state before either is chosen: it attaches
/// on a display with a notch and floats elsewhere, as it always has.
public enum IslandDisplayMode: String, CaseIterable, Sendable {
    case automatic, notch, floating

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        if let value = defaults.string(forKey: "islandDisplayMode"), let mode = Self(rawValue: value) {
            return mode
        }
        return defaults.bool(forKey: "floatingIsland") ? .floating : .automatic
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "islandDisplayMode")
        defaults.set(self == .floating, forKey: "floatingIsland")
    }

    public struct Layout: Equatable, Sendable {
        public let attached: Bool
        public let notchWidth: CGFloat
        public let topHeight: CGFloat
        /// Width of the bar turned on its side at a docked edge.
        public let stripWidth: CGFloat
        /// False while the bar is attached to a real camera housing, whose
        /// height it keeps whatever size is saved.
        public let sizeAdjustable: Bool
        /// The bar hangs from a Mac's hardware notch, not just the top of a
        /// screen without one; only there is it pure black while collapsed.
        public var atHardwareNotch: Bool { !sizeAdjustable }
        public init(attached: Bool, notchWidth: CGFloat, topHeight: CGFloat,
                    stripWidth: CGFloat = IslandGeometry.stripWidth, sizeAdjustable: Bool = true) {
            self.attached = attached; self.notchWidth = notchWidth; self.topHeight = topHeight
            self.stripWidth = stripWidth; self.sizeAdjustable = sizeAdjustable
        }
    }

    /// Screen attachment is a user choice; the center gap only reserves real
    /// hardware. Every bar takes its height from the saved size, except one
    /// attached to a hardware notch, which matches the notch.
    public func layout(safeAreaTop: CGFloat, hardwareNotchWidth: CGFloat, size: CompactBarSize = .standard) -> Layout {
        let hasHardwareNotch = safeAreaTop > 0
        let attached = self == .notch || (self == .automatic && hasHardwareNotch)
        let adjustable = CompactBarSize.isAdjustable(attached: attached, hardwareNotch: hasHardwareNotch)
        return Layout(attached: attached,
            notchWidth: attached && hasHardwareNotch ? max(0, hardwareNotchWidth) : 0,
            topHeight: adjustable ? CGFloat(size.metrics.height) : max(32, safeAreaTop),
            stripWidth: CGFloat(size.metrics.stripWidth), sizeAdjustable: adjustable)
    }
}
