import Foundation
import XCTest
@testable import PacerCore

final class ApplicationLifecycleCoordinatorTests: XCTestCase {
    private typealias Lifecycle = ApplicationLifecycleCoordinator
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func configuration(claude: String = "claude-first", enabled: Set<AgentProvider> = Set(AgentProvider.allCases), demo: Bool = false) -> Lifecycle.Configuration {
        .init(enabled: enabled, sources: [.codex: "codex", .claude: claude, .deepseek: "deepseek"], hasDemoSnapshot: demo)
    }
    func testChangedSourceInvalidatesOnlyItsOwnedWorkBeforeResetAndPublication() {
        var state = Lifecycle(configuration: configuration())
        let codex = state.work.begin(.init(.activity, provider: .codex), version: state.version(.codex))
        let claude = state.work.begin(.init(.activity, provider: .claude), version: state.version(.claude))
        let batch = state.work.begin(.init(.activity), version: state.revision)
        let plan = state.settings(configuration(claude: "claude-second"))
        XCTAssertEqual(plan.changedProviders, [.claude])
        XCTAssertTrue(state.owns(codex)); XCTAssertFalse(state.owns(claude))
        XCTAssertFalse(state.owns(batch))
        XCTAssertNil(state.work.task(.init(.activity)), "A stuck mixed-source read cannot block the replacement's slot")
        XCTAssertEqual(state.version(.codex), 0); XCTAssertEqual(state.version(.claude), 1)
        XCTAssertTrue(plan.actions.contains(.resetSource(.claude)))
        XCTAssertFalse(plan.actions.contains(.resetSource(.codex)))
        XCTAssertLessThan(plan.actions.firstIndex(of: .resetSource(.claude))!, plan.actions.firstIndex(of: .cloud)!)
        XCTAssertLessThan(plan.actions.firstIndex(of: .balanceBinding)!, plan.actions.firstIndex(of: .refilter)!)
    }
    func testColdStartupSleepWakeAndExitReleaseAndReplaceWork() {
        var state = Lifecycle(configuration: configuration())
        XCTAssertTrue(state.acceptsObservedWork)
        let start = state.start()
        XCTAssertEqual(state.phase, .running)
        XCTAssertLessThan(start.actions.firstIndex(of: .quota(.codex, force: true))!, start.actions.firstIndex(of: .codexActivity)!)
        XCTAssertTrue(state.start().actions.isEmpty)
        let old = state.work.begin(.init(.hostScan, provider: .claude), version: state.version(.claude))
        XCTAssertTrue(state.prepareForSleep().actions.contains(.suspendSources))
        XCTAssertTrue(state.isSleeping); XCTAssertFalse(state.owns(old)); XCTAssertEqual(state.work.count, 0)
        XCTAssertTrue(state.prepareForSleep().actions.isEmpty)
        let wake = state.resume()
        XCTAssertTrue(wake.actions.contains(.retryHostTracking)); XCTAssertTrue(state.acceptsObservedWork)
        let next = state.work.begin(.init(.hostScan, provider: .claude), version: state.version(.claude))
        XCTAssertFalse(state.work.finish(old)); XCTAssertTrue(state.owns(next))
        XCTAssertTrue(state.shutdown().actions.contains(.stopSources))
        XCTAssertTrue(state.isStopped); XCTAssertFalse(state.owns(next)); XCTAssertEqual(state.work.count, 0)
        XCTAssertTrue(state.resume().actions.isEmpty); XCTAssertTrue(state.start().actions.isEmpty)
    }
    func testTickKeepsDiscoveryCadenceAndCannotCollectDuringSleep() {
        var state = Lifecycle(configuration: configuration(enabled: [.codex, .deepseek]))
        func input(_ age: Double, connected: Bool) -> Lifecycle.Tick {
            .init(now: date, expanded: false, codexConnected: connected, lastCodexDiscovery: date.addingTimeInterval(-age),
                lastRemoteDiscovery: date.addingTimeInterval(-age), lastClaudeDiscovery: .distantPast, deepseekRunning: true)
        }
        XCTAssertFalse(state.tick(input(119.999, connected: true)).actions.contains(.codexActivity))
        XCTAssertTrue(state.tick(input(120, connected: true)).actions.contains(.codexActivity))
        XCTAssertFalse(state.tick(input(59.999, connected: false)).actions.contains(.codexActivity))
        XCTAssertTrue(state.tick(input(60, connected: false)).actions.contains(.codexActivity))
        let plan = state.tick(input(30, connected: true))
        XCTAssertTrue(plan.actions.contains(.remoteActivity)); XCTAssertFalse(plan.actions.contains(.claudeTargets))
        XCTAssertTrue(plan.actions.contains(.quota(.deepseek, force: false, active: true)))
        _ = state.prepareForSleep()
        XCTAssertEqual(state.tick(input(1000, connected: false)).actions, [.pruneActivities, .pruneHistory])
    }
    func testDemoModuleFilteringNeverResetsObservedSources() {
        var state = Lifecycle(demo: true, configuration: configuration(demo: true))
        let plan = state.settings(configuration(enabled: [.claude], demo: true))
        XCTAssertTrue(plan.changedProviders.isEmpty)
        XCTAssertEqual(state.revision, 0); XCTAssertEqual(state.version(.codex), 0)
        XCTAssertEqual(plan.actions, [.pruneActivities, .demoSnapshot, .applications])
        var observed = Lifecycle(demo: true, configuration: configuration())
        let change = observed.settings(configuration(enabled: [.claude]))
        XCTAssertEqual(change.changedProviders, [.codex, .deepseek])
        XCTAssertTrue(change.actions.contains(.resetSource(.codex))); XCTAssertFalse(change.actions.contains(.demoSnapshot))
    }
    private actor Gate {
        var released = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    func testCleanupDoesNotJoinAResourceThatIgnoresCancellation() async {
        let gate = Gate(), finished = ShutdownSignal()
        let completed = await Lifecycle.cleanup([.reader: { await gate.wait(); finished.finish() }], deadline: .init(timeout: 0))
        XCTAssertFalse(completed); XCTAssertFalse(finished.isFinished)
        await gate.release()
    }
}
