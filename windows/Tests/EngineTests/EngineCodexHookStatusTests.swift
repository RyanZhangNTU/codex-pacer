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

/// Codex's answers to `hooks/list`, one per call; the last repeats.
private final class TrustAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [[String]?]
    private var calls = 0
    init(_ answers: [[String]?]) { self.answers = answers }
    func next() -> [String]? {
        lock.withLock {
            calls += 1
            return answers.count > 1 ? answers.removeFirst() : answers.first ?? nil
        }
    }
    func replace(_ value: [[String]?]) { lock.withLock { answers = value } }
    var count: Int { lock.withLock { calls } }
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

    /// The plugin installed, but Codex did not answer `hooks/list`: the hooks'
    /// trust is unknown, so they do not show as running. Pacer asks Codex for the
    /// trust alone again, shows the approval when Codex reports it pending and
    /// running once the user allowed it, without setting the plugin up again.
    func testAFailedTrustReadIsAskedAgainWithoutSettingTheHooksUpAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-codex-trust-retry " + UUID().uuidString)
        let home = root.appendingPathComponent("codex"), marker = root.appendingPathComponent("notices/codex-hooks-approval-v1")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let count = CodexHookEvent.Kind.allCases.count
        // The first retry fails as well; the next answer reports the approval pending.
        let answers = TrustAnswers([nil, Array(repeating: "untrusted", count: count)]), setups = HookTrust([])
        let services = EngineCodexHookServices(apply: { _, _, enabled in
            setups.value += ["apply"]
            return .init(supportsHooks: true, installed: enabled, trust: nil)
        }, trust: { _, _ in answers.next() }, noticeMarker: marker, opensSettings: { true })
        let frames = HookStatusFrames(), date = Date()
        let runtime = EngineRuntime(demo: false, now: { date }, dismissalStore: nil, codexHookServices: services, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": EngineCodexSourceReport.path(home)]))
        func state() -> String? { frames.all().last?.codexHooks?.state }

        let retried = try await TestWait.until { answers.count >= 1 }
        XCTAssertTrue(retried, "The trust is asked again without waiting for a change in Codex")
        XCTAssertFalse(frames.all().contains { $0.codexHooks?.state == "running" }, "Hooks whose trust is unknown are not running")
        XCTAssertEqual(state(), "notInstalled", "Settings says the hooks are still being set up")

        let trustFile = CodexHookTrustWatch.trustFile(home: home)
        try Data("[features]\n".utf8).write(to: trustFile)
        let approval = try await TestWait.until { state() == "needsApproval" }
        XCTAssertTrue(approval, "The next answer shows the approval")
        XCTAssertEqual(frames.all().last?.codexHooks?.opensSettings, true)
        XCTAssertEqual(frames.all().flatMap(\.notices).filter { $0.id == "codex:hooks-approval" }.count, 1)

        answers.replace([Array(repeating: "trusted", count: count)])
        try Data("[features]\n# allowed\n".utf8).write(to: trustFile)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: trustFile.path)
        let running = try await TestWait.until { state() == "running" }
        XCTAssertTrue(running, "Allowed hooks run")
        XCTAssertEqual(setups.value, ["apply"], "A failed trust read never sets the plugin up again")
        await runtime.stop()
    }

    /// After approval, a turn without a hook row shows the hooks as silent; the
    /// next hook row clears that at once, without waiting for the minute check.
    func testANewHookRowClearsASilentHookAtOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-codex-silent " + UUID().uuidString)
        let home = root.appendingPathComponent("codex")
        defer { try? FileManager.default.removeItem(at: root) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy/MM/dd"
        let day = home.appendingPathComponent("sessions/" + formatter.string(from: Date()))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        // Codex ran a turn and no hook row followed.
        let rollout = day.appendingPathComponent("rollout-2026-11-21T10-00-00-019a0000-0000-7000-8000-000000000051.jsonl")
        try Data().write(to: rollout)
        let trusted = Array(repeating: "trusted", count: CodexHookEvent.Kind.allCases.count)
        let services = EngineCodexHookServices(apply: { _, _, enabled in
            .init(supportsHooks: true, installed: enabled, trust: enabled ? trusted : nil)
        }, trust: { _, _ in trusted })
        // The clock stands still, so the minute check never comes due again.
        let frames = HookStatusFrames(), date = Date()
        let runtime = EngineRuntime(demo: false, now: { date }, dismissalStore: nil, codexHookServices: services, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": EngineCodexSourceReport.path(home)]))
        func state() -> String? { frames.all().last?.codexHooks?.state }
        func warned() -> Bool { frames.all().last?.compactWarnings?.contains { $0.kind == .codexHooks } == true }

        let silent = try await TestWait.until { state() == "notRunning" }
        XCTAssertTrue(silent, "A turn without a hook row after approval is a silent hook")
        XCTAssertTrue(warned())

        try CodexHookFixture.announce([rollout], home: home, turn: "turn-1", at: date)
        let cleared = try await TestWait.until { state() == "running" }
        XCTAssertTrue(cleared, "The hook row clears the notice without waiting for the minute check")
        XCTAssertFalse(warned())
        await runtime.stop()
    }
}
