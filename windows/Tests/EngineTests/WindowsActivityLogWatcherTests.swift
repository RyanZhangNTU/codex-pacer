@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import XCTest
@testable import PacerCore

final class WindowsActivityLogWatcherTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-watch-" + UUID().uuidString + "-中文 space")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func ready(_ watcher: ActivityLogWatcher, count: Int) async throws {
        for _ in 0..<100 {
            if await watcher.activeWatchCount() == count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let actual = await watcher.activeWatchCount()
        XCTAssertEqual(actual, count)
    }
    func testRecursiveAppendAndReplacementWakeWithoutPolling() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("project/session")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("fixture.jsonl")
        try Data("first\n".utf8).write(to: file)
        let delivery = expectation(description: "an append under a nested source wakes the reader")
        let watcher = ActivityLogWatcher { discovery in XCTAssertFalse(discovery); delivery.fulfill() }
        watcher.update([root], interval: 0.1)
        try await ready(watcher, count: 1)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("appended\n".utf8)); try handle.close()
        await fulfillment(of: [delivery], timeout: 3)
        watcher.stop(); try await ready(watcher, count: 0)

        let replacement = expectation(description: "atomic replacement also wakes the reader")
        let next = ActivityLogWatcher { discovery in if discovery { replacement.fulfill() } }
        next.update([root], interval: 0.1)
        try await ready(next, count: 1)
        try Data("replacement\n".utf8).write(to: file, options: .atomic)
        await fulfillment(of: [replacement], timeout: 3)
        next.stop(); try await ready(next, count: 0)
    }
    func testExpansionFlushesPendingChangesAndStopCancelsLaterDelivery() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let delivery = expectation(description: "expansion flushes a pending five-second change")
        let watcher = ActivityLogWatcher { _ in delivery.fulfill() }
        watcher.update([root], interval: ActivityRefreshPolicy.collapsed.interval)
        try await ready(watcher, count: 1)
        try Data("first\n".utf8).write(to: root.appendingPathComponent("fixture.jsonl"))
        try await Task.sleep(nanoseconds: 200_000_000)
        watcher.update([root], interval: ActivityRefreshPolicy.expanded.interval, flushPending: true)
        await fulfillment(of: [delivery], timeout: 0.8)
        watcher.stop(); try await ready(watcher, count: 0)

        let stopped = expectation(description: "stopped watchers cannot publish delayed changes")
        stopped.isInverted = true
        let next = ActivityLogWatcher { _ in stopped.fulfill() }
        next.update([root], interval: 0.5)
        try await ready(next, count: 1)
        try Data("next\n".utf8).write(to: root.appendingPathComponent("second.jsonl"))
        try await Task.sleep(nanoseconds: 100_000_000)
        next.stop(); try await ready(next, count: 0)
        await fulfillment(of: [stopped], timeout: 0.7)
    }
    func testReplacingSourcesDropsOldNotificationsAndIdleHasNoCallbacks() async throws {
        let first = try directory(), second = try directory()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let silent = expectation(description: "old and idle source roots stay silent")
        silent.isInverted = true
        let watcher = ActivityLogWatcher { _ in silent.fulfill() }
        watcher.update([first], interval: 0.1)
        try await ready(watcher, count: 1)
        watcher.update([second], interval: 0.1)
        _ = await watcher.activeWatchCount()
        try Data("old\n".utf8).write(to: first.appendingPathComponent("old.jsonl"))
        await fulfillment(of: [silent], timeout: 0.5)
        watcher.stop(); try await ready(watcher, count: 0)
    }
    func testNonexistentDirectoryIsNotRetainedAndRepeatedCloseReleasesHandles() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = ActivityLogWatcher { _ in }
        watcher.update([root.appendingPathComponent("missing")], interval: 0.1)
        try await ready(watcher, count: 0)
        for _ in 0..<40 {
            watcher.update([root], interval: 0.1); try await ready(watcher, count: 1)
            watcher.update([], interval: 0.1); try await ready(watcher, count: 0)
        }
        watcher.stop(); try await ready(watcher, count: 0)
        watcher.stop(); try await ready(watcher, count: 0)
    }
}
#endif
