import Foundation
import XCTest
@testable import PacerCore

final class ClaudeInitialBacklogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let session = "00000000-0000-4000-8000-000000000001"
    private let prompt = "fixture-prompt"
    private let initialBudget = 512 * 1024
    private let liveLimit = 8 * 1024 * 1024

    /// Directory discovery uses real empty files; all byte reads and file facts
    /// go through the same interface that the production reader receives.
    private final class Files: PlatformFileSystem, @unchecked Sendable {
        struct Entry { var bytes: Data; var identity: String; var created: Date?; var modified: Date }
        struct Read { let offset: UInt64; let maximum: Int; let count: Int }
        var entries: [URL: Entry] = [:]
        var reads: [Read] = []
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        func entries(in directory: URL) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        }
        func install(_ url: URL, bytes: Data, identity: String = "0", created: Date?, modified: Date) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
            entries[url] = Entry(bytes: bytes, identity: identity, created: created, modified: modified)
        }
        func metadata(_ url: URL, followingSymbolicLinks: Bool) -> PlatformFileMetadata? {
            entries[url].map { .init(identity: $0.identity, size: UInt64($0.bytes.count), modified: $0.modified,
                                    created: $0.created, isRegularFile: true) }
        }
        func read(_ url: URL, offset: UInt64, maximumBytes: Int) throws -> Data {
            let entry = try XCTUnwrap(entries[url])
            let start = min(entry.bytes.count, Int(offset)), end = min(entry.bytes.count, start + maximumBytes)
            let bytes = entry.bytes.subdata(in: start..<end)
            reads.append(Read(offset: offset, maximum: maximumBytes, count: bytes.count))
            return bytes
        }
        func replace(_ url: URL, with data: Data) -> Bool { false }
        var totalRead: Int { reads.reduce(0) { $0 + $1.count } }
    }
    private func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-shared-backlog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func file(_ root: URL, session supplied: String? = nil) -> URL {
        root.appendingPathComponent("projects/synthetic/" + (supplied ?? session) + ".jsonl")
    }
    private func line(_ type: String, id: String, parent: String? = nil, at date: Date, extra: [String: Any] = [:]) throws -> Data {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var row: [String: Any] = ["type": type, "uuid": id, "sessionId": session, "timestamp": formatter.string(from: date)]
        if let parent { row["parentUuid"] = parent }
        row.merge(extra) { _, value in value }
        return try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
    }
    private func transcript(size: Int, at date: Date, includePrompt: Bool = true) throws -> Data {
        let start = try line("user", id: prompt, at: date,
            extra: ["origin": ["kind": "human"], "message": ["role": "user", "content": "PRIVATE synthetic prompt"]])
        let ending = try line("assistant", id: "answer", parent: prompt, at: date,
            extra: ["message": ["role": "assistant", "content": [["type": "text", "text": "PRIVATE synthetic reply"]], "stop_reason": "end_turn"]])
            + line("system", id: "stop", parent: "answer", at: date,
                extra: ["subtype": "stop_hook_summary", "preventedContinuation": false, "hookErrors": [String](), "hookAdditionalContext": [String]()])
        var result = includePrompt ? start : Data()
        var remaining = size - result.count - ending.count
        XCTAssertGreaterThanOrEqual(remaining, 0)
        let prefix = Data(#"{"type":"api-request-shape","payload":"PRIVATE metadata "#.utf8)
        let suffix = Data("\"}\n".utf8), overhead = prefix.count + suffix.count
        while remaining >= overhead {
            let count = min(60 * 1024, remaining)
            result.append(prefix); result.append(Data(repeating: 88, count: count - overhead)); result.append(suffix)
            remaining -= count
        }
        result.append(Data(repeating: 32, count: remaining)); result.append(ending)
        XCTAssertEqual(result.count, size)
        return result
    }
    private func drain(_ reader: inout ClaudeActivityReader, root: URL, at date: Date, first: ClaudeActivityReader.Result? = nil) throws -> (ClaudeActivityState, [Data]) {
        var state = ClaudeActivityState(), rows: [Data] = []
        for pass in 0..<160 {
            let result = pass == 0 ? first ?? reader.read(home: root, discover: true, now: date)
                : reader.read(home: root, discover: false, now: date)
            rows += result.records
            for row in result.records { state.consume(row, now: date) }
            if result.caughtUp { state.finalizeHistoricalBaseline(now: date); return (state, rows) }
        }
        XCTFail("A bounded backlog must finish draining")
        return (state, rows)
    }
    private func containsGap(_ rows: [Data]) -> Bool {
        rows.contains { $0.range(of: Data(#""kind":"discontinuity""#.utf8)) != nil }
    }
    private func checkPrivacy(_ rows: [Data], file: StaticString = #filePath, line: UInt = #line) {
        let serialized = rows.map { String(decoding: $0, as: UTF8.self) }.joined()
        for marker in ["PRIVATE synthetic prompt", "PRIVATE synthetic reply", "PRIVATE metadata"] {
            XCTAssertFalse(serialized.contains(marker), file: file, line: line)
        }
    }

    func testFirstObservedDesktopFileDrainsLargeMetadataWithoutLosingHistoricalPromptOwnership() throws {
        let root = try home(), files = Files()
        var reader = ClaudeActivityReader(files: files)
        _ = reader.read(home: root, discover: true, now: now)
        let date = now.addingTimeInterval(1)
        try files.install(file(root), bytes: transcript(size: 640 * 1024, at: now.addingTimeInterval(-3600)), created: date, modified: date)
        let first = reader.read(home: root, discover: true, now: date)
        XCTAssertFalse(first.caughtUp)
        let (state, rows) = try drain(&reader, root: root, at: date, first: first)
        let activity = try XCTUnwrap(state.activities.first { $0.threadID == session })
        XCTAssertEqual(activity.phase, .completed); XCTAssertTrue(activity.isHistoricalCompletion)
        XCTAssertFalse(activity.liveTurnStarted); XCTAssertGreaterThan(reader.fileReads, 1)
        XCTAssertFalse(containsGap(rows)); checkPrivacy(rows)
        var policy = AttentionPolicy()
        XCTAssertTrue(policy.activityNotices(state.activities, at: date).isEmpty)
    }

    func testVeryLargeOldTranscriptKeepsABoundedTailAndDoesNotInventOwnership() throws {
        let root = try home(), files = Files()
        try files.install(file(root), bytes: transcript(size: 9 * 1024 * 1024, at: now.addingTimeInterval(-3600)), created: now.addingTimeInterval(-3600), modified: now)
        var reader = ClaudeActivityReader(files: files), state = ClaudeActivityState()
        let result = reader.read(home: root, discover: true, now: now)
        for row in result.records { state.consume(row, now: now) }
        state.finalizeHistoricalBaseline(now: now)
        XCTAssertTrue(result.caughtUp); XCTAssertEqual(reader.fileReads, 1)
        XCTAssertEqual(files.totalRead, initialBudget); XCTAssertTrue(containsGap(result.records))
        XCTAssertTrue(state.activities.allSatisfy { $0.phase == .unknown }); checkPrivacy(result.records)
    }

    func testGenuinelyNewFirstFileKeepsItsLiveEndingAndUnreadEvidence() throws {
        let root = try home(), files = Files()
        var reader = ClaudeActivityReader(files: files)
        _ = reader.read(home: root, discover: true, now: now)
        let date = now.addingTimeInterval(1)
        try files.install(file(root), bytes: transcript(size: 640 * 1024, at: date), created: date, modified: date)
        let (state, rows) = try drain(&reader, root: root, at: date)
        let activity = try XCTUnwrap(state.activities.first { $0.threadID == session })
        XCTAssertEqual(activity.phase, .completed); XCTAssertFalse(activity.isHistoricalCompletion); XCTAssertTrue(activity.liveTurnStarted)
        XCTAssertGreaterThan(reader.fileReads, 1); XCTAssertFalse(containsGap(rows)); checkPrivacy(rows)
        var policy = AttentionPolicy()
        XCTAssertEqual(policy.activityNotices(state.activities, at: date).map(\.kind), [.completed])
        XCTAssertTrue(policy.activityNotices(state.activities, at: date).isEmpty, "A drained ending notifies only once")
    }

    func testReattachingAnExcludedNewFileCannotReplayItsFirstTurnAsLive() throws {
        let root = try home(), files = Files()
        var reader = ClaudeActivityReader(files: files)
        _ = reader.read(home: root, discover: true, now: now)
        let date = now.addingTimeInterval(1)
        try files.install(file(root), bytes: transcript(size: 64 * 1024, at: date), created: date, modified: date)
        let first = try drain(&reader, root: root, at: date).0
        XCTAssertFalse(try XCTUnwrap(first.activities.first).isHistoricalCompletion)
        XCTAssertEqual(reader.excludeSessionIDs([session]), [file(root)])
        let replay = try drain(&reader, root: root, at: date).0
        XCTAssertTrue(try XCTUnwrap(replay.activities.first).isHistoricalCompletion)
        XCTAssertFalse(try XCTUnwrap(replay.activities.first).liveTurnStarted)
    }

    func testColdStartTotalReadStaysAtSixteenMiBForThirtyTwoLargeSessions() throws {
        let root = try home(), files = Files(), bytes = try transcript(size: 2 * 1024 * 1024, at: now.addingTimeInterval(-3600))
        for index in 0..<33 {
            let id = String(format: "00000000-0000-4000-8000-%012d", index + 1)
            try files.install(file(root, session: id), bytes: bytes, created: now.addingTimeInterval(-3600), modified: now)
        }
        var reader = ClaudeActivityReader(files: files)
        let result = reader.read(home: root, discover: true, now: now)
        XCTAssertTrue(result.caughtUp); XCTAssertEqual(reader.attachedTranscriptCount, 32)
        XCTAssertEqual(files.totalRead, 32 * initialBudget)
        XCTAssertEqual(reader.bytesRead, 16 * 1024 * 1024)
        XCTAssertEqual(files.reads.count, 32); XCTAssertTrue(files.reads.allSatisfy { $0.maximum == initialBudget })
        _ = reader.read(home: root, discover: false, now: now)
        XCTAssertEqual(files.totalRead, 16 * 1024 * 1024, "An idle read cannot scan the skipped cold history")
        reader.reset(); XCTAssertEqual(reader.bytesRead, 0)
    }

    func testColdAndObservedFirstReadUseTheirExactBacklogBoundaries() throws {
        for observed in [false, true] {
            let limit = observed ? liveLimit : initialBudget
            for delta in [-1, 0, 1] {
                let root = try home(), files = Files(), date = now.addingTimeInterval(1)
                var reader = ClaudeActivityReader(files: files)
                if observed { _ = reader.read(home: root, discover: true, now: now) }
                try files.install(file(root), bytes: transcript(size: limit + delta, at: date), created: date, modified: date)
                let first = reader.read(home: root, discover: true, now: date)
                let (state, rows) = try drain(&reader, root: root, at: date, first: first)
                XCTAssertEqual(containsGap(rows), delta > 0)
                XCTAssertEqual(files.reads.first?.maximum, initialBudget)
                XCTAssertTrue(files.reads.dropFirst().allSatisfy { $0.maximum <= 128 * 1024 })
                if delta <= 0 {
                    let activity = try XCTUnwrap(state.activities.first)
                    XCTAssertEqual(activity.phase, .completed); XCTAssertEqual(activity.isHistoricalCompletion, !observed)
                    XCTAssertEqual(files.totalRead, limit + delta)
                } else {
                    XCTAssertEqual(files.totalRead, initialBudget)
                    XCTAssertTrue(state.activities.allSatisfy { $0.phase == .unknown })
                }
                checkPrivacy(rows)
            }
        }
    }

    func testAttachedAppendUsesEightMiBAndKeepsItsPerReadBudget() throws {
        for delta in [-1, 0, 1] {
            let root = try home(), files = Files(), url = file(root), date = now.addingTimeInterval(1)
            try files.install(url, bytes: Data(), created: now.addingTimeInterval(-3600), modified: now)
            var reader = ClaudeActivityReader(files: files)
            _ = reader.read(home: root, discover: true, now: now)
            XCTAssertEqual(reader.fileReads, 1, "An empty file with zero identity still establishes a cursor")
            files.entries[url]?.bytes = try transcript(size: liveLimit + delta, at: date)
            let (state, rows) = try drain(&reader, root: root, at: date)
            XCTAssertEqual(containsGap(rows), delta > 0)
            XCTAssertTrue(files.reads.dropFirst().allSatisfy { $0.maximum == 128 * 1024 })
            if delta <= 0 {
                let activity = try XCTUnwrap(state.activities.first)
                XCTAssertEqual(activity.phase, .completed); XCTAssertFalse(activity.isHistoricalCompletion); XCTAssertTrue(activity.liveTurnStarted)
                XCTAssertEqual(files.totalRead, liveLimit + delta)
            } else { XCTAssertEqual(files.totalRead, 128 * 1024); XCTAssertTrue(state.activities.allSatisfy { $0.phase == .unknown }) }
            checkPrivacy(rows)
        }
    }

    func testUnknownCreationDateDoesNotUpgradeFirstReadToLive() throws {
        let root = try home(), files = Files(), date = now.addingTimeInterval(1)
        var reader = ClaudeActivityReader(files: files)
        _ = reader.read(home: root, discover: true, now: now)
        try files.install(file(root), bytes: transcript(size: 640 * 1024, at: date), created: nil, modified: date)
        let result = reader.read(home: root, discover: true, now: date)
        XCTAssertTrue(result.caughtUp); XCTAssertEqual(reader.bytesRead, initialBudget); XCTAssertTrue(containsGap(result.records))
    }

    func testReplacementAndTruncationRevokeLiveFirstReadEvidence() throws {
        for change in ["identity", "creation", "truncation"] {
            let root = try home(), files = Files(), url = file(root), date = now.addingTimeInterval(1)
            var reader = ClaudeActivityReader(files: files)
            _ = reader.read(home: root, discover: true, now: now)
            try files.install(url, bytes: transcript(size: 96 * 1024, at: date), created: date, modified: date)
            XCTAssertFalse(try XCTUnwrap(drain(&reader, root: root, at: date).0.activities.first).isHistoricalCompletion)
            files.entries[url]?.bytes = try transcript(size: change == "truncation" ? 64 * 1024 : 128 * 1024, at: date)
            if change == "identity" { files.entries[url]?.identity = "replacement" }
            if change == "creation" { files.entries[url]?.created = date.addingTimeInterval(1) }
            let (state, rows) = try drain(&reader, root: root, at: date)
            let activity = try XCTUnwrap(state.activities.first)
            XCTAssertTrue(containsGap(rows)); XCTAssertEqual(activity.phase, .completed)
            XCTAssertTrue(activity.isHistoricalCompletion); XCTAssertFalse(activity.liveTurnStarted)
        }
    }

    func testInjectedClockDefinesObservationAndResetStartsANewHistoricalBaseline() throws {
        let root = try home(), files = Files(), url = file(root)
        var reader = ClaudeActivityReader(files: files, clock: { files.time })
        _ = reader.read(home: root, discover: true)
        files.time = now.addingTimeInterval(1)
        try files.install(url, bytes: transcript(size: 64 * 1024, at: files.time), created: files.time, modified: files.time)
        let first = reader.read(home: root, discover: true)
        let initial = try drain(&reader, root: root, at: files.time, first: first).0
        XCTAssertFalse(try XCTUnwrap(initial.activities.first).isHistoricalCompletion)
        reader.reset()
        let reset = reader.read(home: root, discover: true)
        let replay = try drain(&reader, root: root, at: files.time, first: reset).0
        XCTAssertTrue(try XCTUnwrap(replay.activities.first).isHistoricalCompletion)
        XCTAssertFalse(try XCTUnwrap(replay.activities.first).liveTurnStarted)
    }

    func testExcludedFileObservedBeforeAttachmentCannotBecomeLiveWhenRestored() throws {
        let root = try home(), files = Files(), date = now.addingTimeInterval(1)
        var reader = ClaudeActivityReader(files: files)
        _ = reader.read(home: root, discover: true, now: now)
        try files.install(file(root), bytes: transcript(size: 64 * 1024, at: date), created: date, modified: date)
        let hidden = reader.read(home: root, discover: true, excludingSessionIDs: [session], now: date)
        XCTAssertTrue(hidden.records.isEmpty); XCTAssertEqual(reader.fileReads, 0)
        let (state, _) = try drain(&reader, root: root, at: date)
        XCTAssertTrue(try XCTUnwrap(state.activities.first).isHistoricalCompletion)
        XCTAssertFalse(try XCTUnwrap(state.activities.first).liveTurnStarted)
    }

    func testOversizeAndPartialRecordsDropOwnershipWithoutLeakingContent() throws {
        for terminated in [false, true] {
            let root = try home(), files = Files(), url = file(root), date = now.addingTimeInterval(1)
            var reader = ClaudeActivityReader(files: files)
            _ = reader.read(home: root, discover: true, now: now)
            let start = try line("user", id: prompt, at: date, extra: ["origin": ["kind": "human"], "message": ["content": "PRIVATE synthetic prompt"]])
            var oversize = try line("attachment", id: "oversize", parent: prompt, at: date,
                extra: ["attachment": ["body": String(repeating: "PRIVATE metadata", count: 90_000)]])
            if !terminated { oversize.removeLast() }
            try files.install(url, bytes: start + oversize, created: date, modified: date)
            let (_, firstRows) = try drain(&reader, root: root, at: date)
            XCTAssertTrue(containsGap(firstRows)); checkPrivacy(firstRows)
            var ending = terminated ? Data() : Data([10])
            ending.append(try line("assistant", id: "answer", parent: "oversize", at: date,
                extra: ["message": ["content": [["type": "text", "text": "PRIVATE synthetic reply"]]]]))
            ending.append(try line("system", id: "stop", parent: "answer", at: date,
                extra: ["subtype": "stop_hook_summary", "preventedContinuation": false, "hookErrors": [String](), "hookAdditionalContext": [String]()]))
            files.entries[url]?.bytes.append(ending)
            let (state, rows) = try drain(&reader, root: root, at: date)
            XCTAssertTrue(state.activities.allSatisfy { $0.phase == .unknown })
            XCTAssertTrue(state.activities.allSatisfy { $0.responsePerformance == nil && !$0.liveTurnStarted })
            checkPrivacy(rows)
        }
    }

    func testPartialInitialLineWaitsForItsNewlineAndKeepsItsProvenance() throws {
        let root = try home(), files = Files(), url = file(root), date = now.addingTimeInterval(1)
        var reader = ClaudeActivityReader(files: files)
        _ = reader.read(home: root, discover: true, now: now)
        let bytes = try transcript(size: 640 * 1024, at: date)
        let split = try XCTUnwrap(bytes.firstIndex(of: 10))
        try files.install(url, bytes: bytes.prefix(upTo: split), created: date, modified: date)
        let partial = reader.read(home: root, discover: true, now: date)
        XCTAssertTrue(partial.records.isEmpty)
        files.entries[url]?.bytes.append(bytes.suffix(from: split))
        let (state, rows) = try drain(&reader, root: root, at: date)
        let activity = try XCTUnwrap(state.activities.first)
        XCTAssertEqual(activity.phase, .completed); XCTAssertFalse(activity.isHistoricalCompletion); XCTAssertTrue(activity.liveTurnStarted)
        XCTAssertFalse(containsGap(rows)); checkPrivacy(rows)
    }

    func testNewHookBacklogIsDrainedBeforeTheLargeNewTranscript() throws {
        let root = try home(), files = Files(), date = now.addingTimeInterval(1)
        var reader = ClaudeActivityReader(files: files)
        _ = reader.read(home: root, discover: true, now: now)
        let hookURL = root.appendingPathComponent("pacer/events.jsonl")
        var hooks = Data()
        for index in 0..<520 {
            hooks.append(try XCTUnwrap(ClaudeActivityRecord.encode(["kind": index == 0 ? "prompt" : "toolEnd", "origin": "hook",
                "sessionId": session, "promptId": prompt, "itemId": "fixture-\(index)", "at": date.timeIntervalSince1970])))
            hooks.append(10)
        }
        try files.install(hookURL, bytes: hooks, created: date, modified: date)
        try files.install(file(root), bytes: transcript(size: 640 * 1024, at: date), created: date, modified: date)
        let first = reader.read(home: root, discover: true, now: date)
        XCTAssertFalse(first.caughtUp); XCTAssertEqual(first.records.count, 512)
        XCTAssertEqual(reader.transcriptDocumentParses, 0, "The transcript must wait for complete hook records")
        let (state, rows) = try drain(&reader, root: root, at: date, first: first)
        let activity = try XCTUnwrap(state.activities.first)
        XCTAssertEqual(activity.turnID, prompt); XCTAssertEqual(activity.phase, .completed)
        XCTAssertFalse(activity.isHistoricalCompletion); XCTAssertTrue(activity.liveTurnStarted)
        checkPrivacy(rows)
    }

    func testLateParentReleasesLiveInitialRowsWithTheirOriginalProvenance() throws {
        let root = try home(), files = Files(), date = now.addingTimeInterval(1)
        var reader = ClaudeActivityReader(files: files)
        _ = reader.read(home: root, discover: true, now: now)
        let rows = [try line("assistant", id: "answer", parent: "bridge", at: date,
            extra: ["message": ["content": [["type": "text", "text": "PRIVATE synthetic reply"]]]]),
            try line("system", id: "stop", parent: "answer", at: date,
                extra: ["subtype": "stop_hook_summary", "preventedContinuation": false, "hookErrors": [String](), "hookAdditionalContext": [String]()]),
            try line("attachment", id: "bridge", parent: prompt, at: date),
            try line("user", id: prompt, at: date, extra: ["origin": ["kind": "human"], "message": ["content": "PRIVATE synthetic prompt"]])]
        try files.install(file(root), bytes: rows.reduce(into: Data()) { $0.append($1) }, created: date, modified: date)
        let (state, emitted) = try drain(&reader, root: root, at: date)
        let activity = try XCTUnwrap(state.activities.first)
        XCTAssertEqual(activity.phase, .completed); XCTAssertEqual(activity.turnID, prompt)
        XCTAssertFalse(activity.isHistoricalCompletion); XCTAssertTrue(activity.liveTurnStarted)
        XCTAssertEqual(reader.transcriptDocumentParses, rows.count); checkPrivacy(emitted)
    }

    func testNewSubagentUsesTheSameFileObservationAndBacklogRules() throws {
        let root = try home(), files = Files(), date = now.addingTimeInterval(1), child = "fixture-child"
        try files.install(file(root), bytes: Data(), created: now.addingTimeInterval(-3600), modified: now)
        var reader = ClaudeActivityReader(files: files)
        _ = reader.read(home: root, discover: true, now: now)
        let childFile = root.appendingPathComponent("projects/synthetic/\(session)/subagents/agent-\(child).jsonl")
        try files.install(childFile, bytes: transcript(size: 640 * 1024, at: date), created: date, modified: date)
        let (state, rows) = try drain(&reader, root: root, at: date)
        let activity = try XCTUnwrap(state.activities.first { $0.threadID == child })
        XCTAssertEqual(activity.phase, .completed); XCTAssertEqual(activity.parentThreadID, session)
        XCTAssertFalse(activity.isHistoricalCompletion); XCTAssertTrue(activity.liveTurnStarted)
        XCTAssertFalse(containsGap(rows)); checkPrivacy(rows)
    }
}
