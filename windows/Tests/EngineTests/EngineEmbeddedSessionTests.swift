@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore

private final class EmbeddedSessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func date() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(2) }
}
private final class EmbeddedSessionFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var value: EngineSnapshot?
    private var readError: String?
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if let snapshot = try? JSONDecoder().decode(EngineSnapshot.self, from: data) { value = snapshot }
        else if let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any], reply["id"] as? String == "markAllRead" {
            readError = reply["type"] as? String == "error" ? reply["code"] as? String : nil
        }
    }
    func latest() throws -> EngineSnapshot { lock.lock(); defer { lock.unlock() }; return try XCTUnwrap(value) }
    func lastReadError() -> String? { lock.lock(); defer { lock.unlock() }; return readError }
}

final class EngineEmbeddedSessionTests: XCTestCase {
    private func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": method, "method": method, "params": params])
    }
    private func markVisibleRead(_ runtime: EngineRuntime, capture: EmbeddedSessionFrames) async throws {
        for _ in 0..<8 {
            _ = await runtime.receive(try command("markAllRead", ["snapshotSequence": try capture.latest().sequence]))
            guard let failure = capture.lastReadError() else { return }
            XCTAssertEqual(failure, "staleSnapshot", "Only a newer watched-file frame may invalidate this acknowledgement")
        }
        XCTFail("A visible-only read command must eventually be acknowledged")
    }
    func testHiddenFamilyFinishesWithoutNoticesAndKeepsUnreadUntilShownAndMarkedRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-embedded-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = EmbeddedSessionClock(), capture = EmbeddedSessionFrames()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let folder = root.appendingPathComponent("sessions/" + formatter.string(from: clock.date()))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func id(_ number: Int) -> String { String(format: "019a0000-0000-7000-8000-%012d", number) }
        func row(_ type: String, _ payload: [String: Any], _ date: Date) throws -> Data {
            var bytes = try JSONSerialization.data(withJSONObject: ["timestamp": ISO8601DateFormatter().string(from: date), "type": type, "payload": payload])
            bytes.append(10); return bytes
        }
        func start(_ number: Int, embedded: Bool, parent: Int? = nil) throws -> URL {
            let url = folder.appendingPathComponent("rollout-" + id(number) + ".jsonl")
            var metadata: [String: Any] = ["id": id(number), "cwd": root.path, "source": "cli",
                "originator": embedded ? "@agentclientprotocol/codex-acp" : "codex-tui"]
            if let parent { metadata["parent_thread_id"] = id(parent) }
            var bytes = try row("session_meta", metadata, clock.date().addingTimeInterval(-2))
            bytes.append(try row("event_msg", ["type": "task_started", "turn_id": "synthetic-" + id(number)], clock.date().addingTimeInterval(-1)))
            try bytes.write(to: url); return url
        }
        let parent = try start(1, embedded: true), child = try start(2, embedded: false, parent: 1)
        _ = try start(3, embedded: false)
        let runtime = EngineRuntime(demo: false, now: { clock.date() }, dismissalStore: nil, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize", ["codexHome": EngineCodexSourceReport.path(root), "enabledProviders": ["codex"]]))
        XCTAssertEqual(try capture.latest().tasks.count, 3)
        _ = await runtime.receive(try command("configure", ["showEmbeddedCodexSessions": false]))
        XCTAssertEqual(try capture.latest().tasks.map(\.sessionID), [id(3)])
        XCTAssertEqual(try capture.latest().runningCount, 1)
        XCTAssertEqual(try capture.latest().presentation.header.activeCount, 1)
        clock.advance()
        for (url, number) in [(parent, 1), (child, 2)] {
            let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
            try handle.write(contentsOf: row("event_msg", ["type": "task_complete", "turn_id": "synthetic-" + id(number)], clock.date()))
            try handle.close()
        }
        await runtime.refresh(discover: false)
        let hidden = try capture.latest()
        XCTAssertEqual(hidden.tasks.map(\.sessionID), [id(3)])
        XCTAssertNil(hidden.presentation.header.ending)
        XCTAssertTrue(hidden.notices.allSatisfy { !$0.id.hasPrefix(id(1) + ":") && !$0.id.hasPrefix(id(2) + ":") })
        try await markVisibleRead(runtime, capture: capture)
        _ = await runtime.receive(try command("configure", ["showEmbeddedCodexSessions": true]))
        let shown = try capture.latest(), ended = shown.tasks.filter { $0.sessionID != id(3) }
        XCTAssertEqual(ended.count, 2)
        XCTAssertTrue(ended.allSatisfy { $0.phase == "completed" && $0.unread }, "Hidden completions must survive a visible-only Mark All Read")
        try await markVisibleRead(runtime, capture: capture)
        let read = try capture.latest()
        XCTAssertTrue(read.tasks.filter { $0.sessionID != id(3) }.allSatisfy { !$0.unread })
        XCTAssertTrue(read.tasks.contains { $0.sessionID == id(3) && $0.phase == "running" })
        XCTAssertNil(read.presentation.header.ending)
        await runtime.stop()
    }
    func testClaudeSwitchIsIndependentAndLatestMetadataRestoresAHiddenFamilyWithoutAcknowledgment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-claude-embedding-" + UUID().uuidString)
        let spool = root.appendingPathComponent("pacer")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = spool.appendingPathComponent("events.jsonl"); try Data().write(to: file)
        let capture = EmbeddedSessionFrames(), clock = EmbeddedSessionClock()
        let runtime = EngineRuntime(demo: false, now: { clock.date() }, dismissalStore: nil,
            claudeHookServices: .init { _, _ in .init(.ready) }, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["claude"], "claudeHome": EngineCodexSourceReport.path(root)]))
        let parent = "11111111-1111-4111-8111-111111111111", child = "22222222-2222-4222-8222-222222222222", terminal = "33333333-3333-4333-8333-333333333333"
        func row(_ kind: String, _ session: String, _ extra: [String: Any] = [:]) throws -> Data {
            var value: [String: Any] = ["kind": kind, "origin": "hook", "sessionId": session, "promptId": session, "at": clock.date().timeIntervalSince1970]
            value.merge(extra) { _, latest in latest }
            return try JSONSerialization.data(withJSONObject: value) + Data([10])
        }
        func append(_ data: Data) throws { let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close() }
        func until(_ condition: () throws -> Bool) async throws {
            for _ in 0..<400 { if try condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
            XCTFail("The private Claude fixture did not publish its matching state")
        }
        try append(row("metadata", parent, ["embedded": true]) + row("prompt", parent) +
            row("subagentStart", child, ["parentId": parent]) + row("prompt", terminal))
        try await until { try capture.latest().tasks.count == 3 }
        _ = await runtime.receive(try command("configure", ["showEmbeddedCodexSessions": false]))
        XCTAssertEqual(try capture.latest().tasks.count, 3, "Codex's switch cannot hide Claude's sessions")
        _ = await runtime.receive(try command("configure", ["showEmbeddedClaudeSessions": false]))
        XCTAssertEqual(try capture.latest().tasks.map(\.sessionID), [terminal])
        clock.advance()
        try append(row("stopVerified", parent) + row("stopVerified", child))
        await runtime.refresh(discover: false)
        try await until { try capture.latest().tasks.map(\.sessionID) == [terminal] }
        XCTAssertTrue(try capture.latest().notices.isEmpty)
        try await markVisibleRead(runtime, capture: capture)
        _ = await runtime.receive(try command("configure", ["showEmbeddedClaudeSessions": true]))
        try await until { try capture.latest().tasks.filter { $0.sessionID != terminal }.allSatisfy { $0.phase == "completed" && $0.unread } && capture.latest().tasks.count == 3 }
        XCTAssertEqual(try capture.latest().tasks.filter { $0.unread }.count, 2)
        _ = await runtime.receive(try command("configure", ["showEmbeddedClaudeSessions": false]))
        clock.advance(); try append(row("metadata", parent, ["embedded": false]))
        try await until { try capture.latest().tasks.count == 3 }
        XCTAssertEqual(try capture.latest().tasks.filter { $0.unread }.count, 2, "New CLI metadata restores retained endings without marking them read")
        await runtime.stop()
    }
}
