import XCTest
@testable import PacerMacSupport

final class DurableRefreshTests: XCTestCase {
    private func profile() throws -> URL {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-durable-refresh-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("pacer/codex-progress"),
                                                withIntermediateDirectories: true)
        return home
    }

    private func existingExecutor(_ home: URL) -> MacDurableExecutor {
        .init(pid: 0, desktopPID: 0, startedAt: .distantPast, environmentID: "synthetic",
              application: home.appendingPathComponent("Codex.app"))
    }

    func testBusyRefreshPersistsUntilDesktopStartsANewExecutor() async throws {
        let home = try profile()
        defer { try? FileManager.default.removeItem(at: home) }
        let refresh = MacDurableRefresh()
        let marker = home.appendingPathComponent("pacer/codex-progress/executor-refresh.json")
        let syntheticApp = home.appendingPathComponent("Codex.app")
        await refresh.begin(home: home)
        let recorded = await refresh.finish(home: home, changed: true, enabled: true)
        XCTAssertTrue(recorded)
        await refresh.observe(home: home, executor: existingExecutor(home), catalogIdle: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        await refresh.observe(home: home, executor: .init(pid: 0, desktopPID: 0, startedAt: .distantFuture,
            environmentID: "synthetic", application: syntheticApp), catalogIdle: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testNewVerifiedTurnConfirmsInPlaceInstallation() async throws {
        let home = try profile()
        defer { try? FileManager.default.removeItem(at: home) }
        let refresh = MacDurableRefresh()
        let marker = home.appendingPathComponent("pacer/codex-progress/executor-refresh.json")
        let oldTurn = Date()
        await refresh.begin(home: home)
        let recorded = await refresh.finish(home: home, changed: true, enabled: true)
        XCTAssertTrue(recorded)

        await refresh.observe(home: home, executor: existingExecutor(home), catalogIdle: false,
                              verifiedReportTurnStartedAt: oldTurn)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        await refresh.observe(home: home, executor: existingExecutor(home), catalogIdle: false,
                              verifiedReportTurnStartedAt: Date())
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testReportDoesNotConfirmUninstall() async throws {
        let home = try profile()
        defer { try? FileManager.default.removeItem(at: home) }
        let refresh = MacDurableRefresh()
        let marker = home.appendingPathComponent("pacer/codex-progress/executor-refresh.json")
        await refresh.begin(home: home)
        let recorded = await refresh.finish(home: home, changed: true, enabled: false)
        XCTAssertTrue(recorded)

        await refresh.observe(home: home, executor: existingExecutor(home), catalogIdle: false,
                              verifiedReportTurnStartedAt: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}
