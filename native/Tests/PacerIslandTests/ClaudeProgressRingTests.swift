import AppKit
import PacerMacSupport
import XCTest
@testable import PacerCore
@testable import PacerIsland
import PacerTestSupport

/// The Mac's side of Claude's self-reported progress ring: the setting, the
/// switch file it keeps in the selected Claude home, and the rows it draws.
@MainActor
final class ClaudeProgressRingTests: XCTestCase {
    private struct Fixture {
        let model: IslandModel
        let defaults: UserDefaults
        let home: URL
        let root: URL
    }
    private func fixture(demoArguments: [String]? = nil, demo: Bool = false, codex: ProviderModuleMode = .disabled) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/pacer-progress-ring-" + UUID().uuidString)
        let home = root.appendingPathComponent("claude-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let domain = testDefaultsName("progress-ring-tests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(root.path, forKey: "codexHome")
        defaults.set(home.path, forKey: "claudeHome")
        defaults.set(false, forKey: "monitorSSH")
        ProviderModules(codexMode: codex, claudeMode: .enabled).save(to: defaults)
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let model = IslandModel(demo: demo, demoClock: { clock }, demoArguments: demoArguments, defaults: defaults,
            installation: demo ? nil : ProviderInstallationDetection(codexInstalled: false, claudeInstalled: true),
            completionDismissalStore: CompletionDismissalStore(fileURL: root.appendingPathComponent("dismissals.json")))
        model.hostApplicationResolver = { _, _, _ in [:] }
        addTeardownBlock {
            await model.shutdown()
            removeTestDefaults(domain)
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(model: model, defaults: defaults, home: home, root: root)
    }
    private func settings(_ home: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("settings.json"))) as? [String: Any])
    }
    private func pluginEnabled(_ home: URL) -> Bool {
        ((try? settings(home))?["enabledPlugins"] as? [String: Any])?["pacer@pacer"] as? Bool == true
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testEveryProvidersRingIsOnUntilItsOwnSettingTurnsItOff() throws {
        let fixture = try fixture()
        func providers() -> Set<AgentProvider> { fixture.model.taskPresentationOptions(for: []).progressRingProviders }
        XCTAssertEqual(providers(), [.claude, .codex, .deepseek], "A user who never chose sees every ring")
        fixture.defaults.set(false, forKey: IslandModel.claudeProgressRingKey)
        XCTAssertEqual(providers(), [.codex, .deepseek])
        fixture.defaults.set(false, forKey: IslandModel.deepseekProgressRingKey)
        XCTAssertEqual(providers(), [.codex])
        fixture.defaults.set(false, forKey: IslandModel.codexProgressRingKey)
        XCTAssertEqual(providers(), [])
        fixture.defaults.set(true, forKey: IslandModel.claudeProgressRingKey)
        XCTAssertEqual(providers(), [.claude], "A stored choice wins over the default either way")
    }

    /// Registration runs Codex against a real profile, so a demo or a model
    /// with injected installation state must never start it. Codex and its
    /// switch are on, so only those guards keep setup from starting.
    func testDemoAndInjectedModelsNeverRegisterTheCodexReporter() throws {
        for demo in [false, true] {
            let fixture = try fixture(demoArguments: demo ? ["--demo"] : nil, demo: demo, codex: .enabled)
            fixture.defaults.set(true, forKey: IslandModel.codexProgressRingKey)
            XCTAssertTrue(fixture.model.isModuleEnabled(.codex))
            XCTAssertTrue(fixture.model.taskPresentationOptions(for: []).progressRingProviders.contains(.codex))
            fixture.model.syncCodexProgressSwitch(force: true)
            XCTAssertNil(fixture.model.codexProgressSetup, "Setup would report settingUp at once")
            XCTAssertFalse(exists(fixture.root.appendingPathComponent("pacer/codex-progress")))
        }
    }

    func testDemoClaudeTaskGoesFromDashedToItsEstimateToFullWhileCloudRowsStayDashed() throws {
        let fixture = try fixture(demoArguments: ["--demo", "--demo-claude", "--demo-cloud"], demo: true), model = fixture.model
        func rows() -> [ActivityTaskRowPresentation] { model.taskPresentation.rows.filter { $0.activity.provider == .claude } }
        func local() throws -> TaskProgressRing? { try XCTUnwrap(rows().first { $0.activity.claudeCloud == nil }).progressRing }
        fixture.defaults.set(false, forKey: IslandModel.claudeProgressRingKey)
        model.applySettings(sourceChanged: false)
        model.setDemoStage(.tool)
        XCTAssertTrue(rows().allSatisfy { $0.progressRing == nil }, "A switch turned off draws no ring")
        fixture.defaults.set(true, forKey: IslandModel.claudeProgressRingKey)
        model.applySettings(sourceChanged: false)
        model.setDemoStage(.thinking)
        XCTAssertEqual(try local()?.state, .pending)
        model.setDemoStage(.tool)
        XCTAssertEqual(try local()?.percent, 62)
        XCTAssertEqual(try local()?.mode, .working)
        let cloud = rows().filter { $0.activity.claudeCloud != nil && $0.phase == .running }
        XCTAssertFalse(cloud.isEmpty)
        XCTAssertTrue(cloud.allSatisfy { $0.progressRing?.state == .pending && $0.progressRing?.cloud == true },
            "Cloud Projects cannot run the plugin, so their rings stay dashed while they run")
        model.setDemoStage(.completed)
        XCTAssertEqual(try local()?.mode, .done)
        XCTAssertEqual(try local()?.fraction, 1)
        XCTAssertFalse(exists(ClaudeProgressRingSwitch.flagURL(home: fixture.home)), "A demo never touches the Claude home")
    }

    func testLocalSetupAddsThePluginWhileTheRingIsOnAndTheSettingRemovesIt() async throws {
        let fixture = try fixture(), model = fixture.model, home = fixture.home
        let flag = ClaudeProgressRingSwitch.flagURL(home: home)
        fixture.defaults.set(true, forKey: IslandModel.claudeProgressRingKey)
        model.retryClaudeLocalSetup()
        try await TestWait.until { model.claudeLocalSetup == .ready }
        XCTAssertEqual(model.claudeLocalSetup, .ready)
        // Setup creates Pacer's folder before the switch can exist; the same pass writes it and adds the plugin.
        XCTAssertEqual(try String(contentsOf: flag), "tool\n")
        XCTAssertTrue(pluginEnabled(home))
        let allowed = (try settings(home)["permissions"] as? [String: Any])?["allow"] as? [String]
        XCTAssertEqual(allowed?.contains(ClaudeHookInstaller.progressTool), true)

        fixture.defaults.set(false, forKey: IslandModel.claudeProgressRingKey)
        model.applySettings(sourceChanged: false)
        XCTAssertFalse(exists(flag), "Turning the setting off removes the switch this app wrote at once")
        try await TestWait.until { !self.pluginEnabled(home) }
        XCTAssertFalse(pluginEnabled(home), "The switch change brings Pacer's settings entries current")
        XCTAssertTrue(ClaudeHookInstaller.status(home: model.claudeHome), "Pacer's hooks stay installed")
    }

    func testSwitchChangesOnlyAFileThisAppWroteOrALeftoverInAConfirmedHome() throws {
        let fixture = try fixture(), model = fixture.model, home = fixture.home
        let other = fixture.root.appendingPathComponent("other-claude-home")
        for folder in [home, other] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("pacer"), withIntermediateDirectories: true)
        }
        let flag = ClaudeProgressRingSwitch.flagURL(home: home), otherFlag = ClaudeProgressRingSwitch.flagURL(home: other)
        fixture.defaults.set(false, forKey: IslandModel.claudeProgressRingKey)
        // A leftover from another run stays until setup confirms that Pacer manages this home.
        try Data("tool\n".utf8).write(to: flag)
        XCTAssertFalse(model.applyClaudeProgressSwitch(home: home))
        XCTAssertTrue(exists(flag))
        XCTAssertTrue(model.applyClaudeProgressSwitch(home: home, setupConfirmed: true))
        XCTAssertFalse(exists(flag))

        fixture.defaults.set(true, forKey: IslandModel.claudeProgressRingKey)
        XCTAssertTrue(model.applyClaudeProgressSwitch(home: home))
        XCTAssertFalse(model.applyClaudeProgressSwitch(home: home), "An unchanged switch needs no hook update")
        XCTAssertTrue(model.applyClaudeProgressSwitch(home: other))
        XCTAssertFalse(exists(flag), "Changing the home removes the switch from the previous one")
        XCTAssertTrue(exists(otherFlag))

        // A home this app never wrote to keeps a switch someone else put there.
        try Data("tool\n".utf8).write(to: flag)
        fixture.defaults.set(false, forKey: IslandModel.claudeProgressRingKey)
        XCTAssertTrue(model.applyClaudeProgressSwitch(home: other))
        XCTAssertFalse(exists(otherFlag))
        XCTAssertFalse(model.applyClaudeProgressSwitch(home: home))
        XCTAssertTrue(exists(flag))
    }

    func testTurningTheModuleOffRemovesTheSwitch() throws {
        let fixture = try fixture(), model = fixture.model, home = fixture.home
        try FileManager.default.createDirectory(at: home.appendingPathComponent("pacer"), withIntermediateDirectories: true)
        fixture.defaults.set(true, forKey: IslandModel.claudeProgressRingKey)
        XCTAssertTrue(model.applyClaudeProgressSwitch(home: home))
        ProviderModules(codexMode: .disabled, claudeMode: .disabled).save(to: fixture.defaults)
        model.applySettings(sourceChanged: false)
        XCTAssertFalse(exists(ClaudeProgressRingSwitch.flagURL(home: home)))
    }

    func testADemoNeverWritesTheSwitch() throws {
        let fixture = try fixture(demo: true)
        try FileManager.default.createDirectory(at: fixture.home.appendingPathComponent("pacer"), withIntermediateDirectories: true)
        fixture.defaults.set(true, forKey: IslandModel.claudeProgressRingKey)
        XCTAssertFalse(fixture.model.applyClaudeProgressSwitch(home: fixture.home, setupConfirmed: true))
        XCTAssertFalse(exists(ClaudeProgressRingSwitch.flagURL(home: fixture.home)))
    }
}

