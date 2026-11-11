#if canImport(PacerMacSupport)
import PacerMacSupport
#else
@testable import PacerEngineSupport
#endif
import XCTest
@testable import PacerCore

final class ClaudeActivityDirectoryWatchTests: XCTestCase {
    private let rootSession = "aaaaaaaa-1111-4111-8111-111111111111"
    private let otherSession = "bbbbbbbb-2222-4222-8222-222222222222"
    private let newSession = "cccccccc-3333-4333-8333-333333333333"

    private func fixture() throws -> (home: URL, alpha: URL, beta: URL, sessionDirectory: URL) {
        #if canImport(PacerMacSupport)
        let base = URL(fileURLWithPath: "/private/tmp")
        #else
        let base = FileManager.default.temporaryDirectory
        #endif
        let home = base.appendingPathComponent("pacer-claude-directory-" + UUID().uuidString)
        let alpha = home.appendingPathComponent("projects/alpha"), beta = home.appendingPathComponent("projects/beta")
        let sessionDirectory = alpha.appendingPathComponent(rootSession)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        for (directory, session) in [(alpha, rootSession), (beta, otherSession)] {
            let file = directory.appendingPathComponent(session + ".jsonl")
            try ClaudeActivityRecord.encode(["type": "custom-title", "sessionId": session, "customTitle": "Synthetic fixture"])!.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(session == rootSession ? 10 : 0)], ofItemAtPath: file.path)
        }
        return (home, alpha, beta, sessionDirectory)
    }

    func testOrdinaryReadsKeepDiscoveredProjectAndNearestSubagentParentWatchesWithoutRescanning() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        var reader = ClaudeActivityReader(files: TestFileSystem())
        let first = reader.read(home: fixture.home, discover: true)
        let next = reader.read(home: fixture.home, discover: false)
        let inventory = Set(first.watchURLs.map(\.path))
        XCTAssertEqual(Set(next.watchURLs.map(\.path)), inventory)
        for required in [fixture.alpha, fixture.beta, fixture.sessionDirectory] { XCTAssertTrue(inventory.contains(required.path)) }
        XCTAssertEqual(reader.scans, 1); XCTAssertEqual(reader.fileReads, 2)
        XCTAssertLessThanOrEqual(first.watchURLs.count, 32 + ClaudeActivityReader.maximumDirectoryWatches)
        let subagents = fixture.sessionDirectory.appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let discovered = reader.read(home: fixture.home, discover: true)
        XCTAssertTrue(discovered.watchURLs.map(\.path).contains(subagents.path))
        let again = reader.read(home: fixture.home, discover: false)
        XCTAssertEqual(Set(discovered.watchURLs.map(\.path)), Set(again.watchURLs.map(\.path)))
        XCTAssertEqual(reader.scans, 2); XCTAssertEqual(reader.fileReads, 2)
        reader.reset()
        XCTAssertTrue(reader.read(home: fixture.home, discover: false).watchURLs.isEmpty)
    }

    func testLargeProjectSelectsNewestLogsBeyondOldDirectoryEntryLimits() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        let subagents = fixture.sessionDirectory.appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let now = Date(), old = now.addingTimeInterval(-3600)
        func write(_ url: URL, at modified: Date) throws {
            try Data().write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        for index in 0..<280 { try write(fixture.alpha.appendingPathComponent("old-\(index).jsonl"), at: old) }
        for index in 0..<70 { try write(subagents.appendingPathComponent("agent-old-\(index).jsonl"), at: old) }
        let newLog = fixture.alpha.appendingPathComponent("zzz-new-session.jsonl")
        let newAgent = subagents.appendingPathComponent("agent-zzz-new-agent.jsonl")
        try write(newLog, at: now)
        try write(newAgent, at: now)
        try write(fixture.alpha.appendingPathComponent(rootSession + ".jsonl"), at: old)

        var reader = ClaudeActivityReader(files: TestFileSystem())
        _ = reader.read(home: fixture.home, discover: true, now: now)
        XCTAssertEqual(reader.attachedTranscriptCount, 32)
        XCTAssertEqual(reader.transcriptURL(for: "zzz-new-session")?.path, newLog.path)
        XCTAssertEqual(reader.transcriptURL(for: "zzz-new-agent")?.path, newAgent.path)
    }

    func testPeriodicDiscoveryKeepsMinuteFallbackWithoutAProjectWatch() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        let start = Date()
        var reader = ClaudeActivityReader(files: TestFileSystem())
        _ = reader.read(home: fixture.home, discover: true, now: start)
        XCTAssertNotNil(reader.projectWatchURL)
        XCTAssertFalse(reader.discoveryDue(at: start.addingTimeInterval(59), watchingProjects: false))
        XCTAssertTrue(reader.discoveryDue(at: start.addingTimeInterval(60), watchingProjects: false))
        XCTAssertFalse(reader.discoveryDue(at: start.addingTimeInterval(299), watchingProjects: true))
        XCTAssertTrue(reader.discoveryDue(at: start.addingTimeInterval(300), watchingProjects: true))

        let directoryEvent = start.addingTimeInterval(120)
        _ = reader.read(home: fixture.home, discover: true, now: directoryEvent)
        XCTAssertEqual(reader.scans, 2)
        XCTAssertFalse(reader.discoveryDue(at: start.addingTimeInterval(300), watchingProjects: true))
        XCTAssertTrue(reader.discoveryDue(at: directoryEvent.addingTimeInterval(300), watchingProjects: true))
    }

    func testPeriodicDiscoveryChecksTrackedProjectDatesWithoutScanningTheirContents() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        let start = Date()
        let manager = FileManager.default
        let unwatched = fixture.home.appendingPathComponent("projects/unwatched")
        try manager.createDirectory(at: unwatched, withIntermediateDirectories: true)
        try manager.setAttributes([.modificationDate: start.addingTimeInterval(-3600)], ofItemAtPath: unwatched.path)
        var reader = ClaudeActivityReader(files: TestFileSystem())
        let first = reader.read(home: fixture.home, discover: true, now: start)
        XCTAssertNotNil(reader.projectWatchURL)
        XCTAssertFalse(first.watchURLs.map(\.path).contains(unwatched.path))
        XCTAssertFalse(reader.discoveryDue(at: start.addingTimeInterval(60), watchingProjects: true))

        let log = unwatched.appendingPathComponent(newSession + ".jsonl")
        try Data().write(to: log)
        try manager.setAttributes([.modificationDate: start.addingTimeInterval(1)], ofItemAtPath: unwatched.path)
        XCTAssertTrue(reader.discoveryDue(at: start.addingTimeInterval(60), watchingProjects: true))
        XCTAssertEqual(reader.scans, 1)
        _ = reader.read(home: fixture.home, discover: true, now: start.addingTimeInterval(60))
        XCTAssertEqual(reader.transcriptURL(for: newSession)?.path, log.path)
        XCTAssertFalse(reader.discoveryDue(at: start.addingTimeInterval(120), watchingProjects: true))
    }

    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var delivered: Set<String> = []
        func observe(_ values: [SessionActivity], main: String, parent: String, mainReady: XCTestExpectation, childReady: XCTestExpectation) {
            lock.lock(); defer { lock.unlock() }
            if values.contains(where: { $0.threadID == main && $0.phase == .running }), delivered.insert("main").inserted { mainReady.fulfill() }
            if values.contains(where: { $0.threadID == "fixture-child" && $0.parentThreadID == parent && $0.phase == .running }), delivered.insert("child").inserted { childReady.fulfill() }
        }
    }

    func testExistingVnodeWatchesPublishNewMainAndNestedChildWithoutPeriodicDiscovery() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        let monitor = ClaudeActivityMonitor(), observations = Observations()
        let mainReady = expectation(description: "new main log in another selected project was discovered")
        let childReady = expectation(description: "new nested child log was discovered through its existing parent")
        let main = newSession, parent = rootSession
        await monitor.start(home: fixture.home, refreshPolicy: .collapsed) { values, _, _, _ in
            observations.observe(values, main: main, parent: parent, mainReady: mainReady, childReady: childReady)
        }
        // Queue synchronization proves the real vnode registrations are in
        // place; this is not a sleep that guesses when startup finished.
        let watches = await monitor.localWatchCount()
        XCTAssertGreaterThan(watches, 6, "Selected directory coverage must survive the old four-directory cap")
        XCTAssertLessThanOrEqual(watches, 32 + ClaudeActivityReader.maximumDirectoryWatches)
        func prompt(session: String, id: String) -> Data {
            ClaudeActivityRecord.encode(["type": "user", "sessionId": session, "promptId": id, "uuid": "user-" + id,
                "timestamp": ISO8601DateFormatter().string(from: Date()), "message": ["content": "synthetic"]])! + Data([10])
        }
        let mainStarted = Date()
        try prompt(session: newSession, id: "fixture-main-turn").write(to: fixture.beta.appendingPathComponent(newSession + ".jsonl"))
        await fulfillment(of: [mainReady], timeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(mainStarted), 2, "New sources cannot wait for the 60-second maintenance scan")
        _ = await monitor.localWatchCount()
        let childStarted = Date(), subagents = fixture.sessionDirectory.appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try prompt(session: rootSession, id: "fixture-child-turn").write(to: subagents.appendingPathComponent("agent-fixture-child.jsonl"))
        await fulfillment(of: [childReady], timeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(childStarted), 2)
        let finalWatches = await monitor.localWatchCount()
        XCTAssertLessThanOrEqual(finalWatches, 32 + ClaudeActivityReader.maximumDirectoryWatches)
        await monitor.shutdown()
    }


}
