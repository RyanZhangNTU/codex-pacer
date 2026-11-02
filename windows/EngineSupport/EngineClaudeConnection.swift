import Foundation

/// Routine UI state contains no cookie, account ID, organization ID or source path.
struct EngineClaudeConnection: Codable, Equatable {
    let context: String
    let webAvailable: Bool, refreshing: Bool, paused: Bool, canChooseOrganization: Bool
    let state: String
    let message: String?
    init(_ value: ClaudeQuotaState, paused: Bool) {
        context = value.connectionContext; webAvailable = value.webAvailable; refreshing = value.refreshing
        self.paused = paused; canChooseOrganization = !value.organizations.isEmpty
        message = value.error
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
