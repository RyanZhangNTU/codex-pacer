import XCTest
@testable import PacerCore
@testable import PacerIsland
import PacerMacSupport
import PacerTestSupport

/// A Dot poll the test drives: it records each start and stop, and reports
/// whatever catalog and turns the test hands it.
private final class ScriptedDot: @unchecked Sendable {
    private let lock = NSLock()
    private var catalog: (@Sendable (DurableActivityCatalog?) -> Void)?
    private var history: (@Sendable (String, [DurableTurnHistory]) -> Void)?
    private(set) var homes: [URL] = []
    private(set) var running = 0

    var starts: Int { lock.withLock { homes.count } }
    var active: Int { lock.withLock { running } }
    var lastHome: URL? { lock.withLock { homes.last } }

    func observe(home: URL, catalog: @escaping @Sendable (DurableActivityCatalog?) -> Void,
                 history: @escaping @Sendable (String, [DurableTurnHistory]) -> Void) async {
        lock.withLock { homes.append(home); running += 1; self.catalog = catalog; self.history = history }
        try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        lock.withLock { running -= 1 }
    }
    func report(_ value: DurableActivityCatalog) { lock.withLock { catalog }?(value) }
    func report(_ scope: String, _ turns: [DurableTurnHistory]) { lock.withLock { history }?(scope, turns) }
}

/// The Mac host around Pacer's Codex hooks: which rollouts it watches, when it
/// recomputes the hooks' status, and which Codex home it installs them in.
@MainActor
final class CodexHookHostTests: XCTestCase {
    private let first = "019a0000-0000-7000-8000-0000000000a1"
    private let resumed = "019a0000-0000-7000-8000-0000000000a2"

    private func temporaryHome(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-\(label)-" + UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return home
    }

