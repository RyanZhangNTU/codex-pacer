import Foundation
import CoreGraphics

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
    }

    /// Screen attachment is a user choice; the center gap only reserves real hardware.
    public func layout(safeAreaTop: CGFloat, hardwareNotchWidth: CGFloat) -> Layout {
        let hasHardwareNotch = safeAreaTop > 0
        let attached = self == .notch || (self == .automatic && hasHardwareNotch)
        return Layout(attached: attached,
            notchWidth: attached && hasHardwareNotch ? max(0, hardwareNotchWidth) : 0,
            topHeight: attached ? max(32, safeAreaTop) : 38)
    }
}
