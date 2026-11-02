import Foundation
import XCTest
@testable import PacerCore

final class CodexProcessPortTests: XCTestCase {
    private struct Files: PlatformFileSystem {
        func metadata(_ url: URL) -> PlatformFileMetadata? { nil }
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
    private final class Connection: ChildProcessConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var events: [String] = []
        private var methods: [String] = []
        let exited = ShutdownSignal()
        let ioClosed = ShutdownSignal()
        private let stubborn: Bool
        let output: @Sendable (Data) -> Void
        init(output: @escaping @Sendable (Data) -> Void, stubborn: Bool) { self.output = output; self.stubborn = stubborn }
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
        var terminationStatus: Int32? { isRunning ? nil : 0 }
        func errorMessage() -> String { "" }
        func write(_ data: Data) throws {
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let method = try XCTUnwrap(request["method"] as? String)
            lock.lock(); methods.append(method); lock.unlock()
            guard let id = request["id"] as? Int else { return }
            let result: [String: Any]
            switch method {
            case "initialize": result = [:]
            case "account/read": result = ["account": ["type": "chatgpt", "planType": "fixture"]]
            case "account/rateLimits/read": result = ["rateLimits": ["primary": ["usedPercent": 25, "windowDurationMins": 300]]]
            default: XCTFail("Unexpected RPC method"); result = [:]
            }
            var reply = try JSONSerialization.data(withJSONObject: ["id": id, "result": result]); reply.append(10)
            output(reply)
        }
        func close() {
            lock.lock(); events.append("close"); if !stubborn { running = false }; lock.unlock()
            guard !stubborn else { return }
            exited.finish(); ioClosed.finish()
        }
        func terminateImmediately() {
            lock.lock(); events.append("kill"); running = false; lock.unlock()
            exited.finish()
        }
        func snapshot() -> (events: [String], methods: [String]) {
            lock.lock(); defer { lock.unlock() }; return (events, methods)
        }
    }
    private final class Launcher: ChildProcessLauncher, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(ChildProcessRequest, Connection)] = []
        private let stubborn: Bool
        init(stubborn: Bool = false) { self.stubborn = stubborn }
        func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) -> Void,
                    ended: @escaping @Sendable () -> Void) throws -> any ChildProcessConnection {
            let connection = Connection(output: output, stubborn: stubborn)
            lock.lock(); entries.append((request, connection)); lock.unlock()
            return connection
        }
        func snapshot() -> [(ChildProcessRequest, Connection)] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    func testDisconnectThenShutdownWaitsForEveryOwnedChildAndIgnoresOldOutput() async throws {
        let launcher = Launcher(), home = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-home")
        let client = CodexClient(executable: home.appendingPathComponent("codex"), home: home, timeout: 1,
            environment: ["FIXTURE": "kept"], processes: launcher, executables: Executables(), files: Files())
        _ = try await client.readQuota()
        await client.disconnect()
        _ = try await client.readQuota()
        let entries = launcher.snapshot()
        XCTAssertEqual(entries.count, 2)
        entries[0].1.output(Data("not-json\n".utf8))
        _ = try await client.readQuota()
        XCTAssertEqual(launcher.snapshot().count, 2)
        await client.shutdown()
        for (request, connection) in entries {
            XCTAssertEqual(request.environment["CODEX_HOME"], home.path)
            XCTAssertEqual(request.environment["FIXTURE"], "kept")
            XCTAssertEqual(connection.snapshot().events, ["close"])
            XCTAssertTrue(connection.snapshot().methods.allSatisfy { ["initialize", "initialized", "account/read", "account/rateLimits/read"].contains($0) })
            XCTAssertFalse(connection.isRunning)
        }
    }

    func testClientShutdownBoundsStalledIOAndChildExitAndCannotRelaunch() async throws {
        let launcher = Launcher(stubborn: true), home = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-home")
        let client = CodexClient(executable: home.appendingPathComponent("codex"), home: home, timeout: 1,
            processes: launcher, executables: Executables(), files: Files())
        _ = try await client.readQuota()
        let connection = try XCTUnwrap(launcher.snapshot().first?.1)
        let started = Date()
        await client.shutdown()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.9)
        XCTAssertTrue(connection.snapshot().events.contains("close"))
        XCTAssertTrue(connection.snapshot().events.contains("kill"))
        XCTAssertFalse(connection.ioClosed.isFinished, "The IO worker deliberately ignores cancellation")
        XCTAssertFalse(connection.isRunning)
        do { _ = try await client.readQuota(); XCTFail("A shut-down client cannot launch another child") }
        catch CodexClientError.disconnected {} catch { XCTFail("Unexpected shutdown result") }
        XCTAssertEqual(launcher.snapshot().count, 1)
    }
}
