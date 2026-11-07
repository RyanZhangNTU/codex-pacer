import Foundation

/// Serializes one provider's progress-reporter setup. Each request waits for
/// the one before it, so two writers never edit the same profile at once, and
/// only the newest request may publish its status.
public struct ProgressSetupQueue<Target: Equatable & Sendable>: Sendable {
    public struct Ticket: Sendable {
        let id: UUID
        /// The target the switch moves away from, so its home can be revoked.
        public let previous: Target?
        public let target: Target
        let pending: Task<Void, Never>?
        public func waitForPrevious() async { await pending?.value }
    }

    public private(set) var target: Target?
    private var task: Task<Void, Never>?
    private var current: UUID?
    public init() {}

    /// A ticket when the target changed or a retry forces one; otherwise nil.
    public mutating func request(_ target: Target, force: Bool = false) -> Ticket? {
        guard force || self.target != target else { return nil }
        let ticket = Ticket(id: UUID(), previous: self.target, target: target, pending: task)
        self.target = target; current = ticket.id
        return ticket
    }

    /// Records the task running a ticket, for the next request to wait on.
    public mutating func track(_ task: Task<Void, Never>) { self.task = task }

    /// True only for the newest ticket, which then publishes its status.
    public mutating func finish(_ ticket: Ticket) -> Bool {
        guard current == ticket.id else { return false }
        task = nil; current = nil
        return true
    }
}
