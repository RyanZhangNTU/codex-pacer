import Foundation
import PacerCore

enum CodexConversationOpener {
    /// Only the caller handling an explicit card click invokes this path.
    /// An unknown third-party host never falls back to a codex:// URL.
    @MainActor static func open(_ activity: SessionActivity, home: URL, recordedHost: HostApplication?) async -> ActivityOpenOutcome {
        guard activity.provider == .codex, activity.sourceHostID == nil, activity.launchedByEmbeddingApp,
              let session = activity.threadID, UUID(uuidString: session) != nil else { return .failed(L10n.text("activity.open_failed")) }
        let current = await Task.detached(priority: .userInitiated) {
            HostApplication.resolve(sessions: [session], provider: .codex, home: home)[session]
        }.value
        guard let host = current ?? recordedHost else { return .failed(L10n.text("activity.codex_host_missing")) }
        return await HostApplication.activate(host, provider: .codex)
    }
}
