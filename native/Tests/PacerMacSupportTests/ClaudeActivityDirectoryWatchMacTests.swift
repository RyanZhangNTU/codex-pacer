import Foundation
import XCTest
@testable import PacerCore
import PacerMacSupport

final class ClaudeActivityDirectoryWatchMacTests: XCTestCase {
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

    func testSymlinkHomeKeepsCursorsAndWatchesStableAcrossDiscoveryAndAppend() async throws {
        let fixture = try fixture()
        let home = fixture.home.deletingLastPathComponent().appendingPathComponent(fixture.home.lastPathComponent + "-link")
        try FileManager.default.createSymbolicLink(at: home, withDestinationURL: fixture.home)
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: fixture.home) }
        for (project, session) in [(fixture.alpha, rootSession), (fixture.beta, otherSession)] {
            let writer = try FileHandle(forWritingTo: project.appendingPathComponent(session + ".jsonl"))
            try writer.seekToEnd(); try writer.write(contentsOf: Data([10])); try writer.close()
        }
        var reader = ClaudeActivityReader(files: TestFileSystem())
        let first = reader.read(home: home, discover: true)
        let physicalWatches = Set(first.watchURLs.map { $0.resolvingSymlinksInPath().path })
        XCTAssertEqual(physicalWatches.count, first.watchURLs.count, "Aliases cannot spend two watch slots on one physical entry")
        XCTAssertEqual(reader.attachedTranscriptCount, 2); XCTAssertEqual(reader.fileReads, 2)
        let again = reader.read(home: home, discover: true)
        XCTAssertEqual(Set(again.watchURLs.map(\.path)), Set(first.watchURLs.map(\.path)))
        XCTAssertTrue(again.records.isEmpty); XCTAssertEqual(reader.fileReads, 2)
        func prompt(session: String, id: String) -> Data {
            ClaudeActivityRecord.encode(["type": "user", "sessionId": session, "promptId": id, "uuid": "user-" + id,
                "timestamp": ISO8601DateFormatter().string(from: Date()), "message": ["content": "synthetic"]])! + Data([10])
        }
        let file = fixture.alpha.appendingPathComponent(rootSession + ".jsonl")
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd(); try writer.write(contentsOf: prompt(session: rootSession, id: "symlink-append")); try writer.close()
        XCTAssertFalse(reader.read(home: home, discover: false).records.isEmpty)
        XCTAssertEqual(reader.fileReads, 3)
        XCTAssertTrue(reader.read(home: home, discover: true).records.isEmpty)
        XCTAssertEqual(reader.attachedTranscriptCount, 2); XCTAssertEqual(reader.fileReads, 3)
        XCTAssertEqual(reader.transcriptURL(for: rootSession)?.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)

        let monitor = ClaudeActivityMonitor(), session = newSession
        addTeardownBlock { await monitor.shutdown() }
        let discovered = expectation(description: "a new transcript under the symlink home is observed")
        discovered.assertForOverFulfill = false
        await monitor.start(home: home) { activities, _, _, _ in
            if activities.contains(where: { $0.threadID == session && $0.phase == .running }) { discovered.fulfill() }
        }
        let watches = await monitor.localWatchCount()
        XCTAssertGreaterThan(watches, 0); XCTAssertLessThanOrEqual(watches, 32 + ClaudeActivityReader.maximumDirectoryWatches)
        try prompt(session: session, id: "symlink-discovery").write(to: fixture.beta.appendingPathComponent(session + ".jsonl"))
        await fulfillment(of: [discovered], timeout: TestWait.limit)
        let activities = await monitor.activities()
        XCTAssertEqual(activities.filter { $0.threadID == session }.count, 1)
        await monitor.shutdown()
    }
}
