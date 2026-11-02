import Foundation

/// A random source context authorizes owned cookie requests. Account identifiers
/// and cloud response bodies never enter this routine host-state message.
struct EngineClaudeCloudConnection: Codable, Equatable {
    let context: String
    let enabled: Bool, webAvailable: Bool
    init(_ state: ClaudeCloudState) {
        context = state.connectionContext; enabled = state.enabled; webAvailable = state.webAvailable
    }
}