    private func model(home: URL, durable: MacDurableMonitor = MacDurableMonitor { _, _, _, _ in }) throws -> IslandModel {
        let domain = testDefaultsName("CodexHookHostTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock { removeTestDefaults(domain) }
        ProviderModules(codexMode: .enabled, claudeMode: .disabled, deepseekMode: .disabled).save(to: defaults)
        defaults.set(home.path, forKey: "codexHome")
        defaults.set(false, forKey: "monitorSSH"); defaults.set(false, forKey: IslandModel.monitorsDurableKey)
        defaults.set("/nonexistent/codex", forKey: "codexExecutable")
        defaults.set(false, forKey: "systemNotifications")
        let model = IslandModel(demo: false, defaults: defaults, installation: .init(codexInstalled: true, claudeInstalled: false),
            completionDismissalStore: CompletionDismissalStore(fileURL: home.deletingLastPathComponent().appendingPathComponent("dismissals.json")),
            durableMonitor: durable)
        model.hostApplicationResolver = { _, _, _ in [:] }
        addTeardownBlock { await model.shutdown() }
        return model
    }

    private func line(_ type: String, _ payload: [String: Any], at date: Date) throws -> Data {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": formatter.string(from: date), "payload": payload]) + Data([10])
    }

    /// A rollout with a running turn in the given day folder.
    private func rollout(_ thread: String, day: String, home: URL, at date: Date) throws -> URL {
        let folder = home.appendingPathComponent("sessions/" + day, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("rollout-2026-11-21T10-00-00-\(thread).jsonl")
        try (line("session_meta", ["id": thread, "originator": "Codex Desktop", "cwd": "/fixture"], at: date)
            + line("event_msg", ["type": "task_started", "turn_id": "turn-1"], at: date)).write(to: file)
        return file
    }

    /// Appends one UserPromptSubmit row naming `rollout`, as Pacer's hook does.
    private func announce(_ rollout: URL, thread: String, home: URL, at date: Date, event: String = "UserPromptSubmit") throws {
        let spool = CodexHookSpool.current(home: home)
        try FileManager.default.createDirectory(at: spool.deletingLastPathComponent(), withIntermediateDirectories: true)
        let row: [String: Any] = ["v": 1, "hook": 1, "at": date.timeIntervalSince1970, "event": event, "thread": thread,
                                  "turn": "turn-1", "agent": NSNull(), "agentType": NSNull(), "transcript": rollout.path,
                                  "agentTranscript": NSNull(), "approval": NSNull(), "reason": NSNull()]
        let data = try JSONSerialization.data(withJSONObject: row) + Data([10])
        if let handle = try? FileHandle(forWritingTo: spool) {
            try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
        } else {
            try data.write(to: spool)
        }
    }

    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
    }

    func testARolloutAHookNamesInASpoolAppendIsWatchedForItsNextWrite() async throws {
        let home = try temporaryHome("codex-watch")
        let model = try model(home: home)
        let start = Date().addingTimeInterval(-30)
        let today = try rollout(first, day: "2026/11/21", home: home, at: start)
        try announce(today, thread: first, home: home, at: start)
        model.refreshActivity()
        try await TestWait.until { model.activities.contains { $0.threadID == self.first } }
        XCTAssertTrue(model.watchedLogURLs.contains(CodexHookSpool.current(home: home)))

        // A week-old conversation continues: only the spool's append names its rollout,
        // and the read that append causes is a metrics read.
        let older = try rollout(resumed, day: "2026/11/14", home: home, at: start.addingTimeInterval(1))
        try announce(older, thread: resumed, home: home, at: start.addingTimeInterval(1))
        model.refreshActivity(metricsOnly: true)
        try await TestWait.until { model.activities.contains { $0.threadID == self.resumed } }
        let watched = try await TestWait.until { model.watchedLogURLs.contains(older.standardizedFileURL) || model.watchedLogURLs.contains(older) }
        XCTAssertTrue(watched, "The rollout found by the metrics read is watched")

        // Only that rollout changes now: Codex asks the user a question. No hook row, no panel.
        let question = #"{"questions":[{"title":"PRIVATE question","options":["PRIVATE option"]}]}"#
        try append(line("response_item", ["type": "function_call", "name": "request_user_input_async", "call_id": "call-1", "arguments": question],
                        at: start.addingTimeInterval(2))
                   + line("response_item", ["type": "function_call_output", "call_id": "call-1", "output": #"{"accepted":true}"#],
                          at: start.addingTimeInterval(3)), to: older)
        let asked = try await TestWait.until { model.pendingInputRequests.contains { $0.threadID == self.resumed } }
        XCTAssertTrue(asked, "The question shows from the rollout's own file event")
    }

    func testSpoolAppendsStillReachTheModelAfterSleepAndRotation() async throws {
        let home = try temporaryHome("codex-rewatch"), model = try model(home: home)
        let start = Date().addingTimeInterval(-60)
        let original = try rollout(first, day: "2026/11/21", home: home, at: start)
        let other = try rollout(resumed, day: "2026/11/14", home: home, at: start)
        try announce(original, thread: first, home: home, at: start)
        model.refreshActivity()
        let running = try await TestWait.until { model.activities.contains { $0.threadID == self.first && $0.phase == .running } }
        XCTAssertTrue(running)

        await model.prepareForSleep()
        // Only the contents change during sleep. The wake read returns the same URLs.
        try append(line("event_msg", ["type": "task_complete", "turn_id": "turn-1"], at: Date()), to: original)
        model.resumeAfterSleep()
        let woke = try await TestWait.until { model.pendingCompletions.contains { $0.threadID == self.first } }
        XCTAssertTrue(woke)
        try announce(other, thread: resumed, home: home, at: start.addingTimeInterval(2))
        let resumedTurn = try await TestWait.until { model.activities.contains { $0.threadID == self.resumed && $0.phase == .running } }
        XCTAssertTrue(resumedTurn, "An append to the existing spool wakes the collapsed panel after sleep")

        try FileManager.default.moveItem(at: CodexHookSpool.current(home: home), to: CodexHookSpool.previous(home: home))
        try announce(other, thread: resumed, home: home, at: start.addingTimeInterval(3), event: "SessionEnd")
        let closed = try await TestWait.until { !model.activities.contains { $0.threadID == self.resumed && $0.phase == .running } }
        XCTAssertTrue(closed)
        try announce(other, thread: resumed, home: home, at: start.addingTimeInterval(4))
        let reopened = try await TestWait.until { model.activities.contains { $0.threadID == self.resumed && $0.phase == .running } }
        XCTAssertTrue(reopened, "Only the replacement spool receives this append")
    }

    func testQuietTurnExpiresWithoutAnotherFileEvent() async throws {
        let home = try temporaryHome("codex-expiry"), model = try model(home: home)
        let start = Date().addingTimeInterval(-3 * 3600 + 5)
        let file = try rollout(first, day: "2026/11/21", home: home, at: start)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try announce(file, thread: first, home: home, at: start)
        model.refreshActivity()
        let appeared = try await TestWait.until { model.activities.contains { $0.threadID == self.first && $0.phase == .running } }
        XCTAssertTrue(appeared)
        let expired = try await TestWait.until { !model.activities.contains { $0.threadID == self.first && $0.phase == .running } }
        XCTAssertTrue(expired, "The deadline alone must release the running task")
    }

    func testRouteRefreshesKeepOneDotPollSoATurnThatEndsBetweenPollsCompletesOnce() async throws {
        let home = try temporaryHome("codex-dot")
        let dot = ScriptedDot()
        let monitor = MacDurableMonitor { home, catalog, history, _ in await dot.observe(home: home, catalog: catalog, history: history) }
        let model = try model(home: home, durable: monitor)
        model.defaults.set(true, forKey: IslandModel.monitorsDurableKey)
        let thread = "019a0000-0000-7000-8000-0000000000d1", start = Date().addingTimeInterval(-60)
        func turn(_ status: DurableTurnHistory.Status, completed: Double? = nil) -> DurableTurnHistory {
            DurableTurnHistory(threadID: thread, name: "Synthetic Dot task", turnID: "turn-1", rootTurnID: nil, status: status,
                               startedAt: start, completedAt: completed.map { start.addingTimeInterval($0) }, report: nil)
        }

        // Routes are refreshed every 30 seconds, and each refresh syncs Dot.
        for _ in 0..<3 { model.syncDurable() }
        try await TestWait.until { dot.active == 1 }
        XCTAssertEqual(dot.starts, 1, "The same home keeps its one poll")

        dot.report(DurableActivityCatalog(scope: "account", threadIDs: [thread]))
        dot.report("account", [turn(.inProgress)])
        try await TestWait.until { model.activities.contains { $0.threadID == thread && $0.phase == .running } }

        // The turn ends; a route refresh comes before the next poll reads it.
        model.syncDurable()
        dot.report("account", [turn(.completed, completed: 50)])
        try await TestWait.until { model.pendingCompletions.contains { $0.threadID == thread } }
        dot.report("account", [turn(.completed, completed: 50)])
        model.syncDurable()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.pendingCompletions.filter { $0.threadID == thread }.count, 1, "One ending, reported once")
        XCTAssertEqual(dot.starts, 1)

        // Turning Dot off stops the poll; on again starts one.
        model.defaults.set(false, forKey: IslandModel.monitorsDurableKey)
        model.syncDurable()
        try await TestWait.until { dot.active == 0 }
        XCTAssertEqual(dot.active, 0)
        model.defaults.set(true, forKey: IslandModel.monitorsDurableKey)
        model.syncDurable()
        try await TestWait.until { dot.starts == 2 && dot.active == 1 }
        XCTAssertEqual(dot.starts, 2)

        // Another Codex home is another poll.
        let other = try temporaryHome("codex-dot-other")
        model.defaults.set(other.path, forKey: "codexHome")
        model.syncDurable()
        try await TestWait.until { dot.starts == 3 && dot.active == 1 }
        XCTAssertEqual(dot.lastHome?.standardizedFileURL, other.standardizedFileURL)

        // Sleep stops the monitor directly; waking syncs it again and it restarts.
        monitor.stop()
        try await TestWait.until { dot.active == 0 }
        model.syncDurable()
        try await TestWait.until { dot.starts == 4 && dot.active == 1 }
        XCTAssertEqual(dot.starts, 4)
    }

    func testSwitchingCodexHomesLeavesTheHooksInTheLastHomeOnly() async throws {
        /// Records each pass and which homes hold Pacer's hooks; each pass takes a moment, as Codex's CLI does.
        final class Installer: @unchecked Sendable {
            private let lock = NSLock()
            private var calls: [(String, Bool)] = []
            private var installed: Set<String> = []
            func apply(_ home: URL, _ enabled: Bool) async -> CodexHookSetupResult {
                try? await Task.sleep(nanoseconds: 30_000_000)
                lock.withLock {
                    calls.append((home.lastPathComponent, enabled))
                    if enabled { installed.insert(home.path) } else { installed.remove(home.path) }
                }
                return .init(supportsHooks: true, installed: enabled, trust: enabled ? Array(repeating: "trusted", count: CodexHookEvent.Kind.allCases.count) : nil)
            }
            var log: [String] { lock.withLock { calls.map { ($0.1 ? "+" : "-") + $0.0 } } }
            var homes: Set<String> { lock.withLock { installed } }
        }
        let root = try temporaryHome("codex-homes").deletingLastPathComponent()
        let homes = try ["a", "b", "c", "d"].map { name -> URL in
            let home = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            return home
        }
        let installer = Installer()
        let model = try model(home: homes[0])
        model.codexHookSetupOverride = { home, _, enabled in await installer.apply(home, enabled) }

        model.syncCodexHooks()
        try await TestWait.until { installer.homes == [homes[0].path] }
        try await TestWait.until { model.codexHookStatus == .running }
        model.syncCodexHooks()
        XCTAssertEqual(installer.log, ["+a"], "An unchanged target is not set up again")

        model.defaults.set(homes[1].path, forKey: "codexHome")
        model.syncCodexHooks()
        try await TestWait.until { installer.homes == [homes[1].path] }
        XCTAssertEqual(installer.log, ["+a", "-a", "+b"], "Leaving a home removes the hooks there before installing in the next")

        // Two quick switches: the passes run in order and the earlier one cannot reinstall its home afterwards.
        model.defaults.set(homes[2].path, forKey: "codexHome"); model.syncCodexHooks()
        model.defaults.set(homes[3].path, forKey: "codexHome"); model.syncCodexHooks()
        try await TestWait.until { installer.log.count == 7 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(installer.log, ["+a", "-a", "+b", "-b", "+c", "-c", "+d"])
        XCTAssertEqual(installer.homes, [homes[3].path])
        XCTAssertEqual(model.codexHookStatus, .running)

        model.syncCodexHooks(force: true)
        try await TestWait.until { installer.log.count == 8 }
        XCTAssertEqual(installer.log.last, "+d", "Retry runs the same target again")
    }

    func testRetryRemovesThePreviousHomeAfterAnUninstallTimeout() async throws {
        actor Installer {
            var calls: [URL] = []
            var failedOnce = false
            func apply(_ home: URL, _ enabled: Bool) -> CodexHookSetupResult {
                calls.append(home.standardizedFileURL)
                if !enabled, !failedOnce {
                    failedOnce = true
                    return .init(supportsHooks: nil, installed: nil, trust: nil)
                }
                return .init(supportsHooks: true, installed: enabled, trust: enabled ? Array(repeating: "trusted", count: CodexHookEvent.Kind.allCases.count) : nil)
            }
        }
        let first = try temporaryHome("codex-uninstall"), second = try temporaryHome("codex-destination")
        let model = try model(home: first), installer = Installer()
        model.codexHookSetupOverride = { home, _, enabled in await installer.apply(home, enabled) }
        model.syncCodexHooks()
        let ready = try await TestWait.until { model.codexHookStatus == .running }
        XCTAssertTrue(ready)
        model.defaults.set(second.path, forKey: "codexHome")
        model.syncCodexHooks()
        let failed = try await TestWait.until { model.codexHookStatus == .installFailed }
        XCTAssertTrue(failed)
        model.syncCodexHooks(force: true)
        let recovered = try await TestWait.until { model.codexHookStatus == .running }
        XCTAssertTrue(recovered)
        let calls = await installer.calls.map(\.path)
        XCTAssertEqual(calls, [first.path, first.path, first.path, second.path])
    }

    func testAfterApprovalTheStatusFollowsActivityAndASilentHookNoticeClearsItself() async throws {
        let home = try temporaryHome("codex-status")
        let model = try model(home: home)
        model.codexHookSetupOverride = { _, _, enabled in
            .init(supportsHooks: true, installed: enabled, trust: Array(repeating: "trusted", count: CodexHookEvent.Kind.allCases.count))
        }
        model.syncCodexHooks()
        try await TestWait.until { model.codexHookStatus == .running }
        XCTAssertFalse(model.codexHooksNeedUser)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy/MM/dd"
        let now = Date(), day = formatter.string(from: now)

        // A long turn: its hook row is ten minutes old and its rollout is still being written.
        let long = try rollout(first, day: day, home: home, at: now)
        try announce(long, thread: first, home: home, at: now.addingTimeInterval(-600))
        model.refreshActivity()
        try await TestWait.until { model.activities.contains { $0.threadID == self.first } }
        model.refreshCodexHookStatusOnClock(now: now)
        try await Task.sleep(nanoseconds: 300_000_000)
        model.refreshCodexHookStatusOnClock(now: now.addingTimeInterval(61))
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.codexHookStatus, .running, "A turn the hooks hold open explains its own writes")

        // Another conversation runs a turn and no hook row follows.
        let other = try rollout(resumed, day: day, home: home, at: now)
        model.refreshCodexHookStatusOnClock(now: now.addingTimeInterval(90))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.codexHookStatus, .running, "Within a minute of the last check the clock does not list the folders")
        model.refreshCodexHookStatusOnClock(now: now.addingTimeInterval(122))
        let silent = try await TestWait.until { model.codexHookStatus == .notRunning }
        XCTAssertTrue(silent, "The clock notices the silence after approval, without Retry")
        XCTAssertTrue(model.codexHooksNeedUser, "The collapsed bar and the Remote page show it")

        // The hook writes again: the read its row causes clears the notice.
        try announce(other, thread: resumed, home: home, at: Date())
        model.refreshActivity(metricsOnly: true)
        let cleared = try await TestWait.until { model.codexHookStatus == .running }
        XCTAssertTrue(cleared, "A valid hook row clears the notice by itself")
        XCTAssertFalse(model.codexHooksNeedUser)
    }

