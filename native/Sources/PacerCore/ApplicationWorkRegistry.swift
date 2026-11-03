import Foundation

/// Cancelling a slot releases ownership immediately. A task that ignores
/// cancellation cannot clear a replacement slot when it eventually returns.
public struct ApplicationWorkRegistry: Sendable {
    public enum Kind: Hashable, Sendable {
        case quota, quotaRestart, activity, remote, discovery, setup, reset
        case hostScan, hostRetry, navigation, navigationError
        case maintenance, presentation, displayExpiry, applications
    }
    public struct Key: Hashable, Sendable {
        public let kind: Kind
        public let provider: AgentProvider?
        public let identifier: String?
        public init(_ kind: Kind, provider: AgentProvider? = nil, identifier: String? = nil) {
            self.kind = kind; self.provider = provider; self.identifier = identifier
        }
    }
    public struct Ticket: Hashable, Sendable {
        public let id: UUID
        public let key: Key
        public let version: UInt64
    }
    private struct Work: Sendable { let ticket: Ticket; var task: Task<Void, Never>? }
    private var work: [Key: Work] = [:]
    public init() {}
    public var count: Int { work.count }
    public func owns(_ ticket: Ticket) -> Bool { work[ticket.key]?.ticket.id == ticket.id }
    public func task(_ key: Key) -> Task<Void, Never>? { work[key]?.task }
    @discardableResult public mutating func begin(_ key: Key, version: UInt64) -> Ticket {
        work.removeValue(forKey: key)?.task?.cancel()
        let ticket = Ticket(id: UUID(), key: key, version: version)
        work[key] = Work(ticket: ticket); return ticket
    }
    public mutating func attach(_ task: Task<Void, Never>, to ticket: Ticket) {
        guard owns(ticket) else { task.cancel(); return }
        work[ticket.key]?.task = task
    }
    @discardableResult public mutating func finish(_ ticket: Ticket) -> Bool {
        guard owns(ticket) else { return false }
        work.removeValue(forKey: ticket.key); return true
    }
    public mutating func cancel(_ key: Key) { work.removeValue(forKey: key)?.task?.cancel() }
    public mutating func cancel(provider: AgentProvider? = nil, kinds: Set<Kind>? = nil) {
        for key in Array(work.keys) where (provider == nil || key.provider == provider) && (kinds == nil || kinds!.contains(key.kind)) {
            work.removeValue(forKey: key)?.task?.cancel()
        }
    }
}
