import Foundation

/// The result of the actual navigation operation, rather than a preflight
/// prediction. Bringing forward the app that started a Claude session counts
/// as opening it; an SSH Terminal handoff cannot confirm that it opened.
enum ActivityOpenOutcome: Equatable, Sendable {
    case openedConversation
    case dispatchedTerminal
    case failed(String)
}
