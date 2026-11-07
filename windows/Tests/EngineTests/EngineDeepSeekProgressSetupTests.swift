import Foundation
import XCTest
@testable import PacerCore
@testable import PacerEngineSupport

final class EngineDeepSeekProgressSetupTests: XCTestCase {
    private final class Frames: @unchecked Sendable {
        let lock = NSLock()
        var setup: DeepSeekProgressSetupStatus?
        func append(_ data: Data) {
            guard let value = try? JSONDecoder().decode(EngineSnapshot.self, from: data) else { return }
            lock.lock(); setup = value.deepseekProgressSetup; lock.unlock()
        }
        var latest: DeepSeekProgressSetupStatus? { lock.lock(); defer { lock.unlock() }; return setup }
    }
    private func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": "synthetic-deepseek-progress", "method": method, "params": params])
    }

    func testSwitchTurnedOffJustBeforeShutdownStillRemovesTheHarnessEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-dsh-engine-" + UUID().uuidString)
        let home = root.appendingPathComponent("dsh")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("profiles"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let patch = home.appendingPathComponent("cordis.patch.yml"), original = Data("- id: user\n".utf8)
        try original.write(to: patch)
        let frames = Frames()
        let runtime = EngineRuntime(demo: false, dismissalStore: nil, managesDeepSeekProgress: true,
            installationDetection: { .init(codexInstalled: false, claudeInstalled: false, deepseekInstalled: true) }, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["deepseek"], "deepseekProgressRing": true,
            "claudeHome": EngineCodexSourceReport.path(root), "codexHome": EngineCodexSourceReport.path(root),
            "deepseekHome": EngineCodexSourceReport.path(home)]))
        let ready = (try? await TestWait.until { frames.latest == .ready }) ?? false
        XCTAssertTrue(ready)
        XCTAssertNotEqual(try Data(contentsOf: patch), original)
        // Quit right after the switch turns off, before its setup has had a chance to run.
        _ = await runtime.receive(try command("configure", ["deepseekProgressRing": false]))
        _ = await runtime.receive(try command("shutdown"))
        XCTAssertEqual(try Data(contentsOf: patch), original, "Harness must not keep loading Pacer's reporter after Pacer exits")
        let folder = home.appendingPathComponent("pacer/deepseek-progress")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("enabled").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("report-progress.mjs").path))
    }
}
