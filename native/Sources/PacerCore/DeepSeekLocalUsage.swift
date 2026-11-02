import Foundation

/// Local spend estimate and billing provider derived from the session logs.
public struct DeepSeekLocalUsage: Equatable, Sendable {
    public let ledger: DeepSeekSpendLedger
    /// The billing provider of the newest request, such as `deepseek-account`.
    public let provider: String?
    /// Each delegated session's parent session.
    public let parents: [String: String]
    /// Session titles from the logs, for tasks whose rows are gone.
    public let titles: [String: String]
    public init(ledger: DeepSeekSpendLedger = DeepSeekSpendLedger(), provider: String? = nil, parents: [String: String] = [:],
                titles: [String: String] = [:]) {
        self.ledger = ledger; self.provider = provider; self.parents = parents; self.titles = titles
    }
    /// The task a session's spend counts toward: its root session.
    public func task(of session: String) -> String { DeepSeekActivityState.root(of: session, parents: parents) }
    /// Delegated sessions under a root task.
    public func subagents(of task: String) -> Int { parents.keys.filter { $0 != task && self.task(of: $0) == task }.count }
}
