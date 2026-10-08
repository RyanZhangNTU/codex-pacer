import XCTest
import SQLite3
@testable import PacerCore

final class SourceDiscoveryTests: XCTestCase {
    func testCoveredCursorsDoNotSpendNewLogDiscoverySlots() async throws {
        let home = try temp(); defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(), formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let day = home.appendingPathComponent("sessions/" + formatter.string(from: now))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let ids = (0..<16).map { _ in UUID().uuidString.lowercased() }
        func write(_ id: String, at date: Date) throws {
            let file = day.appendingPathComponent("rollout-" + id + ".jsonl")
            try record("event_msg", payload: ["type": "task_started", "turn_id": id], at: date).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        for id in ids { try write(id, at: now) }
        let reader = LocalActivityReader()
        let initial = await reader.read(home: home, now: now)
        XCTAssertEqual(initial.activities.count, 16)
        let new = UUID().uuidString.lowercased(); try write(new, at: now.addingTimeInterval(1))
        let result = await reader.read(home: home, now: now.addingTimeInterval(2), excludingThreads: Set(ids))
        XCTAssertTrue(result.activities.contains { $0.threadID == new })
        XCTAssertTrue(result.activities.contains { $0.threadID == ids[0] })
    }

    func testRemovedRunningLogBecomesUnconfirmedAndFreesItsCursor() async throws {
        let home = try temp(); defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(), formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let day = home.appendingPathComponent("sessions/" + formatter.string(from: now))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-" + UUID().uuidString + ".jsonl")
        try record("event_msg", payload: ["type": "task_started", "turn_id": "turn"], at: now).write(to: file)
        let reader = LocalActivityReader()
        let first = await reader.read(home: home, now: now)
        XCTAssertEqual(first.activities.first?.phase, .running)
        try FileManager.default.removeItem(at: file)
        let lost = await reader.read(home: home, now: now.addingTimeInterval(3600))
        XCTAssertEqual(lost.activities.first?.phase, .unknown)
        let next = await reader.read(home: home, now: now.addingTimeInterval(3601))
        XCTAssertTrue(next.activities.isEmpty)
    }
    private func temp() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }
    private func database(home: URL, rollout: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads (rollout_path TEXT, archived INTEGER, recency_at_ms INTEGER, thread_source TEXT, model TEXT, title TEXT)", nil, nil, nil), SQLITE_OK)
        let path = rollout.path.replacingOccurrences(of: "'", with: "''")
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO threads VALUES ('\(path)',0,123,'user','gpt-test','Resumed analysis')", nil, nil, nil), SQLITE_OK)
    }
    private func record(_ type: String, payload: [String: Any], at date: Date) throws -> Data {
        let f = ISO8601DateFormatter()
        return try JSONSerialization.data(withJSONObject: ["timestamp":f.string(from: date),"type":type,"payload":payload]) + Data([10])
    }
    func testOldDateResumedSessionIsFoundThroughReadOnlyIndex() async throws {
        let home = try temp(); defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent("sessions/2025/01/01")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("resumed.jsonl")
        let now = Date()
        try record("event_msg", payload: ["type":"task_started","turn_id":"resumed"], at: now).write(to: file)
        try database(home: home, rollout: file)
        let result = await LocalActivityReader().read(home: home, now: now)
        XCTAssertEqual(result.activities.first?.phase, .running)
        XCTAssertEqual(result.activities.first?.title, "Resumed analysis")
        XCTAssertTrue(result.watchURLs.contains { $0.standardizedFileURL.path == day.standardizedFileURL.path })
    }
    func testAssignedConversationNameTakesPrecedenceOverOriginalPromptTitle() async throws {
        let home = try temp(); defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent("sessions/2025/01/01")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("named.jsonl")
        let now = Date()
        try record("event_msg", payload: ["type":"task_started","turn_id":"named"], at: now).write(to: file)
        try database(home: home, rollout: file)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE threads ADD COLUMN name TEXT", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE threads SET name='Assigned conversation'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let result = await LocalActivityReader().read(home: home, now: now)
        XCTAssertEqual(result.activities.first?.title, "Assigned conversation")
    }
    func testIndexCannotReadPathsOutsideSelectedCodexHome() throws {
        let home = try temp(); defer { try? FileManager.default.removeItem(at: home) }
        let outside = home.appendingPathComponent("private.jsonl")
        try Data().write(to: outside)
        try database(home: home, rollout: outside)
        XCTAssertTrue(SessionIndex.files(home: home).isEmpty)
    }
    func testRemoteDiscoveryOnlyUsesEnabledConfiguredSafeSshAliases() throws {
        let home = try temp(); defer { try? FileManager.default.removeItem(at: home) }
        let state: [String:Any] = [
            "codex-managed-remote-connections":[
                ["hostId":"remote-ssh-discovered:one","displayName":"one","source":"discovered","alias":"one"],
                ["hostId":"remote-ssh-discovered:unsafe","displayName":"unsafe","source":"discovered","alias":"-oProxyCommand=bad"],
                ["hostId":"remote-ssh-discovered:off","displayName":"off","source":"discovered","alias":"off"]],
            "remote-connection-auto-connect-by-host-id":["remote-ssh-discovered:one":true,"remote-ssh-discovered:unsafe":true,"remote-ssh-discovered:off":false]]
        try JSONSerialization.data(withJSONObject:state).write(to:home.appendingPathComponent(".codex-global-state.json"))
        XCTAssertEqual(RemoteActivityTarget.configured(home:home).map(\.alias), ["one"])
    }
    func testRealtimeFallbackFindsResumedTaskAndNeverTransmitsConversationContent() throws {
        let home = try temp(); defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent("sessions/2025/01/01")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("resumed.jsonl")
        let now = Date()
        let rows: [(String,[String:Any])] = [
            ("session_meta",["cwd":"/work/test","thread_source":"user","base_instructions":"private instruction"]),
            ("event_msg",["type":"task_started","turn_id":"resumed"]),
            ("response_item",["type":"message","role":"user","content":"private prompt"]),
            ("response_item",["type":"reasoning","text":"private thought"]),
            ("event_msg",["type":"token_count","info":["total_token_usage":["output_tokens":123,"input_tokens":987]]])]
        var data = Data()
        for (type,payload) in rows { data += try record(type,payload:payload,at:now) }
        try data.write(to:file); try database(home:home,rollout:file)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE threads SET title='" + String(repeating: "x", count: 1000) + "'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments = ["-u","-c",RealtimeProbe.script,Data(home.path.utf8).base64EncodedString(),"once"]
        process.standardOutput=output; process.standardError=FileHandle.nullDevice
        try process.run()
        let bytes=output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0)
        let text=String(decoding:bytes,as:UTF8.self)
        XCTAssertFalse(text.contains("private")); XCTAssertFalse(text.contains("input_tokens"))
        XCTAssertTrue(text.contains("output_tokens"))
        let frames = try bytes.split(separator: 10).compactMap { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        let frame = try XCTUnwrap(frames.first { $0["sessions"] != nil })
        let sessions=try XCTUnwrap(frame["sessions"] as? [[String:Any]])
        XCTAssertEqual(sessions.count,1)
        XCTAssertEqual((sessions.first?["title"] as? String)?.count, 240)
        var activity=SessionActivity(id:"remote:resumed.jsonl",sourceHost:"one")
        for item in try XCTUnwrap(sessions.first?["records"] as? [[String:Any]]) { activity.consume(try JSONSerialization.data(withJSONObject:item)) }
        XCTAssertEqual(activity.phase,.running)
        XCTAssertEqual(activity.sourceHost,"one")
    }
    func testLocalAndSshFreshRatesAggregateAndOldRatesRemainMarkedWithoutSelection() throws {
        let start = Date(timeIntervalSince1970: 1000000)
        var local = SessionActivity(id: "local")
        var ssh = SessionActivity(id: "ssh", sourceHost: "one")
        for (seconds, count) in [(0.0, 100), (2.0, 120)] {
            if seconds == 0 {
                local.consume(try record("event_msg", payload: ["type":"task_started","turn_id":"local"], at: start))
                ssh.consume(try record("event_msg", payload: ["type":"task_started","turn_id":"ssh"], at: start))
            }
            local.consume(try record("event_msg", payload: ["type":"token_count","info":["total_token_usage":["output_tokens":count]]], at:start.addingTimeInterval(seconds)))
            ssh.consume(try record("event_msg", payload: ["type":"token_count","info":["total_token_usage":["output_tokens":count * 2]]], at:start.addingTimeInterval(seconds)))
        }
        let fresh = ActivityOverview(activities: [local, ssh], at: start.addingTimeInterval(3))
        XCTAssertEqual(fresh.displayedRate, 30)
        XCTAssertTrue(fresh.rateIsFresh)
        let overview = ActivityOverview(activities: [local, ssh], at:start.addingTimeInterval(60))
        XCTAssertEqual(overview.running.count, 2)
        XCTAssertEqual(overview.displayedRate, 30)
        XCTAssertFalse(overview.rateIsFresh)
        XCTAssertNil(overview.tokensPerSecond)
    }
    func testStaleStartupLogsCannotInventRunningTasks() async throws {
        let home=try temp(); defer { try? FileManager.default.removeItem(at:home) }
        let day=home.appendingPathComponent("sessions/2025/01/01")
        try FileManager.default.createDirectory(at:day,withIntermediateDirectories:true)
        let file=day.appendingPathComponent("old.jsonl")
        let now=Date()
        try record("event_msg",payload:["type":"task_started","turn_id":"old"],at:now.addingTimeInterval(-3600)).write(to:file)
        try database(home:home,rollout:file)
        let result=await LocalActivityReader().read(home:home,now:now)
        XCTAssertEqual(result.activities.first?.phase,.unknown)
    }
    func testExperimentalTailKeepsCompleteRecentSamplesAfterPartialStartup() async throws {
        let home = try temp(); defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(), day = home.appendingPathComponent("sessions/2025/01/01")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rate.jsonl")
        var bytes = try record("event_msg", payload: ["type":"task_started","turn_id":"rate"], at:now.addingTimeInterval(-20))
        bytes += try record("response_item", payload: ["type":"message","role":"user","content":String(repeating:"padding",count:110000)], at:now.addingTimeInterval(-19))
        for (seconds, count) in [(-10.0, 100), (-5.0, 200)] {
            bytes += try record("event_msg", payload:["type":"token_count","info":["total_token_usage":["output_tokens":count]]], at:now.addingTimeInterval(seconds))
        }
        try bytes.write(to: file); try database(home: home, rollout: file)
        let result = await LocalActivityReader().read(home: home, now: now, phaseAwareRate: true)
        XCTAssertEqual(result.activities.first?.outputEstimate(at: now)?.value, 20)
    }
}
