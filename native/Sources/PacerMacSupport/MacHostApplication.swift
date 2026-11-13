import AppKit
import PacerCore

/// The first regular app above a provider process. Shared by the Claude
/// registry and Codex open-rollout adapters; retained after the process exits.
public struct MacHostApplication: Equatable, Sendable {
    public let bundleIdentifier: String
    public let bundleURL: URL
    public let name: String

    public init(bundleIdentifier: String, bundleURL: URL, name: String) {
        self.bundleIdentifier = bundleIdentifier; self.bundleURL = bundleURL; self.name = name
    }

    public var isClaudeDesktop: Bool { bundleIdentifier == ClaudeApplicationResolver.bundleIdentifier }

    public static func resolve(sessions: Set<String>, provider: AgentProvider, home: URL) -> [String: MacHostApplication] {
        guard !sessions.isEmpty else { return [:] }
        let holders = provider == .claude ? ClaudeLiveSessionRegistry.holders(sessions: sessions, claudeHome: home)
            : CodexRolloutOwners.holders(sessions: sessions, home: home)
        return holders.compactMapValues(application(above:))
    }
    public static func resolve(sessions: Set<String>, claudeHome: URL) -> [String: MacHostApplication] {
        resolve(sessions: sessions, provider: .claude, home: claudeHome)
    }

    public static func application(above pid: pid_t) -> MacHostApplication? {
        guard let owner = ProcessOwnership.owner(of: pid, isApplication: {
                  NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular }),
              let app = NSRunningApplication(processIdentifier: owner),
              let identifier = app.bundleIdentifier, let url = app.bundleURL else { return nil }
        let name = app.localizedName ?? FileManager.default.displayName(atPath: url.path)
        return MacHostApplication(bundleIdentifier: identifier, bundleURL: url,
                                     name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }
    /// Brings the host forward, launching it again if it quit. Which of its
    /// windows shows the session is not verified.
    @MainActor public static func activate(_ host: MacHostApplication, provider: AgentProvider) async -> ActivityOpenOutcome {
        let installed = FileManager.default.fileExists(atPath: host.bundleURL.path) ? host.bundleURL
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: host.bundleIdentifier)
        guard let application = installed else { return .failed(L10n.text("activity.host_app_missing", host.name)) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: application, configuration: configuration) { _, error in
                continuation.resume(returning: error.map {
                    .failed(L10n.text("activity.open_failed_detail", CodexDiagnosticText.description(of: $0)))
                } ?? .openedConversation)
            }
        }
    }

}
