import Foundation
import PacerCore

/// A sign-in in Pacer's browser passed claude.ai's verification, yet the reads that
/// followed were still challenged (#243). Asking for another sign-in only loops, so
/// until a read succeeds the message names the network instead.
struct ClaudeVerificationAfterSignIn {
    private(set) var awaitingRead = false
    /// A reset after a completed sign-in waits for its first read; any other reset ends the wait.
    mutating func reset(signedIn: Bool) { awaitingRead = signedIn }
    mutating func receive(_ state: ClaudeQuotaState) { if state.error == nil && state.snapshot != nil { awaitingRead = false } }
    func error(_ state: ClaudeQuotaState) -> String? {
        awaitingRead && state.failure == .webChallenge ? L10n.text("claude.quota.web_blocked") : state.error
    }
}

/// Routine UI state contains no cookie, account ID, organization ID or source path.
struct EngineClaudeConnection: Codable, Equatable {
    let context: String
    let webAvailable: Bool, refreshing: Bool, paused: Bool, canChooseOrganization: Bool
    let state: String
    let message: String?
    init(_ value: ClaudeQuotaState, paused: Bool, verification: ClaudeVerificationAfterSignIn = .init()) {
        context = value.connectionContext; webAvailable = value.webAvailable; refreshing = value.refreshing
        self.paused = paused; canChooseOrganization = !value.organizations.isEmpty
        message = verification.error(value)
        if paused { state = "paused" }
        else if !value.webAvailable { state = "runtime" }
        else if value.failure == .organizationSelectionRequired { state = "workspaceNeeded" }
        else if value.failure == .notLoggedIn || value.failure == .credentialsExpired { state = "signedOut" }
        else if value.failure == .webChallenge || value.failure == .accountChanged || value.failure == .denied { state = "needsConnection" }
        else if value.refreshing && value.snapshot == nil { state = "checking" }
        else if value.snapshot?.windows.isEmpty == false { state = "signedIn" }
        else { state = "unavailable" }
    }
}

/// Workspace names/IDs are returned only for the explicit account settings query.
struct EngineClaudeAccountReport: Encodable {
    struct Organization: Encodable { let id: String; let name: String?; let label: String }
    let context: String, selectedOrganization: String
    let organizations: [Organization]
    init(_ state: ClaudeQuotaState, selected: String) {
        context = state.connectionContext; selectedOrganization = selected
        organizations = state.organizations.prefix(64).enumerated().map { index, value in
            let label = value.name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ?? L10n.text("claude.login.organization_number", index + 1)
            return .init(id: value.id, name: value.name, label: label)
        }
    }
}
