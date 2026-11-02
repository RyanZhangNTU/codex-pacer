import Foundation

/// The original provider-status decisions beneath the quota dashboard.
public struct QuotaConnectionPresentation: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case hidden, loading, unavailable, error }
    public struct Action: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case retry, settings }
        public let kind: Kind
        public let title: String
        public let enabled: Bool
    }
    public let state: State
    public let message: String?
    public let actions: [Action]

    public init(provider: AgentProvider, snapshot: QuotaSnapshot?, error: String?, refreshing: Bool) {
        if let error {
            state = .error; message = error
            actions = [Action(kind: .retry, title: L10n.text(refreshing ? "common.retrying" : "common.retry"), enabled: !refreshing),
                Action(kind: .settings, title: L10n.text("common.settings"), enabled: true)]
        } else if snapshot?.windows.isEmpty != false {
            state = refreshing ? .loading : .unavailable
            message = refreshing ? L10n.text("quota.loading") : L10n.text("dashboard.provider_unavailable", provider.displayName)
            actions = [Action(kind: .settings, title: L10n.text("common.open_settings"), enabled: true)]
        } else {
            state = .hidden; message = nil; actions = []
        }
    }
}
