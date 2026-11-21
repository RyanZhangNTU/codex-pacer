import Foundation
import XCTest
@testable import PacerCore
@testable import PacerEngineSupport
@testable import WindowsInstallerSupport

final class WindowsCodexHookTests: XCTestCase {
    private func fixture() throws -> (local: URL, root: URL, home: URL) {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        let base = temporary.appendingPathComponent("pacer-codex-hook-中文-" + UUID().uuidString, isDirectory: true)
        let local = base.appendingPathComponent("Local 数据", isDirectory: true)
        let home = base.appendingPathComponent("用户 一号/.codex", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock {
            guard base.path.lowercased().hasPrefix(temporary.path.lowercased() + "/"), base.lastPathComponent.hasPrefix("pacer-codex-hook-") else { return }
            try? FileManager.default.removeItem(at: base)
        }
        return (local, local.appendingPathComponent("CodexPacer/CodexProgressRuntime", isDirectory: true), home)
    }
    private var package: URL { get throws {
        URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_CLAUDE_PYTHON_PACKAGE"]), isDirectory: true)
    } }
    private func environment(localAppData: URL) -> [String: String] {
        var values = ProcessInfo.processInfo.environment.filter { $0.key.caseInsensitiveCompare("LOCALAPPDATA") != .orderedSame }
        values["LOCALAPPDATA"] = WindowsCodexHookLauncher.windowsPath(localAppData)
        return values
    }
    private func run(_ executable: URL, _ arguments: [String], input: Data, environment: [String: String]) throws -> (status: Int32, stdout: Data) {
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    /// Codex runs Windows handlers through Windows PowerShell 5.1: a quoted path
    /// at the start of the line is a syntax error, so the trusted command uses
    /// the call operator and single quotes that keep `$` and backticks literal.
    func testTheTrustedCommandCallsTheFixedLauncherWithThePowerShellCallOperator() throws {
        let home = URL(fileURLWithPath: "C:/Users/O'Brien $x/.codex", isDirectory: true)
        let command = WindowsCodexHookLauncher.commandWindows(home: home)
        XCTAssertEqual(command, "& 'C:\\Users\\O''Brien $x\\.codex\\pacer\\bin\\codex-hook.cmd'")
        XCTAssertEqual(WindowsCodexHookLauncher().commandWindows(home: home), command)
        XCTAssertNil(WindowsCodexHookLauncher().command(home: home))
        let files = try CodexHookPlugin.files(command: nil, commandWindows: command)
        let hooks = try XCTUnwrap(files.first { $0.relativePath.hasSuffix("hooks/hooks.json") })
        let definitions = try XCTUnwrap((try JSONSerialization.jsonObject(with: hooks.data) as? [String: Any])?["hooks"] as? [String: [[String: Any]]])
        for groups in definitions.values {
            let handler = try XCTUnwrap((groups.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(handler["commandWindows"] as? String, command)
            XCTAssertNil(handler["command"], "Windows writes only its own command")
        }
    }

    /// cmd reads a batch file in the console code page, so the launcher holds
    /// no literal path that could be non-ASCII: the Codex home comes from its own
    /// location and the Python under %LOCALAPPDATA% through the variable.
    func testTheLauncherIsASCIIAndNamesNoLiteralUserPath() throws {
        let local = URL(fileURLWithPath: "C:/Users/张三/AppData/Local", isDirectory: true)
        let python = local.appendingPathComponent("CodexPacer/CodexProgressRuntime/3.14.10-0123456789ab-0123456789ab/python.exe")
        let data = try WindowsCodexHookRuntime.launcher(python: python, environment: ["LocalAppData": local.path])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(data.allSatisfy { $0 < 0x80 })
        XCTAssertFalse(text.contains("张三"))
        XCTAssertTrue(text.contains("for %%I in (\"%~dp0..\\..\") do set \"PACER_CODEX_HOME=%%~fI\""))
        XCTAssertTrue(text.contains("\"%LOCALAPPDATA%\\CodexPacer\\CodexProgressRuntime\\3.14.10-0123456789ab-0123456789ab\\python.exe\" -S -B "
            + "\"%PACER_CODEX_HOME%\\pacer\\codex_hook.py\" hook \"%PACER_CODEX_HOME%\" >nul 2>&1\r\nexit /b 0\r\n"))
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "CRLF line ends only")
        XCTAssertEqual(try WindowsCodexHookRuntime.batchPath(URL(fileURLWithPath: "D:/Pacer QA/python.exe"), environment: [:]), "D:\\Pacer QA\\python.exe")
        XCTAssertThrowsError(try WindowsCodexHookRuntime.batchPath(URL(fileURLWithPath: "Z:/不存在的目录/python.exe"), environment: [:]))
        XCTAssertThrowsError(try WindowsCodexHookRuntime.batchPath(URL(fileURLWithPath: "D:/100%/python.exe"), environment: [:]))
    }

    /// The whole chain as Codex runs it: Windows PowerShell with the trusted
    /// command, the event on stdin, the bundled Python, the bootstrap and the
    /// shared program, in paths with spaces and non-ASCII names.
    func testThePreparedLauncherWritesOneIdentifierOnlyRowAndNothingToStdout() throws {
        let fixture = try fixture(), package = try self.package
        let environment = environment(localAppData: fixture.local)
        let launcher = try WindowsCodexHookRuntime(root: fixture.root, environment: environment).prepare(home: fixture.home, package: package)
        XCTAssertEqual(launcher.standardizedFileURL, WindowsCodexHookLauncher.launcher(home: fixture.home).standardizedFileURL)
        XCTAssertNoThrow(try WindowsCodexHookLauncher().prepare(home: fixture.home))
        XCTAssertTrue(try Data(contentsOf: CodexHookProgram.script(home: fixture.home)).starts(with: Data("SHARED_SOURCE = '".utf8)))
        XCTAssertTrue(String(decoding: try Data(contentsOf: launcher), as: UTF8.self).contains("%LOCALAPPDATA%\\CodexPacer\\CodexProgressRuntime\\"))

        let thread = "01a1fc3e-004f-7fc3-b297-a359b8826813", turn = "01a1fc3e-00f2-7212-b7c2-13204a44115d"
        let transcript = fixture.home.appendingPathComponent("sessions/2026/11/21/rollout-2026-11-21T10-00-00-\(thread).jsonl")
        let input = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest", "session_id": thread, "turn_id": turn, "tool_name": "Bash",
            "transcript_path": WindowsCodexHookLauncher.windowsPath(transcript), "tool_input": ["command": "synthetic-secret"],
            "permission_mode": "default", "model": "synthetic", "cwd": "C:\\synthetic-secret"])
        let system = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows", isDirectory: true)
        let powershell = system.appendingPathComponent("System32/WindowsPowerShell/v1.0/powershell.exe")
        let result = try run(powershell, ["-NoProfile", "-NonInteractive", "-Command", WindowsCodexHookLauncher.commandWindows(home: fixture.home)],
                             input: input, environment: environment)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, Data(), "A hook's output would be read as a decision")

        let spool = try Data(contentsOf: CodexHookSpool.current(home: fixture.home))
        XCTAssertFalse(String(decoding: spool, as: UTF8.self).contains("synthetic-secret"))
        let lines = spool.split(separator: 10)
        XCTAssertEqual(lines.count, 1)
        let event = try XCTUnwrap(CodexHookEvent.decode(Data(lines[0])))
        XCTAssertEqual(event.kind, .permissionRequest)
        XCTAssertEqual(event.thread, thread)
        XCTAssertEqual(event.turn, turn)
        XCTAssertEqual(event.approval, .exec)
        XCTAssertNotNil(CodexHookSpool.transcript(event.transcript, home: fixture.home))

        try WindowsCodexHookLauncher().remove(home: fixture.home)
        for path in [launcher, CodexHookProgram.script(home: fixture.home), CodexHookSpool.current(home: fixture.home), CodexHookSpool.lock(home: fixture.home)] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), path.lastPathComponent)
        }
        XCTAssertThrowsError(try WindowsCodexHookLauncher().prepare(home: fixture.home), "A missing launcher is not a prepared one")
    }
}
