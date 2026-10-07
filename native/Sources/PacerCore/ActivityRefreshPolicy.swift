import Foundation

/// Ordinary event/log updates follow visibility; critical events stay immediate.
/// This is runtime state, independent of previously saved refresh preferences.
public enum ActivityRefreshPolicy: Sendable {
    case collapsed, expanded
    public var interval: TimeInterval { self == .expanded ? 1 : 5 }
}
