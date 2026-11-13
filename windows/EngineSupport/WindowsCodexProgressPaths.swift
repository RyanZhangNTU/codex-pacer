import Foundation
import PacerCore

public struct WindowsCodexProgressPaths: Sendable {
    public static let directoryName = "CodexProgressRuntime"
    public static let scriptName = "pacer-codex-progress.py"
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    public static var defaultRoot: URL {
        let local = WindowsEnvironment.value("LOCALAPPDATA", in: ProcessInfo.processInfo.environment)
        let base = local.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local", isDirectory: true)
        return base.appendingPathComponent("CodexPacer/" + directoryName, isDirectory: true)
    }

    public func command(python: URL, home: URL) -> CodexProgressCommand {
        let script = python.deletingLastPathComponent().appendingPathComponent(Self.scriptName)
        return .init(executable: python, arguments: ["-I", "-S", script.path, home.path])
    }

    public func owns(_ command: CodexProgressCommand, home: URL) -> Bool {
        guard WindowsCodexExecutableDiscovery.absolute(command.executable) else { return false }
        let python = URL(fileURLWithPath: command.executable).standardizedFileURL
        let version = python.deletingLastPathComponent()
        return python.lastPathComponent == "python.exe" &&
            version.deletingLastPathComponent().path.caseInsensitiveCompare(root.path) == .orderedSame &&
            // The Python-only directory is still owned during migration and uninstall.
            version.lastPathComponent.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}-[0-9a-f]{12}(?:-[0-9a-f]{12})?\z"#, options: .regularExpression) != nil &&
            command.arguments == self.command(python: python, home: home).arguments
    }

    package func localHarnessCommand(_ command: CodexProgressCommand, home: URL) -> CodexProgressCommand {
        .init(executable: URL(fileURLWithPath: command.executable),
              arguments: Array(command.arguments.dropLast()) + [LocalHarnessProgressSetup.managedArgument, LocalHarnessProgressSetup.flag(home).path])
    }

    package func ownsLocalHarness(_ executable: String, arguments: [String], home: URL) -> Bool {
        guard WindowsCodexExecutableDiscovery.absolute(executable), arguments.count == 5 else { return false }
        let python = URL(fileURLWithPath: executable)
        let standard = command(python: python, home: home)
        return owns(standard, home: home) && arguments == localHarnessCommand(standard, home: home).arguments
    }
}
