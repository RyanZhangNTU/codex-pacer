import Foundation
import XCTest
@testable import PacerCore

final class CodexRemoteProgressSetupTests: XCTestCase {
    private func payload(_ command: String) throws -> [String: Any] {
        let encoded = try XCTUnwrap(command.split(separator: " ").last.map(String.init))
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCommandShipsTheReporterOnlyWhileTheRingIsOn() throws {
        for enabled in [true, false] {
            let command = try CodexRemoteProgressSetup.command(home: "~/.codex", enabled: enabled)
            XCTAssertTrue(command.hasPrefix("python3 -u -c 'import base64;exec(base64.b64decode(\""))
            let value = try payload(command)
            XCTAssertEqual(value["home"] as? String, "~/.codex")
            XCTAssertEqual(value["enabled"] as? Bool, enabled)
            XCTAssertEqual(value["reporter"] != nil, enabled, "Turning off ships no reporter")
            if let reporter = value["reporter"] as? String {
                XCTAssertEqual(Data(base64Encoded: reporter), try CodexRemoteProgressSetup.resources().reporter)
            }
        }
        for home in ["", "~/.codex\n", String(repeating: "a", count: 4097)] {
            XCTAssertThrowsError(try CodexRemoteProgressSetup.command(home: home, enabled: true)) {
                XCTAssertEqual($0 as? ClaudeRemoteSetup.Failure, .invalidTarget)
            }
        }
        XCTAssertNotEqual(try CodexRemoteProgressSetup.digest(enabled: true), try CodexRemoteProgressSetup.digest(enabled: false),
                          "Switching the ring sets connected hosts up again")
    }

    func testResponsesCarryOnlyTwoBooleansOrAKnownError() throws {
        func status(_ text: String, _ exit: Int32 = 0) throws -> CodexRemoteProgressSetup.Status {
            try CodexRemoteProgressSetup.status(data: Data(text.utf8), exitStatus: exit)
        }
        XCTAssertEqual(try status(#"{"configured":true,"conflict":false}"#), .init(configured: true, conflict: false))
        XCTAssertEqual(try status(#"{"configured":false,"conflict":true}"#), .init(configured: false, conflict: true))
        let failures: [(String, Int32, ClaudeRemoteSetup.Failure)] = [
            (#"{"error":"missingHome"}"#, 1, .missingHome), (#"{"error":"unsafePath"}"#, 1, .unsafePath),
            (#"{"error":"changedSettings"}"#, 1, .changedSettings), (#"{"error":"invalidSettings"}"#, 1, .invalidSettings),
            (#"{"error":"somethingElse"}"#, 1, .setupFailed), ("ssh: connect failed", 255, .connectionFailed),
            ("not json", 0, .invalidResponse), (#"{"configured":true,"conflict":false,"path":"/home"}"#, 0, .invalidResponse),
            (#"{"configured":"yes","conflict":false}"#, 0, .invalidResponse), (#"{"configured":true,"conflict":false}"#, 1, .connectionFailed)
        ]
        for (text, exit, expected) in failures {
            XCTAssertThrowsError(try status(text, exit), text) { XCTAssertEqual($0 as? ClaudeRemoteSetup.Failure, expected, text) }
        }
        XCTAssertThrowsError(try status(String(repeating: " ", count: 4097))) {
            XCTAssertEqual($0 as? ClaudeRemoteSetup.Failure, .invalidResponse)
        }
    }

    func testConfiguredDigestsStayBoundedPerHost() {
        let suite = "codex-remote-progress-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for index in 0..<40 { CodexRemoteProgressSetup.recordConfigured(alias: String(format: "host-%02d", index), digest: "d\(index)", defaults: defaults) }
        let digests = CodexRemoteProgressSetup.configuredDigests(defaults: defaults)
        XCTAssertEqual(digests.count, 32)
        XCTAssertEqual(digests["host-39"], "d39")
    }

    /// The setup runs over SSH or WSL with the same transport and deadline as Claude's.
    func testInstallRunsTheCommandThroughTheTransportAndParsesItsAnswer() async throws {
        final class Operation: ClaudeRemoteSetupOperation, @unchecked Sendable {
            let arguments: [String]
            init(_ arguments: [String]) { self.arguments = arguments }
            var failure: ClaudeRemoteSetup.Failure? { nil }
            func start() throws {}
            func result() throws -> (data: Data, exitStatus: Int32)? { (Data(#"{"configured":true,"conflict":false}"#.utf8), 0) }
            func abort(_ failure: ClaudeRemoteSetup.Failure) {}
            func close() {}
        }
        final class Recorder: @unchecked Sendable { var arguments: [[String]] = [] }
        let recorder = Recorder()
        let transport = ClaudeRemoteSetup(executable: URL(fileURLWithPath: "/usr/bin/ssh"), makeOperation: { _, arguments in
            recorder.arguments.append(arguments); return Operation(arguments)
        }, validDestination: { _ in true })
        let target = RemoteActivityTarget(id: "ssh:devbox", name: "devbox", alias: "devbox", home: "~/.codex")
        let status = try await CodexRemoteProgressSetup.install(target: target, enabled: true, transport: transport)
        XCTAssertEqual(status, .init(configured: true, conflict: false))
        let command = try XCTUnwrap(recorder.arguments.first?.last)
        XCTAssertEqual(try payload(command)["home"] as? String, "~/.codex")
        XCTAssertTrue(recorder.arguments.first?.contains("devbox") == true, "The command runs over the target's SSH route")
    }
}