    func testAFailedTrustReadShowsSettingUpAndIsAskedAgainAtOnce() async throws {
        final class Reads: @unchecked Sendable {
            private let lock = NSLock(); private var count = 0
            func next() -> Int { lock.withLock { count += 1; return count } }
            var value: Int { lock.withLock { count } }
        }
        let home = try temporaryHome("codex-trust")
        let model = try model(home: home)
        let reads = Reads()
        model.codexHookSetupOverride = { _, _, enabled in .init(supportsHooks: true, installed: enabled, trust: nil) }
        // Setup could not read the trust; the watch's first check asks again at once.
        model.codexHookTrustOverride = { _, _ in _ = reads.next(); return Array(repeating: "trusted", count: CodexHookEvent.Kind.allCases.count) }
        model.syncCodexHooks()
        try await TestWait.until { model.codexHookStatus == .notInstalled }
        XCTAssertFalse(model.codexHooksNeedUser, "Unknown trust shows as setting up, not as a problem")
        let started = Date()
        let running = try await TestWait.until { model.codexHookStatus == .running }
        XCTAssertTrue(running, "The trust is asked again without Retry")
        XCTAssertLessThan(Date().timeIntervalSince(started), CodexHookTrustWatch.fallback, "At the first check, not after the fallback minute")
        XCTAssertEqual(reads.value, 1)
    }

