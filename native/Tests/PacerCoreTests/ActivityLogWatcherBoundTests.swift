import XCTest
@testable import PacerCore

final class ActivityLogWatcherBoundTests: XCTestCase {
    private final class Events: ActivityFileEvents, @unchecked Sendable {
        final class Watch: ActivityFileWatch, @unchecked Sendable {
            let changed: @Sendable (ActivityFileEvent) -> Void
            private let lock = NSLock()
            private var stopped = false
            init(_ changed: @escaping @Sendable (ActivityFileEvent) -> Void) { self.changed = changed }
            func stop() { lock.lock(); stopped = true; lock.unlock() }
            var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        }
        private let lock = NSLock()
        private var watches: [URL: [Watch]] = [:]
        func watch(_ url: URL, isDirectory: Bool, changed: @escaping @Sendable (ActivityFileEvent) -> Void) -> (any ActivityFileWatch)? {
            let watch = Watch(changed)
            lock.lock(); watches[url, default: []].append(watch); lock.unlock()
            return watch
        }
        func history(_ url: URL) -> [Watch] { lock.lock(); defer { lock.unlock() }; return watches[url] ?? [] }
        var all: [Watch] { lock.lock(); defer { lock.unlock() }; return watches.values.flatMap { $0 } }
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-shared-watch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testFileAndDirectoryCapsAndStopReleaseEveryRawWatch() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directories = (0..<110).map { root.appendingPathComponent("directory-\($0)") }
        for directory in directories { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        let files = (0..<40).map { root.appendingPathComponent("file-\($0).jsonl") }
        for file in files { try Data().write(to: file) }
        let events = Events()
        let watcher = ActivityLogWatcher(files: TestFileSystem(), events: events, maximumDirectoryWatches: 999) { _ in XCTFail("Idle watches cannot publish") }
        watcher.update(files + directories, interval: 0.1)
        let count = await watcher.activeWatchCount()
        XCTAssertEqual(count, 32 + 99); XCTAssertEqual(events.all.count, count)
        watcher.stop()
        let stopped = await watcher.activeWatchCount()
        XCTAssertEqual(stopped, 0); XCTAssertTrue(events.all.allSatisfy(\.isStopped))
    }
    func testInvalidationReattachesAndIgnoresLateCallbacksFromPreviousHandles() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.jsonl"); try Data().write(to: file)
        let events = Events(), delivered = expectation(description: "replacement event delivered")
        let watcher = ActivityLogWatcher(files: TestFileSystem(), events: events, interval: 0.1) { discover in
            XCTAssertFalse(discover); delivered.fulfill()
        }
        watcher.update([file], interval: 0.1); _ = await watcher.activeWatchCount()
        let old = try XCTUnwrap(events.history(file).last)
        old.changed(ActivityFileEvent(invalidated: true)); _ = await watcher.activeWatchCount()
        XCTAssertTrue(old.isStopped)
        watcher.update([file], interval: 0.1); _ = await watcher.activeWatchCount()
        XCTAssertEqual(events.history(file).count, 2)
        // The retired source cannot turn the pending file event into discovery.
        old.changed(ActivityFileEvent(requiresDiscovery: true))
        await fulfillment(of: [delivered], timeout: 2)
        watcher.stop(); _ = await watcher.activeWatchCount()
        let silent = expectation(description: "stopped handle is ignored"); silent.isInverted = true
        let stopped = ActivityLogWatcher(files: TestFileSystem(), events: events, interval: 0.1) { _ in silent.fulfill() }
        stopped.update([file], interval: 0.1); _ = await stopped.activeWatchCount()
        let handle = try XCTUnwrap(events.history(file).last)
        stopped.stop(); _ = await stopped.activeWatchCount(); handle.changed(ActivityFileEvent())
        await fulfillment(of: [silent], timeout: 0.2)
    }
}
