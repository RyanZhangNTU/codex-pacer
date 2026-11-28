@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore

private final class HookStatusFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [EngineSnapshot] = []
    private var lastSnapshot: Data?
    private var errorCode: String?
    func append(_ data: Data) {
        if let value = try? JSONDecoder().decode(EngineSnapshot.self, from: data) {
            lock.withLock { values.append(value); lastSnapshot = data }
        } else if let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any], reply["type"] as? String == "error" {
            lock.withLock { errorCode = reply["code"] as? String }
        }
    }
    func wireHooks() throws -> [String: Any]? {
        let bytes = try XCTUnwrap(lock.withLock { lastSnapshot })
        return (try JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["codexHooks"] as? [String: Any]
    }
    var lastError: String? { lock.withLock { errorCode } }
    func all() -> [EngineSnapshot] { lock.withLock { values } }
}
private func hookTrust(_ state: String, set: CodexHookSet = .legacy) -> [CodexHookTrust] {
    set.events.map { CodexHookTrust(event: $0, state: state) }
}

/// Codex's answers to `hooks/list`, one per call; the last repeats.
private final class TrustAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [[CodexHookTrust]?]
    private var calls = 0
    init(_ answers: [[CodexHookTrust]?]) { self.answers = answers }
    func next() -> [CodexHookTrust]? {
        lock.withLock {
            calls += 1
            return answers.count > 1 ? answers.removeFirst() : answers.first ?? nil
        }
    }
    func replace(_ value: [[CodexHookTrust]?]) { lock.withLock { answers = value } }
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
        let trust = TrustAnswers([hookTrust("untrusted")])
        // Setup takes a moment, as Codex's own calls do: the initialization that
        // starts it also replaces Codex's source and must not cancel it.
        let services = EngineCodexHookServices(apply: { _, _, enabled, _ in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return .init(supportsHooks: true, installed: enabled, trust: enabled ? trust.next() : nil)
        }, trust: { _, _ in trust.next() }, noticeMarker: marker)
        let frames = HookStatusFrames(), date = Date()
        let runtime = EngineRuntime(demo: false, now: { date }, dismissalStore: nil, codexHookServices: services, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": EngineCodexSourceReport.path(home)]))
        func state() -> String? { frames.all().last?.codexHooks?.state }
        func warned() -> Bool { frames.all().last?.compactWarnings?.contains { $0.kind == .codexHooks } == true }
        func notices() -> Int { frames.all().flatMap(\.notices).filter { $0.id == "codex:hooks-approval" }.count }

        let approval = try await TestWait.until { state() == "needsApproval" }
        XCTAssertTrue(approval, "Untrusted hooks must ask for approval")
        XCTAssertEqual(frames.all().last?.codexHooks?.pending, 7)
        XCTAssertEqual(frames.all().last?.codexHooks?.updateAvailable, false)
        XCTAssertTrue(warned(), "The collapsed bar shows that Codex needs the user")
        XCTAssertEqual(notices(), 1); XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        // A retry clears the result at once, so a later approval state comes from a new setup pass.
        let mark = frames.all().count
        _ = await runtime.receive(try command("retryCodexHooks"))
        let again = try await TestWait.until { frames.all().dropFirst(mark).contains { $0.codexHooks?.state == "needsApproval" } }
        XCTAssertTrue(again, "A second setup pass still needs approval")
        XCTAssertEqual(notices(), 1, "The approval notice is sent once")

        trust.replace([hookTrust("trusted")])
        _ = await runtime.receive(try command("retryCodexHooks"))
        let running = try await TestWait.until { state() == "running" }
        XCTAssertTrue(running, "Trusted hooks run")
        XCTAssertFalse(warned(), "Running hooks raise no warning")
        await runtime.stop()
    }

    func testHealthyLegacySnapshotOffersUpdateAndCommandStartsNineHookApproval() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-update-hooks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let marker = home.appendingPathComponent("notice")
        let updates = TrustAnswers([hookTrust("modified", set: .full)])
        let services = EngineCodexHookServices(apply: { _, _, enabled, update in
            .init(supportsHooks: true, installed: enabled, trust: update ? updates.next() : hookTrust("trusted"),
                  hookSet: update ? .full : .legacy, supportsCompaction: true)
        }, trust: { _, _ in hookTrust("trusted", set: .full) }, noticeMarker: marker, opensSettings: { true })
        let frames = HookStatusFrames(), date = Date()
        let runtime = EngineRuntime(demo: false, now: { date }, dismissalStore: nil, codexHookServices: services, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": EngineCodexSourceReport.path(home)]))
        let available = try await TestWait.until { frames.all().last?.codexHooks?.updateAvailable == true }
        XCTAssertTrue(available)
        let hooks = try XCTUnwrap(frames.all().last?.codexHooks)
        XCTAssertEqual(hooks.state, "running")
        let wire = try XCTUnwrap(frames.wireHooks())
        XCTAssertEqual(wire["updateAvailable"] as? Bool, true)
        XCTAssertNil(wire["optionalPending"])
        XCTAssertNil(hooks.opensSettings)
        XCTAssertFalse(frames.all().contains { $0.compactWarnings?.contains { $0.kind == .codexHooks } == true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        _ = await runtime.receive(try command("updateCodexHooks"))
        let pending = try await TestWait.until { frames.all().last?.codexHooks?.pending == 9 }
        XCTAssertTrue(pending)
        XCTAssertEqual(frames.all().last?.codexHooks?.state, "needsApproval")
        XCTAssertEqual(frames.all().last?.codexHooks?.updateAvailable, false)
        XCTAssertEqual(frames.all().last?.codexHooks?.opensSettings, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        _ = await runtime.receive(try command("updateCodexHooks"))
        XCTAssertEqual(frames.lastError, "codexHooksUnavailable")
        XCTAssertEqual(updates.count, 1)
        try Data("# trusted".utf8).write(to: CodexHookTrustWatch.trustFile(home: home))
        let approved = try await TestWait.until { frames.all().last?.codexHooks?.state == "running" }
        XCTAssertTrue(approved)
        XCTAssertEqual(frames.all().last?.codexHooks?.updateAvailable, false)
        await runtime.stop()
    }

    /// A Codex too old for hooks says whether Codex Desktop is installed: its
    /// update step then opens Codex itself, and the CLI alone gets Codex's page.
    func testAnOldCodexSaysWhetherCodexDesktopCanUpdateIt() async throws {
        for desktop in [true, false] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-codex-old " + UUID().uuidString)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let services = EngineCodexHookServices(apply: { _, _, _, _ in .init(supportsHooks: false, installed: nil, trust: nil) },
                                                   trust: { _, _ in nil }, opensSettings: { desktop })
            let frames = HookStatusFrames(), date = Date()
            let runtime = EngineRuntime(demo: false, now: { date }, dismissalStore: nil, codexHookServices: services, output: { frames.append($0) })
            _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": EngineCodexSourceReport.path(home)]))
            let old = try await TestWait.until { frames.all().last?.codexHooks?.state == "needsCodexUpdate" }
            XCTAssertTrue(old, "A Codex without hooks asks for its update")
            XCTAssertEqual(frames.all().last?.codexHooks?.opensSettings, desktop ? true : nil, "Codex Desktop installed: \(desktop)")
            await runtime.stop()
        }
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
        let trust = TrustAnswers([hookTrust("untrusted")]), setups = TrustAnswers([hookTrust("untrusted")])
        let services = EngineCodexHookServices(apply: { _, _, enabled, _ in
            .init(supportsHooks: true, installed: enabled, trust: enabled ? setups.next() : nil)
        }, trust: { _, _ in trust.next() }, opensSettings: { true })
        let frames = HookStatusFrames(), date = Date()
        let runtime = EngineRuntime(demo: false, now: { date }, dismissalStore: nil, codexHookServices: services, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": EngineCodexSourceReport.path(home)]))
        let approval = try await TestWait.until { frames.all().last?.codexHooks?.state == "needsApproval" }
        XCTAssertTrue(approval)
        XCTAssertEqual(frames.all().last?.codexHooks?.opensSettings, true, "Settings can open Codex while approval is pending")

        trust.replace([hookTrust("trusted")])
        try Data("[features]\n".utf8).write(to: CodexHookTrustWatch.trustFile(home: home))
        let running = try await TestWait.until { frames.all().last?.codexHooks?.state == "running" }
        XCTAssertTrue(running, "The config change leads to the new trust, and the earlier turn is not a silent hook")
        XCTAssertNil(frames.all().last?.codexHooks?.opensSettings)
        XCTAssertEqual(setups.count, 1, "Only the trust is read again; setup does not run")
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
        // The first retry fails as well; the next answer reports the approval pending.
        let answers = TrustAnswers([nil, hookTrust("untrusted")]), setups = TrustAnswers([nil])
        let services = EngineCodexHookServices(apply: { _, _, enabled, _ in
            .init(supportsHooks: true, installed: enabled, trust: setups.next())
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

        answers.replace([hookTrust("trusted")])
        try Data("[features]\n# allowed\n".utf8).write(to: trustFile)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: trustFile.path)
        let running = try await TestWait.until { state() == "running" }
        XCTAssertTrue(running, "Allowed hooks run")
        XCTAssertEqual(setups.count, 1, "A failed trust read never sets the plugin up again")
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
        let trusted = hookTrust("trusted")
        let services = EngineCodexHookServices(apply: { _, _, enabled, _ in
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
