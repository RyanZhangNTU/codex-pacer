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

    func testLargeInventoryResumesWithinItsStepBudgetAndKeepsLiveLogs() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        let subagents = fixture.sessionDirectory.appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let now = Date(), old = now.addingTimeInterval(-3600)
        func write(_ url: URL, at modified: Date) throws {
            try Data().write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        let oldRoot = fixture.alpha.appendingPathComponent(rootSession + ".jsonl")
        try write(oldRoot, at: old.addingTimeInterval(-100))
        var reader = ClaudeActivityReader(files: TestFileSystem())
        _ = reader.read(home: fixture.home, discover: true, now: now)
        XCTAssertEqual(reader.transcriptURL(for: rootSession)?.path, oldRoot.path)
        for index in 0..<(ClaudeActivityReader.discoveryStepLimit + 32) {
            try write(fixture.alpha.appendingPathComponent("old-\(index).jsonl"), at: old)
            try write(subagents.appendingPathComponent("agent-old-\(index).jsonl"), at: old)
        }
        for index in 0..<40 { try write(fixture.alpha.appendingPathComponent(".hidden-\(index).jsonl"), at: now) }
        let newLog = fixture.alpha.appendingPathComponent("zzz-new-session.jsonl")
        let newAgent = subagents.appendingPathComponent("agent-zzz-new-agent.jsonl")
        try write(newLog, at: now)
        try write(newAgent, at: now)
        let first = reader.read(home: fixture.home, discover: true, retainingSessionIDs: [rootSession], now: now)
        XCTAssertTrue(first.discoveryPending)
        XCTAssertTrue(first.caughtUp, "An unfinished inventory does not hold back existing transcript updates")
        XCTAssertEqual(reader.lastDiscoverySteps, ClaudeActivityReader.discoveryStepLimit)
        XCTAssertEqual(reader.transcriptURL(for: rootSession)?.path, oldRoot.path)
        // A watch notification queues one follow-up instead of restarting the active scan.
        var next = reader.read(home: fixture.home, discover: true, retainingSessionIDs: [rootSession], now: now)
        XCTAssertEqual(reader.scans, 2)
        for _ in 0..<16 where next.discoveryPending {
            next = reader.read(home: fixture.home, discover: false, retainingSessionIDs: [rootSession], now: now)
            XCTAssertLessThanOrEqual(reader.lastDiscoverySteps, ClaudeActivityReader.discoveryStepLimit)
            XCTAssertEqual(reader.transcriptURL(for: rootSession)?.path, oldRoot.path)
        }
        XCTAssertFalse(next.discoveryPending)
        XCTAssertEqual(reader.scans, 3)
        XCTAssertEqual(reader.attachedTranscriptCount, 32)
        XCTAssertEqual(reader.transcriptURL(for: "zzz-new-session")?.path, newLog.path)
        XCTAssertEqual(reader.transcriptURL(for: "zzz-new-agent")?.path, newAgent.path)
    }

    func testFirstInventoryRetriesWhenAnUnwatchedProjectChangesAfterItWasRead() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        let start = Date()
        let manager = FileManager.default
        for index in 0..<ClaudeActivityReader.discoveryStepLimit {
            try Data().write(to: fixture.beta.appendingPathComponent("older-\(index).jsonl"))
        }
        try manager.setAttributes([.modificationDate: start.addingTimeInterval(10)], ofItemAtPath: fixture.alpha.path)
        var reader = ClaudeActivityReader(files: TestFileSystem())
        let first = reader.read(home: fixture.home, discover: true, now: start)
        XCTAssertTrue(first.discoveryPending)
        XCTAssertFalse(first.watchURLs.map(\.path).contains(fixture.alpha.path))

        let log = fixture.alpha.appendingPathComponent(newSession + ".jsonl")
        try Data().write(to: log)
        try manager.setAttributes([.modificationDate: start.addingTimeInterval(30)], ofItemAtPath: log.path)
        try manager.setAttributes([.modificationDate: start.addingTimeInterval(20)], ofItemAtPath: fixture.alpha.path)
        let completedFirst = reader.read(home: fixture.home, discover: false, now: start)
        XCTAssertEqual(reader.scans, 1)
        XCTAssertNil(reader.transcriptURL(for: newSession))
        XCTAssertTrue(completedFirst.discoveryPending, "A creation before watch registration must queue a prompt retry")
        var next = completedFirst
        for _ in 0..<8 where next.discoveryPending { next = reader.read(home: fixture.home, discover: false, now: start) }
        XCTAssertFalse(next.discoveryPending)
        XCTAssertEqual(reader.scans, 2)
        XCTAssertEqual(reader.transcriptURL(for: newSession)?.path, log.path)
    }

    func testExistingLogEndingAfterFirstInventorySliceIsUnread() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), manager = FileManager.default
        let endingDate = start.addingTimeInterval(1), promptDate = start.addingTimeInterval(-10)
        func row(_ session: String, end: Bool, at time: Date) throws -> Data {
            var value: [String: Any] = ["type": end ? "system" : "user", "sessionId": session,
                "uuid": end ? "end" : "owned-before", "timestamp": ISO8601DateFormatter().string(from: time)]
            if end {
                value.merge(["parentUuid": "owned-before", "subtype": "stop_hook_summary", "preventedContinuation": false,
                             "hookErrors": [String](), "hookAdditionalContext": [String]()]) { _, new in new }
            } else {
                value.merge(["origin": ["kind": "human"], "message": ["role": "user", "content": "synthetic"]]) { _, new in new }
            }
            return try JSONSerialization.data(withJSONObject: value) + Data([10])
        }
        for index in 0..<ClaudeActivityReader.discoveryStepLimit {
            try Data().write(to: fixture.beta.appendingPathComponent("older-\(index).jsonl"))
        }
        let existing = fixture.alpha.appendingPathComponent(rootSession + ".jsonl")
        let control = fixture.alpha.appendingPathComponent(otherSession + ".jsonl")
        try row(rootSession, end: false, at: promptDate).write(to: existing)
        try (row(otherSession, end: false, at: promptDate) + row(otherSession, end: true, at: start)).write(to: control)
        for log in [existing, control] {
            try manager.setAttributes([.modificationDate: start.addingTimeInterval(20)], ofItemAtPath: log.path)
        }
        try manager.setAttributes([.modificationDate: start.addingTimeInterval(30)], ofItemAtPath: fixture.alpha.path)
        var reader = ClaudeActivityReader(files: TestFileSystem()), state = ClaudeActivityState()
        var result = reader.read(home: fixture.home, discover: true, now: start)
        XCTAssertTrue(result.discoveryPending)
        XCTAssertNil(reader.transcriptURL(for: rootSession))
        let directoryBefore = try manager.attributesOfItem(atPath: fixture.alpha.path)[.modificationDate] as? Date
        let writer = try FileHandle(forWritingTo: existing)
        try writer.seekToEnd(); try writer.write(contentsOf: row(rootSession, end: true, at: endingDate)); try writer.close()
        // This append does not create a directory entry or request a rescan.
        XCTAssertEqual(try manager.attributesOfItem(atPath: fixture.alpha.path)[.modificationDate] as? Date, directoryBefore)
        // Keep the changed file at the top even when its content timestamp
        // was captured before the synthetic flood was written.
        try manager.setAttributes([.modificationDate: start.addingTimeInterval(20)], ofItemAtPath: existing.path)
        for _ in 0..<8 where result.discoveryPending || !result.caughtUp {
            result = reader.read(home: fixture.home, discover: false, now: endingDate)
            for bytes in result.records { state.consume(bytes, now: endingDate) }
            if result.caughtUp { state.finalizeHistoricalBaseline(now: endingDate) }
        }
        XCTAssertFalse(result.discoveryPending)
        let live = try XCTUnwrap(state.activities.first { $0.threadID == rootSession })
        let historical = try XCTUnwrap(state.activities.first { $0.threadID == otherSession })
        XCTAssertEqual(live.phase, .completed)
        XCTAssertEqual(live.turnStartedAt, promptDate)
        XCTAssertFalse(live.isHistoricalCompletion)
        XCTAssertTrue(historical.isHistoricalCompletion)
        var inbox = CompletionInbox()
        _ = inbox.observe(state.activities, at: endingDate, retention: 1_800)
        XCTAssertEqual(inbox.unreadActivities.compactMap(\.threadID), [rootSession])
    }

    func testAbandonedLiveCursorsYieldToNewerLogsWithoutInventingAnEnding() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), manager = FileManager.default
        let sessions = (0..<ClaudeActivityReader.maximumFileWatches).map { "lease-\($0)" }
        var reader = ClaudeActivityReader(files: TestFileSystem()), state = ClaudeActivityState()
        func event(_ kind: String, _ session: String, _ turn: String, at date: Date) {
            state.consume(ClaudeActivityRecord.encode(["kind": kind, "origin": kind == "prompt" ? "hook" : "transcript", "sessionId": session,
                "promptId": turn, "at": date.timeIntervalSince1970])!, now: date)
        }
        for session in sessions {
            let log = fixture.alpha.appendingPathComponent(session + ".jsonl")
            try Data().write(to: log)
            try manager.setAttributes([.modificationDate: start.addingTimeInterval(20)], ofItemAtPath: log.path)
            event("prompt", session, "owned-turn", at: start)
        }
        _ = reader.read(home: fixture.home, discover: true, retainingSessionIDs: state.prioritySessionIDs(at: start), now: start)
        XCTAssertTrue(sessions.allSatisfy { reader.transcriptURL(for: $0) != nil })
        let newLog = fixture.alpha.appendingPathComponent(newSession + ".jsonl")
        try Data().write(to: newLog)
        try manager.setAttributes([.modificationDate: start.addingTimeInterval(21)], ofItemAtPath: newLog.path)

        let beforeExpiry = start.addingTimeInterval(899)
        _ = reader.read(home: fixture.home, discover: true, retainingSessionIDs: state.prioritySessionIDs(at: beforeExpiry), now: beforeExpiry)
        XCTAssertNil(reader.transcriptURL(for: newSession))
        let afterExpiry = start.addingTimeInterval(900)
        XCTAssertTrue(state.activities.allSatisfy { $0.phase == .running }, "Aging a priority does not change task state")
        let oldest = fixture.alpha.appendingPathComponent(sessions[0] + ".jsonl")
        try Data("{}\n".utf8).write(to: oldest)
        try manager.setAttributes([.modificationDate: start.addingTimeInterval(20)], ofItemAtPath: oldest.path)
        let reads = reader.fileReads
        let draining = reader.read(home: fixture.home, discover: true, retainingSessionIDs: state.prioritySessionIDs(at: afterExpiry), now: afterExpiry)
        XCTAssertTrue(draining.discoveryPending, "A displaced cursor must first read its pending bytes")
        XCTAssertEqual(reader.fileReads, reads + 1)
        XCTAssertNil(reader.transcriptURL(for: newSession))
        let scans = reader.scans
        let updated = reader.read(home: fixture.home, discover: false, retainingSessionIDs: state.prioritySessionIDs(at: afterExpiry), now: afterExpiry)
        XCTAssertEqual(reader.scans, scans, "Draining a cursor reuses the finished inventory")
        for row in updated.records { state.consume(row, now: afterExpiry) }
        XCTAssertEqual(reader.transcriptURL(for: newSession)?.path, newLog.path)
        let released = try XCTUnwrap(sessions.first { reader.transcriptURL(for: $0) == nil })
        func releasedPhase() -> ActivityPhase? { state.activities.first { $0.threadID == released }?.phase }
        XCTAssertEqual(releasedPhase(), .unknown)
        event("stopVerified", released, "other-turn", at: afterExpiry.addingTimeInterval(1))
        XCTAssertEqual(releasedPhase(), .unknown)
        event("stopVerified", released, "owned-turn", at: afterExpiry.addingTimeInterval(2))
        XCTAssertEqual(releasedPhase(), .completed)
    }

    func testNativeAndSSHDiscoveryPickTheSamePathsWhenDatesTie() throws {
        let base = FileManager.default.temporaryDirectory
        let home = base.appendingPathComponent("pacer-claude-ties-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let date = Date(timeIntervalSince1970: 1_700_000_000), manager = FileManager.default
        func write(_ session: String, to project: URL, at time: Date) throws {
            let log = project.appendingPathComponent(session + ".jsonl")
            try Data().write(to: log)
            try manager.setAttributes([.modificationDate: time], ofItemAtPath: log.path)
        }
        let lastProject = ClaudeActivityReader.maximumProjects
        let tiedLogCount = ClaudeActivityReader.maximumFileWatches + 3
        for index in 0...lastProject {
            let project = home.appendingPathComponent(String(format: "projects/project-%03d", index))
            try manager.createDirectory(at: project, withIntermediateDirectories: true)
            switch index {
            case 0: try write("outside-project-limit", to: project, at: date.addingTimeInterval(2))
            case 1: try write("inside-project-limit", to: project, at: date.addingTimeInterval(1))
            case lastProject:
                for log in 0..<tiedLogCount { try write(String(format: "tied-%03d", log), to: project, at: date) }
            default: break
            }
            try manager.setAttributes([.modificationDate: date], ofItemAtPath: project.path)
        }
        var reader = ClaudeActivityReader(files: TestFileSystem())
        var result = reader.read(home: home, discover: true)
        for _ in 0..<8 where result.discoveryPending { result = reader.read(home: home, discover: false) }
        XCTAssertFalse(result.discoveryPending)
        let local = Set(result.watchURLs.filter { $0.pathExtension == "jsonl" }.map { $0.deletingPathExtension().lastPathComponent })
        let expected = Set((4..<tiedLogCount).map { String(format: "tied-%03d", $0) } + ["inside-project-limit"])
        XCTAssertEqual(local, expected)

        let body = """
        import base64, json, pathlib, sys
        namespace = {'__name__': 'fixture'}
        exec(base64.b64decode(sys.argv[1]), namespace)
        source = namespace['Tailer'](pathlib.Path(sys.argv[2]))
        while not source.discover(): pass
        try: print(json.dumps([path.stem for path in source.cursors]))
        finally: source.close()
        """
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = PythonFixture.executable
        process.arguments = ["-c", body, Data(ClaudeActivityProbe.script.utf8).base64EncodedString(), home.path]
        process.standardOutput = output; process.standardError = errors
        let python = try PythonFixture.prepare(process); defer { python.remove() }
        try process.run()
        let reply = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual(Set(try JSONDecoder().decode([String].self, from: reply)), expected)
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
