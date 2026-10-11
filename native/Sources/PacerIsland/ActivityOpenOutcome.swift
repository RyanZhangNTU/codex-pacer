import Foundation

/// The result of the actual navigation operation, rather than a preflight
/// prediction. A Terminal handoff cannot confirm that a conversation opened.
enum ActivityOpenOutcome: Equatable, Sendable {
    case openedConversation
    case dispatchedTerminal
    case failed(String)
}
