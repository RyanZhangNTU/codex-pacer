#if os(Windows)
import Foundation
import PacerCore

enum WindowsActivityNavigation {
    static func currentHost(file: URL, home: URL,
                            writers: (URL, URL) -> [WindowsProcessIdentity]? = { WindowsProcessOwnership.writers(of: $0, within: $1) },
                            host: (WindowsProcessIdentity) -> WindowsProcessHost? = { WindowsProcessHost.nearest(to: $0) }) throws -> WindowsProcessHost? {
        guard let holders = writers(file, home) else { throw ActivityNavigationError.unavailable }
        guard !holders.isEmpty else { return nil }
        let owners = holders.compactMap(host)
        guard owners.count == holders.count, let first = owners.first, owners.allSatisfy({ $0 == first }) else { throw ActivityNavigationError.unavailable }
        return first
    }
    static func isDefaultProfile(_ home: URL, provider: AgentProvider, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let standard = userHome.appendingPathComponent(provider == .claude ? ".claude" : ".codex")
        return home.standardizedFileURL == standard.standardizedFileURL || WindowsClaudeAccountBinding.sameDirectory(home, standard)
    }
    static func resolve(_ input: ActivityNavigationServices.Input,
                        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        records: [ClaudeDesktopRecords.Record]? = nil,
                        writers: (URL, URL) -> [WindowsProcessIdentity]? = { WindowsProcessOwnership.writers(of: $0, within: $1) },
                        host: (WindowsProcessIdentity) -> WindowsProcessHost? = { WindowsProcessHost.nearest(to: $0) }) throws -> EngineNavigationPlan {
        let activity = input.activity, provider = activity.provider
        guard provider == .claude || provider == .codex, !activity.isInternalReview, !activity.isIgnoredCodexSession else { throw ActivityNavigationError.unavailable }
        if activity.claudeCloud != nil, let url = activity.threadURL, let web = activity.claudeCloudWebURL {
            return .init(context: input.context, provider: provider, url: url, webURL: web)
        }
        guard let session = activity.threadID, UUID(uuidString: session) != nil else { throw ActivityNavigationError.unavailable }
        if let source = activity.sourceHostID {
            guard let target = input.remoteTarget, target.id == source,
                  let token = WindowsSSHResume(provider: provider, session: session, target: target).token else { throw ActivityNavigationError.unavailable }
            return .init(context: input.context, provider: provider, terminal: token)
        }
        let defaultProfile = isDefaultProfile(input.home, provider: provider, userHome: userHome)
        if provider == .codex, !activity.launchedByEmbeddingApp {
            guard defaultProfile, let url = activity.threadURL else { throw ActivityNavigationError.unavailable }
            return .init(context: input.context, provider: provider, url: url)
        }
        var currentHost: WindowsProcessHost?
        if let file = input.transcript {
            currentHost = try self.currentHost(file: file, home: input.home, writers: writers, host: host)
        }
        if currentHost == nil, input.transcript != nil, let cached = input.cachedHost, cached.home == input.home,
           WindowsProcessOwnership.inspect(cached.identity.pid, started: cached.identity.started)?.identity == cached.identity,
           WindowsHostWindow.available(pid: cached.identity.pid, started: cached.identity.started) {
            currentHost = .init(identity: cached.identity, provider: cached.provider)
        }
        if currentHost == nil, input.transcript != nil, let cached = input.cachedHost,
           cached.home == input.home, cached.application != nil {
            return .init(context: input.context, provider: provider, host: cached)
        }
        func plan(for owner: WindowsProcessHost) -> EngineNavigationPlan {
            let observed = WindowsHostApplication.capture(owner.identity)
            let cached = input.cachedHost.flatMap { $0.identity == owner.identity && $0.home == input.home ? $0 : nil }
            let application = ActivityHostApplication(identity: owner.identity, provider: owner.provider,
                name: owner.provider?.displayName ?? observed?.executable.deletingPathExtension().lastPathComponent ?? "",
                home: input.home, application: observed ?? cached?.application)
            return .init(context: input.context, provider: provider, host: application)
        }
        // A live editor or terminal outranks Desktop's saved mapping. Activating
        // that process never imports the session or resumes a model turn.
        if let owner = currentHost, provider == .codex || owner.provider != .claude {
            return plan(for: owner)
        }
        if provider == .claude, defaultProfile {
            let rows = records ?? ClaudeDesktopRecords.load(configFiles: WindowsClaudeAccountBinding.locations(environment: environment))
            if let desktopID = ClaudeDesktopRecords.localSessionID(for: session, records: rows) {
                var url = URLComponents(); url.scheme = "claude"; url.host = "code"; url.path = "/continue"
                url.queryItems = [URLQueryItem(name: "session", value: desktopID)]
                if let destination = url.url { return .init(context: input.context, provider: provider, url: destination) }
            }
        }
        if let owner = currentHost {
            return plan(for: owner)
        }
        throw provider == .claude ? ActivityNavigationError.missingClaudeHost : ActivityNavigationError.missingCodexHost
    }
}
#endif
