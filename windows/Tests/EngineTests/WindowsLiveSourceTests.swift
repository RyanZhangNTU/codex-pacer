@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import XCTest
@testable import PacerCore

private final class LiveSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [EngineSnapshot] = []
    func append(_ data: Data) {
        guard let snapshot = try? JSONDecoder().decode(EngineSnapshot.self, from: data) else { return }
        lock.lock(); defer { lock.unlock() }; values.append(snapshot)
    }
    func all() -> [EngineSnapshot] { lock.lock(); defer { lock.unlock() }; return values }
}

final class WindowsLiveSourceTests: XCTestCase {
    private func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
    }
    private func record(_ type: String, payload: [String: Any], at now: Date) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["timestamp": ISO8601DateFormatter().string(from: now), "type": type, "payload": payload]) + Data([10])
    }
    private func session(_ home: URL, id: String, at now: Date) throws -> URL {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let day = home.appendingPathComponent("sessions/" + formatter.string(from: now))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-" + id + ".jsonl")
        var bytes = try record("session_meta", payload: ["id": id, "source": "cli", "cwd": "C:\\synthetic"], at: now)
        bytes += try record("event_msg", payload: ["type": "task_started", "turn_id": id], at: now)
        try bytes.write(to: file)
        return file
    }
    private func finish(_ file: URL, id: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: record("event_msg", payload: ["type": "task_complete", "turn_id": id], at: Date()))
    }
    private func until(_ predicate: () -> Bool, message: String) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        while !predicate(), ProcessInfo.processInfo.systemUptime - started < TestWait.limit {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(predicate(), message)
    }
    func testLiveNotificationsDiscoverAndFinishTasksAndStopWithTheEngine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-live-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("first"), replacement = root.appendingPathComponent("second")
        let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased(), third = UUID().uuidString.lowercased()
        let original = try session(home, id: first, at: Date())
        let capture = LiveSnapshots()
        let runtime = EngineRuntime(demo: false, dismissalStore: nil, output: { capture.append($0) })
        func path(_ url: URL) -> String { url.withUnsafeFileSystemRepresentation { String(cString: $0!) } }
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": path(home)]))
        XCTAssertEqual(capture.all().last?.runningCount, 1)
        try finish(original, id: first)
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = await runtime.receive(try command("setExpanded", ["expanded": true]))
        XCTAssertTrue(capture.all().last?.tasks.contains { $0.sessionID == first && $0.phase == "completed" && $0.unread } == true,
            "Expansion must flush the appended ending without another write")

        let created = try session(home, id: second, at: Date())
        try await until({ capture.all().last?.tasks.contains { $0.sessionID == second && $0.phase == "running" } == true },
            message: "A new session must appear from a directory notification, before minute maintenance")
        try finish(created, id: second)
        try await until({ capture.all().last?.tasks.contains { $0.sessionID == second && $0.phase == "completed" && $0.unread } == true },
            message: "An appended ending must reach the engine through a write notification")

        let active = try session(replacement, id: third, at: Date())
        _ = await runtime.receive(try command("configure", ["codexHome": path(replacement)]))
        XCTAssertEqual(capture.all().last?.tasks.compactMap(\.sessionID), [third], "Changing profiles must clear old live and retained rows")
        try finish(original, id: first)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(capture.all().last?.tasks.compactMap(\.sessionID), [third])
        await runtime.stop()
        let stopped = capture.all().count
        try finish(active, id: third)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(capture.all().count, stopped, "Stopping must cancel source notifications and the metadata clock")
    }
    func testOneQuietClaudeAppendDrainsAcrossReadBudgetsWithoutAnotherNotification() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-live-claude-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let spool = home.appendingPathComponent("pacer")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        let file = spool.appendingPathComponent("events.jsonl")
        try Data().write(to: file)
        let capture = LiveSnapshots(), session = UUID().uuidString.lowercased(), prompt = UUID().uuidString.lowercased()
        let runtime = EngineRuntime(demo: false, dismissalStore: nil, output: { capture.append($0) })
        let path = home.withUnsafeFileSystemRepresentation { String(cString: $0!) }
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["claude"], "claudeHome": path]))
        _ = await runtime.receive(try command("setExpanded", ["expanded": true]))
        let now = Date().timeIntervalSince1970
        func row(_ kind: String, at: Double) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["kind": kind, "origin": "hook", "sessionId": session, "promptId": prompt, "at": at]) + Data([10])
        }
        var append = try row("prompt", at: now)
        for _ in 0..<700 { append += try row("metadata", at: now) }
        append += try row("stopVerified", at: now + 0.01)
        let writer = try FileHandle(forWritingTo: file)
        try writer.write(contentsOf: append); try writer.close()
        try await until({ capture.all().last?.tasks.contains { $0.sessionID == session && $0.phase == "completed" && $0.unread } == true },
            message: "The last ending in a quiet append beyond the 512-record budget must drain without another write")
        await runtime.stop()
    }
}
#endif