/// The ring view: continuity across rebuilt rows, looping motion by mode, and
/// no clocks without motion.
@MainActor
final class TaskStatusIconViewTests: XCTestCase {
    private typealias Ring = TaskStatusIconNSView
    private let ink = NSColor.orange.cgColor
    private let loops: Set<String> = ["pending.spin", "pending.breath", "arc.breath", "flow.travel", "step.breath", "glyph.rhythm"]
    /// Whether the test windows count as on screen and unoccluded.
    private var shows = true
    private var windows: [NSWindow] = []
    private func shown() -> Ring {
        if windows.isEmpty {
            let original = Ring.windowShows
            Ring.windowShows = { [unowned self] _ in MainActor.assumeIsolated { self.shows } }
            addTeardownBlock { @MainActor in Ring.windowShows = original }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = Ring(frame: NSRect(x: 6, y: 6, width: Ring.diameter, height: Ring.diameter))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        windows.append(window)
        return view
    }
    private func input(_ id: String, _ state: TaskProgressRing.State?, _ mode: TaskProgressRing.Mode = .working,
                       _ fraction: Double = 0, stale: Bool = false, animates: Bool = true, codex: Bool = false) -> Ring.Input {
        .init(id: id, state: state, mode: mode, fraction: fraction, stale: stale, color: ink, animates: animates,
              completionPulseOnly: codex)
    }
    private func running(_ view: Ring) -> Set<String> { view.animationKeys.intersection(loops) }

    func testARowAppliesItsRingOnlyOnceShownAndRebuildsContinueTheSweepInEitherRemovalOrder() throws {
        let id = UUID().uuidString
        let detached = Ring(frame: NSRect(x: 0, y: 0, width: Ring.diameter, height: Ring.diameter))
        detached.update(input(id, .reported, .working, 0.3))
        XCTAssertNil(Ring.memory(for: id), "A row resumes motion only once it is in a window")

        for removeFirst in [false, true] {
            let id = UUID().uuidString, first = shown()
            first.update(input(id, .reported, .working, 0.3))
            XCTAssertEqual(Ring.memory(for: id)?.duration, 0, "A ring that appears with an estimate draws it at once")
            XCTAssertEqual(first.restingFraction, 0.3, accuracy: 0.0001)
            first.update(input(id, .reported, .working, 0.62))
            let sweep = try XCTUnwrap(Ring.memory(for: id)), firstBegin = try XCTUnwrap(first.sweepBegin())
            XCTAssertEqual(sweep.from, 0.3, accuracy: 0.0001); XCTAssertEqual(sweep.to, 0.62, accuracy: 0.0001)
            XCTAssertEqual(sweep.duration, 0.3 + 0.3 * 0.32, accuracy: 0.0001)

            if removeFirst { first.removeFromSuperview() }
            let second = shown()
            second.update(input(id, .reported, .working, 0.62))
            if !removeFirst { first.removeFromSuperview() }
            let resumed = try XCTUnwrap(Ring.memory(for: id))
            XCTAssertEqual(resumed.start, sweep.start, "Removing the previous row must preserve the sweep's clock")
            XCTAssertEqual(resumed.duration, sweep.duration)
            XCTAssertEqual(try XCTUnwrap(second.sweepBegin()), firstBegin, accuracy: 0.0001)
            XCTAssertTrue(first.animationKeys.isEmpty, "A removed row stops all its own animation")

            let before = CACurrentMediaTime()
            second.update(input(id, .reported, .working, 0.1))
            let after = CACurrentMediaTime(), falling = try XCTUnwrap(Ring.memory(for: id))
            XCTAssertGreaterThanOrEqual(falling.from, sweep.displayed(at: before) - 0.0001)
            XCTAssertLessThanOrEqual(falling.from, sweep.displayed(at: after) + 0.0001,
                "The next estimate starts from the displayed value rather than the previous target")
        }
    }

    func testALoweredEstimateStartsFromTheDisplayedValueAndLeavesATrace() throws {
        let id = UUID().uuidString, view = shown()
        view.update(input(id, .reported, .working, 0.3))
        view.update(input(id, .reported, .working, 0.9))
        view.update(input(id, .reported, .working, 0.1))
        let memory = try XCTUnwrap(Ring.memory(for: id))
        XCTAssertGreaterThanOrEqual(memory.from, 0.3); XCTAssertLessThanOrEqual(memory.from, 0.9)
        XCTAssertEqual(memory.to, 0.1, accuracy: 0.0001)
        XCTAssertEqual(memory.ease, .sineInOut); XCTAssertEqual(memory.duration, 0.5, accuracy: 0.0001)
        XCTAssertTrue(view.animationKeys.contains("ghost.opacity"))
    }

    func testOccludingAnOldRowCannotSettleItsVisibleSuccessor() throws {
        let id = UUID().uuidString, first = shown()
        first.update(input(id, .reported, .working, 0.3))
        first.update(input(id, .reported, .working, 0.8))
        let second = shown()
        second.update(input(id, .reported, .working, 0.8))
        let sweep = try XCTUnwrap(Ring.memory(for: id))
        shows = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: first.window)
        shows = true
        XCTAssertTrue(first.animationKeys.isEmpty)
        XCTAssertTrue(second.animationKeys.contains("arc.sweep"))
        XCTAssertEqual(Ring.memory(for: id)?.start, sweep.start)
        XCTAssertEqual(Ring.memory(for: id)?.duration, sweep.duration)
    }

