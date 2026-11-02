#if os(Windows)
import Foundation

enum WindowsActivityNavigation {
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
        guard activity.sourceHostID == nil, let session = activity.threadID, UUID(uuidString: session) != nil else { throw ActivityNavigationError.unavailable }
        let defaultProfile = isDefaultProfile(input.home, provider: provider, userHome: userHome)
        if provider == .codex, !activity.launchedByEmbeddingApp {
            guard defaultProfile, let url = activity.threadURL else { throw ActivityNavigationError.unavailable }
            return .init(context: input.context, provider: provider, url: url)
        }
        var currentHost: WindowsProcessHost?
        if let file = input.transcript {
            guard let holders = writers(file, input.home) else { throw ActivityNavigationError.unavailable }
            if !holders.isEmpty {
                let owners = holders.compactMap(host)
                guard owners.count == holders.count, let first = owners.first, owners.allSatisfy({ $0 == first }) else { throw ActivityNavigationError.unavailable }
                currentHost = first
            }
        }
        // A live editor or terminal outranks Desktop's saved mapping. Activating
        // that process never imports the session or resumes a model turn.
        if let owner = currentHost, provider == .codex || owner.provider != .claude {
            return .init(context: input.context, provider: provider, pid: owner.identity.pid, started: owner.identity.started)
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
            return .init(context: input.context, provider: provider, pid: owner.identity.pid, started: owner.identity.started)
        }
        throw provider == .claude ? ActivityNavigationError.missingClaudeHost : ActivityNavigationError.missingCodexHost
    }
}
#endif
