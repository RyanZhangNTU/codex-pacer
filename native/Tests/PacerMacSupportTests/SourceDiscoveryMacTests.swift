import XCTest
import SQLite3
@testable import PacerCore

final class SourceDiscoveryMacTests: XCTestCase {


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
}
