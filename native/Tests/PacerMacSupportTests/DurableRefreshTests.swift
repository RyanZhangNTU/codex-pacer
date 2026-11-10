import XCTest
@testable import PacerMacSupport

final class DurableRefreshTests: XCTestCase {
    func testBusyRefreshPersistsUntilDesktopStartsANewExecutor() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-durable-refresh-" + UUID().uuidString, isDirectory: true)
        let folder = home.appendingPathComponent("pacer/codex-progress")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let refresh = MacDurableRefresh()
        let marker = folder.appendingPathComponent("executor-refresh.json")
        let syntheticApp = home.appendingPathComponent("Codex.app")
        await refresh.begin(home: home)
        let recorded = await refresh.finish(home: home, changed: true)
        XCTAssertTrue(recorded)
        await refresh.observe(home: home, executor: .init(pid: 0, desktopPID: 0, startedAt: .distantPast,
            environmentID: "synthetic", application: syntheticApp), catalogIdle: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        await refresh.observe(home: home, executor: .init(pid: 0, desktopPID: 0, startedAt: .distantFuture,
            environmentID: "synthetic", application: syntheticApp), catalogIdle: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