    func testRememberedSweepsDoNotRetainRemovedRows() {
        let id = UUID().uuidString
        weak var removed: Ring?
        autoreleasepool {
            let view = shown()
            view.update(input(id, .reported, .working, 0.3))
            view.update(input(id, .reported, .working, 0.8))
            removed = view
            view.removeFromSuperview()
        }
        XCTAssertNil(removed)
        XCTAssertNotNil(Ring.memory(for: id), "The next row can still resume the sweep after its owner is released")
    }

    func testLoopingMotionFollowsTheLifecycleMode() {
        let cases: [(TaskProgressRing.State, TaskProgressRing.Mode, Double, Bool, Set<String>)] = [
            (.pending, .working, 0, false, ["pending.spin"]),
            (.pending, .longStep, 0, false, ["pending.spin"]),
            (.pending, .attention, 0, false, []),
            (.pending, .waiting, 0, false, ["pending.breath"]),
            (.reported, .working, 0.5, false, ["flow.travel"]),
            (.reported, .working, 0.5, true, []),
            (.reported, .longStep, 0.5, false, ["step.breath"]),
            (.reported, .waiting, 0.5, false, ["arc.breath"]),
            (.reported, .attention, 0.5, false, []),
            (.reported, .done, 1, false, []),
            (.reported, .interrupted, 0.4, false, []),
            // A paused or limited Codex goal keeps still with or without an estimate.
            (.pending, .paused, 0, false, []),
            (.reported, .paused, 0.5, false, []),
        ]
        for (state, mode, fraction, stale, expected) in cases {
            let view = shown()
            view.update(input(UUID().uuidString, state, mode, fraction, stale: stale))
            XCTAssertEqual(running(view), expected, "\(state) \(mode) stale: \(stale)")
        }
        // One row moving through a request swaps its loops without leaving any behind.
        let id = UUID().uuidString, view = shown()
        view.update(input(id, .pending, .working))
        view.update(input(id, .pending, .waiting))
        XCTAssertEqual(running(view), ["pending.breath"])
        view.update(input(id, .reported, .working, 0.4))
        XCTAssertEqual(running(view), ["flow.travel"])
        XCTAssertTrue(view.animationKeys.isSuperset(of: ["pending.opacity", "track.opacity", "arc.sweep"]),
            "The comet closes into the track before the first estimate sweeps in")
        view.update(input(id, .reported, .done, 1))
        XCTAssertEqual(running(view), [])
        XCTAssertTrue(view.animationKeys.contains("icon.pulse"), "Reaching 100% settles with one pulse")
    }

