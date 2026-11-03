import Foundation
import PacerCore

struct ActivityHostApplication: Equatable, Sendable {
    let identity: ProcessInstance
    let provider: AgentProvider?
    let name: String
    let home: URL
    var isClaudeDesktop: Bool { provider == .claude }
}

struct ActivityHostServices: Sendable {
    struct Input: Sendable {
        let provider: AgentProvider
        let sessions: Set<String>
        let home: URL
        let files: [String: URL]
    }
    let resolve: @Sendable (Input) async -> [String: ActivityHostApplication]
    static let live = Self { input in
        #if os(Windows)
        return await Task.detached(priority: .utility) {
            var result: [String: ActivityHostApplication] = [:]
            for session in input.sessions {
                guard let file = input.files[session],
                      let owner = try? WindowsActivityNavigation.currentHost(file: file, home: input.home),
                      let row = WindowsProcessOwnership.inspect(owner.identity.pid, started: owner.identity.started),
                      row.identity == owner.identity else { continue }
                result[session] = .init(identity: owner.identity, provider: owner.provider,
                    name: owner.provider?.displayName ?? row.executable.deletingPathExtension().lastPathComponent, home: input.home)
            }
            return result
        }.value
        #else
        return [:]
        #endif
    }
}
