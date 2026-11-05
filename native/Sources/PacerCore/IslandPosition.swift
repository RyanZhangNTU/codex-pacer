import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where a Custom (floating) island sits. Center is the original capsule below
/// the menu bar. A corner docks the collapsed bar as a vertical strip whose
/// long edge lies against that side of the screen, so it takes little width.
/// Notch attachment ignores the choice; it applies whenever the island floats.
public enum IslandPosition: String, CaseIterable, Sendable {
    case center, topLeft, bottomLeft, topRight, bottomRight

    public static let defaultsKey = "islandPosition"
    public var label: String { L10n.text("position." + rawValue) }

    /// Nil until a position is chosen. Without one a floating island keeps the
    /// original center, so earlier Floating and Automatic choices look the same.
    public static func saved(in defaults: UserDefaults = .standard) -> Self? {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:))
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self { saved(in: defaults) ?? .center }

    /// The position Custom shows: the saved one, or bottom left when Custom is
    /// first chosen over notch attachment.
    public static func custom(saved: Self?, attached: Bool) -> Self { saved ?? (attached ? .bottomLeft : .center) }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    public enum Side: Sendable { case left, right }

    /// The screen edge a docked strip hugs; nil for the centered capsule.
    public var side: Side? {
        switch self {
        case .center: nil
        case .topLeft, .bottomLeft: .left
        case .topRight, .bottomRight: .right
        }
    }

    public var isBottom: Bool { self == .bottomLeft || self == .bottomRight }

    /// The corner whose strip hugs `side` and opens up from the bottom or down from the top.
    public static func corner(side: Side, bottom: Bool) -> Self {
        switch side {
        case .left: bottom ? .bottomLeft : .topLeft
        case .right: bottom ? .bottomRight : .topRight
        }
    }

    /// The point that stays put while the island opens and closes.
    public var anchor: IslandGeometry.Anchor {
        switch self {
        case .center: .topCenter
        case .topLeft: .init(horizontal: .left, vertical: .top)
        case .bottomLeft: .init(horizontal: .left, vertical: .bottom)
        case .topRight: .init(horizontal: .right, vertical: .top)
        case .bottomRight: .init(horizontal: .right, vertical: .bottom)
        }
    }
}

/// Where Free Move left the island: the collapsed bar's center as fractions
/// of the screen's visible frame, `y` measured from the top, so the place
/// means the same on any display and scale. A docked edge overrides the
/// coordinate across it; left and right turn the bar into a strip. Windows
/// stores the same values. Without one, the saved IslandPosition still applies.
public struct IslandPlacement: Equatable, Sendable {
    public enum Edge: String, CaseIterable, Sendable { case free, top, bottom, left, right }
    public var edge: Edge
    public var x: Double
    public var y: Double

    public static let defaultsKey = "islandPlacement"

    public init(edge: Edge, x: Double, y: Double) {
        self.edge = edge; self.x = x; self.y = y
    }

    public var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
    /// Left and right docks show the collapsed bar on its side.
    public var vertical: Bool { edge == .left || edge == .right }

    /// A damaged value is ignored, so the island falls back to its saved position.
    public static func load(from defaults: UserDefaults = .standard) -> Self? {
        guard let saved = defaults.dictionary(forKey: defaultsKey),
              let edge = (saved["edge"] as? String).flatMap(Edge.init(rawValue:)),
              let x = saved["x"] as? Double, let y = saved["y"] as? Double else { return nil }
        let value = Self(edge: edge, x: x, y: y)
        return value.isValid ? value : nil
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(["edge": edge.rawValue, "x": x, "y": y], forKey: Self.defaultsKey)
    }

    public static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
