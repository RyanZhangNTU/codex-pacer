import Foundation

/// The saved source and the currently detected billing mode own wallet history.
public struct DeepSeekBalanceBinding: Equatable, Sendable {
    public let source: DeepSeekBalanceSelection
    public let mode: DeepSeekAuthMode?
    public init(source: DeepSeekBalanceSelection, mode: DeepSeekAuthMode?) { self.source = source; self.mode = mode }
    public var historySource: String? { mode.map { $0 == .account ? "web" : "apiKey" } }
    public func restoredHistory(_ history: DeepSeekBalanceHistory) -> DeepSeekBalanceHistory {
        if let expected = historySource, let saved = history.source, expected != saved { return .init() }
        return history
    }
    public func retainedHistory(_ history: DeepSeekBalanceHistory, previousMode: DeepSeekAuthMode?) -> DeepSeekBalanceHistory {
        retainsHistory(history, previousMode: previousMode) ? history : .init()
    }
    public func retainsHistory(_ history: DeepSeekBalanceHistory, previousMode: DeepSeekAuthMode?) -> Bool {
        history.source == historySource && (previousMode == nil || previousMode == mode)
    }
    public static func sessionHistory(_ history: DeepSeekBalanceHistory, newSession: Bool) -> DeepSeekBalanceHistory {
        newSession ? .init() : history
    }
}
