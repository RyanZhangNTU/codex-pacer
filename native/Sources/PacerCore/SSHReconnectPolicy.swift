import Foundation

/// An unreachable SSH host backs off to 15 minutes, so a host behind a VPN or
/// Wi-Fi that comes back would wait that long. A network change or the user's
/// return retries only failed SSH hosts at once. Changes arrive as bursts:
/// one retry follows a short settle, and retries stay apart while a link flaps.
public struct SSHReconnectPolicy: Sendable {
    public static let settle: TimeInterval = 2
    public static let spacing: TimeInterval = 15
    private var lastRetry: Date?
    public init() {}
    /// How long a retry requested at `now` waits before it runs.
    public func delay(at now: Date) -> TimeInterval {
        max(Self.settle, lastRetry.map { $0.addingTimeInterval(Self.spacing).timeIntervalSince(now) } ?? 0)
    }
    public mutating func ran(at now: Date) { lastRetry = now }
}
