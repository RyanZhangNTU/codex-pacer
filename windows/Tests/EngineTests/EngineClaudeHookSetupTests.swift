import Foundation
import XCTest
@testable import PacerCore

final class EngineClaudeHookSetupTests: XCTestCase {
    private actor Gate {
        var calls = 0
        var pending: [CheckedContinuation<EngineClaudeHookSetup, Never>?] = []
        func run(_ action: EngineClaudeHookServices.Action, _ home: URL) async -> EngineClaudeHookSetup {
            calls += 1
            return await withCheckedContinuation { pending.append($0) }
        }
        func complete(_ index: Int, _ state: EngineClaudeHookSetup.State) {
            guard pending.indices.contains(index), let continuation = pending[index] else { return }
            pending[index] = nil; continuation.resume(returning: .init(state))
        }
    }
    private final class Frames: @unchecked Sendable {
        let lock = NSLock()
        var values: [EngineSnapshot] = []
        func append(_ data: Data) {
            guard let value = try? JSONDecoder().decode(EngineSnapshot.self, from: data) else { return }
            lock.lock(); values.append(value); lock.unlock()
        }
        var state: EngineClaudeHookSetup.State? { lock.lock(); defer { lock.unlock() }; return values.last?.claudeSetup?.state }
    }
    private func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": "synthetic-setup", "method": method, "params": params])
    }
    private func wait(_ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline { if await condition() { return true }; try? await Task.sleep(nanoseconds: 10_000_000) }
        return false
    }
    func testPendingSetupDoesNotBlockInitializeOrRetryAndLateRepliesAreIgnored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-hook-binding-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate(), frames = Frames(), initialized = expectation(description: "initialize returns while helper has not replied")
        let services = EngineClaudeHookServices { action, home in await gate.run(action, home) }
        let runtime = EngineRuntime(demo: false, dismissalStore: nil, claudeHookServices: services,
            installationDetection: { .init(codexInstalled: false, claudeInstalled: false, deepseekInstalled: false) }, output: { frames.append($0) })
        let initialize = try command("initialize", ["enabledProviders": ["claude"], "claudeHome": EngineCodexSourceReport.path(root),
            "codexHome": EngineCodexSourceReport.path(root), "deepseekHome": EngineCodexSourceReport.path(root)])
        let initialization = Task { _ = await runtime.receive(initialize); initialized.fulfill() }
        await fulfillment(of: [initialized], timeout: 2)
        await initialization.value
        let firstStarted = await wait { await gate.calls == 1 }
        XCTAssertTrue(firstStarted); XCTAssertEqual(frames.state, .settingUp)
        _ = await runtime.receive(try command("configure", ["hideProjects": true]))
        let afterConfiguration = await gate.calls
        XCTAssertEqual(afterConfiguration, 1, "Unrelated preferences cannot launch another installer or poll the helper")
        _ = await runtime.receive(try command("retryClaudeSetup"))
        let retried = await wait { await gate.calls == 2 }
        XCTAssertTrue(retried)
        await gate.complete(0, .failed)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(frames.state, .settingUp, "Cancelled attempts cannot overwrite the current setup state")
        await gate.complete(1, .ready)
        let ready = await wait { frames.state == .ready }
        XCTAssertTrue(ready)
        await runtime.stop()
    }
    func testUnresponsiveNativeHelperHasBoundedAsyncDeadline() async throws {
        let source = try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_CLAUDE_PYTHON_PACKAGE"])
        let start = Date()
        let result = await WindowsSubprocess.capture(executable: URL(fileURLWithPath: source).appendingPathComponent("python.exe"),
            arguments: ["-S", "-c", "import time; time.sleep(60)"], timeout: 0.2, limit: 4096)
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "A missing helper reply cannot block the engine command loop")
    }
    func testSleepRevokesPendingSetupAndWakeStartsANewOwnedAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-hook-wake-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate(), frames = Frames()
        let runtime = EngineRuntime(demo: false, dismissalStore: nil,
            claudeHookServices: .init { action, home in await gate.run(action, home) },
            installationDetection: { .init(codexInstalled: false, claudeInstalled: false, deepseekInstalled: false) }, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["claude"],
            "claudeHome": EngineCodexSourceReport.path(root), "codexHome": EngineCodexSourceReport.path(root),
            "deepseekHome": EngineCodexSourceReport.path(root)]))
        let first = await wait { await gate.calls == 1 }
        XCTAssertTrue(first)
        await runtime.prepareForSleep()
        await runtime.resumeAfterSleep()
        let second = await wait { await gate.calls == 2 }
        XCTAssertTrue(second)
        XCTAssertEqual(frames.state, .settingUp)
        await gate.complete(0, .failed)
        await gate.complete(1, .ready)
        let ready = await wait { frames.state == .ready }
        XCTAssertTrue(ready, "A cancelled pre-sleep helper cannot replace the wake attempt")
        await runtime.stop()
    }
}
