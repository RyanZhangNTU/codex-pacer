import Foundation
import PacerCore

struct ActivityHostApplication: Equatable, Sendable {
    struct ApplicationIdentity: Equatable, Sendable {
        let executable: URL
        let volume: UInt64, low: UInt64, high: UInt64, modified: UInt64, size: UInt64
        let packageApplicationID: String
    }
    let identity: ProcessInstance
    let provider: AgentProvider?
    let name: String
    let home: URL
    var application: ApplicationIdentity? = nil
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
    let activate: @Sendable (ActivityHostApplication) async -> Bool
    init(resolve: @escaping @Sendable (Input) async -> [String: ActivityHostApplication],
         activate: @escaping @Sendable (ActivityHostApplication) async -> Bool = { _ in false }) {
        self.resolve = resolve; self.activate = activate
    }
    static let live = Self { input in
        #if os(Windows)
        let worker = Task.detached(priority: .utility) { () -> [String: ActivityHostApplication] in
            let files = input.files.filter { input.sessions.contains($0.key) }
            guard !files.isEmpty, !Task.isCancelled, let snapshot = WindowsProcessOwnership.snapshot() else { return [:] }
            let roots: [AgentProvider: [URL]] = [.claude: WindowsPackageLocations.find(family: "Claude_pzs8sxrjxfjjc"),
                                               .codex: WindowsPackageLocations.find(family: "OpenAI.Codex_2p2nqsd0c76g0")]
            var result: [String: ActivityHostApplication] = [:]
            for (session, file) in files {
                guard !Task.isCancelled else { break }
                guard let owner = try? WindowsActivityNavigation.currentHost(file: file, home: input.home, host: {
                          WindowsProcessHost.nearest(to: $0, lookup: snapshot.inspect, packageRoots: roots)
                      }),
                      let row = snapshot.inspect(owner.identity.pid, owner.identity.started),
                      row.identity == owner.identity else { continue }
                result[session] = .init(identity: owner.identity, provider: owner.provider,
                    name: owner.provider?.displayName ?? row.executable.deletingPathExtension().lastPathComponent, home: input.home,
                    application: WindowsHostApplication.capture(owner.identity))
            }
            return result
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        #else
        return [:]
        #endif
    } activate: { application in
        #if os(Windows)
        let worker = Task.detached(priority: .userInitiated) { WindowsHostApplication.activate(application) }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        #else
        return false
        #endif
    }
}
