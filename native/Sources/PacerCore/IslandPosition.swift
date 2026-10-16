import Foundation
import CoreGraphics

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
