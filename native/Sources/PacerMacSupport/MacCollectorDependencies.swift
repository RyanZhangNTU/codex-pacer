import Foundation
import PacerCore

extension ClaudeActivityMonitor {
    public init(sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(sshExecutable: sshExecutable, makePipeReader: { PipeChunkReader(descriptor: $0) },
            remoteMirrorSessionIDs: { ClaudeApplicationResolver.remoteMirrorSessionIDs(claudeHome: $0) },
            files: MacFileSystem(), clock: clock)
    }
}

extension RemoteControlCatalog {
    public init(fetch: (@Sendable (URLRequest) async throws -> Data)? = nil,
        makeClient: @escaping @Sendable (URL) -> CodexClient? = { home in
            guard let executable = CodexClient.findExecutable(customPath: UserDefaults.standard.string(forKey: "codexExecutable") ?? "") else { return nil }
            return CodexClient(executable: executable, home: home, timeout: 8)
        }) {
        self.init(fetch: fetch, files: MacFileSystem(), makeClient: makeClient)
    }
}

extension RealtimeActivityMonitor {
    public init(controlCatalog: RemoteControlCatalog = RemoteControlCatalog()) {
        self.init(controlCatalog: controlCatalog, makePipeReader: { PipeChunkReader(descriptor: $0) })
    }
}
