import AppKit
import PacerMacSupport
import XCTest
@testable import PacerCore
@testable import PacerIsland

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
    private func fixture(demoArguments: [String]? = nil, demo: Bool = false) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/pacer-progress-ring-" + UUID().uuidString)
        let home = root.appendingPathComponent("claude-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let domain = "com.codexpacer.progress-ring-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(root.path, forKey: "codexHome")
        defaults.set(home.path, forKey: "claudeHome")
        defaults.set(false, forKey: "monitorSSH")
        ProviderModules(codexMode: .disabled, claudeMode: .enabled).save(to: defaults)
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let model = IslandModel(demo: demo, demoClock: { clock }, demoArguments: demoArguments, defaults: defaults,
            installation: demo ? nil : ProviderInstallationDetection(codexInstalled: false, claudeInstalled: true),
            completionDismissalStore: CompletionDismissalStore(fileURL: root.appendingPathComponent("dismissals.json")))
        model.hostApplicationResolver = { _, _, _ in [:] }
        addTeardownBlock {
            await model.shutdown()
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
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

    func testRowsDrawTheRingForClaudeOnlyWhileTheSettingIsOn() throws {
        let fixture = try fixture()
        XCTAssertEqual(fixture.model.taskPresentationOptions(for: []).progressRingProviders, [])
        fixture.defaults.set(true, forKey: IslandModel.claudeProgressRingKey)
        XCTAssertEqual(fixture.model.taskPresentationOptions(for: []).progressRingProviders, [.claude])
    }

    func testDemoClaudeTaskGoesFromDashedToItsEstimateToFullWhileCloudRowsStayDashed() throws {
        let fixture = try fixture(demoArguments: ["--demo", "--demo-claude", "--demo-cloud"], demo: true), model = fixture.model
        func rows() -> [ActivityTaskRowPresentation] { model.taskPresentation.rows.filter { $0.activity.provider == .claude } }
        func local() throws -> TaskProgressRing? { try XCTUnwrap(rows().first { $0.activity.claudeCloud == nil }).progressRing }
        model.setDemoStage(.tool)
        XCTAssertTrue(rows().allSatisfy { $0.progressRing == nil }, "The switch is off by default")
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
final class TaskProgressRingViewTests: XCTestCase {
    private typealias Ring = TaskProgressRingNSView
    private let ink = NSColor.orange.cgColor
    private let loops: Set<String> = ["pending.spin", "pending.breath", "arc.breath", "dot.travel"]
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
                       _ fraction: Double = 0, stale: Bool = false, animates: Bool = true) -> Ring.Input {
        .init(id: id, state: state, mode: mode, fraction: fraction, stale: stale, color: ink, animates: animates)
    }
    private func running(_ view: Ring) -> Set<String> { view.animationKeys.intersection(loops) }

    func testARowAppliesItsRingOnlyOnceShownAndARebuiltRowContinuesTheSweep() throws {
        let id = UUID().uuidString
        let detached = Ring(frame: NSRect(x: 0, y: 0, width: Ring.diameter, height: Ring.diameter))
        detached.update(input(id, .reported, .working, 0.3))
        XCTAssertNil(Ring.memory(for: id), "A row resumes motion only once it is in a window")

        let first = shown()
        first.update(input(id, .reported, .working, 0.3))
        XCTAssertEqual(Ring.memory(for: id)?.duration, 0, "A ring that appears with an estimate draws it at once")
        XCTAssertEqual(first.restingFraction, 0.3, accuracy: 0.0001)
        first.update(input(id, .reported, .working, 0.62))
        let sweep = try XCTUnwrap(Ring.memory(for: id))
        XCTAssertEqual(sweep.from, 0.3, accuracy: 0.0001); XCTAssertEqual(sweep.to, 0.62, accuracy: 0.0001)
        XCTAssertEqual(sweep.duration, 0.3 + 0.3 * 0.32, accuracy: 0.0001)
        XCTAssertTrue(first.animationKeys.contains("arc.sweep"))

        // The page changes mid-sweep: the new row continues on the same clock.
        let second = shown()
        second.update(input(id, .reported, .working, 0.62))
        XCTAssertEqual(Ring.memory(for: id)?.start, sweep.start)
        let begin = try XCTUnwrap(second.sweepBegin()), firstBegin = try XCTUnwrap(first.sweepBegin())
        XCTAssertEqual(begin, firstBegin, accuracy: 0.0001)
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

    func testLoopingMotionFollowsTheLifecycleMode() {
        let cases: [(TaskProgressRing.State, TaskProgressRing.Mode, Double, Bool, Set<String>)] = [
            (.pending, .working, 0, false, ["pending.spin"]),
            (.pending, .longStep, 0, false, ["pending.spin"]),
            (.pending, .attention, 0, false, []),
            (.pending, .waiting, 0, false, ["pending.breath"]),
            (.reported, .working, 0.5, false, ["dot.travel"]),
            (.reported, .working, 0.5, true, []),
            (.reported, .longStep, 0.5, false, []),
            (.reported, .waiting, 0.5, false, ["arc.breath"]),
            (.reported, .attention, 0.5, false, []),
            (.reported, .done, 1, false, []),
            (.reported, .interrupted, 0.4, false, []),
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
        XCTAssertEqual(running(view), ["dot.travel"])
        XCTAssertTrue(view.animationKeys.isSuperset(of: ["pending.opacity", "track.opacity", "arc.sweep"]),
            "The dashes close into the track before the first estimate sweeps in")
        view.update(input(id, .reported, .done, 1))
        XCTAssertEqual(running(view), [])
        XCTAssertTrue(view.animationKeys.contains("container.pulse"), "Reaching 100% settles with one pulse")
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
        XCTAssertEqual(running(view), ["dot.travel"], "Motion returns with the setting")
        view.update(input(id, .reported, .working, 0.8))
        shows = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: view.window)
        try await TestWait.until { self.running(view).isEmpty }
        XCTAssertEqual(running(view), [], "An occluded or hidden panel runs no loops")
        XCTAssertFalse(view.animationKeys.contains("arc.sweep"))
        XCTAssertEqual(Ring.memory(for: id)?.duration, 0, "A rebuilt row inherits the settled value")
        shows = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: view.window)
        try await TestWait.until { !self.running(view).isEmpty }
        XCTAssertEqual(running(view), ["dot.travel"])
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

    func testACloudRunThatEndsClosesItsDashesBeforeTheArcSweepsToFull() throws {
        let id = UUID().uuidString, view = shown()
        view.update(input(id, .pending, .working))
        let before = CACurrentMediaTime()
        view.update(input(id, .reported, .done, 1))
        let memory = try XCTUnwrap(Ring.memory(for: id))
        XCTAssertEqual(memory.from, 0); XCTAssertEqual(memory.to, 1)
        XCTAssertGreaterThanOrEqual(memory.start, before + 0.2, "The arc waits for the dashes to close")
        XCTAssertEqual(memory.duration, 0.6, accuracy: 0.0001)
        XCTAssertTrue(view.animationKeys.isSuperset(of: ["pending.opacity", "arc.sweep", "container.pulse"]))
        XCTAssertEqual(running(view), [], "The dashes stop where they are")
    }
}
