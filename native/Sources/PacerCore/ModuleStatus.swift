import Foundation

/// The first row of every module page's Status card: whether Pacer reads the
/// module's tasks on this computer. Every module uses the same states, tones and
/// actions, so the pages read alike; only what feeds them differs.
public struct ModuleMonitoring: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case on, checking, settingUp, needsApproval, needsUpdate, silent, failed, notFound, unreadable
    }
    public enum Tone: String, Equatable, Sendable { case positive, neutral, attention }
    /// At most one button per row.
    public enum Action: String, Equatable, Sendable {
        /// Codex Desktop's settings, with the floating guide beside them.
        case openCodex
        /// Sets the module's monitoring up again.
        case retry
        /// Looks for the module's program or data again.
        case rescan
    }

    public let state: State
    /// Running sessions on this computer, shown while monitoring is on.
    public var sessions: Int
    /// One line under the row, only when the user has something to read.
    public var detail: String?
    public var action: Action?

    public init(_ state: State, sessions: Int = 0, detail: String? = nil, action: Action? = nil) {
        self.state = state; self.sessions = max(0, sessions); self.detail = detail; self.action = action
    }

    public var tone: Tone {
        switch state {
        case .on: .positive
        case .checking, .settingUp: .neutral
        case .needsApproval, .needsUpdate, .silent, .failed, .notFound, .unreadable: .attention
        }
    }

    /// The row's state text, with the running sessions while monitoring is on.
    public var text: String {
        let base = L10n.text("monitoring." + Self.key(state))
        guard state == .on, sessions > 0 else { return base }
        return base + " · " + L10n.text(sessions == 1 ? "connections.sessions_one" : "connections.sessions", sessions)
    }

    /// The module page needs the user: its sidebar entry and Overview say so.
    public var needsUser: Bool { tone == .attention }

    private static func key(_ state: State) -> String {
        switch state {
        case .on: "on"
        case .checking: "checking"
        case .settingUp: "setting_up"
        case .needsApproval: "needs_approval"
        case .needsUpdate: "needs_update"
        case .silent: "silent"
        case .failed: "failed"
        case .notFound: "not_found"
        case .unreadable: "unreadable"
        }
    }

    /// Codex: its CLI first, then the hooks it runs. `executableFound` is nil while
    /// Pacer still looks; `opensCodex` when Codex Desktop can open its settings.
    public static func codex(executableFound: Bool?, executableIssue: String? = nil, hooks: CodexHookStatus?,
                             sessions: Int, opensCodex: Bool) -> Self {
        if executableFound == false { return .init(.notFound, detail: executableIssue, action: .rescan) }
        guard executableFound == true, let hooks else { return .init(.checking) }
        switch hooks {
        case .off, .notInstalled: return .init(.settingUp)
        case .needsApproval:
            return opensCodex ? .init(.needsApproval, action: .openCodex)
                : .init(.needsApproval, detail: L10n.text("whats_new.codex_setup.allow_manual"))
        case .running: return .init(.on, sessions: sessions)
        case .notRunning: return .init(.silent, detail: L10n.text("codex.hooks.not_running"), action: .retry)
        case .needsCodexUpdate: return .init(.needsUpdate, detail: L10n.text("codex.hooks.needs_update"))
        case .installFailed: return .init(.failed, action: .retry)
        }
    }

    /// Where Claude's local hook setup stands.
    public enum Setup: String, Equatable, Sendable { case checking, configuring, ready, missingHome, failed }

    /// Claude: its hooks in the Claude home. `note` is a plain line the setup
    /// leaves, such as Claude speeds estimated from transcripts.
    public static func claude(_ setup: Setup, sessions: Int, note: String? = nil) -> Self {
        switch setup {
        case .ready: .init(.on, sessions: sessions, detail: note)
        case .checking: .init(.checking)
        case .configuring: .init(.settingUp)
        case .missingHome: .init(.notFound, detail: L10n.text("provider.state.no_home"))
        case .failed: .init(.failed, detail: L10n.text("claude.monitoring_setup_failed"), action: .retry)
        }
    }

    /// A local harness (WorkBuddy, WorkBuddy AI) read from its data folder. Nil
    /// while the first read is pending; `detected` when the app is installed.
    public static func harness(_ status: HarnessSourceStatus?, detected: Bool, sessions: Int) -> Self {
        switch status {
        case .ready?: .init(.on, sessions: sessions)
        case .missing?: .init(.notFound, detail: detected ? L10n.text("harness.missing") : nil, action: .rescan)
        case .incompatible?: .init(.unreadable, detail: L10n.text("harness.incompatible"), action: .rescan)
        case .unavailable?: .init(.unreadable, detail: L10n.text("harness.unavailable"), action: .rescan)
        case nil: detected ? .init(.checking) : .init(.notFound, action: .rescan)
        }
    }

    /// DeepSeek Harness, read from its sessions folder; nil while it is first read.
    public static func deepseek(found: Bool?, sessions: Int) -> Self {
        switch found {
        case true?: .init(.on, sessions: sessions)
        case false?: .init(.notFound, detail: L10n.text("provider.state.no_home"))
        case nil: .init(.checking)
        }
    }
}

/// The Account row of Codex's Status card: the ChatGPT account Codex is signed
/// in to, as its quota read shows it. Signing in happens in Codex.
public enum CodexAccountState: Equatable, Sendable {
    case checking
    case signedIn(plan: String?)
    case signedOut
    /// Read failed for another reason; the Usage row says why.
    case unavailable

    /// `error` is the quota read's message, as `CodexClientError.errorDescription` gives it.
    public init(quota: QuotaSnapshot?, error: String?) {
        if let error {
            self = error == CodexClientError.notLoggedIn.errorDescription ? .signedOut : .unavailable
        } else if let quota {
            self = .signedIn(plan: quota.buckets.first { $0.id == "codex" }?.plan ?? quota.buckets.first?.plan)
        } else {
            self = .checking
        }
    }

    public var tone: ModuleMonitoring.Tone {
        switch self {
        case .signedIn: .positive
        case .checking, .unavailable: .neutral
        case .signedOut: .attention
        }
    }

    /// "Signed in · Pro", "Not signed in", …
    public var text: String {
        switch self {
        case .checking: L10n.text("claude.account.checking")
        case .signedIn(let plan): [L10n.text("claude.account.signed_in"), plan.flatMap(Self.planName)].compactMap { $0 }.joined(separator: " · ")
        case .signedOut: L10n.text("claude.account.signed_out")
        case .unavailable: L10n.text("claude.account.unavailable")
        }
    }

    /// How to sign in, under the row while signed out.
    public var detail: String? { self == .signedOut ? L10n.text("codex.account.sign_in_hint") : nil }

    /// ChatGPT's plan as people know it: "plus" → "Plus".
    static func planName(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 32, value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        return value.replacingOccurrences(of: "_", with: " ").split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }
}
