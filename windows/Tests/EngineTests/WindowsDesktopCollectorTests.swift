@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import XCTest
@testable import PacerCore

private actor CollectorFrames {
    var frames: [Data] = []
    var closed = 0
    func append(_ value: Data) { frames.append(value) }
    func close() { closed += 1 }
    func has(_ method: String) -> Bool {
        frames.contains { bytes in
            guard let row = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
            return (row["events"] as? [[String: Any]])?.contains { $0["method"] as? String == method } == true
        }
    }
    func approval() -> Bool {
        frames.contains { bytes in
            guard let row = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
            return (row["requests"] as? [[String: String]])?.contains { $0["kind"] == "approval" } == true
        }
    }
    func containsPrivateText() -> Bool {
        frames.contains { String(decoding: $0, as: UTF8.self).contains("PRIVATE-") || String(decoding: $0, as: UTF8.self).contains("FOREIGN-TITLE") }
    }
}
private final class CollectorEngineSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [EngineSnapshot] = []
    func append(_ data: Data) {
        guard let value = try? JSONDecoder().decode(EngineSnapshot.self, from: data) else { return }
        lock.lock(); values.append(value); lock.unlock()
    }
    func all() -> [EngineSnapshot] { lock.lock(); defer { lock.unlock() }; return values }
}

final class WindowsDesktopCollectorTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001"
    private final class Fixture {
        let root: URL, home: URL, file: URL, ready: URL, executable: URL, endpoint: String
        let process = Process()
        init(mode: String = "runtime", ignored: Bool = false, delayedHeader: Bool = false) throws {
            executable = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_DESKTOP_PIPE_FIXTURE"]))
            root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-runtime-中文 " + UUID().uuidString)
            home = root.appendingPathComponent("home"); ready = root.appendingPathComponent("ready")
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
            let directory = home.appendingPathComponent("sessions/" + formatter.string(from: Date()))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            file = directory.appendingPathComponent("rollout-019a0000-0000-7000-8000-000000000001.jsonl")
            let header: [String: Any] = ["type": "session_meta", "timestamp": ISO8601DateFormatter().string(from: Date()), "payload": [
                "id": "019a0000-0000-7000-8000-000000000001", "originator": ignored ? "embedded-fixture" : "Codex Desktop",
                "cwd": ignored ? "C:/synthetic/zotero-chat/translate" : "C:/synthetic"]]
            try (delayedHeader ? Data([10]) : JSONSerialization.data(withJSONObject: header) + Data([10])).write(to: file)
            endpoint = "PacerRuntime." + UUID().uuidString
            process.executableURL = executable
            process.arguments = [mode, endpoint, WindowsCodexExecutableDiscovery.path(ready), WindowsCodexExecutableDiscovery.path(file)]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { try? FileManager.default.removeItem(at: root); throw error }
            let limit = Date().addingTimeInterval(TestWait.limit)
            while process.isRunning && !exists("") && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
            guard exists("") else { stop(); throw WindowsDesktopTransport.Failure.unavailable }
        }
        func exists(_ suffix: String) -> Bool { FileManager.default.fileExists(atPath: ready.path + suffix) }
        func signal(_ suffix: String) throws { try Data("signal".utf8).write(to: URL(fileURLWithPath: ready.path + suffix)) }
        func collector(_ capture: CollectorFrames, home selected: URL? = nil) -> WindowsDesktopCollector {
            let endpoint = endpoint, peerRoot = executable.deletingLastPathComponent()
            return .init(home: selected ?? home, interval: 5, connect: { try .init(endpoint: endpoint, peerRoot: peerRoot) },
                onFrame: { await capture.append($0) }, onClosed: { await capture.close() })
        }
        func stop() { if process.isRunning { process.terminate() }; process.waitUntilExit(); try? FileManager.default.removeItem(at: root) }
    }
    private func until(_ message: String, timeout: TimeInterval = TestWait.limit, _ condition: () async -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while !(await condition()), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds: 20_000_000) }
        let result = await condition(); XCTAssertTrue(result, message)
    }
    func testSourceBoundRuntimeDeliversImmediateApprovalAndCompletionWithoutTranscript() async throws {
        let fixture = try Fixture(); defer { fixture.stop() }
        let original = try Data(contentsOf: fixture.file), capture = CollectorFrames(), collector = fixture.collector(capture)
        await collector.discover([thread, "019a0000-0000-7000-8000-000000000002"])
        await collector.start()
        try await until("The selected writer must feed the shared runtime session") { await capture.has("turn/attached") }
        XCTAssertFalse(fixture.exists(".foreign-follow"), "Neither an unrelated broadcast nor an unbound collaboration child may be followed")
        let sent = ProcessInfo.processInfo.systemUptime
        try fixture.signal(".approval")
        try await until("Approval cannot wait for the five-second batch", timeout: 2) { await capture.approval() }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - sent, 2)
        try fixture.signal(".complete")
        try await until("The current turn must complete through the shared parser") { await capture.has("turn/completed") }
        try fixture.signal(".close")
        try await until("EOF must close only this connection") { await capture.closed == 1 }
        XCTAssertEqual(try Data(contentsOf: fixture.file), original)
        let privateText = await capture.containsPrivateText(); XCTAssertFalse(privateText)
        await collector.stop()
        let closures = await capture.closed; XCTAssertEqual(closures, 1)
    }
    func testReplacingTheSelectedFileRejectsALateCompletion() async throws {
        let fixture = try Fixture(); defer { fixture.stop() }
        let capture = CollectorFrames(), collector = fixture.collector(capture)
        await collector.start(); await collector.discover([thread])
        try await until("The original file must bind first") { await capture.has("turn/attached") }
        let replacement = try Data(contentsOf: fixture.file)
        try FileManager.default.removeItem(at: fixture.file); try replacement.write(to: fixture.file)
        try fixture.signal(".complete")
        try await until("Replacing a bound source must revoke the connection") { await capture.closed == 1 }
        let completed = await capture.has("turn/completed"); XCTAssertFalse(completed)
        await collector.stop()
    }
    func testAnotherProfileAndIgnoredOriginsCannotSubscribe() async throws {
        for ignored in [false, true] {
            let fixture = try Fixture(ignored: ignored); defer { fixture.stop() }
            let selected = ignored ? fixture.home : fixture.root.appendingPathComponent("other-profile")
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
            let capture = CollectorFrames(), collector = fixture.collector(capture, home: selected)
            await collector.start(); await collector.discover([thread])
            try await until("The global transport may initialize without authorizing any thread") { fixture.exists(".initialized") }
            try await Task.sleep(nanoseconds: 250_000_000)
            XCTAssertFalse(fixture.exists(".streaming")); XCTAssertFalse(fixture.exists(".foreign-follow"))
            let runtime = await capture.has("turn/attached"); XCTAssertFalse(runtime)
            await collector.stop()
        }
    }
    func testHandshakeDeadlineRunsWhileTheReaderIsIdle() async throws {
        let fixture = try Fixture(mode: "runtime-no-init"); defer { fixture.stop() }
        let capture = CollectorFrames(), collector = fixture.collector(capture)
        let before = ProcessInfo.processInfo.systemUptime
        await collector.start()
        try await until("An idle pipe cannot prevent the initialization deadline", timeout: 6.5) { await capture.closed == 1 }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - before, 6.5)
        XCTAssertFalse(fixture.exists(".streaming")); await collector.stop()
    }
    func testActualCollectorFeedsEngineUnreadStateAndClearsOnProfileChange() async throws {
        let fixture = try Fixture(); defer { fixture.stop() }
        let endpoint = fixture.endpoint, peerRoot = fixture.executable.deletingLastPathComponent()
        let services = CodexDesktopServices { home, interval, frame, closed in
            WindowsDesktopCollector(home: home, interval: interval, connect: { try .init(endpoint: endpoint, peerRoot: peerRoot) },
                onFrame: frame, onClosed: closed)
        }
        let snapshots = CollectorEngineSnapshots(), runtime = EngineRuntime(demo: false, dismissalStore: nil,
            desktopServices: services, output: { snapshots.append($0) })
        func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
        }
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": WindowsCodexExecutableDiscovery.path(fixture.home)]))
        try await until("The production collector must feed the engine without a log task-start record") {
            snapshots.all().last?.tasks.contains { $0.sessionID == self.thread && $0.phase == "running" } == true
        }
        try fixture.signal(".approval")
        try await until("A source-bound approval must reach the engine immediately", timeout: 2) { snapshots.all().last?.requests.count == 1 }
        try fixture.signal(".complete")
        try await until("The pipe ending must become unread") {
            snapshots.all().last?.tasks.contains { $0.sessionID == self.thread && $0.phase == "completed" && $0.unread } == true
        }
        try fixture.signal(".close")
        try await until("Disconnected runtime status must be visible") {
            snapshots.all().last?.sources.contains { $0.id == "codex:desktop-runtime" && !$0.available } == true
        }
        _ = await runtime.receive(try command("refresh"))
        XCTAssertTrue(snapshots.all().last?.tasks.first?.unread == true, "A metadata-only log cannot erase the observed ending")
        let other = fixture.root.appendingPathComponent("other-home")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = await runtime.receive(try command("configure", ["codexHome": WindowsCodexExecutableDiscovery.path(other)]))
        XCTAssertTrue(snapshots.all().last?.tasks.isEmpty == true, "Changing physical homes must clear retained endings")
        await runtime.stop()
        let stopped = snapshots.all().count
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(snapshots.all().count, stopped)
        XCTAssertFalse(fixture.exists(".foreign-follow"))
    }
    func testRoutingHintBeforeTheRolloutHeaderIsRetriedWithoutAnotherBroadcast() async throws {
        let fixture = try Fixture(delayedHeader: true); defer { fixture.stop() }
        let capture = CollectorFrames(), collector = fixture.collector(capture)
        await collector.start()
        try await until("The initial hint must arrive before the header") { fixture.exists(".initialized") }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(fixture.exists(".streaming"))
        try fixture.signal(".repair")
        try await until("A newly valid selected rollout must not require another hint or log notification", timeout: 4) { await capture.has("turn/attached") }
        XCTAssertFalse(fixture.exists(".foreign-follow")); await collector.stop()
    }
    func testAuthorizedRemotePipeUsesCatalogHostWithoutBorrowingLocalRolloutOwnership() async throws {
        let fixture = try Fixture(mode: "runtime-remote", ignored: true); defer { fixture.stop() }
        let view = RemoteControlAuthorizationView(), capture = CollectorFrames(), host = "remote-control:work"
        view.publish(home: fixture.home, scope: "account", hosts: [host], verified: true, validate: { true })
        let endpoint = fixture.endpoint, peerRoot = fixture.executable.deletingLastPathComponent(), home = fixture.home
        let collector = WindowsDesktopCollector(home: home, interval: 5,
            connect: { try .init(endpoint: endpoint, peerRoot: peerRoot) }, hosts: ["local", host, "remote-control:foreign"],
            authorization: { view.snapshot(home: home) }, onFrame: { await capture.append($0) }, onClosed: { await capture.close() })
        let original = try Data(contentsOf: fixture.file)
        await collector.start()
        try await until("Authorized Remote Control must use the shared parser even when the local UUID is excluded") { await capture.has("turn/attached") }
        XCTAssertFalse(fixture.exists(".foreign-host-follow"), "An authenticated pipe alone cannot authorize another device")
        try fixture.signal(".approval")
        try await until("Remote approvals bypass the collapsed batch") { await capture.approval() }
        try fixture.signal(".complete")
        try await until("Remote completion reaches the shared projection") { await capture.has("turn/completed") }
        try fixture.signal(".close")
        try await until("EOF releases the owned remote pipe") { await capture.closed == 1 }
        XCTAssertEqual(try Data(contentsOf: fixture.file), original)
        let privateText = await capture.containsPrivateText(); XCTAssertFalse(privateText)
        await collector.stop()
    }
    func testAccountRevocationDropsLateRemoteCompletionBeforeItEntersCore() async throws {
        let fixture = try Fixture(mode: "runtime-remote"); defer { fixture.stop() }
        let view = RemoteControlAuthorizationView(), capture = CollectorFrames(), host = "remote-control:work", home = fixture.home
        view.publish(home: home, scope: "old", hosts: [host], verified: true, validate: { true })
        let endpoint = fixture.endpoint, peerRoot = fixture.executable.deletingLastPathComponent()
        let collector = WindowsDesktopCollector(home: home, interval: 5,
            connect: { try .init(endpoint: endpoint, peerRoot: peerRoot) }, hosts: [host],
            authorization: { view.snapshot(home: home) }, onFrame: { await capture.append($0) }, onClosed: { await capture.close() })
        await collector.start()
        try await until("The old account first establishes its own runtime") { await capture.has("turn/attached") }
        view.publish(home: home, scope: "new", hosts: [host], verified: true, validate: { true })
        try fixture.signal(".complete")
        try await until("The account change revokes the pipe") { await capture.closed == 1 }
        let completed = await capture.has("turn/completed"); XCTAssertFalse(completed)
        await collector.stop()
    }
}
#endif
