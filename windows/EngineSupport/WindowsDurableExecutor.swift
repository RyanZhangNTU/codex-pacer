#if os(Windows)
import Foundation
import PacerCore
import CWindowsSupport

/// A local executor is the `exec-server --remote` child of a running Codex
/// Desktop. The parent must run from a registered Codex package with that
/// package's identity; the child must run the package's CLI or the copy
/// Desktop staged. Neither a local-looking cwd nor any codex CLI proves that.
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

    /// What the search reads about one process.
    struct ProcessImage: Equatable {
        let identity: WindowsProcessIdentity
        let parent: UInt32
        let executable: URL
    }

    /// The executor of the one running Codex Desktop, or nil with none or several.
    static func findRunning() -> Self? {
        let packages = WindowsCodexExecutableDiscovery.packageLocations().prefix(12)
        guard !packages.isEmpty else { return nil }
        var rows = [pacer_process_identity](repeating: .init(), count: 256)
        let count = pacer_process_named(Array("codex.exe".utf16) + [0], &rows, rows.count)
        guard count >= 0, count <= rows.count else { return nil }
        let localAppData = WindowsEnvironment.value("LOCALAPPDATA", in: ProcessInfo.processInfo.environment)
            .flatMap { WindowsCodexExecutableDiscovery.absolute($0) ? URL(fileURLWithPath: $0).appendingPathComponent("OpenAI/Codex/bin") : nil }
        let family = Array(WindowsCodexExecutableDiscovery.packageFamily.utf16) + [0]
        let match = select(candidates: rows.prefix(Int(count)).map { ($0.pid, $0.parent) }, packages: Array(packages),
            managedBin: localAppData, process: image(_:parent:),
            packaged: { pacer_process_package_family($0.pid, $0.started, family) != 0 },
            environment: { identity in
                var buffer = [UInt16](repeating: 0, count: 129)
                guard pacer_process_durable_environment(identity.pid, identity.started, &buffer, buffer.count) != 0 else { return nil }
                return String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
            }, cli: cli(in:))
        return match?.isAlive == true ? match : nil
    }

    /// Picks the one executor among `codex.exe` processes. The parent is read
    /// first, so the command line of a codex.exe outside Desktop is never read.
    static func select(candidates: [(pid: UInt32, parent: UInt32)], packages: [URL], managedBin: URL?,
                       process: (UInt32, UInt32) -> ProcessImage?, packaged: (WindowsProcessIdentity) -> Bool,
                       environment: (WindowsProcessIdentity) -> String?, cli: (URL) -> URL?) -> Self? {
        var match: Self?
        for candidate in candidates.prefix(256) where candidate.pid > 4 && candidate.parent > 4 {
            guard let child = process(candidate.pid, candidate.parent),
                  let desktop = process(candidate.parent, 0), desktop.identity.started <= child.identity.started,
                  let package = packages.first(where: { isInside(desktop.executable, $0.appendingPathComponent("app")) }),
                  let packagedCLI = cli(package), isExecutorImage(child.executable, cli: packagedCLI, managedBin: managedBin),
                  packaged(desktop.identity), let id = environment(child.identity),
                  id.range(of: #"^[A-Za-z0-9_-]{1,128}\z"#, options: .regularExpression) != nil else { continue }
            guard match == nil else { return nil }
            match = Self(identity: child.identity, desktop: desktop.identity, environmentID: id, packagedCLI: packagedCLI)
        }
        return match
    }

    private static func image(_ pid: UInt32, parent: UInt32) -> ProcessImage? {
        var identity = pacer_process_identity(), image = [UInt16](repeating: 0, count: 32768)
        guard pacer_process_image(pid, 0, &identity, &image, image.count) != 0, identity.pid == pid, identity.started != 0 else { return nil }
        let path = String(decoding: image.prefix { $0 != 0 }, as: UTF16.self)
        guard WindowsCodexExecutableDiscovery.absolute(path) else { return nil }
        return ProcessImage(identity: .init(pid: pid, started: identity.started), parent: parent, executable: URL(fileURLWithPath: path))
    }

    static func isInside(_ file: URL, _ folder: URL) -> Bool {
        let root = WindowsCodexExecutableDiscovery.path(folder.standardizedFileURL)
        let path = WindowsCodexExecutableDiscovery.path(file.standardizedFileURL)
        let prefix = root.hasSuffix("\\") ? root : root + "\\"
        return path.count > prefix.count && path.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
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