    func testACodexTooOldForHooksIsSetUpAgainWhenCodexStartsAfterItsUpdate() async throws {
        final class Codex: @unchecked Sendable {
            private let lock = NSLock(); private var updated = false; private var passes = 0
            func update() { lock.withLock { updated = true } }
            func apply(_ enabled: Bool) -> CodexHookSetupResult {
                lock.withLock {
                    passes += 1
                    return updated ? .init(supportsHooks: true, installed: enabled, trust: Array(repeating: "trusted", count: CodexHookEvent.Kind.allCases.count))
                                   : .init(supportsHooks: false, installed: false, trust: nil)
                }
            }
            var count: Int { lock.withLock { passes } }
        }
        let home = try temporaryHome("codex-update")
        let model = try model(home: home)
        let codex = Codex()
        model.codexHookSetupOverride = { _, _, enabled in codex.apply(enabled) }
        model.syncCodexHooks()
        try await TestWait.until { model.codexHookStatus == .needsCodexUpdate }

        model.codexApplicationDidLaunch("com.apple.Safari")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(codex.count, 1, "Another app starting changes nothing")

        // Codex installs its update and starts again.
        codex.update()
        model.codexApplicationDidLaunch("com.openai.codex")
        let running = try await TestWait.until { model.codexHookStatus == .running }
        XCTAssertTrue(running, "The status follows the update without Retry")
        model.codexApplicationDidLaunch("com.openai.codex")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(codex.count, 2, "A Codex that has hooks starting again sets nothing up")
    }

