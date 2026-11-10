#if os(Windows)
import Foundation
import FoundationNetworking
import WinSDK
import XCTest
@testable import PacerCore
@testable import PacerEngineSupport
import WindowsInstallerSupport

final class WindowsDurableTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000011"
    private let turn = "019a0000-0000-7000-8000-000000000012"

    func testCatalogSocketReassemblesAFragmentedReplyAndCancelsAnIdleRead() async throws {
        let server = try LoopbackHTTPServer(); defer { server.stop() }
        let socket = try WindowsDurableSocket(target: .init(host: "127.0.0.1", port: server.port, secure: false, path: "/"),
            headers: [("Sec-WebSocket-Protocol", "codex-app-server")])
        defer { socket.close() }
        let opening = Task { try await socket.send(Data("{}".utf8)) }
        guard try await TestWait.until({ server.opened }) else { throw WindowsHTTPStream.Failure.timedOut }
        let head = try XCTUnwrap(server.requests.first)
        let key = try XCTUnwrap(head.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("sec-websocket-key:") }?.split(separator: ":", maxSplits: 1).last)
        let accept = try webSocketAccept(key.trimmingCharacters(in: .whitespaces))
        server.send("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: codex-app-server\r\n\r\n")
        try await opening.value

        let text = Data(String(repeating: "Dot 中文", count: 3000).utf8)
        let split = 18_005
        func frame(_ opcode: UInt8, _ data: Data.SubSequence) -> Data {
            Data([opcode, 126, UInt8(data.count >> 8), UInt8(data.count & 255)]) + Data(data)
        }
        server.send(frame(0x01, text.prefix(split)))
        server.send(frame(0x80, text.dropFirst(split)))
        let message = try await socket.receive()
        XCTAssertEqual(message, text)

        let reading = Task { try await socket.receive() }
        try await Task.sleep(for: .milliseconds(50))
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        reading.cancel()
        do { _ = try await reading.value; XCTFail("A cancelled WebSocket read returned a message") }
        catch { XCTAssertEqual(error as? WindowsHTTPStream.Failure, .cancelled) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelledAt, 1)
        let closed = try await TestWait.until { server.closed }
        XCTAssertTrue(closed, "Cancelling a read must close the underlying connection")
    }

    func testCatalogSocketDoesNotFollowAnUpgradeRedirect() async throws {
        let server = try LoopbackHTTPServer(), other = try LoopbackHTTPServer()
        defer { server.stop(); other.stop() }
        let socket = try WindowsDurableSocket(target: .init(host: "127.0.0.1", port: server.port, secure: false, path: "/"),
            headers: [("Sec-WebSocket-Protocol", "fixture")])
        defer { socket.close() }
        let opening = Task { try await socket.send(Data("{}".utf8)) }
        guard try await TestWait.until({ server.opened }) else { throw WindowsHTTPStream.Failure.timedOut }
        server.respond(302, headers: ["Location": "http://127.0.0.1:\(other.port)/unexpected", "Content-Length": "0"])
        do { try await opening.value; XCTFail("A redirect is not a WebSocket upgrade") }
        catch { XCTAssertEqual(error as? WindowsHTTPStream.Failure, .failed) }
        XCTAssertFalse(other.opened)
    }

    func testPackagedReporterUsesOnlyVerifiedMCPMetadataAndHonorsRevocation() throws {
        let root = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let reporter = try prepareReporter(root: root)
        let flag = root.appendingPathComponent("pacer/codex-progress/native/enabled")
        try FileManager.default.createDirectory(at: flag.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("on\n".utf8).write(to: flag)
        let mailbox = WindowsDurableProgressMailbox(home: root)
        try FileManager.default.createDirectory(at: mailbox.root, withIntermediateDirectories: true)
        try WindowsDurableProgressMailbox.owner.write(to: mailbox.marker)
        try mailbox.prepare()
        let request: (String, Int, String) -> [String: Any] = { [thread, turn] call, percent, claimedThread in
            ["jsonrpc": "2.0", "id": call, "method": "tools/call", "params": ["name": "report_progress",
                "arguments": ["percent": percent], "_meta": ["threadId": thread, "callId": call,
                    "x-codex-turn-metadata": ["thread_id": claimedThread, "turn_id": turn]]]]
        }
        func send(_ requests: [[String: Any]], durable: Bool) throws -> [Bool] {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: reporter.executable)
            process.arguments = reporter.arguments + (durable ? ["--durable"] : [])
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            for request in requests {
                try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
            }
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return try data.split(separator: 10).map { line in
                let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                return try XCTUnwrap((reply["result"] as? [String: Any])?["isError"] as? Bool)
            }
        }
        XCTAssertEqual(try send([request("local", 80, thread)], durable: false), [false])
        XCTAssertTrue(mailbox.read(at: Date()).isEmpty)
        XCTAssertEqual(try send([request("mismatch", 70, turn), request("accepted", 60, thread),
                                request("accepted", 90, thread), request("lower", 25, thread)], durable: true),
                       [false, false, false, false])
        let accepted = try XCTUnwrap(mailbox.read(at: Date())[thread + ":" + turn])
        XCTAssertEqual(accepted.callID, "lower"); XCTAssertEqual(accepted.percent, 25)
        try FileManager.default.removeItem(at: flag)
        XCTAssertEqual(try send([request("disabled", 100, thread)], durable: true), [true])
        XCTAssertEqual(mailbox.read(at: Date())[thread + ":" + turn]?.callID, "lower")
    }

    func testInstalledDesktopExecutorAndPluginInADisposableProfile() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PACER_DURABLE_DESKTOP_QA"] == "1",
            "Requires a running Store Codex Desktop executor; run with PACER_DURABLE_DESKTOP_QA=1.")
        let pipe = try WindowsDesktopTransport.connectCodex(); defer { pipe.cancel() }
        let peer = try XCTUnwrap(pipe.peerIdentity), package = try XCTUnwrap(pipe.codexPackage)
        let executor = try XCTUnwrap(WindowsDurableExecutor.find(desktop: peer, package: package))
        let root = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let reporter = try prepareReporter(root: root)
        let config = root.appendingPathComponent("config.toml")
        try Data("[mcp_servers.unrelated]\ncommand = \"fixture\"\n".utf8).write(to: config)
        let installed = await WindowsDurableProgressSetup.apply(home: root, reporter: reporter, cli: executor.packagedCLI)
        XCTAssertTrue(installed)
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains("pacer-progress@codex-pacer-local"))
        let checked = await WindowsDurableProgressSetup.apply(home: root, reporter: nil, cli: executor.packagedCLI, checkOnly: true)
        XCTAssertTrue(checked)
        XCTAssertTrue(WindowsDurableProgressSetup.wasConfigured(in: root))
        let removed = await WindowsDurableProgressSetup.apply(home: root, reporter: nil, cli: executor.packagedCLI)
        XCTAssertTrue(removed)
        let remaining = try String(contentsOf: config, encoding: .utf8)
        XCTAssertFalse(remaining.contains("codex-pacer-local")); XCTAssertTrue(remaining.contains("mcp_servers.unrelated"))
        XCTAssertFalse(WindowsDurableProgressSetup.wasConfigured(in: root))
    }

    func testLiveCatalogReadOnly() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PACER_DURABLE_CATALOG_QA"] == "1",
            "Opt in to one read-only catalog request using the current Desktop login.")
        let pipe = try WindowsDesktopTransport.connectCodex(); defer { pipe.cancel() }
        let peer = try XCTUnwrap(pipe.peerIdentity), package = try XCTUnwrap(pipe.codexPackage)
        let executor = try XCTUnwrap(WindowsDurableExecutor.find(desktop: peer, package: package))
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let client = CodexClient(executable: executor.packagedCLI, home: home, timeout: 8)
        let credentials: (request: URLRequest, scope: String)
        do { credentials = try await client.durableCatalogCredentials() }
        catch {
            await client.shutdown()
            return XCTFail("The packaged CLI did not authorize the catalog.")
        }
        await client.shutdown()
        let reader = DurableCatalogReader(socket: try WindowsDurableSocket(credentials.request), scope: credentials.scope,
            environmentID: executor.environmentID)
        defer { reader.close() }
        do {
            try await reader.initialize()
            // The second read on the connection may stop paging early.
            let first = try await reader.read(retaining: nil)
            _ = try await reader.read(retaining: first.catalog)
        } catch { XCTFail("The Durable server did not return a valid catalog page.") }
    }

    private func fixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-dot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func prepareReporter(root: URL) throws -> CodexProgressCommand {
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_CLAUDE_PYTHON_PACKAGE"])
        return try WindowsCodexProgressRuntime(root: root.appendingPathComponent("CodexProgressRuntime"))
            .prepare(home: root, package: URL(fileURLWithPath: python))
    }

    private func webSocketAccept(_ key: String) throws -> String {
        var algorithm: BCRYPT_ALG_HANDLE?
        let result = BCryptOpenAlgorithmProvider(&algorithm, Array("SHA1".utf16) + [0], nil, 0)
        guard result >= 0, let algorithm else { throw WindowsHTTPStream.Failure.failed }
        defer { _ = BCryptCloseAlgorithmProvider(algorithm, 0) }
        var bytes = Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        var digest = [UInt8](repeating: 0, count: 20)
        guard BCryptHash(algorithm, nil, 0, &bytes, UInt32(bytes.count), &digest, UInt32(digest.count)) >= 0 else {
            throw WindowsHTTPStream.Failure.failed
        }
        return Data(digest).base64EncodedString()
    }
}
#endif
