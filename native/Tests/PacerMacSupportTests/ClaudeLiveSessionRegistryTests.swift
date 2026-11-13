import PacerMacSupport
import XCTest
@testable import PacerCore

final class ClaudeLiveSessionRegistryTests: XCTestCase {
    private let session = "0405a740-81c4-441b-a11d-3bca4d079aee"
    private let lstart = "Mon Oct  5 07:41:00 2026"

    func testOnlyAVerifiedLiveHolderOfTheSameSessionIsReturned() throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let started = try XCTUnwrap(ClaudeLiveSessionRegistry.startDate(lstart: lstart))
        let live: (pid_t) -> Date? = { $0 == 4242 ? started : nil }
        func holder() -> pid_t? {
            ClaudeLiveSessionRegistry.holder(for: session.uppercased(), claudeHome: home, currentProcess: 7, processStart: live)
        }
        XCTAssertNil(holder())
        try write(["pid": 4242, "sessionId": session, "kind": "sdk", "procStart": lstart, "entrypoint": "sdk-ts"], home: home, name: "4242")
        XCTAssertEqual(holder(), 4242)

        // A reused PID, an exited process or a record without its start time is not trusted.
        let later = started.addingTimeInterval(2)
        XCTAssertNil(ClaudeLiveSessionRegistry.holder(for: session, claudeHome: home, currentProcess: 7, processStart: { _ in later }))
        XCTAssertNil(ClaudeLiveSessionRegistry.holder(for: session, claudeHome: home, currentProcess: 7, processStart: { _ in nil }))
        XCTAssertNil(ClaudeLiveSessionRegistry.holder(for: session, claudeHome: home, currentProcess: 4242, processStart: live))
        for record: [String: Any] in [
            ["pid": 4242, "sessionId": session, "kind": "sdk"],
            ["pid": 4242, "sessionId": session, "procStart": lstart],
            ["pid": 4242, "sessionId": session, "kind": "", "procStart": lstart],
            ["pid": 4242, "sessionId": session, "kind": "interactive", "parkedJobId": "a1b2c3d4", "procStart": lstart],
            ["pid": 4243, "sessionId": session, "kind": "sdk", "procStart": lstart],
            ["pid": 4242, "sessionId": "e0c2a517-74bc-43ec-a806-e9187a72fcc8", "kind": "sdk", "procStart": lstart],
            ["pid": 4242, "sessionId": session + ";x", "kind": "sdk", "procStart": lstart]
        ] {
            try write(record, home: home, name: "4242")
            XCTAssertNil(holder(), "\(record)")
        }
        try write(["pid": 4242, "sessionId": session, "kind": "interactive", "procStart": lstart], home: home, name: "4242")
        XCTAssertEqual(holder(), 4242)
        XCTAssertNil(ClaudeLiveSessionRegistry.holder(for: "local_" + session, claudeHome: home, currentProcess: 7, processStart: live))
        XCTAssertNil(ClaudeLiveSessionRegistry.holder(for: session, claudeHome: URL(string: "https://example.test/.claude")!,
            currentProcess: 7, processStart: live))
    }

    func testOneScanMapsEveryVerifiedHolderByLowercaseSession() throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let started = try XCTUnwrap(ClaudeLiveSessionRegistry.startDate(lstart: lstart))
        let other = "e0c2a517-74bc-43ec-a806-e9187a72fcc8"
        try write(["pid": 4242, "sessionId": session.uppercased(), "kind": "sdk", "procStart": lstart], home: home, name: "4242")
        try write(["pid": 4343, "sessionId": other, "kind": "interactive", "procStart": lstart], home: home, name: "4343")
        try write(["pid": 4444, "sessionId": other, "kind": "interactive", "procStart": lstart], home: home, name: "4444")
        try write(["pid": 4545, "sessionId": "e0c2a517-74bc-43ec-a806-e9187a72fcc9", "kind": "sdk", "procStart": lstart], home: home, name: "4545")
        let live: (pid_t) -> Date? = { $0 == 4545 ? nil : started }
        XCTAssertEqual(ClaudeLiveSessionRegistry.holders(claudeHome: home, currentProcess: 7, processStart: live),
                       [session: 4242, other: 4343])
        XCTAssertEqual(ClaudeLiveSessionRegistry.holders(claudeHome: URL(string: "https://example.test/.claude")!,
                       currentProcess: 7, processStart: live), [:])
    }

    func testRequestedSessionChoosesNewerLiveHolderDuringResume() throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let started = try XCTUnwrap(ClaudeLiveSessionRegistry.startDate(lstart: lstart))
        let other = "e0c2a517-74bc-43ec-a806-e9187a72fcc8"
        for (pid, id) in [(4242, session), (4343, other), (4444, session), (4545, session)] {
            try write(["pid": pid, "sessionId": id, "kind": "sdk", "procStart": lstart], home: home, name: String(pid))
        }
        var checked: [pid_t] = []
        let holders = ClaudeLiveSessionRegistry.holders(sessions: [session.uppercased()], claudeHome: home,
            currentProcess: 7, processStart: { pid in
                checked.append(pid)
                switch pid {
                case 4444: return started.addingTimeInterval(0.75)
                case 4545: return started.addingTimeInterval(2)
                default: return started
                }
            })
        XCTAssertEqual(checked, [4242, 4444, 4545])
        XCTAssertEqual(holders, [session: 4444])
    }

    func testRegistryFileShapeIsCheckedBeforeDecoding() throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let started = try XCTUnwrap(ClaudeLiveSessionRegistry.startDate(lstart: lstart))
        let record: [String: Any] = ["pid": 4242, "sessionId": session, "kind": "sdk", "procStart": lstart]
        func holder() -> pid_t? {
            ClaudeLiveSessionRegistry.holder(for: session, claudeHome: home, currentProcess: 7, processStart: { _ in started })
        }
        try write(record, home: home, name: "04242")
        try write(record, home: home, name: "4242.backup")
        XCTAssertNil(holder())
        let sessions = home.appendingPathComponent("sessions")
        let target = sessions.appendingPathComponent("target.data")
        try JSONSerialization.data(withJSONObject: record).write(to: target)
        try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent("4242.json"), withDestinationURL: target)
        XCTAssertNil(holder())
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("4242.json"))
        var padded = try JSONSerialization.data(withJSONObject: record)
        padded.insert(contentsOf: Data(repeating: 0x20, count: 64 * 1024), at: 0)
        try padded.write(to: sessions.appendingPathComponent("4242.json"))
        XCTAssertNil(holder())
        try Data("{".utf8).write(to: sessions.appendingPathComponent("4242.json"))
        XCTAssertNil(holder())
    }

    func testRecordedStartMatchesTheLiveProcessAsTheCliWritesIt() throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        // Claude Code records `ps -o lstart=` with LC_ALL=C and TZ=UTC.
        let ps = Process(), output = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps"); ps.arguments = ["-o", "lstart=", "-p", String(child.processIdentifier)]
        ps.environment = ["LC_ALL": "C", "TZ": "UTC"]; ps.standardOutput = output; ps.standardError = FileHandle.nullDevice
        try ps.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); ps.waitUntilExit()
        let recorded = try XCTUnwrap(String(data: data, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        try write(["pid": child.processIdentifier, "sessionId": session, "kind": "sdk", "procStart": recorded],
                  home: home, name: String(child.processIdentifier))
        XCTAssertEqual(ClaudeLiveSessionRegistry.holder(for: session, claudeHome: home), child.processIdentifier)
        XCTAssertEqual(ProcessOwnership.parentProcess(child.processIdentifier), getpid())
        // launchd is root-owned, as is the `login` above Terminal and iTerm shells.
        XCTAssertEqual(ProcessOwnership.parentProcess(1), 0)
        XCTAssertNotNil(ClaudeLiveSessionRegistry.processStartDate(1))
        child.terminate(); child.waitUntilExit()
        XCTAssertNil(ClaudeLiveSessionRegistry.holder(for: session, claudeHome: home))
    }

    private func write(_ record: [String: Any], home: URL, name: String) throws {
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: record).write(to: sessions.appendingPathComponent(name + ".json"))
    }

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/pacer-live-registry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
