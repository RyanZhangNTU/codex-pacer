import Foundation
import PacerCore

typealias EngineActivityLink = ActivityNavigationLink

struct EngineNavigationPlan: Codable, Equatable, Sendable {
    let context: String, provider: String, kind: String
    let url: String?, webURL: String?
    let pid: UInt32?, started: UInt64?
    var terminal: String? = nil
    // This capability never crosses the protocol boundary.
    var hostApplication: ActivityHostApplication? = nil
    enum CodingKeys: String, CodingKey { case context, provider, kind, url, webURL, pid, started, terminal }
    init(context: String, provider: AgentProvider, terminal: String, kind: String = "terminal") {
        self.context = context; self.provider = provider.rawValue; self.kind = kind; self.terminal = terminal
        url = nil; webURL = nil; pid = nil; started = nil
    }
    init(context: String, provider: AgentProvider, url: URL, webURL: URL? = nil) {
        self.context = context; self.provider = provider.rawValue; kind = "application"
        self.url = url.absoluteString; self.webURL = webURL?.absoluteString; pid = nil; started = nil
    }
    init(context: String, provider: AgentProvider, pid: UInt32, started: UInt64) {
        self.context = context; self.provider = provider.rawValue; kind = "host"
        url = nil; webURL = nil; self.pid = pid; self.started = started
    }
    init(context: String, provider: AgentProvider, host: ActivityHostApplication) {
        self.init(context: context, provider: provider, pid: host.identity.pid, started: host.identity.started)
        hostApplication = host
    }
    init(demoContext: String, provider: AgentProvider) {
        context = demoContext; self.provider = provider.rawValue; kind = "demo"
        url = nil; webURL = nil; pid = nil; started = nil
    }
    init(applicationContext: String, provider: AgentProvider) {
        context = applicationContext; self.provider = provider.rawValue; kind = "application"
        url = nil; webURL = nil; pid = nil; started = nil
    }
}

struct ActivityNavigationServices: Sendable {
    struct Input: Sendable {
        let context: String, activity: SessionActivity, home: URL, transcript: URL?
        var cachedHost: ActivityHostApplication? = nil
        var remoteControlHosts: Set<String> = []
        var wslProfile: WindowsWSLProfile? = nil
        var remoteTarget: RemoteActivityTarget? = nil
    }
    let resolve: @Sendable (Input) async throws -> EngineNavigationPlan
    static let demo = Self { .init(demoContext: $0.context, provider: $0.activity.provider) }
    static let live = Self { input in
        if input.activity.provider == .deepseek { return .init(applicationContext: input.context, provider: .deepseek) }
        #if os(Windows)
        return try await Task.detached(priority: .userInitiated) { try WindowsActivityNavigation.resolve(input) }.value
        #else
        throw ActivityNavigationError.unavailable
        #endif
    }
}

enum ActivityNavigationError: Error { case unavailable, missingClaudeHost, missingCodexHost }
