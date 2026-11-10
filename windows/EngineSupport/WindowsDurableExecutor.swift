#if os(Windows)
import Foundation
import PacerCore
import CWindowsSupport

struct WindowsDurableExecutor: Equatable, Sendable {
    let identity: WindowsProcessIdentity
    let desktop: WindowsProcessIdentity
    let environmentID: String
    let packagedCLI: URL

    var isAlive: Bool { WindowsProcessOwnership.alive(desktop) && WindowsProcessOwnership.alive(identity) }

    static func cli(in package: URL) -> URL? {
        let cli = package.appendingPathComponent("app/resources/codex.exe")
        return WindowsCodexExecutableDiscovery.isExecutable(cli) ? cli : nil
    }

    static func find(desktop: WindowsProcessIdentity, package: URL) -> Self? {
        guard let cli = cli(in: package), let snapshot = WindowsProcessOwnership.snapshot(),
              snapshot.inspect(desktop.pid, desktop.started)?.identity == desktop else { return nil }
        let localAppData = WindowsEnvironment.value("LOCALAPPDATA", in: ProcessInfo.processInfo.environment)
            .flatMap { WindowsCodexExecutableDiscovery.absolute($0) ? URL(fileURLWithPath: $0).appendingPathComponent("OpenAI/Codex/bin") : nil }
        let children = snapshot.parents.filter { $0.value == desktop.pid }.keys
        guard children.count <= 256 else { return nil }
        var match: Self?
        for pid in children {
            guard let child = snapshot.inspect(pid, 0), child.identity.started >= desktop.started,
                  isExecutorImage(child.executable, cli: cli, managedBin: localAppData) else { continue }
            var buffer = [UInt16](repeating: 0, count: 129)
            guard pacer_process_durable_environment(pid, child.identity.started, &buffer, buffer.count) != 0 else { continue }
            guard match == nil else { return nil }
            match = Self(identity: child.identity, desktop: desktop,
                         environmentID: String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self), packagedCLI: cli)
        }
        return match?.isAlive == true ? match : nil
    }

    static func isExecutorImage(_ executable: URL, cli: URL, managedBin: URL?) -> Bool {
        if executable.path.caseInsensitiveCompare(cli.path) == .orderedSame { return true }
        // Desktop can stage an updated codex.exe in its own per-user bin.
        // Recognize that child for discovery only; launch the packaged CLI.
        let version = executable.deletingLastPathComponent()
        return executable.lastPathComponent.caseInsensitiveCompare("codex.exe") == .orderedSame &&
            version.lastPathComponent.range(of: #"^[0-9a-fA-F]{16}\z"#, options: .regularExpression) != nil &&
            managedBin.map { version.deletingLastPathComponent().path.caseInsensitiveCompare($0.path) == .orderedSame } == true
    }
}
#endif
