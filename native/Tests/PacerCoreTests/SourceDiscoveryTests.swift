import XCTest
import SQLite3
@testable import PacerCore

final class SourceDiscoveryTests: XCTestCase {
    private func temp() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }
    private func database(home: URL, rollout: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads (rollout_path TEXT, archived INTEGER, recency_at_ms INTEGER, thread_source TEXT, model TEXT)", nil, nil, nil), SQLITE_OK)
        let path = rollout.path.replacingOccurrences(of: "'", with: "''")
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO threads VALUES ('\(path)',0,123,'user','gpt-test')", nil, nil, nil), SQLITE_OK)
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
        XCTAssertTrue(result.watchURLs.contains { $0.standardizedFileURL.path == day.standardizedFileURL.path })
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
    func testRemoteProbeFindsResumedTaskAndNeverTransmitsConversationContent() throws {
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
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments = ["-u","-c",RemoteProbe.script,Data(home.path.utf8).base64EncodedString(),"once"]
        process.standardOutput=output; process.standardError=FileHandle.nullDevice
        try process.run()
        let bytes=output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0)
        let text=String(decoding:bytes,as:UTF8.self)
        XCTAssertFalse(text.contains("private")); XCTAssertFalse(text.contains("input_tokens"))
        XCTAssertTrue(text.contains("output_tokens"))
        let frame=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        let sessions=try XCTUnwrap(frame["sessions"] as? [[String:Any]])
        XCTAssertEqual(sessions.count,1)
        var activity=SessionActivity(id:"remote:resumed.jsonl",sourceHost:"one")
        for item in try XCTUnwrap(sessions.first?["records"] as? [[String:Any]]) { activity.consume(try JSONSerialization.data(withJSONObject:item)) }
        XCTAssertEqual(activity.phase,.running)
        XCTAssertEqual(activity.sourceHost,"one")
    }
    func testRetainedEstimateDoesNotDisappearButNeverPretendsToBeFresh() {
        let start=Date(timeIntervalSince1970:1000000)
        var rate=OutputRate()
        rate.observe(totalOutput:100,at:start); rate.observe(totalOutput:120,at:start.addingTimeInterval(2))
        let estimate=rate.estimate(at:start.addingTimeInterval(60))
        XCTAssertEqual(estimate?.value,10)
        XCTAssertFalse(estimate!.isFresh)
        XCTAssertNil(rate.tokensPerSecond(at:start.addingTimeInterval(60)))
        rate.startTurn(at:start.addingTimeInterval(100))
        XCTAssertNil(rate.estimate(at:start.addingTimeInterval(100)))
        rate.observe(totalOutput:140,at:start.addingTimeInterval(102))
        XCTAssertEqual(rate.estimate(at:start.addingTimeInterval(102))?.value,10)
        rate.finishTurn(); XCTAssertNil(rate.estimate(at:start.addingTimeInterval(103)))
    }
    func testLocalAndSshRetainedRatesAreAggregatedWithoutSelection() throws {
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
}
