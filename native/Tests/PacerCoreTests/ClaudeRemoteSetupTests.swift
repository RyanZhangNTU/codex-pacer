import XCTest
import Darwin
@testable import PacerCore

final class ClaudeRemoteSetupTests: XCTestCase {
    private let success = #"{"hooksConfigured":true,"telemetryConfigured":true,"statusLineConfigured":true,"telemetryConflict":false}"#
    private var target: RemoteActivityTarget { RemoteActivityTarget(id: "fixture-host", name: "Fixture", alias: "fixture-host", home: "/private-codex-home") }

    private func fixture() throws -> (root: URL, home: URL) {
        let root = URL(fileURLWithPath: "/private/tmp/pacer-claude-remote-" + UUID().uuidString)
        let home = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (root, home)
    }

    private func write(_ value: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: file)
    }

    private func read(_ file: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    private func runInstaller(home: URL, environment: [String: String]? = nil) throws -> (value: [String: Any], bytes: Data, status: Int32) {
        let resources = try ClaudeRemoteSetup.resources()
        let payload = try JSONSerialization.data(withJSONObject: ["home": home.path, "hook": resources.hook.base64EncodedString()])
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", "import base64;exec(base64.b64decode('\(resources.installer.base64EncodedString())').decode())", payload.base64EncodedString()]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        for key in Array(env.keys) where key.hasPrefix("OTEL_") || key.hasPrefix("CLAUDE_CODE_") { env.removeValue(forKey: key) }
        if let environment { env.merge(environment) { _, value in value } }
        process.environment = env
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any]), bytes, process.terminationStatus)
    }

    func testFixtureInstallIsPrivateIdempotentAndPreservesHooksAndRenderer() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.home.appendingPathComponent("settings.json")
        let originalGroup: [String: Any] = ["matcher": "Bash", "customOption": "retained", "hooks": [
            ["type": "command", "command": "printf existing-hook", "timeout": 20], ["type": "prompt", "prompt": "PRIVATE fixture rule"]]]
        let line: [String: Any] = ["type": "command", "command": "printf existing-renderer", "padding": 4, "extra": "retained"]
        let original: [String: Any] = ["hooks": ["PreToolUse": [originalGroup], "FutureEvent": [["custom": true]]],
            "env": ["USER_SETTING": "PRIVATE fixture value", "CLAUDE_CODE_ENABLE_TELEMETRY": "1"],
            "statusLine": line, "permissions": ["allow": ["Read"]], "custom": ["enabled": true]]
        try write(original, to: file)
        let firstResult = try runInstaller(home: fixture.home)
        XCTAssertEqual(firstResult.status, 0)
        XCTAssertTrue(try ClaudeRemoteSetup.status(data: firstResult.bytes, exitStatus: 0).hooksConfigured)
        XCTAssertFalse(String(decoding: firstResult.bytes, as: UTF8.self).contains("PRIVATE"))
        XCTAssertFalse(String(decoding: firstResult.bytes, as: UTF8.self).contains(fixture.home.path))
        let first = try read(file), manifestURL = fixture.home.appendingPathComponent("pacer/installation.json")
        let manifest = try read(manifestURL)
        XCTAssertTrue(NSDictionary(dictionary: manifest["previousStatusLine"] as? [String: Any] ?? [:]).isEqual(to: line))
        XCTAssertNil((manifest["addedEnvironment"] as? [String: String])?["CLAUDE_CODE_ENABLE_TELEMETRY"])
        XCTAssertEqual((first["env"] as? [String: String])?["USER_SETTING"], "PRIVATE fixture value")
        XCTAssertEqual((first["statusLine"] as? [String: Any])?["padding"] as? Int, 4)
        let hooks = try XCTUnwrap(first["hooks"] as? [String: [[String: Any]]])
        XCTAssertNotNil(hooks["MessageDisplay"], "Interactive first-output events must have an installed owned hook")
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(hooks["PreToolUse"]?.first)).isEqual(to: originalGroup))
        for (event, groups) in hooks where event != "FutureEvent" {
            let owned = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.filter {
                $0["type"] as? String == "command" && ($0["command"] as? String)?.contains("/pacer/hook.py'") == true
            }
            XCTAssertEqual(owned.count, 1, event)
        }
        _ = try runInstaller(home: fixture.home)
        XCTAssertTrue(NSDictionary(dictionary: try read(file)).isEqual(to: first))
        XCTAssertTrue(NSDictionary(dictionary: try read(manifestURL)).isEqual(to: manifest))
        for path in [file, manifestURL] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: fixture.home.appendingPathComponent("pacer").path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try Data(contentsOf: fixture.home.appendingPathComponent("pacer/hook.py")), try ClaudeRemoteSetup.resources().hook)
    }

    func testConflictingTelemetryAndInheritedExporterStayUntouched() throws {
        let conflicts = [
            ["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "http://127.0.0.1:54321/v1/traces"],
            ["OTEL_EXPORTER_OTLP_ENDPOINT": "https://private-fixture.invalid"],
            ["OTEL_EXPORTER_OTLP_HEADERS": "PRIVATE fixture header"],
            ["OTEL_EXPORTER_OTLP_TRACES_HEADERS": "PRIVATE fixture header"],
            ["CLAUDE_CODE_ENABLE_TELEMETRY": "0"]
        ]
        for conflict in conflicts {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
            let file = fixture.home.appendingPathComponent("settings.json")
            let env = conflict.merging(["USER_SETTING": "retained"]) { _, value in value }
            try write(["env": env], to: file)
            let result = try runInstaller(home: fixture.home)
            let status = try ClaudeRemoteSetup.status(data: result.bytes, exitStatus: result.status)
            XCTAssertTrue(status.hooksConfigured); XCTAssertTrue(status.statusLineConfigured)
            XCTAssertTrue(status.telemetryConflict); XCTAssertFalse(status.telemetryConfigured)
            XCTAssertEqual(try read(file)["env"] as? [String: String], env)
        }
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runInstaller(home: fixture.home, environment: ["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "https://private-fixture.invalid"])
        XCTAssertTrue(try ClaudeRemoteSetup.status(data: result.bytes, exitStatus: result.status).telemetryConflict)
        XCTAssertNil(try read(fixture.home.appendingPathComponent("settings.json"))["env"])
    }

    func testMalformedSettingsAndSymlinksAbortWithoutChangingUserFiles() throws {
        let invalid = ["[]", "{broken", #"{"hooks":[]}"#, #"{"hooks":{"SessionStart":[{"hooks":"bad"}]}}"#,
                       #"{"env":{"X":1}}"#, #"{"statusLine":null}"#, #"{"custom":NaN}"#, #"{"custom":1,"custom":2}"#]
        for text in invalid {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
            let file = fixture.home.appendingPathComponent("settings.json"), original = Data(text.utf8)
            try original.write(to: file)
            let result = try runInstaller(home: fixture.home)
            XCTAssertEqual(result.value["error"] as? String, "invalidSettings")
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("pacer").path))
        }
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let external = fixture.root.appendingPathComponent("external.json"), file = fixture.home.appendingPathComponent("settings.json")
        let original = Data(#"{"PRIVATE":"fixture"}"#.utf8); try original.write(to: external)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        let result = try runInstaller(home: fixture.home)
        XCTAssertEqual(result.value["error"] as? String, "unsafePath")
        XCTAssertEqual(try Data(contentsOf: external), original)
        XCTAssertFalse(String(decoding: result.bytes, as: UTF8.self).contains("PRIVATE"))
    }

    func testSSHArgumentsRequireSafeAliasAndReturnOnlyStrictBooleanStatus() throws {
        let args = try ClaudeRemoteSetup.arguments(target: target)
        XCTAssertEqual(Array(args.dropLast(3)), ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
            "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"])
        XCTAssertEqual(args[args.count - 3], "--"); XCTAssertEqual(args[args.count - 2], target.alias)
        XCTAssertFalse(args.last!.contains(target.home))
        for alias in ["-oProxyCommand=bad", "fixture host", "host\n", "host;private"] {
            XCTAssertThrowsError(try ClaudeRemoteSetup.arguments(target: RemoteActivityTarget(id: "fixture", name: "Fixture", alias: alias, home: "~/.claude")))
        }
        XCTAssertTrue(try ClaudeRemoteSetup.status(data: Data(success.utf8), exitStatus: 0).telemetryConfigured)
        for text in [success.replacingOccurrences(of: "true", with: "1"), success.dropLast() + #", "privatePath":"PRIVATE"}"#] {
            XCTAssertThrowsError(try ClaudeRemoteSetup.status(data: Data(text.utf8), exitStatus: 0))
        }
        XCTAssertThrowsError(try ClaudeRemoteSetup.status(data: Data(), exitStatus: 255)) { error in
            XCTAssertEqual(error as? ClaudeRemoteSetup.Failure, .connectionFailed)
        }
    }

    private func executable(in root: URL, code: String) throws -> URL {
        let file = root.appendingPathComponent("fixture-ssh")
        try Data(("#!/usr/bin/python3\n" + code).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    private func waitForPID(_ file: URL) async throws -> Int32 {
        for _ in 0..<100 {
            if let bytes = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(bytes) { return pid }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("owned setup process did not start"); throw ClaudeRemoteSetup.Failure.setupFailed
    }

    private func assertExited(_ pid: Int32) async throws {
        for _ in 0..<100 {
            if Darwin.kill(pid, 0) != 0, errno == ESRCH { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("owned setup process remained alive")
        _ = Darwin.kill(pid, SIGKILL)
    }

    func testRealSubprocessSuccessAndBoundedOutput() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = try executable(in: fixture.root, code: "print('\(success)')\n")
        let setup = ClaudeRemoteSetup(executable: file, timeout: 1)
        let status = try await setup.install(target: target)
        XCTAssertTrue(status.hooksConfigured)
        _ = try executable(in: fixture.root, code: "import sys\nsys.stdout.write('x'*10000)\nsys.stdout.flush()\n")
        do { _ = try await setup.install(target: target); XCTFail("oversized setup response was accepted") }
        catch { XCTAssertEqual(error as? ClaudeRemoteSetup.Failure, .invalidResponse) }
        await setup.shutdown()
    }

    func testTimeoutAndExplicitShutdownKillOnlyOwnedSetupSubprocess() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = target
        let pidFile = fixture.root.appendingPathComponent("pid")
        // A JSON string is not a Python string literal: JSONSerialization may
        // escape path separators as \/, which Python preserves as backslashes.
        let pidPath = Data(pidFile.path.utf8).base64EncodedString()
        let hanging = "import base64,os,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nwith open(base64.b64decode('\(pidPath)').decode(),'w') as handle: handle.write(str(os.getpid()))\nwhile True: time.sleep(0.1)\n"
        let file = try executable(in: fixture.root, code: hanging)
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/usr/bin/env"); unrelated.arguments = ["python3", "-c", "import time;time.sleep(30)"]
        unrelated.standardOutput = FileHandle.nullDevice; unrelated.standardError = FileHandle.nullDevice
        try unrelated.run(); defer { if unrelated.isRunning { unrelated.terminate() }; unrelated.waitUntilExit() }
        // Include a cold interpreter launch in the fixture budget. A 600 ms
        // deadline could kill it before the PID/ignored-SIGTERM marker, testing
        // startup scheduling instead of cleanup of an already hung peer.
        let setup = ClaudeRemoteSetup(executable: file, timeout: 1.5), started = ProcessInfo.processInfo.systemUptime
        let timedTask = Task { try await setup.install(target: destination) }
        defer { timedTask.cancel() }
        let timedPID = try await waitForPID(pidFile)
        do { _ = try await timedTask.value; XCTFail("hanging setup did not time out") }
        catch { XCTAssertEqual(error as? ClaudeRemoteSetup.Failure, .timedOut) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        try await assertExited(timedPID); XCTAssertTrue(unrelated.isRunning)
        try FileManager.default.removeItem(at: pidFile)
        let cancellable = ClaudeRemoteSetup(executable: file, timeout: 15)
        let task = Task { try await cancellable.install(target: destination) }
        defer { task.cancel() }
        let cancelPID = try await waitForPID(pidFile)
        await cancellable.shutdown()
        do { _ = try await task.value; XCTFail("shutdown did not cancel setup") }
        catch { XCTAssertEqual(error as? ClaudeRemoteSetup.Failure, .cancelled) }
        try await assertExited(cancelPID); XCTAssertTrue(unrelated.isRunning)
        try FileManager.default.removeItem(at: pidFile)
        let cancelledTask = Task { try await cancellable.install(target: destination) }
        defer { cancelledTask.cancel() }
        let taskPID = try await waitForPID(pidFile)
        cancelledTask.cancel()
        do { _ = try await cancelledTask.value; XCTFail("task cancellation did not stop setup") }
        catch { XCTAssertEqual(error as? ClaudeRemoteSetup.Failure, .cancelled) }
        try await assertExited(taskPID); XCTAssertTrue(unrelated.isRunning)
    }
}
