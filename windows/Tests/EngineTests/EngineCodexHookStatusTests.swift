@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore

private final class HookStatusFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [EngineSnapshot] = []
    func append(_ data: Data) {
        guard let value = try? JSONDecoder().decode(EngineSnapshot.self, from: data) else { return }
        lock.withLock { values.append(value) }
    }
    func all() -> [EngineSnapshot] { lock.withLock { values } }
}
private final class HookTrust: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [String]
    init(_ value: [String]) { current = value }
    var value: [String] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

final class EngineCodexHookStatusTests: XCTestCase {
    private func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
    }

    /// Hooks waiting for approval in Codex show in Settings and the collapsed bar,
    /// and the one notice asking for it is sent once, even across setup passes.
    func testApprovalRaisesTheWarningAndSendsOneNotice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-codex-hooks " + UUID().uuidString)
        let home = root.appendingPathComponent("codex"), marker = root.appendingPathComponent("notices/codex-hooks-approval-v1")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let count = CodexHookEvent.Kind.allCases.count
        let trust = HookTrust(Array(repeating: "untrusted", count: count))
        // Setup takes a moment, as Codex's own calls do: the initialization that
        // starts it also replaces Codex's source and must not cancel it.
        let services = EngineCodexHookServices(apply: { _, _, enabled in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return .init(supportsHooks: true, installed: enabled, trust: enabled ? trust.value : nil)
        }, trust: { _, _ in trust.value }, noticeMarker: marker)
        let frames = HookStatusFrames(), date = Date()
        let runtime = EngineRuntime(demo: false, now: { date }, dismissalStore: nil, codexHookServices: services, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": EngineCodexSourceReport.path(home)]))
        func state() -> String? { frames.all().last?.codexHooks?.state }
        func warned() -> Bool { frames.all().last?.compactWarnings?.contains { $0.kind == .codexHooks } == true }
        func notices() -> Int { frames.all().flatMap(\.notices).filter { $0.id == "codex:hooks-approval" }.count }

        let approval = try await TestWait.until { state() == "needsApproval" }
        XCTAssertTrue(approval, "Untrusted hooks must ask for approval")
        XCTAssertEqual(frames.all().last?.codexHooks?.pending, count)
        XCTAssertTrue(warned(), "The collapsed bar shows that Codex needs the user")
        XCTAssertEqual(notices(), 1); XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        // A retry clears the result at once, so a later approval state comes from a new setup pass.
        let mark = frames.all().count
        _ = await runtime.receive(try command("retryCodexHooks"))
        let again = try await TestWait.until { frames.all().dropFirst(mark).contains { $0.codexHooks?.state == "needsApproval" } }
        XCTAssertTrue(again, "A second setup pass still needs approval")
        XCTAssertEqual(notices(), 1, "The approval notice is sent once")

        trust.value = Array(repeating: "trusted", count: count)
        _ = await runtime.receive(try command("retryCodexHooks"))
        let running = try await TestWait.until { state() == "running" }
        XCTAssertTrue(running, "Trusted hooks run")
        XCTAssertFalse(warned(), "Running hooks raise no warning")
        await runtime.stop()
    }

    /// Allowing the hooks in Codex changes its config; Pacer then asks Codex for
    /// their trust alone, and turns from before the approval are not a silent hook.
    func testAConfigChangeFindsTheApprovalAndEarlierTurnsDoNotCountAsSilence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-codex-trust " + UUID().uuidString)
        let home = root.appendingPathComponent("codex")
        defer { try? FileManager.default.removeItem(at: root) }
        // A turn Codex ran a moment ago, before the user allowed the hooks.
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy/MM/dd"
        let day = home.appendingPathComponent("sessions/" + formatter.string(from: Date()))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data().write(to: day.appendingPathComponent("rollout-019a0000-0000-7000-8000-000000000041.jsonl"))
        let count = CodexHookEvent.Kind.allCases.count
        let trust = HookTrust(Array(repeating: "untrusted", count: count)), setups = HookTrust([])
        let services = EngineCodexHookServices(apply: { _, _, enabled in
            setups.value += ["apply"]
            return .init(supportsHooks: true, installed: enabled, trust: enabled ? trust.value : nil)
        }, trust: { _, _ in trust.value }, opensSettings: { true })
        let frames = HookStatusFrames(), date = Date()
        let runtime = EngineRuntime(demo: false, now: { date }, dismissalStore: nil, codexHookServices: services, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": EngineCodexSourceReport.path(home)]))
        let approval = try await TestWait.until { frames.all().last?.codexHooks?.state == "needsApproval" }
        XCTAssertTrue(approval)
        XCTAssertEqual(frames.all().last?.codexHooks?.opensSettings, true, "Settings can open Codex while approval is pending")

        trust.value = Array(repeating: "trusted", count: count)
        try Data("[features]\n".utf8).write(to: CodexHookTrustWatch.trustFile(home: home))
        let running = try await TestWait.until { frames.all().last?.codexHooks?.state == "running" }
        XCTAssertTrue(running, "The config change leads to the new trust, and the earlier turn is not a silent hook")
        XCTAssertNil(frames.all().last?.codexHooks?.opensSettings)
        XCTAssertEqual(setups.value, ["apply"], "Only the trust is read again; setup does not run")
        await runtime.stop()
    }
}
