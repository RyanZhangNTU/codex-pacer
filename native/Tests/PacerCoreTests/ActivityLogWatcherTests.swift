import XCTest
@testable import PacerCore

final class ActivityLogWatcherTests: XCTestCase {
    func testExpansionFlushesPendingFiveSecondAppendWithoutAnotherWrite() async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/pacer-watch-expand-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.jsonl")
        try Data("initial\n".utf8).write(to: file)
        let delivered = expectation(description: "pending append delivered on expansion")
        let watcher = ActivityLogWatcher(interval: 5) { discovery in
            XCTAssertFalse(discovery); delivered.fulfill()
        }
        watcher.update([file], interval: 5)
        try await Task.sleep(nanoseconds: 100_000_000)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("next\n".utf8)); try handle.close()
        try await Task.sleep(nanoseconds: 100_000_000)
        watcher.update([file], interval: 1, flushPending: true)
        await fulfillment(of: [delivered], timeout: 1)
        watcher.stop()
    }

    func testAppendAndDirectoryCreationWakeAndStoppingCancelsPendingDelivery() async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/pacer-watch-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.jsonl")
        try Data("initial\n".utf8).write(to: file)
        let appended = expectation(description: "incremental append wakes reader")
        let watcher = ActivityLogWatcher(interval: 0.1) { discovery in
            XCTAssertFalse(discovery); appended.fulfill()
        }
        watcher.update([file], interval: 0.1)
        try await Task.sleep(nanoseconds: 50_000_000)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("next\n".utf8)); try handle.close()
        await fulfillment(of: [appended], timeout: 2); watcher.stop()
        let created = expectation(description: "new rollout triggers discovery")
        let directories = ActivityLogWatcher { discovery in
            XCTAssertTrue(discovery); created.fulfill()
        }
        directories.update([folder], interval: 0.1)
        try await Task.sleep(nanoseconds: 50_000_000)
        try Data("new\n".utf8).write(to: folder.appendingPathComponent("new.jsonl"))
        await fulfillment(of: [created], timeout: 2); directories.stop()
        let stopped = expectation(description: "stopped watcher has no delayed publication"); stopped.isInverted = true
        let cancelled = ActivityLogWatcher { _ in stopped.fulfill() }
        cancelled.update([file], interval: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = try FileHandle(forWritingTo: file); try second.seekToEnd(); try second.write(contentsOf: Data("cancel\n".utf8)); try second.close()
        try await Task.sleep(nanoseconds: 50_000_000); cancelled.stop()
        await fulfillment(of: [stopped], timeout: 1.2)
    }
}
