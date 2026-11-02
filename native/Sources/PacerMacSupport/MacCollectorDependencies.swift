import Foundation
import Darwin
import PacerCore

extension ClaudeActivityMonitor {
    public init(sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(sshExecutable: sshExecutable, processes: MacHelperProcessLauncher(),
            fileEvents: MacActivityFileEvents(), telemetryTransport: MacTelemetryTransport(),
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
        self.init(fetch: fetch ?? { try await RemoteControlCatalog.fetch($0) }, files: MacFileSystem(), makeClient: makeClient)
    }
}

extension RealtimeActivityMonitor {
    public init(controlCatalog: RemoteControlCatalog = RemoteControlCatalog()) {
        self.init(controlCatalog: controlCatalog, services: RealtimeActivityServices(
            desktopAvailable: { Self.desktopEndpointAvailable(home: $0) }, controlAvailable: { Self.controlEndpointAvailable(home: $0) },
            makeDesktop: { home, hosts, local, interval, frame, closed in
                MacDesktopActivityChannel(home: home, hosts: hosts, localRuntime: local, interval: interval, frame: frame, closed: closed)
            }, processes: MacHelperProcessLauncher(), python: URL(fileURLWithPath: "/usr/bin/python3"),
            ssh: URL(fileURLWithPath: "/usr/bin/ssh"), diagnostics: RuntimeDiagnostics.observer))
    }
    public static func localEndpointAvailable(home: URL) -> Bool {
        controlEndpointAvailable(home: home) || desktopEndpointAvailable(home: home)
    }
    static func desktopEndpointAvailable(home: URL) -> Bool {
        let directory = home.appendingPathComponent("ipc")
        let path = directory.appendingPathComponent("ipc.sock")
        for (url, type) in [(directory, FileAttributeType.typeDirectory), (path, .typeSocket)] {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == type,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let permissions = attrs[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o077 == 0 else { return false }
        }
        return true
    }
    static func controlEndpointAvailable(home: URL) -> Bool {
        let path = home.appendingPathComponent("app-server-control/app-server-control.sock")
        guard let link = try? FileManager.default.attributesOfItem(atPath: path.path),
              let owner = link[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else { return false }
        let actual = path.resolvingSymlinksInPath()
        guard let target = try? FileManager.default.attributesOfItem(atPath: actual.path),
              target[.type] as? FileAttributeType == .typeSocket,
              (target[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = target[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0 else { return false }
        return true // The helper also verifies both parent directories and the WS handshake.
    }

}

extension DesktopRouteHints {
    public init() {
        self.init(files: MacFileSystem(), owned: { file in
            let fields = try? FileManager.default.attributesOfItem(atPath: file.path)
            return (fields?[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
        })
    }
}