    /// Codex pulses only on a confirmed ending: a working 100% fills the arc
    /// quietly, and neither a rebuilt row nor a first sight replays it.
    func testCodexPulsesOnceWhenTheRequestEndsRatherThanWhenItReportsFull() throws {
        let pulse = "icon.pulse"
        let id = UUID().uuidString, view = shown()
        view.update(input(id, .reported, .working, 0.4, codex: true))
        view.update(input(id, .reported, .working, 1, codex: true))
        XCTAssertEqual(view.restingFraction, 1, accuracy: 0.0001)
        XCTAssertFalse(view.animationKeys.contains(pulse), "A working estimate of 100% is not an ending")
        view.update(input(id, .reported, .done, 1, codex: true))
        XCTAssertTrue(view.animationKeys.contains(pulse), "The confirmed ending pulses even after a full estimate")
        let rebuilt = shown()
        view.removeFromSuperview()
        rebuilt.update(input(id, .reported, .done, 1, codex: true))
        XCTAssertFalse(rebuilt.animationKeys.contains(pulse), "A rebuilt row of the same ending stays still")

        // The next request in the same chat drops a pulse that has yet to play.
        let next = UUID().uuidString, row = shown()
        row.update(input(next, .reported, .working, 0.8, codex: true))
        row.update(input(next, .reported, .done, 1, codex: true))
        XCTAssertTrue(row.animationKeys.contains(pulse))
        row.update(input(next, .pending, .working, codex: true))
        XCTAssertFalse(row.animationKeys.contains(pulse))
        row.update(input(next, .reported, .done, 1, codex: true))
        XCTAssertTrue(row.animationKeys.contains(pulse), "Each request's ending pulses once")

        // A request that never reported closes its comet, fills and pulses.
        let unreported = UUID().uuidString, dashed = shown()
        dashed.update(input(unreported, .pending, .working, codex: true))
        dashed.update(input(unreported, .reported, .done, 1, codex: true))
        XCTAssertTrue(dashed.animationKeys.isSuperset(of: ["pending.opacity", "arc.sweep", pulse]))

        let seen = shown()
        seen.update(input(UUID().uuidString, .reported, .done, 1, codex: true))
        XCTAssertFalse(seen.animationKeys.contains(pulse), "An ending seen for the first time draws without replaying")
        let quiet = UUID().uuidString, reduced = shown()
        reduced.update(input(quiet, .reported, .working, 0.4, animates: false, codex: true))
        reduced.update(input(quiet, .reported, .done, 1, animates: false, codex: true))
        XCTAssertTrue(reduced.animationKeys.isEmpty, "Reduced motion fills without a pulse")
    }

