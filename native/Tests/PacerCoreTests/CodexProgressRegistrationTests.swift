import Foundation
import XCTest
@testable import PacerCore

/// Pacer's Codex MCP entry keeps the reporting tool out of tool search, so models
/// that Codex would otherwise not tell about it can report. Setup upgrades the
/// entry Pacer wrote before that setting and leaves anyone else's entry alone.
final class CodexProgressRegistrationTests: XCTestCase {
    private struct Files: PlatformFileSystem {
        func entries(in directory: URL) throws -> [URL] { [] }
        func metadata(_ url: URL, followingSymbolicLinks: Bool) -> PlatformFileMetadata? { nil }
        func read(_ url: URL, offset: UInt64, maximumBytes: Int) throws -> Data { Data() }
        func replace(_ url: URL, with data: Data) -> Bool { false }
    }
    private struct Executables: ExecutablePlatform {
        func normalize(_ input: String, userHome: URL) -> String { input }
        func isAbsolutePath(_ path: String) -> Bool { true }
        func searchPaths(environment: [String: String], userHome: URL, applicationURLs: [URL]?, systemBinDirectories: [String]?) -> [ExecutableSearchPath] { [] }
        func isExecutableFile(_ url: URL) -> Bool { true }
        func executableIdentity(_ url: URL) -> String { url.path }
        func selectionKind(_ url: URL) -> ExecutableSelectionKind? { .file }
        func selectionURLs(_ url: URL, isDirectory: Bool) -> [URL] { [url] }
        func launchEnvironment(for executable: URL, inherited: [String: String], userHome: URL) -> [String: String] { inherited }
    }
    /// An app-server whose user layer holds `servers` and that records every config write.
    private final class AppServer: ChildProcessConnection, ChildProcessLauncher, @unchecked Sendable {
        let exited = ShutdownSignal(), ioClosed = ShutdownSignal(), lock = NSLock()
        let layer: [String: Any]
        var output: (@Sendable (Data) -> Void)?
        var edits: [[String: Any]] = []
        init(home: URL, servers: [String: Any]) {
            let name: [String: Any] = ["type": "user", "file": home.appendingPathComponent("config.toml").path]
            let config: [String: Any] = servers.isEmpty ? [:] : ["mcp_servers": servers]
            layer = ["name": name, "version": "1", "config": config]
        }
        var isRunning: Bool { !exited.isFinished }
        var terminationStatus: Int32? { isRunning ? nil : 0 }
        func errorMessage() -> String { "" }
        func close() { exited.finish(); ioClosed.finish() }
        func terminateImmediately() { close() }
        func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) -> Void,
                    ended: @escaping @Sendable () -> Void) throws -> any ChildProcessConnection {
            lock.lock(); self.output = output; lock.unlock(); return self
        }
        func write(_ data: Data) throws {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            guard let id = row["id"] else { return }
            let result: [String: Any]
            switch row["method"] as? String {
            case "initialize": result = [:]
            case "config/read": result = ["layers": [layer]]
            case "config/batchWrite":
                let params = try XCTUnwrap(row["params"] as? [String: Any])
                lock.lock(); edits += params["edits"] as? [[String: Any]] ?? []; lock.unlock()
                result = [:]
            default: XCTFail("Setup must only read and write the user configuration"); result = [:]
            }
            lock.lock(); let output = output; lock.unlock()
            output?(try JSONSerialization.data(withJSONObject: ["id": id, "result": result]) + Data([10]))
        }
        func writes() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return edits }
    }

    private let command = CodexProgressCommand(executable: URL(fileURLWithPath: "/synthetic/pacer-reporter"),
                                               arguments: ["--codex-progress-mcp", "/synthetic/profile"])
    /// The entry Pacer 4.3 wrote, before it kept the tool out of tool search.
    private var earlierEntry: [String: Any] { command.value.filter { $0.key != "omit_tools_from" } }

    private func register(_ wanted: CodexProgressCommand?, existing: [String: Any]?) async throws -> (CodexProgressSetupStatus, [[String: Any]]) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var servers: [String: Any] = [:]
        if let existing { servers[CodexProgressEvidence.server] = existing }
        let server = AppServer(home: home, servers: servers)
        let client = CodexClient(executable: home.appendingPathComponent("codex"), home: home, timeout: 5,
                                 processes: server, executables: Executables(), files: Files())
        let command = command
        let status = try await client.setProgressReporter(wanted, checkOnly: false, owns: { $0 == command })
        await client.shutdown()
        return (status, server.writes())
    }

    private func assertWritesCurrentEntry(_ edits: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(edits.count, 1, file: file, line: line)
        let edit = try XCTUnwrap(edits.first, file: file, line: line)
        XCTAssertEqual(edit["keyPath"] as? String, "mcp_servers.pacer_progress", file: file, line: line)
        XCTAssertEqual(edit["mergeStrategy"] as? String, "replace", file: file, line: line)
        let value = try XCTUnwrap(edit["value"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(value["omit_tools_from"] as? [String], ["deferred"], "The tool never waits behind tool search", file: file, line: line)
        XCTAssertEqual(CodexProgressCommand(ownedEntry: value), command, file: file, line: line)
        XCTAssertTrue(command.isRegistered(by: value), file: file, line: line)
    }

    func testTheEntryKeepsTheToolOutOfToolSearch() throws {
        XCTAssertEqual(command.value["omit_tools_from"] as? [String], ["deferred"])
        XCTAssertEqual(CodexProgressCommand(ownedEntry: command.value), command)
        XCTAssertTrue(command.isRegistered(by: command.value))
        XCTAssertEqual(CodexProgressCommand(ownedEntry: earlierEntry), command, "Pacer still owns the entry it wrote earlier")
        XCTAssertFalse(command.isRegistered(by: earlierEntry), "The earlier entry needs the current settings")

        var edited = command.value; edited["omit_tools_from"] = ["deferred", "code_mode"]
        XCTAssertNil(CodexProgressCommand(ownedEntry: edited), "Edited exposure belongs to whoever edited it")
        var extra = earlierEntry; extra["enabled"] = false
        XCTAssertNil(CodexProgressCommand(ownedEntry: extra))
        var both = command.value; both["enabled"] = false
        XCTAssertNil(CodexProgressCommand(ownedEntry: both))
    }

    func testSetupWritesTheCurrentEntryAndUpgradesTheEarlierOne() async throws {
        let (fresh, freshEdits) = try await register(command, existing: nil)
        XCTAssertEqual(fresh, .ready)
        try assertWritesCurrentEntry(freshEdits)

        let (earlier, earlierEdits) = try await register(command, existing: earlierEntry)
        XCTAssertEqual(earlier, .ready)
        try assertWritesCurrentEntry(earlierEdits)

        let (current, currentEdits) = try await register(command, existing: command.value)
        XCTAssertEqual(current, .ready)
        XCTAssertTrue(currentEdits.isEmpty, "A current registration is left as it is")
    }

    func testAnEditedEntryIsKeptAndTurningOffRemovesOnlyPacersEntries() async throws {
        var edited = command.value; edited["omit_tools_from"] = ["deferred", "code_mode"]
        let (conflict, conflictEdits) = try await register(command, existing: edited)
        XCTAssertEqual(conflict, .conflict)
        XCTAssertTrue(conflictEdits.isEmpty)
        let (kept, keptEdits) = try await register(nil, existing: edited)
        XCTAssertEqual(kept, .ready)
        XCTAssertTrue(keptEdits.isEmpty, "Turning off never removes someone else's entry")

        for entry in [earlierEntry, command.value] {
            let (status, edits) = try await register(nil, existing: entry)
            XCTAssertEqual(status, .ready)
            XCTAssertEqual(edits.count, 1)
            XCTAssertEqual(edits.first?["keyPath"] as? String, "mcp_servers.pacer_progress")
            XCTAssertTrue(edits.first?["value"] is NSNull, "Either shape of Pacer's entry is removed")
        }
    }
}