    func testTheCodexSetupStepsFollowTheHookStatusAsOnWindows() {
        func steps(_ status: CodexHookStatus, desktop: Bool = true) -> CodexSetupSteps { CodexSetupSteps(status: status, opensSettings: desktop) }
        XCTAssertEqual(steps(.off).update, .checking); XCTAssertEqual(steps(.off).allow, .waiting)
        XCTAssertEqual(steps(.notInstalled).update, .checking, "Setup or an unknown trust is still being checked")
        XCTAssertEqual(steps(.needsCodexUpdate).update, .needed); XCTAssertEqual(steps(.needsCodexUpdate).allow, .waiting)
        XCTAssertEqual(steps(.needsApproval(count: 7)).update, .ready)
        XCTAssertEqual(steps(.needsApproval(count: 7)).allow, .open, "Codex Desktop opens its settings with the guide")
        XCTAssertEqual(steps(.needsApproval(count: 7), desktop: false).allow, .manual, "Without Codex Desktop the step says what to do")
        XCTAssertEqual(steps(.installFailed).allow, .failed)
        for status in [CodexHookStatus.running, .notRunning] {
            XCTAssertEqual(steps(status).update, .ready); XCTAssertEqual(steps(status).allow, .done)
            XCTAssertTrue(steps(status).done, "The note's button turns to Continue")
        }
        XCTAssertFalse(steps(.needsApproval(count: 7)).done, "Later until the hooks are allowed")
    }
}