    func testReducedMotionAndAHiddenPanelSettleAtFinalValuesWithoutClocks() async throws {
        let id = UUID().uuidString, view = shown()
        view.update(input(id, .reported, .working, 0.3, animates: false))
        view.update(input(id, .reported, .working, 0.62, animates: false))
        XCTAssertEqual(running(view), [])
        XCTAssertFalse(view.animationKeys.contains("arc.sweep"))
        XCTAssertEqual(Ring.memory(for: id)?.duration, 0)
        XCTAssertEqual(view.restingFraction, 0.62, accuracy: 0.0001)

        view.update(input(id, .reported, .working, 0.62))
        XCTAssertEqual(running(view), ["flow.travel"], "Motion returns with the setting")
        view.update(input(id, .reported, .working, 0.8))
        shows = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: view.window)
        try await TestWait.until { self.running(view).isEmpty }
        XCTAssertTrue(view.animationKeys.isEmpty, "An occluded or hidden panel runs no animations")
        XCTAssertEqual(Ring.memory(for: id)?.duration, 0, "A rebuilt row inherits the settled value")
        shows = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: view.window)
        try await TestWait.until { !self.running(view).isEmpty }
        XCTAssertEqual(running(view), ["flow.travel"])
    }

    func testReducedMotionAndOcclusionCancelFiniteAnimationsDuringEveryTransition() throws {
        for occluded in [false, true] {
            let id = UUID().uuidString
            let transitions = [
                [input(id, .pending)],
                [input(id, .pending), input(id, .reported, .working, 0.62)],
                [input(id, .reported, .working, 0.8), input(id, .reported, .working, 0.1)],
                [input(id, .pending), input(id, .reported, .done, 1)],
                [input(id, .reported, .working, 0.8), input(id, .pending)],
                [input(id, .reported, .waiting, 0.5)],
                [input(id, .pending), input(id, nil)]
            ]
            for transition in transitions {
                shows = true
                let view = shown()
                // Each scenario has its own task memory.
                let taskID = UUID().uuidString
                for value in transition {
                    view.update(.init(id: taskID, state: value.state, mode: value.mode, fraction: value.fraction,
                        color: ink, animates: true))
                }
                let last = try XCTUnwrap(transition.last)
                XCTAssertFalse(view.animationKeys.isEmpty, "The transition must be in motion before it is stopped")
                if occluded {
                    shows = false
                    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: view.window)
                } else {
                    view.update(.init(id: taskID, state: last.state, mode: last.mode, fraction: last.fraction,
                        color: ink, animates: false))
                }
                XCTAssertTrue(view.animationKeys.isEmpty, "Stopping motion cancels pulses, crossfades, traces and loops")
                XCTAssertEqual(view.restingFraction, last.fraction, accuracy: 0.0001)
                XCTAssertEqual(view.showsRing, last.state != nil)
                if last.state != nil { XCTAssertEqual(Ring.memory(for: taskID)?.duration, 0) }
            }
        }
    }

    func testReducedMotionAppliesANewEstimateWithoutKeepingAnEarlierCompletionPulse() {
        let id = UUID().uuidString, view = shown()
        view.update(input(id, .pending))
        view.update(input(id, .reported, .done, 1))
        XCTAssertTrue(view.animationKeys.contains("icon.pulse"))
        view.update(input(id, .reported, .working, 0.2, animates: false))
        XCTAssertTrue(view.animationKeys.isEmpty)
        XCTAssertEqual(view.restingFraction, 0.2, accuracy: 0.0001)
        XCTAssertEqual(Ring.memory(for: id)?.duration, 0)
    }

    func testARingWithoutAnEstimateAtItsEndFadesAndIsForgotten() {
        let id = UUID().uuidString, view = shown()
        view.update(input(id, .pending, .working))
        XCTAssertTrue(view.showsRing)
        view.update(input(id, nil))
        XCTAssertNil(Ring.memory(for: id))
        XCTAssertTrue(view.animationKeys.contains("container.fade"))
        XCTAssertFalse(view.showsRing)
        XCTAssertEqual(running(view), [])

        let still = UUID().uuidString, reduced = shown()
        reduced.update(input(still, .pending, .working, animates: false))
        reduced.update(input(still, nil, animates: false))
        XCTAssertFalse(reduced.showsRing)
        XCTAssertFalse(reduced.animationKeys.contains("container.fade"))
    }

    func testACloudRunThatEndsClosesItsCometBeforeTheArcSweepsToFull() throws {
        let id = UUID().uuidString, view = shown()
        view.update(input(id, .pending, .working))
        let before = CACurrentMediaTime()
        view.update(input(id, .reported, .done, 1))
        let memory = try XCTUnwrap(Ring.memory(for: id))
        XCTAssertEqual(memory.from, 0); XCTAssertEqual(memory.to, 1)
        XCTAssertGreaterThanOrEqual(memory.start, before + 0.2, "The arc waits for the comet to close")
        XCTAssertEqual(memory.duration, 0.6, accuracy: 0.0001)
        XCTAssertTrue(view.animationKeys.isSuperset(of: ["pending.opacity", "arc.sweep", "icon.pulse"]))
        XCTAssertEqual(running(view), [], "The comet stops where it is")
    }

    /// The middle of the icon: a working stage lights its glyph's parts in
    /// turn; a request for the user or an ending fills a disc once, and a
    /// rebuilt row or a first sight draws it without replaying the arrival.
    func testFacesPlayTheirArrivalOnceAndOnlyWorkingGlyphsLoop() {
        func face(_ id: String, _ face: Ring.Face, _ state: TaskProgressRing.State? = nil, _ mode: TaskProgressRing.Mode = .working,
                  _ fraction: Double = 0, animates: Bool = true) -> Ring.Input {
            .init(id: id, state: state, mode: mode, fraction: fraction, face: face, color: ink, animates: animates)
        }
        let id = UUID().uuidString, view = shown()
        view.update(face(id, .working(.thinking), .reported, .working, 0.5))
        XCTAssertTrue(view.showsOrb); XCTAssertFalse(view.showsDisc)
        XCTAssertEqual(running(view), ["flow.travel", "glyph.rhythm"])
        XCTAssertFalse(view.animationKeys.contains("glyph.swap"), "A first sight draws its glyph at once")
        view.update(face(id, .working(.tool), .reported, .working, 0.5))
        XCTAssertTrue(view.animationKeys.contains("glyph.swap"), "A new stage swaps its glyph")
        view.update(face(id, .solid(.completed, read: false), .reported, .done, 1))
        XCTAssertTrue(view.showsDisc); XCTAssertFalse(view.showsOrb)
        XCTAssertTrue(view.animationKeys.isSuperset(of: ["arc.sweep", "disc.fill", "glyph.draw", "icon.pulse", "ring.opacity"]),
            "The arc closes, the disc fills, the check is drawn and the icon pops")
        XCTAssertEqual(running(view), [], "A solid face keeps still")

        let rebuilt = shown()
        view.removeFromSuperview()
        rebuilt.update(face(id, .solid(.completed, read: false), .reported, .done, 1))
        XCTAssertTrue(rebuilt.showsDisc)
        XCTAssertTrue(rebuilt.animationKeys.isDisjoint(with: ["disc.fill", "glyph.draw", "icon.pulse"]), "A rebuilt row does not replay the ending")
        rebuilt.update(face(id, .solid(.completed, read: true), .reported, .done, 1))
        XCTAssertTrue(rebuilt.animationKeys.isDisjoint(with: ["disc.fill", "icon.pulse"]), "Reading an ending greys it without a second arrival")

        let asking = UUID().uuidString, row = shown()
        row.update(face(asking, .working(.tool), .pending))
        XCTAssertEqual(running(row), ["pending.spin", "glyph.rhythm"])
        row.update(face(asking, .solid(.approval, read: false), .pending, .attention))
        XCTAssertTrue(row.animationKeys.isSuperset(of: ["disc.fill", "icon.bounce", "ripple.ping"]), "A request for the user bounces and rings")
        XCTAssertEqual(running(row), [])
        row.update(face(asking, .working(.tool), .pending))
        XCTAssertTrue(row.animationKeys.isSuperset(of: ["disc.fill", "ring.opacity"]), "Back at work, the disc empties and the ring returns")
        XCTAssertFalse(row.showsDisc)
        XCTAssertEqual(running(row), ["pending.spin", "glyph.rhythm"])
        row.update(face(asking, .solid(.failed, read: false), .reported, .failed, 0.4))
        XCTAssertTrue(row.animationKeys.contains("icon.shake"), "A failure shakes once")

        let seen = shown()
        seen.update(face(UUID().uuidString, .solid(.approval, read: false), .pending, .attention))
        XCTAssertTrue(seen.showsDisc)
        XCTAssertEqual(seen.animationKeys, [], "A request seen for the first time draws without its arrival")

        let quiet = UUID().uuidString, reduced = shown()
        reduced.update(face(quiet, .working(.thinking), .reported, .working, 0.5, animates: false))
        reduced.update(face(quiet, .solid(.completed, read: false), .reported, .done, 1, animates: false))
        XCTAssertTrue(reduced.showsDisc)
        XCTAssertTrue(reduced.animationKeys.isEmpty, "Reduced motion fills the disc without motion")
        let still = shown()
        still.update(face(UUID().uuidString, .working(.responding), .pending, animates: false))
        XCTAssertTrue(still.animationKeys.isEmpty, "Without motion the glyph keeps all its parts lit and the comet stands still")
    }

    func testWorkingGlyphsAreDrawnInsideTheirBox() {
        XCTAssertEqual(TaskGlyphArt.svg("M7.6 10.1l2.6 1.9-2.6 1.9").boundingBoxOfPath.integral, CGRect(x: 7, y: 10, width: 4, height: 4))
        let cloud = TaskGlyphArt.svg("M7.6 18.2h9a4 4 0 0 0 .5-7.97 5.4 5.4 0 0 0-10.3 1.2A3.4 3.4 0 0 0 7.6 18.2z").boundingBoxOfPath
        XCTAssertEqual(cloud.minX, 3.79, accuracy: 0.05, "The left lobe bulges outwards, on the side its flags pick")
        XCTAssertEqual(cloud.maxY, 18.2, accuracy: 0.05); XCTAssertGreaterThan(cloud.minY, 3); XCTAssertLessThan(cloud.maxX, 22)
        for symbol in [TaskSymbol.thinking, .tool, .responding, .starting, .working, .coordinating, .background] {
            let parts = TaskGlyphArt.parts(for: symbol)
            XCTAssertFalse(parts.isEmpty, "\(symbol)")
            for part in parts {
                let box = part.path.boundingBoxOfPath
                XCTAssertGreaterThan(box.width + box.height, 1, "\(symbol)")
                XCTAssertTrue(CGRect(x: 1, y: 1, width: 22, height: 22).contains(box), "\(symbol) \(box)")
            }
            XCTAssertTrue(symbol == .working || parts.contains { $0.rhythm != nil }, "Every working glyph but the cloud's has a part that moves")
        }
        for symbol in [TaskSymbol.approval, .input, .interrupted, .failed] {
            let name = try? XCTUnwrap(TaskGlyphArt.solidSymbol(for: symbol))
            XCTAssertNotNil(name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }, "\(symbol)")
        }
    }

    /// With one task reporting, the badge's comets give way to its estimate.
    func testTheBadgeDrawsTheOnlyTasksEstimateWithTheRowsMotion() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let orbit = ActivityOrbitView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        window.contentView?.addSubview(orbit)
        orbit.layoutSubtreeIfNeeded()
        let codex = [ActivityOrbit.Segment(color: .systemTeal, weight: 1), .init(color: .systemOrange, weight: 0)]
        orbit.update(segments: codex, animates: true)
        XCTAssertEqual(orbit.estimateAnimationKeys, ["orbit.orbit"])
        XCTAssertFalse(orbit.showsEstimate)
        orbit.update(segments: codex, progress: .init(fraction: 0.4, longStep: false, stale: false), animates: true)
        XCTAssertTrue(orbit.showsEstimate)
        XCTAssertEqual(orbit.estimateFraction, 0.4, accuracy: 0.0001)
        XCTAssertEqual(orbit.estimateAnimationKeys, ["flow.travel"], "Light runs along the arc in place of the orbit")
        orbit.update(segments: codex, progress: .init(fraction: 0.4, longStep: true, stale: false), animates: true)
        XCTAssertEqual(orbit.estimateAnimationKeys, ["step.breath"], "A long step breathes past the head")
        orbit.update(segments: codex, progress: .init(fraction: 0.4, longStep: false, stale: true), animates: true)
        XCTAssertEqual(orbit.estimateAnimationKeys, [], "A stale estimate keeps still")
        orbit.update(segments: codex, progress: .init(fraction: 0.7, longStep: false, stale: false), animates: false)
        XCTAssertEqual(orbit.estimateAnimationKeys, [])
        XCTAssertEqual(orbit.estimateFraction, 0.7, accuracy: 0.0001)
        orbit.update(segments: codex, progress: nil, animates: true)
        XCTAssertEqual(orbit.estimateAnimationKeys, ["orbit.orbit"], "Without an estimate the comet returns")
        XCTAssertFalse(orbit.showsEstimate)
        window.close()
    }
}
