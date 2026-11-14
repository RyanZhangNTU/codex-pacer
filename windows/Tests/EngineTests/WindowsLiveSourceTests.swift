@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import SQLite3
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

private final class CodexTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func set(_ date: Date) { lock.lock(); defer { lock.unlock() }; self.date = date }
}

final class WindowsLiveSourceTests: XCTestCase {
    private func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
    }
    private func record(_ type: String, payload: [String: Any], at now: Date) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["timestamp": ISO8601DateFormatter().string(from: now), "type": type, "payload": payload]) + Data([10])
    }
    private func dayDirectory(_ home: URL, at date: Date) -> URL {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        return home.appendingPathComponent("sessions/" + formatter.string(from: date), isDirectory: true)
    }
    private func session(_ home: URL, id: String, at now: Date) throws -> URL {
        let day = dayDirectory(home, at: now)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-" + id + ".jsonl")
        var bytes = try record("session_meta", payload: ["id": id, "source": "cli", "originator": "codex_cli_rs", "cwd": "C:\\synthetic"], at: now)
        bytes += try record("event_msg", payload: ["type": "task_started", "turn_id": id], at: now)
        try bytes.write(to: file)
        return file
    }
    private func appendTurn(_ event: String, to file: URL, turn: String, at date: Date) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: record("event_msg", payload: ["type": event, "turn_id": turn], at: date))
    }
    private func finish(_ file: URL, id: String) throws {
        try appendTurn("task_complete", to: file, turn: id, at: Date())
    }
    private func indexSession(_ file: URL, in home: URL) throws {
        var database: OpaquePointer?
        let path = EngineCodexSourceReport.path(home.appendingPathComponent("state_1.sqlite"))
        let opened = sqlite3_open(path, &database)
        defer { sqlite3_close(database) }
        XCTAssertEqual(opened, SQLITE_OK)
        guard let database else { return }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE threads (rollout_path TEXT)", nil, nil, nil), SQLITE_OK)
        let rollout = EngineCodexSourceReport.path(file).replacingOccurrences(of: "'", with: "''")
        XCTAssertEqual(sqlite3_exec(database, "INSERT INTO threads VALUES ('\(rollout)')", nil, nil, nil), SQLITE_OK)
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

    func testCodexFileEventsDiscoverNewAndResumedTurnsAcrossMidnight() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-codex-watch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let calendar = Calendar.current
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let beforeMidnight = midnight.addingTimeInterval(-10), afterMidnight = midnight.addingTimeInterval(1)
        let clock = CodexTestClock(beforeMidnight)
        let capture = LiveSnapshots()
        let runtime = EngineRuntime(demo: false, now: { clock.now }, dismissalStore: nil, output: { capture.append($0) })
        let oldID = UUID().uuidString.lowercased()
        let oldDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: beforeMidnight))
        let oldFile = try session(root, id: oldID, at: oldDate)
        try appendTurn("task_complete", to: oldFile, turn: oldID, at: oldDate.addingTimeInterval(1))
        try indexSession(oldFile, in: root)
        try FileManager.default.createDirectory(at: dayDirectory(root, at: beforeMidnight), withIntermediateDirectories: true)
        // A new year's first write has to pass through a parent directory watch.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dayDirectory(root, at: afterMidnight).path))

        func expectRunning(_ session: String, turn: String, since started: TimeInterval, scenario: String) async throws {
            // All three changes must arrive well before the collapsed metrics batch.
            func hasTurn() -> Bool {
                capture.all().last?.tasks.contains { $0.sessionID == session && $0.turnID == turn && $0.phase == "running" } == true
            }
            while !hasTurn(), ProcessInfo.processInfo.systemUptime - started < 3 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            XCTAssertTrue(hasTurn(), "\(scenario) must appear from a file notification")
            XCTAssertLessThan(elapsed, 3, "\(scenario) must bypass the collapsed metrics batch")
            if hasTurn() { print("Codex file notification, \(scenario): \(Int(elapsed * 1000)) ms") }
        }

        do {
            _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": EngineCodexSourceReport.path(root)]))
            let newID = UUID().uuidString.lowercased()
            var started = ProcessInfo.processInfo.systemUptime
            _ = try session(root, id: newID, at: beforeMidnight)
            try await expectRunning(newID, turn: newID, since: started, scenario: "new rollout")

            let resumedTurn = UUID().uuidString.lowercased()
            started = ProcessInfo.processInfo.systemUptime
            try appendTurn("task_started", to: oldFile, turn: resumedTurn, at: beforeMidnight)
            try await expectRunning(oldID, turn: resumedTurn, since: started, scenario: "indexed old rollout append")

            clock.set(afterMidnight)
            let nextDayID = UUID().uuidString.lowercased()
            started = ProcessInfo.processInfo.systemUptime
            _ = try session(root, id: nextDayID, at: afterMidnight)
            try await expectRunning(nextDayID, turn: nextDayID, since: started, scenario: "first rollout of the new year while collapsed")
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    func testCollapsedCodexBatchesMetricsButPublishesAnEndingImmediately() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-codex-batch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(), capture = LiveSnapshots()
        let runtime = EngineRuntime(demo: false, now: { date.addingTimeInterval(3) }, dismissalStore: nil, output: { capture.append($0) })
        let id = UUID().uuidString.lowercased()
        let file = try session(root, id: id, at: date)
        do {
            _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": EngineCodexSourceReport.path(root)]))
            let sequence = try XCTUnwrap(capture.all().last).sequence
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            for (seconds, tokens) in [(1.0, 20), (2.0, 50)] {
                try handle.write(contentsOf: record("event_msg", payload: ["type": "token_count", "turn_id": id,
                    "info": ["total_token_usage": ["output_tokens": tokens]]], at: date.addingTimeInterval(seconds)))
            }
            try handle.close()
            try await Task.sleep(nanoseconds: 650_000_000)
            XCTAssertEqual(capture.all().last?.sequence, sequence, "Routine metrics must wait while the panel is collapsed")

            let started = ProcessInfo.processInfo.systemUptime
            try appendTurn("task_complete", to: file, turn: id, at: date.addingTimeInterval(3))
            while capture.all().last?.tasks.first?.phase != "completed", ProcessInfo.processInfo.systemUptime - started < 3 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(capture.all().last?.tasks.first?.phase, "completed")
            XCTAssertEqual(capture.all().last?.tasks.first?.unread, true)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3, "An ending must bypass the pending metrics batch")
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
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
